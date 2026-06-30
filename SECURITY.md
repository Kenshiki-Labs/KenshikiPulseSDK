# Security Policy

## Supported versions

The Kenshiki Pulse SDK is under active development. Security fixes are provided for the
latest released minor version.

| Version | Supported |
| ------- | --------- |
| 0.1.x   | ✅        |

## Reporting a vulnerability

Please report suspected vulnerabilities privately. **Do not** open a public GitHub issue
for security reports.

- Email: <security@kenshiki.com>
- Include: affected version, a description of the issue, reproduction steps or a proof of
  concept, and any relevant logs (with secrets redacted).

We aim to acknowledge reports within 3 business days and to provide a remediation timeline
after triage. Please allow us reasonable time to investigate and release a fix before any
public disclosure.

## Scope and design boundaries

The SDK is built to minimize the security surface it exposes:

- **No raw sensor streams or stable hardware identifiers** leave the device. Every envelope
  declares its boundary as `derived_device_physics_envelope_only`.
- **Secrets stay in the Keychain.** Salts used for the recurrence pseudonym are 32-byte CSPRNG
  values stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: never egressed, never
  synced to iCloud, never migrated to a new device.
- **Evidence is tamper-evident.** Envelopes are canonicalized and signed (ECDSA P‑256, Secure
  Enclave when available) with an append-only Merkle root; the recurrence block is inside the
  signed payload.
- **No on-device decisioning.** The SDK produces proof material only; trust decisions are made
  server-side by you or by Kenshiki.

## Handling API keys

The `apiKey` passed to `KenshikiPulseConfiguration` is a server-issued token for your endpoint.
Provision it at runtime from your backend session flow; do not hardcode production credentials
into the app binary or commit them to source control.
