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
        }
        .sheet(item: $selection) { sel in
            BuildingSheet(buildingID: sel.id, lon: sel.lon, lat: sel.lat)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}
