import Foundation

@main struct RenewalDiagnosticChecks {
    static func main() {
        let auth = RenewalStage.authentication.failure(appleCode: -80046)
        precondition(auth.contains("Apple error -80046"))
        precondition(auth.contains("will not fix"))
        let metadata = RenewalStage.metadata.failure(networkCode: -1001)
        precondition(metadata.contains("installation step was not reached"))
        precondition(!metadata.contains("Keep Wi-Fi"))
        let install = RenewalStage.installation.failure()
        precondition(install.contains("check whether installation completed"))
        precondition(!install.contains("installation step was not reached"))
        print("Renewal failure stages and recovery guidance passed.")
    }
}
