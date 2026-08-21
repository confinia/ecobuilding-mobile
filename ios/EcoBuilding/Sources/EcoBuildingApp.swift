import SwiftUI
import UIKit

@main
struct EcoBuildingApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Écran unique de la V1 : la carte, et une fiche qui monte depuis le bas.
///
/// Pas d'écran d'accueil, pas de compte à créer, pas de tutoriel : on ouvre
/// l'app, on voit des bâtiments colorés par DPE, on en touche un. Tout ce qui
/// s'interpose entre le lancement et cette première information est du
/// renoncement d'utilisateurs.
struct ContentView: View {
    @State private var selection: Target?
    @State private var search = ""
    @State private var copied = false

    /// « v1.0 (12) » : version publique et numéro de compilation, les deux
    /// étant nécessaires — la version publique bouge rarement, le numéro de
    /// compilation identifie précisément ce qui tourne sur l'appareil.
    static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    /// Ce que la fiche doit charger. Deux entrées distinctes : un bâtiment
    /// touché sur la carte, ou une adresse — saisie librement ou choisie dans
    /// les suggestions. Les confondre revenait à envoyer « latitude,longitude »
    /// dans un champ qui attend une adresse.
    enum Target: Identifiable {
        case building(id: String, lon: Double, lat: Double)
        case suggestion(banID: String, lon: Double, lat: Double, label: String)
        case freeText(String)

        var id: String {
            switch self {
            case let .building(id, _, _): return "b:" + id
            case let .suggestion(banID, _, _, _): return "s:" + banID
            case let .freeText(q): return "q:" + q
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            BuildingMap { id, coord in
                selection = .building(id: id, lon: coord.longitude, lat: coord.latitude)
            }
            .ignoresSafeArea()

            SearchField(text: $search, onPick: { s in
                if let ban = s.banID {
                    selection = .suggestion(banID: ban, lon: s.lon, lat: s.lat, label: s.label)
                } else {
                    selection = .freeText(s.label)
                }
            }, onSubmit: { text in
                // Valider au clavier ou par la loupe doit CHERCHER : sans cela,
                // une adresse tapée en entier ne menait nulle part.
                let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if q.count >= 3 { selection = .freeText(q) }
            })
            .padding(.horizontal, 12)
            .padding(.top, 8)          // ne pas coller à la barre d'état

            // Version affichée en clair : un testeur qui dit « ça plante » sans
            // savoir sur quelle version tourne son téléphone fait perdre un
            // aller-retour à chaque fois.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    // Toucher la version copie l'identifiant d'installation.
                    // C'est ce que le bêta-testeur envoie pour être exempté de
                    // quota : sans ce geste, il faudrait le lui extraire de
                    // l'appareil, ce qu'aucun partenaire ne fera.
                    Button {
                        UIPasteboard.general.string = InstallID.current
                        copied = true
                    } label: {
                        Text(copied ? "Identifiant copié" : Self.versionLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.trailing, 12).padding(.bottom, 6)
                }
            }
        }
        .sheet(item: $selection) { target in
            BuildingSheet(target: target)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}
