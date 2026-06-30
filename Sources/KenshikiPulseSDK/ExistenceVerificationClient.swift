import Foundation

public protocol ExistenceVerificationTransport: Sendable {
    func send(
        _ request: ExistenceVerificationRequest,
        configuration: KenshikiPulseConfiguration
    ) async throws -> ExistenceVerificationResult
}

public struct ExistenceVerificationClient: Sendable {
    private let configuration: KenshikiPulseConfiguration
    private let collector: DevicePhysicsCollecting
    private let transport: ExistenceVerificationTransport

    public init(
        configuration: KenshikiPulseConfiguration,
        collector: DevicePhysicsCollecting,
        transport: ExistenceVerificationTransport = URLSessionExistenceVerificationTransport()
    ) {
        self.configuration = configuration
        self.collector = collector
        self.transport = transport
    }

    public func verify(context: KenshikiSessionContext) async throws -> ExistenceVerificationResult {
        let collectedEvidence = try await collector.collectEvidence(context: context)
        let evidence = try await EvidenceIntegrityIssuer.shared.signedEnvelope(
            from: collectedEvidence,
            configuration: configuration
        )
        let request = ExistenceVerificationRequest(evidence: evidence)
        return try await transport.send(request, configuration: configuration)
    }
}

public struct URLSessionExistenceVerificationTransport: ExistenceVerificationTransport {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func send(
        _ request: ExistenceVerificationRequest,
        configuration: KenshikiPulseConfiguration
    ) async throws -> ExistenceVerificationResult {
        guard let endpoint = configuration.endpoint else {
            throw KenshikiPulseError.missingEndpoint
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("KenshikiPulseSDK/\(KenshikiPulseConstants.sdkVersion)", forHTTPHeaderField: "User-Agent")

        if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        for (header, value) in configuration.additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: header)
        }

        do {
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            throw KenshikiPulseError.encodingFailed(error.localizedDescription)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw KenshikiPulseError.networkFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KenshikiPulseError.invalidHTTPResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw KenshikiPulseError.httpStatus(httpResponse.statusCode, body)
        }

        do {
            return try decoder.decode(ExistenceVerificationResult.self, from: data)
        } catch {
            throw KenshikiPulseError.decodingFailed(error.localizedDescription)
        }
    }
}
