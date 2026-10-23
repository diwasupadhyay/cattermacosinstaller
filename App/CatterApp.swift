import SwiftUI

@main
struct CatterApp: App {
    init() { RenewalScheduler.register() }
    @StateObject private var updates = UpdateManager.shared
    @Environment(\.openURL) private var openURL
    @State private var dismissedUpdate: String?
    @State private var showActivation = false
    @State private var checkedActivation = false
    @State private var checkOnReturn = false
    @State private var checkingActivation = false
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
                    await checkActivation()
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
                    if value == .background { model.enteredBackground(); checkOnReturn = true; RenewalScheduler.schedule() }
                    if value == .active { model.enteredForeground(); Task {
                        if checkOnReturn { checkOnReturn = false; await checkActivation() }
                        await updates.check(); await RenewalManager.shared.renewIfDue()
                    } }
                }
        }
    }
    @MainActor private func checkActivation() async {
        guard !checkingActivation, !showActivation else { return }
        checkingActivation = true
        defer { checkingActivation = false }
        let access = AccessManager.shared
        if access.hasSavedActivation { try? await access.requireAccess(fresh: true) }
        if !access.isActivated { showActivation = true }
    }

}
