import CoreLocation
import MapLibre
import SwiftUI

/// Carte 3D des bâtiments, colorés par classe DPE.
///
/// Les tuiles viennent de **notre** cache (`/v1/tiles`), jamais d'api.bdnb.io en
/// direct : ce service est anonyme et plafonné par IP (120 req/min,
/// 10 000/mois), et MapLibre redemande la même tuile une fois par identifiant
/// sur-zoomé — mesuré 10 à 17 fois par affichage. En direct, la carte se vidait
/// silencieusement au bout de quelques minutes d'usage.
///
/// BDNB ne publie que le **z14** : demander un autre niveau ne ramène rien.
struct BuildingMap: UIViewRepresentable {
    /// Bâtiment CONFIRMÉ (second appui) : identifiant BDNB + point touché
    /// (l'arbitrage d'adresse dépend du point, un « bâtiment groupe » pouvant
    /// couvrir plusieurs rues).
    var onSelect: (String, CLLocationCoordinate2D) -> Void
    /// Bâtiment simplement DÉSIGNÉ (premier appui), pour l'annoncer à l'écran.
    var onHighlight: (String?) -> Void = { _ in }
    /// Point à rejoindre quand une adresse est trouvée. La carte restait
    /// immobile : on cherchait une adresse à l'autre bout de la France et on
    /// continuait de regarder son propre quartier.
    var focus: CLLocationCoordinate2D?
    /// Bâtiment à mettre en évidence, y compris lorsqu'il vient d'une RECHERCHE
    /// et non d'un appui. Sans cela, la fiche s'ouvrait sans qu'on sache lequel
    /// des bâtiments visibles elle décrivait — d'autant qu'un « bâtiment
    /// groupe » BDNB couvre parfois plusieurs adresses.
    var highlighted: String?

    static let tilesURL = "https://ecobuilding.confinia.io/api/v1/tiles/batiment_groupe/{z}/{x}/{y}.pbf"
    /// Vue d'ouverture, avant la plongée : assez large pour situer le quartier.
    static let openZoom: Double = 10
    /// Vue de travail : les bâtiments sont assez gros pour être touchés au doigt.
    static let workZoom: Double = 17
    /// Inclinaison par défaut. Le relief EST le produit : à plat, rien ne
    /// distingue une passoire de quatre étages d'une maison de plain-pied.
    static let defaultPitch: CGFloat = 30
    private static let sourceID = "bdnb"
    private static let layerID = "bdnb-dpe-3d"
    fileprivate static let selectedLayerID = "bdnb-selected"

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero)
        map.styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")
        // Repli quand la position est refusée ou pas encore acquise. Le vrai
        // cadrage vient de userTrackingMode ci-dessous : l'usage mobile, c'est
        // « les bâtiments AUTOUR DE MOI » — atterrir sur une ville arbitraire
        // oblige l'utilisateur à chercher avant de comprendre à quoi sert l'app.
        map.minimumZoomLevel = 5
        map.showsUserLocation = true

        // Partir de la position de l'utilisateur, PAS d'une ville en dur.
        // Auparavant la carte s'ouvrait sur Montpellier puis traversait la
        // France en vol : spectaculaire une fois, pénible toutes les suivantes,
        // et trompeur — on croit un instant regarder son quartier.
        // Zoom 18 : à 16 les bâtiments sont trop petits pour être touchés.
        if let fix = context.coordinator.locations.location {
            // On ouvre de loin, puis on plonge : le vol d'arrivée montre d'un
            // coup le quartier ET le relief. Arriver directement au ras des
            // toits ne donne aucun repère.
            map.setCenter(fix.coordinate, zoomLevel: BuildingMap.openZoom, animated: false)
            context.coordinator.diveTo(fix.coordinate, on: map)
        } else {
            // Pas encore de position : vue d'ensemble de la France, et le premier
            // point reçu déclenchera le même vol — jamais un déplacement latéral
            // d'une ville à une autre.
            map.setCenter(.init(latitude: 46.6, longitude: 2.5), zoomLevel: 4.5, animated: false)
        }
        map.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        map.addGestureRecognizer(tap)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        // Surlignage piloté depuis l'extérieur (résultat de recherche).
        if context.coordinator.lastHighlighted != highlighted {
            context.coordinator.lastHighlighted = highlighted
            context.coordinator.selectedLayer?.predicate =
                NSPredicate(format: "batiment_groupe_id == %@", highlighted ?? "")
        }
        guard let focus, CLLocationCoordinate2DIsValid(focus) else { return }
        // Ne rejouer l'animation que si la cible a changé.
        let last = context.coordinator.lastFocus
        if let last, abs(last.latitude - focus.latitude) < 1e-7,
           abs(last.longitude - focus.longitude) < 1e-7 { return }
        context.coordinator.lastFocus = focus
        // Suivre l'utilisateur ET aller ailleurs sont contradictoires : on
        // relâche le suivi, sinon la carte revient aussitôt sur lui.
        uiView.userTrackingMode = .none
        // Vol en DEUX temps : on prend d'abord du champ, puis on plonge sur la
        // cible. Un déplacement à zoom constant traverse la France au ras des
        // toits — illisible, et on ne comprend pas où l'on atterrit.
        let camera = MLNMapCamera(lookingAtCenter: focus, altitude: 4000,
                                  pitch: 0, heading: 0)
        uiView.fly(to: camera, withDuration: 1.6) {
            let close = MLNMapCamera(lookingAtCenter: focus, altitude: 320,
                                     pitch: BuildingMap.defaultPitch, heading: 0)
            uiView.fly(to: close, withDuration: 1.4, completionHandler: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect, onHighlight: onHighlight) }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var map: MLNMapView?
        var selectedLayer: MLNFillExtrusionStyleLayer?
        var lastFocus: CLLocationCoordinate2D?
        var lastHighlighted: String?
        let onSelect: (String, CLLocationCoordinate2D) -> Void
        let onHighlight: (String?) -> Void
        /// Bâtiment désigné par le premier appui, en attente de confirmation.
        private var armed: String?
        /// Sert uniquement à lire la position DÉJÀ connue du système au
        /// démarrage, pour ouvrir la carte au bon endroit sans animation.
        let locations = CLLocationManager()
        private var didCenter = false

        init(onSelect: @escaping (String, CLLocationCoordinate2D) -> Void,
             onHighlight: @escaping (String?) -> Void) {
            self.onSelect = onSelect
            self.onHighlight = onHighlight
            super.init()
            locations.requestWhenInUseAuthorization()
        }

        /// Premier point reçu quand aucune position n'était connue : on zoome
        /// depuis la vue d'ensemble, sans traversée latérale.
        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            guard !didCenter, let coord = userLocation?.coordinate,
                  CLLocationCoordinate2DIsValid(coord) else { return }
            didCenter = true
            mapView.setCenter(coord, zoomLevel: BuildingMap.openZoom, animated: false)
            diveTo(coord, on: mapView)
        }

        /// Plongée du zoom d'ouverture vers le zoom de travail, en inclinant.
        ///
        /// Le suivi de position doit être RELÂCHÉ : il réécrase la caméra à
        /// chaque point reçu, ce qui remettait l'inclinaison à plat aussitôt
        /// après l'avoir posée — la carte restait obstinément en vue de dessus.
        func diveTo(_ coord: CLLocationCoordinate2D, on map: MLNMapView) {
            map.userTrackingMode = .none
            let altitude = MLNAltitudeForZoomLevel(
                BuildingMap.workZoom, BuildingMap.defaultPitch, coord.latitude, map.frame.size)
            let camera = MLNMapCamera(lookingAtCenter: coord, altitude: altitude,
                                      pitch: BuildingMap.defaultPitch, heading: 0)
            map.fly(to: camera, withDuration: 2.2, completionHandler: nil)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // Le style peut être rechargé (changement de fond, reprise après
            // veille) : réajouter une source ou un calque déjà présent lève une
            // exception, donc plante l'app.
            guard style.source(withIdentifier: BuildingMap.sourceID) == nil else { return }
            // Le fond de carte porte ses propres bâtiments OSM, qui ne
            // s'alignent pas sur les emprises BDNB : deux volumes superposés et
            // décalés. On ne garde que les nôtres, porteurs du DPE.
            for layer in style.layers where layer.identifier.contains("building") {
                style.removeLayer(layer)
            }

            let source = MLNVectorTileSource(
                identifier: BuildingMap.sourceID,
                tileURLTemplates: [BuildingMap.tilesURL],
                options: [.minimumZoomLevel: 14, .maximumZoomLevel: 14,
                          .attributionInfos: [
                              MLNAttributionInfo(title: NSAttributedString(string: "BDNB (CSTB)"),
                                                 url: URL(string: "https://bdnb.io"))
                          ]])
            style.addSource(source)

            let layer = MLNFillExtrusionStyleLayer(identifier: BuildingMap.layerID, source: source)
            layer.sourceLayerIdentifier = "sql_statement"
            layer.minimumZoomLevel = 14
            layer.fillExtrusionColor = NSExpression(
                forMLNMatchingKey: NSExpression(forKeyPath: "classe_bilan_dpe"),
                in: [
                    NSExpression(forConstantValue: "A"): NSExpression(forConstantValue: UIColor(red: 0.00, green: 0.56, blue: 0.21, alpha: 1)),
                    NSExpression(forConstantValue: "B"): NSExpression(forConstantValue: UIColor(red: 0.32, green: 0.69, blue: 0.33, alpha: 1)),
                    NSExpression(forConstantValue: "C"): NSExpression(forConstantValue: UIColor(red: 0.65, green: 0.80, blue: 0.45, alpha: 1)),
                    NSExpression(forConstantValue: "D"): NSExpression(forConstantValue: UIColor(red: 0.96, green: 0.91, blue: 0.06, alpha: 1)),
                    NSExpression(forConstantValue: "E"): NSExpression(forConstantValue: UIColor(red: 0.94, green: 0.71, blue: 0.06, alpha: 1)),
                    NSExpression(forConstantValue: "F"): NSExpression(forConstantValue: UIColor(red: 0.92, green: 0.51, blue: 0.21, alpha: 1)),
                    NSExpression(forConstantValue: "G"): NSExpression(forConstantValue: UIColor(red: 0.84, green: 0.13, blue: 0.12, alpha: 1)),
                ],
                default: NSExpression(forConstantValue: UIColor(red: 0.84, green: 0.80, blue: 0.75, alpha: 1)))
            // Hauteur réelle quand la BDNB la connaît ; 6 m sinon, pour que le
            // bâtiment reste touchable au lieu d'être plat et invisible.
            layer.fillExtrusionHeight = NSExpression(
                format: "mgl_coalesce({%@, %@})",
                NSExpression(forKeyPath: "hauteur_mean"),
                NSExpression(forConstantValue: 6))
            // Opacité CONSTANTE : par entité, MapLibre invalide la propriété en
            // silence — la leçon a coûté cher côté web.
            layer.fillExtrusionOpacity = NSExpression(forConstantValue: 0.9)
            style.addLayer(layer)

            // Confirmation visuelle de la sélection. Sans elle, on touche un
            // bâtiment et on doit DEVINER, d'après l'adresse affichée, si c'est
            // bien celui qu'on visait — la même leçon que sur le web (#237).
            // Un calque filtré plutôt qu'un marqueur : le marqueur masque le
            // bâtiment qu'il est censé désigner.
            let highlight = MLNFillExtrusionStyleLayer(
                identifier: BuildingMap.selectedLayerID, source: source)
            highlight.sourceLayerIdentifier = "sql_statement"
            highlight.minimumZoomLevel = 14
            // Rien de sélectionné au départ. PAS « NSPredicate(value: false) » :
            // MapLibre traduit les prédicats en filtres de style et ne sait pas
            // convertir une constante booléenne — il produit alors une valeur
            // nulle et l'app meurt sur une exception au chargement du style.
            // Une comparaison à un identifiant impossible fait le même travail.
            highlight.predicate = NSPredicate(format: "batiment_groupe_id == %@", "")
            // Assombrir la PROPRE couleur du bâtiment plutôt que de tout peindre
            // en vert : le vert uniforme effaçait la classe DPE, c'est-à-dire
            // l'information qu'on est venu chercher (#254).
            highlight.fillExtrusionColor = NSExpression(
                forMLNMatchingKey: NSExpression(forKeyPath: "classe_bilan_dpe"),
                in: [
                    NSExpression(forConstantValue: "A"): NSExpression(forConstantValue: UIColor(red: 0.00, green: 0.31, blue: 0.12, alpha: 1)),
                    NSExpression(forConstantValue: "B"): NSExpression(forConstantValue: UIColor(red: 0.16, green: 0.40, blue: 0.17, alpha: 1)),
                    NSExpression(forConstantValue: "C"): NSExpression(forConstantValue: UIColor(red: 0.36, green: 0.50, blue: 0.20, alpha: 1)),
                    NSExpression(forConstantValue: "D"): NSExpression(forConstantValue: UIColor(red: 0.60, green: 0.56, blue: 0.03, alpha: 1)),
                    NSExpression(forConstantValue: "E"): NSExpression(forConstantValue: UIColor(red: 0.58, green: 0.43, blue: 0.03, alpha: 1)),
                    NSExpression(forConstantValue: "F"): NSExpression(forConstantValue: UIColor(red: 0.56, green: 0.30, blue: 0.10, alpha: 1)),
                    NSExpression(forConstantValue: "G"): NSExpression(forConstantValue: UIColor(red: 0.49, green: 0.06, blue: 0.06, alpha: 1)),
                ],
                default: NSExpression(forConstantValue: UIColor(red: 0.42, green: 0.39, blue: 0.35, alpha: 1)))
            highlight.fillExtrusionHeight = NSExpression(
                format: "mgl_coalesce({%@, %@})",
                NSExpression(forKeyPath: "hauteur_mean"),
                NSExpression(forConstantValue: 6))
            highlight.fillExtrusionOpacity = NSExpression(forConstantValue: 1.0)
            style.addLayer(highlight)
            selectedLayer = highlight
            // Le style se charge parfois APRÈS la recherche : sans ce rappel,
            // le premier bâtiment cherché n'était jamais surligné.
            if let id = lastHighlighted {
                highlight.predicate = NSPredicate(format: "batiment_groupe_id == %@", id)
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map, gesture.state == .ended else { return }
            let point = gesture.location(in: map)
            let features = map.visibleFeatures(
                at: point, styleLayerIdentifiers: [BuildingMap.layerID])
            guard let feature = features.first,
                  let id = feature.attribute(forKey: "batiment_groupe_id") as? String
            else {
                // Appui à côté : on désarme, plutôt que de garder une sélection
                // fantôme que le prochain appui confirmerait par surprise.
                armed = nil
                selectedLayer?.predicate = NSPredicate(format: "batiment_groupe_id == %@", "")
                onHighlight(nil)
                return
            }
            selectedLayer?.predicate = NSPredicate(format: "batiment_groupe_id == %@", id)

            // DEUX temps : le premier appui désigne, le second charge. Avec de
            // l'inclinaison, la visée tombe souvent sur le voisin — un appui
            // manqué ne doit pas coûter un chargement complet, ni ouvrir la
            // fiche d'un bâtiment qu'on ne visait pas.
            if armed == id {
                armed = nil
                onHighlight(nil)
                onSelect(id, map.convert(point, toCoordinateFrom: map))
            } else {
                armed = id
                onHighlight(id)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}
