FROM rust:1.87-slim AS chef
RUN cargo install cargo-chef --locked
WORKDIR /app

# Issue #401: Multi-stage build with cargo-chef for efficient layer caching
# Stage 1: Generate recipe from Cargo.lock (fast, cached unless dependencies change)
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# Stage 2: Build dependencies only (cached unless Cargo.lock changes)
FROM chef AS builder
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json

# Stage 3: Build application (fast rebuild on source changes, dependencies cached)
COPY . .
# Issue #1441: build only the server. Development-only binaries live behind the
# `dev-tools` feature and must never end up in the production image.
RUN cargo build --release --bin soroban-pulse

# Base runtime used by both the production and tools images.
# debian:bookworm-slim — digest pinned 2025-07-14. Update via Dependabot or manually with:
# docker inspect --format='{{index .RepoDigests 0}}' debian:bookworm-slim
FROM debian:bookworm-slim@sha256:8af0e5095f9964007f5ebd11191dfe52dcb51bf3afa2c07f055fc5451b78ba0e AS runtime-base
RUN apt-get update && apt-get install -y ca-certificates libssl3 && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Optional tools image: `docker build --target tools -t soroban-pulse-tools .`
# Used by e2e/demo seeding and code generation; not part of the production image.
FROM builder AS tools-builder
RUN cargo build --release --features dev-tools --bins

FROM runtime-base AS tools
COPY --from=tools-builder /app/target/release/gen_openapi .
COPY --from=tools-builder /app/target/release/dump_openapi .
COPY --from=tools-builder /app/target/release/gen_postman .
COPY --from=tools-builder /app/target/release/gen_subscription_scaffold .
COPY --from=builder /app/migrations ./migrations

# Final stage: production runtime image (minimal size, server binary only)
FROM runtime-base AS production
COPY --from=builder /app/target/release/soroban-pulse .
COPY --from=builder /app/migrations ./migrations

EXPOSE 3000
CMD ["./soroban-pulse"]
