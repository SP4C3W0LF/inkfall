import Foundation

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

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw InkfallError.commandFailed("Local command timed out")
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus == 0 {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw InkfallError.commandFailed(error.isEmpty ? output : error)
    }
}
