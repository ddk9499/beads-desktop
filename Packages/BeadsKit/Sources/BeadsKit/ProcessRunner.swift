import Foundation

/// Result of a finished child process.
public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessError: Error, Sendable, CustomStringConvertible {
    case launchFailed(executable: String, underlying: String)
    case timedOut(executable: String, seconds: Double)

    public var description: String {
        switch self {
        case let .launchFailed(exe, err): "Failed to launch \(exe): \(err)"
        case let .timedOut(exe, s): "\(exe) did not finish within \(Int(s)) s"
        }
    }
}

/// Runs external tools (git, ssh, dolt) without a shell. Arguments are passed as argv, never interpolated.
public enum ProcessRunner {
    /// - Parameters:
    ///   - stdoutFile: when set, stdout is streamed into this file instead of being collected in memory.
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        stdoutFile: URL? = nil,
        timeout: Double = 120
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe

        var outPipe: Pipe?
        var outHandle: FileHandle?
        if let stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: stdoutFile)
            outHandle = handle
            process.standardOutput = handle
        } else {
            let pipe = Pipe()
            outPipe = pipe
            process.standardOutput = pipe
        }
        defer { try? outHandle?.close() }

        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { p in
            exited.continuation.yield(p.terminationStatus)
            exited.continuation.finish()
        }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(executable: executable.path, underlying: "\(error)")
        }

        // Drain pipes concurrently so a full pipe buffer can never deadlock the child.
        async let outData: Data = Task.detached { outPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data() }.value
        async let errData: Data = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }.value

        let timedOut = TimeoutFlag()
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }

        var status: Int32 = -1
        for await s in exited.stream { status = s }
        timeoutTask.cancel()
        let (out, err) = await (outData, errData)

        if timedOut.isSet {
            throw ProcessError.timedOut(executable: executable.lastPathComponent, seconds: timeout)
        }
        return ProcessOutput(status: status, stdout: out, stderr: err)
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
