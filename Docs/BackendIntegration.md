# Backend Integration

Kenshiki Pulse is the client half of a trust check. The SDK produces tamper-evident proof
material on-device; your backend turns it into a decision. This document describes what your
server must do.

## Responsibilities

Your backend needs an endpoint or session flow that:

1. **Creates a Pulse session / action request.** Generate a `sessionId` and, when you want
   platform attestation, a fresh App Attest challenge nonce.
2. **Passes tenant/session/action context into the app.** At minimum `tenantId` and `sessionId`;
   include the challenge in `metadata["kenshiki_app_attest_challenge"]` and any workflow tags.
3. **Receives the SDK evidence envelope or result.** Either the app submits directly to your
   `endpoint` (via `verifyExistence`) or you collect the `DeviceEvidenceEnvelope` and forward it.
4. **Verifies / forwards.** Verify the envelope signature and Merkle root yourself, or forward the
   envelope to Kenshiki for verification, depending on your architecture.
5. **Maps the decision into your flow.** Translate the returned `decision` + `reasons` into your
   account-opening or step-up logic (approve, step up, deny, retry). See
   [ReasonCodes.md](ReasonCodes.md).

## Session context contract

The app constructs a `KenshikiSessionContext` from values your backend provides:

```swift
let context = KenshikiSessionContext(
    sessionId: "<server-issued session id>",
    applicantId: "applicant_123",
    applicationId: "application_456",
    tenantId: "tenant_acme",
    metadata: [
        "workflow": "account_opening",
        "kenshiki_app_attest_challenge": "<base64 server nonce>"
    ]
)
```

- **`tenantId` is important in multi-tenant deployments.** It scopes the device-recurrence
  pseudonym so the same device presents a different token to each tenant. Omitting it makes the
  token install-scoped (`scope == "install"`).
- **The App Attest challenge must be fresh and server-generated.** Without it, the integrity
  receipt reports `challenge_required` and is device-signed only.

## The evidence envelope

`collectDeviceEvidence(context:)` returns a `DeviceEvidenceEnvelope`. Key fields:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Wire schema id (e.g. `kenshiki.device.evidence.v0`) — pin and validate this. |
| `privacyBoundary` | Always `derived_device_physics_envelope_only`. |
| `generatedAt` | Capture timestamp. |
| `session` | Echo of the `KenshikiSessionContext`. |
| `signals` | Bounded device-physics signals (no raw streams). |
| `recurrence` | Salted, tenant-scoped, rotating `{ current, previous }` pseudonym. |
| `receipt` | Integrity receipt: canonical hash, Merkle root, ECDSA P‑256 signature, App Attest state. |

### Verifying integrity

The `receipt` is excluded from the canonical hash before signing, so re-canonicalize the envelope
with `receipt` set to null, hash it, and confirm:

1. the hash matches `receipt.payloadHash`;
2. the signature verifies against `receipt.publicKey` (P‑256);
3. the Merkle root is consistent;
4. when present, the App Attest assertion is bound to **your** challenge nonce.

The `recurrence` block is inside the signed payload, so it is covered by the signature and is
tamper-evident.

### Using device recurrence server-side

- Index `recurrence.current` per tenant to recognize a returning device.
- On a rotation boundary, `recurrence.previous` lets you chain the new token to the prior window.
- An absence longer than one rotation window unlinks the device by design (forward privacy).

## HTTP details

When the app submits directly, requests carry:

- `User-Agent: KenshikiPulseSDK/<version>`
- `Authorization` / your configured `apiKey` and any `additionalHeaders`.

The response is decoded into `ExistenceVerificationResult`:

```json
{
  "requestId": "req_...",
  "decision": "approve",
  "confidence": 0.92,
  "reasons": ["device_recognized", "attestation_valid"],
  "receivedAt": "2026-06-29T14:52:19.000Z"
}
```

`decision`, `confidence`, and `reasons` are defined by your verification service — the SDK does not
prescribe their values.
