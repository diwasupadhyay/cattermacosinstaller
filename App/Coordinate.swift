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

/// All offsets are relative to the selected anchor, never a cumulative random walk.
struct RandomMotion {
    let minimum: Double
    let maximum: Double
    let interval: Double

    init(minimum: Double, maximum: Double, interval: Double) {
        self.minimum = minimum.isFinite ? min(max(minimum, 0), 100) : 5
        self.maximum = maximum.isFinite ? min(max(maximum, self.minimum), 100) : max(10, self.minimum)
        self.interval = interval.isFinite ? min(max(interval, 15), 3600) : 60
    }

    func destination(from anchor: Coordinate, distance: Double, bearing: Double) -> Coordinate {
        let angular = min(max(distance, minimum), maximum) / 6_371_000
        let latitude = anchor.latitude * .pi / 180
        let longitude = anchor.longitude * .pi / 180
        let newLatitude = asin(min(1, max(-1, sin(latitude) * cos(angular) + cos(latitude) * sin(angular) * cos(bearing))))
        let newLongitude = longitude + atan2(sin(bearing) * sin(angular) * cos(latitude), cos(angular) - sin(latitude) * sin(newLatitude))
        let degrees = newLongitude * 180 / .pi
        let wrapped = (degrees + 540).truncatingRemainder(dividingBy: 360) - 180
        return (try? Coordinate(latitude: newLatitude * 180 / .pi, longitude: wrapped)) ?? anchor
    }

    func next(from anchor: Coordinate) -> Coordinate {
        destination(from: anchor, distance: Double.random(in: minimum...maximum), bearing: Double.random(in: 0..<(2 * .pi)))
    }
}
