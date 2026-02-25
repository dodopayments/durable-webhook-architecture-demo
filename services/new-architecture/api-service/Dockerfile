FROM rust:latest as builder

WORKDIR /app
COPY Cargo.toml Cargo.toml
COPY src src

RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/api-service /app/api-service

EXPOSE 3001
CMD ["/app/api-service"]
