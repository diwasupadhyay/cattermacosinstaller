import Foundation
import Combine

struct SavedPlace: Identifiable, Codable {
    var id: UUID
    var name: String
    let latitude: Double
    let longitude: Double
    var coordinate: Coordinate? { try? Coordinate(latitude: latitude, longitude: longitude) }
}

/// User-selected destinations only; never records the phone's observed location.
@MainActor
final class PlaceLibrary: ObservableObject {
    @Published private(set) var saved: [SavedPlace] = []
    @Published private(set) var recent: [SavedPlace] = []
    @Published private(set) var error: String?
    private var loadFailed = false
    private struct Archive: Codable { var saved: [SavedPlace]; var recent: [SavedPlace] }
    private var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("places.json")
    }
    init() {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 256_000 else { throw AppError.message("Place library is too large.") }
            let data = try Data(contentsOf: file)
            guard data.count <= 256_000 else { throw AppError.message("Place library is too large.") }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            saved = Array(archive.saved.filter { $0.coordinate != nil }.prefix(100))
            recent = Array(archive.recent.filter { $0.coordinate != nil }.prefix(20))
        } catch {
            loadFailed = true
            self.error = "Saved places could not be loaded. Unlock the iPhone and reopen Catter. Your existing library has been kept."
        }
    }
    func contains(_ coordinate: Coordinate) -> Bool { saved.contains { matches($0, coordinate) } }
    private func matches(_ place: SavedPlace, _ coordinate: Coordinate) -> Bool {
        abs(place.latitude - coordinate.latitude) < 0.000001 && abs(place.longitude - coordinate.longitude) < 0.000001
    }
    private func place(_ coordinate: Coordinate, name: String) -> SavedPlace {
        let label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return SavedPlace(id: UUID(), name: label.isEmpty ? "Pinned location" : label,
                          latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
    func save(_ coordinate: Coordinate, name: String) {
        guard !contains(coordinate) else { return }
        guard saved.count < 100 else { error = "Remove a saved place before adding another (100 maximum)."; return }
        var updated = saved
        updated.insert(place(coordinate, name: name), at: 0)
        persist(saved: updated, recent: recent)
    }
    func record(_ coordinate: Coordinate, name: String) {
        var updated = recent.filter { !matches($0, coordinate) }
        updated.insert(place(coordinate, name: name), at: 0)
        persist(saved: saved, recent: Array(updated.prefix(20)))
    }
    func remove(_ id: UUID) { persist(saved: saved.filter { $0.id != id }, recent: recent) }
    func rename(_ id: UUID, to name: String) {
        let label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !label.isEmpty, let index = saved.firstIndex(where: { $0.id == id }) else { return }
        var updated = saved
        updated[index].name = label
        persist(saved: updated, recent: recent)
    }
    func clearRecent() { persist(saved: saved, recent: []) }
    private func persist(saved: [SavedPlace], recent: [SavedPlace]) {
        // Never replace an archive that failed to load with an empty library.
        guard !loadFailed else { return }
        do {
            guard var file else { throw AppError.message("Storage unavailable") }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Archive(saved: saved, recent: recent))
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try file.setResourceValues(values)
            self.saved = saved
            self.recent = recent
            error = nil
        } catch { self.error = "Places could not be saved. Keep the app open and try again." }
    }
}
