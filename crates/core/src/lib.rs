use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use std::fmt;
use url::Url;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Protocol {
    VlessReality,
    AmneziaWg,
    WireGuard,
    Trojan,
    Shadowsocks,
    Hysteria2,
    Tuic,
    SingBox,
    Unknown,
}

impl Protocol {
    pub fn from_scheme(scheme: &str) -> Self {
        match scheme.to_ascii_lowercase().as_str() {
            "vless" => Self::VlessReality,
            "awg" | "amneziawg" => Self::AmneziaWg,
            "wg" | "wireguard" => Self::WireGuard,
            "trojan" => Self::Trojan,
            "ss" | "shadowsocks" => Self::Shadowsocks,
            "hysteria2" | "hy2" => Self::Hysteria2,
            "tuic" => Self::Tuic,
            "sing-box" | "singbox" => Self::SingBox,
            _ => Self::Unknown,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::VlessReality => "VLESS / TCP / REALITY",
            Self::AmneziaWg => "AmneziaWG",
            Self::WireGuard => "WireGuard",
            Self::Trojan => "Trojan",
            Self::Shadowsocks => "Shadowsocks",
            Self::Hysteria2 => "Hysteria2",
            Self::Tuic => "TUIC",
            Self::SingBox => "sing-box",
            Self::Unknown => "Unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RouteMode {
    WholeComputer,
    SelectedAppsOnly,
    ExcludeSelectedApps,
}

impl fmt::Display for RouteMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::WholeComputer => f.write_str("Весь компьютер"),
            Self::SelectedAppsOnly => f.write_str("Только выбранные приложения"),
            Self::ExcludeSelectedApps => f.write_str("Кроме выбранных приложений"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Server {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: Option<u16>,
    pub protocol: Protocol,
    pub country_code: Option<String>,
    pub ping_ms: Option<u32>,
    pub raw_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Subscription {
    pub id: String,
    pub name: String,
    pub url: String,
    pub servers: Vec<Server>,
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    pub route_mode: RouteMode,
    pub autostart: bool,
    pub start_minimized: bool,
    pub theme: String,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            route_mode: RouteMode::WholeComputer,
            autostart: false,
            start_minimized: false,
            theme: "samhain-dark".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParseReport {
    pub servers: Vec<Server>,
    pub rejected_lines: Vec<String>,
}

pub fn parse_server_url(input: &str, fallback_index: usize) -> Option<Server> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }

    let url = Url::parse(trimmed).ok()?;
    let protocol = Protocol::from_scheme(url.scheme());
    if protocol == Protocol::Unknown {
        return None;
    }

    let host = url.host_str().unwrap_or_default().to_string();
    let port = url.port();
    let fragment_name = percent_decode(url.fragment().unwrap_or_default());
    let name = if fragment_name.is_empty() {
        build_server_name(protocol, &host, fallback_index)
    } else {
        fragment_name
    };

    Some(Server {
        id: format!("server-{fallback_index}"),
        name,
        host,
        port,
        protocol,
        country_code: guess_country_code(trimmed),
        ping_ms: None,
        raw_url: trimmed.to_string(),
    })
}

pub fn parse_subscription_payload(payload: &str) -> ParseReport {
    let mut report = parse_lines(payload);
    if report.servers.is_empty() {
        if let Ok(decoded) = STANDARD.decode(payload.trim()) {
            if let Ok(text) = String::from_utf8(decoded) {
                report = parse_lines(&text);
            }
        }
    }

    report
}

pub fn sample_subscription() -> Subscription {
    let urls = [
        "vless://id@gb-london-1.samhain.example:443?type=tcp&security=reality#Samhain%20GB%20London%20%231",
        "vless://id@gb-london-2.samhain.example:443?type=tcp&security=reality#Samhain%20GB%20London%20%232",
        "vless://id@nl-amsterdam-3.samhain.example:443?type=tcp&security=reality#Samhain%20NL%20Amsterdam%20%233",
        "awg://de-frankfurt-6.samhain.example:51820#Samhain%20DE%20Frankfurt%20%236",
        "trojan://pass@se-evle-4.samhain.example:443#Samhain%20SE%20Evle%20%234",
        "ss://method:pass@se-evle-5.samhain.example:443#Samhain%20SE%20Evle%20%235",
        "hysteria2://pass@de-frankfurt-7.samhain.example:443#Samhain%20DE%20Frankfurt%20%237",
    ];

    let mut servers = Vec::new();
    for (index, url) in urls.iter().enumerate() {
        if let Some(mut server) = parse_server_url(url, index + 1) {
            server.ping_ms = match index {
                0 => Some(1277),
                1 => Some(1189),
                2 => Some(360),
                3 => None,
                4 => Some(248),
                5 => Some(251),
                _ => None,
            };
            servers.push(server);
        }
    }

    Subscription {
        id: "default-samhain".to_string(),
        name: "Samhain Security".to_string(),
        url: "demo://samhain".to_string(),
        servers,
        updated_at: Some("27.04.2026 23:22 | Автообновление - 24ч.".to_string()),
    }
}

fn parse_lines(payload: &str) -> ParseReport {
    let mut servers = Vec::new();
    let mut rejected_lines = Vec::new();

    for line in payload.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        if let Some(server) = parse_server_url(trimmed, servers.len() + 1) {
            servers.push(server);
        } else {
            rejected_lines.push(trimmed.to_string());
        }
    }

    ParseReport {
        servers,
        rejected_lines,
    }
}

fn build_server_name(protocol: Protocol, host: &str, index: usize) -> String {
    if host.is_empty() {
        return format!("{} #{index}", protocol.label());
    }

    format!("{host} #{index}")
}

fn guess_country_code(value: &str) -> Option<String> {
    let lower = value.to_ascii_lowercase();
    for (needle, code) in [
        ("gb", "GB"),
        ("london", "GB"),
        ("nl", "NL"),
        ("amsterdam", "NL"),
        ("de", "DE"),
        ("frankfurt", "DE"),
        ("se", "SE"),
        ("evle", "SE"),
        ("us", "US"),
    ] {
        if lower.contains(needle) {
            return Some(code.to_string());
        }
    }

    None
}

fn percent_decode(value: &str) -> String {
    let replaced = value.replace('+', " ");
    match url::form_urlencoded::parse(replaced.as_bytes()).next() {
        Some((decoded, _)) if !decoded.is_empty() => decoded.into_owned(),
        _ => replaced,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_vless_url() {
        let server = parse_server_url(
            "vless://id@nl-amsterdam.example:443?security=reality#Samhain%20NL",
            1,
        )
        .expect("server");

        assert_eq!(server.protocol, Protocol::VlessReality);
        assert_eq!(server.port, Some(443));
        assert_eq!(server.name, "Samhain NL");
        assert_eq!(server.country_code.as_deref(), Some("NL"));
    }

    #[test]
    fn parses_base64_subscription_payload() {
        let payload = STANDARD.encode(
            "trojan://pass@de.example:443#DE\nhysteria2://pass@se.example:443#SE",
        );
        let report = parse_subscription_payload(&payload);

        assert_eq!(report.servers.len(), 2);
        assert_eq!(report.servers[0].protocol, Protocol::Trojan);
        assert_eq!(report.servers[1].protocol, Protocol::Hysteria2);
    }

    #[test]
    fn sample_subscription_contains_mixed_protocols() {
        let subscription = sample_subscription();

        assert!(subscription.servers.iter().any(|s| s.protocol == Protocol::VlessReality));
        assert!(subscription.servers.iter().any(|s| s.protocol == Protocol::AmneziaWg));
    }
}
