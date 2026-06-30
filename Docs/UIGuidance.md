# UI Guidance

Present Pulse as a **bounded check tied to a specific action** — not as a vague surveillance or
"always-on monitoring" permission. Users (and app reviewers) should understand exactly what is and
is not happening.

## Principles

- **Explain the specific action being protected.** "We're confirming this device before you move
  money," not "We need to scan your device."
- **Ask for permissions only when needed**, at the moment they are needed, with a one-line reason.
- **Offer a clear fallback** — "do this later" or "continue with limited protection" — **only where
  your product policy allows it**.
- **Never overclaim.** Pulse does **not** read private content, location trails, contacts, messages,
  or screen contents. Do not imply it does.

## Recommended result states

Map your backend's decision/reason codes to a small set of plain states:

| State | When | Suggested copy |
| --- | --- | --- |
| **Ready** | Before the check | "We'll do a quick device check to protect this step." |
| **Checking** | While collecting/verifying | "Checking your device…" |
| **Needs phone** | A device/phone signal is required | "We need to confirm this phone to continue." |
| **Needs passport** | An identity capture is required | "Scan your passport to finish verifying." |
| **Unable to verify** | The check could not complete | "We couldn't verify this device. Try again or contact support." |

Keep these states stable and decoupled from internal reason strings — the backend can evolve
reason codes without forcing a UI change (see [ReasonCodes.md](ReasonCodes.md)).

## Consent and the SDK

The SDK does not draw UI; you own the consent surface. Choose a `KenshikiConsentPolicy`:

- `hostApplicationManaged` — you gate collection in your own flow (most common).
- `requiredBeforeCollection` — the SDK expects consent to be recorded before it collects.
- `disabledForLocalTesting` — disables collection and suppresses the recurrence pseudonym.

## "Forget me"

If a user asks to be forgotten, call `KenshikiPulseLocalState.erase()`. This wipes the locally
minted salts, so any future recurrence token starts a fresh, unlinkable series.

## Don'ts

- Don't present Pulse as a blanket "allow tracking" toggle.
- Don't request permissions speculatively at app launch.
- Don't surface raw tokens, hashes, or internal reason strings to end users.
- Don't claim certainty the backend didn't return — reflect `decision`/`confidence` honestly.
