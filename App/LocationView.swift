import SwiftUI
import MapKit

extension Coordinate {
    var mapCoordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

@MainActor
struct LocationView: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var monitor: BackgroundLocationMonitor
    @ObservedObject var library: PlaceLibrary
    @Binding var selectedPlace: SavedPlace?
    var openPlaces: () -> Void
    var openSettings: () -> Void
    @State private var savePlace = false
    @State private var placeName = ""
    @State private var selectedName = "Pinned location"
    @State private var camera: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var activeSearch: MKLocalSearch?
    @State private var searchGeneration = 0
    @State private var searchError: String?
    @State private var coordinates = false
    @State private var pendingLocation: Coordinate?
    @State private var confirmChange = false
    @State private var confirmRestore = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionCard
                    if let failure = model.failure {
                        DisclosureGroup {
                            Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        } label: {
                            Label("Operation failed - view details", systemImage: "exclamationmark.triangle")
                                .font(.subheadline).foregroundStyle(.red)
                        }
                    }
                    HStack {
                        Text("Choose a location").font(.headline)
                        Spacer()
                        Button { searchFocused = false; openPlaces() } label: {
                            Label("Your places", systemImage: "bookmark")
                        }.font(.subheadline).padding(.vertical, 8)
                    }
                    searchField
                    if let searchError { Text(searchError).foregroundStyle(.red).font(.caption) }
                    if !results.isEmpty { searchResults }
                    map
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.selected == nil ? "Choose a place" : "Selected location").font(.subheadline.weight(.semibold))
                            if let selected = model.selected {
                                Text(String(format: "%.5f, %.5f", selected.latitude, selected.longitude))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                            } else {
                                Text("Search above or tap the map.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        Button { searchFocused = false; coordinates = true } label: {
                            Label("Coordinates", systemImage: "number")
                                .font(.subheadline).padding(.vertical, 12)
                        }.accessibilityLabel("Enter coordinates")
                    }
                    if let selected = model.selected {
                        Button {
                            placeName = selectedName; savePlace = true
                        } label: {
                            Label(library.contains(selected) ? "Place saved" : "Save this place", systemImage: library.contains(selected) ? "bookmark.fill" : "bookmark")
                        }.disabled(library.contains(selected))
                    }
                    if let error = library.error { Text(error).font(.caption).foregroundStyle(.red) }
                    if model.unresolved && model.canConfirmRestored {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Check your real location in Maps before confirming.").font(.caption).foregroundStyle(.secondary)
                            Button("Real location verified") { model.confirmRestored() }.font(.subheadline)
                        }
                    }
                }.padding(20)
            }
            .background(CatterTheme.background)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { CatterWordmark() }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { searchFocused = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { searchFocused = false; openSettings() } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Settings and setup")
                }
            }
            .alert("Save place", isPresented: $savePlace) {
                TextField("Place name", text: $placeName)
                Button("Save") { if let coordinate = model.selected { library.save(coordinate, name: placeName) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Give this location a name you will recognize.") }
            .sheet(isPresented: $coordinates) {
                CoordinateEntryView(latitude: model.latitude, longitude: model.longitude) { coordinate in
                    choose(coordinate.mapCoordinate)
                }.presentationDetents([.medium, .large])
            }
            .confirmationDialog("Change this iPhone's location?", isPresented: $confirmChange, titleVisibility: .visible) {
                Button("Set location") {
                    guard let coordinate = pendingLocation else { return }
                    model.select(coordinate)
                    let name = selectedName
                    Task {
                        model.locationSent = { sent in library.record(sent, name: name) }
                        await model.start()
                        model.locationSent = nil
                    }
                    pendingLocation = nil
                }
                Button("Cancel", role: .cancel) { pendingLocation = nil }
            } message: {
                if let coordinate = pendingLocation {
                    Text(String(format: "Send %.5f, %.5f to iOS? This can affect Maps, Find My and other apps. Restore when you are finished.", coordinate.latitude, coordinate.longitude))
                }
            }
            .confirmationDialog("Restore your real location?", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Stop simulation and restore", role: .destructive) {
                    Task { await model.restore() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Catter will stop sending the selected location and ask iOS to resume normal location. Other apps may take time to refresh their location and address.")
            }
            .onChange(of: query) { _, _ in
                results = []
                searchError = nil
                cancelSearch()
            }
            .onChange(of: selectedPlace?.id) { _, _ in applyLibrarySelection() }
            .onAppear { applyLibrarySelection() }
            .onDisappear { cancelSearch(); searchFocused = false }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search for a place", text: $query)
                .focused($searchFocused).submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { Task { await search() } }
            if searching {
                ProgressView().accessibilityLabel("Searching")
            } else if !query.isEmpty {
                Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }.padding(16).background(CatterTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var searchResults: some View {
        VStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.offset) { index, item in
                Button {
                    cancelSearch()
                    choose(item.placemark.coordinate, name: item.name ?? "Pinned location")
                    results = []
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle").font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name ?? "Place").font(.subheadline.weight(.semibold))
                            Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                if index < results.count - 1 { Divider().padding(.leading, 46) }
            }
        }.background(CatterTheme.surface, in: RoundedRectangle(cornerRadius: CatterTheme.cornerRadius))
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                searchFocused = false
                pendingLocation = model.selected
                confirmChange = pendingLocation != nil
            } label: {
                Label(model.busy && !model.refreshing ? "Working..." : "Set location", systemImage: "location.fill")
            }.buttonStyle(CatterPrimaryButton()).disabled(model.busy || model.selected == nil)
            Button {
                searchFocused = false
                confirmRestore = true
            } label: {
                Text(model.restoring ? "Restoring..." : "Restore real location")
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(model.restoring || (model.busy && !model.refreshing) || !model.pairingAvailable)
        }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
            .background(.ultraThinMaterial)
    }

    private var connectionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.failure != nil || model.sessionNeedsCheck ? "exclamationmark.circle" : model.connected ? "checkmark.circle" : "circle.dotted")
                .foregroundStyle(model.failure != nil || model.sessionNeedsCheck ? Color.orange : CatterTheme.accent)
                .font(.title3).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.statusTitle).font(.subheadline.weight(.semibold)).accessibilityIdentifier("sessionStatus")
                Text(model.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let date = model.lastCommandAt {
                    Text("Last command " + date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if model.busy && !model.refreshing { ProgressView() }
            if model.pairingAvailable && model.failure != nil && !model.busy {
                Button("Reconnect") { Task { await model.connect() } }.font(.subheadline)
            }
            if !model.pairingAvailable {
                Button(model.pairingAvailable ? "Help" : "Set up") { openSettings() }.font(.subheadline)
            }
        }.padding(16).background(CatterTheme.surface, in: RoundedRectangle(cornerRadius: CatterTheme.cornerRadius))
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let selected = model.selected { Marker("Selected", coordinate: selected.mapCoordinate).tint(CatterTheme.accent) }
                if let sent = model.lastSent, sent != model.selected {
                    Marker("Last sent", systemImage: "paperplane.fill", coordinate: sent.mapCoordinate).tint(.orange)
                }
            }
            .mapStyle(.standard)
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) { choose(coordinate, recenter: false) }
            }
        }.frame(height: 320).clipShape(RoundedRectangle(cornerRadius: CatterTheme.cornerRadius))
    }

    private func choose(_ location: CLLocationCoordinate2D, recenter: Bool = true, name: String = "Pinned location") {
        guard let coordinate = try? Coordinate(latitude: location.latitude, longitude: location.longitude) else { return }
        cancelSearch()
        results = []
        searchError = nil
        searchFocused = false
        model.select(coordinate)
        selectedName = name
        if recenter { camera = .region(.init(center: location, span: .init(latitudeDelta: 0.025, longitudeDelta: 0.025))) }
    }

    private func applyLibrarySelection() {
        guard let place = selectedPlace, let coordinate = place.coordinate else { return }
        choose(coordinate.mapCoordinate, name: place.name)
        selectedPlace = nil
    }

    private func cancelSearch() {
        searchGeneration += 1
        activeSearch?.cancel()
        activeSearch = nil
        searching = false
    }

    private func search() async {
        cancelSearch()
        let generation = searchGeneration
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchFocused = false
        searching = true
        searchError = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        let operation = MKLocalSearch(request: request)
        activeSearch = operation
        defer {
            if generation == searchGeneration { searching = false; activeSearch = nil }
        }
        do {
            let response = try await operation.start()
            guard generation == searchGeneration else { return }
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            results = Array(response.mapItems.prefix(6))
            if results.isEmpty { searchError = "No places found. Try a fuller address or enter coordinates." }
        } catch {
            guard generation == searchGeneration else { return }
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            results = []
            searchError = "Search is unavailable. Try again or enter coordinates."
        }
    }
}
