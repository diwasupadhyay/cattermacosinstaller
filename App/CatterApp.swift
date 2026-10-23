import SwiftUI

@main
struct CatterApp: App {
    init() { RenewalScheduler.register() }
    @StateObject private var updates = UpdateManager.shared
    @Environment(\.openURL) private var openURL
    @State private var dismissedUpdate: String?
    @State private var showActivation = false
    @State private var checkedActivation = false
    @StateObject private var model = SessionModel()
    @StateObject private var monitor = BackgroundLocationMonitor()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            CatterWorkspace(model: model, monitor: monitor)
                .tint(CatterTheme.accent)
                .preferredColorScheme(.dark)
                .task {
                    guard !checkedActivation else { return }
                    checkedActivation = true
                    let access = AccessManager.shared
                    if access.hasSavedActivation {
                        try? await access.requireAccess(fresh: true)
                    } else { showActivation = true }
                }
                .task { await updates.check() }
                .task { RenewalManager.shared.load(); await RenewalManager.shared.renewIfDue() }
                .safeAreaInset(edge: .top) {
                    if let version = updates.availableVersion, dismissedUpdate != version {
                        HStack {
                            Button("Catter " + version + " available") { openURL(UpdateManager.downloadURL) }
                            Spacer()
                            Button { dismissedUpdate = version } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss update notice")
                        }.font(.subheadline).padding().background(.ultraThinMaterial)
                    }
                }
                .sheet(isPresented: $showActivation) { ActivationWelcomeView() }
                .onAppear {
                    model.installationInProgress = { RenewalManager.shared.busy }
                    monitor.availabilityChanged = { model.setBackgroundUpdatesAllowed($0) }
                    model.activityChanged = { monitor.setSessionActive($0) }
                    model.restoreCompleted = { monitor.sampleAfterRestore() }
                    model.restoreVerificationCancelled = { monitor.cancelRestoreCheck() }
                    monitor.restorationReading = { model.restorationReading(simulated: $0) }
                    monitor.restorationUnavailable = { model.restorationUnavailable($0) }
                }
                .onChange(of: phase) { _, value in
                    if value == .background { model.enteredBackground(); RenewalScheduler.schedule() }
                    if value == .active { model.enteredForeground(); Task { await updates.check(); await RenewalManager.shared.renewIfDue() } }
                }
        }
    }
}
