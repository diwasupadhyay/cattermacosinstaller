import SwiftUI
import MapKit

/// A separate draft keeps cancel safe and leaves the entire map available for pin placement.
struct RouteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var points: [Coordinate]
    @State private var repeats: Bool
    @State private var camera: MapCameraPosition
    @State private var center: CLLocationCoordinate2D?
    @State private var clear = false
    @State private var discard = false
    private let original: [Coordinate]
    private let originalRepeats: Bool
    let onDone: ([Coordinate], Bool) -> Void

    init(points: [Coordinate], repeats: Bool, anchor: Coordinate?, onDone: @escaping ([Coordinate], Bool) -> Void) {
        _points = State(initialValue: points); _repeats = State(initialValue: repeats)
        original = points; originalRepeats = repeats; self.onDone = onDone
        let start = points.last ?? anchor
        _center = State(initialValue: start?.mapCoordinate)
        _camera = State(initialValue: start.map { .region(.init(center: $0.mapCoordinate, span: .init(latitudeDelta: 0.003, longitudeDelta: 0.003))) } ?? .automatic)
    }
    var body: some View {
        NavigationStack {
            Map(position: $camera) {
                if points.count > 1 {
                    MapPolyline(coordinates: (repeats ? points + [points[0]] : points).map(\.mapCoordinate))
                        .stroke(.blue, lineWidth: 4)
                }
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Annotation("Pin \(index + 1)", coordinate: point.mapCoordinate) {
                        Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(.blue, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange { center = $0.region.center }
            .overlay {
                Image(systemName: "plus").font(.title.weight(.light)).foregroundStyle(.primary)
                    .padding(8).background(.regularMaterial, in: Circle())
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    HStack {
                        Text("\(points.count)/64 pins").font(.caption.monospacedDigit())
                        Spacer()
                        Toggle("Loop", isOn: $repeats).fixedSize().font(.subheadline)
                    }
                    Text("Move the map under the crosshair, then add a pin.").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button { if !points.isEmpty { points.removeLast() } } label: {
                            Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                        }.buttonStyle(.bordered).disabled(points.isEmpty).accessibilityLabel("Undo last pin")
                        Button {
                            guard points.count < 64, let center,
                                  let point = try? Coordinate(latitude: center.latitude, longitude: center.longitude) else { return }
                            points.append(point)
                        } label: {
                            Label("Add pin here", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).disabled(center == nil || points.count >= 64)
                    }
                }.padding(16).background(.regularMaterial)
            }
            .navigationTitle("Edit route").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if points != original || repeats != originalRepeats { discard = true } else { dismiss() }
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button { clear = true } label: { Image(systemName: "trash") }
                        .disabled(points.isEmpty).accessibilityLabel("Clear all pins")
                    Button("Done") { onDone(points, repeats); dismiss() }.fontWeight(.semibold)
                }
            }
            .confirmationDialog("Clear all pins?", isPresented: $clear, titleVisibility: .visible) {
                Button("Clear pins", role: .destructive) { points = [] }
            }
            .confirmationDialog("Discard route changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
            }
        }.interactiveDismissDisabled()
    }
}
