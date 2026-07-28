import Foundation
import Darwin
import DevBarCore
import DevBarRunnerKit

private struct RunnerDescriptorArguments {
    let commandReadFD: Int32
    let eventWriteFD: Int32
    let stdoutWriteFD: Int32
    let stderrWriteFD: Int32

    init?(arguments: [String]) {
        guard arguments.count == 9 else { return nil }
        var values: [String: Int32] = [:]
        var index = 1
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), let value = Int32(arguments[index + 1]), value > STDERR_FILENO else {
                return nil
            }
            guard values[name] == nil else { return nil }
            values[name] = value
            index += 2
        }
        guard
            let commandReadFD = values["--command-fd"],
            let eventWriteFD = values["--event-fd"],
            let stdoutWriteFD = values["--stdout-fd"],
            let stderrWriteFD = values["--stderr-fd"],
            values.count == 4,
            Set([commandReadFD, eventWriteFD, stdoutWriteFD, stderrWriteFD]).count == 4
        else {
            return nil
        }
        self.commandReadFD = commandReadFD
        self.eventWriteFD = eventWriteFD
        self.stdoutWriteFD = stdoutWriteFD
        self.stderrWriteFD = stderrWriteFD
    }
}

signal(SIGPIPE, SIG_IGN)

guard let descriptors = RunnerDescriptorArguments(arguments: CommandLine.arguments) else {
    FileHandle.standardError.write(Data("DevBarRunner requires four distinct --*-fd arguments above standard I/O.\n".utf8))
    exit(64)
}

let session = RunnerSession(
    commandReadFD: descriptors.commandReadFD,
    eventWriteFD: descriptors.eventWriteFD,
    stdoutWriteFD: descriptors.stdoutWriteFD,
    stderrWriteFD: descriptors.stderrWriteFD
)
let exitCode = await session.run()
exit(exitCode)
