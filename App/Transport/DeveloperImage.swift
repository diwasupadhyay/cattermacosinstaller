import Foundation
import CryptoKit

/// Runs only on the transport queue. Assets are pinned and verified before native parsing.
enum DeveloperImage {
    private struct Manifest: Decodable {
        let baseURL: String
        let files: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let sha256: String
        let size: Int
    }

    static func prepare(adapter: OpaquePointer, handshake: OpaquePointer,
                        progress: (String) -> Void) throws -> Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if !DeveloperImagePolicy.usesCryptex(version) {
            return try preparePersonalized(adapter: adapter, handshake: handshake, progress: progress)
        }
        progress("Checking developer image...")
        var installed: UnsafeMutablePointer<InstalledCryptexC>?
        try DVTClient.check(cryptexd_installed_ddi(adapter, handshake, &installed), stage: "Check developer image")
        if let installed {
            cryptexd_free_installed_cryptex(installed)
            return false
        }
        let directory = try download(progress: progress)
        var assets: OpaquePointer?
        defer { if let assets { cryptex1_assets_free(assets) } }
        try DVTClient.check(directory.path.withCString { cryptex1_assets_load($0, &assets) }, stage: "Read verified developer image")
        idevice_set_global_timeout(180)
        defer { idevice_set_global_timeout(10) }
        progress("Preparing developer services. Keep this app open...")
        try DVTClient.check(cryptexd_install_ddi(adapter, handshake, assets, nil), stage: "Personalize and install developer image")
        try DVTClient.check(cryptexd_installed_ddi(adapter, handshake, &installed), stage: "Verify installed developer image")
        guard let installed else { throw AppError.message("Developer image installation could not be verified.") }
        cryptexd_free_installed_cryptex(installed)
        return true
    }

    private static func download(specification name: String = "DDIAssets", progress: (String) -> Void) throws -> URL {
        guard let specification = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw AppError.message("Developer-image download specification is missing from the app.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: specification))
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for (index, asset) in manifest.files.enumerated() {
            guard !asset.name.contains("/"), !asset.name.contains(".."),
                  let url = URL(string: manifest.baseURL + asset.name), url.scheme == "https" else {
                throw AppError.message("Invalid developer-image download specification.")
            }
            let destination = cache.appendingPathComponent(asset.name)
            if AssetIntegrity.valid(destination, size: asset.size, sha256: asset.sha256) { continue }
            progress("Downloading preparation files (\(index + 1)/\(manifest.files.count))...")
            let temporary = cache.appendingPathComponent(UUID().uuidString + ".download")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try fetch(url, to: temporary)
            guard AssetIntegrity.valid(temporary, size: asset.size, sha256: asset.sha256) else {
                throw AppError.message("Developer-image download failed its size or checksum check. Try preparation again.")
            }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return cache
    }

    private static func preparePersonalized(adapter: OpaquePointer, handshake: OpaquePointer,
                                            progress: (String) -> Void) throws -> Bool {
        progress("Checking developer image...")
        var mounter: OpaquePointer?
        try DVTClient.check(image_mounter_connect_rsd(adapter, handshake, &mounter), stage: "Open image preparation")
        defer { if let mounter { image_mounter_free(mounter) } }
        guard let mounter else { throw AppError.message("Image preparation returned no connection.") }
        func isMounted() throws -> Bool {
            var signature: UnsafeMutablePointer<UInt8>?
            var length = 0
            let error = "Personalized".withCString { image_mounter_lookup_image(mounter, $0, &signature, &length) }
            defer { if let signature { idevice_data_free(signature, UInt(length)) } }
            // NotFound is explicitly code 20 in the pinned idevice error mapping.
            if let error, error.pointee.code == 20 { idevice_error_free(error); return false }
            try DVTClient.check(error, stage: "Check personalized image")
            return length > 0
        }
        if try isMounted() { return false }
        let directory = try download(specification: "DDIPersonalized", progress: progress)
        let image = try Data(contentsOf: directory.appendingPathComponent("Image.dmg"), options: .mappedIfSafe)
        let trust = try Data(contentsOf: directory.appendingPathComponent("Image.dmg.trustcache"))
        let manifest = try Data(contentsOf: directory.appendingPathComponent("BuildManifest.plist"))
        var lockdown: OpaquePointer?
        try DVTClient.check(lockdownd_connect_rsd(adapter, handshake, &lockdown), stage: "Read image personalization identity")
        defer { if let lockdown { lockdownd_client_free(lockdown) } }
        var identity: plist_t?
        defer { if let identity { plist_free(identity) } }
        try DVTClient.check("UniqueChipID".withCString { lockdownd_get_value(lockdown, $0, nil, &identity) }, stage: "Read device identity")
        guard let identity else { throw AppError.message("No personalization identity was returned.") }
        var chip: UInt64 = 0
        plist_get_uint_val(identity, &chip)
        guard chip != 0 else { throw AppError.message("Invalid personalization identity.") }
        progress("Preparing developer services. Keep this app open...")
        idevice_set_global_timeout(180)
        defer { idevice_set_global_timeout(10) }
        let error = image.withUnsafeBytes { imageBytes in
            trust.withUnsafeBytes { trustBytes in
                manifest.withUnsafeBytes { manifestBytes in
                    image_mounter_mount_personalized_rsd(mounter, adapter, handshake,
                        imageBytes.bindMemory(to: UInt8.self).baseAddress, image.count,
                        trustBytes.bindMemory(to: UInt8.self).baseAddress, trust.count,
                        manifestBytes.bindMemory(to: UInt8.self).baseAddress, manifest.count, nil, chip)
                }
            }
        }
        try DVTClient.check(error, stage: "Personalize and mount developer image")
        guard try isMounted() else { throw AppError.message("Developer image mount could not be verified.") }
        return true
    }

    private static func fetch(_ url: URL, to file: URL) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let signal = DispatchSemaphore(value: 0)
        let outcome = DownloadOutcome()
        let task = session.downloadTask(with: url) { temporary, response, error in
            defer { signal.signal() }
            do {
                if let error { throw error }
                guard let temporary, let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw AppError.message("Developer-image server did not return a valid download.")
                }
                try FileManager.default.moveItem(at: temporary, to: file)
            } catch { outcome.error = error }
        }
        task.resume()
        // Wait for URLSession's bounded completion, so it cannot write into a later operation.
        signal.wait()
        if let error = outcome.error { throw error }
    }
}

private final class DownloadOutcome: @unchecked Sendable {
    // Written before semaphore signal, read only after its wait.
    var error: Error?
}
