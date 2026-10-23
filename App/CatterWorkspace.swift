import SwiftUI

private enum WorkspaceTab: Hashable { case location, places, settings }

/// One shared library and session across independent navigation stacks.
struct CatterWorkspace: View {
    @ObservedObject var model: SessionModel
    @ObservedObject var monitor: BackgroundLocationMonitor
    @StateObject private var library = PlaceLibrary()
    @State private var tab: WorkspaceTab = .location
    @State private var selectedPlace: SavedPlace?

    var body: some View {
        TabView(selection: $tab) {
            LocationView(model: model, monitor: monitor, library: library,
                         selectedPlace: $selectedPlace,
                         openPlaces: { tab = .places }, openSettings: { tab = .settings })
                .tabItem { Label("Location", systemImage: "map") }.tag(WorkspaceTab.location)
            PlacesView(library: library) { place in
                selectedPlace = place
                tab = .location
            }
            .tabItem { Label("Places", systemImage: "bookmark") }.tag(WorkspaceTab.places)
            SetupView(model: model, monitor: monitor)
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(WorkspaceTab.settings)
        }
        .toolbarBackground(CatterTheme.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}
