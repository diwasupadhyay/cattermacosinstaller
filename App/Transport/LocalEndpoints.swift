import Foundation
import Darwin

enum LocalEndpoints {
    // Enumerate only addresses assigned to this phone. Never scan a subnet,
    // guess another device's address, or send pairing keys to remote hosts.
    static func candidates() -> [String] {
        var result = ["10.7.0.1"]
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return result }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            // Cellular addresses may hairpin through the carrier. Exclude them.
            guard name.hasPrefix("en") || name.hasPrefix("utun") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                           socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let host = String(cString: buffer)
                if !result.contains(host) { result.append(host) }
            }
        }
        return Array(result.prefix(8))
    }
}
