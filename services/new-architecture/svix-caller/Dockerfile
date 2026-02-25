FROM rust:bookworm as builder

WORKDIR /app
COPY Cargo.toml Cargo.toml
COPY src src
RUN cargo build --release

FROM debian:sid-slim
RUN apt-get update && apt-get install -y ca-certificates libssl3t64 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/svix-caller /app/svix-caller

ENV PORT=9080
EXPOSE 9080

CMD ["/app/svix-caller"]
