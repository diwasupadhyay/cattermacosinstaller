import Foundation
import Combine

struct SavedRoute: Codable, Identifiable {
    struct Point: Codable {
        let latitude: Double
        let longitude: Double
        var coordinate: Coordinate? { try? Coordinate(latitude: latitude, longitude: longitude) }
    }
    let id: UUID
    var name: String
    let points: [Point]
    let repeats: Bool
    let speed: Double
    var coordinates: [Coordinate] { points.compactMap(\.coordinate) }
    var valid: Bool {
        (2...64).contains(points.count) && coordinates.count == points.count &&
        speed.isFinite && (0.5...35).contains(speed) && !name.isEmpty && name.count <= 80
    }
}

/// Explicitly saved paths only. Stored locally, protected when locked, excluded from backup.
@MainActor final class RouteLibrary: ObservableObject {
    @Published private(set) var saved: [SavedRoute] = []
    @Published private(set) var error: String?
    private let file: URL?
    private var loadFailed = false
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("routes.json")
        guard let file = self.file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 512_000 else { throw AppError.message("Too large") }
            let data = try Data(contentsOf: file)
            guard data.count <= 512_000 else { throw AppError.message("Too large") }
            let routes = try JSONDecoder().decode([SavedRoute].self, from: data)
            guard routes.count <= 50, routes.allSatisfy(\.valid), Set(routes.map(\.id)).count == routes.count else { throw AppError.message("Invalid route archive") }
            saved = routes
        } catch {
            loadFailed = true
            self.error = "Routes could not be loaded. Unlock and reopen Catter. Your existing file has been kept."
        }
    }
    func save(_ points: [Coordinate], name: String, repeats: Bool, speed: Double) {
        guard saved.count < 50 else { error = "Remove a route before saving another (50 maximum)."; return }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let route = SavedRoute(id: UUID(), name: name.isEmpty ? "Saved route" : name,
                              points: points.map { .init(latitude: $0.latitude, longitude: $0.longitude) }, repeats: repeats, speed: speed)
        guard route.valid else { error = "A route needs 2-64 valid pins and a speed from 0.5 to 35 m/s."; return }
        persist([route] + saved)
    }
    func rename(_ id: UUID, to name: String) {
        let label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !label.isEmpty, let index = saved.firstIndex(where: { $0.id == id }) else { return }
        var updated = saved; updated[index].name = label; persist(updated)
    }
    func remove(_ id: UUID) { persist(saved.filter { $0.id != id }) }
    private func persist(_ updated: [SavedRoute]) {
        guard !loadFailed else { return }
        do {
            guard var file else { throw AppError.message("Storage unavailable") }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(updated)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try data.write(to: file, options: options)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try file.setResourceValues(values)
            saved = updated; error = nil
        } catch { self.error = "Routes could not be saved. Keep Catter open and try again." }
    }
}
