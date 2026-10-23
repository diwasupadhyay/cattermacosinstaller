import SwiftUI

struct CoordinateEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var latitude: String
    @State private var longitude: String
    @FocusState private var focused: Field?
    private enum Field: Hashable { case latitude, longitude }
    private let select: (Coordinate) -> Void

    init(latitude: String, longitude: String, select: @escaping (Coordinate) -> Void) {
        _latitude = State(initialValue: latitude)
        _longitude = State(initialValue: longitude)
        self.select = select
    }

    private var coordinate: Coordinate? { try? Coordinate(latitude: latitude, longitude: longitude) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("Latitude", hint: "-90 to 90", text: $latitude, focus: .latitude)
                    field("Longitude", hint: "-180 to 180", text: $longitude, focus: .longitude)
                } footer: {
                    Text("Use decimal degrees, for example 19.0760, 72.8777. Choosing coordinates does not change your location until you tap Set location.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(CatterTheme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Coordinates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") {
                        guard let coordinate else { return }
                        focused = nil
                        select(coordinate)
                        dismiss()
                    }.disabled(coordinate == nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
        }
    }

    private func field(_ title: String, hint: String, text: Binding<String>, focus: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            TextField(hint, text: text)
                .focused($focused, equals: focus)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel(title)
        }.padding(.vertical, 6)
    }
}
