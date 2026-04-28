use anyhow::{Context, Result, anyhow};
use samhain_core::{
    RouteMode, Server, Subscription, parse_server_url, parse_subscription_payload,
    sample_subscription,
};
use samhain_ipc::{
    ClientCommand, IPC_PROTOCOL_VERSION, RequestEnvelope, ResponseEnvelope, ServiceEvent,
    ServiceState, decode_request, encode_event, encode_response,
};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static STORE: OnceLock<Mutex<ServiceStore>> = OnceLock::new();

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
            route_mode: _,
        } => ServiceEvent::Connecting { server_id },
        ClientCommand::Disconnect => ServiceEvent::Disconnected,
        ClientCommand::TestPing { server_id } => {
            let checksum = server_id.bytes().fold(0u32, |acc, byte| acc + byte as u32);
            ServiceEvent::PingResult {
                server_id,
                ping_ms: Some(40 + checksum % 380),
            }
        }
    }
}

fn current_state(running: bool) -> ServiceState {
    match service_store().lock() {
        Ok(store) => store.service_state(running),
        Err(_) => ServiceState {
            version: env!("CARGO_PKG_VERSION").to_string(),
            running,
            selected_server_id: None,
            connected_server_id: None,
            route_mode: RouteMode::WholeComputer,
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

        Ok(Self { path, state })
    }

    fn fallback() -> Self {
        Self {
            path: storage_path(),
            state: StoredState::seeded(),
        }
    }

    fn service_state(&self, running: bool) -> ServiceState {
        ServiceState {
            version: env!("CARGO_PKG_VERSION").to_string(),
            running,
            selected_server_id: self.state.selected_server_id.clone(),
            connected_server_id: self.state.connected_server_id.clone(),
            route_mode: self.state.route_mode,
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
}

#[derive(Debug, Serialize, Deserialize)]
struct StoredState {
    schema_version: u32,
    route_mode: RouteMode,
    #[serde(default)]
    selected_server_id: Option<String>,
    connected_server_id: Option<String>,
    subscriptions: Vec<StoredSubscription>,
}

impl StoredState {
    fn seeded() -> Self {
        Self {
            schema_version: 1,
            route_mode: RouteMode::WholeComputer,
            selected_server_id: None,
            connected_server_id: None,
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

    for mut server in servers {
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
}
