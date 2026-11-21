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
    case outputTooLarge(executable: String, limit: Int)
    case cancelled(executable: String)

    public var description: String {
        switch self {
        case let .launchFailed(exe, err): "Failed to launch \(exe): \(err)"
        case let .timedOut(exe, s): "\(exe) did not finish within \(Int(s)) s"
        case let .outputTooLarge(exe, limit): "\(exe) produced more than \(limit / 1_048_576) MB of output; stopped"
        case let .cancelled(exe): "\(exe) was cancelled"
        }
    }
}

/// Runs external tools (git, ssh, dolt) without a shell. Arguments are passed as argv, never interpolated.
public enum ProcessRunner {
    /// Default cap for collected stdout (data comes from untrusted repositories).
    public static let defaultOutputLimit = 64 * 1_048_576
    static let stderrLimit = 1_048_576
    /// Grace period between SIGTERM and SIGKILL.
    static let killGrace: Double = 5

    /// - Parameters:
    ///   - stdoutFile: when set, stdout is streamed into this file instead of being collected in memory.
    ///   - outputLimit: max bytes of collected stdout; exceeding it kills the process and throws `outputTooLarge`.
    ///   - sandboxProfile: when set, the tool runs under `sandbox-exec -p <profile>`.
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        stdoutFile: URL? = nil,
        timeout: Double = 120,
        outputLimit: Int = defaultOutputLimit,
        sandboxProfile: String? = nil
    ) async throws -> ProcessOutput {
        let process = Process()
        if let sandboxProfile {
            process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", sandboxProfile, executable.path] + arguments
        } else {
            process.executableURL = executable
            process.arguments = arguments
        }
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

        let reason = StopReason()
        let stopper = Stopper(process: process)

        // Drain pipes concurrently so a full pipe buffer can never deadlock the child. Reading stops
        // accumulating past the limit and the process is killed.
        // Pipe reads block a thread until EOF: they run on GCD threads, never on the Swift concurrency pool
        // (blocking that pool starves every other task, including the timeout below, on machines with few cores).
        let outReader = outPipe?.fileHandleForReading
        async let outData: Data = onBlockingThread {
            guard let handle = outReader else { return Data() }
            return drain(handle, limit: outputLimit) { reason.set(.outputTooLarge); stopper.stop() }
        }
        async let errData: Data = onBlockingThread {
            drain(errPipe.fileHandleForReading, limit: stderrLimit) {}
        }

        // A GCD timer, independent of the concurrency pool, so it fires on time under load.
        let timeoutTimer = DispatchWorkItem {
            guard process.isRunning else { return }
            reason.set(.timedOut)
            stopper.stop()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutTimer)

        let status: Int32 = await withTaskCancellationHandler {
            var status: Int32 = -1
            for await s in exited.stream { status = s }
            return status
        } onCancel: {
            reason.set(.cancelled)
            stopper.stop()
        }
        timeoutTimer.cancel()
        let (out, err) = await (outData, errData)

        switch reason.value {
        case .timedOut: throw ProcessError.timedOut(executable: executable.lastPathComponent, seconds: timeout)
        case .outputTooLarge: throw ProcessError.outputTooLarge(executable: executable.lastPathComponent, limit: outputLimit)
        case .cancelled: throw ProcessError.cancelled(executable: executable.lastPathComponent)
        case nil: return ProcessOutput(status: status, stdout: out, stderr: err)
        }
    }

    /// Runs blocking work on a GCD thread and resumes the caller when it finishes.
    static func onBlockingThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }

    /// Reads until EOF; keeps at most `limit` bytes and calls `overflow` once when exceeded (still draining).
    static func drain(_ handle: FileHandle, limit: Int, overflow: () -> Void) -> Data {
        var data = Data()
        var overflowed = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count + chunk.count > limit {
                if !overflowed { overflowed = true; overflow() }
                continue
            }
            data.append(chunk)
        }
        return data
    }
}

/// Why a process was stopped by us (first reason wins).
private final class StopReason: @unchecked Sendable {
    enum Kind { case timedOut, outputTooLarge, cancelled }
    private let lock = NSLock()
    private var kind: Kind?
    func set(_ k: Kind) { lock.withLock { if kind == nil { kind = k } } }
    var value: Kind? { lock.withLock { kind } }
}

/// SIGTERM, then SIGKILL after a grace period if the process is still alive.
private final class Stopper: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var stopping = false

    init(process: Process) { self.process = process }

    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopping = true }
            return !stopping
        }
        guard first, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + ProcessRunner.killGrace) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
