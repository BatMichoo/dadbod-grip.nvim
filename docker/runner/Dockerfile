# Test runner for the live suite: Neovim plus every database CLI grip shells
# out to, so nothing has to be installed on the host. Ubuntu 24.04 matches the
# CI runners (same psql and mysql client packages); downloads are pinned and
# checksummed like the DuckDB CLI in .github/workflows/test.yml.
FROM ubuntu:24.04

ARG NVIM_VERSION=v0.12.6
ARG NVIM_SHA256=474430d53e6264f6d6dd18db42d6dc9df3a1b56ca9e88a325bbf860e1a811d87
# Same version as .mise.toml.
ARG JUST_VERSION=1.40.0
ARG JUST_SHA256=181b91d0ceebe8a57723fb648ed2ce1a44d849438ce2e658339df4f8db5f1263
ARG DUCKDB_VERSION=v1.5.5
ARG DUCKDB_SHA256=08c0ca117111fcede14239d0093792352befdc174218c344d232c13279643d05
# go-sqlcmd: the client Entra ID auth needs. CI uses mssql-tools18 instead.
ARG SQLCMD_VERSION=v1.10.0
ARG SQLCMD_SHA256=92516d98c63d99b0994de5b61350c91f6915f9b76f139a59039fbcb225c2e987

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bzip2 ca-certificates curl mysql-client postgresql-client sqlite3 tmux unzip \
 && rm -rf /var/lib/apt/lists/*

RUN set -eu; cd /tmp; \
    fetch() { curl -fsSL -o "$1" "$2"; echo "$3  $1" | sha256sum -c -; }; \
    fetch nvim.tar.gz "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz" "$NVIM_SHA256"; \
    tar -xzf nvim.tar.gz -C /opt; \
    ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim; \
    fetch just.tar.gz "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" "$JUST_SHA256"; \
    tar -xzf just.tar.gz -C /usr/local/bin just; \
    fetch duckdb.zip "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-amd64.zip" "$DUCKDB_SHA256"; \
    unzip -q duckdb.zip -d /usr/local/bin; \
    fetch sqlcmd.tar.bz2 "https://github.com/microsoft/go-sqlcmd/releases/download/${SQLCMD_VERSION}/sqlcmd-linux-amd64.tar.bz2" "$SQLCMD_SHA256"; \
    tar -xjf sqlcmd.tar.bz2 -C /usr/local/bin sqlcmd; \
    rm -f /tmp/*

# test-live.sh runs as the host user so files written into the mounted repo
# keep their owner. That user has no home here, so share one with the DuckDB
# extensions the federation tests load already installed (no network needed).
ENV HOME=/home/grip
# Like the CI runners. Without a UTF-8 locale the mysql client falls back to
# latin1 and multibyte text comes back as "?".
ENV LANG=C.UTF-8
RUN mkdir -p "$HOME" \
 && duckdb -c "INSTALL sqlite_scanner; INSTALL postgres_scanner; INSTALL mysql_scanner;" \
 && chmod -R a+rwX "$HOME"

WORKDIR /work
