# syntax=docker/dockerfile:1.9

# ============================================================
# Stage 1: Rust toolchain
# ============================================================
FROM rust:1.91.1-trixie AS rust-toolchain


# ============================================================
# Stage 2: Build Python environment
# ============================================================
FROM ghcr.io/astral-sh/uv:python3.13-trixie-slim AS py-builder

COPY --from=rust-toolchain /usr/local/cargo /usr/local/cargo
COPY --from=rust-toolchain /usr/local/rustup /usr/local/rustup

# Node.js for web-studio build
COPY --from=node:24-trixie-slim /usr/local/bin/node /usr/local/bin/
COPY --from=node:24-trixie-slim /usr/local/lib/node_modules/ /usr/local/lib/node_modules/

RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH="/app/.venv/bin:/usr/local/cargo/bin:${PATH}"

ARG OPENVIKING_VERSION=
ARG TARGETPLATFORM
ARG UV_LOCK_STRATEGY=auto

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ccache \
        cmake \
        git \
    && rm -rf /var/lib/apt/lists/*

# ccache
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR=/root/.ccache

# Cargo build cache
ENV CARGO_TARGET_DIR=/cargo-target

ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy
ENV UV_NO_DEV=1

WORKDIR /app


# ============================================================
# Copy OpenViking source
# ============================================================
COPY Cargo.toml Cargo.lock ./
COPY pyproject.toml uv.lock setup.py README.md ./

COPY build_support/ build_support/
COPY bot/ bot/
COPY crates/ crates/
COPY openviking/ openviking/
COPY openviking_cli/ openviking_cli/
COPY src/ src/
COPY third_party/ third_party/
COPY web-studio/ web-studio/


# ============================================================
# Install OpenViking + ALL required extras
#
# IMPORTANT:
# --extra local-embed installs llama-cpp-python
# ============================================================
RUN --mount=type=cache,target=/root/.cache/uv,id=uv-${TARGETPLATFORM} \
    --mount=type=cache,target=/root/.npm,id=npm-${TARGETPLATFORM} \
    --mount=type=cache,target=/cargo-target,id=cargo-target-${TARGETPLATFORM} \
    --mount=type=cache,target=/usr/local/cargo/registry,id=cargo-registry-${TARGETPLATFORM} \
    --mount=type=cache,target=/usr/local/cargo/git,id=cargo-git-${TARGETPLATFORM} \
    --mount=type=cache,target=/root/.ccache,id=ccache-${TARGETPLATFORM} \
    sh -c '\
        if [ -n "${OPENVIKING_VERSION:-}" ]; then \
            export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_OPENVIKING="${OPENVIKING_VERSION}"; \
        else \
            export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_OPENVIKING="0.1.0"; \
        fi; \
        if ! uv lock --check; then \
            uv lock; \
        fi; \
        uv sync \
            --locked \
            --no-editable \
            --extra bot \
            --extra gemini \
            --extra local-embed \
    '


# ============================================================
# Stage 3: Runtime
# ============================================================
FROM python:3.13-slim-trixie

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libstdc++6 \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app


# ============================================================
# Copy Python environment
# ============================================================
COPY --from=py-builder /app/.venv /app/.venv

COPY docker/openviking-entrypoint.sh \
    /usr/local/bin/openviking-entrypoint

COPY docker/pending_health_server.py \
    /usr/local/bin/openviking-pending-health


# ============================================================
# Persistent OpenViking directory
# ============================================================
RUN mkdir -p /app/.openviking \
    && chmod +x \
        /usr/local/bin/openviking-entrypoint \
        /usr/local/bin/openviking-pending-health


# ============================================================
# Environment
# ============================================================
ENV HOME="/app"
ENV PATH="/app/.venv/bin:$PATH"

ENV OPENVIKING_CONFIG_FILE="/app/.openviking/ov.conf"
ENV OPENVIKING_CLI_CONFIG_FILE="/app/.openviking/ovcli.conf"


# ============================================================
# Server
# ============================================================
EXPOSE 1933

HEALTHCHECK \
    --interval=30s \
    --timeout=5s \
    --start-period=30s \
    --retries=3 \
    CMD ["openviking-entrypoint", "--healthcheck"]


# ============================================================
# Persistent state:
#
# /app/.openviking
# ├── ov.conf
# ├── ovcli.conf
# ├── data/
# └── models/cache/etc.
#
# Coolify MUST mount the persistent volume here:
#
# openviking_data:/app/.openviking
# ============================================================

ENTRYPOINT ["openviking-entrypoint"]