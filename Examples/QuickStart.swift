// QuickStart.swift
//
// A minimal, copy-pasteable integration snippet for the Kenshiki Pulse SDK.
// This file is intentionally NOT part of the SwiftPM target — it is reference
// material. Drop the relevant pieces into your own app.
//
// See Docs/BackendIntegration.md and Docs/UIGuidance.md for the full contract.

import Foundation
import KenshikiPulseSDK

enum PulseQuickStart {
    /// Configure the SDK once and reuse the instance.
    static func makePulse() -> KenshikiPulseSDK {
        let configuration = KenshikiPulseConfiguration(
            endpoint: URL(string: "https://api.example.com/v1/existence/verify"),
            apiKey: "server-issued-token",
            // You own the consent UI; the SDK honors the policy you set.
            consentPolicy: .hostApplicationManaged,
            // Tenant-scoped, rotating returning-device pseudonym (default 90-day window).
            enableDeviceRecurrence: true,
            deviceRecurrenceRotationDays: 90
        )
        return KenshikiPulseSDK(configuration: configuration)
    }

    /// Collect a signed, tamper-evident evidence envelope without submitting it.
    static func collectEvidence() async throws {
        let pulse = makePulse()

        // Values your backend provides when it opens the Pulse session/action.
        let context = KenshikiSessionContext(
            sessionId: "<server-issued session id>",
            applicantId: "applicant_123",
            applicationId: "application_456",
            tenantId: "tenant_acme",
            metadata: [
                "workflow": "account_opening",
                // Fresh, server-generated nonce → challenge-bound App Attest.
                "kenshiki_app_attest_challenge": "<base64 server nonce>"
            ]
        )

        let evidence = try await pulse.collectDeviceEvidence(context: context)

        // Recognize a returning device without any raw device identifier.
        if let recurrence = evidence.recurrence {
            print("recurrence.current:", recurrence.current)
            print("recurrence.previous:", recurrence.previous)
        }

        // Forward `evidence` to your backend for verification.
        _ = evidence
    }

    /// Collect, sign, and submit in one call; branch on the returned decision.
    static func verifyAndDecide() async throws {
        let pulse = makePulse()
        let context = KenshikiSessionContext(tenantId: "tenant_acme")

        let result = try await pulse.verifyExistence(context: context)

        switch result.decision {
        case "approve":
            break // continue the protected action
        case "step_up":
            if result.reasons.contains("identity_required") {
                break // present passport capture
            } else {
                break // present phone/device confirmation
            }
        case "deny":
            break // show "unable to verify" with a support path
        default:
            break // "retry" / unknown → allow another attempt
        }
    }

    /// Local "forget me" lever: wipe minted salts and start a fresh, unlinkable series.
    static func forgetMe() {
        KenshikiPulseLocalState.erase()
    }
}
