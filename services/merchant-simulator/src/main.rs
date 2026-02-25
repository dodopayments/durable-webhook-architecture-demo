use axum::{
    extract::{Json, State},
    http::StatusCode,
    routing::{get, post},
    Router,
};
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::sync::Arc;
use tracing::info;
use uuid::Uuid;

// ==============================================================================
// MERCHANT SIMULATOR: Mock webhook endpoint that tracks received webhooks
// ==============================================================================

#[derive(Clone)]
struct AppState {
    received_webhooks: Arc<RwLock<Vec<ReceivedWebhook>>>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ReceivedWebhook {
    event_id: Uuid,
    event_type: String,
    payment_id: Uuid,
    amount: i64,
    status: String,
    received_at: String,
}

#[derive(Serialize, Deserialize)]
struct WebhookPayload {
    event_id: Uuid,
    event_type: String,
    payment: serde_json::Value,
}

#[derive(Serialize)]
struct StatsResponse {
    total_received: usize,
    unique_payments: usize,
    webhooks: Vec<ReceivedWebhook>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let state = AppState {
        received_webhooks: Arc::new(RwLock::new(Vec::new())),
    };

    let app = Router::new()
        .route("/health", get(health_check))
        .route("/webhooks", post(receive_webhook))
        .route("/stats", get(get_stats))
        .route("/reset", post(reset_webhooks))
        .with_state(state);

    let port = std::env::var("PORT").unwrap_or_else(|_| "4000".to_string());
    let instance = std::env::var("INSTANCE_NAME").unwrap_or_else(|_| "merchant".to_string());

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port))
        .await
        .unwrap();

    info!("Merchant Simulator ({}) listening on port {}", instance, port);

    axum::serve(listener, app).await.unwrap();
}

async fn health_check() -> &'static str {
    "OK"
}

async fn receive_webhook(
    State(state): State<AppState>,
    Json(payload): Json<WebhookPayload>,
) -> (StatusCode, String) {
    let webhook = ReceivedWebhook {
        event_id: payload.event_id,
        event_type: payload.event_type.clone(),
        payment_id: payload.payment["id"]
            .as_str()
            .and_then(|s| Uuid::parse_str(s).ok())
            .unwrap_or_default(),
        amount: payload.payment["amount"]
            .as_i64()
            .unwrap_or_default(),
        status: payload.payment["status"]
            .as_str()
            .unwrap_or("unknown")
            .to_string(),
        received_at: chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f").to_string(),
    };

    let payment_id = webhook.payment_id;
    state.received_webhooks.write().push(webhook);

    info!("Webhook received for payment: {}", payment_id);

    (StatusCode::OK, "Webhook received".to_string())
}

async fn get_stats(State(state): State<AppState>) -> Json<StatsResponse> {
    let webhooks = state.received_webhooks.read().clone();

    let unique_payments: HashSet<Uuid> = webhooks
        .iter()
        .map(|w| w.payment_id)
        .collect();

    info!(
        "Stats: {} webhooks, {} unique payments",
        webhooks.len(),
        unique_payments.len()
    );

    Json(StatsResponse {
        total_received: webhooks.len(),
        unique_payments: unique_payments.len(),
        webhooks,
    })
}

async fn reset_webhooks(State(state): State<AppState>) -> (StatusCode, String) {
    state.received_webhooks.write().clear();
    info!("Webhook state reset - all webhooks cleared");
    (StatusCode::OK, "Webhooks reset".to_string())
}
