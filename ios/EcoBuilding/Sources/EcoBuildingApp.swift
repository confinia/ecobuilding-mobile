import SwiftUI

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
    @State private var selection: Selection?
    @State private var search = ""

    /// « v1.0 (12) » : version publique et numéro de compilation, les deux
    /// étant nécessaires — la version publique bouge rarement, le numéro de
    /// compilation identifie précisément ce qui tourne sur l'appareil.
    static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    struct Selection: Identifiable {
        let id: String
        let lon: Double
        let lat: Double
    }

    var body: some View {
        ZStack(alignment: .top) {
            BuildingMap { id, coord in
                selection = Selection(id: id, lon: coord.longitude, lat: coord.latitude)
            }
            .ignoresSafeArea()

            SearchField(text: $search) { suggestion in
                selection = Selection(id: "", lon: suggestion.lon, lat: suggestion.lat)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)          // ne pas coller à la barre d'état

            // Version affichée en clair : un testeur qui dit « ça plante » sans
            // savoir sur quelle version tourne son téléphone fait perdre un
            // aller-retour à chaque fois.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(Self.versionLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.trailing, 12).padding(.bottom, 6)
                }
            }
            .allowsHitTesting(false)   // ne jamais voler un toucher à la carte
        }
        .sheet(item: $selection) { sel in
            BuildingSheet(buildingID: sel.id, lon: sel.lon, lat: sel.lat)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}
