use axum::{
    extract::{Json, State},
    http::StatusCode,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use tracing::info;
use uuid::Uuid;

#[derive(Clone)]
struct AppState {
    db: PgPool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Payment {
    id: Uuid,
    amount: i64,
    currency: String,
    status: String,
}

#[derive(Serialize, Deserialize)]
struct CreatePaymentRequest {
    merchant_id: Option<String>,
    amount: i64,
    currency: String,
}

#[derive(Serialize, Deserialize)]
struct PaymentResponse {
    id: Uuid,
    amount: i64,
    currency: String,
    status: String,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let database_url = std::env::var("DATABASE_URL")
        .expect("DATABASE_URL must be set");

    let pool = PgPoolOptions::new()
        .max_connections(50) // Increased for load testing
        .connect(&database_url)
        .await
        .expect("Failed to connect to database");

    let state = AppState { db: pool };

    let app = Router::new()
        .route("/health", get(health_check))
        .route("/payments", post(create_payment))
        .with_state(state);

    let port = std::env::var("PORT").unwrap_or_else(|_| "3001".to_string());

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port))
        .await
        .unwrap();

    info!("NEW ARCHITECTURE API listening on port {}", port);

    axum::serve(listener, app).await.unwrap();
}

async fn health_check() -> &'static str {
    "OK"
}

async fn create_payment(
    State(state): State<AppState>,
    Json(req): Json<CreatePaymentRequest>,
) -> Result<(StatusCode, Json<PaymentResponse>), (StatusCode, String)> {
    let payment_id = Uuid::new_v4();

    // Use provided merchant_id:
    // - If it's a valid UUID, use it directly
    // - If it's a string, convert to deterministic UUID (for testing)
    // - Otherwise generate a new random UUID
    let merchant_id = match &req.merchant_id {
        Some(id) => {
            Uuid::parse_str(id).unwrap_or_else(|_| {
                // Convert string to deterministic UUID using v5 (name-based)
                Uuid::new_v5(&Uuid::NAMESPACE_DNS, id.as_bytes())
            })
        }
        None => Uuid::new_v4(),
    };

    // ATOMIC OPERATION: INSERT payment, trigger creates event automatically
    // The PostgreSQL trigger fires automatically and creates the domain event
    // If this transaction fails, BOTH payment and event are rolled back
    let result = sqlx::query(
        r#"
        INSERT INTO payments (id, merchant_id, amount, currency, status)
        VALUES ($1, $2, $3, $4, $5)
        "#,
    )
    .bind(payment_id)
    .bind(merchant_id)
    .bind(req.amount)
    .bind(&req.currency)
    .bind("succeeded")
    .execute(&state.db)
    .await;

    match result {
        Ok(_) => {
            info!(
                "Payment created atomically: {} (event created by trigger)",
                payment_id
            );

            // GUARANTEE: Event exists in database
            // Sequin is already reading the WAL and will catch it within milliseconds
            Ok((
                StatusCode::CREATED,
                Json(PaymentResponse {
                    id: payment_id,
                    amount: req.amount,
                    currency: req.currency,
                    status: "succeeded".to_string(),
                }),
            ))
        }
        Err(e) => {
            tracing::error!("Failed to create payment: {}", e);
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to create payment: {}", e),
            ))
        }
    }
}
