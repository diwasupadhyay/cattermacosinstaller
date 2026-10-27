import SwiftUI
import MapKit

extension Coordinate {
    var mapCoordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

private enum MovementMode: String, CaseIterable {
    case normal = "Location", route = "Route"
    var action: String {
        switch self { case .normal: return "Set location"; case .route: return "Start route" }
    }
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
    @State private var showMovement = false
    @State private var editingRoute = false
    @State private var randomMovement = false
    @State private var pendingRandom = false
    @StateObject private var routes = RouteLibrary()
    @State private var routeName = "New route"
    @State private var namingRoute = false
    @State private var renameID: UUID?
    @State private var deletingRoute: SavedRoute?
    @State private var clearRoute = false
    @AppStorage("motionMaximum") private var motionRadius = 10.0
    @State private var movementMode: MovementMode = .normal
    @State private var loopRoute = false
    @State private var pendingLoop = false
    @State private var pendingMode: MovementMode = .normal
    @State private var routePins: [Coordinate] = []
    @State private var pendingRoute: [Coordinate] = []
    @State private var movementSpeed = 1.4
    @State private var pendingSpeed = 1.4
    @StateObject private var movementPairing = OnDevicePairing()

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
            map
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 8) {
                        searchField
                        if let searchError { Text(searchError).font(.caption).foregroundStyle(.red).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                        if !results.isEmpty { ScrollView { searchResults }.frame(maxHeight: 220) }
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !searchFocused { actions }
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
            .sheet(isPresented: $showMovement) { movementSheet }
            .fullScreenCover(isPresented: $editingRoute) {
                RouteEditorView(points: routePins, repeats: loopRoute, anchor: model.selected) { points, repeats in
                    routePins = points; loopRoute = repeats
                    camera = .automatic
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
                        if model.awaitingRestoreReading || model.realLocationReceived || model.canConfirmRestored {
                            Section("Restore") { restoreCard }
                        }
                        Section("Destination") {
                            Text(selectedName)
                            if let selected = model.selected { Text(String(format: "%.5f, %.5f", selected.latitude, selected.longitude)).monospacedDigit().textSelection(.enabled) }
                        }
                        if let error = library.error { Section { Text(error).foregroundStyle(.red) } }
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
                                Button("Reconnect") { Task { await model.connect() } }.disabled(model.userActionBusy)
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
                Button(pendingRandom ? "Set & move" : pendingMode.action) {
                    guard let coordinate = pendingLocation else { return }
                    model.select(coordinate)
                    let name = selectedName
                    let route = pendingRoute, speed = pendingSpeed, repeats = pendingLoop, random = pendingRandom
                    Task {
                        model.locationSent = { sent in library.record(sent, name: name) }
                        await model.start(route: route, speed: speed, repeatRoute: repeats, random: random)
                        pendingRoute = []
                        model.locationSent = nil
                    }
                    pendingLocation = nil
                }
                Button("Cancel", role: .cancel) { pendingLocation = nil; pendingRoute = [] }
            } message: {
                if let coordinate = pendingLocation {
                    Text(String(format: "Send %.5f, %.5f to iOS? This can affect Maps, Find My and other apps. Restore when you are finished.", coordinate.latitude, coordinate.longitude))
                }
            }
            .onChange(of: monitor.restoredCoordinate) { _, coordinate in
                guard let coordinate else { return }
                model.select(coordinate)
                selectedName = "Current location"
                withAnimation { camera = .region(.init(center: coordinate.mapCoordinate, span: .init(latitudeDelta: 0.005, longitudeDelta: 0.005))) }
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

    private var movementSheet: some View {
        NavigationStack {
            Form {
                if movementMode == .route {
                    Section("Current route") {
                        LabeledContent("Pins", value: "\(routePins.count) / 64")
                        Toggle("Loop back to the start", isOn: $loopRoute)
                            .disabled(model.movementActive)
                        Button("Save route", systemImage: "bookmark") {
                            renameID = nil; routeName = "New route"; namingRoute = true
                        }.disabled(routePins.count < 2)
                        Button("Clear current route", role: .destructive) { clearRoute = true }
                            .disabled(routePins.isEmpty || model.movementActive)
                    }
                    Section("Speed") {
                        HStack {
                            speedPreset("Walk", speed: 1.4)
                            speedPreset("Run", speed: 3)
                            speedPreset("Car", speed: 13.9)
                        }.buttonStyle(.bordered)
                        Slider(value: $movementSpeed, in: 0.5...35, step: 0.1).accessibilityLabel("Route speed")
                        Text(String(format: "%.1f km/h", movementSpeed * 3.6)).monospacedDigit()
                        Text("Straight lines between pins, not road directions. Changes apply on the next start.").font(.caption).foregroundStyle(.secondary)
                    }.disabled(model.movementActive)
                    Section("Saved routes") {
                        if routes.saved.isEmpty { Text("Save a route to use it again later.").foregroundStyle(.secondary) }
                        ForEach(routes.saved) { route in
                            HStack {
                                Button {
                                    routePins = route.coordinates; loopRoute = route.repeats; movementSpeed = route.speed
                                    showMovement = false; camera = .automatic
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(route.name).font(.headline)
                                        Text("\(route.points.count) pins" + (route.repeats ? " - Loop" : "") + String(format: " - %.1f km/h", route.speed * 3.6))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.disabled(model.movementActive)
                                Menu {
                                    Button("Rename", systemImage: "pencil") { renameID = route.id; routeName = route.name; namingRoute = true }
                                    Button("Delete", systemImage: "trash", role: .destructive) { deletingRoute = route }
                                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                                    .accessibilityLabel("Options for \(route.name)")
                            }
                        }
                        if let error = routes.error { Text(error).foregroundStyle(.red) }
                    }
                } else {
                    Section {
                        NavigationLink("Movement area and timing") {
                            SettingsDetailView(page: .motion, model: model, monitor: monitor, pairing: movementPairing)
                        }
                        Text("Walk around the selected place within your chosen radius. For a mall, choose its center and a radius that fits inside it. Movement does not follow indoor paths or avoid walls; use a route for precise paths.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Movement is optional and starts only when you apply the location with Move nearby enabled. Speed is walking pace.").font(.caption)
                    }
                }
                Section {
                    Text("Keep LocalDevVPN connected. iOS can pause movement when the app is in the background or the phone is locked.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle(movementMode == .route ? "Routes" : "Move nearby")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showMovement = false } } }
            .alert(renameID == nil ? "Save route" : "Rename route", isPresented: $namingRoute) {
                TextField("Route name", text: $routeName)
                Button("Save") {
                    if let id = renameID { routes.rename(id, to: routeName) }
                    else { routes.save(routePins, name: routeName, repeats: loopRoute, speed: movementSpeed) }
                    renameID = nil
                }
                Button("Cancel", role: .cancel) { renameID = nil }
            }
            .confirmationDialog("Delete saved route?", isPresented: Binding(get: { deletingRoute != nil }, set: { if !$0 { deletingRoute = nil } }), titleVisibility: .visible) {
                Button("Delete route", role: .destructive) { if let route = deletingRoute { routes.remove(route.id) }; deletingRoute = nil }
                Button("Cancel", role: .cancel) { deletingRoute = nil }
            }
            .confirmationDialog("Clear the current route?", isPresented: $clearRoute, titleVisibility: .visible) {
                Button("Clear pins", role: .destructive) { routePins = []; loopRoute = false }
            } message: { Text("Saved routes will be kept.") }
        }
    }

    private func speedPreset(_ title: String, speed: Double) -> some View {
        Button { movementSpeed = speed } label: { Text(title).frame(maxWidth: .infinity) }
            .tint(abs(movementSpeed - speed) < 0.05 ? CatterTheme.accent : .secondary)
    }

    private var restoreCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(model.realLocationReceived ? "Real location restored" : model.awaitingRestoreReading ? "Finding your real location" : "Location reading unavailable",
                  systemImage: model.realLocationReceived ? "checkmark.circle.fill" : "location.circle")
                .font(.headline)
            Text(model.awaitingRestoreReading
                 ? "Simulation has stopped. Waiting for iOS to report a fresh location."
                 : model.realLocationReceived ? "The map now shows the fresh real location reported by iOS." : "Simulation is stopped. Allow location access and retry the automatic check.")
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
        if !model.realLocationReceived {
            Button("Retry location check", systemImage: "arrow.clockwise") { model.retryRestoreCheck() }
                .buttonStyle(.bordered).disabled(model.awaitingRestoreReading || model.restoring)
        }
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
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { showDetails = true } label: {
                    Label(model.statusTitle, systemImage: statusSymbol)
                        .font(.caption.weight(.semibold)).foregroundStyle(statusColor).lineLimit(1)
                }.buttonStyle(.plain)
                Spacer(minLength: 0)
                Menu {
                    Button("Enter coordinates", systemImage: "number") { coordinates = true }
                    Button("Save place", systemImage: "bookmark") { placeName = selectedName; savePlace = true }.disabled(model.selected == nil)
                    Button("Session details", systemImage: "info.circle") { showDetails = true }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 32) }.accessibilityLabel("Location options")
            }
            Picker("Location mode", selection: $movementMode) {
                ForEach(MovementMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(model.userActionBusy || model.movementActive)
            if movementMode == .route {
                HStack {
                    Button(routePins.isEmpty ? "Create route" : "Edit \(routePins.count) pins", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        searchFocused = false; editingRoute = true
                    }.disabled(model.userActionBusy || model.movementActive)
                    Spacer()
                    Button("Routes", systemImage: "folder") { showMovement = true }
                }.font(.subheadline).frame(minHeight: 36)
            } else {
                HStack(spacing: 12) {
                    Toggle("Move nearby", isOn: $randomMovement).font(.subheadline)
                        .disabled(model.userActionBusy || model.movementActive)
                    Button { showMovement = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 36) }
                        .accessibilityLabel("Movement radius and timing")
                }
            }
            HStack(spacing: 10) {
                Button {
                    if model.movementActive { model.stopMovement(); return }
                    searchFocused = false; pendingMode = movementMode
                    pendingRoute = movementMode == .route ? routePins : []
                    pendingLoop = loopRoute
                    pendingRandom = movementMode == .normal && randomMovement
                    pendingSpeed = pendingRandom ? 1.4 : movementSpeed
                    pendingLocation = movementMode == .route ? routePins.first : model.selected
                    confirmChange = pendingLocation != nil
                } label: {
                    Label(model.userActionBusy ? "Working..." : model.movementActive ? "Stop moving" : movementMode == .normal && randomMovement ? "Set & move" : movementMode.action,
                          systemImage: model.movementActive ? "pause.fill" : "location.fill")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent)
                    .disabled(model.userActionBusy || (!model.movementActive && (movementMode == .route ? routePins.count < 2 : model.selected == nil)))
                Button { Task { await model.restore() } } label: {
                    Label(model.restoring ? "Restoring" : "Restore", systemImage: "location.slash")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.bordered)
                    .disabled(model.restoring || model.userActionBusy || !model.pairingAvailable)
            }.controlSize(.small)
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
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
                if movementMode == .route && routePins.count > 1 { MapPolyline(coordinates: (loopRoute ? routePins + [routePins[0]] : routePins).map(\.mapCoordinate)).stroke(.blue, lineWidth: 4) }
                if movementMode == .route {
                    ForEach(Array(routePins.enumerated()), id: \.offset) { index, point in
                        Marker("Pin \(index + 1)", coordinate: point.mapCoordinate).tint(.blue)
                    }
                }
                if let real = monitor.restoredCoordinate, model.realLocationReceived {
                    Annotation("Current location", coordinate: real.mapCoordinate) {
                        Image(systemName: "location.circle.fill").font(.title).foregroundStyle(.blue).background(.white, in: Circle())
                    }
                }
                if movementMode == .normal, randomMovement, let selected = model.selected {
                    MapCircle(center: selected.mapCoordinate, radius: min(100, max(0, motionRadius)))
                        .foregroundStyle(.blue.opacity(0.12)).stroke(.blue.opacity(0.5), lineWidth: 1)
                }
                if let selected = model.selected { Marker("Selected", coordinate: selected.mapCoordinate).tint(CatterTheme.accent) }
                if let sent = model.lastSent, sent != model.selected {
                    Marker("Last sent", systemImage: "paperplane.fill", coordinate: sent.mapCoordinate).tint(.orange)
                }
            }
            .mapStyle(.standard)
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) {
                    if movementMode == .normal { choose(coordinate, recenter: false) }
                }
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
