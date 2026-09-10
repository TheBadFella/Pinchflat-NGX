ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.2.4
ARG DEBIAN_VERSION=bookworm-20260316-slim
ARG INSTALL_SHELL_TOOLS=0

ARG DEV_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"

FROM node:24-bookworm-slim AS node

FROM ${DEV_IMAGE}

ARG TARGETPLATFORM
ARG YT_DLP_CACHE_BUST=""
ARG BGUTIL_PLUGIN_VERSION=2.0.0
RUN echo "Building for ${TARGETPLATFORM:?}"

COPY --from=node /usr/local/ /usr/local/

# Install debian packages
RUN set -eux; \
  for attempt in 1 2 3 4 5; do \
    rm -rf /var/lib/apt/lists/*; \
    apt-get clean; \
    if apt-get \
      -o Acquire::Retries=5 \
      -o Acquire::By-Hash=force \
      -o Acquire::http::No-Cache=true \
      -o Acquire::https::No-Cache=true \
      update -qq && \
      apt-get install -y --no-install-recommends inotify-tools curl git openssh-client jq \
        python3 python3-setuptools python3-wheel python3-dev pipx \
        python3-mutagen locales procps build-essential graphviz zsh unzip; then \
      break; \
    fi; \
    if [ "$attempt" -eq 5 ]; then exit 1; fi; \
    sleep 5; \
  done && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

# Install ffmpeg
RUN export FFMPEG_DOWNLOAD=$(case ${TARGETPLATFORM:-linux/amd64} in \
    "linux/amd64")   echo "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"   ;; \
    "linux/arm64")   echo "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz" ;; \
    *)               echo ""        ;; esac) && \
    curl -L ${FFMPEG_DOWNLOAD} --output /tmp/ffmpeg.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz --strip-components=2 --no-anchored -C /usr/bin/ "ffmpeg" && \
    tar -xf /tmp/ffmpeg.tar.xz --strip-components=2 --no-anchored -C /usr/bin/ "ffprobe"

# Install Yarn and project tooling
RUN set -eux; \
  node --version; \
  npm --version; \
  rm -f /usr/local/bin/yarn /usr/local/bin/yarnpkg && \
  npm install -g yarn prettier@3.9.4 sqleton@^4.0.0 && \
  yarn --version && \
  # Install baseline Elixir packages
  mix local.hex --force && \
  mix local.rebar --force && \
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
  # Download and update YT-DLP
  echo "Refreshing yt-dlp nightly cache bust token: ${YT_DLP_CACHE_BUST}" && \
  export YT_DLP_DOWNLOAD="https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp" && \
  curl -L ${YT_DLP_DOWNLOAD} -o /usr/local/bin/yt-dlp && \
  chmod a+rx /usr/local/bin/yt-dlp && \
  yt-dlp --update-to nightly && \
  # Keep the optional bgutil plugin outside the app's mounted config. It is only
  # loaded when POT_PROVIDER_URL is configured by the application.
  install -d /opt/pinchyt/yt-dlp-plugins && \
  curl -4 -fsSL --retry 5 --retry-all-errors "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/releases/download/${BGUTIL_PLUGIN_VERSION}/bgutil-ytdlp-pot-provider.zip" \
    -o /opt/pinchyt/yt-dlp-plugins/bgutil-ytdlp-pot-provider.zip && \
  chmod -R a+rX /opt/pinchyt/yt-dlp-plugins && \
  # Install Apprise
  export PIPX_HOME=/opt/pipx && \
  export PIPX_BIN_DIR=/usr/local/bin && \
  pipx install apprise && \
  # Set up optional shell tools
  if [ "${INSTALL_SHELL_TOOLS:-0}" = "1" ]; then \
    chsh -s $(which zsh) && \
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"; \
  fi && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

# Install PowerShell for repository scripts that run under Docker
RUN set -eux; \
  . /etc/os-release; \
  curl -fsSL "https://packages.microsoft.com/config/debian/${VERSION_ID}/packages-microsoft-prod.deb" -o /tmp/packages-microsoft-prod.deb; \
  dpkg -i /tmp/packages-microsoft-prod.deb; \
  rm /tmp/packages-microsoft-prod.deb; \
  apt-get update -qq; \
  apt-get install -y --no-install-recommends powershell; \
  ln -sf /usr/bin/pwsh /usr/bin/powershell; \
  apt-get clean; \
  rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

COPY mix.exs mix.lock ./
# Install Elixir deps
# NOTE: this has to be before the bulk copy to ensure that deps are cached
RUN MIX_ENV=dev mix deps.get && MIX_ENV=dev mix deps.compile
RUN MIX_ENV=test mix deps.get && MIX_ENV=test mix deps.compile

COPY . ./

# Gives us iex shell history
ENV ERL_AFLAGS="-kernel shell_history enabled"

EXPOSE 4008
