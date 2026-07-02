import Foundation

struct CommandLineToolInstallResult {
    let installedPath: String
}

struct CommandLineToolUninstallResult {
    let installPath: String
    let didRemove: Bool
}

enum CommandLineToolInstallError: LocalizedError {
    case bundledBinaryMissing
    case refusingToRemoveBundledBinary

    var errorDescription: String? {
        switch self {
        case .bundledBinaryMissing:
            return "The bundled codex-keeper binary was not found. Build the app with scripts/build-app.sh and try again."
        case .refusingToRemoveBundledBinary:
            return "Refusing to remove the codex-keeper binary inside the app bundle."
        }
    }
}

enum CommandLineToolInstaller {
    private static let binaryName = "codex-keeper"

    static func installBundledCLI() throws -> CommandLineToolInstallResult {
        guard let source = bundledCLIURL() else {
            throw CommandLineToolInstallError.bundledBinaryMissing
        }

        let installDirectory = defaultInstallDirectory()
        let destination = installDirectory.appendingPathComponent(binaryName)
        let temporaryDestination = installDirectory.appendingPathComponent(".\(binaryName).install-\(UUID().uuidString)")
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDestination) }
        if fileManager.fileExists(atPath: temporaryDestination.path) {
            try fileManager.removeItem(at: temporaryDestination)
        }
        try fileManager.copyItem(at: source, to: temporaryDestination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryDestination.path)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryDestination, to: destination)

        return CommandLineToolInstallResult(installedPath: destination.path)
    }

    static func uninstallCLI() throws -> CommandLineToolUninstallResult {
        let destination = defaultInstallDirectory().appendingPathComponent(binaryName).standardizedFileURL
        let bundledPath = bundledCLIURL()?.standardizedFileURL.path

        guard destination.path != bundledPath else {
            throw CommandLineToolInstallError.refusingToRemoveBundledBinary
        }

        guard FileManager.default.fileExists(atPath: destination.path) else {
            return CommandLineToolUninstallResult(installPath: destination.path, didRemove: false)
        }

        try FileManager.default.removeItem(at: destination)
        return CommandLineToolUninstallResult(installPath: destination.path, didRemove: true)
    }

    private static func bundledCLIURL() -> URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: binaryName),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }

        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            let url = executableDirectory.appendingPathComponent(binaryName)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        if let resource = Bundle.main.url(forResource: binaryName, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: resource.path) {
            return resource
        }

        return nil
    }

    private static func defaultInstallDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_KEEPER_INSTALL_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }
}
