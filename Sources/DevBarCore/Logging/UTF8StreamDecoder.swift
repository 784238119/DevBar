import Foundation

/// Incrementally decodes a byte stream without converting an incomplete trailing scalar
/// into a replacement character until the stream is finished.
public struct UTF8StreamDecoder: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) -> String {
        pending.append(data)
        var output = String.UnicodeScalarView()
        var offset = pending.startIndex

        while offset < pending.endIndex {
            let byte = pending[offset]
            if byte < 0x80 {
                output.append(UnicodeScalar(byte))
                offset += 1
                continue
            }

            guard let sequenceLength = expectedLength(for: byte) else {
                output.append("\u{FFFD}")
                offset += 1
                continue
            }

            let available = pending.distance(from: offset, to: pending.endIndex)
            guard available >= sequenceLength else { break }

            let bytes = (0 ..< sequenceLength).map { pending[pending.index(offset, offsetBy: $0)] }
            guard let scalar = validScalar(bytes) else {
                output.append("\u{FFFD}")
                offset += 1
                continue
            }
            output.append(scalar)
            offset += sequenceLength
        }

        if offset > pending.startIndex {
            pending.removeSubrange(pending.startIndex ..< offset)
        }
        return String(output)
    }

    /// Flushes incomplete trailing bytes as replacement characters when the pipe closes.
    public mutating func finish() -> String {
        guard !pending.isEmpty else { return "" }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return text
    }

    private func expectedLength(for byte: UInt8) -> Int? {
        switch byte {
        case 0xC2 ... 0xDF: 2
        case 0xE0 ... 0xEF: 3
        case 0xF0 ... 0xF4: 4
        default: nil
        }
    }

    private func validScalar(_ bytes: [UInt8]) -> UnicodeScalar? {
        guard bytes.dropFirst().allSatisfy({ $0 & 0xC0 == 0x80 }) else { return nil }
        let value: UInt32
        switch bytes.count {
        case 2:
            value = (UInt32(bytes[0] & 0x1F) << 6) | UInt32(bytes[1] & 0x3F)
        case 3:
            value = (UInt32(bytes[0] & 0x0F) << 12) | (UInt32(bytes[1] & 0x3F) << 6) | UInt32(bytes[2] & 0x3F)
        case 4:
            value = (UInt32(bytes[0] & 0x07) << 18) | (UInt32(bytes[1] & 0x3F) << 12) | (UInt32(bytes[2] & 0x3F) << 6) | UInt32(bytes[3] & 0x3F)
        default:
            return nil
        }
        guard value <= 0x10FFFF, !(0xD800 ... 0xDFFF).contains(value) else { return nil }
        return UnicodeScalar(value)
    }
}
