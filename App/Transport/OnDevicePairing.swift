import Foundation
import UIKit
import UserNotifications
import Combine

/// Owns one native pairing operation. Raw pointers are released only after its worker returns.
@MainActor
final class OnDevicePairing: NSObject, ObservableObject, NetServiceDelegate {
    @Published private(set) var running = false
    @Published private(set) var message = ""
    @Published private(set) var pin: String?
    private var service: NetService?
    private var cancellation: OpaquePointer?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var timeout: Task<Void, Never>?
    private var cancellationReason: String?

    func start(viaSettings: Bool = false, completion: @escaping () -> Void) {
        guard !running else { return }
        guard !viaSettings || ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            message = "Pair via Settings requires iOS 27. Use Pair this iPhone instead."
            return
        }
        guard !PairingStore.isAvailable else { message = "This phone is already paired."; return }
        running = true
        pin = nil
        cancellationReason = nil
        message = viaSettings ? "Allow Local Network, then open Settings > Privacy & Security > Developer Mode > Pair with Host. Choose Catter." : "Keep LocalDevVPN connected on Wi-Fi. Accept the pairing prompt on this iPhone and keep this app open."
        if viaSettings { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
        cancellation = pairable_host_cancel_new()
        guard let cancellation else { running = false; message = "Could not allocate a pairing session."; return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Pair this iPhone") { [weak self] in
            Task { @MainActor in self?.cancel(reason: "iOS ended the pairing time window. Return here and try again, then approve promptly in Settings.") }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
            self?.cancel(reason: "Pairing timed out. Check Local Network permission and Developer Mode, then try again.")
        }
        let context = Unmanaged.passRetained(self).toOpaque()
        DispatchQueue.global(qos: .userInitiated).async {
            var pairing: OpaquePointer?
            var failure: String?
            do {
                defer { if let pairing { rp_pairing_file_free(pairing) } }
                let error: UnsafeMutablePointer<IdeviceFfiError>?
                if viaSettings {
                    error = "Catter".withCString { name in
                        ghostly_pairable_host_accept(name, nil, 0, false, pairingPublished,
                            pairingPIN, context, cancellation, nil, nil, &pairing)
                    }
                } else {
                    error = ghostly_pair_network(cancellation, &pairing)
                }
                try DVTClient.check(error, stage: "Pair this iPhone")
                guard let pairing else { throw AppError.message("Pairing returned no credentials.") }
                let temporary = try PairingStore.url().deletingLastPathComponent()
                    .appendingPathComponent(UUID().uuidString + ".pending")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Data().write(to: temporary, options: [.completeFileProtection])
                try DVTClient.check(temporary.path.withCString { rp_pairing_file_write(pairing, $0) }, stage: "Save pairing")
                try PairingStore.importFile(temporary)
            } catch { failure = error.localizedDescription }
            let result = failure
            DispatchQueue.main.async {
                let owner = Unmanaged<OnDevicePairing>.fromOpaque(context).takeRetainedValue()
                owner.finish(error: result)
                completion()
            }
        }
    }

    func cancel(reason: String = "Pairing cancelled.") {
        guard running else { return }
        cancellationReason = reason
        service?.stop()
        if let cancellation { pairable_host_cancel_signal(cancellation) }
    }

    fileprivate func publish(port: UInt16, identifier: String, data: Data) {
        guard running, cancellationReason == nil else { return }
        do {
            guard let txt = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
                throw AppError.message("Invalid pairing advertisement.")
            }
            let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.",
                name: identifier, port: Int32(port))
            service.includesPeerToPeer = true
            service.delegate = self
            service.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
            self.service = service
            service.publish()
        } catch { cancel(reason: error.localizedDescription) }
    }

    fileprivate func showPIN(_ value: String) {
        guard running, cancellationReason == nil else { return }
        pin = value
        message = "Enter this code in the iPhone Settings pairing prompt."
        let content = UNMutableNotificationContent()
        content.title = "Catter pairing code"
        content.body = value
        UNUserNotificationCenter.current().add(.init(identifier: "catter.pairing", content: content, trigger: nil))
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        cancel(reason: "Could not advertise pairing: \(errorDict). Allow Local Network in Settings.")
    }

    private func finish(error: String?) {
        timeout?.cancel()
        timeout = nil
        service?.stop()
        service = nil
        if let cancellation { pairable_host_cancel_free(cancellation) }
        cancellation = nil
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        backgroundTask = .invalid
        running = false
        pin = nil
        // A completed credential write wins a late cancellation race.
        message = error == nil ? "Paired. Connect LocalDevVPN, then tap Prepare this iPhone." : (cancellationReason ?? error!)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["catter.pairing", "ghostly.pairing"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["catter.pairing", "ghostly.pairing"])
    }
}

private func pairingPublished(_ port: UInt16, _ identifier: UnsafePointer<CChar>?,
                              _ bytes: UnsafePointer<UInt8>?, _ count: UInt, _ context: UnsafeMutableRawPointer?) {
    guard let identifier, let bytes, let context else { return }
    let name = String(cString: identifier)
    let data = Data(bytes: bytes, count: Int(count))
    let owner = Unmanaged<OnDevicePairing>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { owner.publish(port: port, identifier: name, data: data) }
}

private func pairingPIN(_ pin: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let pin, let context else { return }
    let value = String(cString: pin)
    let owner = Unmanaged<OnDevicePairing>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { owner.showPIN(value) }
}
