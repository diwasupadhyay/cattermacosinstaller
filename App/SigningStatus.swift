import Foundation

// Informational metadata only: never an entitlement or proof of renewal.
enum SigningStatus {
    static func expiration(in profile: Data) -> Date? {
        guard profile.count <= 4 * 1024 * 1024,
              let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }
    static var expiration: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return expiration(in: data)
    }
    static func renewalDue(expiration: Date, now: Date = Date()) -> Bool {
        let remaining = expiration.timeIntervalSince(now)
        return remaining > 0 && remaining <= 2 * 86400
    }
}
