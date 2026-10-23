import Foundation
import Security
import Combine

// Online-only access checks. No six-day entitlement is trusted from local storage.
@MainActor
final class AccessManager: ObservableObject {
    static let shared = AccessManager()
    @Published private(set) var message = "Enter your invitation code in Settings."
    @Published private(set) var working = false
    @Published private(set) var isActivated = false
    var hasSavedActivation: Bool { (try? readIdentity().id) != nil }
    private let service = "com.diwasupadhyay.catter.access"
    private var validUntil: TimeInterval = 0

    private struct SetupBinding: Decodable { let proof: String }
    private struct Identity: Codable {
        var token: String
        var id: String? = nil
    }
    private struct Reply: Decodable {
        let id: String
        let expiresAt: Double
        let serverTime: Double
        let validFor: Double
    }
    private var identity: Identity?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: NoAccessRedirects(), delegateQueue: nil)
    }()

    private func readIdentity() throws -> Identity {
        if let identity { return identity }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "device",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecSuccess, let data = item as? Data {
            let stored = try JSONDecoder().decode(Identity.self, from: data)
            identity = stored
            return stored
        }
        guard result == errSecItemNotFound else {
            throw AppError.message("Unlock the iPhone to access your activation.")
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppError.message("Could not create a secure device credential.")
        }
        let created = Identity(token: bytes.map { String(format: "%02x", $0) }.joined())
        try save(created) // Persist before the network call so retries use the same identity.
        return created
    }
    private func save(_ value: Identity) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "device"]
        let data = try JSONEncoder().encode(value)
        var result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw AppError.message("Could not save activation securely. Try again.") }
        identity = value
    }
    private func request(_ path: String, _ input: [String: String]) async throws -> Reply {
        guard let address = Bundle.main.object(forInfoDictionaryKey: "CatterAccessURL") as? String,
              let base = URL(string: address), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              base.path.isEmpty || base.path == "/" else {
            throw AppError.message("Access service is not configured in this build. Contact the owner for an updated app.")
        }
        var request = URLRequest(url: base.appendingPathComponent("api/" + path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: input)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let http = response as? HTTPURLResponse, http.statusCode == 403 {
                throw AppError.message("Access is invalid, expired, revoked, or assigned to another iPhone. If this is the first activation, finish preparation with the latest Catter Installer on this iPhone. Restore remains available.")
            }
            throw AppError.message("Could not verify access. Check your internet connection and try again. Restore remains available.")
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.validFor > 0, reply.validFor <= 60, reply.expiresAt > reply.serverTime,
              reply.validFor <= reply.expiresAt - reply.serverTime else {
            throw AppError.message("Invalid access response. Contact the owner.")
        }
        return reply
    }
    func activate(_ code: String) async {
        guard !working else { return }
        working = true
        validUntil = 0
        defer { working = false }
        do {
            var stored = try readIdentity()
            let clean = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard clean.range(of: "^[a-f0-9]{48}$", options: .regularExpression) != nil else {
                throw AppError.message("Paste the full invitation code supplied by the owner.")
            }
            var input = ["code": clean, "deviceToken": stored.token]
            // Installer proof lives beside pairing data, outside Files and backups.
            if let directory = try? FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: false),
               let data = try? Data(contentsOf: directory.appendingPathComponent("PrivatePairing/access-binding.json")),
               data.count <= 2048,
               let binding = try? JSONDecoder().decode(SetupBinding.self, from: data) {
                input["setupProof"] = binding.proof
            }
            let reply = try await request("activate", input)
            stored.id = reply.id
            try save(stored)
            isActivated = true
            message = "Access active until \(Date(timeIntervalSince1970: reply.expiresAt).formatted(date: .abbreviated, time: .shortened))."
        } catch { isActivated = false; message = error.localizedDescription }
    }
    func requireAccess(fresh: Bool = false) async throws {
        // Uptime avoids granting extra time by moving the wall clock backwards.
        if !fresh && ProcessInfo.processInfo.systemUptime < validUntil { return }
        validUntil = 0
        do {
            let stored = try readIdentity()
            guard let id = stored.id else { throw AppError.message("Activate Catter in Settings before changing location. Restore remains available.") }
            let started = ProcessInfo.processInfo.systemUptime
            let reply = try await request("check", ["id": id, "deviceToken": stored.token])
            validUntil = started + reply.validFor
            guard ProcessInfo.processInfo.systemUptime < validUntil else {
                throw AppError.message("Access check took too long. Try again.")
            }
            isActivated = true
            message = "Access active until \(Date(timeIntervalSince1970: reply.expiresAt).formatted(date: .abbreviated, time: .shortened))."
        } catch {
            validUntil = 0
            isActivated = false
            message = error.localizedDescription
            throw error
        }
    }
}

private final class NoAccessRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
