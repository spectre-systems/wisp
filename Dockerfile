FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git coreutils \
 && rm -rf /var/lib/apt/lists/*
RUN HOME=/opt/claude bash -c "curl -fsSL https://claude.ai/install.sh | bash" \
 && ln -s "$(readlink -f /opt/claude/.local/bin/claude)" /usr/local/bin/claude \
 && useradd -m -u 1000 agent
USER agent
WORKDIR /home/agent
ENV DISABLE_AUTOUPDATER=1 HOME=/home/agent
