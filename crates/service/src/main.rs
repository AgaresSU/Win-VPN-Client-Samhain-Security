use anyhow::Result;
use samhain_core::{RouteMode, sample_subscription};
use samhain_ipc::{ServiceEvent, ServiceState, encode_event};

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "status".to_string());

    match command.as_str() {
        "install" => print_stub("install"),
        "start" => print_stub("start"),
        "stop" => print_stub("stop"),
        "uninstall" => print_stub("uninstall"),
        "status" => print_status()?,
        _ => {
            eprintln!("Usage: samhain-service [install|start|stop|status|uninstall]");
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
    let state = ServiceState {
        version: env!("CARGO_PKG_VERSION").to_string(),
        running: false,
        connected_server_id: None,
        route_mode: RouteMode::WholeComputer,
        subscriptions: vec![sample_subscription()],
    };

    println!("{}", encode_event(&ServiceEvent::State(state))?);
    Ok(())
}
