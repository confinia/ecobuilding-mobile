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
    /// Double appui : on saute la fiche et on sort directement le document.
    var onReportWanted: (String, CLLocationCoordinate2D) -> Void = { _, _ in }
    /// Point à rejoindre quand une adresse est trouvée. La carte restait
    /// immobile : on cherchait une adresse à l'autre bout de la France et on
    /// continuait de regarder son propre quartier.
    var focus: CLLocationCoordinate2D?
    /// Bâtiment à mettre en évidence, y compris lorsqu'il vient d'une RECHERCHE
    /// et non d'un appui. Sans cela, la fiche s'ouvrait sans qu'on sache lequel
    /// des bâtiments visibles elle décrivait — d'autant qu'un « bâtiment
    /// groupe » BDNB couvre parfois plusieurs adresses.
    var highlighted: String?
    /// Fond photo aérienne plutôt que plan.
    var aerial: Bool = false
    /// Épingle posée sur le bâtiment concerné.
    var pin: CLLocationCoordinate2D?
    /// Remonte la position de l'utilisateur dès qu'elle est connue : elle sert
    /// à classer les suggestions d'adresses par proximité.
    var onLocation: (CLLocationCoordinate2D) -> Void = { _ in }

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
    fileprivate static let aerialLayerID = "ign-ortho"
    fileprivate static let parcelsLayerID = "ign-parcelles"
    fileprivate static let parcelFillID = "parcelle-selectionnee"
    /// Identifiant unique de parcelle, porté par chaque entité du cadastre.
    fileprivate static let parcelKey = "idu"
    /// Limites de parcelles cadastrales — IGN, Licence Ouverte, sans clé.
    ///
    /// « Où s'arrête le terrain ? » est une des premières questions d'un
    /// acheteur, et la photo seule n'y répond pas.
    ///
    /// Tuiles VECTORIELLES, et non l'image toute faite : celle-ci imprime le
    /// numéro de chaque parcelle sur la carte. Illisible et sans intérêt à
    /// l'écran — un numéro cadastral ne dit rien à personne devant un
    /// bâtiment, et il recouvrait le reste. Ici on ne dessine que les limites.
    fileprivate static let parcelsURL = "https://data.geopf.fr/tms/1.0.0/PCI/{z}/{x}/{y}.pbf"
    fileprivate static let outlineLayerID = "bdnb-selected-outline"
    /// Photo aérienne de l'IGN — Licence Ouverte, sans clé ni compte.
    /// C'est elle qui montre ce qu'un acheteur veut voir : le terrain, les
    /// arbres, la piscine, le portail — rien de tout cela n'existe en donnée
    /// structurée, mais l'image le montre (#258).
    private static let orthoURL =
        "https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0"
        + "&LAYER=ORTHOIMAGERY.ORTHOPHOTOS&STYLE=normal&TILEMATRIXSET=PM"
        + "&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&FORMAT=image/jpeg"
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
        // Le double appui zoomait — comportement par défaut de MapLibre, hérité
        // sans l'avoir choisi. À 60° et au niveau de travail, ce zoom était
        // presque toujours subi.
        map.allowsZooming = true
        for recognizer in map.gestureRecognizers ?? [] {
            if let double = recognizer as? UITapGestureRecognizer,
               double !== tap, double.numberOfTapsRequired == 2 {
                double.isEnabled = false
            }
        }
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        // La photo est opaque et posée au-dessus du plan : la rendre visible
        // suffit, rien à masquer. Nos volumes, ajoutés après, restent dessus.
        context.coordinator.aerialLayer?.isVisible = aerial
        // Sur la photo, on efface les volumes : ils cachent précisément le
        // bâtiment qu'on est venu regarder. Le contour, lui, reste.
        //
        // Transparents, et non masqués : MapLibre n'interroge que les couches
        // RENDUES. Masquée, la couche des volumes ne répondait plus à
        // `visibleFeatures`, et toucher un bâtiment en vue photo ne
        // sélectionnait plus rien — le geste même qu'on vient chercher ici.
        //
        // 1 % et non 0 : vérifié sur émulateur, une opacité STRICTEMENT nulle
        // n'est pas indexée non plus. À 1 % la couche reste interrogeable et
        // demeure invisible à l'œil.
        if let style = uiView.style {
            (style.layer(withIdentifier: BuildingMap.layerID) as? MLNFillExtrusionStyleLayer)?
                .fillExtrusionOpacity = NSExpression(forConstantValue: aerial ? 0.01 : 0.9)
            (style.layer(withIdentifier: BuildingMap.selectedLayerID) as? MLNFillExtrusionStyleLayer)?
                .fillExtrusionOpacity = NSExpression(forConstantValue: aerial ? 0.01 : 1.0)
        }
        // Épingle : un repère qui survit au changement de fond et au zoom.
        if let pin, CLLocationCoordinate2DIsValid(pin) {
            if let existing = context.coordinator.pinAnnotation {
                existing.coordinate = pin
            } else {
                let a = MLNPointAnnotation()
                a.coordinate = pin
                uiView.addAnnotation(a)
                context.coordinator.pinAnnotation = a
            }
        } else if let existing = context.coordinator.pinAnnotation {
            uiView.removeAnnotation(existing)
            context.coordinator.pinAnnotation = nil
        }
        // Surlignage piloté depuis l'extérieur (résultat de recherche).
        if context.coordinator.lastHighlighted != highlighted {
            context.coordinator.lastHighlighted = highlighted
            let p = NSPredicate(format: "batiment_groupe_id == %@", highlighted ?? "")
            context.coordinator.selectedLayer?.predicate = p
            context.coordinator.outlineLayer?.predicate = p
        }
        guard let focus, CLLocationCoordinate2DIsValid(focus) else {
            // Fiche refermée : rendre le plein cadre à la carte.
            if uiView.contentInset.bottom != 0 {
                uiView.setContentInset(.zero, animated: true, completionHandler: nil)
            }
            return
        }
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
            // La fiche recouvre la moitié basse de l'écran : sans ce retrait,
            // la plongée centrait le bâtiment... pile sous elle. Le décalage
            // le pose dans le tiers haut, visible AU-DESSUS de sa fiche (#21).
            let lift = UIEdgeInsets(top: 0, left: 0,
                                    bottom: uiView.frame.height * 0.55, right: 0)
            uiView.setCamera(close, withDuration: 1.4,
                             animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut),
                             edgePadding: lift, completionHandler: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onSelect: onSelect, onHighlight: onHighlight)
        coordinator.onLocation = onLocation
        coordinator.onReportWanted = onReportWanted
        return coordinator
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var map: MLNMapView?
        var selectedLayer: MLNFillExtrusionStyleLayer?
        var aerialLayer: MLNRasterStyleLayer?
        var parcelsLayer: MLNLineStyleLayer?
        var parcelFill: MLNFillStyleLayer?
        var outlineLayer: MLNLineStyleLayer?
        var pinAnnotation: MLNPointAnnotation?
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

        var onLocation: (CLLocationCoordinate2D) -> Void = { _ in }
        var onReportWanted: (String, CLLocationCoordinate2D) -> Void = { _, _ in }
        private var armedAt = Date.distantPast

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
            if let coord = userLocation?.coordinate, CLLocationCoordinate2DIsValid(coord) {
                onLocation(coord)
            }
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

            // Photo aérienne, SOUS les volumes : on voit sa maison, et sa
            // couleur énergétique par-dessus.
            let ortho = MLNRasterTileSource(
                identifier: "ign-ortho-src",
                tileURLTemplates: [BuildingMap.orthoURL],
                options: [.tileSize: 256,
                          .attributionInfos: [
                              MLNAttributionInfo(title: NSAttributedString(string: "IGN — BD ORTHO"),
                                                 url: URL(string: "https://geoservices.ign.fr"))
                          ]])
            style.addSource(ortho)
            let orthoLayer = MLNRasterStyleLayer(identifier: BuildingMap.aerialLayerID,
                                                 source: ortho)
            orthoLayer.isVisible = false
            style.addLayer(orthoLayer)      // au-dessus du plan, sous nos volumes
            aerialLayer = orthoLayer

            let parcels = MLNVectorTileSource(
                identifier: "ign-parcelles-src",
                tileURLTemplates: [BuildingMap.parcelsURL],
                options: [.minimumZoomLevel: 13, .maximumZoomLevel: 16,
                          .attributionInfos: [
                              MLNAttributionInfo(title: NSAttributedString(string: "IGN — Parcellaire Express"),
                                                 url: URL(string: "https://geoservices.ign.fr"))
                          ]])
            style.addSource(parcels)
            // La parcelle du bâtiment choisi, en aplat translucide : le
            // bâtiment seul ne dit pas ce qu'on achète. Le terrain autour
            // compte autant — c'est lui qu'on arpente, qu'on plante, où l'on
            // gare la voiture.
            let parcelFill = MLNFillStyleLayer(identifier: BuildingMap.parcelFillID,
                                               source: parcels)
            parcelFill.sourceLayerIdentifier = "parcelle"
            parcelFill.minimumZoomLevel = 15
            parcelFill.predicate = NSPredicate(format: "%K == %@", BuildingMap.parcelKey, "")
            parcelFill.fillColor = NSExpression(forConstantValue: UIColor(red: 0, green: 0.88,
                                                                          blue: 1, alpha: 1))
            parcelFill.fillOpacity = NSExpression(forConstantValue: 0.22)
            style.addLayer(parcelFill)
            self.parcelFill = parcelFill

            let parcelsLayer = MLNLineStyleLayer(identifier: BuildingMap.parcelsLayerID,
                                                 source: parcels)
            parcelsLayer.sourceLayerIdentifier = "parcelle"
            // En dessous, les limites forment une bouillie de traits.
            parcelsLayer.minimumZoomLevel = 15
            // Assez marqué pour se lire sur une toiture claire comme sur des
            // arbres, sans masquer ce qu'on est venu regarder.
            parcelsLayer.lineColor = NSExpression(forConstantValue: UIColor(red: 1, green: 0.54,
                                                                            blue: 0, alpha: 1))
            parcelsLayer.lineWidth = NSExpression(forConstantValue: 1.6)
            parcelsLayer.lineOpacity = NSExpression(forConstantValue: 0.9)
            style.addLayer(parcelsLayer)
            self.parcelsLayer = parcelsLayer

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

            // Contour au sol du bâtiment retenu. Sur la photo, les volumes
            // cachent le toit qu'on veut justement voir : un trait ne masque
            // rien, et désigne sans ambiguïté.
            let outline = MLNLineStyleLayer(identifier: BuildingMap.outlineLayerID,
                                            source: source)
            outline.sourceLayerIdentifier = "sql_statement"
            outline.minimumZoomLevel = 14
            outline.predicate = NSPredicate(format: "batiment_groupe_id == %@", "")
            outline.lineColor = NSExpression(forConstantValue: UIColor.systemBlue)
            outline.lineWidth = NSExpression(forConstantValue: 3)
            outline.lineOpacity = NSExpression(forConstantValue: 0.95)
            style.addLayer(outline)
            outlineLayer = outline
            // Le style se charge parfois APRÈS la recherche : sans ce rappel,
            // le premier bâtiment cherché n'était jamais surligné.
            if let id = lastHighlighted {
                let p = NSPredicate(format: "batiment_groupe_id == %@", id)
                highlight.predicate = p
                outlineLayer?.predicate = p
            }
        }

        /// Trouve le bâtiment VISÉ, et non celui dont l'emprise est sous le doigt.
        ///
        /// MapLibre teste la collision sur l'emprise au SOL. Incliné, le toit
        /// qu'on voit est décalé vers le haut de l'écran : viser le bâtiment
        /// qu'on regarde ne sélectionnait rien, ou pire, le voisin de derrière.
        /// On cherche donc aussi SOUS le point touché, puis on retient celui
        /// dont le toit — position au sol remontée de sa hauteur — tombe le plus
        /// près du doigt.
        static func hitTest(_ point: CGPoint, on map: MLNMapView,
                            aerial: Bool) -> [MLNFeature] {
            let direct = map.visibleFeatures(at: point,
                                             styleLayerIdentifiers: [BuildingMap.layerID])
            // En vue photo les volumes sont effacés : ce qu'on voit EST
            // l'emprise au sol, posée à plat sur l'orthophoto. La visée directe
            // est alors exacte, et c'est elle qu'il faut.
            if aerial || map.camera.pitch <= 5 { return direct }

            // Bande large et surtout HAUTE vers le bas : c'est là que se
            // trouvent les emprises des bâtiments dont on voit le toit plus
            // haut. On ne court-circuite JAMAIS sur le résultat direct dès que
            // la caméra est inclinée : il renvoie presque toujours quelque
            // chose, et c'est le voisin de derrière.
            let strip = CGRect(x: point.x - 30, y: point.y - 15, width: 60, height: 300)
            let candidates = map.visibleFeatures(in: strip,
                                                 styleLayerIdentifiers: [BuildingMap.layerID])
            guard !candidates.isEmpty else { return direct }

            let mpp = map.metersPerPoint(atLatitude: map.centerCoordinate.latitude)
            let lift = sin(map.camera.pitch * .pi / 180) / max(mpp, 0.0001)

            var best: MLNFeature?
            var bestHeight = -1.0
            var fallback: MLNFeature?
            var fallbackDistance = CGFloat.greatestFiniteMagnitude

            for feature in candidates {
                let height = (feature.attribute(forKey: "hauteur_mean") as? NSNumber)?
                    .doubleValue ?? 6
                let roof = roofPolygon(feature, on: map, lift: height * lift)
                if roof.count > 2, contains(roof, point) {
                    // Plusieurs toits peuvent se recouvrir : le plus haut est
                    // celui qui est dessiné devant, donc celui qu'on voit.
                    if height > bestHeight { bestHeight = height; best = feature }
                } else if best == nil {
                    let ground = map.convert(feature.coordinate, toPointTo: map)
                    let centre = CGPoint(x: ground.x, y: ground.y - CGFloat(height * lift))
                    let d = hypot(centre.x - point.x, centre.y - point.y)
                    if d < fallbackDistance { fallbackDistance = d; fallback = feature }
                }
            }
            if let best { return [best] }
            if let fallback { return [fallback] }
            return direct
        }

        /// L'emprise projetée à l'écran, remontée de la hauteur du bâtiment.
        private static func roofPolygon(_ feature: MLNFeature, on map: MLNMapView,
                                        lift: Double) -> [CGPoint] {
            let polygon = (feature as? MLNPolygonFeature)
                ?? (feature as? MLNMultiPolygonFeature)?.polygons.first
            guard let polygon else { return [] }
            let count = polygon.pointCount
            guard count > 2 else { return [] }
            var coordinates = [CLLocationCoordinate2D](
                repeating: kCLLocationCoordinate2DInvalid, count: Int(count))
            polygon.getCoordinates(&coordinates, range: NSRange(location: 0, length: Int(count)))
            return coordinates.map { coordinate in
                let ground = map.convert(coordinate, toPointTo: map)
                return CGPoint(x: ground.x, y: ground.y - CGFloat(lift))
            }
        }

        /// Lancer de rayon : le point est-il à l'intérieur du polygone ?
        private static func contains(_ ring: [CGPoint], _ point: CGPoint) -> Bool {
            var inside = false
            var j = ring.count - 1
            for i in ring.indices {
                let a = ring[i], b = ring[j]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }

        /// Met en avant la parcelle sous un point de l'écran.
        ///
        /// On interroge la carte plutôt que le serveur : les limites sont déjà
        /// chargées pour être dessinées, et une requête réseau de plus ferait
        /// attendre pour une information qu'on a sous la main.
        func selectParcel(at point: CGPoint, on map: MLNMapView) {
            let hits = map.visibleFeatures(
                at: point, styleLayerIdentifiers: [BuildingMap.parcelsLayerID,
                                                   BuildingMap.parcelFillID])
            let idu = hits.first?.attribute(forKey: BuildingMap.parcelKey) as? String
            parcelFill?.predicate = NSPredicate(format: "%K == %@",
                                                BuildingMap.parcelKey, idu ?? "")
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map, gesture.state == .ended else { return }
            let point = gesture.location(in: map)
            let features = BuildingMap.Coordinator.hitTest(
                point, on: map, aerial: aerialLayer?.isVisible == true)
            guard let feature = features.first,
                  let id = feature.attribute(forKey: "batiment_groupe_id") as? String
            else {
                // Appui à côté : on désarme, plutôt que de garder une sélection
                // fantôme que le prochain appui confirmerait par surprise.
                armed = nil
                let none = NSPredicate(format: "batiment_groupe_id == %@", "")
                selectedLayer?.predicate = none
                outlineLayer?.predicate = none
                onHighlight(nil)
                return
            }
            let p = NSPredicate(format: "batiment_groupe_id == %@", id)
            selectedLayer?.predicate = p
            outlineLayer?.predicate = p

            // DEUX temps : le premier appui désigne, le second charge. Avec de
            // l'inclinaison, la visée tombe souvent sur le voisin — un appui
            // manqué ne doit pas coûter un chargement complet, ni ouvrir la
            // fiche d'un bâtiment qu'on ne visait pas.
            if armed == id {
                let quick = Date().timeIntervalSince(armedAt) <= 0.32
                armed = nil
                onHighlight(nil)
                selectParcel(at: point, on: map)
                let coord = map.convert(point, toCoordinateFrom: map)
                // Deux appuis RAPPROCHÉS valent double appui : on sort le
                // document. Posés, ils ouvrent la fiche à l'écran. C'est le
                // délai qui décide.
                if quick { onReportWanted(id, coord) } else { onSelect(id, coord) }
            } else {
                armed = id
                armedAt = Date()
                onHighlight(id)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}
