import SwiftUI
import UniformTypeIdentifiers

enum SettingsPage: String, Identifiable {
    case account, connection, motion, updates, help
    var id: String { rawValue }
    var title: String {
        switch self {
        case .account: return "Access & signing"
        case .connection: return "Connection"
        case .motion: return "Random movement"
        case .updates: return "Updates"
        case .help: return "Help & diagnostics"
        }
    }
}

struct SetupView: View {
    @StateObject private var pairing = OnDevicePairing()
    @ObservedObject var model: SessionModel
    @ObservedObject var monitor: BackgroundLocationMonitor
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Image("CatterLogo").resizable().scaledToFit().frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Catter").font(.title2.weight(.semibold))
                            Text("Your phone. Your location.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 12)
                }
                Section("Your iPhone") {
                    destination(.connection, icon: "network", subtitle: model.pairingAvailable ? "VPN, pairing and background updates" : "Prepare this iPhone to get started")
                    destination(.motion, icon: "arrow.triangle.swap", subtitle: "Small movements around your selected location")
                    destination(.account, icon: "checkmark.shield", subtitle: "Invitation, signing expiry and renewal")
                }
                Section("About & support") {
                    destination(.updates, icon: "arrow.down.circle", subtitle: "Installed version and new releases")
                    destination(.help, icon: "questionmark.circle", subtitle: "Guides, diagnostics and advanced options")
                }
                Section {
                    Label(model.statusTitle, systemImage: model.failure == nil ? "location.circle" : "exclamationmark.circle")
                        .font(.subheadline)
                    Text("Restore real location from the Location tab when you finish.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background(CatterTheme.background)
            .navigationTitle("Settings")
        }
    }
    private func destination(_ page: SettingsPage, icon: String, subtitle: String) -> some View {
        NavigationLink {
            SettingsDetailView(page: page, model: model, monitor: monitor, pairing: pairing)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).frame(width: 28).foregroundStyle(CatterTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(page.title).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 9)
        }
    }
}

struct SettingsDetailView: View {
    let page: SettingsPage
    @ObservedObject var model: SessionModel
    @ObservedObject var monitor: BackgroundLocationMonitor
    @Environment(\.openURL) private var openURL
    @ObservedObject var pairing: OnDevicePairing
    @State private var importing = false
    @State private var deleting = false
    @ObservedObject private var access = AccessManager.shared
    @ObservedObject private var updates = UpdateManager.shared
    @State private var vpnStorePrompt = false
    @AppStorage("motionMinimum") private var motionMinimum = 5.0
    @AppStorage("motionMaximum") private var motionMaximum = 10.0
    @AppStorage("motionInterval") private var motionInterval = 60.0


    var body: some View {
        Form {
                if page == .motion {
                    Section {
                        Text("Choose a new point around the location you set. Movements stay inside this range from that original point.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Movement range") {
                        Stepper("Minimum: \(Int(motionMinimum)) metres", value: $motionMinimum, in: 0...motionMaximum)
                        Stepper("Maximum: \(Int(motionMaximum)) metres", value: $motionMaximum, in: motionMinimum...100)
                        Stepper("Every \(Int(motionInterval)) seconds", value: $motionInterval, in: 15...3600, step: 15)
                        Button("Use 5-10 m every minute") { motionMinimum = 5; motionMaximum = 10; motionInterval = 60 }
                    }
                    Section("How it works") {
                        Text("Choose Random on the map, then tap Start random movement. Normal always holds a fixed location. Restore stops both movement and simulation.")
                        Text("Turn on Background location updates in Connection to request movement while locked. iOS may pause the app; missed movements are skipped, and timing is approximate.")
                        Text(model.motionSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if page == .account {
                Section("Your access") {
                    ActivationFields(disabled: model.busy)
                }
                Section("App signing") {
                    if let expiry = SigningStatus.expiration {
                        LabeledContent("Signing expires") { Text(expiry.formatted(date: .abbreviated, time: .shortened)) }
                        if SigningStatus.renewalDue(expiration: expiry) {
                            Text("Renew before signing expires. Computer reinstallation remains available if renewal fails. Keep the app installed.").font(.caption).foregroundStyle(.orange)
                        }
                    } else { Text("Signing expiry is unavailable for this build.").font(.caption).foregroundStyle(.secondary) }
                    Text("On-device renewal is experimental. Signing expiry is separate from invitation access.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Renewal") {
                    NavigationLink("Renew Catter on this iPhone") { RenewalView() }
                        .disabled(model.busy || model.unresolved)
                    if model.unresolved { Text("Restore and wait for a fresh real-location reading before renewing.").font(.caption) }
                }
                }
                if page == .connection {
                Section("Connection") {
                    Button("Open LocalDevVPN") {
                        openURL(URL(string: "localdevvpn://enable?scheme=catter")!) { opened in
                            if !opened { vpnStorePrompt = true }
                        }
                    }
                    Label(model.pairingAvailable ? "Pairing ready" : "One-time preparation needed",
                          systemImage: model.pairingAvailable ? "checkmark.circle" : "exclamationmark.circle")
                    if model.pairingAvailable {
                        Text("Your pairing file is kept in Catter's private app storage, outside the Files app. It is excluded from backup. Do not export or share pairing files; they grant developer access to your phone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.pairingAvailable { preparation }
                    if !pairing.message.isEmpty { Text(pairing.message).font(.callout).textSelection(.enabled) }
                    if let pin = pairing.pin { Text(pin).font(.largeTitle.monospacedDigit()).textSelection(.enabled) }
                    if pairing.running {
                        ProgressView("Waiting for pairing approval")
                        Button("Cancel pairing", role: .cancel) { pairing.cancel() }
                    } else if !model.pairingAvailable {
                        Button("Pair this iPhone") { pairing.start { model.enteredForeground() } }
                            .disabled(model.busy || model.unresolved || pairing.running)
                    }
                    if model.pairingAvailable {
                        Button("Check connection") { Task { await model.connect() } }.disabled(model.busy)
                    }
                    Text(model.status).font(.caption).textSelection(.enabled)
                    if let failure = model.failure {
                        DisclosureGroup("Error details") {
                            Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                        Text("Join Wi-Fi and connect LocalDevVPN, then retry. Keep Catter open during preparation.").font(.caption)
                    }
                }
                Section {
                    Toggle("Background location updates", isOn: Binding(
                        get: { monitor.enabled }, set: { monitor.setEnabled($0) }))
                    LabeledContent("Location permission", value: monitor.permission)
                    if monitor.permission != "Always" {
                        Button("Request Always location access") { monitor.requestAlwaysAccess() }
                    }
                    Button("Open Catter location settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    if monitor.enabled { Text(monitor.message).font(.caption) }
                } footer: {
                    Text("Uses location permission and more battery. iOS can still interrupt the session.")
                }
                }
                if page == .updates {
                Section("Updates") {
                    Text("Installed version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"))
                    if let version = updates.availableVersion {
                        Link("Download Catter " + version, destination: UpdateManager.downloadURL)
                        if !updates.notes.isEmpty { Text(updates.notes).font(.caption).foregroundStyle(.secondary) }
                        Text("Install the new IPA over Catter using your computer. Keep the app installed to preserve its data.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(updates.checking ? "Checking..." : "Check for updates") { Task { await updates.check(force: true) } }.disabled(updates.checking)
                    Text(updates.message).font(.caption).foregroundStyle(.secondary)
                }
                }
                if page == .help {
                Section("iPhone settings") {
                    Button("Open Catter settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    DisclosureGroup("Find Developer Mode") {
                        Text("Open Settings > Privacy & Security > Developer Mode. iOS does not provide a supported direct link to this page.")
                    }
                    DisclosureGroup("Find My settings") {
                        Text("Open Settings > your name > Find My. To check your current position, open the Find My app. Catter cannot change Find My's settings.")
                    }
                }

                Section {
                    DisclosureGroup("First-time setup") { preparation }
                    DisclosureGroup("Using mobile data") {
                        Text("Use a connected Wi-Fi network. Cellular-only connection and recovery are not currently supported on the tested phone, even when LocalDevVPN shows Connected.")
                    }
                    DisclosureGroup("Updates and reinstalling") {
                        Text("Install updates over the existing app with Catter Installer and the same Apple Account. Do not delete it first. Reinstall manually every seven days. Deleting the app removes its preparation data; the installer can restore a verified backup.")
                    }
                    DisclosureGroup("Diagnostics") {
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")")
                        Text(model.status).textSelection(.enabled)
                        if let observation = monitor.observation { Text(observation).textSelection(.enabled) }
                        Text("The last iOS reading is not independent verification of other apps. Observed GPS readings are not saved. Saved places and recent destinations stay on this iPhone.")
                    }
                    DisclosureGroup("Advanced") {
                        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 && !model.pairingAvailable {
                            Button("Pair via iPhone Settings") { pairing.start(viaSettings: true) { model.enteredForeground() } }
                                .disabled(model.busy || model.unresolved || pairing.running)
                        }
                        Button("Import pairing file") { importing = true }.disabled(model.busy || model.unresolved || pairing.running)
                        Button("Delete pairing file", role: .destructive) { deleting = true }.disabled(model.busy || model.unresolved || pairing.running)
                    }
                }
                }
            }
            .task { if access.hasSavedActivation { try? await access.requireAccess(fresh: true) } }
            .scrollContentBackground(.hidden)
            .background(CatterTheme.background)
            .navigationBarBackButtonHidden(pairing.running)
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(pairing.running || model.busy)
            .alert("Open LocalDevVPN in the App Store?", isPresented: $vpnStorePrompt) {
                Button("Open App Store") { openURL(URL(string: "https://apps.apple.com/app/id6755608044")!) }
                Button("Cancel", role: .cancel) { }
            } message: { Text("LocalDevVPN could not be opened. Install it, connect its VPN, then return to Catter.") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url): Task { await model.importPairing(url) }
                case .failure(let error): model.showImportError(error)
                }
            }
            .confirmationDialog("Delete pairing? You will need to prepare this phone again.", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete pairing", role: .destructive) { Task { await model.removePairing() } }
            }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Enable Developer Mode in iPhone Settings.")
            Text("2. Install LocalDevVPN from the App Store.")
            Text("3. Use Catter Installer on Windows or Mac to finish preparation, or pair here while connected to Wi-Fi and LocalDevVPN.")
            Text("4. Choose a place and tap Set location. Any remaining preparation runs automatically.").font(.caption)
            if let address = Bundle.main.object(forInfoDictionaryKey: "CatterSupportURL") as? String,
               let url = URL(string: address), url.scheme == "https" {
                Link("Setup instructions", destination: url)
            }
        }
    }

}


struct ActivationFields: View {
    @ObservedObject private var access = AccessManager.shared
    @State private var invitation = ""
    var disabled = false
    var body: some View {
        Text(access.message).font(.callout)
        SecureField(access.isActivated ? "Activation saved securely" : "Invitation code", text: $invitation)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .submitLabel(.done).disabled(access.isActivated || access.working || disabled)
        if !access.isActivated {
            Button(access.working ? "Checking..." : "Activate this iPhone") {
                let code = invitation; invitation = ""
                Task { await access.activate(code) }
            }.disabled(access.working || invitation.isEmpty || disabled)
            if access.hasSavedActivation {
                Button("Check saved activation") { Task { try? await access.requireAccess(fresh: true) } }
                    .disabled(access.working || disabled)
            }
        } else { Label("This iPhone is activated", systemImage: "checkmark.shield") }
        Text("Activation stays in the iPhone Keychain. You do not need to enter your code each time. Internet is required to check access; Restore stays available.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct ActivationWelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var access = AccessManager.shared
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("Activate Catter").font(.title2.bold())
                    Text("Enter your invitation to enable location changes on this iPhone.") }
                Section { ActivationFields() }
            }
            .navigationTitle("Welcome")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Not now") { dismiss() }.disabled(access.working)
            } }
            .interactiveDismissDisabled(access.working)
            .onChange(of: access.isActivated) { _, activated in if activated { dismiss() } }
        }
    }
}
