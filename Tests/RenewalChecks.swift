import Foundation
@main struct RenewalChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let identity = RenewalIdentity(bundleID: "test.catter", applicationIdentifier: "TEAM.test.catter", teamIdentifier: "TEAM", keychainGroups: ["TEAM.test.catter"])
        let other = RenewalIdentity(bundleID: "test.catter", applicationIdentifier: "OTHER.test.catter", teamIdentifier: "OTHER", keychainGroups: ["OTHER.test.catter"])
        func fails(_ expected: RenewalFailure, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("Expected failure") }
            catch { precondition(error as? RenewalFailure == expected) }
        }
        var ledger = RenewalLedger()
        let old = now.addingTimeInterval(86400), fresh = now.addingTimeInterval(7 * 86400)
        fails(.invalidIdentity) { try ledger.begin(identity: identity, currentExpiration: old, candidateIdentity: other, candidateExpiration: fresh, now: now) }
        fails(.expiryNotAdvanced) { try ledger.begin(identity: identity, currentExpiration: old, candidateIdentity: identity, candidateExpiration: old, now: now) }
        try ledger.begin(identity: identity, currentExpiration: old, candidateIdentity: identity, candidateExpiration: fresh, now: now)
        fails(.alreadyPending) { try ledger.begin(identity: identity, currentExpiration: old, candidateIdentity: identity, candidateExpiration: fresh, now: now) }
        fails(.noPendingInstall) { try ledger.verifyInstalled(identity: identity, expiration: fresh, now: now) }
        try ledger.willInstall()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RenewalJournal(url: directory.appendingPathComponent("renewal.json"))
        try journal.save(ledger)
        var restarted = try journal.load()
        precondition(restarted.transaction == ledger.transaction)
        fails(.unverifiedInstall) { try restarted.verifyInstalled(identity: identity, expiration: old, now: now) }
        fails(.invalidIdentity) { try restarted.verifyInstalled(identity: other, expiration: fresh, now: now) }
        // App was killed during self-install, before acknowledgment.
        try restarted.verifyInstalled(identity: identity, expiration: fresh, now: now)
        precondition(restarted.transaction?.phase == .verified && !restarted.pending)
        fails(.retryTooSoon) { try restarted.begin(identity: identity, currentExpiration: old, candidateIdentity: identity, candidateExpiration: fresh, now: now) }
        ledger.fail()
        precondition(!ledger.pending && ledger.consecutiveFailures == 1)
        fails(.retryTooSoon) { try ledger.begin(identity: identity, currentExpiration: old, candidateIdentity: identity, candidateExpiration: fresh, now: now.addingTimeInterval(20)) }
        try Data("broken".utf8).write(to: journal.url)
        fails(.corruptState) { _ = try journal.load() }
        print("Renewal identity, expiry verification, crash recovery, atomic journal and retry checks passed.")
    }
}
