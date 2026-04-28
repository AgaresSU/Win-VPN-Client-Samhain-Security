use anyhow::{Context, Result, anyhow};
use samhain_core::{
    Protocol, RouteMode, Server, Subscription, parse_server_url, parse_subscription_payload,
    sample_subscription,
};
use samhain_ipc::{
    ClientCommand, EngineCatalogEntry, EngineConfigPreview, EngineKind, EngineLifecycleState,
    EngineLogEntry, IPC_PROTOCOL_VERSION, PingProbeResult, RequestEnvelope, ResponseEnvelope,
    ServiceEvent, ServiceState, decode_request, encode_event, encode_response,
};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

static STORE: OnceLock<Mutex<ServiceStore>> = OnceLock::new();
const PROBE_TIMEOUT: Duration = Duration::from_millis(260);

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "status".to_string());

    match command.as_str() {
        "install" => print_stub("install"),
        "start" => print_stub("start"),
        "stop" => print_stub("stop"),
        "uninstall" => print_stub("uninstall"),
        "status" => print_status()?,
        "run" | "serve" => run_service()?,
        _ => {
            eprintln!("Usage: samhain-service [install|start|stop|status|uninstall|run]");
            std::process::exit(2);
        }
    }

    Ok(())
}

fn print_stub(command: &str) {
    println!(
        "Samhain Security Native service skeleton: '{command}' is reserved for the privileged Rust service."
    );
}

fn print_status() -> Result<()> {
    println!("{}", encode_event(&ServiceEvent::State(current_state(false)))?);
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
        Err(error) => ResponseEnvelope::error("invalid-request", format!("Invalid request: {error}")),
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
    STORE.get_or_init(|| Mutex::new(ServiceStore::load().unwrap_or_else(|_| ServiceStore::fallback())))
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
        ServiceState {
            version: env!("CARGO_PKG_VERSION").to_string(),
            running,
            selected_server_id: self.state.selected_server_id.clone(),
            connected_server_id: self.state.connected_server_id.clone(),
            route_mode: self.state.route_mode,
            engine_state,
            engine_catalog,
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
        if state.status == "running" || state.status == "starting" {
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
        self.state.connected_server_id = None;
        self.save()?;
        Ok(state)
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
        let url = secret::unprotect_string(&old.protected_url)
            .or_else(|_| {
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
            subscriptions: vec![StoredSubscription::from_public(sample_subscription())],
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

fn stable_subscription_id(name: &str, url: &str) -> String {
    let checksum = name
        .bytes()
        .chain(url.bytes())
        .fold(0u32, |acc, byte| {
            acc.wrapping_mul(31).wrapping_add(byte as u32)
        });
    format!("subscription-{checksum:08x}")
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

    let Ok(ip) = server.host.parse::<IpAddr>() else {
        return PingProbeResult {
            server_id: server.id.clone(),
            ping_ms: server.ping_ms,
            status: "unresolved".to_string(),
            checked_at,
            source: "stored".to_string(),
            stale: server.ping_ms.is_some(),
        };
    };

    let endpoint = SocketAddr::new(ip, port);
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
    server_id: String,
    executable_path: PathBuf,
    config_path: PathBuf,
    args: Vec<String>,
    full_config: String,
}

#[derive(Debug, Clone)]
struct GeneratedEngineConfig {
    engine: EngineKind,
    full_config: String,
    redacted_config: String,
    warnings: Vec<String>,
}

#[derive(Debug)]
struct EngineManager {
    child: Option<Child>,
    state: EngineLifecycleState,
    logs: Arc<Mutex<Vec<EngineLogEntry>>>,
    last_plan: Option<EngineStartPlan>,
}

impl EngineManager {
    fn new() -> Self {
        Self {
            child: None,
            state: EngineLifecycleState::default(),
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
        if generated.engine == EngineKind::WireGuard || generated.engine == EngineKind::AmneziaWg {
            self.state = EngineLifecycleState {
                status: "adapter-pending".to_string(),
                engine: generated.engine,
                server_id: Some(server.id.clone()),
                pid: None,
                started_at: None,
                stopped_at: None,
                last_exit_code: None,
                restart_attempts: 0,
                config_path: None,
                message: "Адаптерный запуск будет включён в отдельном этапе.".to_string(),
                log_tail: self.log_tail(),
            };
            push_engine_log(
                &self.logs,
                "info",
                "manager",
                &format!("Adapter lifecycle is pending for {}", server.name),
            );
            return Ok(self.snapshot());
        }

        let catalog = discover_engines();
        let Some(engine) = catalog
            .iter()
            .find(|entry| entry.kind == generated.engine && entry.available)
        else {
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
                    "Движок {} не найден. Поместите бинарник в папку engines рядом с приложением.",
                    engine_name(generated.engine)
                ),
                log_tail: self.log_tail(),
            };
            push_engine_log(
                &self.logs,
                "warn",
                "manager",
                &format!("Missing engine for {}", server.name),
            );
            return Ok(self.snapshot());
        };

        let executable_path = engine
            .executable_path
            .as_ref()
            .map(PathBuf::from)
            .ok_or_else(|| anyhow!("путь движка не найден"))?;
        let config_path = engine_config_path(&server.id, generated.engine);
        let args = engine_args(generated.engine, &config_path);
        let plan = EngineStartPlan {
            kind: generated.engine,
            server_id: server.id.clone(),
            executable_path,
            config_path,
            args,
            full_config: generated.full_config,
        };
        self.spawn_plan(plan, 0)?;
        Ok(self.snapshot())
    }

    fn stop(&mut self) -> Result<EngineLifecycleState> {
        self.reap_finished_process();
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let status = child.wait().ok();
            self.state.last_exit_code = status.and_then(|value| value.code());
        }

        if let Some(path) = self.state.config_path.as_deref() {
            let _ = fs::remove_file(path);
        }

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
            message: format!("Движок {} запущен.", engine_name(plan.kind)),
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

        if self.state.restart_attempts < 1 {
            if let Some(plan) = self.last_plan.clone() {
                let restart_attempts = self.state.restart_attempts + 1;
                if let Err(error) = self.spawn_plan(plan, restart_attempts) {
                    self.state.status = "crashed".to_string();
                    self.state.message = format!("Автоперезапуск не удался: {error}");
                    push_engine_log(&self.logs, "error", "manager", &self.state.message);
                }
            }
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
    let mut warnings = Vec::new();
    if route_mode != RouteMode::WholeComputer {
        warnings.push(
            "Режим приложений хранится в состоянии, но прозрачная маршрутизация включается позднее."
                .to_string(),
        );
    }
    if server.port.is_none() {
        warnings.push("У сервера нет явного порта.".to_string());
    }

    let full_config = build_sing_box_config(server, raw_url, false)?;
    let redacted_config = build_sing_box_config(server, raw_url, true)?;

    Ok(GeneratedEngineConfig {
        engine,
        full_config,
        redacted_config,
        warnings,
    })
}

fn build_sing_box_config(server: &Server, raw_url: &str, redacted: bool) -> Result<String> {
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

    let config = serde_json::json!({
        "log": {
            "level": "info",
            "timestamp": true
        },
        "inbounds": [
            {
                "type": "mixed",
                "tag": "local-proxy",
                "listen": "127.0.0.1",
                "listen_port": 20808
            }
        ],
        "outbounds": [
            serde_json::Value::Object(outbound),
            {
                "type": "direct",
                "tag": "direct"
            }
        ],
        "route": {
            "auto_detect_interface": true,
            "final": "selected"
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
    let dirs = engine_search_dirs();
    let names = engine_binary_names(kind);
    let executable_path = dirs
        .iter()
        .flat_map(|dir| names.iter().map(move |name| dir.join(name)))
        .find(|candidate| candidate.is_file());

    EngineCatalogEntry {
        kind,
        name: engine_name(kind).to_string(),
        executable_path: executable_path.as_ref().map(|path| path.display().to_string()),
        search_paths: dirs
            .iter()
            .map(|path| path.display().to_string())
            .collect(),
        available: executable_path.is_some(),
    }
}

fn engine_search_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(value) = std::env::var_os("SAMHAIN_ENGINE_DIR") {
        dirs.extend(std::env::split_paths(&value));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            dirs.push(parent.join("engines"));
            dirs.push(parent.to_path_buf());
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        dirs.push(cwd.join("engines"));
        dirs.push(cwd);
    }

    let mut unique = Vec::new();
    for dir in dirs {
        if !unique.iter().any(|existing: &PathBuf| existing == &dir) {
            unique.push(dir);
        }
    }
    unique
}

fn engine_binary_names(kind: EngineKind) -> &'static [&'static str] {
    match kind {
        EngineKind::SingBox => &["sing-box.exe", "sing-box"],
        EngineKind::Xray => &["xray.exe", "xray"],
        EngineKind::WireGuard => &["wireguard.exe", "wg.exe", "wireguard-go.exe", "wireguard"],
        EngineKind::AmneziaWg => &["amneziawg.exe", "awg.exe", "awg-go.exe", "amneziawg"],
        EngineKind::Unknown => &[],
    }
}

fn engine_config_path(server_id: &str, kind: EngineKind) -> PathBuf {
    storage_path()
        .parent()
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("engine")
        .join(format!(
            "{}-{}.json",
            engine_name(kind).to_ascii_lowercase(),
            sanitize_filename(server_id)
        ))
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

fn query_value(parsed: &Option<url::Url>, key: &str) -> Option<String> {
    parsed.as_ref()?.query_pairs().find_map(|(name, value)| {
        if name == key {
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
    ("2022-blake3-aes-128-gcm".to_string(), redacted_value(redacted))
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

fn spawn_engine_reader<R>(stream: R, stream_name: &'static str, logs: Arc<Mutex<Vec<EngineLogEntry>>>)
where
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

        assert!(catalog.iter().any(|entry| entry.kind == EngineKind::SingBox));
        assert!(catalog.iter().any(|entry| entry.kind == EngineKind::Xray));
        assert!(catalog
            .iter()
            .all(|entry| !entry.name.is_empty() && !entry.search_paths.is_empty()));
    }

    #[test]
    fn redacts_generated_engine_preview() {
        let raw_url = "vless://00000000-0000-4000-8000-000000000001@example.com:443?type=tcp&security=reality&pbk=public-secret&sid=short-secret&sni=front.example&fp=chrome#Samhain";
        let server = parse_server_url(raw_url, 1).expect("server");
        let generated =
            generate_engine_config(&server, raw_url, RouteMode::WholeComputer).expect("config");

        assert!(generated.full_config.contains("00000000-0000-4000-8000-000000000001"));
        assert!(generated.full_config.contains("public-secret"));
        assert!(!generated.redacted_config.contains("00000000-0000-4000-8000-000000000001"));
        assert!(!generated.redacted_config.contains("public-secret"));
        assert!(!generated.redacted_config.contains("short-secret"));
        assert!(generated.redacted_config.contains("<redacted>"));
    }
}
