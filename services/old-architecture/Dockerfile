FROM rust:latest as builder

WORKDIR /app
COPY Cargo.toml Cargo.toml
COPY src src

RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/old-architecture /app/old-architecture

EXPOSE 3000
CMD ["/app/old-architecture"]
