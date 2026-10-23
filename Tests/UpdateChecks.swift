import Foundation
@main struct UpdateChecks {
    @MainActor static func main() throws {
        precondition(UpdateManager.newer("0.10.0", than: "0.9.0"))
        precondition(!UpdateManager.newer("0.8.1", than: "0.9.0"))
        precondition(!UpdateManager.newer("0.9.0", than: "0.9.0"))
        precondition(!UpdateManager.newer("invalid", than: "0.9.0"))
        precondition(!UpdateManager.newer("0..9", than: "0.9.0"))
        let expiry = Date(timeIntervalSince1970: 1800000000)
        let xml = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": expiry], format: .xml, options: 0)
        let profile = Data([0x30, 0x82, 0xff]) + xml + Data([0xff])
        precondition(SigningStatus.expiration(in: profile) == expiry)
        precondition(SigningStatus.expiration(in: Data("invalid".utf8)) == nil)
        precondition(SigningStatus.renewalDue(expiration: expiry, now: expiry.addingTimeInterval(-86400)))
        precondition(SigningStatus.renewalDue(expiration: expiry, now: expiry.addingTimeInterval(-2 * 86400)))
        precondition(!SigningStatus.renewalDue(expiration: expiry, now: expiry.addingTimeInterval(-2 * 86400 - 1)))
        precondition(!SigningStatus.renewalDue(expiration: expiry, now: expiry))
        precondition(!SigningStatus.renewalDue(expiration: expiry, now: expiry.addingTimeInterval(1)))
        precondition(!SigningStatus.renewalDue(expiration: expiry, now: expiry.addingTimeInterval(-6 * 86400)))
        print("Version comparisons, profile expiry and renewal window passed.")
    }
}
