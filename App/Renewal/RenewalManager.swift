import Foundation
import Combine
import UIKit
import SideSign

struct RenewalBootstrap: Codable {
    let bundleID: String
    let udid: String
    let p12: Data
}
private struct RenewalLogin: Codable { let email: String; let password: String }

@MainActor
final class RenewalManager: ObservableObject {
    static let shared = RenewalManager()
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var automatic = false
    @Published private(set) var message = "Enable renewal during computer setup, then sign in here."
    @Published private(set) var awaitingCode = false
    private var verification: CheckedContinuation<TwoFactorResponse, Error>?
    private var codeTimeout: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.diwasupadhyay.catter.renewal.install")
    // Persist across relaunches so opening the app repeatedly does not retry Apple.
    private var lastAutomaticAttempt: Date {
        get { UserDefaults.standard.object(forKey: "renewalLastAutomaticAttempt") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "renewalLastAutomaticAttempt") }
    }

    private func journal() throws -> RenewalJournal {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return RenewalJournal(url: root.appendingPathComponent("Renewal/transaction.json"))
    }

    private func installed() throws -> (AppBundle, ProvisioningProfile, RenewalIdentity) {
        guard let app = AppBundle(fileURL: Bundle.main.bundleURL), let profile = app.provisioningProfile,
              let applicationID = app.entitlements["application-identifier"] as? String,
              let groups = app.entitlements["keychain-access-groups"] as? [String], !groups.isEmpty else {
            throw AppError.message("The installed signing identity could not be read. Reinstall with Catter Setup.")
        }
        return (app, profile, RenewalIdentity(bundleID: app.bundleIdentifier, applicationIdentifier: applicationID,
                                             teamIdentifier: profile.teamIdentifier, keychainGroups: groups))
    }

    func load() {
        guard !busy else { return }
        do {
            let (_, profile, identity) = try installed()
            let file = try PairingStore.url().deletingLastPathComponent().appendingPathComponent("renewal-bootstrap.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard size.isSymbolicLink != true, (size.fileSize ?? Int.max) <= 65536 else {
                    throw AppError.message("Invalid renewal setup. Run computer preparation again.")
                }
                let data = try Data(contentsOf: file)
                let bootstrap = try JSONDecoder().decode(RenewalBootstrap.self, from: data)
                let key = try KeyStore(p12Data: bootstrap.p12)
                guard bootstrap.bundleID == identity.bundleID, profile.deviceIDs.contains(bootstrap.udid),
                      profile.certificates.contains(where: { $0.serialNumberHex == key.certificate.serialNumberHex }) else {
                    throw AppError.message("Renewal setup does not match this iPhone and installed app.")
                }
                try RenewalVault.save(data, account: "signing")
                try FileManager.default.removeItem(at: file)
            }
            ready = try RenewalVault.read("signing") != nil
            automatic = try RenewalVault.read("login") != nil
            var ledger = try journal().load()
            if let transaction = ledger.transaction, [.installing, .awaitingVerification].contains(transaction.phase) {
                do {
                    try ledger.verifyInstalled(identity: identity, expiration: profile.expirationDate, now: Date())
                    try journal().save(ledger)
                    message = "Renewal verified. The installed expiry has advanced."
                } catch {
                    ledger.fail(); try journal().save(ledger)
                    message = "Renewal was not verified. The previous app is still installed; try again."
                }
            } else if ledger.pending {
                ledger.fail(); try journal().save(ledger)
                message = "The previous renewal was interrupted before installation. You can retry."
            } else if ready { message = "Ready. Join Wi-Fi, connect LocalDevVPN and unlock your iPhone to renew." }
        } catch { message = "Renewal setup could not be loaded. Unlock the iPhone and retry computer preparation." }
    }

    func reply(code: String?) {
        let pending = verification
        verification = nil
        codeTimeout?.cancel(); codeTimeout = nil
        awaitingCode = false
        if let code, code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) {
            pending?.resume(returning: .verificationCode(code))
        } else { pending?.resume(returning: .cancel) }
    }

    private func challenge(_ request: TwoFactorRequest, background: Bool) async throws -> TwoFactorResponse {
        if background { throw AppError.message("Open Catter to complete Apple verification.") }
        if case .selectDeliveryMethod = request { return .requestTrustedDevice }
        message = "Enter the six-digit verification code Apple sent you."
        awaitingCode = true
        return try await withCheckedThrowingContinuation { continuation in
            verification = continuation
            codeTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
                self?.reply(code: nil)
            }
        }
    }

    func disableAutomatic() {
        guard !busy else { return }
        do {
            try RenewalVault.remove("login")
            automatic = false
            message = "Automatic renewal disabled. Saved Apple sign-in credentials removed from this iPhone."
        } catch { message = "Could not remove saved credentials. Unlock this iPhone and retry." }
    }

    func renew(email: String, password: String, remember: Bool, background: Bool = false) async {
        guard !busy else { return }
        guard UIApplication.shared.isProtectedDataAvailable else { message = "Unlock your iPhone before renewing."; return }
        guard !UserDefaults.standard.bool(forKey: "simulationUnresolved") else {
            message = "Restore and confirm your real location before renewing Catter."; return
        }
        busy = true
        defer { busy = false; reply(code: nil) }
        var temporary: URL?
        var stage = RenewalStage.preparation
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let previous = try journal().load()
            guard !previous.pending else {
                throw AppError.message("Reopen Catter to verify the previous installation before renewing again.")
            }
            if let last = previous.lastAttempt, Date().timeIntervalSince(last) < previous.retryDelay {
                throw AppError.message("Please wait before retrying renewal. Your installed app is unchanged.")
            }
            stage = .access
            try await AccessManager.shared.requireAccess(fresh: true)
            stage = .preparation
            guard !email.isEmpty, !password.isEmpty, let data = try RenewalVault.read("signing") else {
                throw AppError.message("Enable renewal in Catter Setup and enter your Apple Account.")
            }
            let bootstrap = try JSONDecoder().decode(RenewalBootstrap.self, from: data)
            let (app, oldProfile, identity) = try installed()
            guard bootstrap.bundleID == identity.bundleID, oldProfile.deviceIDs.contains(bootstrap.udid) else {
                throw AppError.message("Renewal identity does not match this iPhone.")
            }
            let key = try KeyStore(p12Data: bootstrap.p12)
            SideSignLogging.setLogging(false)
            message = "Preparing Apple authentication..."
            stage = .metadata
            let identifier: UUID
            if let saved = try RenewalVault.read("anisette-id"), let id = UUID(uuidString: String(decoding: saved, as: UTF8.self)) { identifier = id }
            else { identifier = UUID(); try RenewalVault.save(Data(identifier.uuidString.utf8), account: "anisette-id") }
            // This service receives only anisette provisioning data, never the
            // Apple email, password, 2FA code, developer token or signing key.
            let anisette = AnisetteDataManager(mode: .remote(server: URL(string: "https://ani.sidestore.io")!))
            let headers = try await anisette.fetchAnisetteData(identifier: identifier, existingAdiBlob: RenewalVault.read("anisette-blob"))
            try Task.checkCancellation()
            if let blob = headers.newAdiBlob { try RenewalVault.save(blob, account: "anisette-blob") }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
            let http = URLSession(configuration: configuration, delegate: RenewalNoRedirects(), delegateQueue: nil)
            defer { http.invalidateAndCancel() }
            let portal = DeveloperPortal(session: http)
            message = "Signing in directly to Apple..."
            stage = .authentication
            var authHeaders = headers.data
            authHeaders.clientInfo = authHeaders.clientInfo.replacingOccurrences(of: "com\\.apple\\.dt\\.Xcode/[^)\\s>]+", with: "com.apple.akd/1.0", options: .regularExpression)
            let auth = try await portal.authenticate(appleID: email, password: password, anisetteData: authHeaders,
                xcodeVersion: "11.2 (11B41)", machinePassword: nil, accountRepairHandler: { _, _ in .cancel },
                verificationHandler: { [weak self] request in
                    guard let self else { return .cancel }
                    return try await self.challenge(request, background: background)
                })
            stage = .account
            let teams = try await portal.fetchTeams(for: auth.account, session: auth.session)
            try Task.checkCancellation()
            guard let team = teams.first(where: { $0.identifier == identity.teamIdentifier }) else {
                throw AppError.message("Use the Apple Account that installed this copy of Catter.")
            }
            let certificates = try await portal.fetchCertificates(for: team, session: auth.session)
            guard certificates.contains(where: { $0.serialNumberHex == key.certificate.serialNumberHex }) else {
                throw AppError.message("The signing certificate was removed. Reinstall using Catter Setup; no certificate was revoked.")
            }
            let apps = try await portal.fetchAppIDs(for: team, session: auth.session)
            guard let appID = apps.first(where: { $0.bundleIdentifier == identity.bundleID }) else {
                throw AppError.message("The installed App ID is missing from this Apple Account.")
            }
            message = "Requesting a fresh signing profile..."
            stage = .profile
            let profile = try await portal.downloadProvisioningProfile(for: appID, isTeamProfile: true,
                subPlatform: nil, deviceType: .iPhone, team: team, session: auth.session)
            guard profile.bundleIdentifier == identity.bundleID, profile.teamIdentifier == identity.teamIdentifier,
                  profile.deviceIDs.contains(bootstrap.udid),
                  profile.certificates.contains(where: { $0.serialNumberHex == key.certificate.serialNumberHex }) else {
                throw AppError.message("Apple returned a profile for a different app, certificate or iPhone.")
            }
            var ledger = try journal().load()
            try ledger.begin(identity: identity, currentExpiration: oldProfile.expirationDate,
                             candidateIdentity: identity, candidateExpiration: profile.expirationDate, now: Date())
            try journal().save(ledger)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CatterRenewal-" + UUID().uuidString)
            temporary = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete])
            let copy = folder.appendingPathComponent("Catter.app")
            try FileManager.default.copyItem(at: app.fileURL, to: copy)
            message = "Signing Catter on this iPhone..."
            stage = .signing
            try await AppBundleSigner(team: team, keyStore: key).signApp(at: copy, provisioningProfiles: [profile])
            guard let signed = AppBundle(fileURL: copy),
                  signed.entitlements["application-identifier"] as? String == identity.applicationIdentifier,
                  signed.entitlements["com.apple.developer.team-identifier"] as? String == identity.teamIdentifier,
                  Set(signed.entitlements["keychain-access-groups"] as? [String] ?? []) == Set(identity.keychainGroups) else {
                throw AppError.message("Signing changed the app identity. Installation was stopped to protect your data.")
            }
            let ipa = try FileManager.default.zipAppBundle(at: copy, compressionLevel: .fastest)
            stage = .access
            try await AccessManager.shared.requireAccess(fresh: true)
            try Task.checkCancellation()
            if remember {
                try RenewalVault.save(JSONEncoder().encode(RenewalLogin(email: email, password: password)), account: "login")
                automatic = true
            }
            let pairing = try PairingStore.lockdownURL()
            try ledger.willInstall(); try journal().save(ledger)
            message = "Installing the renewed app. Catter may close; reopen it to verify renewal."
            stage = .installation
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do { try RenewalInstaller.install(ipa: ipa, pairingURL: pairing); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
            try ledger.installationSubmitted(); try journal().save(ledger)
            message = "Installation submitted. Reopen Catter to verify its new expiry."
        } catch {
            if var ledger = try? journal().load(), ledger.transaction?.phase == .preparing {
                ledger.fail(); try? journal().save(ledger)
            }
            // Once installation starts, an interrupted reply is ambiguous.
            // Preserve the journal so the next launch checks the actual expiry.
            // Library errors may embed Apple response payloads. Never echo them.
            if let error = error as? AppError { message = error.localizedDescription }
            else if error as? RenewalFailure == .expiryNotAdvanced { message = "Apple has not extended the profile yet. Your installed app is unchanged. Try again later." }
            else if let server = error as? ServerError, case .underlyingError(let code, _) = server {
                message = stage.failure(appleCode: code)
            } else if let network = error as? URLError {
                message = stage.failure(networkCode: network.code.rawValue)
            } else if let portal = error as? DeveloperPortalError {
                switch portal {
                case .incorrectCredentials: message = "Apple did not accept the account credentials. Keep Catter installed."
                case .incorrectVerificationCode, .invalid2FAResponse: message = "Apple did not accept the verification response. Sign in again with a new code. Keep Catter installed."
                case .requiresTwoFactorAuthentication: message = "Apple requires verification. Open Renew Catter and sign in manually."
                case .userCancelled: message = "Renewal cancelled. Keep Catter installed."
                case .tooManyAttempts: message = "Apple limited sign-in attempts. Wait before trying again; keep Catter installed."
                default: message = stage.failure()
                }
            } else { message = stage.failure() }
        }
    }

    func renewIfDue() async {
        guard !busy, automatic, Date().timeIntervalSince(lastAutomaticAttempt) >= 3600,
              let expiry = SigningStatus.expiration, SigningStatus.renewalDue(expiration: expiry),
              let bytes = try? RenewalVault.read("login"),
              let login = try? JSONDecoder().decode(RenewalLogin.self, from: bytes) else { return }
        lastAutomaticAttempt = Date()
        await renew(email: login.email, password: login.password, remember: true, background: true)
    }
}

private final class RenewalNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
