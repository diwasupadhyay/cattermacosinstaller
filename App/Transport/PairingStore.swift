import Foundation

enum PairingStore {
    static var isAvailable: Bool {
        guard let location = try? url() else { return false }
        return FileManager.default.fileExists(atPath: location.path)
    }
    static func url() throws -> URL {
        var directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PrivatePairing", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory.appendingPathComponent("remote-pairing.plist")
    }

    static func importFile(_ source: URL) throws {
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 1_048_576 else {
            throw AppError.message("The pairing file must be nonempty and smaller than 1 MB.")
        }
        let data = try Data(contentsOf: source)
        guard !data.isEmpty, data.count <= 1_048_576 else {
            throw AppError.message("The pairing file changed or exceeds the 1 MB limit.")
        }
        // The native parser validates the remote-pairing format before replacement.
        var pairing: OpaquePointer?
        defer { if let pairing { rp_pairing_file_free(pairing) } }
        let error = data.withUnsafeBytes { bytes in
            rp_pairing_file_from_bytes(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), &pairing)
        }
        try DVTClient.check(error, stage: "Import remote pairing file")
        try data.write(to: url(), options: [.atomic, .completeFileProtection])
    }

    static func lockdownURL() throws -> URL {
        let file = try url().deletingLastPathComponent().appendingPathComponent("lockdown-pairing.plist")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        }
        return file
    }

    static func remove() throws {
        let path = try url()
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        let classic = try lockdownURL()
        if FileManager.default.fileExists(atPath: classic.path) { try FileManager.default.removeItem(at: classic) }
    }
}
