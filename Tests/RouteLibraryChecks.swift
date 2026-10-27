import Foundation

@main struct RouteLibraryChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("routes.json")
        let a = try Coordinate(latitude: 10, longitude: 20)
        let b = try Coordinate(latitude: 10.001, longitude: 20.001)
        let library = RouteLibrary(file: file)
        library.save([a], name: "Invalid", repeats: false, speed: 1.4)
        precondition(library.saved.isEmpty && library.error != nil)
        library.save([a,b], name: "  Mall  ", repeats: true, speed: 1.4)
        precondition(library.saved.count == 1 && library.error == nil)
        let id = library.saved[0].id
        let loaded = RouteLibrary(file: file)
        precondition(loaded.saved[0].coordinates == [a,b] && loaded.saved[0].repeats)
        precondition(loaded.saved[0].name == "Mall" && loaded.saved[0].speed == 1.4)
        loaded.rename(id, to: "New name")
        precondition(RouteLibrary(file: file).saved[0].name == "New name")
        loaded.remove(id)
        precondition(RouteLibrary(file: file).saved.isEmpty)
        loaded.save([a,b], name: "Bad speed", repeats: false, speed: .infinity)
        precondition(loaded.saved.isEmpty)
        loaded.save(Array(repeating: a, count: 65), name: "Too many", repeats: false, speed: 1.4)
        precondition(loaded.saved.isEmpty)
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: file)
        let broken = RouteLibrary(file: file)
        broken.save([a,b], name: "Must not overwrite", repeats: false, speed: 1.4)
        let unchanged = try Data(contentsOf: file)
        precondition(unchanged == corrupt && broken.saved.isEmpty && broken.error != nil)
        print("Route storage checks passed")
    }
}
