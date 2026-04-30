# App Routing Enforcement

Version: `1.4.1`

Samhain Security now has one release-supported per-application route path:

- mode: `selected-apps-only`;
- contour: proxy-aware applications;
- local endpoint: `127.0.0.1:20808`;
- system proxy: unchanged;
- rollback: service app-routing transaction reset on disconnect, failed start, or emergency restore.

This means selected applications are supported when they can be configured to use the local proxy endpoint. Transparent process capture, selected-app TUN capture, adapter bypass, and except-selected bypass remain blocked until the signed privileged WFP layer is implemented.

## Service Behavior

Before a connection starts, the service validates the selected route mode and app list. Unsupported route modes fail before the engine is launched.

When `selected-apps-only` is accepted, the service starts the proxy engine path and explicitly does not apply the Windows system proxy. This prevents the selected-app mode from silently becoming a whole-computer proxy route.

## Evidence

The service state and support bundle include:

- route mode;
- enabled application count;
- release-supported and experimental compatibility lines;
- transaction kind and status;
- local proxy endpoint;
- missing executable path evidence;
- rollback state.

## Known Limit

The client cannot force arbitrary applications through the route without an application-level proxy setting or a future transparent WFP layer. The UI must keep that limitation visible in advanced policy details.
