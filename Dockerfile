# syntax=docker/dockerfile:1.9

# ============================================================
# Stage 1: Rust toolchain
# ============================================================
FROM rust:1.91.1-trixie AS rust-toolchain


# ============================================================
# Stage 2: Build OpenViking
# ============================================================
FROM ghcr.io/astral-sh/uv:python3.13-trixie-slim AS py-builder

# Rust toolchain
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

# ============================================================
# Native build dependencies
# ============================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ccache \
    cmake \
    git \
    pkg-config \
 && rm -rf /var/lib/apt/lists/*

# Use ccache for native compilation
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR=/root/.ccache

# Cargo build cache
ENV CARGO_TARGET_DIR=/cargo-target

# uv settings
ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy
ENV UV_NO_DEV=1

WORKDIR /app


# ============================================================
# OpenViking source
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
# Install OpenViking environment
#
# IMPORTANT:
# local-embed extra is explicitly enabled.
# ============================================================
RUN --mount=type=cache,target=/root/.cache/uv,id=uv-${TARGETPLATFORM} \
    --mount=type=cache,target=/root/.npm,id=npm-${TARGETPLATFORM} \
    --mount=type=cache,target=/cargo-target,id=cargo-target-${TARGETPLATFORM} \
    --mount=type=cache,target=/usr/local/cargo/registry,id=cargo-registry-${TARGETPLATFORM} \
    --mount=type=cache,target=/usr/local/cargo/git,id=cargo-git-${TARGETPLATFORM} \
    --mount=type=cache,target=/root/.ccache,id=ccache-${TARGETPLATFORM} \
    if [ -n "${OPENVIKING_VERSION:-}" ]; then \
        export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_OPENVIKING="${OPENVIKING_VERSION}"; \
    elif [ -f openviking/_version.py ]; then \
        export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_OPENVIKING="$(
            python -c "import runpy; print(runpy.run_path('openviking/_version.py')['version'])"
        )"; \
    else \
        echo "OPENVIKING_VERSION build arg is required when building without openviking/_version.py" >&2; \
        exit 2; \
    fi; \
    case "${UV_LOCK_STRATEGY}" in \
        locked) \
            uv sync \
                --locked \
                --no-editable \
                --extra bot \
                --extra gemini \
                --extra local-embed \
            ;; \
        auto) \
            if ! uv lock --check; then \
                uv lock; \
            fi; \
            uv sync \
                --locked \
                --no-editable \
                --extra bot \
                --extra gemini \
                --extra local-embed \
            ;; \
        *) \
            echo "Unsupported UV_LOCK_STRATEGY: ${UV_LOCK_STRATEGY}" >&2; \
            exit 2 \
            ;; \
    esac


# ============================================================
# FORCE llama-cpp-python into the runtime virtualenv
#
# This is intentionally separate from the OpenViking extra.
# It guarantees that the package exists in /app/.venv.
# ============================================================
RUN uv pip install \
    --python /app/.venv/bin/python \
    --no-cache \
    llama-cpp-python


# ============================================================
# BUILD-TIME VERIFICATION
#
# Docker build MUST fail if llama-cpp-python cannot be imported.
# ============================================================
RUN /app/.venv/bin/python -c \
    "import llama_cpp; print('=================================================='); print('SUCCESS: llama-cpp-python installed'); print('Version:', llama_cpp.__version__); print('Path:', llama_cpp.__file__); print('==================================================')"


# ============================================================
# Stage 3: Runtime
# ============================================================
FROM python:3.13-slim-trixie

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    libstdc++6 \
    ripgrep \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app


# ============================================================
# Copy complete virtual environment
#
# This includes llama-cpp-python from the builder.
# ============================================================
COPY --from=py-builder /app/.venv /app/.venv

# OpenViking runtime scripts
COPY docker/openviking-entrypoint.sh /usr/local/bin/openviking-entrypoint
COPY docker/pending_health_server.py /usr/local/bin/openviking-pending-health

RUN mkdir -p /app/.openviking \
 && chmod +x \
    /usr/local/bin/openviking-entrypoint \
    /usr/local/bin/openviking-pending-health


# ============================================================
# Environment
# ============================================================
ENV HOME="/app" \
    PATH="/app/.venv/bin:$PATH" \
    OPENVIKING_CONFIG_FILE="/app/.openviking/ov.conf" \
    OPENVIKING_CLI_CONFIG_FILE="/app/.openviking/ovcli.conf"


# ============================================================
# OpenViking server
# ============================================================
EXPOSE 1933


# ============================================================
# Healthcheck
# ============================================================
HEALTHCHECK \
    --interval=30s \
    --timeout=5s \
    --start-period=30s \
    --retries=3 \
    CMD ["openviking-entrypoint", "--healthcheck"]


# ============================================================
# Persistent state
#
# Coolify volume:
#
#   openviking_data:/app/.openviking
#
# This contains:
#   /app/.openviking/ov.conf
#   /app/.openviking/ovcli.conf
#   /app/.openviking/data/
#
# Do NOT remove this volume.
# ============================================================

ENTRYPOINT ["openviking-entrypoint"]