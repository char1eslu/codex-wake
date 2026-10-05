import Foundation

package struct Shell {
    package static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw WakeError.commandFailed(message)
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }

    /// Runs `executable` and returns its standard output as raw bytes.
    ///
    /// Unlike ``run(_:_:)`` this drains both pipes concurrently. A decompressed
    /// rollout is far larger than the 64 KB pipe buffer, so reading stdout only
    /// after `waitUntilExit()` would deadlock on every non-trivial chat.
    package static func runData(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()

        let outputBox = DataBox()
        let errorBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputBox.value = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorBox.value = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(data: errorBox.value, encoding: .utf8) ?? "Unknown error"
            throw WakeError.commandFailed(message)
        }
        return outputBox.value
    }

    /// Runs `executable` and feeds its standard output to `body` one chunk at a
    /// time, so a large stream can be scanned without being held in memory.
    ///
    /// `body` returns `true` to keep reading and `false` to stop early. The
    /// return value reports whether `body` stopped the stream; a non-zero exit
    /// status is only reported as an error when it was not stopped early.
    @discardableResult
    package static func streamData(
        _ executable: String,
        _ arguments: [String],
        chunkSize: Int,
        _ body: (Data) -> Bool
    ) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()

        let handle = output.fileHandleForReading
        var stoppedEarly = false
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            if !body(chunk) {
                stoppedEarly = true
                process.terminate()
                break
            }
        }

        // Drained before waiting so a chatty child cannot fill its own stderr
        // buffer and block. `zstd` only writes diagnostics there, so this stays
        // far below the pipe limit.
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if !stoppedEarly && process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw WakeError.commandFailed(message)
        }
        return stoppedEarly
    }
}

/// Mutable storage for the concurrent pipe readers in ``Shell/runData(_:_:)``.
/// Each box is written on exactly one queue and read only after
/// `DispatchGroup.wait()`, which supplies the needed happens-before edge.
private final class DataBox: @unchecked Sendable {
    var value = Data()
}

package extension URL {
    /// Path of the receiver relative to `base`.
    ///
    /// Both sides are canonicalised with `resolvingSymlinksInPath()` before they
    /// are compared. Directory enumeration hands back fully resolved paths
    /// (`/tmp/...` arrives as `/private/tmp/...`, and a base that is itself a
    /// symlink arrives as its target) while a base URL built from a string keeps
    /// the unresolved form. Comparing raw paths then silently truncates the
    /// result and yields a relative path that points somewhere else — trashing a
    /// chat would miss its history database. `standardizedFileURL` is not enough
    /// here: it normalises the `/private` prefix but does not follow a symlink
    /// that the base itself is, which returns nil below.
    /// Returns nil when the receiver is not inside `base`.
    func relativePath(from base: URL) -> String? {
        let basePath = base.resolvingSymlinksInPath().path
        let selfPath = resolvingSymlinksInPath().path
        if selfPath == basePath { return "" }
        guard selfPath.hasPrefix(basePath + "/") else { return nil }
        return String(selfPath.dropFirst(basePath.count + 1))
    }
}

package enum WakeError: LocalizedError {
    case commandFailed(String)
    case missingCodexHome(URL)
    case missingStateDatabase(URL)
    case invalidJSON(String)
    case missingThreadFile(String)
    case missingCompressionTool(String)
    case unreadableThreadFile(String)
    case unsupportedByClaudeStore(String)

    package var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        case .missingCodexHome(let url):
            return "Codex home not found: \(url.path)"
        case .missingStateDatabase(let url):
            return "Codex state database not found: \(url.path)"
        case .invalidJSON(let message):
            return "Invalid JSON: \(message)"
        case .missingThreadFile(let path):
            return "Thread file not found: \(path)"
        case .missingCompressionTool(let path):
            return "Compressed chat file needs the 'zstd' command-line tool, which was not found: \(path)"
        case .unreadableThreadFile(let path):
            return "Chat file is not valid UTF-8 text: \(path)"
        case .unsupportedByClaudeStore(let operation):
            return "\(operation) is not supported for Claude sessions."
        }
    }
}
