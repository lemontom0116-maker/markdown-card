import Foundation

public enum IPCFrameError: Error, Equatable, LocalizedError, Sendable {
    case payloadTooLarge(actual: Int, maximum: Int)
    case invalidLength(Int)
    case truncatedFrame

    public var errorDescription: String? {
        switch self {
        case let .payloadTooLarge(actual, maximum):
            "IPC payload is \(actual) bytes; the maximum is \(maximum) bytes."
        case let .invalidLength(length):
            "IPC frame declares an invalid payload length of \(length) bytes."
        case .truncatedFrame:
            "The IPC connection closed before the complete frame arrived."
        }
    }
}

public enum IPCFrameCodec {
    public static let headerSize = MemoryLayout<UInt32>.size
    public static let maximumPayloadSize = 4 * 1024 * 1024

    public static func encode<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder = JSONEncoder(),
        maximumPayloadSize: Int = maximumPayloadSize
    ) throws -> Data {
        try frame(
            payload: encoder.encode(value),
            maximumPayloadSize: maximumPayloadSize
        )
    }

    public static func frame(
        payload: Data,
        maximumPayloadSize: Int = maximumPayloadSize
    ) throws -> Data {
        guard payload.count <= maximumPayloadSize else {
            throw IPCFrameError.payloadTooLarge(actual: payload.count, maximum: maximumPayloadSize)
        }
        guard payload.count <= Int(UInt32.max) else {
            throw IPCFrameError.invalidLength(payload.count)
        }

        var length = UInt32(payload.count).bigEndian
        var result = Data(bytes: &length, count: headerSize)
        result.append(payload)
        return result
    }

    public static func payloadLength(from header: Data) throws -> Int {
        guard header.count == headerSize else { throw IPCFrameError.truncatedFrame }
        let bytes = [UInt8](header)
        let length = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int(length)
    }

    public static func decode<T: Decodable>(
        _ type: T.Type,
        payload: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        try decoder.decode(type, from: payload)
    }
}

public struct IPCFrameDecoder: Sendable {
    public let maximumPayloadSize: Int
    private var buffer = Data()

    public init(maximumPayloadSize: Int = IPCFrameCodec.maximumPayloadSize) {
        self.maximumPayloadSize = maximumPayloadSize
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while buffer.count >= IPCFrameCodec.headerSize {
            let headerEnd = buffer.index(
                buffer.startIndex,
                offsetBy: IPCFrameCodec.headerSize
            )
            let header = buffer[buffer.startIndex..<headerEnd]
            let length = try IPCFrameCodec.payloadLength(from: Data(header))
            guard length <= maximumPayloadSize else {
                throw IPCFrameError.payloadTooLarge(actual: length, maximum: maximumPayloadSize)
            }
            let frameLength = IPCFrameCodec.headerSize + length
            guard buffer.count >= frameLength else { break }
            let frameEnd = buffer.index(buffer.startIndex, offsetBy: frameLength)
            frames.append(Data(buffer[headerEnd..<frameEnd]))
            buffer.removeSubrange(buffer.startIndex..<frameEnd)
        }

        return frames
    }

    public var bufferedByteCount: Int { buffer.count }
}
