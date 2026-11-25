import Foundation

/// One reader thread writes it, and only after the group wait does anyone read it.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

enum CommandRunner {
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try runSync(executable, arguments: arguments, timeout: timeout)
        }.value
    }

    private static func runSync(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let semaphore = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in semaphore.signal() }

        try process.run()

        // Read both pipes while the process runs. Reading only after it exits stalls any
        // tool that prints more than the pipe buffer (about 64 KB): it blocks on write,
        // never exits, and the call waits out the whole timeout.
        let readers = DispatchGroup()
        let outputBox = DataBox()
        let errorBox = DataBox()
        for (pipe, box) in [(stdout, outputBox), (stderr, errorBox)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw InkfallError.commandFailed("Local command timed out")
        }

        readers.wait()
        let outputData = outputBox.data
        let errorData = errorBox.data
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus == 0 {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw InkfallError.commandFailed(error.isEmpty ? output : error)
    }
}
