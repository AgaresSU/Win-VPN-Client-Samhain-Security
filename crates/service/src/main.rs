use anyhow::{Result, anyhow};
use samhain_core::{RouteMode, Subscription, parse_server_url, parse_subscription_payload, sample_subscription};
use samhain_ipc::{
    ClientCommand, IPC_PROTOCOL_VERSION, RequestEnvelope, ResponseEnvelope, ServiceEvent,
    ServiceState, decode_request, encode_event, encode_response,
};

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
            ServiceEvent::SubscriptionAdded {
                subscription: build_subscription(name, url),
            }
        }
        ClientCommand::SelectServer { server_id } => {
            let server = sample_subscription()
                .servers
                .into_iter()
                .find(|server| server.id == server_id)
                .or_else(|| sample_subscription().servers.into_iter().next());

            match server {
                Some(server) => ServiceEvent::ServerSelected { server },
                None => ServiceEvent::Error {
                    message: "No server is available.".to_string(),
                },
            }
        }
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
    ServiceState {
        version: env!("CARGO_PKG_VERSION").to_string(),
        running,
        connected_server_id: None,
        route_mode: RouteMode::WholeComputer,
        subscriptions: vec![sample_subscription()],
    }
}

fn build_subscription(name: String, url: String) -> Subscription {
    let mut report = parse_subscription_payload(&url);
    if report.servers.is_empty() {
        if let Some(server) = parse_server_url(&url, 1) {
            report.servers.push(server);
        }
    }

    if report.servers.is_empty() {
        report.servers = sample_subscription().servers;
    }

    Subscription {
        id: stable_subscription_id(&name, &url),
        name: if name.trim().is_empty() {
            "Samhain Security".to_string()
        } else {
            name.trim().to_string()
        },
        url,
        servers: report.servers,
        updated_at: Some("Получено через сервис IPC".to_string()),
    }
}

fn stable_subscription_id(name: &str, url: &str) -> String {
    let checksum = name
        .bytes()
        .chain(url.bytes())
        .fold(0u32, |acc, byte| acc.wrapping_mul(31).wrapping_add(byte as u32));
    format!("subscription-{checksum:08x}")
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
}
