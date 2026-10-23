import BackgroundTasks
import Foundation

@MainActor
enum RenewalScheduler {
    static let identifier = "com.diwasupadhyay.catter.renewal"
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task { @MainActor in
                let manager = RenewalManager.shared
                manager.load()
                await manager.renewIfDue()
                schedule()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }
    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard RenewalManager.shared.automatic else { return }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        // iOS decides when (or whether) to run this. Foreground attempts remain
        // available, and no success is inferred from scheduling a request.
        try? BGTaskScheduler.shared.submit(request)
    }
}
