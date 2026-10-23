import Foundation

// Independent of the eventual signing library. These records never contain
// passwords, tokens, certificates, signing keys, pairing records or locations.
struct RenewalIdentity: Codable, Equatable {
    let bundleID: String
    let applicationIdentifier: String
    let teamIdentifier: String
    let keychainGroups: [String]

    func matches(_ other: Self) -> Bool {
        bundleID == other.bundleID && applicationIdentifier == other.applicationIdentifier &&
        teamIdentifier == other.teamIdentifier && Set(keychainGroups) == Set(other.keychainGroups)
    }
}

struct RenewalTransaction: Codable, Equatable {
    enum Phase: String, Codable { case preparing, installing, awaitingVerification, verified, failed }
    let id: UUID
    let identity: RenewalIdentity
    let previousExpiration: Date
    let expectedExpiration: Date
    let startedAt: Date
    var phase: Phase
    var verifiedAt: Date?
}

enum RenewalFailure: Error, Equatable {
    case alreadyPending, invalidIdentity, expiryNotAdvanced, expiredProfile, noPendingInstall
    case unverifiedInstall, retryTooSoon, corruptState
}

struct RenewalLedger: Codable {
    private(set) var transaction: RenewalTransaction?
    private(set) var lastAttempt: Date?
    private(set) var consecutiveFailures = 0

    var pending: Bool {
        guard let phase = transaction?.phase else { return false }
        return [.preparing, .installing, .awaitingVerification].contains(phase)
    }

    // Back off after failure; waking the app repeatedly must not hammer Apple.
    var retryDelay: TimeInterval { min(6 * 3600, 15 * 60 * pow(2, Double(min(consecutiveFailures, 5)))) }

    mutating func begin(identity: RenewalIdentity, currentExpiration: Date,
                        candidateIdentity: RenewalIdentity, candidateExpiration: Date,
                        now: Date) throws {
        guard !pending else { throw RenewalFailure.alreadyPending }
        guard !identity.bundleID.isEmpty, !identity.applicationIdentifier.isEmpty,
              !identity.teamIdentifier.isEmpty, !identity.keychainGroups.isEmpty,
              identity.matches(candidateIdentity) else { throw RenewalFailure.invalidIdentity }
        guard candidateExpiration > now else { throw RenewalFailure.expiredProfile }
        guard candidateExpiration > currentExpiration else { throw RenewalFailure.expiryNotAdvanced }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryDelay {
            throw RenewalFailure.retryTooSoon
        }
        lastAttempt = now
        transaction = RenewalTransaction(id: UUID(), identity: identity,
            previousExpiration: currentExpiration, expectedExpiration: candidateExpiration,
            startedAt: now, phase: .preparing)
    }

    mutating func willInstall() throws {
        guard transaction?.phase == .preparing else { throw RenewalFailure.noPendingInstall }
        transaction?.phase = .installing
    }

    // An installation service acknowledgment is NOT renewal success. Self-install
    // may terminate the app before even this callback; reconcile on next launch.
    mutating func installationSubmitted() throws {
        guard transaction?.phase == .installing else { throw RenewalFailure.noPendingInstall }
        transaction?.phase = .awaitingVerification
    }

    mutating func verifyInstalled(identity: RenewalIdentity, expiration: Date, now: Date) throws {
        guard let record = transaction, [.installing, .awaitingVerification].contains(record.phase)
        else { throw RenewalFailure.noPendingInstall }
        guard record.identity.matches(identity) else { throw RenewalFailure.invalidIdentity }
        guard expiration >= record.expectedExpiration, expiration > record.previousExpiration, expiration > now
        else { throw RenewalFailure.unverifiedInstall }
        transaction?.phase = .verified
        transaction?.verifiedAt = now
        consecutiveFailures = 0
    }

    mutating func fail() {
        guard pending else { return }
        transaction?.phase = .failed
        consecutiveFailures = min(consecutiveFailures + 1, 10)
    }
}

// The signing adapter must persist before initiating self-installation. Failure
// to save must abort installation; otherwise we cannot verify it after restart.
struct RenewalJournal {
    let url: URL
    func load() throws -> RenewalLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return RenewalLedger() }
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
              ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max) <= 65536
        else { throw RenewalFailure.corruptState }
        do { return try JSONDecoder().decode(RenewalLedger.self, from: Data(contentsOf: url)) }
        catch { throw RenewalFailure.corruptState }
    }
    func save(_ ledger: RenewalLedger) throws {
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw RenewalFailure.corruptState }
        if FileManager.default.fileExists(atPath: url.path),
           (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw RenewalFailure.corruptState }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let bytes = try JSONEncoder().encode(ledger)
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
    }
}
