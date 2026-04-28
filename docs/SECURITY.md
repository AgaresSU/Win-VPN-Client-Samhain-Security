# Security Direction

## Client Reality

No desktop client can be fully abuse-proof. Anything running on a user's machine can be inspected or patched.

## Design Rules

- UI never owns access control decisions.
- Privileged actions belong to the Rust service.
- Secrets are stored using platform protection.
- Runtime configs have the shortest practical lifetime.
- Updates and manifests must be signed before production.
- Server-side checks decide entitlement, limits, and device trust.

## Future Hardening

- Signed service and desktop binaries.
- Short-lived subscription grants.
- Device binding.
- Integrity checks for service/core.
- Audit log with no secret leakage.
- Rate limits and anomaly checks on the backend.
