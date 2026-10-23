import Foundation
import Combine

@MainActor
final class SessionModel: ObservableObject {
    @Published var latitude = ""
    @Published var longitude = ""
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var pairingAvailable = PairingStore.isAvailable
    @Published private(set) var status: String
    @Published private(set) var failure: String?
    @Published private(set) var unresolved: Bool
    @Published private(set) var lastSent: Coordinate?
    @Published private(set) var refreshing = false
    @Published private(set) var restoring = false
    @Published private(set) var sessionNeedsCheck = false
    @Published private(set) var backgroundUpdatesAllowed = false
    @Published private(set) var awaitingRestoreReading = false
    @Published private(set) var realLocationReceived = false
    @Published private(set) var lastCommandAt: Date?
    var locationSent: ((Coordinate) -> Void)?
    var activityChanged: ((Bool) -> Void)?
    var restoreCompleted: (() -> Void)?
    var installationInProgress: (() -> Bool)?

    private let queue = DispatchQueue(label: "com.diwasupadhyay.catter.dvt")
    private let client = DVTClient()
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var foreground = true
    private var maySendUpdates: Bool { foreground || backgroundUpdatesAllowed }
    var canConfirmRestored: Bool { unresolved && !busy && !refreshing && lastSent == nil }
    var selected: Coordinate? { try? Coordinate(latitude: latitude, longitude: longitude) }

    init() {
        let previous = UserDefaults.standard.bool(forKey: "simulationUnresolved")
        unresolved = previous
        status = previous ? "A previous simulation may still be active. Restore before continuing." : "Ready to choose a location"
    }

    func select(_ coordinate: Coordinate) {
        latitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude)
        longitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), coordinate.longitude)
    }

    private func markUnresolved(_ value: Bool) {
        unresolved = value
        UserDefaults.standard.set(value, forKey: "simulationUnresolved")
    }

    private func perform(watchdogSeconds: UInt64 = 30, _ work: @escaping () throws -> Void) async throws {
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: watchdogSeconds * 1_000_000_000) } catch { return }
            self?.failure = "The operation is taking longer than expected. Preparation or the device may still be busy. Keep the app open; do not assume the location was restored."
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try work(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    var statusTitle: String {
        if restoring { return "Restoring real location" }
        if busy && !refreshing { return "Connecting and applying location" }
        if awaitingRestoreReading { return "Simulation stopped" }
        if failure != nil { return connected ? "Action needed" : "Connection interrupted" }
        if realLocationReceived { return "Real location received" }
        if sessionNeedsCheck { return "Connection needs checking" }
        if refreshing { return "Simulation active" }
        if unresolved { return "Location needs verification" }
        return connected ? "Ready to set location" : "Ready"
    }

    /// A failed command can leave the location unchanged or already applied.
    /// Retry the same coordinate once only; never retry background refreshes.
    private func sendWithRecovery(_ coordinate: Coordinate, token: Int) async throws {
        try await ensureConnected()
        guard foreground, token == generation else { throw CancellationError() }
        do { try await perform { [client] in try client.set(coordinate) } }
        catch {
            guard foreground, token == generation else { throw CancellationError() }
            connected = false
            status = "Connection lost. Reconnecting once..."
            try await ensureConnected()
            guard foreground, token == generation else { throw CancellationError() }
            try await AccessManager.shared.requireAccess(fresh: true)
            guard foreground, token == generation else { throw CancellationError() }
            try await perform { [client] in try client.set(coordinate) }
        }
    }

    private func stopLoop() {
        generation += 1
        loop?.cancel()
        loop = nil
        refreshing = false
        activityChanged?(false)
    }

    private func ensureConnected(allowPreparation: Bool = true) async throws {
        guard !connected else { return }
        pairingAvailable = PairingStore.isAvailable
        guard pairingAvailable else { throw AppError.message("Pairing is not set up yet. Open Settings and choose Pair this iPhone.") }
        status = "Connecting to this iPhone…"
        try await perform(watchdogSeconds: 360) { [client] in try client.connect(pairingURL: PairingStore.url(), progress: { [weak self] message in
            Task { @MainActor in self?.status = message }
        }, allowPreparation: allowPreparation) }
        connected = true
        sessionNeedsCheck = false
    }

    func connect() async {
        guard !busy else { return }
        // A fresh tunnel may be unavailable after leaving Wi-Fi even if an existing
        // DVT session still works. Never tear it down just to press Connect again.
        // This preserves a handle; only a successful command tests its liveness.
        if connected {
            status = "Existing session kept. Send a new location to test it."
            return
        }
        stopLoop()
        busy = true
        defer { busy = false }
        connected = false
        do {
            try await ensureConnected()
            failure = nil
            status = unresolved ? "Connected. A previous location may still be active." : "Connected — choose a location and tap Set"
        } catch { operationFailed(error) }
    }

    private func operationFailed(_ error: Error) {
        stopLoop()
        awaitingRestoreReading = false
        connected = false
        failure = error.localizedDescription
        sessionNeedsCheck = false
        status = unresolved ? "Connection interrupted. Location may still be simulated." : "Could not connect — check Settings"
    }

    func start() async {
        guard !busy else { return }
        guard installationInProgress?() != true else {
            failure = "Catter is renewing. Wait until renewal finishes before changing location."
            return
        }
        guard let coordinate = selected else {
            failure = "Enter valid coordinates or choose a place on the map."
            return
        }
        stopLoop()
        awaitingRestoreReading = false
        realLocationReceived = false
        let token = generation
        busy = true
        defer { busy = false }
        do { try await AccessManager.shared.requireAccess(fresh: true) }
        catch {
            failure = error.localizedDescription
            status = "Access could not be verified. Restore remains available."
            return
        }
        do {
            try await ensureConnected()
            guard foreground, token == generation else { return }
            try await AccessManager.shared.requireAccess()
            guard foreground, token == generation else { return }
            markUnresolved(true)
            try await sendWithRecovery(coordinate, token: token)
            lastCommandAt = Date()
            locationSent?(coordinate)
            lastSent = coordinate
            sessionNeedsCheck = false
            failure = nil
            guard foreground, token == generation else {
                status = "Location sent. Refreshing paused while the app is away."
                return
            }
            status = "Location sent — check another app to verify"
            beginLoop()
        } catch { operationFailed(error) }
    }

    private func beginLoop() {
        let token = generation
        refreshing = true
        activityChanged?(true)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                guard let self, self.maySendUpdates, self.generation == token, self.connected else { return }
                if self.busy { continue }
                guard let coordinate = self.lastSent else { return }
                self.busy = true
                do { try await AccessManager.shared.requireAccess() }
                catch {
                    guard self.generation == token else {
                        if !self.restoring { self.busy = false }
                        return
                    }
                    self.stopLoop()
                    self.busy = false
                    self.failure = error.localizedDescription
                    self.status = "Location updates stopped. Restore remains available."
                    return
                }
                do {
                    guard self.generation == token, self.maySendUpdates else {
                        if !self.restoring { self.busy = false }
                        return
                    }
                    try await self.perform { [client = self.client] in try client.set(coordinate) }
                    guard self.generation == token else {
                        if !self.restoring { self.busy = false }
                        return
                    }
                    let wasChecking = self.sessionNeedsCheck
                    self.sessionNeedsCheck = false
                    self.lastCommandAt = Date()
                    self.failure = nil
                    if wasChecking {
                        self.status = "Location refresh succeeded. Check another app to verify."
                    }
                } catch {
                    guard self.generation == token else {
                        if !self.restoring { self.busy = false }
                        return
                    }
                    self.operationFailed(error)
                    self.busy = false
                    return
                }
                self.busy = false
            }
        }
    }

    func restore() async {
        guard !restoring, !busy || refreshing else { return }
        awaitingRestoreReading = false
        realLocationReceived = false
        restoring = true
        stopLoop()
        busy = true
        status = "Stopping simulation…"
        defer { busy = false; restoring = false }
        do {
            // Restore must not download or personalize a developer image.
            // Use the existing handle first, then reconnect only if necessary.
            try await ensureConnected(allowPreparation: false)
            markUnresolved(true)
            do {
                try await perform { [client] in try client.restore() }
            } catch {
                // A saved handle can be stale after locking. Clear is idempotent:
                // reconnect once and retry, never restart the simulation here.
                connected = false
                try await ensureConnected(allowPreparation: false)
                try await perform { [client] in try client.restore() }
            }
            lastSent = nil
            awaitingRestoreReading = true
            lastCommandAt = Date()
            connected = false
            sessionNeedsCheck = false
            status = "Simulation stopped. Checking for a fresh location…"
            failure = nil
            restoreCompleted?()
        } catch { operationFailed(error) }
    }

    func restorationReading(simulated: Bool?) {
        guard unresolved, !refreshing, lastSent == nil else { return }
        if simulated == false {
            awaitingRestoreReading = false
            realLocationReceived = true
        }
        if simulated == true {
            status = "iOS still reports a simulated location. Try Restore again."
        } else {
            status = simulated == false ? "Fresh non-simulated location received. Check Maps to confirm; addresses may refresh later." : "Fresh location received. Check Maps to confirm."
        }
    }

    func restorationUnavailable(_ message: String) {
        guard unresolved, !refreshing, lastSent == nil else { return }
        awaitingRestoreReading = false
        status = message
    }

    func confirmRestored() {
        guard canConfirmRestored else { return }
        awaitingRestoreReading = false
        markUnresolved(false)
        lastSent = nil
        status = "Real location confirmed by you"
    }

    func enteredBackground() {
        foreground = false
        if connected { sessionNeedsCheck = true }
        if refreshing && backgroundUpdatesAllowed {
            status = "Background updates requested. Verify location after locking."
            return
        }
        stopLoop()
        if unresolved { status = "Updates paused while the app is away. Location may remain simulated." }
    }

    func enteredForeground() {
        let returningFromBackground = !foreground
        foreground = true
        pairingAvailable = PairingStore.isAvailable
        // A successful refresh before suspension does not prove the tunnel
        // survived it. The next successful command clears this flag.
        if returningFromBackground && connected { sessionNeedsCheck = true }
        if sessionNeedsCheck {
            status = "Session needs checking after leaving the app. Set or Restore to test it."
        }
    }

    func setBackgroundUpdatesAllowed(_ value: Bool) {
        backgroundUpdatesAllowed = value
        if !value && !foreground && refreshing {
            stopLoop()
            sessionNeedsCheck = connected
            status = "Background updates stopped. Return to the app to check or restore."
        }
    }

    func showImportError(_ error: Error) { failure = "Import failed: \(error.localizedDescription)" }

    func importPairing(_ source: URL) async {
        guard !busy, !unresolved else { return }
        stopLoop()
        busy = true
        defer { busy = false }
        connected = false
        do {
            try await perform { [client] in client.close(); try PairingStore.importFile(source) }
            pairingAvailable = true
            failure = nil
            status = "Pairing ready. Open VPN, then set a location."
        } catch { failure = error.localizedDescription }
    }

    func removePairing() async {
        guard !busy, !unresolved else { return }
        stopLoop()
        busy = true
        defer { busy = false }
        connected = false
        do {
            try await perform { [client] in client.close(); try PairingStore.remove() }
            pairingAvailable = false
            status = "Pairing removed"
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}
