# Evidence Envelope

This is the cryptographic contract for the SDK receipt. [Signal surface](../README.md#signal-surface)
explains what signals may be observed and fused; this document explains why a verifier should believe an
envelope was produced by the enrolled device, has not been tampered with, and is fresh enough for a risk
decision.

## Goals

- Bind a bounded `DeviceSignals` payload to a device-held signing key.
- Bind production receipts to a fresh server challenge when App Attest is enabled.
- Preserve append-only local receipt history with a Merkle root.
- Let a verifier validate receipts without raw sensor streams.
- Make replay, relay, and stale receipts explicit failure modes.

## Envelope shape

`DeviceEvidenceEnvelope` contains:

- `schemaVersion`
- `privacyBoundary`
- `generatedAt`
- `session`: session id plus optional applicant/application/tenant ids and metadata
- `collection`: start/end time, SDK version, duration, consent policy
- `signals`: the bounded signed-envelope signals
- `receipt`: the integrity receipt, omitted while computing the payload hash

The signed sensor payload is therefore the envelope with `receipt = nil`.

## Canonicalization

The SDK canonicalizes JSON with:

- sorted keys
- unescaped slashes
- ISO-8601 UTC dates with fractional seconds
- receipt omitted from the hashed payload

The `payloadHash` is SHA-256 over that canonical unsigned envelope.

## Merkle receipt chain

Each payload hash is appended to the local evidence ledger:

- `leafHash = SHA256("kenshiki:evidence:leaf:v1" || payloadHashData)`
- parent nodes use `SHA256("kenshiki:evidence:node:v1" || left || right)`
- the receipt records `previousMerkleRoot`, `merkleRoot`, `merkleLeafIndex`, and `merkleLeafCount`

The Merkle chain proves local append order and makes deletion/reordering visible to a verifier that
has seen prior roots. It is not by itself proof of server freshness.

## Device signature

The receipt signs an `EvidenceSigningPayload` containing:

- receipt schema version
- `signedAt`
- `payloadHash`
- `leafHash`
- Merkle root metadata
- platform attestation provider/state
- App Attest key-id hash and client-data hash when present

The SDK signs this payload with ECDSA P-256 SHA-256 (`ecdsa-p256-sha256-x962`). The signing key is
persistent, prefers Secure Enclave, and is stored device-only where iOS supports it. The receipt carries
the public key, public-key hash, secure-hardware boolean, and signature.

Production policy should treat `secureHardware = true` as the normal path for supported iOS devices.
`secureHardware = false` is a downgrade state, not an equivalent posture: it may be allowed for
simulators, development, or explicitly degraded partner policy, but verification should surface it as
reviewable risk.

The signature covers the canonical evidence envelope, not every app-layer projection derived from it.
Day-view events, local feature rows, and state-transition labels inherit their provenance from the
check-in `sessionId`/Merkle root today. If those derived rows ever become exportable proof material,
the verifier must either receive the original signed envelope plus a deterministic derivation version,
or receive a separately signed derived-proof batch hash. Unsigned local UI rows are not sufficient for a
bank/lender proof.

## Platform attestation

When enabled, Apple App Attest is challenge-bound:

- The server provides a fresh challenge in `metadata["kenshiki_app_attest_challenge"]`.
- The SDK computes
  `clientDataHash = SHA256("kenshiki:app-attest:client-data:v1" || challenge || payloadHashData)`.
- On first use, the SDK creates an App Attest key and returns an attestation object.
- On later use, it returns an assertion object.

The SDK can produce the objects, but only the verifier can fully validate them against Apple's App Attest
rules, challenge freshness, bundle/team binding, and duplicate-use policy. A receipt with
`platformAttestation.state = "challenge_required"` is locally signed but not server-fresh.

## Replay and relay protection

Local verification proves integrity only:

- The payload hash matches the envelope.
- The device signature verifies against the carried public key.
- The leaf hash and signing payload match the receipt.

Production verification additionally requires server checks:

- Challenge id/nonce exists, is fresh, and has not been used.
- App Attest attestation/assertion verifies for that challenge and app.
- `generatedAt` and `signedAt` fall within accepted clock skew.
- Session id and receipt id have not been replayed.
- Payload hash/leaf hash have not already been accepted for a different challenge.
- Merkle root advances from the last accepted root, or enters an explicit offline-queue reconciliation
  path.
- Device public-key hash is enrolled for the subject/account, or is in an authenticated recovery flow.

Without these server checks, an old legitimate envelope can be replayed as a local artifact. It should
not be accepted as a fresh credit/identity proof.

## QR / optical boundary

QR codes are a zero-trust boundary. A QR rendered in a browser or partner flow must be treated as
attacker-controllable until both the scanner and verifier validate it.

Production challenge QR payloads must be:

- **Self-authenticating:** signed by the issuing verifier, for example as compact JWS or an equivalent
  signed token. The scanner verifies provenance before routing or starting a bonding flow.
- **Short-lived:** carry issued-at and expiry claims measured in seconds, not minutes.
- **Single-use:** reference a server challenge id/nonce that transitions to `consumed` on successful
  verification; duplicate scans become telemetry and fail closed.
- **Purpose-bound:** claims include purpose (`enroll`, `receipt`, `bond`, `rebind`), tenant/partner
  context where applicable, and the expected app/bundle audience.
- **Challenge-bound:** the phone's evidence response binds App Attest client data and device signing to
  the challenge. The optical payload alone is never proof.

The scanning app should reject unsigned, expired, wrong-audience, wrong-purpose, or malformed QR
payloads locally before collection begins. The verifier remains the final authority for consumption,
freshness, and replay checks.

Browser-rendered QR codes should additionally use strict CSP, avoid remote static QR images, and
monitor the QR container for obvious mutation/overlay events. DOM checks are detection and telemetry,
not trust anchors; cryptographic challenge verification is the trust boundary.

## Verifier output

The verifier should reduce the envelope to a small acceptance record:

- `receipt_id`
- tenant-scoped opaque subject handle
- device public-key hash
- App Attest key-id hash
- generated/signed/accepted times
- Merkle root and leaf index
- schema/model versions
- verification state: accepted, stale, replayed, bad signature, bad attestation, recovery required
- bounded continuity bands and break type when applicable

It should not return raw sensor values to lenders by default.

## Threat coverage

| Attack | Envelope control | Remaining dependency |
| --- | --- | --- |
| Payload tampering | Canonical hash and device signature fail. | Correct canonicalization on verifier. |
| Local receipt deletion/reorder | Merkle root discontinuity. | Verifier must remember prior accepted roots. |
| Replay old valid receipt | Fresh challenge and duplicate-receipt checks. | Verifier challenge service. |
| Relay live device once | Challenge proves freshness, not intent. | Transaction binding and risk policy. |
| Emulator/fake app | App Attest should fail. | Server-side App Attest verification. |
| Fresh stolen-identity device | Low maturity and unenrolled key. | Subject/KYC enrollment and recovery policy. |
| Fully compromised real device | Signature may still be valid. | App Attest posture, jailbreak signals, multi-day coherence, KYC/carrier layers. |

## False-positive handling

Envelope failures should separate integrity failure from legitimate recovery:

- **Bad signature/hash:** reject receipt.
- **Stale or replayed challenge:** request a fresh challenge and retry.
- **Merkle discontinuity:** enter review/offline-reconciliation path.
- **New device key:** require authenticated rebind, not silent acceptance.
- **App Attest unavailable:** degrade only if policy allows; never label as verified.

Risk systems should prefer "needs recovery" over "fraud" when the failure can be caused by phone
replacement, eSIM migration, backup/restore, offline queuing, or app reinstall.

## What the SDK ships today

Produced on-device by the SDK:

- Canonical payload hash.
- Device ECDSA P-256 signatures.
- Secure Enclave preference with software fallback.
- Local Merkle ledger.
- App Attest object generation when a challenge is provided.
- Local `EvidenceIntegrity.verify(_:)` for payload/signature consistency.

Provided by your verification backend (see [BackendIntegration.md](BackendIntegration.md)):

- Fresh challenge issuance and one-time challenge consumption.
- Server-side App Attest verification.
- Subject/device-key enrollment and recovery.
- Accepted-root memory and replay rejection.
- Lender/bureau-facing minimal proof API.
