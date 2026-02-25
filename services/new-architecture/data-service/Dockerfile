FROM rust:latest as builder

WORKDIR /app
COPY Cargo.toml Cargo.toml
COPY src src

RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/data-service /app/data-service

EXPOSE 3002
CMD ["/app/data-service"]
