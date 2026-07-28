import Darwin
import DevBarCore
import Foundation

public enum RunnerChannelError: Error, Equatable, Sendable, LocalizedError {
    case endOfFile
    case lineTooLong
    case systemCall(operation: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .endOfFile:
            "Runner control channel closed."
        case .lineTooLong:
            "Runner control message exceeds 1 MiB."
        case let .systemCall(operation, code):
            "\(operation) failed: \(String(cString: strerror(code)))."
        }
    }
}

/// Low-level framing for the control and event pipes. Raw service output bypasses this type.
public enum RunnerChannel {
    public static let maximumLineLength = 1_048_576

    public static func readLine(from descriptor: Int32) throws -> Data {
        var line = Data()
        var byte: UInt8 = 0

        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 0 { throw RunnerChannelError.endOfFile }
            if count < 0 {
                if errno == EINTR { continue }
                throw RunnerChannelError.systemCall(operation: "read", errno: errno)
            }
            line.append(byte)
            if byte == 0x0A { return line }
            if line.count > maximumLineLength { throw RunnerChannelError.lineTooLong }
        }
    }

    public static func writeLine<Value: Encodable>(_ value: Value, to descriptor: Int32) throws {
        try writeAll(RunnerCodec.encodeLine(value), to: descriptor)
    }

    public static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                throw RunnerChannelError.systemCall(operation: "write", errno: errno)
            }
        }
    }
}
