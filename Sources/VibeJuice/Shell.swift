import Foundation

/// The one way this app runs a child process. Both pipes are drained while the child runs (so a
/// chatty child never deadlocks on a full pipe), stdin is fed and closed, a timeout terminates
/// then kills, and the child is always reaped before returning. Synchronous by design: every
/// caller already sits on a serial queue or a detached task, never on the main actor.
enum Shell {
    struct Result: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
        var ok: Bool { status == 0 && !timedOut }
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    static func run(_ path: String, _ args: [String], stdin input: Data? = nil, cwd: String? = nil,
                    env: [String: String]? = nil, timeout: TimeInterval? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = input.map { _ in Pipe() }
        p.standardInput = inPipe ?? FileHandle.nullDevice
        let outBuf = Buffer(), errBuf = Buffer()
        out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; d.isEmpty ? (h.readabilityHandler = nil) : outBuf.append(d) }
        err.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; d.isEmpty ? (h.readabilityHandler = nil) : errBuf.append(d) }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return Result(status: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8), timedOut: false)
        }
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        var timedOut = false
        if let timeout, done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        // Whatever is still buffered in the pipes after exit.
        outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
        errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        return Result(status: p.terminationStatus, stdout: outBuf.data, stderr: errBuf.data, timedOut: timedOut)
    }

    /// Fire and forget, for GUI apps and terminal launchers whose lifetime is not ours.
    static func launch(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ d: Data) { guard !d.isEmpty else { return }; lock.lock(); bytes.append(d); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }
}
