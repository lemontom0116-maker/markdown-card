import Darwin
import Foundation
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

final class AgentCommandServerTests: XCTestCase {
    private let zeroRequestID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    func testUnknownCommandReturnsStructuredErrorAndPreservesRequestID() throws {
        let requestID = UUID()
        let payload = Data(
            """
            {
              "protocolVersion": 5,
              "requestID": "\(requestID.uuidString)",
              "command": { "type": "future-command" }
            }
            """.utf8
        )

        let response = try exchange(payload: payload)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.requestID, requestID)
        XCTAssertEqual(response.error?.code, "invalid_command")
    }

    func testMalformedJSONReturnsStructuredErrorWithFallbackRequestID() throws {
        let response = try exchange(payload: Data("{ definitely-not-json".utf8))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.requestID, zeroRequestID)
        XCTAssertEqual(response.error?.code, "invalid_request")
    }

    func testProtocolV4ReturnsExplicitUpgradeError() throws {
        let request = AgentRequest(protocolVersion: 4, command: .quit)
        let response = try exchange(payload: JSONEncoder().encode(request))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.error?.code, "unsupported_protocol")
        XCTAssertTrue(response.error?.message.contains("Upgrade the CLI and app together") == true)
    }

    func testLegacyShowShapeIsRejectedAsProtocolMismatchBeforeCommandDecoding() throws {
        let requestID = UUID()
        let payload = Data(
            """
            {
              "protocolVersion": 2,
              "requestID": "\(requestID.uuidString)",
              "command": {
                "type": "show",
                "options": { "markdown": "# Legacy", "pin": true, "edit": false }
              }
            }
            """.utf8
        )
        let response = try exchange(payload: payload)

        XCTAssertEqual(response.error?.code, "unsupported_protocol")
        XCTAssertEqual(response.requestID, requestID)
    }

    func testInvalidRequestFieldsPreserveExtractableRequestID() throws {
        let requestID = UUID()
        let payload = Data(
            """
            {
              "protocolVersion": "wrong-type",
              "requestID": "\(requestID.uuidString)",
              "command": { "type": "quit" }
            }
            """.utf8
        )

        let response = try exchange(payload: payload)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.requestID, requestID)
        XCTAssertEqual(response.error?.code, "invalid_request")
    }

    func testOversizedFrameReturnsStructuredErrorWithFallbackRequestID() throws {
        let response = try exchange(payload: Data(count: 257), maximumPayloadSize: 256)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.requestID, zeroRequestID)
        XCTAssertEqual(response.error?.code, "payload_too_large")
    }

    private func exchange(
        payload: Data,
        declaredLength: UInt32? = nil,
        maximumPayloadSize: Int = IPCFrameCodec.maximumPayloadSize
    ) throws -> AgentResponse {
        let path = "/tmp/mdcard-command-server-tests-\(UUID().uuidString).sock"
        let socketServer = UnixDomainSocketServer(
            path: path,
            maximumPayloadSize: maximumPayloadSize
        )
        let commandServer = AgentCommandServer(server: socketServer) { request in
            .success(requestID: request.requestID)
        }
        try commandServer.start()
        defer { commandServer.stop() }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXTestError(operation: "socket", code: errno) }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout.size(ofValue: timeout))
        guard Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            timeoutSize
        ) == 0 else {
            throw POSIXTestError(operation: "setsockopt", code: errno)
        }

        try withSocketAddress(path: path) { address, length in
            guard Darwin.connect(descriptor, address, length) == 0 else {
                throw POSIXTestError(operation: "connect", code: errno)
            }
        }

        var length = (declaredLength ?? UInt32(payload.count)).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll(descriptor, bytes: $0) }
        if !payload.isEmpty {
            try payload.withUnsafeBytes { try writeAll(descriptor, bytes: $0) }
        }

        let header = try readExactly(descriptor, count: IPCFrameCodec.headerSize)
        let responseLength = try IPCFrameCodec.payloadLength(from: header)
        let responsePayload = try readExactly(descriptor, count: responseLength)
        return try IPCFrameCodec.decode(AgentResponse.self, payload: responsePayload)
    }

    private func withSocketAddress<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw POSIXTestError(operation: "path", code: ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in bytes.indices { destination[index] = bytes[index] }
            }
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func writeAll(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws {
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                bytes.count - offset
            )
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw POSIXTestError(operation: "write", code: errno)
            }
        }
    }

    private func readExactly(_ descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < count {
                let received = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
                if received > 0 {
                    offset += received
                } else if received < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXTestError(operation: "read", code: received == 0 ? ECONNRESET : errno)
                }
            }
        }
        return data
    }
}

private struct POSIXTestError: Error {
    var operation: String
    var code: Int32
}
