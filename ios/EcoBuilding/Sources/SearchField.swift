import SwiftUI

/// Recherche d'adresse, avec suggestions de la Base Adresse Nationale.
///
/// L'agent immobilier en visite tape l'adresse du bien qu'il fait visiter ; le
/// particulier cherche la maison qu'il vient de voir. C'est l'entrée principale
/// de l'app, avant même la carte.
struct SearchField: View {
    @Binding var text: String
    var onPick: (API.Suggestion) -> Void

    @State private var suggestions: [API.Suggestion] = []
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Adresse en France…", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onChange(of: text) { _, value in schedule(value) }
                if !text.isEmpty {
                    Button {
                        text = ""; suggestions = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { s in
                        Button {
                            text = s.label
                            suggestions = []
                            focused = false
                            onPick(s)
                        } label: {
                            Text(s.label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10).padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 4)
            }
        }
    }

    /// Anti-rebond : une frappe ne doit pas déclencher une requête par lettre.
    private func schedule(_ value: String) {
        task?.cancel()
        guard value.count >= 3 else { suggestions = []; return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            suggestions = (try? await API.suggest(value)) ?? []
        }
    }
}
