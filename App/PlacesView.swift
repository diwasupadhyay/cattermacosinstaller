import SwiftUI

struct PlacesView: View {
    @ObservedObject var library: PlaceLibrary
    let choose: (SavedPlace) -> Void
    @State private var query = ""
    @State private var section = 0
    @State private var clearHistory = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Places", selection: $section) {
                    Text("Saved").tag(0); Text("Recent").tag(1)
                }.pickerStyle(.segmented).padding()
                List {
                    if let error = library.error { Text(error).foregroundStyle(.red) }
                    let places = (section == 0 ? library.saved : library.recent).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                    if places.isEmpty {
                        ContentUnavailableView(!query.isEmpty ? "No matching places" : section == 0 ? "No saved places" : "No recent locations",
                            systemImage: section == 0 ? "bookmark" : "clock",
                            description: Text(!query.isEmpty ? "Try another name or clear your search." : section == 0 ? "Save a selected place from the map." : "Locations appear here after a successful Set command."))
                    }
                    ForEach(places) { place in
                        Button {
                            choose(place)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: section == 0 ? "bookmark.fill" : "clock").foregroundStyle(CatterTheme.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(place.name).foregroundStyle(.primary)
                                    Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }
                        .swipeActions {
                            if section == 0 {
                                Button("Delete", role: .destructive) { library.remove(place.id) }
                            } else if let coordinate = place.coordinate, !library.contains(coordinate) {
                                Button("Save") { library.save(coordinate, name: place.name) }.tint(.blue)
                            }
                        }
                    }
                    Section {
                        Text("Stored only on this iPhone. Selecting a place does not change your location until you tap Set.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(CatterTheme.background)
            }
            .navigationTitle("Places")
            .searchable(text: $query, prompt: "Find a saved or recent place")
            .background(CatterTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if section == 1 && !library.recent.isEmpty { Button("Clear") { clearHistory = true } }
                }
            }
            .confirmationDialog("Clear recent locations?", isPresented: $clearHistory, titleVisibility: .visible) {
                Button("Clear recent locations", role: .destructive) { library.clearRecent() }
            } message: { Text("Saved places and the current simulation are unchanged.") }
        }
    }
}
