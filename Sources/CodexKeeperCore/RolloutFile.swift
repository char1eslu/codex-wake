import Foundation

/// Access to Codex rollout files, which Codex may store zstd-compressed.
///
/// Codex writes each conversation to
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<thread-id>.jsonl` and later
/// replaces the plain file with a zstd-compressed `<name>.jsonl.zst` once it
/// ages out of the live window. The `rollout_path` column in the state database
/// keeps pointing at the *uncompressed* name, so every reader has to fall back
/// to the `.zst` sibling before concluding a chat is missing.
///
/// A compressed rollout is still a first-class chat: it can be previewed,
/// searched, trimmed, branched, moved and trashed. Only the operations that
/// rewrite the file in place need it expanded first, which
/// ``materialize(for:fileManager:)`` does on demand.
package enum RolloutFile {
    /// Suffix Codex appends when it compresses an aged-out rollout.
    package static let compressedSuffix = ".zst"

    /// Bytes handed to the search loop per iteration. Matches the chunk size the
    /// uncompressed path has always used.
    private static let chunkSize = 512 * 1024

    // MARK: - Resolution

    /// The file that actually backs `path`, preferring the plain JSONL and
    /// falling back to `<path>.zst`.
    ///
    /// Returns the plain URL unchanged when neither form exists, so callers can
    /// still report the path Codex recorded rather than a derived one.
    package static func resolvedURL(for path: String, fileManager: FileManager = .default) -> URL {
        let plain = URL(fileURLWithPath: path)
        if fileManager.fileExists(atPath: plain.path) { return plain }
        let compressed = URL(fileURLWithPath: path + compressedSuffix)
        if fileManager.fileExists(atPath: compressed.path) { return compressed }
        return plain
    }

    /// Whether a rollout is present on disk in either form.
    package static func exists(_ path: String, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: resolvedURL(for: path, fileManager: fileManager).path)
    }

    package static func isCompressed(_ url: URL) -> Bool {
        url.path.hasSuffix(compressedSuffix)
    }

    // MARK: - Reading

    /// Decoded contents of the rollout, decompressing transparently.
    package static func readText(for path: String, fileManager: FileManager = .default) throws -> String {
        let url = resolvedURL(for: path, fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else { throw WakeError.missingThreadFile(path) }
        let data = try readData(at: url, fileManager: fileManager)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WakeError.unreadableThreadFile(path)
        }
        return text
    }

    /// Raw decompressed bytes of the rollout.
    package static func readData(for path: String, fileManager: FileManager = .default) throws -> Data {
        let url = resolvedURL(for: path, fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else { throw WakeError.missingThreadFile(path) }
        return try readData(at: url, fileManager: fileManager)
    }

    package static func readData(at url: URL, fileManager: FileManager = .default) throws -> Data {
        guard isCompressed(url) else { return try Data(contentsOf: url) }
        return try decompress(url)
    }

    // MARK: - Searching

    /// Case-insensitive substring search over the rollout, streaming in chunks
    /// so a large chat never has to be materialised in memory.
    ///
    /// A tail of the previous chunk is carried forward so a match straddling a
    /// chunk boundary is still found, and so a multi-byte UTF-8 character split
    /// by the boundary is re-joined instead of dropping the chunk.
    package static func containsText(
        _ query: String,
        for path: String,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { false }
    ) throws -> Bool {
        let url = resolvedURL(for: path, fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else { return false }

        let lowerQuery = query.lowercased()
        let overlap = max(0, lowerQuery.utf8.count - 1)
        var carry = Data()

        func scan(_ data: Data) -> Bool {
            var buffer = carry
            buffer.append(data)
            let matched = String(data: buffer, encoding: .utf8)?.lowercased().contains(lowerQuery) ?? false
            carry = buffer.suffix(min(overlap + 3, buffer.count))
            return matched
        }

        if isCompressed(url) {
            guard let executable = zstdExecutable else {
                throw WakeError.missingCompressionTool(url.path)
            }
            var found = false
            _ = try Shell.streamData(
                executable,
                ["-d", "-c", "-q", "--", url.path],
                chunkSize: chunkSize
            ) { chunk in
                if isCancelled() { return false }
                if scan(chunk) {
                    found = true
                    return false
                }
                return true
            }
            return found
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            if isCancelled() { return false }
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { return false }
            if scan(data) { return true }
        }
    }

    // MARK: - Writing

    /// Expands a compressed rollout back to the plain JSONL path Codex records
    /// in `rollout_path` and drops the `.zst` sibling.
    ///
    /// Operations that rewrite a chat (trim, move, wake) need a plain file to
    /// write into, and Codex reads the recorded path — leaving both copies
    /// behind would make which one wins ambiguous. Callers are expected to have
    /// taken a backup of the compressed original first.
    ///
    /// Returns the plain URL unchanged when the rollout was never compressed.
    @discardableResult
    package static func materialize(for path: String, fileManager: FileManager = .default) throws -> URL {
        let plain = URL(fileURLWithPath: path)
        if fileManager.fileExists(atPath: plain.path) { return plain }
        let compressed = URL(fileURLWithPath: path + compressedSuffix)
        guard fileManager.fileExists(atPath: compressed.path) else {
            throw WakeError.missingThreadFile(path)
        }
        let data = try readData(at: compressed, fileManager: fileManager)
        try data.write(to: plain, options: .atomic)
        try? fileManager.removeItem(at: compressed)
        return plain
    }

    // MARK: - Decompression

    /// Searched after `PATH`. A bundle launched from Finder inherits a minimal
    /// environment that does not include the Homebrew prefix, so relying on
    /// `PATH` alone would work from a terminal and fail in the app.
    private static let fallbackSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]

    /// Absolute path of the `zstd` CLI, or nil when it is not installed.
    ///
    /// Override with `CODEX_KEEPER_ZSTD=/path/to/zstd`. Resolved once and cached:
    /// the lookup runs on every compressed read, and a `static let` initialiser
    /// is evaluated lazily and atomically.
    private static let discoveredZstd: String? = {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        if let override = environment["CODEX_KEEPER_ZSTD"], !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for directory in pathDirectories + fallbackSearchPaths {
            let candidate = directory.hasSuffix("/") ? directory + "zstd" : directory + "/zstd"
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }()

    package static var zstdExecutable: String? { discoveredZstd }

    private static func decompress(_ url: URL) throws -> Data {
        guard let executable = zstdExecutable else {
            throw WakeError.missingCompressionTool(url.path)
        }
        return try Shell.runData(executable, ["-d", "-c", "-q", "--", url.path])
    }
}
