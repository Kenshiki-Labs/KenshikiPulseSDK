import Foundation

public enum PulseWebSocketMessage: Encodable, Sendable {
    case bondEstablished
    case heartbeat(PulseHeartbeat)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bondEstablished:
            try container.encode("bond_established", forKey: .type)
        case .heartbeat(let payload):
            try container.encode("heartbeat", forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case payload
    }
}

public struct PulseWebSocketInboundMessage: Decodable, Equatable, Sendable {
    public let type: String?
    public let event: String?
    public let state: String?
    public let sessionID: String?
    public let action: String?
    public let challengeID: String?
    public let nonce: String?
    public let materialActionID: String?
    public let payloadHash: String?
    public let workflow: String?
    public let tenantID: String?
    public let valueTier: String?
    public let expiresAt: String?
    public let signingProfile: String?
    public let displayIntent: [String: String]?
    public let actionCommitmentPayload: PulseMaterialActionPayload?
    public let present: Bool?

    /// The browser/web side of this session dropped its connection (tab closed / navigated away).
    /// Lets the phone stop "waiting for browser" and surface that the web session ended.
    public var isWebPresenceLost: Bool {
        type == "pulse.web_presence" && present == false
    }

    public var actionCommitmentChallenge: PulseActionCommitmentChallengeResponse? {
        guard type == "action_commitment.challenge",
              let challengeID,
              let nonce,
              let sessionID,
              let materialActionID,
              let payloadHash,
              let workflow,
              let action,
              let tenantID,
              let valueTierRaw = valueTier,
              let valueTier = PulseActionValueTier(rawValue: valueTierRaw),
              let expiresAt,
              let signingProfile,
              let displayIntent
        else { return nil }
        return PulseActionCommitmentChallengeResponse(
            challengeID: challengeID,
            nonce: nonce,
            sessionID: sessionID,
            materialActionID: materialActionID,
            payloadHash: payloadHash,
            workflow: workflow,
            action: action,
            tenantID: tenantID,
            valueTier: valueTier,
            expiresAt: expiresAt,
            signingProfile: signingProfile,
            displayIntent: displayIntent
        )
    }

    public var isActionCommitmentAuthorized: Bool {
        type == "action_commitment.authorized"
    }

    enum CodingKeys: String, CodingKey {
        case type
        case event
        case state
        case sessionID = "session_id"
        case action
        case challengeID = "challenge_id"
        case nonce
        case materialActionID = "material_action_id"
        case payloadHash = "payload_hash"
        case workflow
        case tenantID = "tenant_id"
        case valueTier = "value_tier"
        case expiresAt = "expires_at"
        case signingProfile = "signing_profile"
        case displayIntent = "display_intent"
        case actionCommitmentPayload = "payload"
        case present
    }
}

public typealias PulseWebSocketInboundHandler = @Sendable (PulseWebSocketInboundMessage) -> Void

public actor PulseWebSocketClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private let url: URL
    private let session: URLSession
    private let onMessage: PulseWebSocketInboundHandler?

    public init(
        url: URL,
        session: URLSession = .shared,
        onMessage: PulseWebSocketInboundHandler? = nil
    ) {
        self.url = url
        self.session = session
        self.onMessage = onMessage
    }

    public func connect() {
        guard webSocketTask == nil else { return }
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        listenForMessages()
    }

    public func disconnect(closeCode: URLSessionWebSocketTask.CloseCode = .normalClosure) {
        webSocketTask?.cancel(with: closeCode, reason: nil)
        webSocketTask = nil
    }

    public func send(_ message: PulseWebSocketMessage) async throws {
        let encoder = JSONEncoder()

        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }

        let data = try encoder.encode(message)
        let string = String(data: data, encoding: .utf8) ?? "{}"

        guard let task = webSocketTask else {
            throw URLError(.notConnectedToInternet)
        }

        try await task.send(.string(string))
    }

    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                Task {
                    await self.handle(message)
                    await self.listenForMessages()
                }
            case .failure(let error):
                print("[PulseWebSocketClient] disconnected or failed: \(error)")
                Task { await self.disconnect() }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let string):
            data = string.data(using: .utf8)
        case .data(let payload):
            data = payload
        @unknown default:
            data = nil
        }
        guard let data,
              let inbound = try? JSONDecoder().decode(PulseWebSocketInboundMessage.self, from: data) else {
            return
        }
        onMessage?(inbound)
    }
}
