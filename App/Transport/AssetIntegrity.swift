import Foundation
import CryptoKit

enum AssetIntegrity {
    static func valid(_ file: URL, size expectedSize: Int, sha256: String) -> Bool {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == expectedSize, let stream = InputStream(url: file) else { return false }
        stream.open()
        defer { stream.close() }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return false }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }

}

enum DeveloperImagePolicy {
    static func usesCryptex(_ version: OperatingSystemVersion) -> Bool {
        version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4)
    }
}
