import SwiftUI

/// Fiche d'un bâtiment, remplie **au fil de l'eau**.
///
/// Le serveur émet le bâtiment dès que la BDNB a répondu (~0,6 s), puis un
/// événement par source. On affiche donc immédiatement ce qu'on sait, et on
/// complète — au lieu d'attendre la source la plus lente, qui met plus de 5 s.
/// Ce qui manque encore est annoncé, jamais masqué.
@MainActor
final class BuildingModel: ObservableObject {
    /// Adresse renvoyée par le serveur : celle du « bâtiment groupe » BDNB.
    @Published var address: String?
    /// Ce que l'utilisateur a réellement cherché. Un bâtiment groupe peut
    /// couvrir plusieurs adresses : titrer avec l'adresse principale du groupe
    /// affichait « 5 Allée des Marronniers » à qui avait cherché « 2 Allée des
    /// Peupliers » — on croit s'être trompé de bâtiment.
    @Published var searched: String?
    @Published var building: JSONValue?
    @Published var blocks: [String: JSONValue] = [:]
    @Published var marketDIA: JSONValue?
    @Published var pending: Set<String> = Set(BuildingModel.expected)
    @Published var failure: String?

    static let expected = ["area_risks", "groundwater", "solar_pv", "water_network",
                           "official_dpe", "local_taxes", "schools", "prices", "rnb"]
    static let labels = [
        "area_risks": "Risques", "groundwater": "Nappe phréatique",
        "solar_pv": "Solaire", "water_network": "Eau potable",
        "official_dpe": "DPE officiel", "local_taxes": "Fiscalité locale",
        "schools": "Écoles", "prices": "Prix de vente", "rnb": "ID-RNB",
    ]

    var buildingID: String? { building?["bdnb_id"]?.stringValue }
    /// Appelé dès que le flux a livré le bâtiment, pour que la carte le mette
    /// en évidence. Branché ICI plutôt que sur une détection de changement de
    /// vue : le rappel doit partir quand la DONNÉE arrive, pas quand SwiftUI
    /// décide de réévaluer un corps — c'est ce qui l'avait rendu muet.
    var onResolved: ((String) -> Void)?
    private(set) var lon: Double?
    private(set) var lat: Double?

    func load(_ target: ContentView.Target) async {
        let stream: AsyncThrowingStream<API.StreamEvent, Error>
        switch target {
        case let .building(id, lon, lat):
            self.lon = lon; self.lat = lat
            stream = API.buildingStream(id: id, lon: lon, lat: lat)
        case let .suggestion(banID, lon, lat, label):
            self.lon = lon; self.lat = lat
            searched = label
            address = label            // afficher tout de suite ce qu'on a choisi
            stream = API.lookupStream(banID: banID, lon: lon, lat: lat)
        case let .freeText(q):
            searched = q
            address = q
            stream = API.lookupStream(q: q)
        }
        do {
            for try await event in stream {
                switch event {
                case let .core(query, buildings):
                    address = query["address"]?.stringValue
                    building = buildings.first
                    if let id = buildingID { onResolved?(id) }
                case let .block(name, value):
                    blocks[name] = value
                    pending.remove(name)
                case let .done(query, _):
                    address = query["address"]?.stringValue ?? address
                    pending.removeAll()
                case let .failure(status, detail):
                    failure = status == 404
                        ? t("no_sheet")
                        : (detail.isEmpty ? t("data_unavailable") : detail)
                    pending.removeAll()
                }
            }
        } catch {
            // Réseau coupé en cours de route : on garde ce qui est déjà affiché
            // et on le dit, plutôt que de vider l'écran.
            if building == nil { failure = t("data_unavailable") }
            pending.removeAll()
        }
    }
}

struct BuildingSheet: View {
    let target: ContentView.Target
    /// Remonte l'identifiant dès que le flux l'a livré, pour que la carte
    /// puisse mettre le bâtiment en évidence.
    var onBuildingResolved: (String) -> Void = { _ in }
    /// Fiche réclamée par un double appui sur la carte : le bouton se déclenche
    /// seul dès que le bâtiment a répondu.
    var autoReport: Binding<Bool> = .constant(false)
    @StateObject private var model = BuildingModel()

    var body: some View {
      VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.searched ?? model.address ?? t("sheet_fallback_title")).font(.title3.bold())
                // Le groupe BDNB porte parfois une autre adresse principale :
                // la dire, plutôt que de laisser croire à une erreur.
                if let principal = model.address, let searched = model.searched,
                   principal.caseInsensitiveCompare(searched) != .orderedSame {
                    Text(t("main_address", principal))
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if let failure = model.failure {
                    Text(failure).foregroundStyle(.secondary)
                } else if let b = model.building {
                    EnergySection(building: b, officialDPE: model.blocks["official_dpe"])
                    BuildingSection(building: b)
                    RisksSection(risks: model.blocks["area_risks"])
                    EnvironmentSection(groundwater: model.blocks["groundwater"],
                                       solar: model.blocks["solar_pv"],
                                       water: model.blocks["water_network"])
                    NeighbourhoodSection(taxes: model.blocks["local_taxes"],
                                         schools: model.blocks["schools"],
                                         prices: model.blocks["prices"])
                    IdentitySection(building: b, rnb: model.blocks["rnb"])
                } else {
                    ProgressView().padding(.vertical, 24)
                }

                if !model.pending.isEmpty {
                    Text(t("pending_prefix") + model.pending
                        .compactMap { BuildingModel.labels[$0] }
                        .sorted().joined(separator: ", ") + "…")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        // Bouton ANCRÉ en bas, hors du défilement : il n'apparaissait qu'après
        // avoir fait défiler toute la fiche, alors que c'est l'objet vendu.
        if model.building != nil {
            ReportButton(model: model, autoStart: autoReport)
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
                .background(.regularMaterial)
        }
      }
      .task {
          model.onResolved = onBuildingResolved
          await model.load(target)
      }
    }
}

// MARK: - Blocs d'affichage

/// Une valeur absente disparaît au lieu d'afficher « — » : une fiche pleine de
/// tirets donne l'impression d'un produit vide.
private struct Row: View {
    let label: String
    let value: String?
    var body: some View {
        if let value {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).multilineTextAlignment(.trailing)
            }
            .font(.callout)
        }
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct EnergySection: View {
    let building: JSONValue
    let officialDPE: JSONValue?

    var body: some View {
        let energy = building["energy"]
        let cls = energy?["dpe_class"]?.stringValue
        SectionBox(title: t("section_energy")) {
            HStack(spacing: 12) {
                Text(cls ?? "?")
                    .font(.title2.bold()).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(DPE.color(cls), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    // Un « ? » nu n'explique rien : on dit ce qu'il signifie.
                    Text(cls.map { t("dpe_class", $0) } ?? t("dpe_missing"))
                        .font(.callout.weight(.medium))
                    if cls == nil {
                        Text(t("dpe_none_published"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let kwh = energy?["consumption_kwh_m2y"]?.doubleValue {
                        Text(t("unit_kwh_m2y", Int(kwh))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let ban = energy?["rental_ban"]?["rental_ban_date"]?.stringValue {
                Text(t("rental_ban", String(ban.prefix(4))))
                    .font(.callout).foregroundStyle(.orange)
            }
            Row(label: t("ghg"), value: energy?["ghg_kgco2_m2y"]?.doubleValue.map { t("unit_ghg", Int($0)) })
            Row(label: t("dpe_date"), value: energy?["dpe_date"]?.stringValue.map { String($0.prefix(10)) })
            Row(label: t("dpe_number"), value: officialDPE?["dpe_number"]?.stringValue)
            Row(label: t("living_area"),
                value: officialDPE?["surface_habitable_m2"]?.doubleValue.map { t("unit_m2", Int($0)) })
            Row(label: t("annual_cost"),
                value: officialDPE?["annual_cost_eur"]?.doubleValue.map { t("unit_eur_year", Int($0)) })
        }
    }
}

private struct BuildingSection: View {
    let building: JSONValue
    var body: some View {
        SectionBox(title: t("section_building")) {
            Row(label: t("build_year"), value: building["construction_year"]?.intValue.map(String.init))
            Row(label: t("height"), value: building["height_m"]?.doubleValue.map { t("unit_metres", Int($0)) })
            // « Niveaux » et non « Étages » : en français, « 1 étage » se
            // comprend comme rez-de-chaussée + 1, alors que la BDNB compte des
            // niveaux — le rez-de-chaussée inclus. Et à un seul niveau, on dit
            // « de plain-pied » : c'est le mot qu'emploie un acheteur, et un
            // critère décisif pour qui vieillit ou vit avec un handicap.
            Row(label: t("levels"), value: building["floors"]?.intValue.map {
                $0 == 1 ? t("single_storey") : String($0)
            })
            Row(label: t("dwellings"), value: building["dwellings"]?.intValue.map(String.init))
            Row(label: t("walls"), value: building["wall_material"]?.stringValue?.capitalized)
            Row(label: t("roof"), value: building["roof_material"]?.stringValue?.capitalized)
        }
    }
}

private struct RisksSection: View {
    let risks: JSONValue?
    var body: some View {
        let natural = (risks?["risques_naturels"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let techno = (risks?["risques_technologiques"]?.arrayValue ?? []).compactMap { $0.stringValue }
        if !natural.isEmpty || !techno.isEmpty {
            SectionBox(title: t("section_risks")) {
                if !natural.isEmpty {
                    Row(label: t("risks_natural"), value: natural.map(Self.humanize).joined(separator: ", "))
                }
                if !techno.isEmpty {
                    Row(label: t("risks_techno"), value: techno.map(Self.humanize).joined(separator: ", "))
                }
                Row(label: t("clay_hazard"), value: risks?["clay_shrink_swell"]?.stringValue)
            }
        }
    }

    /// Les clés de Géorisques arrivent en langage machine (« retraitGonflementArgile ») :
    /// personne ne doit lire ça dans une fiche.
    static func humanize(_ key: String) -> String {
        // Traduits depuis la CLÉ MACHINE (`inondation`, `seisme`) et non depuis
        // le français affiché : c'est ce qui les rend localisables. Les tables
        // fr/en portent les mêmes clés que côté Android.
        let known = [
            "inondation", "remonteeNappe", "seisme", "mouvementTerrain",
            "retraitGonflementArgile", "feuForet", "radon", "icpe",
            "pollutionSols", "nucleaire", "ruptureBarrage", "risqueMinier",
            "cavite", "avalanche", "canalisationsMatieresDangereuses",
        ]
        if known.contains(key) { return t("risk_" + key) }
        let spaced = key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2",
                                              options: .regularExpression)
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

private struct EnvironmentSection: View {
    let groundwater: JSONValue?
    let solar: JSONValue?
    let water: JSONValue?
    var body: some View {
        let depth = groundwater?["depth_m"]?.doubleValue
        let yield = solar?["yield_kwh_per_kwc_y"]?.doubleValue
        let eff = water?["efficiency_pct"]?.doubleValue
        if depth != nil || yield != nil || eff != nil {
            SectionBox(title: t("section_environment")) {
                Row(label: t("groundwater"), value: depth.map { String(format: "%.1f m", $0) })
                Row(label: t("solar"), value: yield.map { t("unit_solar", Int($0)) })
                Row(label: t("water_efficiency"), value: eff.map { String(format: "%.1f %%", $0) })
                Row(label: t("water_price"), value: water?["price_eur_m3"]?.doubleValue.map {
                    String(format: "%.2f €/m³", $0) })
            }
        }
    }
}

private struct NeighbourhoodSection: View {
    let taxes: JSONValue?
    let schools: JSONValue?
    let prices: JSONValue?
    var body: some View {
        let medians = prices?["commune_eur_m2"]?.objectValue ?? [:]
        let nbSchools = schools?.arrayValue?.count ?? 0
        let tax = taxes?["property_tax_built_pct"]?.doubleValue
        if !medians.isEmpty || nbSchools > 0 || tax != nil {
            SectionBox(title: t("section_area")) {
                ForEach(medians.keys.sorted(), id: \.self) { k in
                    Row(label: t("median_price", k.lowercased()),
                        value: medians[k]?["median"]?.intValue.map { t("unit_eur_m2", $0) })
                }
                Row(label: t("property_tax"), value: tax.map { String(format: "%.2f %%", $0) })
                Row(label: t("waste_tax"),
                    value: taxes?["waste_tax_pct"]?.doubleValue.map { String(format: "%.2f %%", $0) })
                Row(label: t("schools"), value: nbSchools > 0 ? "\(nbSchools)" : nil)
            }
        }
    }
}

private struct IdentitySection: View {
    let building: JSONValue
    let rnb: JSONValue?
    var body: some View {
        SectionBox(title: t("section_ids")) {
            Row(label: t("id_rnb"), value: rnb?["rnb_id"]?.stringValue)
            Row(label: t("id_bdnb"), value: building["bdnb_id"]?.stringValue)
        }
    }
}

enum DPE {
    static func color(_ cls: String?) -> Color {
        switch cls {
        case "A": return Color(red: 0.00, green: 0.56, blue: 0.21)
        case "B": return Color(red: 0.32, green: 0.69, blue: 0.33)
        case "C": return Color(red: 0.65, green: 0.80, blue: 0.45)
        case "D": return Color(red: 0.96, green: 0.91, blue: 0.06)
        case "E": return Color(red: 0.94, green: 0.71, blue: 0.06)
        case "F": return Color(red: 0.92, green: 0.51, blue: 0.21)
        case "G": return Color(red: 0.84, green: 0.13, blue: 0.12)
        default: return Color.gray
        }
    }
}
