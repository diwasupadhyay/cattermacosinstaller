import Foundation

enum RenewalStage: String {
    case preparation = "checking renewal preparation"
    case access = "checking invitation access"
    case metadata = "preparing authentication metadata"
    case authentication = "signing in to Apple"
    case account = "checking the Apple developer account"
    case profile = "requesting the signing profile"
    case signing = "signing the app on this iPhone"
    case installation = "installing the renewed app"

    func failure(appleCode: Int? = nil, networkCode: Int? = nil) -> String {
        var text = "Renewal stopped while \(rawValue)."
        if let appleCode { text += " Apple error \(appleCode)." }
        if let networkCode { text += " Network error \(networkCode)." }
        if appleCode == -80045 || appleCode == -80046 {
            text += " Apple rejected this authentication method. Reconnecting LocalDevVPN will not fix this rejection."
        } else if self == .installation {
            text += " Keep Wi-Fi and LocalDevVPN connected and unlock the iPhone. Reopen Catter to check whether installation completed before retrying."
        } else {
            text += " The app installation step was not reached."
        }
        return text + " Keep Catter installed."
    }
}
