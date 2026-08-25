import CoreLocation
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
    /// Bâtiment désigné, en attente du second appui.
    @State private var armed: String?
    /// Bâtiment mis en évidence sur la carte (touché OU trouvé par recherche).
    @State private var highlighted: String?
    /// Fond photo plutôt que plan.
    @State private var aerial = false
    /// Épingle sur le bâtiment concerné.
    @State private var pin: CLLocationCoordinate2D?
    /// Point que la carte doit rejoindre (adresse trouvée).
    @State private var focus: CLLocationCoordinate2D?
    /// Dernière position connue, gardée pour classer les suggestions par
    /// proximité. `focus` ne peut pas servir : il désigne le point à REJOINDRE,
    /// pas celui où l'on est.
    @State private var here: CLLocationCoordinate2D?
    /// Fiche demandée par double appui : à lancer dès que le bâtiment répond.
    @State private var wantsReport = false

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
            BuildingMap(onSelect: { id, coord in
                armed = nil
                highlighted = id
                pin = coord
                selection = .building(id: id, lon: coord.longitude, lat: coord.latitude)
            }, onHighlight: { id in armed = id },
               onReportWanted: { id, coord in
                   armed = nil
                   highlighted = id
                   pin = coord
                   wantsReport = true
                   selection = .building(id: id, lon: coord.longitude, lat: coord.latitude)
               },
               focus: focus, highlighted: highlighted,
               aerial: aerial, pin: pin, onLocation: { here = $0 })
            .ignoresSafeArea()

            // Bascule plan / photo aérienne. Placée en haut à droite, sous la
            // recherche : c'est le premier geste d'un acheteur qui veut « voir
            // le bien » plutôt que des volumes (#258).
            if search.isEmpty {
              VStack {
                HStack {
                    Spacer()
                    Button { aerial.toggle() } label: {
                        Image(systemName: aerial ? "map.fill" : "globe.europe.africa.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }
                    .padding(.trailing, 12)
                    .accessibilityLabel(aerial ? t("show_plan") : t("show_aerial"))
                }
                .padding(.top, 72)
                Spacer()
              }
            }

            SearchField(text: $search, near: here, onPick: { s in
                let point = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
                focus = point
                pin = point
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

            // Sans ce mot, le premier appui paraît sans effet et l'utilisateur
            // conclut que la carte ne répond pas.
            if armed != nil {
                VStack {
                    Spacer()
                    Text(t("tap_again"))
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 4, y: 2)
                        .padding(.bottom, 40)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

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
                        Text(copied ? t("id_copied") : Self.versionLabel)
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
            BuildingSheet(target: target, onBuildingResolved: { id in
                highlighted = id
            }, autoReport: $wantsReport)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                // La carte reste MANIPULABLE tant que la fiche est à
                // mi-hauteur : on lit la fiche, on veut voir ce qu'il y a juste
                // à côté, on pousse la carte du doigt. Sans cela il fallait
                // refermer, se déplacer, rouvrir. Tirée en grand, la fiche
                // redevient modale.
                .modifier(BackgroundInteraction())
        }
    }
}


/// `presentationBackgroundInteraction` n'existe qu'à partir d'iOS 16.4, or nous
/// ciblons iOS 16.0 pour couvrir l'iPhone 8. Les appareils plus anciens gardent
/// le comportement actuel — pas de régression, simplement pas le confort.
private struct BackgroundInteraction: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackgroundInteraction(.enabled(upThrough: .medium))
        } else {
            content
        }
    }
}
