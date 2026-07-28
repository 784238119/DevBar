import Foundation

/// Removes terminal controls before text reaches the UI or rotating log files.
///
/// DevBar deliberately does not guess which command output is secret. Environment
/// dictionaries are never serialized, while stdout/stderr remain user-controlled.
public struct LogSanitizer: Sendable {
    private enum TerminalState: Sendable {
        case text
        case escape
        case csi
        case osc
        case oscEscape
    }

    private var terminalState: TerminalState = .text
    private var previousWasCarriageReturn = false
    public init() {}

    public mutating func append(_ input: String) -> String {
        var terminalClean = String.UnicodeScalarView()

        for scalar in input.unicodeScalars {
            switch terminalState {
            case .text:
                switch scalar.value {
                case 0x1B:
                    terminalState = .escape
                case 0x0D:
                    terminalClean.append("\n")
                    previousWasCarriageReturn = true
                case 0x0A:
                    if !previousWasCarriageReturn { terminalClean.append("\n") }
                    previousWasCarriageReturn = false
                case 0x09:
                    terminalClean.append(scalar)
                    previousWasCarriageReturn = false
                case 0x00 ... 0x1F, 0x7F:
                    previousWasCarriageReturn = false
                default:
                    terminalClean.append(scalar)
                    previousWasCarriageReturn = false
                }
            case .escape:
                previousWasCarriageReturn = false
                switch scalar.value {
                case 0x5B: terminalState = .csi // ESC [
                case 0x5D: terminalState = .osc // ESC ]
                case 0x1B: terminalState = .escape
                default: terminalState = .text
                }
            case .csi:
                if (0x40 ... 0x7E).contains(scalar.value) { terminalState = .text }
            case .osc:
                if scalar.value == 0x07 {
                    terminalState = .text
                } else if scalar.value == 0x1B {
                    terminalState = .oscEscape
                }
            case .oscEscape:
                terminalState = scalar.value == 0x5C ? .text : .osc
            }
        }

        return String(terminalClean)
    }

    public mutating func finish() -> String {
        terminalState = .text
        previousWasCarriageReturn = false
        return ""
    }
}
