# syntax=docker/dockerfile:1

# ─── Stage 1: build ───────────────────────────────────────────────────────────
FROM ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine AS builder

WORKDIR /app

COPY gleam.toml manifest.toml ./
RUN gleam deps download

COPY src ./src

RUN gleam export erlang-shipment

# ─── Stage 2: runtime ────────────────────────────────────────────────────────
FROM erlang:27-alpine AS runtime

RUN addgroup -S neural_link && adduser -S -G neural_link neural_link

WORKDIR /app

COPY --from=builder --chown=neural_link:neural_link /app/build/erlang-shipment ./

RUN mkdir -p /data && chown -R neural_link:neural_link /data

USER neural_link

ENV NEURAL_LINK_DATA_DIR=/data \
    NEURAL_LINK_PORT=9961 \
    NEURAL_LINK_TRANSPORT=http

VOLUME ["/data"]
EXPOSE 9961

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:9961/health || exit 1

ENTRYPOINT ["./entrypoint.sh", "run"]
CMD ["start", "--foreground"]
