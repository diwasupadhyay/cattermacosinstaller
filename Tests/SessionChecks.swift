import Foundation

@MainActor final class AccessManager {
    static let shared = AccessManager()
    var denied = false
    func requireAccess(fresh: Bool = false) async throws {
        if denied { throw AppError.message("Access expired") }
    }
}

// Test doubles replace USB/device services only in this macOS test executable.
enum PairingStore {
    static var isAvailable = true
    static func url() throws -> URL { URL(fileURLWithPath: "/test-only") }
    static func importFile(_ source: URL) throws { }
    static func remove() throws { }
}
final class DVTClient {
    static var connects = 0
    static var preparationAllowedOnLastConnect = true
    static var sends = 0
    static var clears = 0
    static var failedSetsRemaining = 0
    static var failSet = false
    static var failedClearsRemaining = 0
    static var pauseNextSet = false
    static let setStarted = DispatchSemaphore(value: 0)
    static let releaseSet = DispatchSemaphore(value: 0)
    func connect(pairingURL: URL, progress: @escaping (String) -> Void = { _ in }, allowPreparation: Bool = true) throws {
        Self.connects += 1
        Self.preparationAllowedOnLastConnect = allowPreparation
    }
    func set(_ coordinate: Coordinate) throws {
        if Self.pauseNextSet {
            Self.pauseNextSet = false
            Self.setStarted.signal()
            Self.releaseSet.wait()
        }
        if Self.failedSetsRemaining > 0 {
            Self.failedSetsRemaining -= 1
            throw AppError.message("Injected stale set connection")
        }
        if Self.failSet { throw AppError.message("Injected transport failure") }
        Self.sends += 1
    }
    func restore() throws {
        if Self.failedClearsRemaining > 0 {
            Self.failedClearsRemaining -= 1
            throw AppError.message("Injected stale restore connection")
        }
        Self.clears += 1
    }
    func close() { }
}

@main struct SessionChecks {
    @MainActor static func main() async throws {
        UserDefaults.standard.removeObject(forKey: "simulationUnresolved")
        defer { UserDefaults.standard.removeObject(forKey: "simulationUnresolved") }
        let model = SessionModel()
        var cancelledRestoreChecks = 0
        model.restoreVerificationCancelled = { cancelledRestoreChecks += 1 }
        model.select(try Coordinate(latitude: 0.0, longitude: 0.0))
        await model.start()
        precondition(cancelledRestoreChecks == 1,
                     "Starting a new simulation must cancel observations from an earlier restore")
        precondition(model.connected && model.unresolved && model.refreshing)
        precondition(DVTClient.connects == 1 && DVTClient.sends == 1)
        await model.connect()
        precondition(DVTClient.connects == 1 && model.refreshing && model.lastSent != nil,
                     "Connect must not replace an existing session or stop refresh")
        model.select(try Coordinate(latitude: 0.0, longitude: 0.002))
        await model.start()
        precondition(DVTClient.connects == 1 && DVTClient.sends == 2,
                     "New coordinates must use the existing transport")
        model.confirmRestored()
        precondition(model.unresolved, "Cannot confirm restoration while sending locations")
        model.enteredBackground()
        precondition(!model.refreshing && model.unresolved)
        model.enteredForeground()
        precondition(model.refreshing, "Returning must resume the existing intended simulation")
        await model.connect()
        precondition(DVTClient.connects == 1, "Returning from network settings must preserve the session")
        await model.restore()
        precondition(DVTClient.clears == 1 && model.unresolved && model.lastSent == nil)
        model.enteredBackground()
        model.enteredForeground()
        precondition(!model.refreshing, "Foreground recovery must never reapply a restored location")
        model.confirmRestored()
        precondition(!model.unresolved)

        // Simulate the monitor granting background delivery. This tests our state
        // machine, not iOS scheduling or a physical locked-phone connection.
        model.select(try Coordinate(latitude: 10.0, longitude: 20.0))
        await model.start()
        model.setBackgroundUpdatesAllowed(true)
        let backgroundSends = DVTClient.sends
        model.enteredBackground()
        precondition(model.refreshing && model.sessionNeedsCheck)
        try await Task.sleep(nanoseconds: 4_300_000_000)
        precondition(DVTClient.sends > backgroundSends && !model.sessionNeedsCheck)
        model.enteredForeground()
        precondition(model.sessionNeedsCheck,
                     "Returning after suspension must not present an old successful refresh as current connection proof")
        model.enteredBackground()
        let expectedFixed = try Coordinate(latitude: 10.0, longitude: 20.0)
        precondition(model.lastSent == expectedFixed,
                     "A fixed simulated location must not follow physical-location observations")
        model.setBackgroundUpdatesAllowed(false)
        precondition(!model.refreshing && model.sessionNeedsCheck)
        let stoppedSends = DVTClient.sends
        try await Task.sleep(nanoseconds: 1_100_000_000)
        precondition(DVTClient.sends == stoppedSends)
        model.enteredForeground()
        await model.restore()
        model.confirmRestored()

        let connectsBeforeRecovery = DVTClient.connects
        DVTClient.failedSetsRemaining = 1
        await model.start()
        precondition(model.refreshing && model.failure == nil && DVTClient.connects == connectsBeforeRecovery + 2,
                     "A failed explicit Set must reconnect once and resend the same coordinate")
        model.enteredBackground()
        precondition(!model.canConfirmRestored, "Paused simulation is not restored merely because refresh stopped")
        model.enteredForeground()
        await model.restore()
        precondition(model.awaitingRestoreReading)
        model.restorationReading(simulated: false)
        precondition(!model.awaitingRestoreReading && !model.unresolved)
        precondition(model.realLocationReceived && model.statusTitle == "Real location received")
        model.confirmRestored()

        DVTClient.failSet = true
        await model.start()
        precondition(model.unresolved && !model.connected && !model.refreshing && model.failure != nil)
        precondition(SessionModel().unresolved, "Uncertainty must survive relaunch")
        DVTClient.failSet = false
        await model.restore()
        precondition(!model.connected, "Successful Restore releases the simulation session")
        model.confirmRestored()
        var restoreNotifications = 0
        model.restoreCompleted = { restoreNotifications += 1 }
        await model.start()
        DVTClient.failedClearsRemaining = 1
        await model.restore()
        precondition(restoreNotifications == 1 && model.failure == nil && !model.refreshing && model.lastSent == nil,
                     "Restore must reconnect once, stop refresh, then notify observation")
        precondition(!DVTClient.preparationAllowedOnLastConnect,
                     "Restore recovery must not enter developer-image download or preparation")
        model.restorationUnavailable("No fresh normal location confirmed")
        precondition(model.unresolved && model.status == "No fresh normal location confirmed",
                     "Missing GPS confirmation must stay explicit and unresolved")
        model.restorationReading(simulated: true)
        precondition(model.unresolved && model.status.contains("simulated"))
        model.restorationReading(simulated: false)
        precondition(!model.unresolved, "A fresh non-simulated reading must clear the installer preparation gate automatically")
        let afterRestore = DVTClient.sends
        try await Task.sleep(nanoseconds: 4_300_000_000)
        precondition(DVTClient.sends == afterRestore, "No queued refresh may reapply a location after Restore")
        DVTClient.failedClearsRemaining = 2
        await model.restore()
        precondition(model.failure != nil && model.unresolved && restoreNotifications == 1,
                     "Failed restore must preserve uncertainty and never report completion")
        model.confirmRestored()
        await model.start()
        DVTClient.pauseNextSet = true
        // Let the next periodic update enter the transport and hold it there.
        var entered = false
        for _ in 0..<70 {
            if DVTClient.setStarted.wait(timeout: .now()) == .success { entered = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(entered && model.busy && model.refreshing)
        precondition(!model.userActionBusy, "Periodic refresh must not dim the Set location button")
        let urgentRestore = Task { await model.restore() }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(model.restoring && !model.refreshing, "Restore must cancel refresh immediately even during a send")
        DVTClient.releaseSet.signal()
        await urgentRestore.value
        precondition(!model.busy && !model.restoring && !model.connected && model.failure == nil)
        model.confirmRestored()
        AccessManager.shared.denied = true
        let previousSends = DVTClient.sends
        await model.start()
        precondition(DVTClient.sends == previousSends && model.failure != nil,
                     "Denied access must prevent location sends")
        let previousClears = DVTClient.clears
        await model.restore()
        precondition(DVTClient.clears > previousClears && model.failure == nil,
                     "Restore must remain available after access expires")
        model.confirmRestored()
        AccessManager.shared.denied = false
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "motionEnabled")
        defaults.set(5.0, forKey: "motionMinimum")
        defaults.set(10.0, forKey: "motionMaximum")
        defaults.set(15.0, forKey: "motionInterval")
        defer {
            for key in ["motionEnabled", "motionMinimum", "motionMaximum", "motionInterval"] { defaults.removeObject(forKey: key) }
        }
        let anchor = try Coordinate(latitude: 10, longitude: 20)
        model.select(anchor)
        await model.start()
        model.setBackgroundUpdatesAllowed(true)
        model.enteredBackground()
        try await Task.sleep(nanoseconds: 17_000_000_000)
        precondition(model.lastSent != anchor && model.failure == nil, "Motion should use the running background session")
        precondition(model.selected == anchor, "Motion must not move the selected anchor")
        model.enteredForeground()
        await model.restore()
        precondition(model.lastSent == nil && model.motionSummary == "Fixed location")
        let motionStopped = DVTClient.sends
        try await Task.sleep(nanoseconds: 4_300_000_000)
        precondition(DVTClient.sends == motionStopped, "Restore must stop random movement")
        model.restorationReading(simulated: false)
        PairingStore.isAvailable = false
        let missing = SessionModel()
        missing.select(try Coordinate(latitude: 0.0, longitude: 0.0))
        await missing.start()
        precondition(!missing.connected && !missing.unresolved && missing.failure != nil)
        print("Auto-connect, restore confirmation, background pause, failure recovery and pairing checks passed.")
    }
}
