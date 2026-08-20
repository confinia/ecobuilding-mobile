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
    /// Bâtiment touché : identifiant BDNB + point touché (l'arbitrage d'adresse
    /// dépend du point, un « bâtiment groupe » pouvant couvrir plusieurs rues).
    var onSelect: (String, CLLocationCoordinate2D) -> Void

    static let tilesURL = "https://ecobuilding.confinia.io/api/v1/tiles/batiment_groupe/{z}/{x}/{y}.pbf"
    private static let sourceID = "bdnb"
    private static let layerID = "bdnb-dpe-3d"

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero)
        map.styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")
        map.setCenter(.init(latitude: 43.6108, longitude: 3.8767), zoomLevel: 16, animated: false)
        map.minimumZoomLevel = 5
        map.showsUserLocation = true
        map.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        map.addGestureRecognizer(tap)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var map: MLNMapView?
        let onSelect: (String, CLLocationCoordinate2D) -> Void

        init(onSelect: @escaping (String, CLLocationCoordinate2D) -> Void) {
            self.onSelect = onSelect
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
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
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map, gesture.state == .ended else { return }
            let point = gesture.location(in: map)
            let features = map.visibleFeatures(
                at: point, styleLayerIdentifiers: [BuildingMap.layerID])
            guard let feature = features.first,
                  let id = feature.attribute(forKey: "batiment_groupe_id") as? String
            else { return }
            onSelect(id, map.convert(point, toCoordinateFrom: map))
        }
    }
}
