import Foundation

func requireRejected(_ lat: String, _ lon: String) {
    do {
        _ = try Coordinate(latitude: lat, longitude: lon)
        fatalError("Accepted invalid coordinate: \(lat), \(lon)")
    } catch { }
}

for pair in [("nan", "0"), ("inf", "0"), ("0", "-inf"), ("90.01", "0"),
             ("-90.01", "0"), ("0", "180.01"), ("0", "-180.01"), ("", "0"), ("27,7", "85")] {
    requireRejected(pair.0, pair.1)
}
for pair in [("90", "180"), ("-90", "-180"), ("0", "0"), (" 27.7172 ", "85.3240")] {
    _ = try Coordinate(latitude: pair.0, longitude: pair.1)
}
print("Coordinate boundary, nonfinite and input-format checks passed.")

let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: fixture) }
try Data("abc".utf8).write(to: fixture)
let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
precondition(AssetIntegrity.valid(fixture, size: 3, sha256: digest))
precondition(!AssetIntegrity.valid(fixture, size: 4, sha256: digest))
try Data("abd".utf8).write(to: fixture)
precondition(!AssetIntegrity.valid(fixture, size: 3, sha256: digest))
try FileManager.default.removeItem(at: fixture)
precondition(!AssetIntegrity.valid(fixture, size: 3, sha256: digest))
for (major, minor, expected) in [(18, 0, false), (26, 3, false), (26, 4, true), (27, 0, true)] {
    precondition(DeveloperImagePolicy.usesCryptex(.init(majorVersion: major, minorVersion: minor, patchVersion: 0)) == expected)
}
print("Asset corruption, size, missing-file and OS preparation policy checks passed.")

let motion = RandomMotion(minimum: 5, maximum: 10, interval: 60)
for latitude in [-90.0, -45, 0, 45, 90] {
    for longitude in [-180.0, 0, 180] {
        let anchor = try Coordinate(latitude: latitude, longitude: longitude)
        for bearing in stride(from: 0.0, to: 2 * Double.pi, by: 0.1) {
            let result = motion.destination(from: anchor, distance: 10, bearing: bearing)
            let lat1 = latitude * .pi / 180, lat2 = result.latitude * .pi / 180
            let deltaLat = lat2 - lat1, deltaLon = (result.longitude - longitude) * .pi / 180
            let haversine = pow(sin(deltaLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(deltaLon / 2), 2)
            let metres = 6_371_000 * 2 * asin(sqrt(min(1, max(0, haversine))))
            precondition(abs(metres - 10) < 0.05, "Motion must stay within anchor radius, including poles and date line")
        }
    }
}
let invalidMotion = RandomMotion(minimum: .nan, maximum: .infinity, interval: -1)
precondition(invalidMotion.minimum == 5 && invalidMotion.maximum == 10 && invalidMotion.interval == 15)
print("Random-motion bounds, poles, date-line and invalid configuration checks passed.")
