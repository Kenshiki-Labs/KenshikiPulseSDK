# Reason Codes & Payloads

`ExistenceVerificationResult.reasons` is an **open list of strings defined by your verification
service** — the SDK does not enumerate or validate them. Treat reason codes as backend contract,
and map them to the small, stable set of UI states in [UIGuidance.md](UIGuidance.md).

## Result shape

```swift
public struct ExistenceVerificationResult: Codable, Equatable, Sendable {
    public var requestId: String?
    public var decision: String        // e.g. "approve" | "step_up" | "deny" | "retry"
    public var confidence: Double?      // 0.0...1.0 when provided
    public var reasons: [String]        // backend-defined reason codes
    public var receivedAt: Date?
}
```

## Example response

```json
{
  "requestId": "req_8c21",
  "decision": "step_up",
  "confidence": 0.61,
  "reasons": ["new_device", "attestation_valid"],
  "receivedAt": "2026-06-29T14:52:19.000Z"
}
```

## Illustrative mapping

The codes below are **examples**, not a fixed SDK contract. Define your own and keep the UI mapping
in one place so reason codes can change without UI churn.

| Example `decision` | Example `reasons` | Suggested UI state |
| --- | --- | --- |
| `approve` | `device_recognized`, `attestation_valid` | Ready → proceed |
| `step_up` | `new_device`, `low_confidence` | Needs phone |
| `step_up` | `identity_required` | Needs passport |
| `deny` | `attestation_failed`, `tamper_suspected` | Unable to verify |
| `retry` | `capture_incomplete`, `transient_error` | Checking → retry |

## Recommended client handling

```swift
switch result.decision {
case "approve":
    // continue the protected action
case "step_up":
    // branch on reasons to the right step-up screen
    if result.reasons.contains("identity_required") {
        // present passport capture
    } else {
        // present phone/device confirmation
    }
case "deny":
    // show "unable to verify" with a support path
default:
    // "retry" / unknown → allow another attempt
}
```

Always handle an **unknown** `decision` gracefully — your backend may add values over time.
