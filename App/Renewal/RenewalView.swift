import SwiftUI

struct RenewalView: View {
    @ObservedObject private var renewal = RenewalManager.shared
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var remember = false
    @State private var confirm = false
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section("Signing expiry") {
                if let expiry = SigningStatus.expiration { Text(expiry.formatted(date: .abbreviated, time: .shortened)) }
                Text("Renew before the seven-day signing period ends. Wi-Fi and LocalDevVPN are required. An expired app needs computer recovery.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if renewal.ready {
                Section("Apple Account") {
                    TextField("Apple Account email", text: $email).textContentType(.username)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().focused($editing)
                    SecureField("Password", text: $password).textContentType(.password).focused($editing)
                    Toggle("Enable automatic renewal", isOn: $remember)
                    Text("If enabled, your Apple Account email and password are saved in this iPhone's Keychain for renewal. They are not synced or sent to Catter's server. You can remove them below.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Renew Catter") { editing = false; confirm = true }
                        .disabled(renewal.busy || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                }.disabled(renewal.busy)
            } else {
                Section {
                    Text("Install this version with Catter Setup and accept Enable on-device renewal. Setup transfers the existing signing identity once; your Apple password stays off the transfer.")
                    Button("Check preparation") { renewal.load() }.disabled(renewal.busy)
                }
            }
            Section {
                if renewal.busy { ProgressView() }
                Text(renewal.message).font(.callout)
                if renewal.automatic {
                    Button("Disable automatic renewal and remove saved login", role: .destructive) { renewal.disableAutomatic(); remember = false }
                        .disabled(renewal.busy)
                }
                Text("Automatic attempts depend on iOS allowing execution. Restore an active simulated location first. Apple may require a new verification code; open Catter regularly to check expiry.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Authentication privacy") {
                Text("Apple sign-in goes directly to Apple. The SideStore anisette service supplies authentication metadata and receives an app-generated identifier and provisioning blob, but no Apple password, verification code or signing key. No SideStore app is needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Renew Catter")
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } } }
        .task { renewal.load() }
        .confirmationDialog("Renew this installed copy of Catter?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Sign and reinstall Catter") {
                let secret = password; password = ""
                Task { await renewal.renew(email: email.trimmingCharacters(in: .whitespaces), password: secret, remember: remember) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Catter may close during installation. Reopen it to verify the new expiry. Your app data and invitation identity must stay unchanged.") }
        .alert("Apple verification", isPresented: Binding(get: { renewal.awaitingCode }, set: { if !$0 { renewal.reply(code: nil) } })) {
            TextField("Six-digit code", text: $code).keyboardType(.numberPad)
            Button("Verify") { let reply = code; code = ""; renewal.reply(code: reply) }
            Button("Cancel", role: .cancel) { code = ""; renewal.reply(code: nil) }
        } message: { Text("Enter the code sent by Apple. This is different from your Catter invitation.") }
        .onDisappear { password = ""; code = "" }
    }
}
