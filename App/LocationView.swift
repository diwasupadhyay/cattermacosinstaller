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
    @State private var showDetails = false
    @Environment(\.dynamicTypeSize) private var typeSize
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
    @Environment(\.openURL) private var openURL
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                map
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 10) {
                            searchField
                            TimelineView(.periodic(from: .now, by: 1)) { _ in compactStatus }
                            if let searchError { Text(searchError).font(.caption).foregroundStyle(.red).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                            if !results.isEmpty {
                                ScrollView { searchResults }
                                    .frame(maxHeight: geometry.size.height * 0.3)
                            }
                        }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            Capsule().fill(.secondary.opacity(0.35)).frame(width: 36, height: 4).padding(.top, 10)
                                .accessibilityHidden(true)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    if model.awaitingRestoreReading || model.realLocationReceived || model.canConfirmRestored {
                                        restoreCard
                                    } else {
                                        selectionCard
                                    }
                                    if let error = library.error { Text(error).font(.caption).foregroundStyle(.red) }
                                }.padding(.horizontal, 16).padding(.top, 10)
                            }.frame(maxHeight: typeSize.isAccessibilitySize ? geometry.size.height * 0.4 : 180)
                                .scrollDismissesKeyboard(.interactively)
                            actions
                        }
                        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                    }
            }
            .background(CatterTheme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { CatterWordmark() }
                ToolbarItem(placement: .topBarLeading) {
                    Button { searchFocused = false; openPlaces() } label: { Image(systemName: "bookmark") }
                        .accessibilityLabel("Saved and recent places")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { searchFocused = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { searchFocused = false; openSettings() } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Settings and setup")
                }
            }
            .sheet(isPresented: $showDetails) {
                NavigationStack {
                    List {
                        Section("Location session") {
                            Text(model.statusTitle).font(.headline)
                            Text(model.status)
                            if let sent = model.lastSent {
                                LabeledContent("Last sent", value: String(format: "%.5f, %.5f", sent.latitude, sent.longitude))
                            }
                            if let date = model.lastCommandAt { LabeledContent("Last command", value: date.formatted(date: .omitted, time: .standard)) }
                        }
                        Section("Background updates") {
                            Text(monitor.message)
                            Text("Keep LocalDevVPN connected. iOS can pause background execution; a successful command confirms the connection at that time.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let failure = model.failure {
                            Section("Technical details") { Text(failure).font(.caption).textSelection(.enabled) }
                        }
                        Section {
                            if model.failure != nil && model.pairingAvailable {
                                Button("Reconnect") { Task { await model.connect() } }.disabled(model.busy)
                            }
                            Button("Connection settings") { showDetails = false; openSettings() }
                        }
                    }
                    .navigationTitle("Session details").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDetails = false } } }
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

    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Selected destination", systemImage: "mappin.and.ellipse")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let selected = model.selected {
                Text(selectedName).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(String(format: "%.5f, %.5f", selected.latitude, selected.longitude))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                if let sent = model.lastSent, sent != selected {
                    Label("Selection has not been applied", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { selectionTools(selected) }
                    VStack(alignment: .leading, spacing: 8) { selectionTools(selected) }
                }
            } else {
                Text("Search for a place or tap the map.").font(.subheadline).foregroundStyle(.secondary)
                Button("Enter coordinates", systemImage: "number") { searchFocused = false; coordinates = true }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(CatterTheme.surface, in: RoundedRectangle(cornerRadius: CatterTheme.cornerRadius))
    }

    @ViewBuilder private func selectionTools(_ selected: Coordinate) -> some View {
        Button("Coordinates", systemImage: "number") { searchFocused = false; coordinates = true }
            .buttonStyle(.bordered).controlSize(.large)
        Button(library.contains(selected) ? "Saved" : "Save place", systemImage: "bookmark") {
            searchFocused = false; placeName = selectedName; savePlace = true
        }.buttonStyle(.bordered).controlSize(.large).disabled(library.contains(selected))
    }

    private var restoreCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(model.realLocationReceived ? "Fresh location received" : "Check your real location",
                  systemImage: model.realLocationReceived ? "checkmark.circle.fill" : "location.circle")
                .font(.headline)
            Text(model.awaitingRestoreReading
                 ? "Simulation has stopped. Waiting for iOS to report a fresh location."
                 : "Check your position in Maps. Find My and address labels may update later.")
                .font(.subheadline).foregroundStyle(.secondary)
            if model.realLocationReceived, let accuracy = monitor.restoredAccuracy {
                Text("Reported accuracy: about \(Int(accuracy.rounded())) m")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { restoreTools }
                VStack(alignment: .leading, spacing: 8) { restoreTools }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(CatterTheme.surface, in: RoundedRectangle(cornerRadius: CatterTheme.cornerRadius))
    }

    @ViewBuilder private var restoreTools: some View {
        Button("Open Maps", systemImage: "map") { openURL(URL(string: "maps://")!) }
            .buttonStyle(.bordered).controlSize(.large)
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
                Task { await model.restore() }
            } label: {
                Label(model.restoring ? "Stopping simulation..." : "Restore real location", systemImage: "location.slash")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                    .background(CatterTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(model.restoring || (model.busy && !model.refreshing) || !model.pairingAvailable)
        }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
            .background(.ultraThinMaterial)
    }

    private var compactStatus: some View {
        Button { searchFocused = false; showDetails = true } label: {
            HStack(spacing: 10) {
                Image(systemName: statusSymbol).foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.statusTitle).font(.subheadline.weight(.semibold))
                    Text(model.refreshing ? (model.backgroundUpdatesAllowed ? "Background monitoring on" : "Background monitoring off") : "Tap for session details")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if model.restoring || model.awaitingRestoreReading || (model.busy && !model.refreshing) { ProgressView() }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityHint("Show connection status and troubleshooting details")
    }

    private var statusSymbol: String {
        if model.failure != nil || model.sessionNeedsCheck { return "exclamationmark.circle.fill" }
        if model.realLocationReceived { return "checkmark.circle.fill" }
        if model.refreshing { return model.refreshIsRecent ? "location.fill" : "clock" }
        return "location.circle"
    }

    private var statusColor: Color {
        if model.failure != nil || model.sessionNeedsCheck { return .orange }
        if model.realLocationReceived || (model.refreshing && model.refreshIsRecent) { return .green }
        return CatterTheme.accent
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
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choose(_ location: CLLocationCoordinate2D, recenter: Bool = true, name: String = "Pinned location") {
        guard let coordinate = try? Coordinate(latitude: location.latitude, longitude: location.longitude) else { return }
        cancelSearch()
        results = []
        searchError = nil
        searchFocused = false
        model.select(coordinate)
        model.dismissRestoreResult()
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
