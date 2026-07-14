import Foundation
import MarkdownCardCore

final class AgentCommandServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (AgentRequest) async -> AgentResponse

    private let server: UnixDomainSocketServer
    private let handler: Handler
    private let acceptQueue = DispatchQueue(
        label: "com.garden100.MarkdownCard.ipc.accept",
        qos: .userInitiated
    )
    private let connectionQueue = DispatchQueue(
        label: "com.garden100.MarkdownCard.ipc.connections",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let stateLock = NSLock()
    private var running = false
    private static let fallbackRequestID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    init(server: UnixDomainSocketServer = UnixDomainSocketServer(), handler: @escaping Handler) {
        self.server = server
        self.handler = handler
    }

    func start() throws {
        try server.start()
        stateLock.withLock { running = true }
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        stateLock.withLock { running = false }
        server.stop()
    }

    private func acceptLoop() {
        while stateLock.withLock({ running }) {
            do {
                let connection = try server.accept()
                connectionQueue.async { [weak self] in
                    self?.handle(connection)
                }
            } catch {
                if !stateLock.withLock({ running }) {
                    return
                }
                fputs("Markdown Card IPC accept failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private func handle(_ connection: UnixDomainSocketConnection) {
        let payload: Data
        do {
            payload = try connection.receivePayload()
        } catch IPCFrameError.truncatedFrame {
            // The peer has gone away, so there is no connection on which to report an error.
            connection.close()
            return
        } catch {
            let code: String
            if case IPCFrameError.payloadTooLarge = error {
                code = "payload_too_large"
            } else {
                code = "invalid_frame"
            }
            sendFailure(
                over: connection,
                requestID: Self.fallbackRequestID,
                code: code,
                message: error.localizedDescription
            )
            return
        }

        let extractedRequestID = Self.extractRequestID(from: payload) ?? Self.fallbackRequestID
        if let protocolVersion = Self.extractProtocolVersion(from: payload),
           protocolVersion != markdownCardProtocolVersion
        {
            sendFailure(
                over: connection,
                requestID: extractedRequestID,
                code: "unsupported_protocol",
                message: "Incompatible mdcard protocol v\(protocolVersion); this agent requires v\(markdownCardProtocolVersion). Upgrade the CLI and app together."
            )
            return
        }
        let request: AgentRequest
        do {
            request = try IPCFrameCodec.decode(AgentRequest.self, payload: payload)
        } catch let error as AgentRequestDecodingError {
            sendFailure(
                over: connection,
                requestID: error.requestID,
                code: "invalid_command",
                message: error.localizedDescription
            )
            return
        } catch {
            sendFailure(
                over: connection,
                requestID: extractedRequestID,
                code: "invalid_request",
                message: error.localizedDescription
            )
            return
        }

        Task { [handler] in
            let response: AgentResponse
            if request.protocolVersion != markdownCardProtocolVersion {
                response = .failure(
                    requestID: request.requestID,
                    code: "unsupported_protocol",
                    message: "Incompatible mdcard protocol v\(request.protocolVersion); this agent requires v\(markdownCardProtocolVersion). Upgrade the CLI and app together."
                )
            } else {
                response = await handler(request)
            }

            do {
                try connection.sendResponse(response)
            } catch {
                fputs("Markdown Card IPC response failed: \(error.localizedDescription)\n", stderr)
            }
            connection.close()
        }
    }

    private func sendFailure(
        over connection: UnixDomainSocketConnection,
        requestID: UUID,
        code: String,
        message: String
    ) {
        defer { connection.close() }
        do {
            try connection.sendResponse(
                .failure(requestID: requestID, code: code, message: message)
            )
        } catch {
            fputs("Markdown Card IPC error response failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func extractRequestID(from payload: Data) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let dictionary = object as? [String: Any],
              let requestID = dictionary["requestID"] as? String
        else { return nil }
        return UUID(uuidString: requestID)
    }

    private static func extractProtocolVersion(from payload: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let dictionary = object as? [String: Any],
              let version = dictionary["protocolVersion"] as? NSNumber
        else { return nil }
        return version.intValue
    }
}
