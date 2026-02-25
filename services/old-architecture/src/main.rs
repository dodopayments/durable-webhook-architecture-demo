use axum::{
    extract::{Json, State},
    http::StatusCode,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{error, info};
use uuid::Uuid;

// ==============================================================================
// OLD ARCHITECTURE: IN-MEMORY WEBHOOK DELIVERY (UNRELIABLE)
// ==============================================================================
//
// This demonstrates the original problem at Dodo:
// - Webhooks stored in memory
// - No durability guarantees
// - Loses events on process crash/restart
// - No audit trail
//

#[derive(Clone)]
struct AppState {
    webhook_sender: mpsc::Sender<WebhookEvent>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Payment {
    id: Uuid,
    amount: i64,
    currency: String,
    status: String,
}

#[derive(Clone, Debug)]
struct WebhookEvent {
    id: Uuid,
    payment_id: Uuid,
    event_type: String,
    payment: Payment,
}

#[derive(Serialize, Deserialize)]
struct CreatePaymentRequest {
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

    let (webhook_tx, webhook_rx) = mpsc::channel(1000);

    let state = AppState {
        webhook_sender: webhook_tx,
    };

    // Spawn webhook worker
    // CRITICAL: This worker runs in-process. If the pod crashes,
    // all pending webhooks are lost forever (no persistence)
    tokio::spawn(webhook_worker(webhook_rx));

    let app = Router::new()
        .route("/health", get(health_check))
        .route("/payments", post(create_payment))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000")
        .await
        .unwrap();

    info!("OLD ARCHITECTURE listening on port 3000");
    info!("⚠️  WARNING: This service uses IN-MEMORY webhooks and WILL LOSE DATA on crashes");

    axum::serve(listener, app).await.unwrap();
}

async fn health_check() -> &'static str {
    "OK"
}

async fn create_payment(
    State(state): State<AppState>,
    Json(req): Json<CreatePaymentRequest>,
) -> (StatusCode, Json<PaymentResponse>) {
    let payment = Payment {
        id: Uuid::new_v4(),
        amount: req.amount,
        currency: req.currency,
        status: "succeeded".to_string(),
    };

    info!("Payment created: {:?}", payment.id);

    // PROBLEM 1: Queue webhook in memory
    // If this channel operation succeeds but the process crashes during send,
    // the webhook is lost forever with no recovery mechanism
    let webhook = WebhookEvent {
        id: Uuid::new_v4(),
        payment_id: payment.id,
        event_type: "payment.succeeded".to_string(),
        payment: payment.clone(),
    };

    if let Err(e) = state.webhook_sender.send(webhook).await {
        error!("Failed to queue webhook: {}", e);
        // PROBLEM 2: Lost webhook, no retry mechanism, no audit trail
    }

    (
        StatusCode::CREATED,
        Json(PaymentResponse {
            id: payment.id,
            amount: payment.amount,
            currency: payment.currency,
            status: payment.status,
        }),
    )
}

async fn webhook_worker(mut receiver: mpsc::Receiver<WebhookEvent>) {
    let client = reqwest::Client::new();
    let merchant_url = std::env::var("MERCHANT_WEBHOOK_URL")
        .unwrap_or_else(|_| "http://localhost:4000/webhooks".to_string());

    while let Some(event) = receiver.recv().await {
        // PROBLEM 3: If the process receives SIGTERM/SIGKILL here (during Kubernetes deployment),
        // the webhook is mid-flight and lost forever

        match send_webhook(&client, &merchant_url, &event).await {
            Ok(_) => {
                info!("Webhook sent successfully: {:?}", event.payment_id);
            }
            Err(e) => {
                // PROBLEM 4: No persistent retry queue, simple error logging
                error!("Failed to send webhook: {}", e);
                // Webhook is LOST - no recovery, no audit trail
            }
        }

        // Simulate processing delay
        tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
    }
}

async fn send_webhook(
    client: &reqwest::Client,
    url: &str,
    event: &WebhookEvent,
) -> Result<(), Box<dyn std::error::Error>> {
    let body = serde_json::json!({
        "event_id": event.id,
        "event_type": event.event_type,
        "payment": {
            "id": event.payment.id,
            "amount": event.payment.amount,
            "currency": event.payment.currency,
            "status": event.payment.status,
        }
    });

    let response = client
        .post(url)
        .json(&body)
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await?;

    response.error_for_status()?;
    Ok(())
}
