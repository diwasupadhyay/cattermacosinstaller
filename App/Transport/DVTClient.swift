import Foundation

// All methods and pointer lifetimes belong to SessionModel's single serial queue.
// No NetworkExtension entitlement, remote server, or Python process is used by the app.
final class DVTClient {
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var server: OpaquePointer?
    private var location: OpaquePointer?
    private var lastWorkingRoute: (host: String, remoteXPC: Bool)?

    static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, stage: String) throws {
        guard let error else { return }
        defer { idevice_error_free(error) }
        let code = error.pointee.code
        let detail = error.pointee.message.map { String(cString: $0) } ?? "No service detail"
        throw AppError.message("\(stage) failed (\(code)): \(detail)")
    }

    func connect(pairingURL: URL, progress: @escaping (String) -> Void = { _ in }, allowPreparation: Bool = true) throws {
        var failures: [String] = []
        var routes = LocalEndpoints.candidates().flatMap { host in
            [false, true].map { (host: host, remoteXPC: $0) }
        }
        if let previous = lastWorkingRoute,
           let index = routes.firstIndex(where: { $0.host == previous.host && $0.remoteXPC == previous.remoteXPC }) {
            let preferred = routes.remove(at: index)
            routes.insert(preferred, at: 0)
        }
        // Never retry localhost: device logs explicitly reject local origins.
        for (host, remoteXPC) in routes {
            let protocolName = remoteXPC ? "RemoteXPC" : "Remote pairing"
            do {
                progress("Opening \(protocolName) through \(host)...")
                try connectRoute(host: host, pairingURL: pairingURL, progress: progress,
                                 allowPreparation: allowPreparation, remoteXPC: remoteXPC)
                lastWorkingRoute = (host, remoteXPC)
                progress("Location service connected through \(protocolName)")
                return
            } catch {
                failures.append("\(protocolName) \(host): \(error.localizedDescription)")
            }
        }
        throw AppError.message("No local route completed the developer connection.\n" + failures.joined(separator: "\n"))
    }

    private func connectRoute(host: String, pairingURL: URL, progress: @escaping (String) -> Void, allowPreparation: Bool, remoteXPC: Bool = false) throws {
        close()
        do {
            try openRemotePairing(host: host, pairingURL: pairingURL, remoteXPC: remoteXPC)
            do {
                try Self.check(remote_server_connect_rsd(adapter, handshake, &server), stage: "Open location service")
            } catch {
                let originalError = error
                guard allowPreparation, let adapter, let handshake else { throw error }
                if let server { remote_server_free(server); self.server = nil }
                guard try DeveloperImage.prepare(adapter: adapter, handshake: handshake, progress: progress) else {
                    throw originalError
                }
                // New services require a fresh RSD handshake; never recurse into preparation twice.
                close()
                progress("Opening location service...")
                try connectRoute(host: host, pairingURL: pairingURL, progress: progress, allowPreparation: false, remoteXPC: remoteXPC)
                return
            }
            try Self.check(location_simulation_new(server, &location), stage: "Open location channel")
        } catch {
            close()
            throw error
        }
    }

    private func openRemotePairing(host: String, pairingURL: URL, remoteXPC: Bool) throws {
        var pairing: OpaquePointer?
        defer { if let pairing { rp_pairing_file_free(pairing) } }
        try Self.check(pairingURL.path.withCString { rp_pairing_file_read($0, &pairing) },
                       stage: "Read remote pairing file")
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(49152).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw AppError.message("Invalid local tunnel address.")
        }
        idevice_set_global_timeout(10)
        let error = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                if remoteXPC {
                    return tunnel_create_remotexpc($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                        "GhostlyIOS", pairing, nil, nil, &adapter, &handshake)
                }
                return tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                    "GhostlyIOS", pairing, nil, nil, &adapter, &handshake)
            }
        }
        try Self.check(error, stage: "Developer tunnel")
        // Pair verification can update the upstream record. Persist it privately.
        try Self.check(pairingURL.path.withCString { rp_pairing_file_write(pairing, $0) },
                       stage: "Save pairing record")
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                                ofItemAtPath: pairingURL.path)
    }

    func set(_ coordinate: Coordinate) throws {
        guard let location else { throw AppError.message("Connect to the location service first.") }
        try Self.check(location_simulation_set(location, coordinate.latitude, coordinate.longitude),
                       stage: "Set location")
    }

    func restore() throws {
        guard let location else { throw AppError.message("Reconnect before restoring the location.") }
        try Self.check(location_simulation_clear(location), stage: "Restore location")
        // Release the simulation channel only after Stop completed. No refresh
        // can reuse this handle; a subsequent Set establishes a new session.
        close()
    }

    func close() {
        if let location { location_simulation_free(location) }
        location = nil
        if let server { remote_server_free(server) }
        server = nil
        if let handshake { rsd_handshake_free(handshake) }
        handshake = nil
        if let adapter { adapter_free(adapter) }
        adapter = nil
    }
}
