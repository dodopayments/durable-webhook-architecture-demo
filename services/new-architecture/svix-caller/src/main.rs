use restate_sdk::prelude::*;
use svix::api::{MessageIn, Svix, SvixOptions};
use std::time::Duration;
use uuid::Uuid;

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct DomainEvent {
    pub id: u64,
    pub event_type: String,
    pub object_id: String,
    pub merchant_id: String,
    pub payload: serde_json::Value,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct PaymentPayload {
    pub id: Uuid,
    pub amount: i64,
    pub currency: String,
    pub status: String,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct WebhookPayload {
    pub event_id: String,
    pub event_type: String,
    pub payment: PaymentPayload,
}

#[restate_sdk::service]
trait SvixCaller {
    async fn process(event: Json<DomainEvent>) -> HandlerResult<String>;
}

pub struct SvixCallerImpl;

impl SvixCaller for SvixCallerImpl {
    async fn process(&self, _ctx: Context<'_>, event: Json<DomainEvent>) -> HandlerResult<String> {
        let event = event.0;
        let event_id = format!("evt_{}", event.object_id);

        tracing::info!("Processing event via Restate + Svix: {}", event_id);

        // Get configuration from environment
        let svix_token = std::env::var("SVIX_AUTH_TOKEN")
            .map_err(|_| "SVIX_AUTH_TOKEN not set")?;

        let data_service_url = std::env::var("DATA_SERVICE_URL")
            .unwrap_or_else(|_| "http://data-service:3002".to_string());

        let event_uuid = Uuid::parse_str(&event.object_id)
            .unwrap_or_else(|_| Uuid::new_v4());

        // Fetch enriched payload from data-service
        let payload_url = format!("{}/payload/{}", data_service_url, event.object_id);
        let client = reqwest::Client::new();

        tracing::info!("Fetching payload from: {}", payload_url);
        let payment_payload = client
            .get(&payload_url)
            .timeout(Duration::from_secs(5))
            .send()
            .await
            .map_err(|e| format!("Failed to fetch payload: {}", e))?
            .json::<PaymentPayload>()
            .await
            .map_err(|e| format!("Failed to parse payload: {}", e))?;

        tracing::info!("Fetched payload for payment: {}", event.object_id);

        // Construct webhook payload
        let webhook_payload = WebhookPayload {
            event_id: event_uuid.to_string(),
            event_type: event.event_type.clone(),
            payment: payment_payload,
        };

        // Initialize Svix client
        // The SDK automatically detects the region from the token (.eu suffix)
        tracing::info!("Initializing Svix client");
        let svix = Svix::new(svix_token, None);

        // Create message in Svix
        // Application ID is the merchant_id (each merchant has their own Svix application)
        tracing::info!("Sending message to Svix for application: {}", event.merchant_id);

        let message_in = MessageIn {
            event_type: event.event_type.clone(),
            event_id: Some(event_uuid.to_string()),
            payload: serde_json::to_value(&webhook_payload)
                .map_err(|e| format!("Failed to serialize webhook payload: {}", e))?,
            ..MessageIn::default()
        };

        match svix.message()
            .create(event.merchant_id.clone(), message_in, None)
            .await
        {
            Ok(_) => {
                tracing::info!("Message sent to Svix successfully: {}", event_uuid);
                tracing::info!("Svix will handle delivery to merchant's endpoints");
                Ok(format!("sent_to_svix:{}", event_uuid))
            }
            Err(e) => {
                let error_msg = format!("{}", e);

                // Check if error is 404 Application not found
                if error_msg.contains("404") && error_msg.contains("not_found") {
                    tracing::warn!(
                        "Svix application not found for merchant_id: {}. Skipping event. \
                        Create application via: curl -X POST https://api.eu.svix.com/api/v1/app \
                        -H 'Authorization: Bearer YOUR_TOKEN' \
                        -d '{{\"name\": \"Merchant Name\", \"uid\": \"{}\"}}' ",
                        event.merchant_id,
                        event.merchant_id
                    );
                    // Return success to prevent Restate from retrying
                    Ok(format!("skipped_no_app:{}", event_uuid))
                } else {
                    // Other errors are retryable
                    Err(format!("Svix API error: {}", e).into())
                }
            }
        }
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    let port = std::env::var("PORT").unwrap_or_else(|_| "9080".to_string());

    tracing::info!("Starting Svix Caller service on port {}", port);
    tracing::info!("This service sends webhook events to Svix Cloud for delivery");

    HttpServer::new(
        Endpoint::builder()
            .bind(SvixCallerImpl.serve())
            .build(),
    )
    .listen_and_serve(format!("0.0.0.0:{}", port).parse().unwrap())
    .await;
}
