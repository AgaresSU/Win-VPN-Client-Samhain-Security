use samhain_core::{RouteMode, Server, Subscription};
use serde::{Deserialize, Serialize};

pub const IPC_PROTOCOL_VERSION: u32 = 1;
pub const NAMED_PIPE_NAME: &str = r"\\.\pipe\SamhainSecurity.Native.Ipc";
pub const NAMED_PIPE_SHORT_NAME: &str = "SamhainSecurity.Native.Ipc";
pub const DEFAULT_REQUEST_TIMEOUT_MS: u32 = 2_500;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestEnvelope {
    pub protocol_version: u32,
    pub request_id: String,
    pub command: ClientCommand,
}

impl RequestEnvelope {
    pub fn new(request_id: impl Into<String>, command: ClientCommand) -> Self {
        Self {
            protocol_version: IPC_PROTOCOL_VERSION,
            request_id: request_id.into(),
            command,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResponseEnvelope {
    pub protocol_version: u32,
    pub request_id: String,
    pub ok: bool,
    pub event: ServiceEvent,
}

impl ResponseEnvelope {
    pub fn ok(request_id: impl Into<String>, event: ServiceEvent) -> Self {
        Self {
            protocol_version: IPC_PROTOCOL_VERSION,
            request_id: request_id.into(),
            ok: true,
            event,
        }
    }

    pub fn error(request_id: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            protocol_version: IPC_PROTOCOL_VERSION,
            request_id: request_id.into(),
            ok: false,
            event: ServiceEvent::Error {
                message: message.into(),
            },
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ClientCommand {
    Ping,
    GetState,
    AddSubscription { name: String, url: String },
    RefreshSubscription { subscription_id: String },
    RenameSubscription { subscription_id: String, name: String },
    DeleteSubscription { subscription_id: String },
    SelectServer { server_id: String },
    Connect { server_id: String, route_mode: RouteMode },
    Disconnect,
    TestPing { server_id: String },
    TestPings { server_ids: Vec<String> },
    CancelPingProbes,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ServiceEvent {
    Pong,
    State(ServiceState),
    SubscriptionAdded { subscription: Subscription },
    SubscriptionRefreshed { subscription: Subscription },
    SubscriptionRenamed { subscription: Subscription },
    SubscriptionDeleted { subscription_id: String },
    ServerSelected { server: Server },
    Connecting { server_id: String },
    Connected { server_id: String },
    Disconnected,
    PingResult(PingProbeResult),
    PingBatchResult { results: Vec<PingProbeResult> },
    PingProbesCanceled { canceled: usize },
    Error { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PingProbeResult {
    pub server_id: String,
    pub ping_ms: Option<u32>,
    pub status: String,
    pub checked_at: String,
    pub source: String,
    pub stale: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceState {
    pub version: String,
    pub running: bool,
    pub selected_server_id: Option<String>,
    pub connected_server_id: Option<String>,
    pub route_mode: RouteMode,
    pub probe_queue_active: bool,
    pub probe_results: Vec<PingProbeResult>,
    pub subscriptions: Vec<Subscription>,
}

impl Default for ServiceState {
    fn default() -> Self {
        Self {
            version: env!("CARGO_PKG_VERSION").to_string(),
            running: false,
            selected_server_id: None,
            connected_server_id: None,
            route_mode: RouteMode::WholeComputer,
            probe_queue_active: false,
            probe_results: Vec::new(),
            subscriptions: Vec::new(),
        }
    }
}

pub fn encode_event(event: &ServiceEvent) -> serde_json::Result<String> {
    serde_json::to_string(event)
}

pub fn encode_request(envelope: &RequestEnvelope) -> serde_json::Result<String> {
    serde_json::to_string(envelope)
}

pub fn decode_request(payload: &str) -> serde_json::Result<RequestEnvelope> {
    serde_json::from_str(payload.trim())
}

pub fn encode_response(envelope: &ResponseEnvelope) -> serde_json::Result<String> {
    serde_json::to_string(envelope)
}

pub fn decode_response(payload: &str) -> serde_json::Result<ResponseEnvelope> {
    serde_json::from_str(payload.trim())
}

pub fn decode_command(payload: &str) -> serde_json::Result<ClientCommand> {
    serde_json::from_str(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_command_json() {
        let command = ClientCommand::Connect {
            server_id: "server-1".to_string(),
            route_mode: RouteMode::WholeComputer,
        };

        let payload = serde_json::to_string(&command).expect("serialize");
        let decoded: ClientCommand = decode_command(&payload).expect("decode");

        assert!(matches!(decoded, ClientCommand::Connect { .. }));
    }

    #[test]
    fn round_trips_versioned_envelopes() {
        let request = RequestEnvelope::new("req-1", ClientCommand::GetState);
        let request_payload = encode_request(&request).expect("serialize request");
        let decoded_request = decode_request(&request_payload).expect("decode request");

        assert_eq!(decoded_request.protocol_version, IPC_PROTOCOL_VERSION);
        assert_eq!(decoded_request.request_id, "req-1");
        assert!(matches!(decoded_request.command, ClientCommand::GetState));

        let response = ResponseEnvelope::ok("req-1", ServiceEvent::Pong);
        let response_payload = encode_response(&response).expect("serialize response");
        let decoded_response = decode_response(&response_payload).expect("decode response");

        assert_eq!(decoded_response.protocol_version, IPC_PROTOCOL_VERSION);
        assert_eq!(decoded_response.request_id, "req-1");
        assert!(decoded_response.ok);
        assert!(matches!(decoded_response.event, ServiceEvent::Pong));
    }
}
