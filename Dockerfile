FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git coreutils \
 && rm -rf /var/lib/apt/lists/*
RUN HOME=/opt/claude bash -c "curl -fsSL https://claude.ai/install.sh | bash" \
 && ln -s "$(readlink -f /opt/claude/.local/bin/claude)" /usr/local/bin/claude \
 && useradd -m -u 1000 agent
# Codex CLI: pacote oficial (musl) completo, porque o shell do agente precisa do
# codex-code-mode-host ao lado do binário. A parte de voz fica de fora.
ARG CODEX_VERSION=0.157.0
RUN mkdir -p /opt/codex \
 && curl -fsSL "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-package-x86_64-unknown-linux-musl.tar.gz" \
    | tar -xz -C /opt/codex --exclude='codex-resources/voice' \
 && ln -s /opt/codex/bin/codex /usr/local/bin/codex \
 && codex --version
USER agent
WORKDIR /home/agent
ENV DISABLE_AUTOUPDATER=1 HOME=/home/agent
