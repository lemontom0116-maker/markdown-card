import Darwin
import Foundation

public enum IPCSocketPath {
    public static let prefix = "com.garden100.MarkdownCard"

    public static var defaultPath: String {
        "/tmp/\(prefix).\(geteuid()).sock"
    }
}

public enum UnixSocketError: Error, Equatable, LocalizedError, Sendable {
    case systemCall(operation: String, code: Int32)
    case pathTooLong(String)
    case unsafeExistingPath(String)
    case socketAlreadyActive(String)
    case peerUserMismatch(expected: uid_t, actual: uid_t)
    case connectionClosed
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .systemCall(operation, code):
            "\(operation) failed (errno \(code)): \(String(cString: strerror(code)))"
        case let .pathTooLong(path):
            "Unix socket path is too long: \(path)"
        case let .unsafeExistingPath(path):
            "Refusing to replace an unsafe path at \(path)."
        case let .socketAlreadyActive(path):
            "Another agent is already listening at \(path)."
        case let .peerUserMismatch(expected, actual):
            "IPC peer UID \(actual) does not match the current UID \(expected)."
        case .connectionClosed:
            "The IPC peer closed the connection."
        case let .invalidResponse(message):
            "Invalid agent response: \(message)"
        }
    }
}

public struct UnixDomainSocketClient: Sendable {
    public var path: String
    public var timeout: TimeInterval
    public var maximumPayloadSize: Int

    public init(
        path: String = IPCSocketPath.defaultPath,
        timeout: TimeInterval = 1,
        maximumPayloadSize: Int = IPCFrameCodec.maximumPayloadSize
    ) {
        self.path = path
        self.timeout = timeout
        self.maximumPayloadSize = maximumPayloadSize
    }

    public func send(_ request: AgentRequest) throws -> AgentResponse {
        let descriptor = try SocketPrimitives.makeStreamSocket(timeout: timeout)
        defer { Darwin.close(descriptor) }

        try SocketPrimitives.withAddress(path: path) { address, length in
            guard Darwin.connect(descriptor, address, length) == 0 else {
                throw UnixSocketError.systemCall(operation: "connect", code: errno)
            }
        }
        try SocketPrimitives.verifyPeerUser(descriptor)

        let requestData = try IPCFrameCodec.encode(
            request,
            maximumPayloadSize: maximumPayloadSize
        )
        try SocketPrimitives.writeAll(descriptor, data: requestData)
        let responsePayload = try SocketPrimitives.readFrame(
            descriptor,
            maximumPayloadSize: maximumPayloadSize
        )
        let response = try IPCFrameCodec.decode(AgentResponse.self, payload: responsePayload)
        guard response.requestID == request.requestID else {
            throw UnixSocketError.invalidResponse("request ID does not match")
        }
        return response
    }
}

public final class UnixDomainSocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    public let maximumPayloadSize: Int

    fileprivate init(descriptor: Int32, maximumPayloadSize: Int) {
        self.descriptor = descriptor
        self.maximumPayloadSize = maximumPayloadSize
    }

    deinit {
        close()
    }

    public func receiveRequest() throws -> AgentRequest {
        try IPCFrameCodec.decode(AgentRequest.self, payload: receivePayload())
    }

    /// Receives one validated frame while leaving request decoding to the caller.
    /// This lets the agent return a structured protocol error for malformed JSON.
    public func receivePayload() throws -> Data {
        let descriptor = try openDescriptor()
        return try SocketPrimitives.readFrame(
            descriptor,
            maximumPayloadSize: maximumPayloadSize
        )
    }

    public func sendResponse(_ response: AgentResponse) throws {
        let descriptor = try openDescriptor()
        let data = try IPCFrameCodec.encode(
            response,
            maximumPayloadSize: maximumPayloadSize
        )
        try SocketPrimitives.writeAll(descriptor, data: data)
    }

    public func close() {
        lock.lock()
        let descriptor = self.descriptor
        self.descriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    private func openDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw UnixSocketError.connectionClosed }
        return descriptor
    }
}

public final class UnixDomainSocketServer: @unchecked Sendable {
    public let path: String
    public let maximumPayloadSize: Int
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var boundSocketIdentity: SocketIdentity?

    public init(
        path: String = IPCSocketPath.defaultPath,
        maximumPayloadSize: Int = IPCFrameCodec.maximumPayloadSize
    ) {
        self.path = path
        self.maximumPayloadSize = maximumPayloadSize
    }

    deinit {
        stop()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor < 0 else { return }

        try SocketPrimitives.removeStaleSocketIfSafe(path: path)
        let newDescriptor = try SocketPrimitives.makeStreamSocket(timeout: nil)
        var createdIdentity: SocketIdentity?
        do {
            try SocketPrimitives.withAddress(path: path) { address, length in
                guard Darwin.bind(newDescriptor, address, length) == 0 else {
                    throw UnixSocketError.systemCall(operation: "bind", code: errno)
                }
            }
            guard let identity = try SocketPrimitives.ownedSocketIdentity(path: path) else {
                throw UnixSocketError.systemCall(operation: "lstat(bound socket)", code: ENOENT)
            }
            createdIdentity = identity
            guard Darwin.chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                throw UnixSocketError.systemCall(operation: "chmod", code: errno)
            }
            guard Darwin.listen(newDescriptor, 16) == 0 else {
                throw UnixSocketError.systemCall(operation: "listen", code: errno)
            }
            descriptor = newDescriptor
            boundSocketIdentity = createdIdentity
        } catch {
            Darwin.close(newDescriptor)
            if let createdIdentity {
                SocketPrimitives.removeOwnedSocket(path: path, matching: createdIdentity)
            }
            throw error
        }
    }

    public func accept() throws -> UnixDomainSocketConnection {
        let serverDescriptor: Int32 = try lock.withLock {
            guard descriptor >= 0 else { throw UnixSocketError.connectionClosed }
            return descriptor
        }

        while true {
            let clientDescriptor = Darwin.accept(serverDescriptor, nil, nil)
            if clientDescriptor >= 0 {
                do {
                    try SocketPrimitives.configure(descriptor: clientDescriptor, timeout: 2)
                    try SocketPrimitives.verifyPeerUser(clientDescriptor)
                    return UnixDomainSocketConnection(
                        descriptor: clientDescriptor,
                        maximumPayloadSize: maximumPayloadSize
                    )
                } catch {
                    Darwin.close(clientDescriptor)
                    throw error
                }
            }
            if errno == EINTR { continue }
            throw UnixSocketError.systemCall(operation: "accept", code: errno)
        }
    }

    public func stop() {
        lock.lock()
        let descriptor = self.descriptor
        let boundSocketIdentity = self.boundSocketIdentity
        self.descriptor = -1
        self.boundSocketIdentity = nil
        lock.unlock()

        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        if let boundSocketIdentity {
            SocketPrimitives.removeOwnedSocket(path: path, matching: boundSocketIdentity)
        }
    }
}

private struct SocketIdentity: Equatable {
    var device: dev_t
    var inode: ino_t
}

private enum SocketPrimitives {
    static func makeStreamSocket(timeout: TimeInterval?) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UnixSocketError.systemCall(operation: "socket", code: errno)
        }
        do {
            try configure(descriptor: descriptor, timeout: timeout)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func configure(descriptor: Int32, timeout: TimeInterval?) throws {
        guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            throw UnixSocketError.systemCall(operation: "fcntl", code: errno)
        }

        var noSignal: Int32 = 1
        guard Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else {
            throw UnixSocketError.systemCall(operation: "setsockopt(SO_NOSIGPIPE)", code: errno)
        }

        if let timeout {
            let clamped = max(timeout, 0.001)
            var value = timeval(
                tv_sec: Int(clamped),
                tv_usec: Int32((clamped - floor(clamped)) * 1_000_000)
            )
            let valueSize = socklen_t(MemoryLayout.size(ofValue: value))
            guard Darwin.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, valueSize) == 0 else {
                throw UnixSocketError.systemCall(operation: "setsockopt(SO_RCVTIMEO)", code: errno)
            }
            guard Darwin.setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, valueSize) == 0 else {
                throw UnixSocketError.systemCall(operation: "setsockopt(SO_SNDTIMEO)", code: errno)
            }
        }
    }

    static func withAddress<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw UnixSocketError.pathTooLong(path) }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in bytes.indices {
                    destination[index] = bytes[index]
                }
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                try body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func verifyPeerUser(_ descriptor: Int32) throws {
        var user: uid_t = 0
        var group: gid_t = 0
        guard Darwin.getpeereid(descriptor, &user, &group) == 0 else {
            throw UnixSocketError.systemCall(operation: "getpeereid", code: errno)
        }
        let expected = geteuid()
        guard user == expected else {
            throw UnixSocketError.peerUserMismatch(expected: expected, actual: user)
        }
    }

    static func writeAll(_ descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written == 0 {
                    throw UnixSocketError.connectionClosed
                } else {
                    throw UnixSocketError.systemCall(operation: "write", code: errno)
                }
            }
        }
    }

    static func readFrame(_ descriptor: Int32, maximumPayloadSize: Int) throws -> Data {
        let header = try readExactly(descriptor, count: IPCFrameCodec.headerSize)
        let length = try IPCFrameCodec.payloadLength(from: header)
        guard length <= maximumPayloadSize else {
            throw IPCFrameError.payloadTooLarge(actual: length, maximum: maximumPayloadSize)
        }
        return try readExactly(descriptor, count: length)
    }

    static func readExactly(_ descriptor: Int32, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < count {
                let received = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if received > 0 {
                    offset += received
                } else if received < 0 && errno == EINTR {
                    continue
                } else if received == 0 {
                    throw IPCFrameError.truncatedFrame
                } else {
                    throw UnixSocketError.systemCall(operation: "read", code: errno)
                }
            }
        }
        return data
    }

    static func removeStaleSocketIfSafe(path: String) throws {
        guard let originalIdentity = try ownedSocketIdentity(path: path) else { return }

        let probe = try makeStreamSocket(timeout: 0.2)
        let connectionResult: Int32
        let connectionError: Int32
        do {
            connectionResult = try withAddress(path: path) { address, length in
                Darwin.connect(probe, address, length)
            }
            connectionError = connectionResult == 0 ? 0 : errno
        } catch {
            Darwin.close(probe)
            throw error
        }
        Darwin.close(probe)

        if connectionResult == 0 {
            throw UnixSocketError.socketAlreadyActive(path)
        }
        if connectionError == ENOENT { return }
        guard connectionError == ECONNREFUSED else {
            throw UnixSocketError.systemCall(
                operation: "connect(existing socket)",
                code: connectionError
            )
        }

        // The pathname may have been replaced between the probe and removal.
        // Only unlink the exact stale socket that was inspected above.
        guard let currentIdentity = try ownedSocketIdentity(path: path) else { return }
        guard currentIdentity == originalIdentity else {
            throw UnixSocketError.unsafeExistingPath(path)
        }
        guard Darwin.unlink(path) == 0 else {
            if errno == ENOENT { return }
            throw UnixSocketError.systemCall(operation: "unlink", code: errno)
        }
    }

    static func ownedSocketIdentity(path: String) throws -> SocketIdentity? {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw UnixSocketError.systemCall(operation: "lstat", code: errno)
        }
        let fileType = info.st_mode & S_IFMT
        guard info.st_uid == geteuid(), fileType == S_IFSOCK else {
            throw UnixSocketError.unsafeExistingPath(path)
        }
        return SocketIdentity(device: info.st_dev, inode: info.st_ino)
    }

    static func removeOwnedSocket(path: String, matching identity: SocketIdentity) {
        guard let currentIdentity = try? ownedSocketIdentity(path: path),
              currentIdentity == identity
        else { return }
        Darwin.unlink(path)
    }
}
