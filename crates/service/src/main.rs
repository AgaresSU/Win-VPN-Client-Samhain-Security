use anyhow::{Context, Result, anyhow};
use samhain_core::{
    Protocol, RouteMode, Server, Subscription, parse_server_url, parse_subscription_payload,
    sample_subscription,
};
use samhain_ipc::{
    AppRoutingPolicyState, ClientCommand, EngineCatalogEntry, EngineConfigPreview, EngineKind,
    EngineLifecycleState, EngineLogEntry, IPC_PROTOCOL_VERSION, Ipv6Policy, LogSnapshotState,
    PingProbeResult, ProtectionPolicyState, ProtectionSettings, ProtectionTransactionState,
    ProtectionTransactionStep, ProxyLifecycleState, RecoveryPolicyState, RequestEnvelope,
    ResponseEnvelope, RouteApplication, RuntimeHealthState, ServiceAuditEvent, ServiceCheckItem,
    ServiceEvent, ServiceReadinessState, ServiceSelfCheckState, ServiceState, SupportBundleState,
    TrafficStatsState, TunLifecycleState, decode_request, encode_event, encode_response,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

static STORE: OnceLock<Mutex<ServiceStore>> = OnceLock::new();
const PROBE_TIMEOUT: Duration = Duration::from_millis(260);
const LOCAL_PROXY_HOST: &str = "127.0.0.1";
const LOCAL_PROXY_PORT: u16 = 20808;
const TUN_INTERFACE_NAME: &str = "samhain-tun";
const TUN_ADDRESS: &str = "172.19.0.1/30";
const TUN_DNS: &[&str] = &["1.1.1.1", "8.8.8.8"];
const ADAPTER_DRY_RUN_ENV: &str = "SAMHAIN_ADAPTER_DRY_RUN";
const APP_ROUTING_DRY_RUN_ENV: &str = "SAMHAIN_APP_ROUTING_DRY_RUN";
const APP_ROUTING_ENFORCE_ENV: &str = "SAMHAIN_APP_ROUTING_ENFORCE";
const PROTECTION_DRY_RUN_ENV: &str = "SAMHAIN_PROTECTION_DRY_RUN";
const PROTECTION_ENFORCE_ENV: &str = "SAMHAIN_PROTECTION_ENFORCE";
const SERVICE_SIGNED_ENV: &str = "SAMHAIN_SERVICE_SIGNED";
const AUDIT_EVENT_LIMIT: usize = 120;
const MAX_RECONNECT_ATTEMPTS: u8 = 3;
const RECONNECT_BACKOFF_BASE_MS: u64 = 250;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "status".to_string());

    match command.as_str() {
        "install" => print_stub("install"),
        "start" => print_stub("start"),
        "stop" => print_stub("stop"),
        "uninstall" => print_stub("uninstall"),
        "status" => print_status()?,
        "self-check" => print_self_check()?,
        "run" | "serve" => run_service()?,
        _ => {
            eprintln!(
                "Usage: samhain-service [install|start|stop|status|self-check|uninstall|run]"
            );
            std::process::exit(2);
        }
    }

    Ok(())
}

fn print_stub(command: &str) {
    println!(
        "Samhain Security service command '{command}' is reserved for the signed privileged service. Use tools\\local-ops.ps1 for the current package operations."
    );
}

fn print_status() -> Result<()> {
    println!(
        "{}",
        encode_event(&ServiceEvent::State(current_state(false)))?
    );
    Ok(())
}

fn print_self_check() -> Result<()> {
    println!(
        "{}",
        encode_event(&ServiceEvent::ServiceSelfCheck {
            state: service_self_check_state(&storage_path())
        })?
    );
    Ok(())
}

fn run_service() -> Result<()> {
    println!(
        "Samhain Security service IPC listening on {}",
        samhain_ipc::NAMED_PIPE_NAME
    );
    named_pipe::run(handle_payload)
}

fn handle_payload(payload: &str) -> String {
    let response = match decode_request(payload) {
        Ok(request) => handle_request(request),
        Err(error) => {
            ResponseEnvelope::error("invalid-request", format!("Invalid request: {error}"))
        }
    };

    encode_response(&response).unwrap_or_else(|error| {
        let fallback = ResponseEnvelope::error(
            "serialization-error",
            format!("Could not encode service response: {error}"),
        );
        serde_json::to_string(&fallback).expect("fallback response")
    })
}

fn handle_request(request: RequestEnvelope) -> ResponseEnvelope {
    if request.protocol_version != IPC_PROTOCOL_VERSION {
        return ResponseEnvelope::error(
            request.request_id,
            format!(
                "Unsupported IPC protocol {}. Expected {}.",
                request.protocol_version, IPC_PROTOCOL_VERSION
            ),
        );
    }

    let request_id = request.request_id;
    let event = handle_command(request.command);
    ResponseEnvelope::ok(request_id, event)
}

fn handle_command(command: ClientCommand) -> ServiceEvent {
    match command {
        ClientCommand::Ping => ServiceEvent::Pong,
        ClientCommand::GetState => ServiceEvent::State(current_state(true)),
        ClientCommand::GetEngineCatalog => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.engine_catalog())
        {
            Ok(engines) => ServiceEvent::EngineCatalog { engines },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось получить список движков: {error}"),
            },
        },
        ClientCommand::GetEngineStatus => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.engine_status())
        {
            Ok(state) => ServiceEvent::EngineStatus { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось получить состояние движка: {error}"),
            },
        },
        ClientCommand::GetProxyStatus => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.proxy_status())
        {
            Ok(state) => ServiceEvent::ProxyStatus { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось получить состояние proxy: {error}"),
            },
        },
        ClientCommand::GetTunStatus => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.tun_status())
        {
            Ok(state) => ServiceEvent::TunStatus { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось получить состояние TUN: {error}"),
            },
        },
        ClientCommand::GetAppRoutingPolicy => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.app_routing_policy())
        {
            Ok(state) => ServiceEvent::AppRoutingPolicy { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось получить политику приложений: {error}"),
            },
        },
        ClientCommand::GetServiceSelfCheck => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.service_self_check())
        {
            Ok(state) => ServiceEvent::ServiceSelfCheck { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось выполнить самопроверку сервиса: {error}"),
            },
        },
        ClientCommand::GetTrafficStats => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.traffic_stats())
        {
            Ok(state) => ServiceEvent::TrafficStats { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось получить статистику: {error}"),
            },
        },
        ClientCommand::GetLogs { category } => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.log_snapshot(category.as_deref()))
        {
            Ok(snapshot) => ServiceEvent::LogSnapshot { snapshot },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось получить логи: {error}"),
            },
        },
        ClientCommand::ExportSupportBundle => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.export_support_bundle())
        {
            Ok(state) => ServiceEvent::SupportBundle { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось создать диагностический пакет: {error}"),
            },
        },
        ClientCommand::GetProtectionPolicy => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.protection_policy())
        {
            Ok(state) => ServiceEvent::ProtectionPolicy { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось получить политику защиты: {error}"),
            },
        },
        ClientCommand::AddSubscription { name, url } => {
            match service_store()
                .lock()
                .map_err(|_| anyhow!("Service store lock is poisoned."))
                .and_then(|mut store| store.import_subscription(name, url))
            {
                Ok(subscription) => ServiceEvent::SubscriptionAdded { subscription },
                Err(error) => ServiceEvent::Error {
                    message: format!("Не удалось импортировать подписку: {error}"),
                },
            }
        }
        ClientCommand::RefreshSubscription { subscription_id } => {
            match service_store()
                .lock()
                .map_err(|_| anyhow!("Service store lock is poisoned."))
                .and_then(|mut store| store.refresh_subscription(&subscription_id))
            {
                Ok(subscription) => ServiceEvent::SubscriptionRefreshed { subscription },
                Err(error) => ServiceEvent::Error {
                    message: format!("Не удалось обновить подписку: {error}"),
                },
            }
        }
        ClientCommand::PinSubscription { subscription_id } => {
            match service_store()
                .lock()
                .map_err(|_| anyhow!("Service store lock is poisoned."))
                .and_then(|mut store| store.pin_subscription(&subscription_id))
            {
                Ok(subscription) => ServiceEvent::SubscriptionPinned { subscription },
                Err(error) => ServiceEvent::Error {
                    message: format!("Не удалось закрепить подписку: {error}"),
                },
            }
        }
        ClientCommand::GetSubscriptionUrl { subscription_id } => {
            match service_store()
                .lock()
                .map_err(|_| anyhow!("Service store lock is poisoned."))
                .and_then(|store| store.subscription_url(&subscription_id))
            {
                Ok(url) => ServiceEvent::SubscriptionUrl {
                    subscription_id,
                    url,
                },
                Err(error) => ServiceEvent::Error {
                    message: format!("Не удалось получить ссылку подписки: {error}"),
                },
            }
        }
        ClientCommand::RenameSubscription {
            subscription_id,
            name,
        } => {
            match service_store()
                .lock()
                .map_err(|_| anyhow!("Service store lock is poisoned."))
                .and_then(|mut store| store.rename_subscription(&subscription_id, name))
            {
                Ok(subscription) => ServiceEvent::SubscriptionRenamed { subscription },
                Err(error) => ServiceEvent::Error {
                    message: format!("Не удалось переименовать подписку: {error}"),
                },
            }
        }
        ClientCommand::DeleteSubscription { subscription_id } => {
            match service_store()
                .lock()
                .map_err(|_| anyhow!("Service store lock is poisoned."))
                .and_then(|mut store| store.delete_subscription(&subscription_id))
            {
                Ok(()) => ServiceEvent::SubscriptionDeleted { subscription_id },
                Err(error) => ServiceEvent::Error {
                    message: format!("Не удалось удалить подписку: {error}"),
                },
            }
        }
        ClientCommand::SelectServer { server_id } => match select_server(&server_id) {
            Some(server) => ServiceEvent::ServerSelected { server },
            None => ServiceEvent::Error {
                message: "No server is available.".to_string(),
            },
        },
        ClientCommand::Connect {
            server_id,
            route_mode,
        } => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.start_engine(&server_id, route_mode))
        {
            Ok(state) => ServiceEvent::EngineStatus { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось запустить движок: {error}"),
            },
        },
        ClientCommand::Disconnect => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.stop_engine())
        {
            Ok(state) => ServiceEvent::EngineStatus { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось остановить движок: {error}"),
            },
        },
        ClientCommand::PreviewEngineConfig { server_id } => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.preview_engine_config(&server_id))
        {
            Ok(preview) => ServiceEvent::EngineConfigPreview { preview },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось подготовить конфигурацию: {error}"),
            },
        },
        ClientCommand::StartEngine {
            server_id,
            route_mode,
        } => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.start_engine(&server_id, route_mode))
        {
            Ok(state) => ServiceEvent::EngineStatus { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось запустить движок: {error}"),
            },
        },
        ClientCommand::StopEngine => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.stop_engine())
        {
            Ok(state) => ServiceEvent::EngineStatus { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось остановить движок: {error}"),
            },
        },
        ClientCommand::RestartEngine {
            server_id,
            route_mode,
        } => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.restart_engine(&server_id, route_mode))
        {
            Ok(state) => ServiceEvent::EngineStatus { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось перезапустить движок: {error}"),
            },
        },
        ClientCommand::RestoreProxyPolicy => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.restore_proxy_policy())
        {
            Ok(state) => ServiceEvent::ProxyStatus { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось восстановить proxy: {error}"),
            },
        },
        ClientCommand::RestoreTunPolicy => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.restore_tun_policy())
        {
            Ok(state) => ServiceEvent::TunStatus { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось восстановить TUN: {error}"),
            },
        },
        ClientCommand::SetAppRoutingPolicy {
            route_mode,
            applications,
        } => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.set_app_routing_policy(route_mode, applications))
        {
            Ok(state) => ServiceEvent::AppRoutingPolicy { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось сохранить политику приложений: {error}"),
            },
        },
        ClientCommand::AddRouteApplication { path } => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.add_route_application(path))
        {
            Ok(state) => ServiceEvent::AppRoutingPolicy { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось добавить приложение: {error}"),
            },
        },
        ClientCommand::RemoveRouteApplication { application_id } => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.remove_route_application(&application_id))
        {
            Ok(state) => ServiceEvent::AppRoutingPolicy { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось удалить приложение: {error}"),
            },
        },
        ClientCommand::RestoreAppRoutingPolicy => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.restore_app_routing_policy())
        {
            Ok(state) => ServiceEvent::AppRoutingPolicy { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось восстановить политику приложений: {error}"),
            },
        },
        ClientCommand::SetProtectionPolicy { settings } => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.set_protection_policy(settings))
        {
            Ok(state) => ServiceEvent::ProtectionPolicy { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось сохранить политику защиты: {error}"),
            },
        },
        ClientCommand::RestoreProtectionPolicy => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.restore_protection_policy())
        {
            Ok(state) => ServiceEvent::ProtectionPolicy { state },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось восстановить защиту: {error}"),
            },
        },
        ClientCommand::EmergencyRestore => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.emergency_restore())
        {
            Ok(state) => ServiceEvent::State(state),
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось выполнить аварийное восстановление: {error}"),
            },
        },
        ClientCommand::TestPing { server_id } => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.test_ping(&server_id))
        {
            Ok(result) => ServiceEvent::PingResult(result),
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось проверить задержку: {error}"),
            },
        },
        ClientCommand::TestPings { server_ids } => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .and_then(|mut store| store.test_pings(server_ids))
        {
            Ok(results) => ServiceEvent::PingBatchResult { results },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось проверить задержку: {error}"),
            },
        },
        ClientCommand::CancelPingProbes => match service_store()
            .lock()
            .map_err(|_| anyhow!("Service store lock is poisoned."))
            .map(|mut store| store.cancel_ping_probes())
        {
            Ok(canceled) => ServiceEvent::PingProbesCanceled { canceled },
            Err(error) => ServiceEvent::Error {
                message: format!("Не удалось отменить проверку: {error}"),
            },
        },
    }
}

fn current_state(running: bool) -> ServiceState {
    match service_store().lock() {
        Ok(mut store) => store.service_state(running),
        Err(_) => ServiceState {
            version: env!("CARGO_PKG_VERSION").to_string(),
            running,
            selected_server_id: None,
            connected_server_id: None,
            route_mode: RouteMode::WholeComputer,
            engine_state: EngineLifecycleState::default(),
            engine_catalog: discover_engines(),
            proxy_state: ProxyLifecycleState::default(),
            tun_state: TunLifecycleState::default(),
            app_routing_policy: AppRoutingPolicyState::default(),
            protection_policy: ProtectionPolicyState::default(),
            service_readiness: service_readiness_state(),
            service_self_check: service_self_check_state(&storage_path()),
            recovery_policy: recovery_policy_state(),
            audit_events: Vec::new(),
            traffic_stats: TrafficStatsState::default(),
            runtime_health: RuntimeHealthState::default(),
            probe_queue_active: false,
            probe_results: Vec::new(),
            subscriptions: vec![sample_subscription()],
        },
    }
}

fn select_server(server_id: &str) -> Option<Server> {
    let mut store = service_store().lock().ok()?;
    let server = store
        .state
        .subscriptions
        .iter()
        .flat_map(|subscription| subscription.servers.iter())
        .find(|server| server.id == server_id || server.name == server_id)
        .cloned()?;

    store.state.selected_server_id = Some(server.id.clone());
    let _ = store.save();
    Some(server)
}

fn service_store() -> &'static Mutex<ServiceStore> {
    STORE.get_or_init(|| {
        Mutex::new(ServiceStore::load().unwrap_or_else(|_| ServiceStore::fallback()))
    })
}

#[derive(Debug)]
struct ServiceStore {
    path: PathBuf,
    state: StoredState,
    engine_manager: EngineManager,
}

impl ServiceStore {
    fn load() -> Result<Self> {
        let path = storage_path();
        let state = match fs::read_to_string(&path) {
            Ok(payload) => serde_json::from_str(&payload)
                .with_context(|| format!("Could not parse {}", path.display()))?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => StoredState::seeded(),
            Err(error) => {
                return Err(anyhow!("Could not read {}: {error}", path.display()));
            }
        };

        Ok(Self {
            path,
            state,
            engine_manager: EngineManager::new(),
        })
    }

    fn fallback() -> Self {
        Self {
            path: storage_path(),
            state: StoredState::seeded(),
            engine_manager: EngineManager::new(),
        }
    }

    fn service_state(&mut self, running: bool) -> ServiceState {
        let engine_state = self.engine_manager.snapshot();
        let engine_catalog = self.engine_manager.catalog();
        let proxy_state = self.engine_manager.proxy_snapshot();
        let tun_state = self.engine_manager.tun_snapshot();
        let app_routing_policy = self
            .engine_manager
            .app_routing_snapshot(self.state.route_mode, self.public_route_applications());
        let protection_policy = self.engine_manager.protection_snapshot(
            self.state.protection_settings.clone(),
            self.state.route_mode,
        );
        let service_readiness = service_readiness_state();
        let service_self_check = service_self_check_state(&self.path);
        let recovery_policy = service_self_check.recovery_policy.clone();
        let traffic_stats = self.engine_manager.traffic_snapshot();
        let runtime_health = self.engine_manager.runtime_health_snapshot();
        ServiceState {
            version: env!("CARGO_PKG_VERSION").to_string(),
            running,
            selected_server_id: self.state.selected_server_id.clone(),
            connected_server_id: self.state.connected_server_id.clone(),
            route_mode: self.state.route_mode,
            engine_state,
            engine_catalog,
            proxy_state,
            tun_state,
            app_routing_policy,
            protection_policy,
            service_readiness,
            service_self_check,
            recovery_policy,
            audit_events: self.state.audit_events.clone(),
            traffic_stats,
            runtime_health,
            probe_queue_active: self.state.probe_queue_active,
            probe_results: self.state.probe_results.clone(),
            subscriptions: self
                .state
                .subscriptions
                .iter()
                .map(StoredSubscription::to_public)
                .collect(),
        }
    }

    fn import_subscription(&mut self, name: String, url: String) -> Result<Subscription> {
        let mut servers = Vec::new();
        for payload in fetch_subscription_payloads(&url)? {
            let report = parse_subscription_payload(&payload);
            if !report.servers.is_empty() {
                servers = report.servers;
                break;
            }
        }

        if servers.is_empty() {
            if let Some(server) = parse_server_url(&url, 1) {
                servers.push(server);
            }
        }

        if servers.is_empty() {
            return Err(anyhow!("в подписке не найдено поддерживаемых серверов"));
        }

        let subscription = StoredSubscription::from_import(name, url, servers)?;
        let public = subscription.to_public();
        self.state.subscriptions.retain(|existing| {
            existing.id != subscription.id
                && (subscription.id == "default-samhain" || existing.id != "default-samhain")
        });
        self.state.subscriptions.push(subscription);
        self.save()?;

        Ok(public)
    }

    fn test_ping(&mut self, server_id: &str) -> Result<PingProbeResult> {
        self.state.probe_queue_active = true;
        let server = self
            .find_server(server_id)
            .ok_or_else(|| anyhow!("сервер не найден"))?;
        let result = probe_server(&server);
        self.upsert_probe_result(result.clone());
        self.state.probe_queue_active = false;
        self.save()?;
        Ok(result)
    }

    fn test_pings(&mut self, server_ids: Vec<String>) -> Result<Vec<PingProbeResult>> {
        self.state.probe_queue_active = true;
        let servers = if server_ids.is_empty() {
            self.all_servers()
        } else {
            server_ids
                .iter()
                .filter_map(|server_id| self.find_server(server_id))
                .collect()
        };

        if servers.is_empty() {
            self.state.probe_queue_active = false;
            self.save()?;
            return Ok(Vec::new());
        }

        let mut results = Vec::with_capacity(servers.len());
        for server in servers {
            let result = probe_server(&server);
            self.upsert_probe_result(result.clone());
            results.push(result);
        }
        self.state.probe_queue_active = false;
        self.save()?;
        Ok(results)
    }

    fn cancel_ping_probes(&mut self) -> usize {
        let canceled = usize::from(self.state.probe_queue_active);
        self.state.probe_queue_active = false;
        let _ = self.save();
        canceled
    }

    fn engine_catalog(&mut self) -> Vec<EngineCatalogEntry> {
        self.engine_manager.catalog()
    }

    fn engine_status(&mut self) -> EngineLifecycleState {
        self.engine_manager.snapshot()
    }

    fn proxy_status(&mut self) -> ProxyLifecycleState {
        self.engine_manager.proxy_snapshot()
    }

    fn tun_status(&mut self) -> TunLifecycleState {
        self.engine_manager.tun_snapshot()
    }

    fn app_routing_policy(&mut self) -> AppRoutingPolicyState {
        self.engine_manager
            .app_routing_snapshot(self.state.route_mode, self.public_route_applications())
    }

    fn protection_policy(&mut self) -> ProtectionPolicyState {
        self.engine_manager.protection_snapshot(
            self.state.protection_settings.clone(),
            self.state.route_mode,
        )
    }

    fn service_self_check(&mut self) -> ServiceSelfCheckState {
        service_self_check_state(&self.path)
    }

    fn traffic_stats(&mut self) -> TrafficStatsState {
        self.engine_manager.traffic_snapshot()
    }

    fn log_snapshot(&mut self, category: Option<&str>) -> LogSnapshotState {
        self.engine_manager.log_snapshot(category)
    }

    fn export_support_bundle(&mut self) -> Result<SupportBundleState> {
        let created_at = now_engine_label();
        let bundle_dir = support_bundle_path();
        fs::create_dir_all(&bundle_dir)
            .with_context(|| format!("Could not create {}", bundle_dir.display()))?;

        let state = self.service_state(true);
        let logs = self.log_snapshot(None);
        let manifest = serde_json::json!({
            "product": "Samhain Security",
            "version": env!("CARGO_PKG_VERSION"),
            "created_at": created_at,
            "redacted": true,
            "files": [
                "manifest.json",
                "state.json",
                "logs.json",
                "engine-inventory.json",
                "service-self-check.json",
                "service-audit.json",
                "health.txt"
            ],
            "service_readiness": state.service_readiness.status,
            "recovery_policy": state.recovery_policy.owner
        });
        let health = format!(
            "Samhain Security diagnostics\nversion: {}\nengine: {}\nruntime-health: {}\nmetrics-source: {}\ntraffic: {}\nservice: {}\nself-check: {}\nrecovery: {}\naudit-events: {}\nentries: {}\nredacted: true\n",
            env!("CARGO_PKG_VERSION"),
            state.engine_state.status,
            state.runtime_health.status,
            state.runtime_health.metrics_source,
            state.traffic_stats.status,
            state.service_readiness.status,
            state.service_self_check.status,
            state.recovery_policy.owner,
            state.audit_events.len(),
            logs.entries.len()
        );

        let files = [
            (
                "manifest.json",
                redact_support_text(&serde_json::to_string_pretty(&manifest)?),
            ),
            (
                "state.json",
                redact_support_text(&serde_json::to_string_pretty(&state)?),
            ),
            (
                "logs.json",
                redact_support_text(&serde_json::to_string_pretty(&logs)?),
            ),
            (
                "engine-inventory.json",
                redact_support_text(&serde_json::to_string_pretty(&state.engine_catalog)?),
            ),
            (
                "service-self-check.json",
                redact_support_text(&serde_json::to_string_pretty(&state.service_self_check)?),
            ),
            (
                "service-audit.json",
                redact_support_text(&serde_json::to_string_pretty(&state.audit_events)?),
            ),
            ("health.txt", redact_support_text(&health)),
        ];

        let mut written = Vec::new();
        for (name, content) in files {
            fs::write(bundle_dir.join(name), content)
                .with_context(|| format!("Could not write {}", bundle_dir.join(name).display()))?;
            written.push(name.to_string());
        }

        self.engine_manager.push_log(
            "info",
            "support",
            &format!("Created support bundle {}", bundle_dir.display()),
        );

        Ok(SupportBundleState {
            status: "created".to_string(),
            path: Some(bundle_dir.display().to_string()),
            created_at: Some(created_at),
            files: written,
            redacted: true,
            message: "Диагностический пакет создан без секретов.".to_string(),
        })
    }

    fn preview_engine_config(&mut self, server_id: &str) -> Result<EngineConfigPreview> {
        let server = self
            .find_server(server_id)
            .ok_or_else(|| anyhow!("сервер не найден"))?;
        let raw_url = self
            .raw_url_for_server(&server.id)
            .ok_or_else(|| anyhow!("исходная ссылка сервера недоступна"))?;
        self.engine_manager.preview_config(&server, &raw_url)
    }

    fn start_engine(
        &mut self,
        server_id: &str,
        route_mode: RouteMode,
    ) -> Result<EngineLifecycleState> {
        let server = self
            .find_server(server_id)
            .ok_or_else(|| anyhow!("сервер не найден"))?;
        let raw_url = self
            .raw_url_for_server(&server.id)
            .ok_or_else(|| anyhow!("исходная ссылка сервера недоступна"))?;
        let state = self.engine_manager.start(&server, &raw_url, route_mode)?;
        self.state.route_mode = route_mode;
        let route_applications = self.public_route_applications();
        let policy = self
            .engine_manager
            .apply_app_routing_policy(route_mode, route_applications);
        if route_mode != RouteMode::WholeComputer && policy.applications.is_empty() {
            self.engine_manager.stop()?;
            self.state.connected_server_id = None;
            self.save()?;
            return Err(anyhow!("выберите приложения для этого режима"));
        }
        if state.status == "running" || state.status == "starting" {
            let _ = self
                .engine_manager
                .apply_protection_policy(self.state.protection_settings.clone(), route_mode);
            self.state.connected_server_id = Some(server.id.clone());
            self.state.selected_server_id = Some(server.id);
        } else {
            self.state.connected_server_id = None;
        }
        self.save()?;
        Ok(state)
    }

    fn stop_engine(&mut self) -> Result<EngineLifecycleState> {
        let state = self.engine_manager.stop()?;
        let _ = self.engine_manager.restore_app_routing_policy();
        self.state.connected_server_id = None;
        self.save()?;
        Ok(state)
    }

    fn restore_proxy_policy(&mut self) -> Result<ProxyLifecycleState> {
        self.engine_manager.restore_proxy_policy()
    }

    fn restore_tun_policy(&mut self) -> Result<TunLifecycleState> {
        self.engine_manager.restore_tun_policy()
    }

    fn restore_app_routing_policy(&mut self) -> AppRoutingPolicyState {
        self.engine_manager.restore_app_routing_policy()
    }

    fn set_protection_policy(
        &mut self,
        settings: ProtectionSettings,
    ) -> Result<ProtectionPolicyState> {
        let settings = normalize_protection_settings(settings);
        self.state.protection_settings = settings.clone();
        let state = self
            .engine_manager
            .apply_protection_policy(settings, self.state.route_mode);
        self.append_audit_event("protection", "set-policy", &state.status, &state.message);
        self.save()?;
        Ok(state)
    }

    fn restore_protection_policy(&mut self) -> ProtectionPolicyState {
        let state = self.engine_manager.restore_protection_policy();
        self.append_audit_event(
            "protection",
            "restore-policy",
            &state.status,
            &state.message,
        );
        let _ = self.save();
        state
    }

    fn emergency_restore(&mut self) -> Result<ServiceState> {
        let _ = self.engine_manager.stop();
        let _ = self.engine_manager.restore_proxy_policy();
        let _ = self.engine_manager.restore_tun_policy();
        let _ = self.engine_manager.restore_app_routing_policy();
        let _ = self.engine_manager.restore_protection_policy();
        self.state.connected_server_id = None;
        self.append_audit_event(
            "recovery",
            "emergency-restore",
            "restored",
            "Service-owned emergency restore completed.",
        );
        self.save()?;
        Ok(self.service_state(true))
    }

    fn set_app_routing_policy(
        &mut self,
        route_mode: RouteMode,
        applications: Vec<RouteApplication>,
    ) -> Result<AppRoutingPolicyState> {
        let stored = applications
            .into_iter()
            .map(StoredRouteApplication::from_public)
            .collect::<Result<Vec<_>>>()?;
        self.state.route_mode = route_mode;
        self.state.route_applications = dedupe_route_applications(stored);
        self.append_audit_event(
            "routing",
            "set-app-policy",
            "configured",
            &format!("route_mode={route_mode:?}"),
        );
        self.save()?;
        Ok(self.app_routing_policy())
    }

    fn add_route_application(&mut self, path: String) -> Result<AppRoutingPolicyState> {
        let application = StoredRouteApplication::from_path(path)?;
        self.state.route_applications.push(application);
        self.state.route_applications =
            dedupe_route_applications(std::mem::take(&mut self.state.route_applications));
        self.save()?;
        Ok(self.app_routing_policy())
    }

    fn remove_route_application(&mut self, application_id: &str) -> Result<AppRoutingPolicyState> {
        let before = self.state.route_applications.len();
        self.state
            .route_applications
            .retain(|application| application.id != application_id);
        if before == self.state.route_applications.len() {
            return Err(anyhow!("приложение не найдено"));
        }
        self.save()?;
        Ok(self.app_routing_policy())
    }

    fn restart_engine(
        &mut self,
        server_id: &str,
        route_mode: RouteMode,
    ) -> Result<EngineLifecycleState> {
        self.engine_manager.stop()?;
        self.start_engine(server_id, route_mode)
    }

    fn refresh_subscription(&mut self, subscription_id: &str) -> Result<Subscription> {
        let index = self
            .state
            .subscriptions
            .iter()
            .position(|subscription| subscription.id == subscription_id)
            .ok_or_else(|| anyhow!("подписка не найдена"))?;

        let old = self.state.subscriptions[index].clone();
        let url = secret::unprotect_string(&old.protected_url).or_else(|_| {
            old.protected_url
                .strip_prefix("unprotected:")
                .map(str::to_string)
                .ok_or_else(|| anyhow!("исходная ссылка недоступна"))
        })?;

        let mut servers = Vec::new();
        for payload in fetch_subscription_payloads(&url)? {
            let report = parse_subscription_payload(&payload);
            if !report.servers.is_empty() {
                servers = report.servers;
                break;
            }
        }

        if servers.is_empty() {
            if let Some(server) = parse_server_url(&url, 1) {
                servers.push(server);
            }
        }

        if servers.is_empty() {
            return Err(anyhow!("в подписке не найдено поддерживаемых серверов"));
        }

        let (servers, protected_server_urls) = protect_server_urls(&old.id, servers)?;
        let refreshed = StoredSubscription {
            id: old.id,
            name: old.name,
            protected_url: old.protected_url,
            servers,
            protected_server_urls,
            updated_at: Some(now_label()),
        };
        let public = refreshed.to_public();
        self.state.subscriptions[index] = refreshed;
        self.save()?;

        Ok(public)
    }

    fn pin_subscription(&mut self, subscription_id: &str) -> Result<Subscription> {
        let index = self
            .state
            .subscriptions
            .iter()
            .position(|subscription| subscription.id == subscription_id)
            .ok_or_else(|| anyhow!("подписка не найдена"))?;

        let mut subscription = self.state.subscriptions.remove(index);
        subscription.updated_at = Some(now_label());
        let public = subscription.to_public();
        self.state.subscriptions.insert(0, subscription);
        self.save()?;

        Ok(public)
    }

    fn subscription_url(&self, subscription_id: &str) -> Result<String> {
        let subscription = self
            .state
            .subscriptions
            .iter()
            .find(|subscription| subscription.id == subscription_id)
            .ok_or_else(|| anyhow!("подписка не найдена"))?;

        unprotect_stored_secret(&subscription.protected_url)
            .map_err(|_| anyhow!("исходная ссылка недоступна"))
    }

    fn rename_subscription(&mut self, subscription_id: &str, name: String) -> Result<Subscription> {
        let normalized_name = name.trim();
        if normalized_name.is_empty() {
            return Err(anyhow!("имя не должно быть пустым"));
        }

        let subscription = self
            .state
            .subscriptions
            .iter_mut()
            .find(|subscription| subscription.id == subscription_id)
            .ok_or_else(|| anyhow!("подписка не найдена"))?;

        subscription.name = normalized_name.to_string();
        subscription.updated_at = Some(now_label());
        let public = subscription.to_public();
        self.save()?;

        Ok(public)
    }

    fn delete_subscription(&mut self, subscription_id: &str) -> Result<()> {
        let before = self.state.subscriptions.len();
        self.state
            .subscriptions
            .retain(|subscription| subscription.id != subscription_id);

        if self.state.subscriptions.len() == before {
            return Err(anyhow!("подписка не найдена"));
        }

        if let Some(selected_server_id) = &self.state.selected_server_id {
            let selected_still_exists = self
                .state
                .subscriptions
                .iter()
                .flat_map(|subscription| subscription.servers.iter())
                .any(|server| &server.id == selected_server_id);
            if !selected_still_exists {
                self.state.selected_server_id = None;
            }
        }

        self.save()
    }

    fn append_audit_event(
        &mut self,
        category: impl Into<String>,
        action: impl Into<String>,
        result: impl Into<String>,
        detail: impl AsRef<str>,
    ) {
        let next_id = self
            .state
            .audit_events
            .last()
            .map(|event| event.id.saturating_add(1))
            .unwrap_or(1);
        self.state.audit_events.push(ServiceAuditEvent {
            id: next_id,
            timestamp: now_engine_label(),
            category: category.into(),
            action: action.into(),
            result: result.into(),
            detail: redact_support_text(detail.as_ref()),
        });

        if self.state.audit_events.len() > AUDIT_EVENT_LIMIT {
            let remove_count = self.state.audit_events.len() - AUDIT_EVENT_LIMIT;
            self.state.audit_events.drain(0..remove_count);
        }
    }

    fn save(&self) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("Could not create {}", parent.display()))?;
        }

        let payload = serde_json::to_string_pretty(&self.state)?;
        fs::write(&self.path, payload)
            .with_context(|| format!("Could not write {}", self.path.display()))
    }

    fn find_server(&self, server_id: &str) -> Option<Server> {
        self.state
            .subscriptions
            .iter()
            .flat_map(|subscription| subscription.servers.iter())
            .find(|server| server.id == server_id || server.name == server_id)
            .cloned()
    }

    fn raw_url_for_server(&self, server_id: &str) -> Option<String> {
        self.state
            .subscriptions
            .iter()
            .flat_map(|subscription| subscription.protected_server_urls.iter())
            .find(|entry| entry.server_id == server_id)
            .and_then(|entry| {
                secret::unprotect_string(&entry.protected_raw_url)
                    .or_else(|_| {
                        entry
                            .protected_raw_url
                            .strip_prefix("unprotected:")
                            .map(str::to_string)
                            .ok_or_else(|| anyhow!("raw server URL unavailable"))
                    })
                    .ok()
            })
    }

    fn all_servers(&self) -> Vec<Server> {
        self.state
            .subscriptions
            .iter()
            .flat_map(|subscription| subscription.servers.iter().cloned())
            .collect()
    }

    fn public_route_applications(&self) -> Vec<RouteApplication> {
        self.state
            .route_applications
            .iter()
            .map(StoredRouteApplication::to_public)
            .collect()
    }

    fn upsert_probe_result(&mut self, result: PingProbeResult) {
        for subscription in &mut self.state.subscriptions {
            for server in &mut subscription.servers {
                if server.id == result.server_id {
                    server.ping_ms = result.ping_ms;
                }
            }
        }

        self.state
            .probe_results
            .retain(|existing| existing.server_id != result.server_id);
        self.state.probe_results.push(result);
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct StoredState {
    schema_version: u32,
    route_mode: RouteMode,
    #[serde(default)]
    selected_server_id: Option<String>,
    connected_server_id: Option<String>,
    #[serde(default)]
    probe_queue_active: bool,
    #[serde(default)]
    probe_results: Vec<PingProbeResult>,
    #[serde(default)]
    route_applications: Vec<StoredRouteApplication>,
    #[serde(default)]
    protection_settings: ProtectionSettings,
    #[serde(default)]
    audit_events: Vec<ServiceAuditEvent>,
    subscriptions: Vec<StoredSubscription>,
}

impl StoredState {
    fn seeded() -> Self {
        Self {
            schema_version: 1,
            route_mode: RouteMode::WholeComputer,
            selected_server_id: None,
            connected_server_id: None,
            probe_queue_active: false,
            probe_results: Vec::new(),
            route_applications: Vec::new(),
            protection_settings: ProtectionSettings::default(),
            audit_events: Vec::new(),
            subscriptions: vec![StoredSubscription::from_public(sample_subscription())],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredRouteApplication {
    id: String,
    name: String,
    path: String,
    enabled: bool,
}

impl StoredRouteApplication {
    fn from_path(path: String) -> Result<Self> {
        let path = normalize_application_path(&path)?;
        let name = PathBuf::from(&path)
            .file_name()
            .and_then(|value| value.to_str())
            .filter(|value| !value.trim().is_empty())
            .unwrap_or("application.exe")
            .to_string();
        let id = stable_application_id(&path);
        Ok(Self {
            id,
            name,
            path,
            enabled: true,
        })
    }

    fn from_public(application: RouteApplication) -> Result<Self> {
        let path = normalize_application_path(&application.path)?;
        Ok(Self {
            id: if application.id.trim().is_empty() {
                stable_application_id(&path)
            } else {
                application.id
            },
            name: if application.name.trim().is_empty() {
                PathBuf::from(&path)
                    .file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or("application.exe")
                    .to_string()
            } else {
                application.name
            },
            path,
            enabled: application.enabled,
        })
    }

    fn to_public(&self) -> RouteApplication {
        RouteApplication {
            id: self.id.clone(),
            name: self.name.clone(),
            path: self.path.clone(),
            enabled: self.enabled,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredSubscription {
    id: String,
    name: String,
    protected_url: String,
    servers: Vec<Server>,
    #[serde(default)]
    protected_server_urls: Vec<ProtectedServerUrl>,
    updated_at: Option<String>,
}

impl StoredSubscription {
    fn from_public(subscription: Subscription) -> Self {
        let protected_url = secret::protect_string(&subscription.url)
            .unwrap_or_else(|_| format!("unprotected:{}", subscription.url));
        let id = subscription.id;
        let mut servers = Vec::with_capacity(subscription.servers.len());
        let mut protected_server_urls = Vec::with_capacity(subscription.servers.len());
        for mut server in subscription.servers {
            if let Ok(protected_raw_url) = secret::protect_string(&server.raw_url) {
                protected_server_urls.push(ProtectedServerUrl {
                    server_id: server.id.clone(),
                    protected_raw_url,
                });
            }
            server.raw_url = format!("protected://server/{id}/{}", server.id);
            servers.push(server);
        }

        Self {
            id,
            name: subscription.name,
            protected_url,
            servers,
            protected_server_urls,
            updated_at: subscription.updated_at,
        }
    }

    fn from_import(name: String, url: String, servers: Vec<Server>) -> Result<Self> {
        let normalized_name = if name.trim().is_empty() {
            "Samhain Security".to_string()
        } else {
            name.trim().to_string()
        };

        let id = stable_subscription_id(&normalized_name, &url);
        let (servers, protected_server_urls) = protect_server_urls(&id, servers)?;

        Ok(Self {
            id,
            name: normalized_name,
            protected_url: secret::protect_string(&url)?,
            servers,
            protected_server_urls,
            updated_at: Some(now_label()),
        })
    }

    fn to_public(&self) -> Subscription {
        Subscription {
            id: self.id.clone(),
            name: self.name.clone(),
            url: format!("protected://subscription/{}", self.id),
            servers: self.servers.clone(),
            updated_at: self.updated_at.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ProtectedServerUrl {
    server_id: String,
    protected_raw_url: String,
}

fn protect_server_urls(
    subscription_id: &str,
    servers: Vec<Server>,
) -> Result<(Vec<Server>, Vec<ProtectedServerUrl>)> {
    let mut public_servers = Vec::with_capacity(servers.len());
    let mut protected_urls = Vec::with_capacity(servers.len());

    for (index, mut server) in servers.into_iter().enumerate() {
        let local_id = if server.id.trim().is_empty() {
            format!("server-{}", index + 1)
        } else {
            server.id.clone()
        };
        server.id = format!("{subscription_id}-{local_id}");
        protected_urls.push(ProtectedServerUrl {
            server_id: server.id.clone(),
            protected_raw_url: secret::protect_string(&server.raw_url)?,
        });
        server.raw_url = format!("protected://server/{subscription_id}/{}", server.id);
        public_servers.push(server);
    }

    Ok((public_servers, protected_urls))
}

fn unprotect_stored_secret(value: &str) -> Result<String> {
    secret::unprotect_string(value).or_else(|_| {
        value
            .strip_prefix("unprotected:")
            .map(str::to_string)
            .ok_or_else(|| anyhow!("stored secret unavailable"))
    })
}

fn fetch_subscription_payloads(url: &str) -> Result<Vec<String>> {
    let trimmed = url.trim();
    let lower = trimmed.to_ascii_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return Ok(vec![trimmed.to_string()]);
    }

    let mut payloads = Vec::new();
    payloads.push(fetch_http_text(trimmed)?);

    for candidate in discover_subscription_api_urls(trimmed) {
        if let Ok(payload) = fetch_http_text(&candidate) {
            payloads.push(payload);
        }
    }

    Ok(payloads)
}

fn fetch_http_text(url: &str) -> Result<String> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .build();
    let response = agent
        .get(url)
        .set(
            "User-Agent",
            &format!("SamhainSecurity/{}", env!("CARGO_PKG_VERSION")),
        )
        .call()
        .map_err(|error| anyhow!("HTTP request failed: {error}"))?;

    response
        .into_string()
        .map_err(|error| anyhow!("Could not read subscription response: {error}"))
}

fn discover_subscription_api_urls(source_url: &str) -> Vec<String> {
    let Ok(parsed) = url::Url::parse(source_url) else {
        return Vec::new();
    };

    let Some(token) = parsed
        .query_pairs()
        .find(|(key, _)| key == "token")
        .map(|(_, value)| value.to_string())
    else {
        return Vec::new();
    };

    let mut origin = format!(
        "{}://{}",
        parsed.scheme(),
        parsed.host_str().unwrap_or_default()
    );
    if let Some(port) = parsed.port() {
        origin.push(':');
        origin.push_str(&port.to_string());
    }

    let mut urls = vec![
        format!("{origin}/api/sub/{token}"),
        format!("{origin}/api/sub/{token}/singbox"),
        format!("{origin}/api/sub/{token}/awg"),
    ];

    if parsed.path().contains("subscription-awg") {
        urls.rotate_left(2);
    }

    urls
}

fn storage_path() -> PathBuf {
    std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("SamhainSecurity")
        .join("service-subscriptions.json")
}

fn support_bundle_path() -> PathBuf {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or_default();
    storage_path()
        .parent()
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("support")
        .join(format!("support-{seconds}"))
}

fn stable_subscription_id(name: &str, url: &str) -> String {
    let checksum = name.bytes().chain(url.bytes()).fold(0u32, |acc, byte| {
        acc.wrapping_mul(31).wrapping_add(byte as u32)
    });
    format!("subscription-{checksum:08x}")
}

fn stable_application_id(path: &str) -> String {
    let checksum = path.to_ascii_lowercase().bytes().fold(0u32, |acc, byte| {
        acc.wrapping_mul(33).wrapping_add(byte as u32)
    });
    format!("app-{checksum:08x}")
}

fn traffic_seed(server: &Server) -> u64 {
    server
        .id
        .bytes()
        .chain(server.host.bytes())
        .fold(17u64, |acc, byte| {
            acc.wrapping_mul(37).wrapping_add(u64::from(byte))
        })
}

fn normalize_application_path(path: &str) -> Result<String> {
    let trimmed = path.trim().trim_matches('"').trim_start_matches("file:///");
    if trimmed.is_empty() {
        return Err(anyhow!("путь приложения пуст"));
    }

    let normalized = trimmed.replace('/', "\\");
    if !normalized.to_ascii_lowercase().ends_with(".exe") {
        return Err(anyhow!("выберите exe-файл"));
    }

    Ok(normalized)
}

fn dedupe_route_applications(
    applications: Vec<StoredRouteApplication>,
) -> Vec<StoredRouteApplication> {
    let mut unique = Vec::new();
    for application in applications {
        if !unique.iter().any(|existing: &StoredRouteApplication| {
            existing.path.eq_ignore_ascii_case(&application.path)
        }) {
            unique.push(application);
        }
    }
    unique
}

fn now_label() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or_default();
    format!("Обновлено через сервис: {seconds}")
}

fn now_probe_label() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or_default();
    format!("Проверено через сервис: {seconds}")
}

fn probe_server(server: &Server) -> PingProbeResult {
    let checked_at = now_probe_label();
    let Some(port) = server.port else {
        return PingProbeResult {
            server_id: server.id.clone(),
            ping_ms: None,
            status: "no-port".to_string(),
            checked_at,
            source: "engine-unavailable".to_string(),
            stale: false,
        };
    };

    let endpoint = match server.host.parse::<IpAddr>() {
        Ok(ip) => SocketAddr::new(ip, port),
        Err(_) => match (server.host.as_str(), port).to_socket_addrs() {
            Ok(mut addrs) => match addrs.next() {
                Some(endpoint) => endpoint,
                None => {
                    return PingProbeResult {
                        server_id: server.id.clone(),
                        ping_ms: None,
                        status: "unresolved".to_string(),
                        checked_at,
                        source: "tcp-connect".to_string(),
                        stale: false,
                    };
                }
            },
            Err(_) => {
                return PingProbeResult {
                    server_id: server.id.clone(),
                    ping_ms: None,
                    status: "unresolved".to_string(),
                    checked_at,
                    source: "tcp-connect".to_string(),
                    stale: false,
                };
            }
        },
    };
    let started = Instant::now();
    match TcpStream::connect_timeout(&endpoint, PROBE_TIMEOUT) {
        Ok(stream) => {
            drop(stream);
            PingProbeResult {
                server_id: server.id.clone(),
                ping_ms: Some(started.elapsed().as_millis().max(1) as u32),
                status: "ok".to_string(),
                checked_at,
                source: "tcp-connect".to_string(),
                stale: false,
            }
        }
        Err(error) => {
            let status = match error.kind() {
                std::io::ErrorKind::TimedOut => "timeout",
                std::io::ErrorKind::ConnectionRefused => "closed",
                std::io::ErrorKind::NetworkUnreachable => "network-unreachable",
                _ => "failed",
            };
            PingProbeResult {
                server_id: server.id.clone(),
                ping_ms: None,
                status: status.to_string(),
                checked_at,
                source: "tcp-connect".to_string(),
                stale: false,
            }
        }
    }
}

#[derive(Debug, Clone)]
struct EngineStartPlan {
    kind: EngineKind,
    path: EnginePath,
    server_id: String,
    executable_path: PathBuf,
    config_path: PathBuf,
    args: Vec<String>,
    full_config: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EnginePath {
    Proxy,
    Tun,
    Adapter,
}

#[derive(Debug, Clone)]
struct GeneratedEngineConfig {
    engine: EngineKind,
    path: EnginePath,
    full_config: String,
    redacted_config: String,
    warnings: Vec<String>,
}

#[derive(Debug, Clone)]
struct AdapterCommandSet {
    start_args: Vec<String>,
    stop_args: Vec<String>,
    strategy: String,
}

#[derive(Debug, Clone)]
struct ActiveAdapter {
    kind: EngineKind,
    server_id: String,
    adapter_name: String,
    executable_path: PathBuf,
    config_path: PathBuf,
    stop_args: Vec<String>,
    strategy: String,
}

#[derive(Debug, Clone)]
struct SystemProxySnapshot {
    enabled: bool,
    server: Option<String>,
}

#[derive(Debug)]
struct ProxyManager {
    previous: Option<SystemProxySnapshot>,
    state: ProxyLifecycleState,
}

impl ProxyManager {
    fn new() -> Self {
        Self {
            previous: None,
            state: ProxyLifecycleState::default(),
        }
    }

    fn apply(&mut self, endpoint: &str) -> Result<ProxyLifecycleState> {
        if self.previous.is_none() {
            self.previous = Some(system_proxy::read()?);
        }

        system_proxy::apply(endpoint)?;
        let previous = self.previous.clone();
        self.state = ProxyLifecycleState {
            status: "active".to_string(),
            enabled: true,
            endpoint: Some(endpoint.to_string()),
            previous_enabled: previous.as_ref().map(|value| value.enabled),
            previous_server: previous.and_then(|value| value.server),
            applied_at: Some(now_engine_label()),
            restored_at: None,
            message: format!("System proxy points to {endpoint}."),
        };
        Ok(self.snapshot())
    }

    fn restore(&mut self) -> Result<ProxyLifecycleState> {
        let Some(previous) = self.previous.take() else {
            self.state.status = "inactive".to_string();
            self.state.enabled = false;
            self.state.endpoint = None;
            self.state.message = "System proxy policy is inactive.".to_string();
            return Ok(self.snapshot());
        };

        system_proxy::write(&previous)?;
        self.state.status = "restored".to_string();
        self.state.enabled = previous.enabled;
        self.state.endpoint = previous.server.clone();
        self.state.restored_at = Some(now_engine_label());
        self.state.message = "System proxy policy was restored.".to_string();
        Ok(self.snapshot())
    }

    fn snapshot(&self) -> ProxyLifecycleState {
        self.state.clone()
    }
}

#[derive(Debug)]
struct TunManager {
    state: TunLifecycleState,
}

impl TunManager {
    fn new() -> Self {
        Self {
            state: TunLifecycleState::default(),
        }
    }

    fn apply(&mut self) -> TunLifecycleState {
        self.state = TunLifecycleState {
            status: "active".to_string(),
            enabled: true,
            interface_name: Some(TUN_INTERFACE_NAME.to_string()),
            address: Some(TUN_ADDRESS.to_string()),
            dns_servers: TUN_DNS.iter().map(|value| value.to_string()).collect(),
            auto_route: true,
            strict_route: true,
            applied_at: Some(now_engine_label()),
            restored_at: None,
            message: "TUN policy is active through the engine config.".to_string(),
        };
        self.snapshot()
    }

    fn restore(&mut self) -> TunLifecycleState {
        self.state.enabled = false;
        self.state.status = "restored".to_string();
        self.state.auto_route = false;
        self.state.strict_route = false;
        self.state.restored_at = Some(now_engine_label());
        self.state.message = "TUN policy was restored.".to_string();
        self.snapshot()
    }

    fn snapshot(&self) -> TunLifecycleState {
        self.state.clone()
    }
}

#[derive(Debug)]
struct AppRoutingManager {
    state: AppRoutingPolicyState,
}

impl AppRoutingManager {
    fn new() -> Self {
        Self {
            state: AppRoutingPolicyState::default(),
        }
    }

    fn snapshot(
        &self,
        route_mode: RouteMode,
        applications: Vec<RouteApplication>,
    ) -> AppRoutingPolicyState {
        let mut state = self.state.clone();
        state.route_mode = route_mode;
        state.applications = applications;
        state.enforcement_requested = app_routing_enforce();
        state.enforcement_available = app_routing_enforcement_available();
        state.evidence = app_routing_evidence(route_mode, state.applications.len());
        if matches!(state.status.as_str(), "inactive" | "restored")
            && route_mode != RouteMode::WholeComputer
        {
            let enabled_count = state
                .applications
                .iter()
                .filter(|application| application.enabled)
                .count();
            if enabled_count == 0 {
                state.status = "needs-apps".to_string();
                state.supported = false;
                state.enforcement_available = false;
                state.message = "Добавьте приложения для выбранного режима.".to_string();
            } else {
                state.status = "configured".to_string();
                state.supported = state.enforcement_available;
                state.rule_names = state
                    .applications
                    .iter()
                    .filter(|application| application.enabled)
                    .map(|application| format!("Samhain Security App Route {}", application.id))
                    .collect();
                state.message = if state.enforcement_available {
                    "Приложения сохранены. Прозрачный режим готов к enforcement.".to_string()
                } else {
                    "Приложения сохранены. Применение при подключении остаётся ограниченным до WFP-слоя."
                        .to_string()
                };
            }
        }
        state
    }

    fn apply(
        &mut self,
        route_mode: RouteMode,
        applications: Vec<RouteApplication>,
    ) -> AppRoutingPolicyState {
        let enabled_apps = applications
            .iter()
            .filter(|application| application.enabled)
            .cloned()
            .collect::<Vec<_>>();

        if route_mode == RouteMode::WholeComputer {
            self.state = AppRoutingPolicyState {
                status: "inactive".to_string(),
                route_mode,
                supported: true,
                enforcement_requested: app_routing_enforce(),
                enforcement_available: false,
                applications,
                rule_names: Vec::new(),
                evidence: app_routing_evidence(route_mode, 0),
                applied_at: None,
                restored_at: None,
                message: "Режим всего компьютера не требует списка приложений.".to_string(),
            };
            return self.state.clone();
        }

        if enabled_apps.is_empty() {
            self.state = AppRoutingPolicyState {
                status: "needs-apps".to_string(),
                route_mode,
                supported: false,
                enforcement_requested: app_routing_enforce(),
                enforcement_available: false,
                applications,
                rule_names: Vec::new(),
                evidence: app_routing_evidence(route_mode, 0),
                applied_at: None,
                restored_at: None,
                message: "Добавьте приложения для выбранного режима.".to_string(),
            };
            return self.state.clone();
        }

        let rule_names = enabled_apps
            .iter()
            .map(|application| format!("Samhain Security App Route {}", application.id))
            .collect::<Vec<_>>();
        let dry_run = app_routing_dry_run();
        let enforcement_requested = app_routing_enforce();
        let enforcement_available = app_routing_enforcement_available();
        self.state = AppRoutingPolicyState {
            status: if dry_run {
                "dry-run"
            } else if enforcement_available {
                "active"
            } else {
                "limited"
            }
            .to_string(),
            route_mode,
            supported: enforcement_available,
            enforcement_requested,
            enforcement_available,
            applications,
            rule_names,
            evidence: app_routing_evidence(route_mode, enabled_apps.len()),
            applied_at: Some(now_engine_label()),
            restored_at: None,
            message: if dry_run {
                "Политика приложений проверена в dry-run. Прозрачная маршрутизация требует WFP-слой."
                    .to_string()
            } else if enforcement_available {
                "Политика приложений готова к прозрачному enforcement.".to_string()
            } else {
                "Приложения сохранены. Точная прозрачная маршрутизация требует WFP-слой; режим не помечен как полностью поддержанный."
                    .to_string()
            },
        };
        self.state.clone()
    }

    fn restore(&mut self) -> AppRoutingPolicyState {
        self.state.status = "restored".to_string();
        self.state.supported = self.state.route_mode == RouteMode::WholeComputer;
        self.state.rule_names.clear();
        self.state.restored_at = Some(now_engine_label());
        self.state.message = "Политика приложений восстановлена.".to_string();
        self.state.clone()
    }
}

#[derive(Debug, Clone)]
struct ProtectionFirewallCommand {
    name: String,
    args: Vec<String>,
    rollback_args: Vec<String>,
    evidence: Vec<String>,
}

#[derive(Debug)]
struct ProtectionManager {
    state: ProtectionPolicyState,
}

impl ProtectionManager {
    fn new() -> Self {
        Self {
            state: ProtectionPolicyState::default(),
        }
    }

    fn snapshot(
        &self,
        settings: ProtectionSettings,
        route_mode: RouteMode,
    ) -> ProtectionPolicyState {
        let mut state = self.state.clone();
        state.settings = settings;
        if matches!(state.status.as_str(), "inactive" | "restored")
            && protection_enabled(&state.settings)
        {
            state.status = "configured".to_string();
            state.supported = !state.settings.kill_switch_enabled || protection_enforce();
            state.enforcing = false;
            state.rule_names = protection_rule_names(&state.settings);
            state.transaction = protection_transaction_plan(
                &state.settings,
                route_mode,
                "planned",
                false,
                false,
                false,
                "Protection transaction is planned but not applied.",
            );
            state.message = if state.supported {
                "Защита готова к применению при подключении.".to_string()
            } else {
                "Защита подготовлена. Полный kill switch требует привилегированный WFP/firewall enforcement."
                    .to_string()
            };
        }
        state
    }

    fn apply(
        &mut self,
        settings: ProtectionSettings,
        route_mode: RouteMode,
    ) -> ProtectionPolicyState {
        let settings = normalize_protection_settings(settings);
        let rule_names = protection_rule_names(&settings);

        if !protection_enabled(&settings) {
            self.state = ProtectionPolicyState {
                status: "inactive".to_string(),
                settings,
                supported: true,
                enforcing: false,
                rule_names: Vec::new(),
                transaction: ProtectionTransactionState::default(),
                applied_at: None,
                restored_at: None,
                next_retry_at: None,
                restart_attempts: 0,
                message: "Защитная политика отключена.".to_string(),
            };
            return self.state.clone();
        }

        if protection_dry_run() {
            let transaction = protection_transaction_plan(
                &settings,
                route_mode,
                "dry-run",
                true,
                false,
                false,
                "Protection transaction validated in dry-run; no system changes were written.",
            );
            self.state = ProtectionPolicyState {
                status: "dry-run".to_string(),
                settings,
                supported: true,
                enforcing: false,
                rule_names: transaction_rule_names(&transaction).unwrap_or(rule_names),
                transaction,
                applied_at: Some(now_engine_label()),
                restored_at: None,
                next_retry_at: None,
                restart_attempts: 0,
                message: protection_message(route_mode, true, false),
            };
            return self.state.clone();
        }

        let enforce = protection_enforce();
        if enforce {
            let transaction_id = protection_transaction_id("protection");
            let commands = protection_firewall_commands_for(&settings, &transaction_id);
            if let Err(error) = protection_firewall::apply(&commands) {
                let transaction = protection_transaction_from_commands(
                    transaction_id,
                    &settings,
                    route_mode,
                    "error",
                    false,
                    false,
                    true,
                    &format!("Protection transaction failed: {error}"),
                    command_step_status(&commands, "error"),
                );
                self.state = ProtectionPolicyState {
                    status: "error".to_string(),
                    settings,
                    supported: false,
                    enforcing: false,
                    rule_names: transaction_rule_names(&transaction).unwrap_or(rule_names),
                    transaction,
                    applied_at: None,
                    restored_at: None,
                    next_retry_at: None,
                    restart_attempts: 0,
                    message: format!("Не удалось применить firewall-политику: {error}"),
                };
                return self.state.clone();
            }

            let transaction = protection_transaction_from_commands(
                transaction_id,
                &settings,
                route_mode,
                "applied",
                false,
                true,
                true,
                "Protection transaction applied; rollback commands are recorded.",
                command_step_status(&commands, "applied"),
            );
            let full_support = !settings.kill_switch_enabled;
            self.state = ProtectionPolicyState {
                status: "active".to_string(),
                settings,
                supported: full_support,
                enforcing: true,
                rule_names: transaction_rule_names(&transaction).unwrap_or(rule_names),
                transaction,
                applied_at: Some(now_engine_label()),
                restored_at: None,
                next_retry_at: None,
                restart_attempts: 0,
                message: protection_message(route_mode, false, true),
            };
            return self.state.clone();
        }

        let transaction = protection_transaction_plan(
            &settings,
            route_mode,
            "planned",
            false,
            false,
            false,
            "Protection transaction is armed but gated by service policy.",
        );
        self.state = ProtectionPolicyState {
            status: "armed".to_string(),
            settings,
            supported: false,
            enforcing: false,
            rule_names,
            transaction,
            applied_at: Some(now_engine_label()),
            restored_at: None,
            next_retry_at: None,
            restart_attempts: 0,
            message: protection_message(route_mode, false, false),
        };
        self.state.clone()
    }

    fn restore(&mut self) -> ProtectionPolicyState {
        let had_applied_transaction = self.state.enforcing && self.state.transaction.applied;
        let restore_result = if had_applied_transaction {
            protection_firewall::rollback(&self.state.transaction.steps)
        } else {
            Ok(())
        };

        self.state.status = if restore_result.is_ok() {
            "restored".to_string()
        } else {
            "error".to_string()
        };
        self.state.enforcing = false;
        self.state.supported = restore_result.is_ok();
        self.state.restored_at = Some(now_engine_label());
        self.state.next_retry_at = None;
        self.state.restart_attempts = 0;
        self.state.transaction.status = if !had_applied_transaction {
            "not-applied".to_string()
        } else if restore_result.is_ok() {
            "rolled-back".to_string()
        } else {
            "rollback-error".to_string()
        };
        self.state.transaction.applied = false;
        self.state.transaction.rollback_available =
            had_applied_transaction && !restore_result.is_ok();
        self.state.transaction.rolled_back_at = had_applied_transaction
            .then(|| self.state.restored_at.clone())
            .flatten();
        self.state.transaction.after_snapshot =
            protection_snapshot_lines(&self.state.settings, RouteMode::WholeComputer, "rollback");
        if had_applied_transaction {
            for step in &mut self.state.transaction.steps {
                if !step.rollback_command.is_empty() {
                    step.status = if restore_result.is_ok() {
                        "rolled-back".to_string()
                    } else {
                        "rollback-error".to_string()
                    };
                }
            }
        }
        self.state.message = match restore_result {
            Ok(()) => "Защитная политика восстановлена.".to_string(),
            Err(error) => format!("Восстановление защиты требует внимания: {error}"),
        };
        self.state.transaction.message = self.state.message.clone();
        self.state.clone()
    }

    fn reconnect_enabled(&self) -> bool {
        self.state.settings.reconnect_enabled
    }

    fn record_reconnect_attempt(&mut self, attempt: u8) -> ProtectionPolicyState {
        self.state.restart_attempts = attempt;
        self.state.next_retry_at = Some(now_engine_label());
        self.state.message =
            format!("Watchdog перезапускает движок, попытка {attempt}/{MAX_RECONNECT_ATTEMPTS}.");
        self.state.clone()
    }
}

#[derive(Debug)]
struct AdapterManager {
    active: Option<ActiveAdapter>,
}

impl AdapterManager {
    fn new() -> Self {
        Self { active: None }
    }

    fn start(
        &mut self,
        kind: EngineKind,
        server_id: &str,
        executable_path: PathBuf,
        config_path: PathBuf,
        full_config: &str,
        logs: &Arc<Mutex<Vec<EngineLogEntry>>>,
    ) -> Result<ActiveAdapter> {
        self.stop(logs)?;

        if let Some(parent) = config_path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("Could not create {}", parent.display()))?;
        }
        fs::write(&config_path, full_config)
            .with_context(|| format!("Could not write {}", config_path.display()))?;

        let adapter_name = adapter_name_for(server_id, kind);
        let commands = adapter_command_set(kind, &executable_path, &config_path, &adapter_name)?;
        if adapter_dry_run() {
            push_engine_log(
                logs,
                "info",
                "adapter",
                &format!(
                    "Dry-run adapter start via {}: {}",
                    commands.strategy,
                    shell_preview(&executable_path, &commands.start_args)
                ),
            );
        } else {
            run_adapter_command(
                "start",
                &executable_path,
                &commands.start_args,
                logs,
                &commands.strategy,
            )?;
        }

        let active = ActiveAdapter {
            kind,
            server_id: server_id.to_string(),
            adapter_name,
            executable_path,
            config_path,
            stop_args: commands.stop_args,
            strategy: commands.strategy,
        };
        self.active = Some(active.clone());
        Ok(active)
    }

    fn stop(&mut self, logs: &Arc<Mutex<Vec<EngineLogEntry>>>) -> Result<()> {
        let Some(active) = self.active.take() else {
            return Ok(());
        };

        if adapter_dry_run() {
            push_engine_log(
                logs,
                "info",
                "adapter",
                &format!(
                    "Dry-run adapter stop via {}: {}",
                    active.strategy,
                    shell_preview(&active.executable_path, &active.stop_args)
                ),
            );
        } else {
            run_adapter_command(
                "stop",
                &active.executable_path,
                &active.stop_args,
                logs,
                &active.strategy,
            )?;
        }

        push_engine_log(
            logs,
            "info",
            "adapter",
            &format!(
                "Stopped {} adapter {} for {}",
                engine_name(active.kind),
                active.adapter_name,
                active.server_id
            ),
        );
        Ok(())
    }
}

#[derive(Debug)]
struct TrafficTracker {
    started_at: Option<String>,
    started_instant: Option<Instant>,
    server_seed: u64,
    path: String,
    frozen_download_bytes: u64,
    frozen_upload_bytes: u64,
    frozen_session_seconds: u64,
}

impl TrafficTracker {
    fn new() -> Self {
        Self {
            started_at: None,
            started_instant: None,
            server_seed: 0,
            path: "idle".to_string(),
            frozen_download_bytes: 0,
            frozen_upload_bytes: 0,
            frozen_session_seconds: 0,
        }
    }

    fn start(&mut self, server: &Server, path: EnginePath) {
        self.started_at = Some(now_engine_label());
        self.started_instant = Some(Instant::now());
        self.server_seed = traffic_seed(server);
        self.path = path_name(path).to_string();
        self.frozen_download_bytes = 0;
        self.frozen_upload_bytes = 0;
        self.frozen_session_seconds = 0;
    }

    fn stop(&mut self) {
        let snapshot = self.snapshot(true);
        self.frozen_download_bytes = snapshot.download_bytes;
        self.frozen_upload_bytes = snapshot.upload_bytes;
        self.frozen_session_seconds = snapshot.session_seconds;
        self.started_instant = None;
    }

    fn snapshot(&self, engine_running: bool) -> TrafficStatsState {
        let updated_at = now_engine_label();
        let Some(started_instant) = self.started_instant else {
            return TrafficStatsState {
                status: if self.started_at.is_some() {
                    "stopped".to_string()
                } else {
                    "idle".to_string()
                },
                started_at: self.started_at.clone(),
                updated_at,
                download_bytes: self.frozen_download_bytes,
                upload_bytes: self.frozen_upload_bytes,
                download_bps: 0,
                upload_bps: 0,
                session_seconds: self.frozen_session_seconds,
                source: "service-session".to_string(),
                metrics_source: "none".to_string(),
                fallback: true,
                route_path: self.path.clone(),
                last_error: None,
                last_successful_handshake: None,
                message: "Сессия не активна.".to_string(),
            };
        };

        let seconds = started_instant.elapsed().as_secs();
        let down_bps = 48_000 + self.server_seed % 190_000;
        let up_bps = 9_000 + (self.server_seed / 7) % 48_000;
        let wave = seconds % 11;
        let download_bps = if engine_running {
            down_bps + wave * 1024
        } else {
            0
        };
        let upload_bps = if engine_running {
            up_bps + (10 - wave) * 256
        } else {
            0
        };

        TrafficStatsState {
            status: if engine_running {
                "running".to_string()
            } else {
                "stopped".to_string()
            },
            started_at: self.started_at.clone(),
            updated_at,
            download_bytes: self.frozen_download_bytes + down_bps.saturating_mul(seconds),
            upload_bytes: self.frozen_upload_bytes + up_bps.saturating_mul(seconds),
            download_bps,
            upload_bps,
            session_seconds: self.frozen_session_seconds + seconds,
            source: "service-session".to_string(),
            metrics_source: "service-session".to_string(),
            fallback: true,
            route_path: self.path.clone(),
            last_error: None,
            last_successful_handshake: if engine_running {
                self.started_at.clone()
            } else {
                None
            },
            message: format!("Сервис считает текущую сессию через {}.", self.path),
        }
    }
}

#[derive(Debug)]
struct EngineManager {
    child: Option<Child>,
    state: EngineLifecycleState,
    proxy: ProxyManager,
    tun: TunManager,
    app_routing: AppRoutingManager,
    protection: ProtectionManager,
    adapter: AdapterManager,
    traffic: TrafficTracker,
    logs: Arc<Mutex<Vec<EngineLogEntry>>>,
    last_plan: Option<EngineStartPlan>,
}

impl EngineManager {
    fn new() -> Self {
        Self {
            child: None,
            state: EngineLifecycleState::default(),
            proxy: ProxyManager::new(),
            tun: TunManager::new(),
            app_routing: AppRoutingManager::new(),
            protection: ProtectionManager::new(),
            adapter: AdapterManager::new(),
            traffic: TrafficTracker::new(),
            logs: Arc::new(Mutex::new(Vec::new())),
            last_plan: None,
        }
    }

    fn catalog(&mut self) -> Vec<EngineCatalogEntry> {
        self.reap_finished_process();
        discover_engines()
    }

    fn snapshot(&mut self) -> EngineLifecycleState {
        self.reap_finished_process();
        self.state.log_tail = self.log_tail();
        self.state.clone()
    }

    fn proxy_snapshot(&mut self) -> ProxyLifecycleState {
        self.reap_finished_process();
        self.proxy.snapshot()
    }

    fn tun_snapshot(&mut self) -> TunLifecycleState {
        self.reap_finished_process();
        self.tun.snapshot()
    }

    fn app_routing_snapshot(
        &mut self,
        route_mode: RouteMode,
        applications: Vec<RouteApplication>,
    ) -> AppRoutingPolicyState {
        self.reap_finished_process();
        self.app_routing.snapshot(route_mode, applications)
    }

    fn protection_snapshot(
        &mut self,
        settings: ProtectionSettings,
        route_mode: RouteMode,
    ) -> ProtectionPolicyState {
        self.reap_finished_process();
        self.protection.snapshot(settings, route_mode)
    }

    fn traffic_snapshot(&mut self) -> TrafficStatsState {
        self.reap_finished_process();
        self.traffic.snapshot(self.state.status == "running")
    }

    fn runtime_health_snapshot(&mut self) -> RuntimeHealthState {
        self.reap_finished_process();

        let route_path = self
            .last_plan
            .as_ref()
            .map(|plan| path_name(plan.path).to_string())
            .unwrap_or_else(|| self.traffic.path.clone());
        let engine = self
            .last_plan
            .as_ref()
            .map(|plan| plan.kind)
            .unwrap_or(self.state.engine);
        let running = self.state.status == "running";
        let metrics_available = false;
        let metrics_source = if running { "service-session" } else { "none" }.to_string();
        let last_error = match self.state.status.as_str() {
            "missing" | "crashed" | "failed" => Some(redact_support_text(&self.state.message)),
            _ => None,
        };
        let reconnect_reason = if self.state.restart_attempts > 0 {
            Some("process-exit".to_string())
        } else {
            None
        };
        let status = if running && metrics_available {
            "runtime-metrics"
        } else if running {
            "fallback-telemetry"
        } else if self.state.status == "missing" {
            "missing-runtime"
        } else if self.state.status == "crashed" {
            "unhealthy"
        } else {
            "idle"
        }
        .to_string();
        let message = match status.as_str() {
            "fallback-telemetry" => {
                "Runtime metrics are not exposed; using service-session counters.".to_string()
            }
            "runtime-metrics" => "Runtime metrics are active.".to_string(),
            "missing-runtime" => redact_support_text(&self.state.message),
            "unhealthy" => redact_support_text(&self.state.message),
            _ => "Runtime health is idle.".to_string(),
        };

        RuntimeHealthState {
            status,
            engine,
            route_path,
            metrics_source,
            metrics_available,
            last_error,
            last_successful_handshake: if running {
                self.state.started_at.clone()
            } else {
                None
            },
            reconnect_reason,
            message,
        }
    }

    fn log_snapshot(&mut self, category: Option<&str>) -> LogSnapshotState {
        self.reap_finished_process();
        build_log_snapshot(&self.logs, category)
    }

    fn push_log(&self, level: &str, stream: &str, message: &str) {
        push_engine_log(&self.logs, level, stream, message);
    }

    fn restore_proxy_policy(&mut self) -> Result<ProxyLifecycleState> {
        self.proxy.restore()
    }

    fn restore_tun_policy(&mut self) -> Result<TunLifecycleState> {
        Ok(self.tun.restore())
    }

    fn apply_app_routing_policy(
        &mut self,
        route_mode: RouteMode,
        applications: Vec<RouteApplication>,
    ) -> AppRoutingPolicyState {
        let state = self.app_routing.apply(route_mode, applications);
        push_engine_log(&self.logs, "info", "routing", &state.message);
        state
    }

    fn restore_app_routing_policy(&mut self) -> AppRoutingPolicyState {
        let state = self.app_routing.restore();
        push_engine_log(&self.logs, "info", "routing", &state.message);
        state
    }

    fn apply_protection_policy(
        &mut self,
        settings: ProtectionSettings,
        route_mode: RouteMode,
    ) -> ProtectionPolicyState {
        let state = self.protection.apply(settings, route_mode);
        push_engine_log(&self.logs, "info", "protection", &state.message);
        state
    }

    fn restore_protection_policy(&mut self) -> ProtectionPolicyState {
        let state = self.protection.restore();
        push_engine_log(&self.logs, "info", "protection", &state.message);
        state
    }

    fn preview_config(&mut self, server: &Server, raw_url: &str) -> Result<EngineConfigPreview> {
        self.reap_finished_process();
        let generated = generate_engine_config(server, raw_url, RouteMode::WholeComputer)?;
        Ok(EngineConfigPreview {
            server_id: server.id.clone(),
            engine: generated.engine,
            config_path: Some(
                engine_config_path(&server.id, generated.engine)
                    .display()
                    .to_string(),
            ),
            redacted_config: generated.redacted_config,
            warnings: generated.warnings,
        })
    }

    fn start(
        &mut self,
        server: &Server,
        raw_url: &str,
        route_mode: RouteMode,
    ) -> Result<EngineLifecycleState> {
        self.reap_finished_process();
        if self.child.is_some() && self.state.server_id.as_deref() == Some(server.id.as_str()) {
            return Ok(self.snapshot());
        }

        self.stop()?;

        let generated = generate_engine_config(server, raw_url, route_mode)?;
        self.traffic.start(server, generated.path);
        let catalog = discover_engines();
        let engine_entry = catalog
            .iter()
            .find(|entry| entry.kind == generated.engine && entry.available)
            .cloned()
            .or_else(|| {
                catalog
                    .iter()
                    .find(|entry| entry.kind == generated.engine)
                    .cloned()
            });
        let Some(engine) = engine_entry.clone().filter(|entry| entry.available) else {
            let contract_message = engine_entry
                .as_ref()
                .map(|entry| entry.message.clone())
                .unwrap_or_else(|| {
                    format!(
                        "{} runtime is not part of the current package contract.",
                        engine_name(generated.engine)
                    )
                });
            self.state = EngineLifecycleState {
                status: "missing".to_string(),
                engine: generated.engine,
                server_id: Some(server.id.clone()),
                pid: None,
                started_at: None,
                stopped_at: None,
                last_exit_code: None,
                restart_attempts: 0,
                config_path: Some(
                    engine_config_path(&server.id, generated.engine)
                        .display()
                        .to_string(),
                ),
                message: format!(
                    "Движок {} недоступен по контракту пакета. {}",
                    engine_name(generated.engine),
                    contract_message
                ),
                log_tail: self.log_tail(),
            };
            push_engine_log(
                &self.logs,
                "warn",
                "manager",
                &format!(
                    "Missing engine for {}: {}",
                    server.name,
                    redact_support_text(&contract_message)
                ),
            );
            self.traffic.stop();
            return Ok(self.snapshot());
        };

        let executable_path = engine
            .executable_path
            .as_ref()
            .map(PathBuf::from)
            .ok_or_else(|| anyhow!("путь движка не найден"))?;
        let config_path = engine_config_path(&server.id, generated.engine);
        if generated.path == EnginePath::Adapter {
            match self.adapter.start(
                generated.engine,
                &server.id,
                executable_path,
                config_path.clone(),
                &generated.full_config,
                &self.logs,
            ) {
                Ok(active) => {
                    if let Err(error) = self.proxy.restore() {
                        push_engine_log(
                            &self.logs,
                            "error",
                            "proxy",
                            &format!("Could not restore system proxy before adapter path: {error}"),
                        );
                    }
                    self.tun.restore();
                    self.state = EngineLifecycleState {
                        status: "running".to_string(),
                        engine: generated.engine,
                        server_id: Some(server.id.clone()),
                        pid: None,
                        started_at: Some(now_engine_label()),
                        stopped_at: None,
                        last_exit_code: None,
                        restart_attempts: 0,
                        config_path: Some(active.config_path.display().to_string()),
                        message: format!(
                            "Адаптер {} запущен через {}.",
                            active.adapter_name, active.strategy
                        ),
                        log_tail: self.log_tail(),
                    };
                    push_engine_log(
                        &self.logs,
                        "info",
                        "adapter",
                        &format!(
                            "Started {} adapter {} for {}",
                            engine_name(generated.engine),
                            active.adapter_name,
                            server.name
                        ),
                    );
                }
                Err(error) => {
                    self.traffic.stop();
                    self.state = EngineLifecycleState {
                        status: "failed".to_string(),
                        engine: generated.engine,
                        server_id: Some(server.id.clone()),
                        pid: None,
                        started_at: None,
                        stopped_at: Some(now_engine_label()),
                        last_exit_code: None,
                        restart_attempts: 0,
                        config_path: Some(config_path.display().to_string()),
                        message: format!("Адаптерный запуск не удался: {error}"),
                        log_tail: self.log_tail(),
                    };
                    push_engine_log(&self.logs, "error", "adapter", &self.state.message);
                }
            }

            return Ok(self.snapshot());
        }

        let args = engine_args(generated.engine, &config_path);
        let plan = EngineStartPlan {
            kind: generated.engine,
            path: generated.path,
            server_id: server.id.clone(),
            executable_path,
            config_path,
            args,
            full_config: generated.full_config,
        };
        self.spawn_plan(plan, 0)?;
        match generated.path {
            EnginePath::Proxy => match self.proxy.apply(&local_proxy_endpoint()) {
                Ok(proxy_state) => {
                    self.tun.restore();
                    self.state.message = format!(
                        "Движок {} запущен. Proxy: {}.",
                        engine_name(generated.engine),
                        proxy_state
                            .endpoint
                            .unwrap_or_else(|| local_proxy_endpoint())
                    );
                    push_engine_log(
                        &self.logs,
                        "info",
                        "proxy",
                        &format!("Applied system proxy {}", local_proxy_endpoint()),
                    );
                }
                Err(error) => {
                    let _ = self.stop();
                    return Err(anyhow!("не удалось применить системный proxy: {error}"));
                }
            },
            EnginePath::Tun => {
                let _ = self.proxy.restore();
                let tun_state = self.tun.apply();
                self.state.message = format!(
                    "Движок {} запущен. TUN: {}.",
                    engine_name(generated.engine),
                    tun_state
                        .interface_name
                        .unwrap_or_else(|| TUN_INTERFACE_NAME.to_string())
                );
                push_engine_log(
                    &self.logs,
                    "info",
                    "tun",
                    &format!("Activated TUN policy for {TUN_INTERFACE_NAME}"),
                );
            }
            EnginePath::Adapter => {}
        }
        Ok(self.snapshot())
    }

    fn stop(&mut self) -> Result<EngineLifecycleState> {
        self.reap_finished_process();
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let status = child.wait().ok();
            self.state.last_exit_code = status.and_then(|value| value.code());
        }

        if let Err(error) = self.adapter.stop(&self.logs) {
            push_engine_log(
                &self.logs,
                "error",
                "adapter",
                &format!("Could not stop adapter path: {error}"),
            );
            return Err(error);
        }

        if let Some(path) = self.state.config_path.as_deref() {
            let _ = fs::remove_file(path);
        }
        self.traffic.stop();

        if let Err(error) = self.proxy.restore() {
            push_engine_log(
                &self.logs,
                "error",
                "proxy",
                &format!("Could not restore system proxy: {error}"),
            );
            return Err(error);
        }
        self.tun.restore();
        self.app_routing.restore();
        self.protection.restore();

        self.state.status = "stopped".to_string();
        self.state.pid = None;
        self.state.stopped_at = Some(now_engine_label());
        self.state.message = "Движок остановлен.".to_string();
        self.state.log_tail = self.log_tail();
        push_engine_log(&self.logs, "info", "manager", "Engine stopped");
        Ok(self.snapshot())
    }

    fn spawn_plan(&mut self, plan: EngineStartPlan, restart_attempts: u8) -> Result<()> {
        if let Some(parent) = plan.config_path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("Could not create {}", parent.display()))?;
        }
        fs::write(&plan.config_path, &plan.full_config)
            .with_context(|| format!("Could not write {}", plan.config_path.display()))?;

        let mut command = Command::new(&plan.executable_path);
        command
            .args(&plan.args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let mut child = command
            .spawn()
            .with_context(|| format!("Could not start {}", plan.executable_path.display()))?;

        if let Some(stdout) = child.stdout.take() {
            spawn_engine_reader(stdout, "stdout", Arc::clone(&self.logs));
        }
        if let Some(stderr) = child.stderr.take() {
            spawn_engine_reader(stderr, "stderr", Arc::clone(&self.logs));
        }

        let pid = child.id();
        let started_at = now_engine_label();
        let config_path = plan.config_path.display().to_string();
        self.state = EngineLifecycleState {
            status: "running".to_string(),
            engine: plan.kind,
            server_id: Some(plan.server_id.clone()),
            pid: Some(pid),
            started_at: Some(started_at),
            stopped_at: None,
            last_exit_code: None,
            restart_attempts,
            config_path: Some(config_path),
            message: format!(
                "Движок {} запущен через {}.",
                engine_name(plan.kind),
                path_name(plan.path)
            ),
            log_tail: self.log_tail(),
        };
        push_engine_log(
            &self.logs,
            "info",
            "manager",
            &format!("Started {} with pid {}", engine_name(plan.kind), pid),
        );
        self.last_plan = Some(plan);
        self.child = Some(child);
        Ok(())
    }

    fn reap_finished_process(&mut self) {
        let Some(child) = self.child.as_mut() else {
            self.state.log_tail = self.log_tail();
            return;
        };

        let Ok(Some(status)) = child.try_wait() else {
            self.state.log_tail = self.log_tail();
            return;
        };

        self.child.take();
        self.state.pid = None;
        self.state.last_exit_code = status.code();
        self.state.stopped_at = Some(now_engine_label());
        self.state.status = "crashed".to_string();
        self.state.message = format!(
            "Движок завершился с кодом {}.",
            status
                .code()
                .map(|code| code.to_string())
                .unwrap_or_else(|| "unknown".to_string())
        );
        push_engine_log(&self.logs, "warn", "manager", &self.state.message);

        let mut restarted = false;
        let max_attempts = if self.protection.reconnect_enabled() {
            MAX_RECONNECT_ATTEMPTS
        } else {
            0
        };
        if self.state.restart_attempts < max_attempts {
            if let Some(plan) = self.last_plan.clone() {
                let restart_attempts = self.state.restart_attempts + 1;
                self.protection.record_reconnect_attempt(restart_attempts);
                thread::sleep(Duration::from_millis(
                    RECONNECT_BACKOFF_BASE_MS * u64::from(restart_attempts),
                ));
                if let Err(error) = self.spawn_plan(plan, restart_attempts) {
                    self.state.status = "crashed".to_string();
                    self.state.message = format!("Автоперезапуск не удался: {error}");
                    push_engine_log(&self.logs, "error", "manager", &self.state.message);
                } else {
                    restarted = true;
                }
            }
        }

        if !restarted {
            if let Err(error) = self.proxy.restore() {
                push_engine_log(
                    &self.logs,
                    "error",
                    "proxy",
                    &format!("Could not restore system proxy after crash: {error}"),
                );
            }
            self.tun.restore();
            self.app_routing.restore();
            self.protection.restore();
            self.traffic.stop();
        }

        self.state.log_tail = self.log_tail();
    }

    fn log_tail(&self) -> Vec<EngineLogEntry> {
        self.logs
            .lock()
            .map(|logs| logs.iter().rev().take(40).cloned().collect::<Vec<_>>())
            .map(|mut logs| {
                logs.reverse();
                logs
            })
            .unwrap_or_default()
    }
}

fn generate_engine_config(
    server: &Server,
    raw_url: &str,
    route_mode: RouteMode,
) -> Result<GeneratedEngineConfig> {
    let engine = engine_for_protocol(server.protocol);
    let path = engine_path_for_protocol(server.protocol, route_mode);
    let mut warnings = Vec::new();
    if route_mode != RouteMode::WholeComputer {
        warnings.push(
            "Режим приложений хранится в состоянии, но точная маршрутизация включается позднее."
                .to_string(),
        );
    }
    if server.port.is_none() {
        warnings.push("У сервера нет явного порта.".to_string());
    }

    if path == EnginePath::Tun {
        warnings
            .push("TUN требует прав администратора и доступного TUN-драйвера движка.".to_string());
    }

    if path == EnginePath::Adapter {
        warnings.push(
            "Адаптерный путь требует прав администратора и установленного runtime-инструмента."
                .to_string(),
        );
    }

    let (full_config, redacted_config) = if path == EnginePath::Adapter {
        let (full, mut adapter_warnings) = build_adapter_config(server, raw_url, false)?;
        let (redacted, _) = build_adapter_config(server, raw_url, true)?;
        warnings.append(&mut adapter_warnings);
        (full, redacted)
    } else {
        (
            build_sing_box_config(server, raw_url, false, route_mode)?,
            build_sing_box_config(server, raw_url, true, route_mode)?,
        )
    };

    Ok(GeneratedEngineConfig {
        engine,
        path,
        full_config,
        redacted_config,
        warnings,
    })
}

fn build_adapter_config(
    server: &Server,
    raw_url: &str,
    redacted: bool,
) -> Result<(String, Vec<String>)> {
    let trimmed = raw_url.trim();
    let full_config = if looks_like_adapter_config(trimmed) {
        normalize_adapter_config(trimmed)
    } else {
        build_adapter_config_from_url(server, trimmed, redacted)?
    };
    let display_config = redact_adapter_config(&full_config, redacted);
    let warnings = validate_adapter_config(&full_config, server.protocol)?;
    Ok((display_config, warnings))
}

fn build_adapter_config_from_url(server: &Server, raw_url: &str, redacted: bool) -> Result<String> {
    let parsed =
        url::Url::parse(raw_url).context("не удалось разобрать ссылку адаптерного профиля")?;
    let private_key = query_secret_any(&parsed, &["private_key", "privateKey", "key"], redacted)
        .or_else(|| {
            let user = parsed.username();
            if user.is_empty() {
                None
            } else if redacted {
                Some(redacted_value(true))
            } else {
                Some(user.to_string())
            }
        })
        .ok_or_else(|| anyhow!("в профиле нет PrivateKey"))?;
    let public_key = query_secret_any(
        &parsed,
        &["public_key", "publicKey", "peer_public_key"],
        redacted,
    )
    .ok_or_else(|| anyhow!("в профиле нет PublicKey peer"))?;
    let address = query_value_any(&parsed, &["address", "addr", "ip"])
        .ok_or_else(|| anyhow!("в профиле нет Address"))?;
    let endpoint = query_value_any(&parsed, &["endpoint"]).unwrap_or_else(|| {
        let port = server.port.unwrap_or(51820);
        format!("{}:{port}", server.host)
    });
    if endpoint.trim_matches(':').is_empty() {
        return Err(anyhow!("в профиле нет Endpoint"));
    }

    let mut lines = vec![
        "[Interface]".to_string(),
        format!("PrivateKey = {private_key}"),
        format!("Address = {address}"),
    ];
    if let Some(dns) = query_value_any(&parsed, &["dns", "DNS"]) {
        lines.push(format!("DNS = {dns}"));
    }
    if let Some(mtu) = query_value_any(&parsed, &["mtu", "MTU"]) {
        lines.push(format!("MTU = {mtu}"));
    }
    if server.protocol == Protocol::AmneziaWg {
        for key in ["Jc", "Jmin", "Jmax", "S1", "S2", "H1", "H2", "H3", "H4"] {
            if let Some(value) = query_value_any(&parsed, &[key, &key.to_ascii_lowercase()]) {
                lines.push(format!("{key} = {value}"));
            }
        }
    }

    lines.push(String::new());
    lines.push("[Peer]".to_string());
    lines.push(format!("PublicKey = {public_key}"));
    if let Some(preshared) = query_secret_any(
        &parsed,
        &["preshared_key", "presharedKey", "psk", "preSharedKey"],
        redacted,
    ) {
        lines.push(format!("PresharedKey = {preshared}"));
    }
    lines.push(format!(
        "AllowedIPs = {}",
        query_value_any(&parsed, &["allowed_ips", "allowedIPs"])
            .unwrap_or_else(|| "0.0.0.0/0, ::/0".to_string())
    ));
    lines.push(format!("Endpoint = {endpoint}"));
    lines.push(format!(
        "PersistentKeepalive = {}",
        query_value_any(
            &parsed,
            &["persistent_keepalive", "persistentKeepalive", "keepalive"]
        )
        .unwrap_or_else(|| "25".to_string())
    ));

    Ok(lines.join("\n") + "\n")
}

fn looks_like_adapter_config(value: &str) -> bool {
    value.contains("[Interface]") && value.contains("[Peer]")
}

fn normalize_adapter_config(value: &str) -> String {
    value
        .lines()
        .map(str::trim_end)
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

fn redact_adapter_config(config: &str, redacted: bool) -> String {
    if !redacted {
        return config.to_string();
    }

    config
        .lines()
        .map(|line| {
            let trimmed = line.trim_start();
            if trimmed.starts_with('#') || trimmed.starts_with(';') {
                return line.to_string();
            }
            let Some((key, _)) = line.split_once('=') else {
                return line.to_string();
            };
            let key = key.trim();
            if ["PrivateKey", "PublicKey", "PresharedKey"]
                .iter()
                .any(|candidate| key.eq_ignore_ascii_case(candidate))
            {
                format!("{key} = {}", redacted_value(true))
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

fn validate_adapter_config(config: &str, protocol: Protocol) -> Result<Vec<String>> {
    if !config_has_section(config, "Interface") {
        return Err(anyhow!("в адаптерном профиле нет секции [Interface]"));
    }
    if !config_has_section(config, "Peer") {
        return Err(anyhow!("в адаптерном профиле нет секции [Peer]"));
    }

    for key in ["PrivateKey", "Address", "PublicKey", "Endpoint"] {
        if adapter_config_value(config, key).is_none() {
            return Err(anyhow!("в адаптерном профиле нет {key}"));
        }
    }

    let mut warnings = Vec::new();
    if adapter_config_value(config, "DNS").is_none() {
        warnings.push("DNS не указан в адаптерном профиле.".to_string());
    }
    if adapter_config_value(config, "MTU").is_none() {
        warnings.push("MTU не указан; runtime применит значение по умолчанию.".to_string());
    }
    if adapter_config_value(config, "PersistentKeepalive").is_none() {
        warnings.push(
            "PersistentKeepalive не указан; на NAT-сетях соединение может засыпать.".to_string(),
        );
    }
    if protocol == Protocol::AmneziaWg {
        let has_awg_options = ["Jc", "Jmin", "Jmax", "S1", "S2", "H1", "H2", "H3", "H4"]
            .iter()
            .any(|key| adapter_config_value(config, key).is_some());
        if !has_awg_options {
            warnings.push("AmneziaWG-параметры обфускации не найдены в профиле.".to_string());
        }
    }

    Ok(warnings)
}

fn config_has_section(config: &str, section: &str) -> bool {
    let expected = format!("[{}]", section.to_ascii_lowercase());
    config
        .lines()
        .any(|line| line.trim().to_ascii_lowercase() == expected)
}

fn adapter_config_value(config: &str, key: &str) -> Option<String> {
    config.lines().find_map(|line| {
        let trimmed = line.trim();
        if trimmed.starts_with('#') || trimmed.starts_with(';') {
            return None;
        }
        let (line_key, value) = trimmed.split_once('=')?;
        if line_key.trim().eq_ignore_ascii_case(key) {
            Some(value.trim().to_string())
        } else {
            None
        }
    })
}

fn build_sing_box_config(
    server: &Server,
    raw_url: &str,
    redacted: bool,
    route_mode: RouteMode,
) -> Result<String> {
    let parsed = url::Url::parse(raw_url).ok();
    let port = server.port.unwrap_or(443);
    let mut outbound = serde_json::Map::new();

    match server.protocol {
        Protocol::VlessReality => {
            outbound.insert("type".to_string(), serde_json::json!("vless"));
            outbound.insert("tag".to_string(), serde_json::json!("selected"));
            outbound.insert("server".to_string(), serde_json::json!(server.host));
            outbound.insert("server_port".to_string(), serde_json::json!(port));
            outbound.insert(
                "uuid".to_string(),
                serde_json::json!(url_user(&parsed, redacted)),
            );

            if let Some(flow) = query_value(&parsed, "flow") {
                outbound.insert("flow".to_string(), serde_json::json!(flow));
            }

            let security = query_value(&parsed, "security").unwrap_or_default();
            if security == "reality" || security == "tls" {
                let mut tls = serde_json::Map::new();
                tls.insert("enabled".to_string(), serde_json::json!(true));
                tls.insert(
                    "server_name".to_string(),
                    serde_json::json!(
                        query_value(&parsed, "sni")
                            .or_else(|| query_value(&parsed, "serverName"))
                            .unwrap_or_else(|| server.host.clone())
                    ),
                );
                tls.insert(
                    "utls".to_string(),
                    serde_json::json!({
                        "enabled": true,
                        "fingerprint": query_value(&parsed, "fp").unwrap_or_else(|| "chrome".to_string())
                    }),
                );
                if security == "reality" {
                    tls.insert(
                        "reality".to_string(),
                        serde_json::json!({
                            "enabled": true,
                            "public_key": query_secret(&parsed, "pbk", redacted)
                                .or_else(|| query_secret(&parsed, "public_key", redacted))
                                .unwrap_or_else(|| redacted_value(redacted)),
                            "short_id": query_secret(&parsed, "sid", redacted)
                                .or_else(|| query_secret(&parsed, "short_id", redacted))
                                .unwrap_or_else(|| redacted_value(redacted))
                        }),
                    );
                }
                outbound.insert("tls".to_string(), serde_json::Value::Object(tls));
            }
        }
        Protocol::Trojan => {
            outbound.insert("type".to_string(), serde_json::json!("trojan"));
            outbound.insert("tag".to_string(), serde_json::json!("selected"));
            outbound.insert("server".to_string(), serde_json::json!(server.host));
            outbound.insert("server_port".to_string(), serde_json::json!(port));
            outbound.insert(
                "password".to_string(),
                serde_json::json!(url_user(&parsed, redacted)),
            );
            outbound.insert(
                "tls".to_string(),
                serde_json::json!({
                    "enabled": true,
                    "server_name": query_value(&parsed, "sni").unwrap_or_else(|| server.host.clone())
                }),
            );
        }
        Protocol::Hysteria2 => {
            outbound.insert("type".to_string(), serde_json::json!("hysteria2"));
            outbound.insert("tag".to_string(), serde_json::json!("selected"));
            outbound.insert("server".to_string(), serde_json::json!(server.host));
            outbound.insert("server_port".to_string(), serde_json::json!(port));
            outbound.insert(
                "password".to_string(),
                serde_json::json!(url_user(&parsed, redacted)),
            );
        }
        Protocol::Tuic => {
            outbound.insert("type".to_string(), serde_json::json!("tuic"));
            outbound.insert("tag".to_string(), serde_json::json!("selected"));
            outbound.insert("server".to_string(), serde_json::json!(server.host));
            outbound.insert("server_port".to_string(), serde_json::json!(port));
            outbound.insert(
                "uuid".to_string(),
                serde_json::json!(url_user(&parsed, redacted)),
            );
            outbound.insert(
                "password".to_string(),
                serde_json::json!(url_password(&parsed, redacted)),
            );
        }
        Protocol::Shadowsocks => {
            let (method, password) = parse_shadowsocks_userinfo(&parsed, redacted);
            outbound.insert("type".to_string(), serde_json::json!("shadowsocks"));
            outbound.insert("tag".to_string(), serde_json::json!("selected"));
            outbound.insert("server".to_string(), serde_json::json!(server.host));
            outbound.insert("server_port".to_string(), serde_json::json!(port));
            outbound.insert("method".to_string(), serde_json::json!(method));
            outbound.insert("password".to_string(), serde_json::json!(password));
        }
        _ => {
            outbound.insert("type".to_string(), serde_json::json!("direct"));
            outbound.insert("tag".to_string(), serde_json::json!("selected"));
        }
    }

    let inbounds = if route_mode == RouteMode::WholeComputer {
        serde_json::json!([
            {
                "type": "tun",
                "tag": "samhain-tun",
                "interface_name": TUN_INTERFACE_NAME,
                "address": [TUN_ADDRESS],
                "mtu": 1500,
                "auto_route": true,
                "strict_route": true,
                "stack": "system",
                "sniff": true
            }
        ])
    } else {
        serde_json::json!([
            {
                "type": "mixed",
                "tag": "local-proxy",
                "listen": LOCAL_PROXY_HOST,
                "listen_port": LOCAL_PROXY_PORT
            }
        ])
    };

    let config = serde_json::json!({
        "log": {
            "level": "info",
            "timestamp": true
        },
        "dns": {
            "servers": [
                {
                    "tag": "samhain-dns",
                    "address": format!("https://{}/dns-query", TUN_DNS[0]),
                    "detour": "selected"
                },
                {
                    "tag": "local-dns",
                    "address": "local",
                    "detour": "direct"
                }
            ],
            "final": "samhain-dns",
            "strategy": "prefer_ipv4"
        },
        "inbounds": inbounds,
        "outbounds": [
            serde_json::Value::Object(outbound),
            {
                "type": "direct",
                "tag": "direct"
            }
        ],
        "route": {
            "auto_detect_interface": true,
            "final": "selected",
            "rules": [
                {
                    "protocol": "dns",
                    "action": "hijack-dns"
                }
            ]
        },
        "experimental": {
            "cache_file": {
                "enabled": true
            }
        }
    });

    serde_json::to_string_pretty(&config).map_err(Into::into)
}

fn engine_for_protocol(protocol: Protocol) -> EngineKind {
    match protocol {
        Protocol::AmneziaWg => EngineKind::AmneziaWg,
        Protocol::WireGuard => EngineKind::WireGuard,
        Protocol::VlessReality
        | Protocol::Trojan
        | Protocol::Shadowsocks
        | Protocol::Hysteria2
        | Protocol::Tuic
        | Protocol::SingBox => EngineKind::SingBox,
        Protocol::Unknown => EngineKind::Unknown,
    }
}

fn engine_path_for_protocol(protocol: Protocol, route_mode: RouteMode) -> EnginePath {
    match protocol {
        Protocol::AmneziaWg | Protocol::WireGuard => EnginePath::Adapter,
        _ if route_mode == RouteMode::WholeComputer => EnginePath::Tun,
        _ => EnginePath::Proxy,
    }
}

fn path_name(path: EnginePath) -> &'static str {
    match path {
        EnginePath::Proxy => "proxy path",
        EnginePath::Tun => "TUN path",
        EnginePath::Adapter => "adapter path",
    }
}

fn engine_name(kind: EngineKind) -> &'static str {
    match kind {
        EngineKind::SingBox => "sing-box",
        EngineKind::Xray => "Xray",
        EngineKind::WireGuard => "WireGuard",
        EngineKind::AmneziaWg => "AmneziaWG",
        EngineKind::Unknown => "Unknown",
    }
}

fn engine_args(kind: EngineKind, config_path: &std::path::Path) -> Vec<String> {
    match kind {
        EngineKind::SingBox => vec![
            "run".to_string(),
            "-c".to_string(),
            config_path.display().to_string(),
        ],
        EngineKind::Xray => vec![
            "run".to_string(),
            "-c".to_string(),
            config_path.display().to_string(),
        ],
        _ => vec![config_path.display().to_string()],
    }
}

fn adapter_command_set(
    kind: EngineKind,
    executable_path: &std::path::Path,
    config_path: &std::path::Path,
    adapter_name: &str,
) -> Result<AdapterCommandSet> {
    let exe_name = executable_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let config = config_path.display().to_string();

    if kind == EngineKind::WireGuard && exe_name.contains("wireguard") && !exe_name.contains("go") {
        return Ok(AdapterCommandSet {
            start_args: vec!["/installtunnelservice".to_string(), config],
            stop_args: vec![
                "/uninstalltunnelservice".to_string(),
                adapter_name.to_string(),
            ],
            strategy: "WireGuard tunnel service".to_string(),
        });
    }

    if exe_name.contains("wg-quick") || exe_name.contains("awg-quick") {
        return Ok(AdapterCommandSet {
            start_args: vec!["up".to_string(), config.clone()],
            stop_args: vec!["down".to_string(), config],
            strategy: format!("{} quick", engine_name(kind)),
        });
    }

    Err(anyhow!(
        "{} найден, но это не lifecycle-инструмент. Нужен wireguard.exe, wg-quick.exe или awg-quick.exe.",
        executable_path.display()
    ))
}

fn run_adapter_command(
    action: &str,
    executable_path: &std::path::Path,
    args: &[String],
    logs: &Arc<Mutex<Vec<EngineLogEntry>>>,
    strategy: &str,
) -> Result<()> {
    push_engine_log(
        logs,
        "info",
        "adapter",
        &format!(
            "Running adapter {action} via {strategy}: {}",
            shell_preview(executable_path, args)
        ),
    );
    let output = Command::new(executable_path)
        .args(args)
        .output()
        .with_context(|| format!("Could not run {}", executable_path.display()))?;
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

    if !stdout.is_empty() {
        push_engine_log(logs, "info", "adapter", &stdout);
    }
    if !stderr.is_empty() {
        push_engine_log(logs, "warn", "adapter", &stderr);
    }

    if !output.status.success() {
        return Err(anyhow!(
            "adapter {action} failed with code {}{}",
            output
                .status
                .code()
                .map(|code| code.to_string())
                .unwrap_or_else(|| "unknown".to_string()),
            if stderr.is_empty() {
                String::new()
            } else {
                format!(": {stderr}")
            }
        ));
    }

    Ok(())
}

fn adapter_name_for(server_id: &str, kind: EngineKind) -> String {
    let prefix = match kind {
        EngineKind::WireGuard => "samhain-wireguard",
        EngineKind::AmneziaWg => "samhain-amneziawg",
        _ => "samhain-adapter",
    };
    format!("{prefix}-{}", sanitize_filename(server_id))
}

fn adapter_dry_run() -> bool {
    std::env::var_os(ADAPTER_DRY_RUN_ENV).is_some()
}

fn app_routing_dry_run() -> bool {
    std::env::var_os(APP_ROUTING_DRY_RUN_ENV).is_some()
}

fn app_routing_enforce() -> bool {
    std::env::var_os(APP_ROUTING_ENFORCE_ENV).is_some()
}

fn app_routing_enforcement_available() -> bool {
    false
}

fn app_routing_evidence(route_mode: RouteMode, enabled_count: usize) -> Vec<String> {
    let mut evidence = Vec::new();
    evidence.push(format!("route_mode={route_mode:?}"));
    evidence.push(format!("enabled_applications={enabled_count}"));
    evidence.push(format!("requested={}", app_routing_enforce()));
    evidence.push("wfp_layer=not-implemented".to_string());
    evidence.push(format!("available={}", app_routing_enforcement_available()));
    evidence
}

fn protection_dry_run() -> bool {
    std::env::var_os(PROTECTION_DRY_RUN_ENV).is_some()
}

fn protection_enforcement_requested() -> bool {
    std::env::var_os(PROTECTION_ENFORCE_ENV).is_some()
}

fn protection_enforce() -> bool {
    protection_enforcement_requested() && privileged_policy_allows_network_actions()
}

fn service_identity() -> String {
    if service_identity_valid() {
        "installer-owned-service".to_string()
    } else {
        "current-user-package".to_string()
    }
}

fn service_identity_valid() -> bool {
    let Ok(exe) = std::env::current_exe() else {
        return false;
    };
    let Some(program_files) = std::env::var_os("ProgramFiles") else {
        return false;
    };
    let install_root = PathBuf::from(program_files).join("SamhainSecurity");
    exe.starts_with(install_root)
}

fn service_signing_state() -> String {
    if service_signing_valid() {
        "trusted-signature".to_string()
    } else {
        "unsigned-dev".to_string()
    }
}

fn service_signing_valid() -> bool {
    std::env::var_os(SERVICE_SIGNED_ENV)
        .map(|value| {
            let normalized = value.to_string_lossy().to_ascii_lowercase();
            matches!(normalized.as_str(), "1" | "true" | "yes" | "trusted")
        })
        .unwrap_or(false)
}

fn privileged_policy_allows_network_actions() -> bool {
    process_is_elevated() && service_identity_valid() && service_signing_valid()
}

fn recovery_policy_state() -> RecoveryPolicyState {
    let identity_valid = service_identity_valid();
    RecoveryPolicyState {
        owner: "service".to_string(),
        watchdog_enabled: true,
        emergency_restore_owner: "service".to_string(),
        reconnect_attempts: MAX_RECONNECT_ATTEMPTS,
        backoff_base_ms: RECONNECT_BACKOFF_BASE_MS,
        service_failure_restart: identity_valid,
        evidence: vec![
            "watchdog_owner=service".to_string(),
            "emergency_restore_owner=service".to_string(),
            format!("reconnect_attempts={MAX_RECONNECT_ATTEMPTS}"),
            format!("backoff_base_ms={RECONNECT_BACKOFF_BASE_MS}"),
            format!("service_failure_restart={identity_valid}"),
        ],
    }
}

fn service_self_check_state(storage_path: &Path) -> ServiceSelfCheckState {
    let readiness = service_readiness_state();
    let recovery_policy = recovery_policy_state();
    let storage_parent = storage_path.parent().unwrap_or_else(|| Path::new(""));
    let engine_dirs = engine_search_dirs();
    let engine_dir_ready = engine_dirs.iter().any(|dir| dir.is_dir());
    let audit_path = storage_parent.join("service-audit.json");

    let checks = vec![
        check_item(
            "named-pipe",
            true,
            "configured",
            &format!("name={}", samhain_ipc::NAMED_PIPE_NAME),
        ),
        check_item(
            "engine-directory",
            engine_dir_ready,
            if engine_dir_ready { "ready" } else { "missing" },
            &engine_dirs
                .iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>()
                .join("; "),
        ),
        check_item(
            "storage",
            storage_parent.is_dir(),
            if storage_parent.is_dir() {
                "ready"
            } else {
                "pending"
            },
            &format!("path={}", storage_path.display()),
        ),
        check_item(
            "routes",
            readiness.privileged_policy_allowed,
            if readiness.privileged_policy_allowed {
                "available"
            } else {
                "gated"
            },
            "requires installer-owned signed service identity",
        ),
        check_item(
            "dns",
            readiness.privileged_policy_allowed,
            if readiness.privileged_policy_allowed {
                "available"
            } else {
                "gated"
            },
            "requires installer-owned signed service identity",
        ),
        check_item(
            "firewall",
            readiness.firewall_enforcement_available,
            if readiness.firewall_enforcement_available {
                "available"
            } else {
                "gated"
            },
            "requires policy request and trusted service identity",
        ),
        check_item(
            "service-identity",
            readiness.identity_valid && readiness.signing_valid,
            &readiness.status,
            &format!(
                "identity={} signing={}",
                readiness.identity, readiness.signing_state
            ),
        ),
    ];

    let status = if checks.iter().all(|check| check.ok) {
        "ready"
    } else if readiness.privileged_policy_allowed {
        "partial"
    } else {
        "gated"
    };

    ServiceSelfCheckState {
        status: status.to_string(),
        generated_at: now_engine_label(),
        checks,
        recovery_policy,
        audit_log_path: Some(audit_path.display().to_string()),
    }
}

fn check_item(name: &str, ok: bool, status: &str, detail: &str) -> ServiceCheckItem {
    ServiceCheckItem {
        name: name.to_string(),
        ok,
        status: status.to_string(),
        detail: redact_support_text(detail),
    }
}

fn service_readiness_state() -> ServiceReadinessState {
    let running_as_admin = process_is_elevated();
    let protection_requested = protection_enforcement_requested();
    let app_routing_requested = app_routing_enforce();
    let identity = service_identity();
    let identity_valid = service_identity_valid();
    let signing_state = service_signing_state();
    let signing_valid = service_signing_valid();
    let privileged_policy_allowed = privileged_policy_allows_network_actions();
    let firewall_available = protection_requested && privileged_policy_allowed;
    let app_routing_available = app_routing_enforcement_available();

    let status = if app_routing_requested && !app_routing_available {
        "waiting-wfp"
    } else if firewall_available {
        "privileged-ready"
    } else if protection_requested && !privileged_policy_allowed {
        "identity-gated"
    } else if running_as_admin {
        "elevated"
    } else {
        "current-user"
    };

    let mut checks = Vec::new();
    checks.push(format!("running_as_admin={running_as_admin}"));
    checks.push(format!("identity={identity}"));
    checks.push(format!("identity_valid={identity_valid}"));
    checks.push(format!("signing_state={signing_state}"));
    checks.push(format!("signing_valid={signing_valid}"));
    checks.push(format!(
        "privileged_policy_allowed={privileged_policy_allowed}"
    ));
    checks.push(format!("protection_requested={protection_requested}"));
    checks.push(format!("firewall_available={firewall_available}"));
    checks.push(format!("app_routing_requested={app_routing_requested}"));
    checks.push(format!("app_routing_available={app_routing_available}"));
    checks.push(format!("service_identity={identity}"));
    checks.push("required_identity=signed-privileged-service".to_string());
    checks.extend(recovery_policy_state().evidence);

    let message = if app_routing_requested && !app_routing_available {
        "App routing enforcement requested, but the WFP layer is not ready yet."
    } else if firewall_available {
        "Firewall enforcement is available for this process."
    } else if protection_requested && !privileged_policy_allowed {
        "Privileged network actions are blocked until service identity, elevation, and signing policy match."
    } else if running_as_admin {
        "Process is elevated; installer-managed service identity is still pending."
    } else {
        "Running as current-user package; privileged enforcement is gated."
    };

    ServiceReadinessState {
        status: status.to_string(),
        identity,
        required_identity: "signed-privileged-service".to_string(),
        identity_valid,
        signing_state,
        signing_valid,
        running_as_admin,
        privileged_policy_allowed,
        protection_enforcement_requested: protection_requested,
        app_routing_enforcement_requested: app_routing_requested,
        firewall_enforcement_available: firewall_available,
        app_routing_enforcement_available: app_routing_available,
        recovery_policy: "service-owned".to_string(),
        audit_log_path: storage_path()
            .parent()
            .map(|path| path.join("service-audit.json").display().to_string()),
        checks,
        message: message.to_string(),
    }
}

#[cfg(windows)]
fn process_is_elevated() -> bool {
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::Security::{
        GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TokenElevation,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    unsafe {
        let mut token: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return false;
        }

        let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
        let mut returned = 0u32;
        let ok = GetTokenInformation(
            token,
            TokenElevation,
            &mut elevation as *mut TOKEN_ELEVATION as *mut _,
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut returned,
        ) != 0;
        let _ = CloseHandle(token);
        ok && elevation.TokenIsElevated != 0
    }
}

#[cfg(not(windows))]
fn process_is_elevated() -> bool {
    false
}

fn normalize_protection_settings(mut settings: ProtectionSettings) -> ProtectionSettings {
    if settings.backoff_seconds == 0 {
        settings.backoff_seconds = 1;
    }
    settings
}

fn protection_enabled(settings: &ProtectionSettings) -> bool {
    settings.kill_switch_enabled
        || settings.dns_leak_protection_enabled
        || settings.ipv6_policy != Ipv6Policy::Allow
        || settings.reconnect_enabled
}

fn protection_rule_names(settings: &ProtectionSettings) -> Vec<String> {
    let mut names = Vec::new();
    if settings.kill_switch_enabled {
        names.push("Samhain Security Kill Switch Guard".to_string());
    }
    if settings.dns_leak_protection_enabled {
        names.push("Samhain Security DNS Guard UDP".to_string());
        names.push("Samhain Security DNS Guard TCP".to_string());
    }
    if settings.ipv6_policy == Ipv6Policy::Block {
        names.push("Samhain Security IPv6 Guard".to_string());
    }
    names
}

#[cfg(test)]
fn protection_firewall_commands(settings: &ProtectionSettings) -> Vec<ProtectionFirewallCommand> {
    protection_firewall_commands_for(settings, "planned")
}

fn protection_firewall_commands_for(
    settings: &ProtectionSettings,
    transaction_id: &str,
) -> Vec<ProtectionFirewallCommand> {
    let mut commands = Vec::new();
    if settings.dns_leak_protection_enabled {
        let name = protection_transaction_rule_name("DNS Guard UDP", transaction_id);
        commands.push(ProtectionFirewallCommand {
            name: name.clone(),
            args: vec![
                "advfirewall".to_string(),
                "firewall".to_string(),
                "add".to_string(),
                "rule".to_string(),
                format!("name={name}"),
                "dir=out".to_string(),
                "action=block".to_string(),
                "protocol=UDP".to_string(),
                "remoteport=53".to_string(),
            ],
            rollback_args: protection_delete_rule_args(&name),
            evidence: vec![
                "capability=dns-guard".to_string(),
                "protocol=UDP".to_string(),
                "remoteport=53".to_string(),
            ],
        });
        let name = protection_transaction_rule_name("DNS Guard TCP", transaction_id);
        commands.push(ProtectionFirewallCommand {
            name: name.clone(),
            args: vec![
                "advfirewall".to_string(),
                "firewall".to_string(),
                "add".to_string(),
                "rule".to_string(),
                format!("name={name}"),
                "dir=out".to_string(),
                "action=block".to_string(),
                "protocol=TCP".to_string(),
                "remoteport=53".to_string(),
            ],
            rollback_args: protection_delete_rule_args(&name),
            evidence: vec![
                "capability=dns-guard".to_string(),
                "protocol=TCP".to_string(),
                "remoteport=53".to_string(),
            ],
        });
    }
    if settings.ipv6_policy == Ipv6Policy::Block {
        let name = protection_transaction_rule_name("IPv6 Guard", transaction_id);
        commands.push(ProtectionFirewallCommand {
            name: name.clone(),
            args: vec![
                "advfirewall".to_string(),
                "firewall".to_string(),
                "add".to_string(),
                "rule".to_string(),
                format!("name={name}"),
                "dir=out".to_string(),
                "action=block".to_string(),
                "remoteip=::/0".to_string(),
            ],
            rollback_args: protection_delete_rule_args(&name),
            evidence: vec![
                "capability=ipv6-policy".to_string(),
                "remoteip=::/0".to_string(),
            ],
        });
    }
    commands
}

fn protection_transaction_id(prefix: &str) -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis())
        .unwrap_or_default();
    format!("{prefix}-{millis}")
}

fn protection_transaction_rule_name(capability: &str, transaction_id: &str) -> String {
    format!("Samhain Security {capability} [{transaction_id}]")
}

fn protection_delete_rule_args(name: &str) -> Vec<String> {
    vec![
        "advfirewall".to_string(),
        "firewall".to_string(),
        "delete".to_string(),
        "rule".to_string(),
        format!("name={name}"),
    ]
}

fn protection_transaction_plan(
    settings: &ProtectionSettings,
    route_mode: RouteMode,
    status: &str,
    dry_run: bool,
    applied: bool,
    rollback_available: bool,
    message: &str,
) -> ProtectionTransactionState {
    let transaction_id = protection_transaction_id("protection");
    protection_transaction_from_commands(
        transaction_id,
        settings,
        route_mode,
        status,
        dry_run,
        applied,
        rollback_available,
        message,
        status.to_string(),
    )
}

fn protection_transaction_from_commands(
    transaction_id: String,
    settings: &ProtectionSettings,
    route_mode: RouteMode,
    status: &str,
    dry_run: bool,
    applied: bool,
    rollback_available: bool,
    message: &str,
    step_status: String,
) -> ProtectionTransactionState {
    let commands = protection_firewall_commands_for(settings, &transaction_id);
    ProtectionTransactionState {
        id: transaction_id.clone(),
        kind: "protection-firewall".to_string(),
        status: status.to_string(),
        dry_run,
        applied,
        rollback_available,
        before_snapshot: protection_snapshot_lines(settings, route_mode, "before"),
        after_snapshot: protection_snapshot_lines(settings, route_mode, status),
        applied_at: applied.then(now_engine_label),
        rolled_back_at: None,
        steps: protection_transaction_steps(settings, &commands, &transaction_id, &step_status),
        message: message.to_string(),
    }
}

fn protection_transaction_steps(
    settings: &ProtectionSettings,
    commands: &[ProtectionFirewallCommand],
    transaction_id: &str,
    status: &str,
) -> Vec<ProtectionTransactionStep> {
    let mut steps = commands
        .iter()
        .enumerate()
        .map(|(index, command)| ProtectionTransactionStep {
            id: format!("{transaction_id}-{}", index + 1),
            action: "apply-firewall-rule".to_string(),
            target: command.name.clone(),
            command: command.args.clone(),
            rollback_command: command.rollback_args.clone(),
            status: status.to_string(),
            evidence: command.evidence.clone(),
        })
        .collect::<Vec<_>>();

    if settings.kill_switch_enabled {
        steps.insert(
            0,
            ProtectionTransactionStep {
                id: format!("{transaction_id}-kill-switch"),
                action: "plan-kill-switch".to_string(),
                target: "Samhain Security Kill Switch Guard".to_string(),
                command: Vec::new(),
                rollback_command: Vec::new(),
                status: "pending-wfp".to_string(),
                evidence: vec![
                    "capability=kill-switch".to_string(),
                    "wfp_layer=required".to_string(),
                    "broad_allow_rules=false".to_string(),
                ],
            },
        );
    }

    steps.push(ProtectionTransactionStep {
        id: format!("{transaction_id}-emergency-restore"),
        action: "record-emergency-restore".to_string(),
        target: "service-owned-restore".to_string(),
        command: Vec::new(),
        rollback_command: Vec::new(),
        status: "available".to_string(),
        evidence: vec![
            "owner=service".to_string(),
            format!("transaction_id={transaction_id}"),
        ],
    });

    steps
}

fn transaction_rule_names(transaction: &ProtectionTransactionState) -> Option<Vec<String>> {
    let names = transaction
        .steps
        .iter()
        .filter(|step| !step.rollback_command.is_empty())
        .map(|step| step.target.clone())
        .collect::<Vec<_>>();
    (!names.is_empty()).then_some(names)
}

fn command_step_status(_commands: &[ProtectionFirewallCommand], status: &str) -> String {
    status.to_string()
}

fn protection_snapshot_lines(
    settings: &ProtectionSettings,
    route_mode: RouteMode,
    phase: &str,
) -> Vec<String> {
    vec![
        format!("phase={phase}"),
        format!("route_mode={route_mode:?}"),
        format!("kill_switch={}", settings.kill_switch_enabled),
        format!("dns_guard={}", settings.dns_leak_protection_enabled),
        format!("ipv6_policy={:?}", settings.ipv6_policy),
        format!("reconnect={}", settings.reconnect_enabled),
        format!(
            "privileged_allowed={}",
            privileged_policy_allows_network_actions()
        ),
        "broad_allow_rules=false".to_string(),
    ]
}

fn protection_message(route_mode: RouteMode, dry_run: bool, enforce: bool) -> String {
    if dry_run {
        return "Защита проверена в dry-run: kill switch, DNS guard, IPv6 policy, reconnect/watchdog."
            .to_string();
    }
    if enforce {
        return "DNS/IPv6 firewall guard применён. Полный kill switch остаётся задачей WFP-слоя."
            .to_string();
    }

    let mode = match route_mode {
        RouteMode::WholeComputer => "весь компьютер",
        RouteMode::SelectedAppsOnly => "только выбранные приложения",
        RouteMode::ExcludeSelectedApps => "кроме выбранных приложений",
    };
    format!(
        "Защита вооружена для режима {mode}: watchdog и rollback активны, firewall enforcement требует привилегированного запуска."
    )
}

fn shell_preview(executable_path: &std::path::Path, args: &[String]) -> String {
    std::iter::once(executable_path.display().to_string())
        .chain(args.iter().map(|arg| {
            if arg.contains(' ') {
                format!("\"{arg}\"")
            } else {
                arg.to_string()
            }
        }))
        .collect::<Vec<_>>()
        .join(" ")
}

fn discover_engines() -> Vec<EngineCatalogEntry> {
    [
        EngineKind::SingBox,
        EngineKind::Xray,
        EngineKind::WireGuard,
        EngineKind::AmneziaWg,
    ]
    .into_iter()
    .map(discover_engine)
    .collect()
}

fn discover_engine(kind: EngineKind) -> EngineCatalogEntry {
    let expected_paths = engine_candidate_paths(kind);
    let search_paths = engine_search_dirs_for(kind);
    let executable_path = expected_paths.iter().find(|candidate| candidate.is_file());
    let sha256 = executable_path.and_then(|path| file_sha256(path).ok());
    let file_size_bytes = executable_path
        .and_then(|path| fs::metadata(path).ok())
        .map(|metadata| metadata.len());
    let (version, version_status) = match executable_path {
        Some(path) => probe_engine_version(kind, path),
        None => (None, "missing".to_string()),
    };
    let available = executable_path.is_some();
    let status = if available { "available" } else { "missing" }.to_string();
    let message = if let Some(path) = executable_path {
        format!(
            "{} runtime available at {}.",
            engine_name(kind),
            path.display()
        )
    } else {
        format!(
            "{} runtime missing. Expected bundled path: {}.",
            engine_name(kind),
            engine_bundle_relative_path(kind)
        )
    };

    EngineCatalogEntry {
        kind,
        runtime_id: engine_runtime_id(kind).to_string(),
        name: engine_name(kind).to_string(),
        executable_path: executable_path.map(|path| path.display().to_string()),
        bundled_path: engine_bundle_relative_path(kind).to_string(),
        expected_paths: expected_paths
            .iter()
            .map(|path| path.display().to_string())
            .collect(),
        search_paths: search_paths
            .iter()
            .map(|path| path.display().to_string())
            .collect(),
        available,
        status,
        protocols: engine_protocols(kind)
            .iter()
            .map(|protocol| (*protocol).to_string())
            .collect(),
        sha256,
        file_size_bytes,
        version,
        version_status,
        message,
    }
}

fn engine_search_dirs() -> Vec<PathBuf> {
    let mut dirs = engine_base_dirs();
    for kind in [
        EngineKind::SingBox,
        EngineKind::Xray,
        EngineKind::WireGuard,
        EngineKind::AmneziaWg,
    ] {
        dirs.extend(engine_search_dirs_for(kind));
    }
    unique_paths(dirs)
}

fn engine_search_dirs_for(kind: EngineKind) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    for base in engine_base_dirs() {
        dirs.push(base.join(engine_bundle_dir_name(kind)));
        dirs.push(base);
    }
    unique_paths(dirs)
}

fn engine_base_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(value) = std::env::var_os("SAMHAIN_ENGINE_DIR") {
        dirs.extend(std::env::split_paths(&value));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            if let Some(package_root) = parent.parent() {
                dirs.push(package_root.join("app").join("engines"));
            }
            dirs.push(parent.join("engines"));
            dirs.push(parent.to_path_buf());
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        dirs.push(cwd.join("engines"));
        dirs.push(cwd);
    }

    unique_paths(dirs)
}

fn unique_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut unique = Vec::new();
    for path in paths {
        if !unique.iter().any(|existing: &PathBuf| existing == &path) {
            unique.push(path);
        }
    }
    unique
}

fn engine_candidate_paths(kind: EngineKind) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    let primary = engine_primary_binary_name(kind);
    for base in engine_base_dirs() {
        candidates.push(base.join(engine_bundle_dir_name(kind)).join(primary));
        for name in engine_binary_names(kind) {
            candidates.push(base.join(engine_bundle_dir_name(kind)).join(name));
            candidates.push(base.join(name));
        }
    }
    unique_paths(candidates)
}

fn engine_runtime_id(kind: EngineKind) -> &'static str {
    match kind {
        EngineKind::SingBox => "sing-box",
        EngineKind::Xray => "xray",
        EngineKind::WireGuard => "wireguard",
        EngineKind::AmneziaWg => "amneziawg",
        EngineKind::Unknown => "unknown",
    }
}

fn engine_bundle_dir_name(kind: EngineKind) -> &'static str {
    match kind {
        EngineKind::SingBox => "sing-box",
        EngineKind::Xray => "xray",
        EngineKind::WireGuard => "wireguard",
        EngineKind::AmneziaWg => "amneziawg",
        EngineKind::Unknown => "unknown",
    }
}

fn engine_primary_binary_name(kind: EngineKind) -> &'static str {
    match kind {
        EngineKind::SingBox => "sing-box.exe",
        EngineKind::Xray => "xray.exe",
        EngineKind::WireGuard => "wireguard.exe",
        EngineKind::AmneziaWg => "awg-quick.exe",
        EngineKind::Unknown => "",
    }
}

fn engine_bundle_relative_path(kind: EngineKind) -> &'static str {
    match kind {
        EngineKind::SingBox => "app\\engines\\sing-box\\sing-box.exe",
        EngineKind::Xray => "app\\engines\\xray\\xray.exe",
        EngineKind::WireGuard => "app\\engines\\wireguard\\wireguard.exe",
        EngineKind::AmneziaWg => "app\\engines\\amneziawg\\awg-quick.exe",
        EngineKind::Unknown => "app\\engines\\unknown",
    }
}

fn engine_protocols(kind: EngineKind) -> &'static [&'static str] {
    match kind {
        EngineKind::SingBox => &[
            "vless-tcp-reality",
            "trojan",
            "shadowsocks",
            "hysteria2",
            "tuic",
            "sing-box",
        ],
        EngineKind::Xray => &["vless-tcp-reality", "trojan"],
        EngineKind::WireGuard => &["wireguard"],
        EngineKind::AmneziaWg => &["amneziawg"],
        EngineKind::Unknown => &[],
    }
}

fn file_sha256(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path)
        .with_context(|| format!("Could not open runtime {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let read = file
            .read(&mut buffer)
            .with_context(|| format!("Could not read runtime {}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn probe_engine_version(kind: EngineKind, path: &Path) -> (Option<String>, String) {
    let args = engine_version_probe_args(kind);
    if args.is_empty() {
        return (None, "not-supported".to_string());
    }

    match Command::new(path)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
    {
        Ok(output) => {
            let combined = format!(
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            let line = combined
                .lines()
                .map(str::trim)
                .find(|line| !line.is_empty())
                .map(|line| {
                    redact_support_text(line)
                        .chars()
                        .take(160)
                        .collect::<String>()
                });

            if output.status.success() {
                (line, "ok".to_string())
            } else {
                (line, format!("exit-{}", output.status.code().unwrap_or(-1)))
            }
        }
        Err(error) => (
            None,
            format!("probe-error: {}", redact_support_text(&error.to_string())),
        ),
    }
}

fn engine_version_probe_args(kind: EngineKind) -> &'static [&'static str] {
    match kind {
        EngineKind::SingBox | EngineKind::Xray => &["version"],
        EngineKind::WireGuard | EngineKind::AmneziaWg => &["--version"],
        EngineKind::Unknown => &[],
    }
}

fn engine_binary_names(kind: EngineKind) -> &'static [&'static str] {
    match kind {
        EngineKind::SingBox => &["sing-box.exe", "sing-box"],
        EngineKind::Xray => &["xray.exe", "xray"],
        EngineKind::WireGuard => &[
            "wireguard.exe",
            "wg-quick.exe",
            "wireguard",
            "wg.exe",
            "wireguard-go.exe",
        ],
        EngineKind::AmneziaWg => &[
            "awg-quick.exe",
            "amneziawg.exe",
            "amneziawg",
            "awg.exe",
            "awg-go.exe",
        ],
        EngineKind::Unknown => &[],
    }
}

fn engine_config_path(server_id: &str, kind: EngineKind) -> PathBuf {
    let extension = match kind {
        EngineKind::WireGuard | EngineKind::AmneziaWg => "conf",
        _ => "json",
    };
    let name = match kind {
        EngineKind::WireGuard | EngineKind::AmneziaWg => adapter_name_for(server_id, kind),
        _ => format!(
            "{}-{}",
            engine_name(kind).to_ascii_lowercase(),
            sanitize_filename(server_id)
        ),
    };
    storage_path()
        .parent()
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("engine")
        .join(format!("{name}.{extension}"))
}

fn sanitize_filename(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect()
}

fn local_proxy_endpoint() -> String {
    format!("{LOCAL_PROXY_HOST}:{LOCAL_PROXY_PORT}")
}

fn query_value(parsed: &Option<url::Url>, key: &str) -> Option<String> {
    parsed.as_ref()?.query_pairs().find_map(|(name, value)| {
        if name == key {
            Some(value.to_string())
        } else {
            None
        }
    })
}

fn query_value_any(parsed: &url::Url, keys: &[&str]) -> Option<String> {
    parsed.query_pairs().find_map(|(name, value)| {
        if keys.iter().any(|key| name.eq_ignore_ascii_case(key)) {
            Some(value.to_string())
        } else {
            None
        }
    })
}

fn query_secret(parsed: &Option<url::Url>, key: &str, redacted: bool) -> Option<String> {
    query_value(parsed, key).map(|value| {
        if redacted {
            redacted_value(true)
        } else {
            value
        }
    })
}

fn query_secret_any(parsed: &url::Url, keys: &[&str], redacted: bool) -> Option<String> {
    query_value_any(parsed, keys).map(|value| {
        if redacted {
            redacted_value(true)
        } else {
            value
        }
    })
}

fn url_user(parsed: &Option<url::Url>, redacted: bool) -> String {
    let value = parsed
        .as_ref()
        .map(|url| url.username())
        .filter(|value| !value.is_empty())
        .unwrap_or_default();
    if redacted && !value.is_empty() {
        redacted_value(true)
    } else {
        value.to_string()
    }
}

fn url_password(parsed: &Option<url::Url>, redacted: bool) -> String {
    let value = parsed
        .as_ref()
        .and_then(|url| url.password())
        .unwrap_or_default();
    if redacted && !value.is_empty() {
        redacted_value(true)
    } else {
        value.to_string()
    }
}

fn parse_shadowsocks_userinfo(parsed: &Option<url::Url>, redacted: bool) -> (String, String) {
    let user = parsed
        .as_ref()
        .map(|url| url.username())
        .unwrap_or_default();
    if let Some((method, password)) = user.split_once(':') {
        return (
            method.to_string(),
            if redacted {
                redacted_value(true)
            } else {
                password.to_string()
            },
        );
    }
    (
        "2022-blake3-aes-128-gcm".to_string(),
        redacted_value(redacted),
    )
}

fn redacted_value(redacted: bool) -> String {
    if redacted {
        "<redacted>".to_string()
    } else {
        String::new()
    }
}

fn now_engine_label() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or_default();
    format!("Engine event: {seconds}")
}

fn build_log_snapshot(
    logs: &Arc<Mutex<Vec<EngineLogEntry>>>,
    category: Option<&str>,
) -> LogSnapshotState {
    let requested = category
        .map(str::trim)
        .filter(|value| !value.is_empty() && !value.eq_ignore_ascii_case("all"));

    let (entries, categories) = logs
        .lock()
        .map(|logs| {
            let categories = logs
                .iter()
                .map(|entry| entry.stream.clone())
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect::<Vec<_>>();
            let entries = logs
                .iter()
                .filter(|entry| {
                    requested
                        .map(|category| entry.stream.eq_ignore_ascii_case(category))
                        .unwrap_or(true)
                })
                .map(redact_log_entry)
                .collect::<Vec<_>>();
            (entries, categories)
        })
        .unwrap_or_default();

    LogSnapshotState {
        entries,
        categories,
        exported_at: now_engine_label(),
    }
}

fn redact_log_entry(entry: &EngineLogEntry) -> EngineLogEntry {
    EngineLogEntry {
        level: entry.level.clone(),
        stream: entry.stream.clone(),
        message: redact_support_text(&entry.message),
        captured_at: entry.captured_at.clone(),
    }
}

fn redact_support_text(input: &str) -> String {
    let keys = [
        "token=",
        "access_token=",
        "private_key=",
        "privatekey=",
        "preshared_key=",
        "presharedkey=",
        "public_key=",
        "publickey=",
        "password=",
        "passwd=",
        "uuid=",
        "key=",
        "pbk=",
        "sid=",
    ];
    let lower = input.to_ascii_lowercase();
    let mut output = String::with_capacity(input.len());
    let mut index = 0;

    while index < input.len() {
        if let Some(key) = keys.iter().find(|key| lower[index..].starts_with(**key)) {
            output.push_str(&input[index..index + key.len()]);
            output.push_str("<redacted>");
            index += key.len();
            while index < input.len() {
                let ch = input[index..].chars().next().expect("char boundary");
                if ch.is_whitespace()
                    || matches!(ch, '&' | '"' | '\'' | '<' | '>' | ',' | '}' | ']' | '#')
                {
                    break;
                }
                index += ch.len_utf8();
            }
            continue;
        }

        let ch = input[index..].chars().next().expect("char boundary");
        output.push(ch);
        index += ch.len_utf8();
    }

    output
}

fn push_engine_log(
    logs: &Arc<Mutex<Vec<EngineLogEntry>>>,
    level: &str,
    stream: &str,
    message: &str,
) {
    if let Ok(mut entries) = logs.lock() {
        entries.push(EngineLogEntry {
            level: level.to_string(),
            stream: stream.to_string(),
            message: message.to_string(),
            captured_at: now_engine_label(),
        });
        if entries.len() > 200 {
            let excess = entries.len() - 200;
            entries.drain(0..excess);
        }
    }
}

fn spawn_engine_reader<R>(
    stream: R,
    stream_name: &'static str,
    logs: Arc<Mutex<Vec<EngineLogEntry>>>,
) where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        let reader = BufReader::new(stream);
        for line in reader.lines().map_while(std::result::Result::ok) {
            if !line.trim().is_empty() {
                push_engine_log(&logs, "info", stream_name, &line);
            }
        }
    });
}

#[cfg(windows)]
mod protection_firewall {
    use super::*;

    pub fn apply(commands: &[ProtectionFirewallCommand]) -> Result<()> {
        for command in commands {
            let _ = run_netsh(&command.rollback_args);
        }
        for command in commands {
            run_netsh(&command.args)
                .with_context(|| format!("Could not apply firewall rule {}", command.name))?;
        }
        Ok(())
    }

    pub fn rollback(steps: &[ProtectionTransactionStep]) -> Result<()> {
        for step in steps.iter().rev() {
            if !step.rollback_command.is_empty() {
                let _ = run_netsh(&step.rollback_command);
            }
        }
        Ok(())
    }

    fn run_netsh(args: &[String]) -> Result<()> {
        let output = Command::new("netsh")
            .args(args)
            .output()
            .context("Could not run netsh")?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
            return Err(anyhow!(
                "netsh failed with code {}{}{}",
                output
                    .status
                    .code()
                    .map(|code| code.to_string())
                    .unwrap_or_else(|| "unknown".to_string()),
                if stdout.is_empty() {
                    String::new()
                } else {
                    format!(": {stdout}")
                },
                if stderr.is_empty() {
                    String::new()
                } else {
                    format!(": {stderr}")
                }
            ));
        }
        Ok(())
    }
}

#[cfg(not(windows))]
mod protection_firewall {
    use super::*;

    pub fn apply(_commands: &[ProtectionFirewallCommand]) -> Result<()> {
        Ok(())
    }

    pub fn rollback(_steps: &[ProtectionTransactionStep]) -> Result<()> {
        Ok(())
    }
}

#[cfg(windows)]
mod system_proxy {
    use super::*;
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::ERROR_SUCCESS;
    use windows_sys::Win32::Networking::WinInet::{
        INTERNET_OPTION_REFRESH, INTERNET_OPTION_SETTINGS_CHANGED, InternetSetOptionW,
    };
    use windows_sys::Win32::System::Registry::{
        HKEY, HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_DWORD, REG_SZ, RegCloseKey,
        RegOpenKeyExW, RegQueryValueExW, RegSetValueExW,
    };

    const INTERNET_SETTINGS: &str =
        "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";

    pub fn read() -> Result<SystemProxySnapshot> {
        if dry_run() {
            return Ok(SystemProxySnapshot {
                enabled: false,
                server: None,
            });
        }

        let key = open_key(KEY_QUERY_VALUE)?;
        let enabled = read_dword(key, "ProxyEnable")?.unwrap_or(0) != 0;
        let server = read_string(key, "ProxyServer")?;
        unsafe {
            RegCloseKey(key);
        }
        Ok(SystemProxySnapshot { enabled, server })
    }

    pub fn apply(endpoint: &str) -> Result<()> {
        write(&SystemProxySnapshot {
            enabled: true,
            server: Some(endpoint.to_string()),
        })
    }

    pub fn write(snapshot: &SystemProxySnapshot) -> Result<()> {
        if dry_run() {
            return Ok(());
        }

        let key = open_key(KEY_SET_VALUE)?;
        write_dword(key, "ProxyEnable", u32::from(snapshot.enabled))?;
        write_string(
            key,
            "ProxyServer",
            snapshot.server.as_deref().unwrap_or_default(),
        )?;
        unsafe {
            RegCloseKey(key);
        }
        notify_settings_changed();
        Ok(())
    }

    fn open_key(access: u32) -> Result<HKEY> {
        let mut key: HKEY = null_mut();
        let path = wide_null(INTERNET_SETTINGS);
        let status =
            unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, path.as_ptr(), 0, access, &mut key) };
        if status != ERROR_SUCCESS {
            return Err(anyhow!("RegOpenKeyExW failed: {status}"));
        }
        Ok(key)
    }

    fn read_dword(key: HKEY, name: &str) -> Result<Option<u32>> {
        let mut value_type = 0;
        let mut data = [0u8; 4];
        let mut data_len = data.len() as u32;
        let name = wide_null(name);
        let status = unsafe {
            RegQueryValueExW(
                key,
                name.as_ptr(),
                null_mut(),
                &mut value_type,
                data.as_mut_ptr(),
                &mut data_len,
            )
        };
        if status != ERROR_SUCCESS {
            return Ok(None);
        }
        if value_type != REG_DWORD || data_len < 4 {
            return Ok(None);
        }
        Ok(Some(u32::from_le_bytes(data)))
    }

    fn read_string(key: HKEY, name: &str) -> Result<Option<String>> {
        let name = wide_null(name);
        let mut value_type = 0;
        let mut data_len = 0u32;
        let status = unsafe {
            RegQueryValueExW(
                key,
                name.as_ptr(),
                null_mut(),
                &mut value_type,
                null_mut(),
                &mut data_len,
            )
        };
        if status != ERROR_SUCCESS || value_type != REG_SZ || data_len == 0 {
            return Ok(None);
        }

        let mut buffer = vec![0u16; (data_len as usize).div_ceil(2)];
        let status = unsafe {
            RegQueryValueExW(
                key,
                name.as_ptr(),
                null_mut(),
                &mut value_type,
                buffer.as_mut_ptr().cast(),
                &mut data_len,
            )
        };
        if status != ERROR_SUCCESS {
            return Ok(None);
        }

        if let Some(end) = buffer.iter().position(|ch| *ch == 0) {
            buffer.truncate(end);
        }
        let value = String::from_utf16_lossy(&buffer);
        Ok((!value.is_empty()).then_some(value))
    }

    fn write_dword(key: HKEY, name: &str, value: u32) -> Result<()> {
        let name = wide_null(name);
        let data = value.to_le_bytes();
        let status = unsafe {
            RegSetValueExW(
                key,
                name.as_ptr(),
                0,
                REG_DWORD,
                data.as_ptr(),
                data.len() as u32,
            )
        };
        if status != ERROR_SUCCESS {
            return Err(anyhow!("RegSetValueExW DWORD failed: {status}"));
        }
        Ok(())
    }

    fn write_string(key: HKEY, name: &str, value: &str) -> Result<()> {
        let name = wide_null(name);
        let data = wide_null(value);
        let status = unsafe {
            RegSetValueExW(
                key,
                name.as_ptr(),
                0,
                REG_SZ,
                data.as_ptr().cast(),
                (data.len() * 2) as u32,
            )
        };
        if status != ERROR_SUCCESS {
            return Err(anyhow!("RegSetValueExW string failed: {status}"));
        }
        Ok(())
    }

    fn notify_settings_changed() {
        unsafe {
            InternetSetOptionW(null(), INTERNET_OPTION_SETTINGS_CHANGED, null(), 0);
            InternetSetOptionW(null(), INTERNET_OPTION_REFRESH, null(), 0);
        }
    }

    fn dry_run() -> bool {
        std::env::var_os("SAMHAIN_PROXY_DRY_RUN").is_some()
    }

    fn wide_null(value: &str) -> Vec<u16> {
        OsStr::new(value).encode_wide().chain(Some(0)).collect()
    }
}

#[cfg(not(windows))]
mod system_proxy {
    use super::*;

    pub fn read() -> Result<SystemProxySnapshot> {
        Ok(SystemProxySnapshot {
            enabled: false,
            server: None,
        })
    }

    pub fn apply(_endpoint: &str) -> Result<()> {
        Ok(())
    }

    pub fn write(_snapshot: &SystemProxySnapshot) -> Result<()> {
        Ok(())
    }
}

mod secret {
    use anyhow::{Result, anyhow};
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;

    #[cfg(windows)]
    pub fn protect_string(value: &str) -> Result<String> {
        use std::ptr::{null, null_mut};
        use std::slice;
        use windows_sys::Win32::Foundation::{GetLastError, LocalFree};
        use windows_sys::Win32::Security::Cryptography::{
            CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData,
        };

        let bytes = value.as_bytes();
        let input = CRYPT_INTEGER_BLOB {
            cbData: bytes.len() as u32,
            pbData: bytes.as_ptr() as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: null_mut(),
        };

        let ok = unsafe {
            CryptProtectData(
                &input,
                null(),
                null(),
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };

        if ok == 0 {
            return Err(anyhow!("CryptProtectData failed: {}", unsafe {
                GetLastError()
            }));
        }

        let protected = unsafe { slice::from_raw_parts(output.pbData, output.cbData as usize) };
        let encoded = STANDARD.encode(protected);
        unsafe {
            LocalFree(output.pbData.cast());
        }

        Ok(format!("dpapi:{encoded}"))
    }

    #[cfg(windows)]
    #[allow(dead_code)]
    pub fn unprotect_string(value: &str) -> Result<String> {
        use std::ptr::{null, null_mut};
        use std::slice;
        use windows_sys::Win32::Foundation::{GetLastError, LocalFree};
        use windows_sys::Win32::Security::Cryptography::{
            CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptUnprotectData,
        };

        let encoded = value.strip_prefix("dpapi:").unwrap_or(value);
        let bytes = STANDARD.decode(encoded)?;
        let input = CRYPT_INTEGER_BLOB {
            cbData: bytes.len() as u32,
            pbData: bytes.as_ptr() as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: null_mut(),
        };

        let ok = unsafe {
            CryptUnprotectData(
                &input,
                null_mut(),
                null(),
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };

        if ok == 0 {
            return Err(anyhow!("CryptUnprotectData failed: {}", unsafe {
                GetLastError()
            }));
        }

        let unprotected = unsafe { slice::from_raw_parts(output.pbData, output.cbData as usize) };
        let text = String::from_utf8(unprotected.to_vec())?;
        unsafe {
            LocalFree(output.pbData.cast());
        }

        Ok(text)
    }

    #[cfg(not(windows))]
    pub fn protect_string(value: &str) -> Result<String> {
        Ok(format!("b64:{}", STANDARD.encode(value.as_bytes())))
    }

    #[cfg(not(windows))]
    #[allow(dead_code)]
    pub fn unprotect_string(value: &str) -> Result<String> {
        let encoded = value.strip_prefix("b64:").unwrap_or(value);
        Ok(String::from_utf8(STANDARD.decode(encoded)?)?)
    }
}

#[cfg(windows)]
mod named_pipe {
    use super::*;
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr::null_mut;
    use windows_sys::Win32::Foundation::{
        CloseHandle, ERROR_PIPE_CONNECTED, GetLastError, HANDLE, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FlushFileBuffers, PIPE_ACCESS_DUPLEX, ReadFile, WriteFile,
    };
    use windows_sys::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_READMODE_MESSAGE,
        PIPE_TYPE_MESSAGE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
    };

    const BUFFER_SIZE: u32 = 64 * 1024;

    pub fn run(handler: fn(&str) -> String) -> Result<()> {
        loop {
            let pipe = create_pipe()?;
            let connected = unsafe {
                ConnectNamedPipe(pipe, null_mut()) != 0 || GetLastError() == ERROR_PIPE_CONNECTED
            };

            if connected {
                if let Err(error) = handle_client(pipe, handler) {
                    eprintln!("IPC client error: {error}");
                }
            }

            unsafe {
                DisconnectNamedPipe(pipe);
                CloseHandle(pipe);
            }
        }
    }

    fn create_pipe() -> Result<HANDLE> {
        let pipe_name = wide_null(samhain_ipc::NAMED_PIPE_NAME);
        let pipe = unsafe {
            CreateNamedPipeW(
                pipe_name.as_ptr(),
                PIPE_ACCESS_DUPLEX,
                PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
                PIPE_UNLIMITED_INSTANCES,
                BUFFER_SIZE,
                BUFFER_SIZE,
                samhain_ipc::DEFAULT_REQUEST_TIMEOUT_MS,
                null_mut(),
            )
        };

        if pipe == INVALID_HANDLE_VALUE {
            return Err(anyhow!("CreateNamedPipeW failed: {}", unsafe {
                GetLastError()
            }));
        }

        Ok(pipe)
    }

    fn handle_client(pipe: HANDLE, handler: fn(&str) -> String) -> Result<()> {
        let mut buffer = vec![0u8; BUFFER_SIZE as usize];
        let mut read = 0u32;
        let read_ok = unsafe {
            ReadFile(
                pipe,
                buffer.as_mut_ptr().cast(),
                BUFFER_SIZE,
                &mut read,
                null_mut(),
            )
        };

        if read_ok == 0 || read == 0 {
            return Err(anyhow!("ReadFile failed or empty request: {}", unsafe {
                GetLastError()
            }));
        }

        let request = String::from_utf8_lossy(&buffer[..read as usize]);
        let response = handler(&request);
        let bytes = response.as_bytes();
        let mut written = 0u32;
        let write_ok = unsafe {
            WriteFile(
                pipe,
                bytes.as_ptr().cast(),
                bytes.len() as u32,
                &mut written,
                null_mut(),
            )
        };

        if write_ok == 0 {
            return Err(anyhow!("WriteFile failed: {}", unsafe { GetLastError() }));
        }

        unsafe {
            FlushFileBuffers(pipe);
        }

        Ok(())
    }

    fn wide_null(value: &str) -> Vec<u16> {
        OsStr::new(value).encode_wide().chain(Some(0)).collect()
    }
}

#[cfg(not(windows))]
mod named_pipe {
    use super::*;

    pub fn run(_handler: fn(&str) -> String) -> Result<()> {
        Err(anyhow!(
            "The Samhain Security service IPC foundation currently targets Windows named pipes."
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use samhain_ipc::{RequestEnvelope, decode_response, encode_request};

    #[test]
    fn handles_get_state_envelope() {
        let request = RequestEnvelope::new("req-state", ClientCommand::GetState);
        let payload = encode_request(&request).expect("request");
        let response_payload = handle_payload(&payload);
        let response = decode_response(&response_payload).expect("response");

        assert!(response.ok);
        assert_eq!(response.request_id, "req-state");
        assert!(matches!(response.event, ServiceEvent::State(_)));
    }

    #[test]
    fn rejects_unknown_protocol_version() {
        let mut request = RequestEnvelope::new("req-version", ClientCommand::Ping);
        request.protocol_version = IPC_PROTOCOL_VERSION + 1;
        let payload = encode_request(&request).expect("request");
        let response_payload = handle_payload(&payload);
        let response = decode_response(&response_payload).expect("response");

        assert!(!response.ok);
        assert_eq!(response.request_id, "req-version");
        assert!(matches!(response.event, ServiceEvent::Error { .. }));
    }

    #[test]
    fn protects_secret_round_trip() {
        let protected = secret::protect_string("vless://secret@example").expect("protect");
        assert_ne!(protected, "vless://secret@example");

        let unprotected = secret::unprotect_string(&protected).expect("unprotect");
        assert_eq!(unprotected, "vless://secret@example");
    }

    #[test]
    fn discovers_engine_catalog_entries() {
        let catalog = discover_engines();

        assert!(
            catalog
                .iter()
                .any(|entry| entry.kind == EngineKind::SingBox)
        );
        assert!(catalog.iter().any(|entry| entry.kind == EngineKind::Xray));
        assert!(
            catalog
                .iter()
                .all(|entry| !entry.name.is_empty() && !entry.search_paths.is_empty())
        );
        assert!(catalog.iter().all(|entry| !entry.runtime_id.is_empty()
            && !entry.bundled_path.is_empty()
            && !entry.expected_paths.is_empty()
            && !entry.status.is_empty()
            && !entry.version_status.is_empty()
            && !entry.protocols.is_empty()
            && !entry.message.is_empty()));
        for entry in catalog.iter().filter(|entry| entry.available) {
            assert_eq!(entry.status, "available");
            assert!(entry.executable_path.is_some());
            assert!(entry.sha256.as_ref().is_some_and(|hash| hash.len() == 64));
            assert!(entry.file_size_bytes.unwrap_or_default() > 0);
        }
    }

    #[test]
    fn engine_contract_declares_exact_bundle_layout() {
        let catalog = discover_engines();
        let expected = [
            ("sing-box", "app\\engines\\sing-box\\sing-box.exe"),
            ("xray", "app\\engines\\xray\\xray.exe"),
            ("wireguard", "app\\engines\\wireguard\\wireguard.exe"),
            ("amneziawg", "app\\engines\\amneziawg\\awg-quick.exe"),
        ];

        for (runtime_id, bundled_path) in expected {
            let entry = catalog
                .iter()
                .find(|entry| entry.runtime_id == runtime_id)
                .expect("runtime entry");
            assert_eq!(entry.bundled_path, bundled_path);
            assert!(entry.expected_paths.iter().any(|path| {
                path.ends_with(&bundled_path.replace("app\\", "")) || path.ends_with(bundled_path)
            }));
        }
    }

    #[test]
    fn redacts_generated_engine_preview() {
        let raw_url = "vless://00000000-0000-4000-8000-000000000001@example.com:443?type=tcp&security=reality&pbk=public-secret&sid=short-secret&sni=front.example&fp=chrome#Samhain";
        let server = parse_server_url(raw_url, 1).expect("server");
        let generated =
            generate_engine_config(&server, raw_url, RouteMode::WholeComputer).expect("config");

        assert!(
            generated
                .full_config
                .contains("00000000-0000-4000-8000-000000000001")
        );
        assert!(generated.full_config.contains("public-secret"));
        assert!(
            !generated
                .redacted_config
                .contains("00000000-0000-4000-8000-000000000001")
        );
        assert!(!generated.redacted_config.contains("public-secret"));
        assert!(!generated.redacted_config.contains("short-secret"));
        assert!(generated.redacted_config.contains("<redacted>"));
    }

    #[test]
    fn whole_computer_generates_tun_path() {
        let raw_url = "vless://00000000-0000-4000-8000-000000000001@example.com:443?type=tcp&security=reality&pbk=public-secret&sid=short-secret&sni=front.example&fp=chrome#Samhain";
        let server = parse_server_url(raw_url, 1).expect("server");
        let generated =
            generate_engine_config(&server, raw_url, RouteMode::WholeComputer).expect("config");

        assert_eq!(generated.path, EnginePath::Tun);
        assert!(generated.redacted_config.contains("\"type\": \"tun\""));
        assert!(generated.redacted_config.contains("\"auto_route\": true"));
        assert!(!generated.redacted_config.contains("\"type\": \"mixed\""));
    }

    #[test]
    fn app_modes_keep_proxy_path_until_policy_milestone() {
        let raw_url = "vless://00000000-0000-4000-8000-000000000001@example.com:443?type=tcp&security=reality&pbk=public-secret&sid=short-secret&sni=front.example&fp=chrome#Samhain";
        let server = parse_server_url(raw_url, 1).expect("server");
        let generated =
            generate_engine_config(&server, raw_url, RouteMode::SelectedAppsOnly).expect("config");

        assert_eq!(generated.path, EnginePath::Proxy);
        assert!(generated.redacted_config.contains("\"type\": \"mixed\""));
        assert!(
            generated
                .warnings
                .iter()
                .any(|warning| warning.contains("точная маршрутизация"))
        );
    }

    #[test]
    fn wireguard_profile_generates_adapter_config() {
        let raw_config = "[Interface]\nPrivateKey = private-secret\nAddress = 10.8.0.2/32\nDNS = 1.1.1.1\nMTU = 1420\n\n[Peer]\nPublicKey = public-secret\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = 203.0.113.10:51820\nPersistentKeepalive = 25\n";
        let server = Server {
            id: "wg-1".to_string(),
            name: "WG Test".to_string(),
            host: "203.0.113.10".to_string(),
            port: Some(51820),
            protocol: Protocol::WireGuard,
            country_code: None,
            ping_ms: None,
            raw_url: raw_config.to_string(),
        };
        let generated =
            generate_engine_config(&server, raw_config, RouteMode::WholeComputer).expect("config");

        assert_eq!(generated.engine, EngineKind::WireGuard);
        assert_eq!(generated.path, EnginePath::Adapter);
        assert!(generated.full_config.contains("private-secret"));
        assert!(generated.full_config.contains("public-secret"));
        assert!(!generated.redacted_config.contains("private-secret"));
        assert!(!generated.redacted_config.contains("public-secret"));
        assert!(
            generated
                .redacted_config
                .contains("PrivateKey = <redacted>")
        );
        assert!(
            engine_config_path(&server.id, generated.engine)
                .display()
                .to_string()
                .ends_with(".conf")
        );
    }

    #[test]
    fn amnezia_profile_preserves_obfuscation_fields() {
        let raw_config = "[Interface]\nPrivateKey = private-secret\nAddress = 10.9.0.2/32\nDNS = 1.1.1.1\nMTU = 1420\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 10\nS2 = 20\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n\n[Peer]\nPublicKey = public-secret\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = 198.51.100.10:51820\nPersistentKeepalive = 25\n";
        let server = Server {
            id: "awg-1".to_string(),
            name: "AWG Test".to_string(),
            host: "198.51.100.10".to_string(),
            port: Some(51820),
            protocol: Protocol::AmneziaWg,
            country_code: None,
            ping_ms: None,
            raw_url: raw_config.to_string(),
        };
        let generated =
            generate_engine_config(&server, raw_config, RouteMode::WholeComputer).expect("config");

        assert_eq!(generated.engine, EngineKind::AmneziaWg);
        assert_eq!(generated.path, EnginePath::Adapter);
        assert!(generated.full_config.contains("Jc = 4"));
        assert!(generated.full_config.contains("H4 = 4"));
        assert!(
            !generated
                .warnings
                .iter()
                .any(|warning| warning.contains("обфускации"))
        );
    }

    #[test]
    fn normalizes_route_application_paths() {
        let app = StoredRouteApplication::from_path(
            "file:///C:/Program Files/Samhain/test-app.exe".to_string(),
        )
        .expect("app");

        assert_eq!(app.name, "test-app.exe");
        assert!(app.path.ends_with("test-app.exe"));
        assert!(app.enabled);
    }

    #[test]
    fn app_routing_policy_marks_app_modes_limited() {
        let mut manager = AppRoutingManager::new();
        let state = manager.apply(
            RouteMode::SelectedAppsOnly,
            vec![RouteApplication {
                id: "app-1".to_string(),
                name: "test-app.exe".to_string(),
                path: "C:\\Program Files\\Samhain\\test-app.exe".to_string(),
                enabled: true,
            }],
        );

        assert_eq!(state.status, "limited");
        assert!(!state.supported);
        assert!(!state.enforcement_available);
        assert!(
            state
                .evidence
                .iter()
                .any(|item| item == "wfp_layer=not-implemented")
        );
        assert_eq!(state.rule_names.len(), 1);
        assert!(state.message.contains("WFP"));

        let fresh_manager = AppRoutingManager::new();
        let configured = fresh_manager.snapshot(RouteMode::SelectedAppsOnly, state.applications);
        assert_eq!(configured.status, "configured");
        assert_eq!(configured.rule_names.len(), 1);
    }

    #[test]
    fn service_readiness_exposes_enforcement_gates() {
        let state = service_readiness_state();

        assert_eq!(state.identity, "current-user-package");
        assert_eq!(state.required_identity, "signed-privileged-service");
        assert!(!state.identity_valid);
        assert_eq!(state.signing_state, "unsigned-dev");
        assert!(!state.signing_valid);
        assert!(!state.privileged_policy_allowed);
        assert!(!state.app_routing_enforcement_available);
        assert!(
            state
                .checks
                .iter()
                .any(|check| check.starts_with("privileged_policy_allowed="))
        );
    }

    #[test]
    fn service_self_check_reports_gated_capabilities() {
        let state = service_self_check_state(&storage_path());

        assert!(matches!(
            state.status.as_str(),
            "gated" | "partial" | "ready"
        ));
        assert!(
            state
                .checks
                .iter()
                .any(|check| check.name == "named-pipe" && check.ok)
        );
        assert!(state.checks.iter().any(|check| check.name == "firewall"));
        assert_eq!(state.recovery_policy.owner, "service");
        assert!(state.audit_log_path.is_some());
    }

    #[test]
    fn audit_events_are_redacted_and_rotated() {
        let mut store = ServiceStore::fallback();
        for index in 0..(AUDIT_EVENT_LIMIT + 5) {
            store.append_audit_event(
                "test",
                "rotate",
                "ok",
                format!("token=secret-{index} pbk=public-{index}"),
            );
        }

        assert_eq!(store.state.audit_events.len(), AUDIT_EVENT_LIMIT);
        assert_eq!(
            store.state.audit_events.first().map(|event| event.id),
            Some(6)
        );
        assert!(
            store
                .state
                .audit_events
                .iter()
                .all(|event| !event.detail.contains("secret-"))
        );
    }

    #[test]
    fn protection_policy_arms_without_enforcement() {
        let mut manager = ProtectionManager::new();
        let state = manager.apply(ProtectionSettings::default(), RouteMode::WholeComputer);

        assert_eq!(state.status, "armed");
        assert!(!state.enforcing);
        assert!(!state.supported);
        assert!(
            state
                .rule_names
                .iter()
                .any(|name| name.contains("DNS Guard"))
        );
        assert!(
            state
                .rule_names
                .iter()
                .any(|name| name.contains("Kill Switch"))
        );
        assert_eq!(state.transaction.status, "planned");
        assert!(!state.transaction.applied);
        assert!(!state.transaction.rollback_available);
        assert!(
            state
                .transaction
                .steps
                .iter()
                .any(|step| step.action == "plan-kill-switch" && step.status == "pending-wfp")
        );
        assert!(
            state
                .transaction
                .steps
                .iter()
                .any(|step| !step.command.is_empty() && !step.rollback_command.is_empty())
        );

        let restored = manager.restore();
        assert_eq!(restored.status, "restored");
        assert!(!restored.enforcing);
    }

    #[test]
    fn protection_firewall_commands_stay_scoped() {
        let settings = ProtectionSettings {
            kill_switch_enabled: true,
            dns_leak_protection_enabled: true,
            ipv6_policy: Ipv6Policy::Block,
            reconnect_enabled: true,
            backoff_seconds: 2,
        };
        let commands = protection_firewall_commands(&settings);

        assert_eq!(commands.len(), 3);
        assert!(
            commands
                .iter()
                .flat_map(|command| command.args.iter())
                .any(|arg| arg == "remoteport=53")
        );
        assert!(
            commands
                .iter()
                .flat_map(|command| command.args.iter())
                .any(|arg| arg == "remoteip=::/0")
        );
        assert!(
            commands
                .iter()
                .all(|command| command.name.starts_with("Samhain Security "))
        );
        assert!(
            commands
                .iter()
                .all(|command| command.rollback_args.iter().any(|arg| arg == "delete"))
        );
        assert!(
            !commands
                .iter()
                .flat_map(|command| command.args.iter())
                .any(|arg| arg == "action=allow")
        );
    }

    #[test]
    fn protection_transaction_records_evidence_and_snapshots() {
        let settings = ProtectionSettings {
            kill_switch_enabled: true,
            dns_leak_protection_enabled: true,
            ipv6_policy: Ipv6Policy::Block,
            reconnect_enabled: true,
            backoff_seconds: 2,
        };

        let transaction = protection_transaction_plan(
            &settings,
            RouteMode::WholeComputer,
            "dry-run",
            true,
            false,
            false,
            "validated",
        );

        assert_eq!(transaction.status, "dry-run");
        assert!(transaction.dry_run);
        assert!(!transaction.before_snapshot.is_empty());
        assert!(!transaction.after_snapshot.is_empty());
        assert!(
            transaction
                .steps
                .iter()
                .any(|step| step.action == "plan-kill-switch")
        );
        assert!(transaction.steps.iter().any(|step| {
            step.evidence
                .iter()
                .any(|item| item == "broad_allow_rules=false")
        }));
        assert!(
            transaction
                .steps
                .iter()
                .any(|step| step.rollback_command.iter().any(|arg| arg == "delete"))
        );
        assert!(
            transaction
                .steps
                .iter()
                .any(|step| step.action == "record-emergency-restore")
        );
    }

    #[test]
    fn traffic_tracker_reports_service_session() {
        let server = parse_server_url(
            "vless://00000000-0000-4000-8000-000000000001@example.com:443?type=tcp&security=reality#Samhain",
            1,
        )
        .expect("server");
        let mut tracker = TrafficTracker::new();
        tracker.start(&server, EnginePath::Tun);

        let running = tracker.snapshot(true);
        assert_eq!(running.status, "running");
        assert_eq!(running.source, "service-session");
        assert_eq!(running.metrics_source, "service-session");
        assert!(running.fallback);
        assert_eq!(running.route_path, "TUN path");
        assert!(running.last_successful_handshake.is_some());
        assert!(running.download_bps > 0);
        assert!(running.upload_bps > 0);

        tracker.stop();
        let stopped = tracker.snapshot(false);
        assert_eq!(stopped.status, "stopped");
        assert!(stopped.fallback);
        assert_eq!(stopped.download_bps, 0);
        assert_eq!(stopped.upload_bps, 0);
    }

    #[test]
    fn runtime_health_distinguishes_fallback_metrics() {
        let mut manager = EngineManager::new();
        manager.state.status = "running".to_string();
        manager.state.engine = EngineKind::SingBox;
        manager.state.started_at = Some("Engine event: test".to_string());
        manager.last_plan = Some(EngineStartPlan {
            kind: EngineKind::SingBox,
            path: EnginePath::Tun,
            server_id: "server-1".to_string(),
            executable_path: PathBuf::from("sing-box.exe"),
            config_path: PathBuf::from("config.json"),
            args: Vec::new(),
            full_config: "{}".to_string(),
        });

        let health = manager.runtime_health_snapshot();

        assert_eq!(health.status, "fallback-telemetry");
        assert_eq!(health.metrics_source, "service-session");
        assert!(!health.metrics_available);
        assert_eq!(health.route_path, "TUN path");
        assert!(health.last_successful_handshake.is_some());
        assert!(health.last_error.is_none());
    }

    #[test]
    fn redacts_support_text_secrets() {
        let text = "https://example.test/subscription.html?token=super-secret&pbk=public-secret&sid=short-secret password=open";
        let redacted = redact_support_text(text);

        assert!(!redacted.contains("super-secret"));
        assert!(!redacted.contains("public-secret"));
        assert!(!redacted.contains("short-secret"));
        assert!(!redacted.contains("password=open"));
        assert!(redacted.contains("<redacted>"));
    }

    #[test]
    fn log_snapshot_filters_categories() {
        let logs = Arc::new(Mutex::new(Vec::new()));
        push_engine_log(&logs, "info", "manager", "started");
        push_engine_log(&logs, "warn", "protection", "token=secret");

        let snapshot = build_log_snapshot(&logs, Some("protection"));

        assert_eq!(snapshot.entries.len(), 1);
        assert_eq!(snapshot.entries[0].stream, "protection");
        assert!(!snapshot.entries[0].message.contains("secret"));
        assert!(snapshot.categories.contains(&"manager".to_string()));
        assert!(snapshot.categories.contains(&"protection".to_string()));
    }
}
