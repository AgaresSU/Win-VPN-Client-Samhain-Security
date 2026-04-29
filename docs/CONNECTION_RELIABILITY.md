# Connection Reliability

Version: `1.3.1`

This pass makes the desktop treat the service as the source of truth for connect and disconnect actions.

## Rules

- A connect request must be confirmed by the service before the UI enters `Подключён`.
- If the service is unavailable, the UI keeps the previous state and shows that the command was not applied.
- Connect and disconnect commands use the longer engine-command timeout because runtime startup can take longer than ordinary status reads.
- Route-mode switching is blocked while connected. The user must disconnect, change the mode, then connect again.
- Failed connect attempts stop the local timer and refresh traffic back to a known state.
- Disconnect failures do not silently clear the connected state.

## User Messages

- `Подключение...` while a start command is in flight.
- `Отключение...` while a stop command is in flight.
- `Подключение не выполнено: ...` when the engine or service rejects the start.
- `Отключение не подтверждено: ...` when the service rejects a stop.
- `Сначала отключитесь, затем смените режим работы` when route mode is changed during an active session.

## Evidence

- Rust workspace tests still cover IPC, subscriptions, routing, protection, telemetry, and service state.
- Package validation includes service status, runtime health, subscription operations, and transaction evidence.
- Smoke tests launch the packaged desktop after the reliability changes.
