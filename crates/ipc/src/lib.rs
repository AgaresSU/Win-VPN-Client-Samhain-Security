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
    GetAppRoutingPolicy,
    AddSubscription {
        name: String,
        url: String,
    },
    RefreshSubscription {
        subscription_id: String,
    },
    RenameSubscription {
        subscription_id: String,
        name: String,
    },
    DeleteSubscription {
        subscription_id: String,
    },
    SelectServer {
        server_id: String,
    },
    Connect {
        server_id: String,
        route_mode: RouteMode,
    },
    Disconnect,
    PreviewEngineConfig {
        server_id: String,
    },
    StartEngine {
        server_id: String,
        route_mode: RouteMode,
    },
    StopEngine,
    RestartEngine {
        server_id: String,
        route_mode: RouteMode,
    },
    RestoreProxyPolicy,
    RestoreTunPolicy,
    SetAppRoutingPolicy {
        route_mode: RouteMode,
        applications: Vec<RouteApplication>,
    },
    AddRouteApplication {
        path: String,
    },
    RemoveRouteApplication {
        application_id: String,
    },
    RestoreAppRoutingPolicy,
    GetProtectionPolicy,
    SetProtectionPolicy {
        settings: ProtectionSettings,
    },
    RestoreProtectionPolicy,
    EmergencyRestore,
    TestPing {
        server_id: String,
    },
    TestPings {
        server_ids: Vec<String>,
    },
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
    AppRoutingPolicy { state: AppRoutingPolicyState },
    ProtectionPolicy { state: ProtectionPolicyState },
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
pub struct RouteApplication {
    pub id: String,
    pub name: String,
    pub path: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppRoutingPolicyState {
    pub status: String,
    pub route_mode: RouteMode,
    pub supported: bool,
    pub applications: Vec<RouteApplication>,
    pub rule_names: Vec<String>,
    pub applied_at: Option<String>,
    pub restored_at: Option<String>,
    pub message: String,
}

impl Default for AppRoutingPolicyState {
    fn default() -> Self {
        Self {
            status: "inactive".to_string(),
            route_mode: RouteMode::WholeComputer,
            supported: true,
            applications: Vec::new(),
            rule_names: Vec::new(),
            applied_at: None,
            restored_at: None,
            message: "App routing policy is inactive.".to_string(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Ipv6Policy {
    Allow,
    Block,
    PreferIpv4,
}

impl Default for Ipv6Policy {
    fn default() -> Self {
        Self::Block
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProtectionSettings {
    pub kill_switch_enabled: bool,
    pub dns_leak_protection_enabled: bool,
    pub ipv6_policy: Ipv6Policy,
    pub reconnect_enabled: bool,
    pub backoff_seconds: u32,
}

impl Default for ProtectionSettings {
    fn default() -> Self {
        Self {
            kill_switch_enabled: true,
            dns_leak_protection_enabled: true,
            ipv6_policy: Ipv6Policy::Block,
            reconnect_enabled: true,
            backoff_seconds: 2,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProtectionPolicyState {
    pub status: String,
    pub settings: ProtectionSettings,
    pub supported: bool,
    pub enforcing: bool,
    pub rule_names: Vec<String>,
    pub applied_at: Option<String>,
    pub restored_at: Option<String>,
    pub next_retry_at: Option<String>,
    pub restart_attempts: u8,
    pub message: String,
}

impl Default for ProtectionPolicyState {
    fn default() -> Self {
        Self {
            status: "inactive".to_string(),
            settings: ProtectionSettings::default(),
            supported: true,
            enforcing: false,
            rule_names: Vec::new(),
            applied_at: None,
            restored_at: None,
            next_retry_at: None,
            restart_attempts: 0,
            message: "Protection policy is inactive.".to_string(),
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
    pub app_routing_policy: AppRoutingPolicyState,
    pub protection_policy: ProtectionPolicyState,
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
            app_routing_policy: AppRoutingPolicyState::default(),
            protection_policy: ProtectionPolicyState::default(),
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
