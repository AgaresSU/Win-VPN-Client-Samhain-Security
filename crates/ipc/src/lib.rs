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
    GetEngineCatalog,
    GetEngineStatus,
    GetProxyStatus,
    GetTunStatus,
    AddSubscription { name: String, url: String },
    RefreshSubscription { subscription_id: String },
    RenameSubscription { subscription_id: String, name: String },
    DeleteSubscription { subscription_id: String },
    SelectServer { server_id: String },
    Connect { server_id: String, route_mode: RouteMode },
    Disconnect,
    PreviewEngineConfig { server_id: String },
    StartEngine { server_id: String, route_mode: RouteMode },
    StopEngine,
    RestartEngine { server_id: String, route_mode: RouteMode },
    RestoreProxyPolicy,
    RestoreTunPolicy,
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
    EngineCatalog { engines: Vec<EngineCatalogEntry> },
    EngineStatus { state: EngineLifecycleState },
    EngineConfigPreview { preview: EngineConfigPreview },
    ProxyStatus { state: ProxyLifecycleState },
    TunStatus { state: TunLifecycleState },
    PingResult(PingProbeResult),
    PingBatchResult { results: Vec<PingProbeResult> },
    PingProbesCanceled { canceled: usize },
    Error { message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum EngineKind {
    SingBox,
    Xray,
    WireGuard,
    AmneziaWg,
    Unknown,
}

impl Default for EngineKind {
    fn default() -> Self {
        Self::Unknown
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineCatalogEntry {
    pub kind: EngineKind,
    pub name: String,
    pub executable_path: Option<String>,
    pub search_paths: Vec<String>,
    pub available: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineConfigPreview {
    pub server_id: String,
    pub engine: EngineKind,
    pub config_path: Option<String>,
    pub redacted_config: String,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineLogEntry {
    pub level: String,
    pub stream: String,
    pub message: String,
    pub captured_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineLifecycleState {
    pub status: String,
    pub engine: EngineKind,
    pub server_id: Option<String>,
    pub pid: Option<u32>,
    pub started_at: Option<String>,
    pub stopped_at: Option<String>,
    pub last_exit_code: Option<i32>,
    pub restart_attempts: u8,
    pub config_path: Option<String>,
    pub message: String,
    pub log_tail: Vec<EngineLogEntry>,
}

impl Default for EngineLifecycleState {
    fn default() -> Self {
        Self {
            status: "stopped".to_string(),
            engine: EngineKind::Unknown,
            server_id: None,
            pid: None,
            started_at: None,
            stopped_at: None,
            last_exit_code: None,
            restart_attempts: 0,
            config_path: None,
            message: "Engine is stopped.".to_string(),
            log_tail: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyLifecycleState {
    pub status: String,
    pub enabled: bool,
    pub endpoint: Option<String>,
    pub previous_enabled: Option<bool>,
    pub previous_server: Option<String>,
    pub applied_at: Option<String>,
    pub restored_at: Option<String>,
    pub message: String,
}

impl Default for ProxyLifecycleState {
    fn default() -> Self {
        Self {
            status: "inactive".to_string(),
            enabled: false,
            endpoint: None,
            previous_enabled: None,
            previous_server: None,
            applied_at: None,
            restored_at: None,
            message: "System proxy policy is inactive.".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TunLifecycleState {
    pub status: String,
    pub enabled: bool,
    pub interface_name: Option<String>,
    pub address: Option<String>,
    pub dns_servers: Vec<String>,
    pub auto_route: bool,
    pub strict_route: bool,
    pub applied_at: Option<String>,
    pub restored_at: Option<String>,
    pub message: String,
}

impl Default for TunLifecycleState {
    fn default() -> Self {
        Self {
            status: "inactive".to_string(),
            enabled: false,
            interface_name: None,
            address: None,
            dns_servers: Vec::new(),
            auto_route: false,
            strict_route: false,
            applied_at: None,
            restored_at: None,
            message: "TUN policy is inactive.".to_string(),
        }
    }
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
    pub engine_state: EngineLifecycleState,
    pub engine_catalog: Vec<EngineCatalogEntry>,
    pub proxy_state: ProxyLifecycleState,
    pub tun_state: TunLifecycleState,
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
            engine_state: EngineLifecycleState::default(),
            engine_catalog: Vec::new(),
            proxy_state: ProxyLifecycleState::default(),
            tun_state: TunLifecycleState::default(),
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
