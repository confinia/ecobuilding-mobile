import SwiftUI

/// Recherche d'adresse, avec suggestions de la Base Adresse Nationale.
///
/// L'agent immobilier en visite tape l'adresse du bien qu'il fait visiter ; le
/// particulier cherche la maison qu'il vient de voir. C'est l'entrée principale
/// de l'app, avant même la carte.
struct SearchField: View {
    @Binding var text: String
    var onPick: (API.Suggestion) -> Void
    /// Validation au clavier ou par la loupe : chercher le texte tel quel.
    var onSubmit: (String) -> Void

    @State private var suggestions: [API.Suggestion] = []
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // La loupe était une simple image : la toucher ne faisait rien.
                Button {
                    submit()
                } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                }
                TextField("Adresse en France…", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { submit() }
                    .focused($focused)
                    // Forme à un paramètre : celle à deux exige iOS 17, or
                    // nous ciblons iOS 16 pour couvrir l'iPhone 8.
                    .onChange(of: text) { value in schedule(value) }
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
                            // Vider le champ, et non y recopier l'adresse : la
                            // recopie relançait une recherche par l'anti-rebond,
                            // qui réaffichait aussitôt la liste qu'on venait de
                            // fermer. L'adresse choisie titre la fiche, elle n'a
                            // pas à rester ici.
                            task?.cancel()
                            text = ""
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

    private func submit() {
        task?.cancel()
        let query = text
        text = ""
        suggestions = []
        focused = false
        onSubmit(query)
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
