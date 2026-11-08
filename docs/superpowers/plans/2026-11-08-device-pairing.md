# Device Pairing Implementation Plan

> **For agentic workers:** Implement each task and run its tests before integration.

**Goal:** Pair a personal iPhone once by QR and reuse its device credential for remote TimeWeave analysis.

**Architecture:** The existing service token authorizes pairing creation on the server. A short-lived one-use code exchanges for a revocable device credential, which the existing iOS origin-bound Keychain stores. Legacy manual configuration continues to work with the current deployment.

**Tech stack:** SwiftUI, VisionKit, URLSession, Keychain, Go HTTP.

## Contract

- QR payload: the configured HTTPS origin with `#timeweave-pair=<code>`. The code is 32 random bytes encoded as unpadded base64url. The app compares the QR origin to the explicitly configured origin before any request.
- `POST /v1/device-pairings/redeem` accepts `{ "schema_version": 1, "code": "…" }` without an Authorization header and returns `200` with `{ "schema_version": 1, "access_token": "…" }` and `Cache-Control: no-store`.
- A rejected, expired, or reused code returns a generic versioned error and does not change the app's current configuration.

## iOS

- [x] In `Tests/TimeWeaveCoreTests/AgentClientTests.swift`, verify that successful redemption posts only the code to the selected HTTPS origin and persists the returned token through the existing vault. Verify that an incorrect origin never reaches the network, and that an expired code preserves the active settings.
- [x] Add `AnalysisServiceSettings.pairRemote(qrPayload:address:session:)` and `AgentClient.redeemDevicePairing(code:)`. Check cancellation and service revision before saving the credential.
- [x] Add a QR scanner in `TimeWeave/AIAnalysisView.swift` with the camera purpose string in `TimeWeave/Info.plist`. Keep manual entry available for the deployed legacy server and devices without QR-scanner support.
- [x] Run the Swift core test suite and an iOS build.
- [ ] Once the backend is available, scan one code on a supported iPhone, relaunch, and verify a successful analysis without scanning again.

## Server and QR issuer

- [ ] Fetch the private backend's latest `origin/main` and create an independent development branch.
- [ ] Test that unauthenticated callers and paired devices cannot issue codes, that a code expires within five minutes and redeems at most once even under concurrent requests, and that device credentials work after a server restart and cease working after revocation.
- [ ] Add admin-only code issuance and device revocation. Store hashes, never plaintext device tokens. Enable pairing only for an authenticated deployment with durable state. Preserve the current service token and API behavior.
- [ ] Add a Mac-side QR issuer that uses the admin credential on ECS and renders the returned one-time code locally, without putting a long-lived credential in the QR.
- [ ] Run Go tests and verify end-to-end against a staged service before deploying either change.
