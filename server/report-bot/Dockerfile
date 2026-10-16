FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git python3 curl ripgrep bubblewrap \
    && rm -rf /var/lib/apt/lists/*
# Copied from the server's already installed, authenticated Codex CLI at deployment.
COPY codex /usr/local/bin/codex
COPY codex-code-mode-host /usr/local/bin/codex-code-mode-host
COPY codex-bwrap-real /usr/local/libexec/codex-bwrap-real
COPY bwrap-wrapper.py /usr/local/bin/bwrap
RUN chmod 0755 /usr/local/bin/codex /usr/local/bin/codex-code-mode-host /usr/local/bin/bwrap /usr/local/libexec/codex-bwrap-real
ENV HOME=/tmp/home CODEX_HOME=/auth
WORKDIR /work
ENTRYPOINT ["codex"]
