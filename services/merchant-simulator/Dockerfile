FROM rust:latest as builder

WORKDIR /app
COPY Cargo.toml Cargo.toml
COPY src src

RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/merchant-simulator /app/merchant-simulator

EXPOSE 4000
CMD ["/app/merchant-simulator"]
