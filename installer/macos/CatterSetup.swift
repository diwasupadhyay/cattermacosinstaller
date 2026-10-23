import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SetupModel: ObservableObject {
    @Published var updateVersion = ""
    @Published var updateMessage = "Check for updates"
    @Published var step = 0
    @Published var email = ""
    @Published var password = ""
    @Published var signedIn = false
    @Published var access = false
    @Published var account = ""
    @Published var busy = false
    @Published var ready = false
    @Published var ipa = ""
    @Published var ipaName = "No app selected"
    @Published var status = "Starting setup..."
    @Published var details = ""
    @Published var failed = false
    @Published var prompt: SetupPrompt?
    @Published var statusTitle = "Getting ready"
    @Published var authenticationMethod = "Local Mac"
    private var userOperation = false

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    var finishClosing: (() -> Void)?
    private var closing = false
    private var closePending = false

    private func clearEngineState() {
        ready = false
        busy = false
        access = false
        signedIn = false
        account = ""
        email = ""
        password = ""
        ipa = ""
        ipaName = "No app selected"
        step = 0
        prompt = nil
        authenticationMethod = "Local Mac"
        userOperation = false
    }

    func checkCrashRecovery() {
        ready = true; busy = true; access = true; signedIn = true
        account = "synthetic"; password = "synthetic"; ipa = "synthetic"
        clearEngineState()
        precondition(!ready && !busy && !access && !signedIn && account.isEmpty && password.isEmpty && ipa.isEmpty && prompt == nil)
    }

    func checkStatusPresentation() {
        report("Sign-in stopped (HTTP 429).", error: true)
        precondition(failed && statusTitle == "Apple needs a pause")
        let original = status
        report("Invitation verified and remembered securely for this iPhone.")
        precondition(failed && status == original)
        report("Background message")
        precondition(failed && status == original)
        userOperation = true
        report("Remote Mac metadata enabled. Enter your password and sign in again.")
        precondition(!failed && statusTitle == "Fallback ready" && !signedIn)
        precondition(authenticationMethod == "Remote Mac (approved)")
        report("Signed in. Click Continue to choose your IPA.")
        precondition(statusTitle == "Apple Account connected")
        clearEngineState()
    }

    func start() {
        guard self.process?.isRunning != true else { return }
        clearEngineState()
        closePending = false
        failed = false
        prompt = nil
        buffer.removeAll()
        guard let root = Bundle.main.resourceURL else { return }
        let process = Process()
        process.executableURL = root.appendingPathComponent("backend/runtime/bin/python3")
        process.arguments = ["-B", "-E", "-X", "utf8", root.appendingPathComponent("backend/backend.py").path]
        process.currentDirectoryURL = root.appendingPathComponent("backend")
        var environment = ProcessInfo.processInfo.environment
        environment["LOCALAPPDATA"] = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support").path
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        input = stdin.fileHandleForWriting
        // Mutate the line buffer only on the main actor.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self, self.process === ended else { return }
                self.clearEngineState()
                if self.closePending {
                    self.closing = true
                    self.finishClosing?()
                    return
                }
                if !self.closing { self.report("The setup engine stopped (exit \(ended.terminationStatus)). Click Restart setup. If it happens again, share this exit code and your macOS version.", error: true) }
            }
        }
        self.process = process
        do {
            try process.run()
            report("Welcome to Catter. Verify your invitation to begin.")
            Task { @MainActor [weak self, weak process] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let process, self.process === process, !self.ready, !self.closing else { return }
                self.report("Setup has not responded. Close and reopen Catter Setup. No installation has been confirmed.", error: true)
            }
        } catch { report("Could not start setup: \(error.localizedDescription)", error: true) }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            receive(message)
        }
    }

    func report(_ text: String, error: Bool = false) {
        details = String((details + text + "\n").suffix(64_000))
        // Background invitation checks must not replace an actionable error.
        if text.hasPrefix("Invitation verified") { return }
        if failed && !error && !userOperation { return }
        failed = error
        statusTitle = error ? "Action needed" : busy ? "Working on it" : "Ready"
        status = text
        if text.contains("HTTP 429") {
            statusTitle = "Apple needs a pause"
            status = "Apple temporarily limited sign-in requests. Wait before trying again; repeated attempts may prolong the limit. Your installed app is unchanged."
        } else if text.contains("Remote Mac metadata enabled") {
            authenticationMethod = "Remote Mac (approved)"
            statusTitle = "Fallback ready"
            status = "Enter your password and sign in again. Switching methods has not signed you in."
        } else if text.contains("Signed in. Click Continue") {
            statusTitle = "Apple Account connected"
            status = "Continue to choose the Catter IPA."
        } else if text.hasPrefix("Setup complete.") {
            statusTitle = "Your iPhone is ready"
        }
    }

    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "update":
            updateVersion = message["version"] as? String ?? ""
            updateMessage = message["text"] as? String ?? "Check for updates"
        case "state":
            ready = true
            access = message["access"] as? Bool ?? false
            busy = message["busy"] as? Bool ?? false
            signedIn = message["authenticated"] as? Bool ?? false
            if !busy { userOperation = false }
            if !access { step = 0 }
            account = message["email"] as? String ?? ""
            if message["ipa"] as? Bool != true { ipa = ""; ipaName = "No app selected" }
        case "status": report(message["text"] as? String ?? "")
        case "error": report(message["text"] as? String ?? "Setup failed.", error: true)
        case "ipa":
            ipa = message["path"] as? String ?? ""
            ipaName = (message["name"] as? String ?? "Catter") + " · build " + (message["build"] as? String ?? "")
        case "signed_out": email = ""; password = ""; step = 0
        case "prompt": prompt = SetupPrompt(message)
        case "bye": closePending = false; closing = true; finishClosing?()
        default: break
        }
    }

    func send(_ command: [String: Any], operation: Bool = true) {
        if operation {
            guard ready, !busy else { return }
            busy = true; userOperation = true; failed = false
            statusTitle = "Working on it"; status = "Please wait..."
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: command)
            data.append(10)
            guard let input else { throw CocoaError(.fileWriteUnknown) }
            try input.write(contentsOf: data)
        } catch {
            clearEngineState()
            process?.terminate()
            report("The setup engine is unavailable. Close and reopen the installer.", error: true)
        }
    }

    func login() {
        guard ready, !busy, !signedIn, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else { return }
        let secret = password
        password = ""
        send(["op": "login", "email": email, "password": secret])
    }

    func choose() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.init(filenameExtension: "ipa") ?? .data]
        if picker.runModal() == .OK, let url = picker.url {
            send(["op": "select", "path": url.path])
        }
    }

    func reply(_ value: Any?) {
        guard let prompt else { return }
        self.prompt = nil
        send(["op": "reply", "id": prompt.id, "value": value ?? NSNull()], operation: false)
    }

    func requestClose() -> NSApplication.TerminateReply {
        if closing || process?.isRunning != true { return .terminateNow }
        if !ready {
            closing = true
            password = ""
            process?.terminate()
            return .terminateNow
        }
        if busy {
            let alert = NSAlert()
            alert.messageText = "Cancel setup and close?"
            alert.informativeText = "Installation or preparation may be incomplete. Keep Catter installed if it is already on your iPhone, then reopen setup and retry. Your in-memory Apple session ends with setup."
            alert.addButton(withTitle: "Keep working")
            alert.addButton(withTitle: "Cancel setup and close")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            if let process, process.isRunning {
                guard Darwin.kill(-process.processIdentifier, SIGTERM) == 0 else {
                    report("Could not stop setup. Try closing again.", error: true)
                    return .terminateCancel
                }
            }
            closing = true
            password = ""
            return .terminateNow
        }
        closePending = true
        send(["op": "shutdown"])
        // A dead pipe cannot acknowledge shutdown. Avoid trapping the user in
        // terminateLater; stopping our child also ends its in-memory session.
        if !ready {
            closing = true
            process?.terminate()
            return .terminateNow
        }
        return .terminateLater
    }
}

struct SetupPrompt: Identifiable {
    let id: String
    let kind: String
    let title: String
    let text: String
    let certificates: [[String: String]]
    init(_ message: [String: Any]) {
        id = message["id"] as? String ?? ""
        kind = message["kind"] as? String ?? ""
        title = message["title"] as? String ?? "Continue setup"
        text = message["text"] as? String ?? ""
        certificates = (message["certificates"] as? [[String: Any]] ?? []).map { $0.mapValues { String(describing: $0) } }
    }
}

struct PromptView: View {
    let prompt: SetupPrompt
    @ObservedObject var model: SetupModel
    @State private var code = ""
    @State private var serial = ""
    private var canContinue: Bool {
        if prompt.kind == "code" { return code.count == 6 && code.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
        if prompt.kind == "access" { return !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if prompt.kind == "certificates" { return !serial.isEmpty }
        return true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(prompt.title).font(.title2.weight(.semibold))
            ScrollView {
                Text(prompt.text).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.scrollIndicators(.hidden).frame(maxHeight: 300)
            if (prompt.kind == "code" || prompt.kind == "access") {
                SecureField(prompt.kind == "access" ? "Catter invitation code" : "Apple verification code", text: $code).textFieldStyle(.roundedBorder)
            }
            if prompt.kind == "certificates" {
                Picker("Certificate", selection: $serial) {
                    Text("Choose a certificate").tag("")
                    ForEach(Array(prompt.certificates.enumerated()), id: \.offset) { _, certificate in
                        Text((certificate["machineName"] ?? "Certificate") + " · " + (certificate["serialNumber"] ?? ""))
                            .tag(certificate["serialNumber"] ?? "")
                    }
                }
            }
            HStack {
                Spacer()
                Button(prompt.title.contains("metadata") ? "Keep local method" : "Cancel") { code = ""; model.reply(nil) }.keyboardShortcut(.cancelAction)
                Button((prompt.kind == "code" || prompt.kind == "access") ? "Verify" : prompt.kind == "certificates" ? "Review replacement" : "Continue") {
                    let answer: Any
                    if (prompt.kind == "code" || prompt.kind == "access") { answer = code }
                    else if prompt.kind == "certificates" { answer = serial }
                    else { answer = true }
                    code = ""
                    model.reply(answer)
                }
                .disabled(!canContinue)
                .keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 540)
        .interactiveDismissDisabled()
        .onSubmit { if canContinue && (prompt.kind == "code" || prompt.kind == "access") { model.reply(code); code = "" } }
    }
}

struct SetupButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .frame(width: 172, height: 42)
            .background(Color.white.opacity(configuration.isPressed ? 0.22 : 0.09), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12)))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @State private var showDetails = false
    private let steps = ["Apple Account", "Choose app", "Install & prepare"]

    private var title: String {
        !model.access ? "Welcome to Catter" : ["Your Apple Account", "Choose your iPhone app", "Make your iPhone ready"][model.step]
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label(model.access ? "Access verified" : "Invitation required", systemImage: model.access ? "checkmark.shield.fill" : "lock.shield")
                        .font(.caption.weight(.medium)).foregroundStyle(model.access ? Color.green : Color.secondary)
                    Divider().frame(height: 18)
                    Label(model.signedIn ? model.account : "Not signed in", systemImage: model.signedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if model.signedIn {
                        Button("Sign out") { model.send(["op": "logout"]) }.disabled(model.busy)
                    }
                }.frame(height: 42)
                VStack(alignment: .leading, spacing: 22) {
                    Text(title).font(.system(size: 28, weight: .semibold))
                    page
                    Spacer(minLength: 8)
                    if model.step == 0 && model.access {
                        Text("Your password is sent directly to Apple. Remembering sign-in is optional.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.07)))
                HStack(spacing: 12) {
                    if model.busy { ProgressView().controlSize(.small) }
                    if !model.busy { Image(systemName: model.failed ? "exclamationmark.circle.fill" : "info.circle").foregroundStyle(model.failed ? Color.orange : Color.secondary) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.statusTitle).font(.callout.weight(.semibold))
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(3).help(model.status)
                    }
                    Spacer(minLength: 0)
                    Button { showDetails = true } label: { Image(systemName: "info.circle").font(.title3) }
                        .buttonStyle(.plain).help("Show setup details")
                }.padding(14).frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
                    .background(model.failed ? Color.orange.opacity(0.08) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 12) {
                    Button("Back") { model.step -= 1 }
                        .disabled(!model.access || model.busy || model.step == 0)
                    Spacer(minLength: 0)
                    if !model.ready && model.failed {
                        Button("Restart setup") { model.start() }
                    } else if model.access && model.step < 2 {
                        Button("Already installed") { model.step = 2 }.disabled(model.busy || !model.ready)
                        Button("Continue") { model.step += 1 }
                            .disabled(model.busy || !model.ready || !model.signedIn || model.step == 1 && model.ipa.isEmpty)
                    }
                }.frame(height: 42)
            }.padding(28)
        }
        .buttonStyle(SetupButtonStyle())
        .frame(minWidth: 1000, minHeight: 740)
        .background(Color(white: 0.075)).preferredColorScheme(.dark).tint(.white)
        .sheet(item: $model.prompt) { PromptView(prompt: $0, model: model).buttonStyle(SetupButtonStyle()) }
        .sheet(isPresented: $showDetails) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Setup details").font(.title2.bold())
                ScrollView { Text(model.details).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Copy details") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.details, forType: .string) }
                    Spacer(); Button("Close") { showDetails = false }.keyboardShortcut(.cancelAction)
                }
            }.padding(28).frame(width: 600, height: 400).buttonStyle(SetupButtonStyle())
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let url = Bundle.main.url(forResource: "Catter", withExtension: "png"), let logo = NSImage(contentsOf: url) {
                Image(nsImage: logo).resizable().scaledToFit().frame(width: 70, height: 70).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Catter").font(.largeTitle.weight(.semibold))
                Text("iPhone setup").foregroundStyle(.secondary)
            }
            Divider()
            ForEach(0..<3) { index in
                HStack(spacing: 10) {
                    Image(systemName: index == 0 && model.signedIn || index == 1 && !model.ipa.isEmpty ? "checkmark.circle.fill" : "\(index + 1).circle")
                    Text(steps[index]).font(.system(size: 13, weight: .medium))
                }.foregroundStyle(model.access && model.step == index ? Color.white : Color.gray)
                    .padding(.vertical, 12).padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(model.access && model.step == index ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            }
            Spacer()
            Text("Connect by USB and keep your iPhone unlocked.").font(.caption).foregroundStyle(.secondary)
            Button(model.updateVersion.isEmpty ? "Check for updates" : "Update available") {
                if model.updateVersion.isEmpty { model.send(["op": "updates"], operation: false) }
                else { NSWorkspace.shared.open(URL(string: "https://github.com/diwasupadhyay/catter/releases/latest")!) }
            }.disabled(!model.ready || model.busy).help(model.updateMessage)
            Text("Version " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ")")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Installer files") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
        }.padding(24).frame(width: 180).frame(maxHeight: .infinity).background(Color(white: 0.055))
    }

    @ViewBuilder private var page: some View {
        if !model.access {
            Text("A few guided steps to install and prepare Catter.").foregroundStyle(.secondary)
            Label("Connect one iPhone by USB", systemImage: "cable.connector")
            Label("Unlock it and accept Trust if asked", systemImage: "lock.open")
            Text("Your invitation is assigned to this iPhone when verified.").font(.callout).foregroundStyle(.secondary)
            Button("Enter invitation code") { model.send(["op": "activate"]) }.disabled(!model.ready || model.busy)
        } else if model.step == 0 {
            Text("Sign in directly to Apple to sign Catter for your iPhone.").foregroundStyle(.secondary)
            Label("Authentication: " + model.authenticationMethod, systemImage: "desktopcomputer")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Apple Account email", text: $model.email).textFieldStyle(.roundedBorder)
                .disabled(model.signedIn || model.busy)
            SecureField("Password", text: $model.password).textFieldStyle(.roundedBorder)
                .disabled(model.signedIn || model.busy).onSubmit { model.login() }
            Button(model.signedIn ? "Signed in" : "Sign in to Apple") { model.login() }
                .disabled(!model.ready || model.busy || model.signedIn || model.email.isEmpty || model.password.isEmpty)
            Text("Uses this Mac's local authentication first. If it fails, setup can offer a remote provider with your permission.")
                .font(.caption).foregroundStyle(.secondary)
        } else if model.step == 1 {
            Image(systemName: "app.badge").font(.system(size: 38)).foregroundStyle(.secondary)
            Text(model.ipaName).font(.title3.weight(.medium))
            Text(model.ipa.isEmpty ? "Select the Catter IPA you downloaded." : URL(fileURLWithPath: model.ipa).lastPathComponent)
                .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            Button("Choose IPA") { model.choose() }.disabled(!model.ready || model.busy)
        } else {
            Text("Keep your iPhone connected. Setup will explain each step and any prompts to accept.").foregroundStyle(.secondary)
            Button("Install on iPhone") { model.send(["op": "install"]) }
                .disabled(!model.ready || model.busy || !model.signedIn || model.ipa.isEmpty)
            Divider()
            Text("Already installed or restarted for Developer Mode?").font(.headline)
            Button("Continue preparation") { model.send(["op": "prepare"]) }.disabled(!model.ready || model.busy)
            Text("After enabling Developer Mode, unlock your iPhone and continue here. You do not need to reinstall.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: SetupModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.requestClose() ?? .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Route the red close button through the same busy guard and account
        // cleanup as Quit, rather than hiding the only window during an install.
        NSApplication.shared.terminate(nil)
        return false
    }
}

@main
struct CatterSetupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = SetupModel()
    init() {
        if CommandLine.arguments.contains("--backend-smoke") {
            // Exercise Foundation Process, not Python subprocess: their process
            // group setup differs on macOS. Never touch a real user's session.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let root = Bundle.main.resourceURL!.appendingPathComponent("backend")
                let child = Process()
                child.executableURL = root.appendingPathComponent("runtime/bin/python3")
                child.arguments = ["-B", "-E", "-X", "utf8", root.appendingPathComponent("backend.py").path]
                child.currentDirectoryURL = root
                var env = ProcessInfo.processInfo.environment
                env["LOCALAPPDATA"] = folder.path
                child.environment = env
                let input = Pipe(), output = Pipe(), errors = Pipe()
                child.standardInput = input; child.standardOutput = output; child.standardError = errors
                try child.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 40) {
                    if child.isRunning { child.terminate() }
                }
                try input.fileHandleForWriting.write(contentsOf: Data("{\"op\":\"shutdown\"}\n".utf8))
                try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                let messages = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
                guard child.terminationStatus == 0,
                      messages.first?["type"] as? String == "state",
                      messages.last?["type"] as? String == "bye" else {
                    fputs("Native backend launch failed: \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))", stderr)
                    exit(1)
                }
                try FileManager.default.removeItem(at: folder)
                print("Native Process backend startup and shutdown passed.")
                exit(0)
            } catch { fputs("Native backend smoke test failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--smoke") {
            _ = NSApplication.shared
            let model = SetupModel()
            model.checkCrashRecovery()
            model.checkStatusPresentation()
            model.ready = true
            model.access = true
            let host = NSHostingView(rootView: SetupView(model: model))
            for width in [1000, 1100, 1200] {
                for page in 0..<3 {
                    model.step = page
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 720)
                    host.layoutSubtreeIfNeeded()
                    guard host.fittingSize.width > 0, host.fittingSize.height > 0 else { exit(1) }
                }
            }
            print("Native SwiftUI views loaded for every setup page.")
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("Catter Setup") {
            SetupView(model: model)
                .task {
                    guard delegate.model == nil else { return }
                    delegate.model = model
                    model.finishClosing = { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
                    NSApplication.shared.windows.first?.delegate = delegate
                    model.start()
                }
        }.defaultSize(width: 1000, height: 740)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
