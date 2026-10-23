import Foundation

struct Coordinate: Equatable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw AppError.message("Invalid map coordinate.")
        }
        self.latitude = latitude
        self.longitude = longitude
    }

    init(latitude: String, longitude: String) throws {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              lat.isFinite, lon.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lon) else {
            throw AppError.message("Enter latitude from -90 to 90 and longitude from -180 to 180, using a decimal point.")
        }
        self.latitude = lat
        self.longitude = lon
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
