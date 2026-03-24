# =============================================================================
# Stage 1: Build
# =============================================================================
FROM rust:1.88-bookworm AS builder

WORKDIR /app

# Install system dependencies for rdkafka (optional kafka feature)
RUN apt-get update && apt-get install -y --no-install-recommends \
  cmake \
  libssl-dev \
  pkg-config \
  && rm -rf /var/lib/apt/lists/*

# Copy manifests first for dependency caching
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs && echo '' > src/lib.rs
RUN cargo build --release --locked 2>/dev/null || true
RUN rm -rf src

# Copy full source and build
COPY . .
RUN touch src/main.rs src/lib.rs
RUN cargo build --release --locked

# =============================================================================
# Stage 2: Runtime
# =============================================================================
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  libssl3 \
  && rm -rf /var/lib/apt/lists/*

RUN groupadd --system app && useradd --system --gid app --create-home app

WORKDIR /app

COPY --from=builder /app/target/release/english-notes-cloud ./
COPY --from=builder /app/migrations ./migrations

USER app

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/app/english-notes-cloud", "--health-check"] || exit 1

ENTRYPOINT ["/app/english-notes-cloud"]
