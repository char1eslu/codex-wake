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
        case .unsupportedByClaudeStore(let operation):
            return "\(operation) is not supported for Claude sessions."
        }
    }
}
