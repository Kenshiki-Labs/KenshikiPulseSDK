# Changelog

All notable changes to the Kenshiki Pulse SDK are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — 2026-06-29

First stable release. No source-breaking changes from `0.1.0`.

### Added

- `Docs/EvidenceEnvelope.md`: the cryptographic receipt and verification contract for
  `DeviceEvidenceEnvelope` — binding to the device key, freshness, and explicit replay/relay
  failure modes — linked from the README.

### Changed

- Promoted the SDK to a stable 1.0 API surface.

## [0.1.0] — 2026-06-29

Initial public release of the Kenshiki Pulse SDK.

### Added

- `KenshikiPulseSDK` entry point with `collectDeviceEvidence(context:)`,
  `verifyExistence(context:)`, and `attestIdentityClaim(payload:challenge:)`.
- Bounded device-physics evidence envelope (`DeviceEvidenceEnvelope`) with an explicit,
  machine-readable privacy boundary (`derived_device_physics_envelope_only`).
- On-device integrity receipts: canonical payload hash, append-only Merkle root, and an
  ECDSA P‑256 device signature (Secure Enclave when available, software fallback otherwise).
- Apple App Attest integration producing challenge-bound attestations/assertions, with an
  explicit `challenge_required` state when no backend challenge is supplied.
- Device recurrence: a salted, tenant-scoped, rotating returning-device pseudonym
  (`current`/`previous`) carrying no raw device identifier; configurable rotation window.
- `KenshikiPulseConfiguration` with consent policy, platform-attestation, and recurrence controls.
- `KenshikiPulseLocalState.erase()` — local "forget me" lever that wipes minted salts.

### Notes

- iOS 15+ / macOS 13+, Swift 5.9+, no third-party dependencies.

[Unreleased]: https://github.com/Kenshiki-Labs/KenshikiPulseSDK/compare/1.0.0...HEAD
[1.0.0]: https://github.com/Kenshiki-Labs/KenshikiPulseSDK/compare/0.1.0...1.0.0
[0.1.0]: https://github.com/Kenshiki-Labs/KenshikiPulseSDK/releases/tag/0.1.0
