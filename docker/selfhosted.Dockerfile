# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.2.4
ARG DEBIAN_VERSION=bookworm-20260316-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM node:24-bookworm-slim AS node

FROM ${BUILDER_IMAGE} AS builder

ARG TARGETPLATFORM
RUN echo "Building for ${TARGETPLATFORM:?}"

COPY --from=node /usr/local/ /usr/local/

# install build dependencies
RUN set -eux; \
    for attempt in 1 2 3 4 5; do \
      rm -rf /var/lib/apt/lists/*; \
      apt-get clean; \
      if apt-get \
        -o Acquire::Retries=5 \
        -o Acquire::By-Hash=force \
        -o Acquire::http::No-Cache=true \
        -o Acquire::https::No-Cache=true \
        update -y && \
        apt-get install -y --no-install-recommends \
          build-essential \
          git \
          curl; then \
        break; \
      fi; \
      if [ "$attempt" -eq 5 ]; then exit 1; fi; \
      sleep 5; \
    done && \
    # Remove the Node image's Yarn shim before installing Yarn globally.
    rm -f /usr/local/bin/yarn /usr/local/bin/yarnpkg && \
    npm install -g yarn && \
    yarn --version && \
    # Hex and Rebar
    mix local.hex --force && \
    mix local.rebar --force && \
    # FFmpeg
    export FFMPEG_DOWNLOAD=$(case ${TARGETPLATFORM:-linux/amd64} in \
    "linux/amd64")   echo "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"   ;; \
    "linux/arm64")   echo "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz" ;; \
    *)               echo ""        ;; esac) && \
    curl -L ${FFMPEG_DOWNLOAD} --output /tmp/ffmpeg.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz --strip-components=2 --no-anchored -C /usr/local/bin/ "ffmpeg" && \
    tar -xf /tmp/ffmpeg.tar.xz --strip-components=2 --no-anchored -C /usr/local/bin/ "ffprobe" && \
    # Cleanup
    apt-get clean && \
    rm -f /var/lib/apt/lists/*_*

# prepare build dir
WORKDIR /app

# set build ENV
ENV MIX_ENV="prod"
ENV ERL_FLAGS="+JPperf true"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV && mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Compile assets
RUN yarn --cwd assets install && mix assets.deploy && mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

## -- Release Stage --

FROM ${RUNNER_IMAGE}

ARG TARGETPLATFORM
ARG PORT=8945
ARG BGUTIL_PLUGIN_VERSION=2.0.0
ARG YT_DLP_CACHE_BUST=""

COPY --from=builder ./usr/local/bin/ffmpeg /usr/bin/ffmpeg
COPY --from=builder ./usr/local/bin/ffprobe /usr/bin/ffprobe

RUN set -eux; \
    for attempt in 1 2 3 4 5; do \
      rm -rf /var/lib/apt/lists/*; \
      apt-get clean; \
      if apt-get \
        -o Acquire::Retries=5 \
        -o Acquire::By-Hash=force \
        -o Acquire::http::No-Cache=true \
        -o Acquire::https::No-Cache=true \
        update -y && \
        apt-get install -y --no-install-recommends \
          libstdc++6 \
          openssl \
          libncurses5 \
          locales \
          ca-certificates \
          python3-mutagen \
          curl \
          zip \
          openssh-client \
          nano \
          python3 \
          pipx \
          jq \
          unzip \
          procps; then \
        break; \
      fi; \
      if [ "$attempt" -eq 5 ]; then exit 1; fi; \
      sleep 5; \
    done && \
    # Install Deno - required for YouTube downloads (See yt-dlp#14404)
    case "${TARGETPLATFORM:-linux/amd64}" in \
      "linux/amd64") DENO_ARCH="x86_64" ;; \
      "linux/arm64") DENO_ARCH="aarch64" ;; \
      *) echo "Unsupported platform: ${TARGETPLATFORM}" >&2; exit 1 ;; \
    esac && \
    curl -4 -fsSL --retry 5 --retry-all-errors "https://github.com/denoland/deno/releases/latest/download/deno-${DENO_ARCH}-unknown-linux-gnu.zip" -o /tmp/deno.zip && \
    unzip -q /tmp/deno.zip deno -d /usr/local/bin && \
    chmod a+rx /usr/local/bin/deno && \
    rm -f /tmp/deno.zip && \
    # Apprise
    export PIPX_HOME=/opt/pipx && \
    export PIPX_BIN_DIR=/usr/local/bin && \
    pipx install apprise && \
    # yt-dlp
    echo "Refreshing yt-dlp nightly cache bust token: ${YT_DLP_CACHE_BUST}" && \
    export YT_DLP_DOWNLOAD="https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp" && \
    curl -L ${YT_DLP_DOWNLOAD} -o /usr/local/bin/yt-dlp && \
    chmod a+rx /usr/local/bin/yt-dlp && \
    yt-dlp --update-to nightly && \
    # Set the locale
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen && \
    # Clean up
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# More locale setup
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"

# Set up data volumes
RUN mkdir -p /config /downloads /opt/pinchyt/yt-dlp-plugins /etc/elixir_tzdata_data /etc/yt-dlp/plugins && \
  chmod ugo+rw /etc/elixir_tzdata_data /etc/yt-dlp /etc/yt-dlp/plugins /usr/local/bin /usr/local/bin/yt-dlp

# The official bgutil plugin is installed as a zip in a dedicated directory.
# PinchYT adds --plugin-dirs only when POT_PROVIDER_URL is valid, so the
# disabled configuration keeps the existing yt-dlp command line unchanged.
RUN curl -4 -fsSL --retry 5 --retry-all-errors "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/releases/download/${BGUTIL_PLUGIN_VERSION}/bgutil-ytdlp-pot-provider.zip" \
      -o /opt/pinchyt/yt-dlp-plugins/bgutil-ytdlp-pot-provider.zip && \
    chmod -R a+rX /opt/pinchyt/yt-dlp-plugins

# set runner ENV
ENV MIX_ENV="prod"
ENV PORT=${PORT}
ENV RUN_CONTEXT="selfhosted"
ENV UMASK=022
EXPOSE ${PORT}

# Only copy the final release from the build stage
COPY --from=builder /app/_build/${MIX_ENV}/rel/pinchflat ./

HEALTHCHECK --interval=30s --start-period=15s \
  CMD curl --fail http://localhost:${PORT}/healthcheck || exit 1

# Start the app
CMD ["/app/bin/docker_start"]
