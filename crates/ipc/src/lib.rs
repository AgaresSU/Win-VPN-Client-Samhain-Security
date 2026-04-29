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
    GetServiceSelfCheck,
    GetTrafficStats,
    GetLogs {
        category: Option<String>,
    },
    ExportSupportBundle,
    AddSubscription {
        name: String,
        url: String,
    },
    RefreshSubscription {
        subscription_id: String,
    },
    PinSubscription {
        subscription_id: String,
    },
    GetSubscriptionUrl {
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
    SubscriptionAdded {
        subscription: Subscription,
    },
    SubscriptionRefreshed {
        subscription: Subscription,
    },
    SubscriptionPinned {
        subscription: Subscription,
    },
    SubscriptionUrl {
        subscription_id: String,
        url: String,
    },
    SubscriptionRenamed {
        subscription: Subscription,
    },
    SubscriptionDeleted {
        subscription_id: String,
    },
    ServerSelected {
        server: Server,
    },
    Connecting {
        server_id: String,
    },
    Connected {
        server_id: String,
    },
    Disconnected,
    EngineCatalog {
        engines: Vec<EngineCatalogEntry>,
    },
    EngineStatus {
        state: EngineLifecycleState,
    },
    EngineConfigPreview {
        preview: EngineConfigPreview,
    },
    ProxyStatus {
        state: ProxyLifecycleState,
    },
    TunStatus {
        state: TunLifecycleState,
    },
    AppRoutingPolicy {
        state: AppRoutingPolicyState,
    },
    ProtectionPolicy {
        state: ProtectionPolicyState,
    },
    ServiceSelfCheck {
        state: ServiceSelfCheckState,
    },
    TrafficStats {
        state: TrafficStatsState,
    },
    LogSnapshot {
        snapshot: LogSnapshotState,
    },
    SupportBundle {
        state: SupportBundleState,
    },
    PingResult(PingProbeResult),
    PingBatchResult {
        results: Vec<PingProbeResult>,
    },
    PingProbesCanceled {
        canceled: usize,
    },
    Error {
        message: String,
    },
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
    pub runtime_id: String,
    pub name: String,
    pub executable_path: Option<String>,
    pub bundled_path: String,
    pub expected_paths: Vec<String>,
    pub search_paths: Vec<String>,
    pub available: bool,
    pub status: String,
    pub protocols: Vec<String>,
    pub sha256: Option<String>,
    pub file_size_bytes: Option<u64>,
    pub version: Option<String>,
    pub version_status: String,
    pub message: String,
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
    pub enforcement_requested: bool,
    pub enforcement_available: bool,
    pub applications: Vec<RouteApplication>,
    pub rule_names: Vec<String>,
    pub evidence: Vec<String>,
    #[serde(default)]
    pub release_supported: Vec<String>,
    #[serde(default)]
    pub experimental: Vec<String>,
    #[serde(default)]
    pub compatibility: Vec<String>,
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
            enforcement_requested: false,
            enforcement_available: false,
            applications: Vec::new(),
            rule_names: Vec::new(),
            evidence: Vec::new(),
            release_supported: Vec::new(),
            experimental: Vec::new(),
            compatibility: Vec::new(),
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
    #[serde(default)]
    pub transaction: ProtectionTransactionState,
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
            transaction: ProtectionTransactionState::default(),
            applied_at: None,
            restored_at: None,
            next_retry_at: None,
            restart_attempts: 0,
            message: "Protection policy is inactive.".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProtectionTransactionStep {
    pub id: String,
    pub action: String,
    pub target: String,
    pub command: Vec<String>,
    pub rollback_command: Vec<String>,
    pub status: String,
    pub evidence: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProtectionTransactionState {
    pub id: String,
    pub kind: String,
    pub status: String,
    pub dry_run: bool,
    pub applied: bool,
    pub rollback_available: bool,
    pub before_snapshot: Vec<String>,
    pub after_snapshot: Vec<String>,
    pub applied_at: Option<String>,
    pub rolled_back_at: Option<String>,
    pub steps: Vec<ProtectionTransactionStep>,
    pub message: String,
}

impl Default for ProtectionTransactionState {
    fn default() -> Self {
        Self {
            id: "none".to_string(),
            kind: "protection".to_string(),
            status: "none".to_string(),
            dry_run: false,
            applied: false,
            rollback_available: false,
            before_snapshot: Vec::new(),
            after_snapshot: Vec::new(),
            applied_at: None,
            rolled_back_at: None,
            steps: Vec::new(),
            message: "No protection transaction has been prepared.".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceReadinessState {
    pub status: String,
    pub identity: String,
    pub required_identity: String,
    pub identity_valid: bool,
    pub signing_state: String,
    pub signing_valid: bool,
    pub running_as_admin: bool,
    pub privileged_policy_allowed: bool,
    pub protection_enforcement_requested: bool,
    pub app_routing_enforcement_requested: bool,
    pub firewall_enforcement_available: bool,
    pub app_routing_enforcement_available: bool,
    pub recovery_policy: String,
    pub audit_log_path: Option<String>,
    pub checks: Vec<String>,
    pub message: String,
}

impl Default for ServiceReadinessState {
    fn default() -> Self {
        Self {
            status: "current-user".to_string(),
            identity: "current-user-package".to_string(),
            required_identity: "signed-privileged-service".to_string(),
            identity_valid: false,
            signing_state: "unsigned-dev".to_string(),
            signing_valid: false,
            running_as_admin: false,
            privileged_policy_allowed: false,
            protection_enforcement_requested: false,
            app_routing_enforcement_requested: false,
            firewall_enforcement_available: false,
            app_routing_enforcement_available: false,
            recovery_policy: "service-owned".to_string(),
            audit_log_path: None,
            checks: vec![
                "service identity: current user package".to_string(),
                "privileged identity: pending installer service".to_string(),
                "app routing layer: pending WFP implementation".to_string(),
            ],
            message: "Privileged service identity is not installed yet.".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryPolicyState {
    pub owner: String,
    pub watchdog_enabled: bool,
    pub emergency_restore_owner: String,
    pub reconnect_attempts: u8,
    pub backoff_base_ms: u64,
    pub service_failure_restart: bool,
    pub evidence: Vec<String>,
}

impl Default for RecoveryPolicyState {
    fn default() -> Self {
        Self {
            owner: "service".to_string(),
            watchdog_enabled: true,
            emergency_restore_owner: "service".to_string(),
            reconnect_attempts: 3,
            backoff_base_ms: 250,
            service_failure_restart: false,
            evidence: vec![
                "watchdog_owner=service".to_string(),
                "emergency_restore_owner=service".to_string(),
                "installer_recovery_policy=pending-status-check".to_string(),
            ],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceCheckItem {
    pub name: String,
    pub ok: bool,
    pub status: String,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceSelfCheckState {
    pub status: String,
    pub generated_at: String,
    pub checks: Vec<ServiceCheckItem>,
    pub recovery_policy: RecoveryPolicyState,
    pub audit_log_path: Option<String>,
}

impl Default for ServiceSelfCheckState {
    fn default() -> Self {
        Self {
            status: "unknown".to_string(),
            generated_at: "not collected".to_string(),
            checks: Vec::new(),
            recovery_policy: RecoveryPolicyState::default(),
            audit_log_path: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceAuditEvent {
    pub id: u64,
    pub timestamp: String,
    pub category: String,
    pub action: String,
    pub result: String,
    pub detail: String,
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
pub struct TrafficStatsState {
    pub status: String,
    pub started_at: Option<String>,
    pub updated_at: String,
    pub download_bytes: u64,
    pub upload_bytes: u64,
    pub download_bps: u64,
    pub upload_bps: u64,
    pub session_seconds: u64,
    pub source: String,
    pub metrics_source: String,
    pub fallback: bool,
    pub route_path: String,
    pub last_error: Option<String>,
    pub last_successful_handshake: Option<String>,
    pub message: String,
}

impl Default for TrafficStatsState {
    fn default() -> Self {
        Self {
            status: "idle".to_string(),
            started_at: None,
            updated_at: "not collected".to_string(),
            download_bytes: 0,
            upload_bytes: 0,
            download_bps: 0,
            upload_bps: 0,
            session_seconds: 0,
            source: "service".to_string(),
            metrics_source: "none".to_string(),
            fallback: true,
            route_path: "idle".to_string(),
            last_error: None,
            last_successful_handshake: None,
            message: "Traffic counters are idle.".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeHealthState {
    pub status: String,
    pub engine: EngineKind,
    pub route_path: String,
    pub metrics_source: String,
    pub metrics_available: bool,
    pub last_error: Option<String>,
    pub last_successful_handshake: Option<String>,
    pub reconnect_reason: Option<String>,
    pub message: String,
}

impl Default for RuntimeHealthState {
    fn default() -> Self {
        Self {
            status: "idle".to_string(),
            engine: EngineKind::Unknown,
            route_path: "idle".to_string(),
            metrics_source: "none".to_string(),
            metrics_available: false,
            last_error: None,
            last_successful_handshake: None,
            reconnect_reason: None,
            message: "Runtime health is idle.".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubscriptionOperationState {
    pub status: String,
    pub active: bool,
    pub last_action: String,
    pub last_subscription_id: Option<String>,
    pub last_error: Option<String>,
    pub timeout_ms: u32,
    pub update_interval_minutes: u32,
    pub deterministic: bool,
    pub message: String,
}

impl Default for SubscriptionOperationState {
    fn default() -> Self {
        Self {
            status: "idle".to_string(),
            active: false,
            last_action: "none".to_string(),
            last_subscription_id: None,
            last_error: None,
            timeout_ms: DEFAULT_REQUEST_TIMEOUT_MS,
            update_interval_minutes: 24 * 60,
            deterministic: true,
            message: "Subscription operations are idle.".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogSnapshotState {
    pub entries: Vec<EngineLogEntry>,
    pub categories: Vec<String>,
    pub exported_at: String,
}

impl Default for LogSnapshotState {
    fn default() -> Self {
        Self {
            entries: Vec::new(),
            categories: Vec::new(),
            exported_at: "not collected".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SupportBundleState {
    pub status: String,
    pub path: Option<String>,
    pub created_at: Option<String>,
    pub files: Vec<String>,
    pub redacted: bool,
    pub message: String,
}

impl Default for SupportBundleState {
    fn default() -> Self {
        Self {
            status: "idle".to_string(),
            path: None,
            created_at: None,
            files: Vec::new(),
            redacted: true,
            message: "Support bundle has not been created.".to_string(),
        }
    }
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
    pub service_readiness: ServiceReadinessState,
    pub service_self_check: ServiceSelfCheckState,
    pub recovery_policy: RecoveryPolicyState,
    pub audit_events: Vec<ServiceAuditEvent>,
    pub traffic_stats: TrafficStatsState,
    pub runtime_health: RuntimeHealthState,
    pub subscription_operations: SubscriptionOperationState,
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
            service_readiness: ServiceReadinessState::default(),
            service_self_check: ServiceSelfCheckState::default(),
            recovery_policy: RecoveryPolicyState::default(),
            audit_events: Vec::new(),
            traffic_stats: TrafficStatsState::default(),
            runtime_health: RuntimeHealthState::default(),
            subscription_operations: SubscriptionOperationState::default(),
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

    #[test]
    fn round_trips_telemetry_events() {
        let stats = TrafficStatsState {
            status: "running".to_string(),
            started_at: Some("Engine event: 1".to_string()),
            updated_at: "Engine event: 2".to_string(),
            download_bytes: 1024,
            upload_bytes: 512,
            download_bps: 64,
            upload_bps: 32,
            session_seconds: 7,
            source: "service-session".to_string(),
            metrics_source: "service-session".to_string(),
            fallback: true,
            route_path: "proxy path".to_string(),
            last_error: None,
            last_successful_handshake: Some("Engine event: 1".to_string()),
            message: "ok".to_string(),
        };

        let event = ServiceEvent::TrafficStats { state: stats };
        let payload = encode_event(&event).expect("serialize event");
        assert!(payload.contains("traffic-stats"));

        let command = ClientCommand::GetLogs {
            category: Some("manager".to_string()),
        };
        let payload = serde_json::to_string(&command).expect("serialize command");
        let decoded: ClientCommand = decode_command(&payload).expect("decode command");
        assert!(matches!(
            decoded,
            ClientCommand::GetLogs {
                category: Some(category)
            } if category == "manager"
        ));
    }
}
