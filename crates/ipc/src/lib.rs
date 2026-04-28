use samhain_core::{RouteMode, Server, Subscription};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ClientCommand {
    Ping,
    GetState,
    AddSubscription { name: String, url: String },
    SelectServer { server_id: String },
    Connect { server_id: String, route_mode: RouteMode },
    Disconnect,
    TestPing { server_id: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ServiceEvent {
    Pong,
    State(ServiceState),
    SubscriptionAdded { subscription: Subscription },
    ServerSelected { server: Server },
    Connecting { server_id: String },
    Connected { server_id: String },
    Disconnected,
    PingResult { server_id: String, ping_ms: Option<u32> },
    Error { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceState {
    pub version: String,
    pub running: bool,
    pub connected_server_id: Option<String>,
    pub route_mode: RouteMode,
    pub subscriptions: Vec<Subscription>,
}

impl Default for ServiceState {
    fn default() -> Self {
        Self {
            version: env!("CARGO_PKG_VERSION").to_string(),
            running: false,
            connected_server_id: None,
            route_mode: RouteMode::WholeComputer,
            subscriptions: Vec::new(),
        }
    }
}

pub fn encode_event(event: &ServiceEvent) -> serde_json::Result<String> {
    serde_json::to_string(event)
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
}
