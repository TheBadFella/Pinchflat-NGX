ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.2.4
ARG DEBIAN_VERSION=bookworm-20260316-slim
ARG INSTALL_SHELL_TOOLS=0

ARG DEV_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"

FROM ${DEV_IMAGE}

ARG TARGETPLATFORM
ARG YT_DLP_CACHE_BUST=""
RUN echo "Building for ${TARGETPLATFORM:?}"

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

# Install nodejs and Yarn
RUN curl -sL https://deb.nodesource.com/setup_20.x -o nodesource_setup.sh && \
  bash nodesource_setup.sh && \
  set -eux; \
  for attempt in 1 2 3 4 5; do \
    rm -rf /var/lib/apt/lists/*; \
    apt-get clean; \
    if apt-get \
      -o Acquire::Retries=5 \
      -o Acquire::By-Hash=force \
      -o Acquire::http::No-Cache=true \
      -o Acquire::https::No-Cache=true \
      update -qq && \
      apt-get install -y --no-install-recommends nodejs; then \
      break; \
    fi; \
    if [ "$attempt" -eq 5 ]; then exit 1; fi; \
    sleep 5; \
  done && \
  npm install -g yarn prettier@3.8.1 sqleton@^4.0.0 && \
  # Install baseline Elixir packages
  mix local.hex --force && \
  mix local.rebar --force && \
  # Install Deno - required for YouTube downloads (See yt-dlp#14404)
  curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh -s -- -y --no-modify-path && \
  # Download and update YT-DLP
  echo "Refreshing yt-dlp nightly cache bust token: ${YT_DLP_CACHE_BUST}" && \
  export YT_DLP_DOWNLOAD="https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp" && \
  curl -L ${YT_DLP_DOWNLOAD} -o /usr/local/bin/yt-dlp && \
  chmod a+rx /usr/local/bin/yt-dlp && \
  yt-dlp --update-to nightly && \
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
