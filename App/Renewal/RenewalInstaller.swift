import Foundation

// Runs on a dedicated worker. Upload once, then Upgrade the existing bundle:
// never uninstall it or delete its data to make installation succeed.
enum RenewalInstaller {
    static func install(ipa: URL, pairingURL: URL) throws {
        var pairing: OpaquePointer?
        try DVTClient.check(pairingURL.path.withCString { idevice_pairing_file_read($0, &pairing) }, stage: "Read renewal pairing")
        guard let pairing else { throw AppError.message("Computer preparation is needed for renewal.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(62078).bigEndian
        inet_pton(AF_INET, "10.7.0.1", &address.sin_addr)
        var provider: OpaquePointer?
        let error = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                idevice_tcp_provider_new($0, pairing, "CatterRenewal", &provider)
            }
        }
        if error != nil { idevice_pairing_file_free(pairing) }
        try DVTClient.check(error, stage: "Create renewal connection")
        defer { if let provider { idevice_provider_free(provider) } }
        var afc: OpaquePointer?
        try DVTClient.check(afc_client_connect(provider, &afc), stage: "Connect renewal file service")
        defer { if let afc { afc_client_free(afc) } }
        // PublicStaging normally exists. A mkdir error is harmless only if opening
        // the destination succeeds; the following open is always checked.
        if let error = afc_make_directory(afc, "/PublicStaging") { idevice_error_free(error) }
        let remote = "/PublicStaging/Catter-" + UUID().uuidString + ".ipa"
        var file: OpaquePointer?
        try DVTClient.check(remote.withCString { afc_file_open(afc, $0, AfcWrOnly, &file) }, stage: "Stage renewed app")
        var fileOpen = true
        defer {
            if fileOpen, let error = afc_file_close(file) { idevice_error_free(error) }
            if let error = remote.withCString({ afc_remove_path(afc, $0) }) { idevice_error_free(error) }
        }
        let stream = try FileHandle(forReadingFrom: ipa)
        defer { try? stream.close() }
        while let bytes = try stream.read(upToCount: 256 * 1024), !bytes.isEmpty {
            try DVTClient.check(bytes.withUnsafeBytes { afc_file_write(file, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }, stage: "Upload renewed app")
        }
        let closeError = afc_file_close(file)
        fileOpen = false
        try DVTClient.check(closeError, stage: "Finish renewed app upload")
        var installer: OpaquePointer?
        try DVTClient.check(installation_proxy_connect(provider, &installer), stage: "Connect installation service")
        defer { if let installer { installation_proxy_client_free(installer) } }
        try DVTClient.check(remote.withCString { installation_proxy_upgrade(installer, $0, nil) }, stage: "Install renewed Catter")
    }
}
