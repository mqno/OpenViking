# syntax=docker/dockerfile:1.9

# ============================================================
# Stage 1: Rust toolchain
# ============================================================
FROM rust:1.91.1-trixie AS rust-toolchain


# ============================================================
# Stage 2: Build OpenViking + native dependencies
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

# Native build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ccache \
    cmake \
    git \
    pkg-config \
 && rm -rf /var/lib/apt/lists/*

# Make cmake pick ccache gcc/g++
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR=/root/.ccache
ENV CARGO_TARGET_DIR=/cargo-target

ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy
ENV UV_NO_DEV=1

WORKDIR /app


# ============================================================
# Copy source
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
# Install Python environment
#
# IMPORTANT:
# local-embed MUST be included here so llama-cpp-python
# becomes part of /app/.venv and is copied into runtime.
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
# HARD CHECK
#
# Do NOT allow Docker build to succeed if llama-cpp-python
# wasn't actually installed.
# ============================================================
RUN /app/.venv/bin/python -c \
    "import llama_cpp; print('llama-cpp-python OK:', llama_cpp.__version__)"


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


# Copy complete virtual environment including llama-cpp-python
COPY --from=py-builder /app/.venv /app/.venv

COPY docker/openviking-entrypoint.sh /usr/local/bin/openviking-entrypoint
COPY docker/pending_health_server.py /usr/local/bin/openviking-pending-health

RUN mkdir -p /app/.openviking \
 && chmod +x \
    /usr/local/bin/openviking-entrypoint \
    /usr/local/bin/openviking-pending-health


ENV HOME="/app" \
    PATH="/app/.venv/bin:$PATH" \
    OPENVIKING_CONFIG_FILE="/app/.openviking/ov.conf" \
    OPENVIKING_CLI_CONFIG_FILE="/app/.openviking/ovcli.conf"


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
#   ├── ov.conf
#   ├── ovcli.conf
#   └── data/
#
# Coolify volume:
#   openviking_data:/app/.openviking
# ============================================================


ENTRYPOINT ["openviking-entrypoint"]