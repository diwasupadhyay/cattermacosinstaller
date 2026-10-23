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
