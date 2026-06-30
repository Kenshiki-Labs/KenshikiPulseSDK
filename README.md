# Kenshiki Pulse SDK

[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2015%2B%20%7C%20macOS%2013%2B-blue.svg)](#requirements)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![License](https://img.shields.io/badge/License-Proprietary-lightgrey.svg)](LICENSE)

**Kenshiki Pulse** is an iOS SDK that collects *bounded, device-side evidence*, signs and
structures it on-device, and hands your backend a compact proof envelope — never raw
private phone history. It is the client half of a step-up / account-opening trust check:
you decide *when* to ask for a Pulse, the SDK produces tamper-evident proof material, and
your backend turns that into a decision.

```swift
import KenshikiPulseSDK

let pulse = KenshikiPulseSDK(
    configuration: KenshikiPulseConfiguration(
        endpoint: URL(string: "https://api.example.com/v1/existence/verify"),
        apiKey: "server-issued-token"
    )
)

let context = KenshikiSessionContext(
    applicantId: "applicant_123",
    applicationId: "application_456",
    tenantId: "tenant_acme",
    metadata: ["workflow": "pre_submit"]
)

let evidence = try await pulse.collectDeviceEvidence(context: context)
let result   = try await pulse.verifyExistence(context: context)
```

---

## What it does (and does not)

| Pulse **does** | Pulse **does not** |
| --- | --- |
| Collect bounded device-physics signals (battery, motion magnitudes, network *class*) | Read contacts, messages, photos, screen contents, or location trails |
| Sign a canonical evidence envelope on-device (ECDSA P‑256, Secure Enclave when available) | Ship raw sensor streams or stable hardware identifiers |
| Emit a salted, tenant-scoped, **rotating** returning-device pseudonym | Expose a cross-app supercookie or correlate a device across tenants |
| Wire in Apple App Attest for challenge-bound platform attestation | Make a trust decision on-device — your backend decides |

> The privacy boundary is explicit and machine-readable on every envelope:
> `privacyBoundary == "derived_device_physics_envelope_only"`.

---

## Requirements

- iOS 15+ / macOS 13+
- Swift 5.9+ (Xcode 15+)
- No third-party dependencies

The package builds on macOS so model and network tests run without an attached iOS device.

## Install

Add the package in Xcode (**File ▸ Add Package Dependencies…**) or in your `Package.swift`:

```swift
.package(url: "https://github.com/Kenshiki-Labs/KenshikiPulseSDK.git", from: "0.1.0")
```

Then add the `KenshikiPulseSDK` product to your app target and `import KenshikiPulseSDK`.

## Quick start

1. **Create a session.** Your backend opens a Pulse session/action request and passes
   `tenantId`, `sessionId`, and any `metadata` (including an App Attest challenge) into the app.
2. **Collect evidence.** Call `collectDeviceEvidence(context:)` to produce a signed
   `DeviceEvidenceEnvelope`, or `verifyExistence(context:)` to collect *and* submit to your endpoint.
3. **Verify / forward.** Your backend verifies the envelope (or forwards it to Kenshiki) and
   maps the returned decision and reason codes into your account-opening or step-up flow.

See [Docs/BackendIntegration.md](Docs/BackendIntegration.md) for the full server-side contract,
and [Docs/UIGuidance.md](Docs/UIGuidance.md) for how to present Pulse to users.

## Public API at a glance

```swift
public final class KenshikiPulseSDK {
    public init(configuration: KenshikiPulseConfiguration = .init(), ...)

    /// Collect + sign a tamper-evident evidence envelope on-device.
    public func collectDeviceEvidence(context: KenshikiSessionContext) async throws -> DeviceEvidenceEnvelope

    /// Collect, sign, and submit to your configured endpoint; returns the decision.
    public func verifyExistence(context: KenshikiSessionContext) async throws -> ExistenceVerificationResult

    /// Attest a small claim (e.g. a passport capture) into a Merkle-chained, device-signed receipt.
    public func attestIdentityClaim(payload: [String: String], challenge: Data?) async throws -> EvidenceIntegrityReceipt
}
```

`ExistenceVerificationResult` carries `decision`, optional `confidence`, and a `reasons`
array your backend defines — map these to UI states (see [Docs/ReasonCodes.md](Docs/ReasonCodes.md)).

## Integrity receipts

Both `collectDeviceEvidence` and `verifyExistence` finalize each envelope with an
`EvidenceIntegrityReceipt`: a canonical payload hash, an append-only Merkle root, and an
ECDSA P‑256 device signature. On real iOS hardware the SDK first attempts a Secure Enclave
key and falls back to a software key only where hardware signing is unavailable (simulator /
local tests). Apple App Attest is wired into the receipt and produces a challenge-bound
attestation/assertion when the session metadata includes `kenshiki_app_attest_challenge`;
without a backend challenge it reports `challenge_required` rather than pretending to be attested.

## Device recurrence (returning-device signal)

Every envelope carries a `recurrence` block: a salted, tenant-scoped, rotating device
pseudonym that answers "have I seen this device before?" **without any raw device identifier**.

```swift
if let recurrence = evidence.recurrence {
    recurrence.current   // index this token to recognise a returning device
    recurrence.previous  // chains across a rotation boundary
}
```

- **Salted & install-local.** `HMAC-SHA256(installSalt, "…|scope|epoch")`, base64url-encoded.
  The 32-byte salt is minted once per install and held in the Keychain
  (`AfterFirstUnlockThisDeviceOnly`): never egressed, not reversible to a hardware id,
  survives app delete + reinstall on the same device, never migrates to a new device.
- **Tenant-scoped.** Folds in `KenshikiSessionContext.tenantId`, so the same device presents a
  *different* token to each tenant — no cross-company collusion. With no `tenantId` the token is
  install-scoped (`scope == "install"`); pass a `tenantId` in any multi-tenant deployment.
- **Rotating with overlap.** Rotates every `deviceRecurrenceRotationDays` (default 90). Each
  envelope carries `current` and `previous` so a relying party can chain across a boundary, while
  an absence longer than one window unlinks the device (forward privacy).

Configure via `KenshikiPulseConfiguration(enableDeviceRecurrence:deviceRecurrenceRotationDays:)`.
Suppressed when `consentPolicy == .disabledForLocalTesting`. `KenshikiPulseLocalState.erase()`
wipes the salt (the "forget me" lever). The `recurrence` block is part of the signed payload, so
it is covered by the integrity receipt and is tamper-evident.

## Signal surface

The first SDK layer emits a derived evidence envelope:

- **Battery** — level, charge state, thermal state, low-power mode.
- **Motion** — bounded CoreMotion snapshot with magnitude summaries.
- **Magnetometer** — bounded field-magnitude summary when available.
- **Barometer** — support/availability by default; no altitude stream.
- **Ambient light** — screen-brightness proxy only (iOS exposes no public ambient-light API).
- **Connectivity** — privacy-safe network path class/cost/constraint; no SSID, BSSID, IP, tower, or RF data.
- **Device surface** — coarse platform/runtime metadata, not stable device identifiers.
- **Device recurrence** — salted, tenant-scoped, rotating pseudonym (`current`/`previous`).
- **Integrity receipt** — signed canonical envelope hash plus Merkle root; no raw sensor data added.

## Configuration

```swift
KenshikiPulseConfiguration(
    endpoint: URL? = nil,
    apiKey: String? = nil,
    captureDuration: TimeInterval = 1.5,
    includeBarometerAvailability: Bool = true,
    consentPolicy: KenshikiConsentPolicy = .hostApplicationManaged,
    additionalHeaders: [String: String] = [:],
    signEvidence: Bool = true,
    enablePlatformAttestation: Bool = true,
    appAttestEnvironment: String = "production",
    enableDeviceRecurrence: Bool = true,
    deviceRecurrenceRotationDays: Int = 90
)
```

`KenshikiConsentPolicy` is `hostApplicationManaged`, `requiredBeforeCollection`, or
`disabledForLocalTesting`. You own the consent UI; the SDK honors the policy you set.

## Privacy boundaries

Pulse is a **bounded check**, not a surveillance permission. When presenting it:

- Explain the specific action being protected.
- Request permissions only when needed.
- Never claim Pulse reads private content, location trails, contacts, messages, or screen contents.
- Offer a clear "continue with limited protection / do this later" path **only** where your product policy allows.

Full guidance: [Docs/UIGuidance.md](Docs/UIGuidance.md).

## Examples

[Examples/QuickStart.swift](Examples/QuickStart.swift) is a minimal, copy-pasteable integration
snippet. (This repository intentionally does not ship a full demo app — sample apps rot fast and
make an SDK look noisier than it is. The reference app lives in its own repository.)

## Development

```bash
swift build
swift test
```

168 tests cover continuity modeling, evidence integrity, recurrence, telemetry, and the network clients.

## Versioning & support

Semantic versioning. See [CHANGELOG.md](CHANGELOG.md) for releases and
[SECURITY.md](SECURITY.md) for vulnerability reporting. Current SDK version: **0.1.0**.

## License

Proprietary — see [LICENSE](LICENSE). © 2026 Kenshiki Labs. All rights reserved.
