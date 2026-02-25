use axum::{
    extract::{Json, Path, State},
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

#[derive(Serialize, Deserialize)]
struct PayloadRequest {
    payment_id: Uuid,
}

#[derive(Serialize, Deserialize)]
struct PaymentPayload {
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
        .max_connections(5)
        .connect(&database_url)
        .await
        .expect("Failed to connect to database");

    let state = AppState { db: pool };

    let app = Router::new()
        .route("/health", get(health_check))
        .route("/payload/:payment_id", get(get_payment_payload))
        .with_state(state);

    let port = std::env::var("PORT").unwrap_or_else(|_| "3002".to_string());

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port))
        .await
        .unwrap();

    info!("DATA SERVICE listening on port {}", port);

    axum::serve(listener, app).await.unwrap();
}

async fn health_check() -> &'static str {
    "OK"
}

async fn get_payment_payload(
    State(state): State<AppState>,
    Path(payment_id): Path<Uuid>,
) -> Result<Json<PaymentPayload>, (StatusCode, String)> {
    let query_result = sqlx::query_as::<_, (Uuid, i64, String, String)>(
        "SELECT id, amount, currency, status FROM payments WHERE id = $1"
    )
    .bind(payment_id)
    .fetch_optional(&state.db)
    .await;

    match query_result {
        Ok(Some((id, amount, currency, status))) => {
            info!("Fetched fresh payload for payment: {}", payment_id);
            Ok(Json(PaymentPayload {
                id,
                amount,
                currency,
                status,
            }))
        }
        Ok(None) => {
            Err((
                StatusCode::NOT_FOUND,
                format!("Payment not found: {}", payment_id),
            ))
        }
        Err(e) => {
            tracing::error!("Database error: {}", e);
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Database error: {}", e),
            ))
        }
    }
}
