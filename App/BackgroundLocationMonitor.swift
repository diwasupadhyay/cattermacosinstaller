import CoreLocation
import Combine
import Foundation

/// Opt-in observation of the system location. Never writes coordinates or stores a history.
/// Background location delivery is not a guarantee that the developer tunnel survives.
@MainActor
final class BackgroundLocationMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var running = false
    @Published private(set) var permission = "Not requested"
    @Published private(set) var message = "Off"
    @Published private(set) var observation: String?
    @Published private(set) var restoredCoordinate: Coordinate?
    @Published private(set) var restoredAccuracy: Double?
    var availabilityChanged: ((Bool) -> Void)?
    var restorationReading: ((Bool?) -> Void)?
    var restorationUnavailable: ((String) -> Void)?
    private let manager = CLLocationManager()
    private var sessionActive = false
    private var backgroundSession: CLBackgroundActivitySession?
    private var sampleRequestedAt: Date?
    private var verification: Task<Void, Never>?

    func cancelRestoreCheck() {
        verification?.cancel()
        verification = nil
        sampleRequestedAt = nil
        restoredCoordinate = nil
        restoredAccuracy = nil
        if !sessionActive { manager.stopUpdatingLocation() }
    }

    func sampleAfterRestore() {
        observation = nil
        restoredCoordinate = nil
        restoredAccuracy = nil
        verification?.cancel()
        sampleRequestedAt = Date()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        let authorization = manager.authorizationStatus
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
            verification = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                guard let self else { return }
                self.manager.stopUpdatingLocation()
                self.sampleRequestedAt = nil
                self.verification = nil
                self.restorationUnavailable?("Simulation stopped, but iOS has not supplied an accurate real location yet. Check location permission, then retry the location check.")
            }
        } else {
            sampleRequestedAt = nil
            restorationUnavailable?("Simulation stopped; location access is needed to check a fresh fix here. Verify your actual position in Maps or Find My.")
        }
    }

    override init() {
        super.init()
        enabled = UserDefaults.standard.bool(forKey: "backgroundMonitoringEnabled")
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }

    func requestAlwaysAccess() {
        // Explicit user action only; iOS controls whether and when prompts appear.
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            message = "Allow While Using first, then request Always access here."
        } else if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
            message = "Choose Always if offered, or change Location access in Catter's iPhone Settings."
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "backgroundMonitoringEnabled")
        if value && manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        update()
    }

    func setSessionActive(_ value: Bool) {
        // A repeated "inactive" notification (such as opening Maps after
        // Restore) must not silently cancel the pending real-location check.
        guard sessionActive != value else {
            if value { update() }
            return
        }
        verification?.cancel()
        verification = nil
        sampleRequestedAt = nil
        sessionActive = value
        if value { restoredCoordinate = nil; restoredAccuracy = nil }
        update()
    }

    private func setRunning(_ value: Bool) {
        guard running != value else { return }
        running = value
        availabilityChanged?(value)
    }

    private func update() {
        let authorization = manager.authorizationStatus
        switch authorization {
        case .authorizedAlways: permission = "Always"
        case .authorizedWhenInUse: permission = "While Using"
        case .denied: permission = "Denied"
        case .restricted: permission = "Restricted"
        default: permission = "Not requested"
        }
        let allowed = authorization == .authorizedWhenInUse || authorization == .authorizedAlways
        if enabled && sessionActive && allowed {
            if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
            if !running { manager.startUpdatingLocation() }
            setRunning(true)
            message = "Background monitoring active"
        } else {
            // Restore verification also uses this manager, independently of
            // the opt-in background simulation session.
            if sampleRequestedAt != nil && allowed {
                manager.startUpdatingLocation()
            } else {
                manager.stopUpdatingLocation()
                if sampleRequestedAt != nil {
                    verification?.cancel()
                    verification = nil
                    sampleRequestedAt = nil
                    restorationUnavailable?("Location access changed. Simulation was stopped; check your actual location in Maps.")
                }
            }
            backgroundSession?.invalidate()
            backgroundSession = nil
            setRunning(false)
            if !enabled { message = "Off"; observation = nil }
            else if authorization == .denied || authorization == .restricted {
                message = "Location access denied. Allow it in iPhone Settings."
            } else if !allowed { message = "Allow location access to enable background monitoring" }
            else { message = "Starts when you set a location" }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if sampleRequestedAt != nil && verification == nil && manager.authorizationStatus != .notDetermined {
            sampleAfterRestore()
        }
        update()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        if let requested = sampleRequestedAt, location.timestamp < requested { return }
        guard abs(location.timestamp.timeIntervalSinceNow) < 30 else { return }
        if sampleRequestedAt != nil {
            let simulated = location.sourceInformation?.isSimulatedBySoftware
            // A fresh timestamp alone can still be a very coarse network fix.
            let precise = location.horizontalAccuracy <= 100
            if simulated == false && !precise {
                observation = "Waiting for a more accurate real-location reading..."
                return
            }
            restorationReading?(simulated)
            if simulated == false && precise {
                restoredCoordinate = try? Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                restoredAccuracy = location.horizontalAccuracy
                verification?.cancel()
                verification = nil
                sampleRequestedAt = nil
                if !sessionActive { manager.stopUpdatingLocation() }
            }
        }
        let simulated = location.sourceInformation?.isSimulatedBySoftware == true ? " · iOS marks simulated" : ""
        let time = location.timestamp.formatted(date: .omitted, time: .standard)
        observation = String(format: "iOS reported %.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude)
            + " at \(time)\(simulated)"
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        if sampleRequestedAt != nil {
            verification?.cancel()
            verification = nil
            sampleRequestedAt = nil
            restorationUnavailable?("Simulation was stopped, but a fresh real-location reading is unavailable. Check Location Services and Maps.")
        }
        message = "Location monitor: \(error.localizedDescription)"
        manager.stopUpdatingLocation()
        backgroundSession?.invalidate()
        backgroundSession = nil
        setRunning(false)
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        message = "iOS paused location monitoring. Background updates are not assured."
        setRunning(false)
    }
}
