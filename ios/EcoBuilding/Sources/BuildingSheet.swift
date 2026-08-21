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
                case let .block(name, value):
                    blocks[name] = value
                    pending.remove(name)
                case let .done(query, _):
                    address = query["address"]?.stringValue ?? address
                    pending.removeAll()
                case let .failure(status, detail):
                    failure = status == 404
                        ? "Pas de fiche pour ce bâtiment."
                        : (detail.isEmpty ? "Données momentanément indisponibles." : detail)
                    pending.removeAll()
                }
            }
        } catch {
            // Réseau coupé en cours de route : on garde ce qui est déjà affiché
            // et on le dit, plutôt que de vider l'écran.
            if building == nil { failure = "Données momentanément indisponibles." }
            pending.removeAll()
        }
    }
}

struct BuildingSheet: View {
    let target: ContentView.Target
    @StateObject private var model = BuildingModel()

    var body: some View {
      VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.searched ?? model.address ?? "Bâtiment").font(.title3.bold())
                // Le groupe BDNB porte parfois une autre adresse principale :
                // la dire, plutôt que de laisser croire à une erreur.
                if let principal = model.address, let searched = model.searched,
                   principal.caseInsensitiveCompare(searched) != .orderedSame {
                    Text("Adresse principale du bâtiment : \(principal)")
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
                    Text("Encore en cours : " + model.pending
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
            ReportButton(model: model)
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
                .background(.regularMaterial)
        }
      }
      .task { await model.load(target) }
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
        SectionBox(title: "Énergie") {
            HStack(spacing: 12) {
                Text(cls ?? "?")
                    .font(.title2.bold()).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(DPE.color(cls), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    // Un « ? » nu n'explique rien : on dit ce qu'il signifie.
                    Text(cls.map { "Classe DPE \($0)" } ?? "DPE non renseigné")
                        .font(.callout.weight(.medium))
                    if cls == nil {
                        Text("Aucun diagnostic publié pour ce bâtiment")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let kwh = energy?["consumption_kwh_m2y"]?.doubleValue {
                        Text("\(Int(kwh)) kWh/m²/an").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let ban = energy?["rental_ban"]?["rental_ban_date"]?.stringValue {
                Text("⚠ Location interdite à partir de \(ban.prefix(4)) (loi Climat et Résilience)")
                    .font(.callout).foregroundStyle(.orange)
            }
            Row(label: "GES", value: energy?["ghg_kgco2_m2y"]?.doubleValue.map { "\(Int($0)) kgCO₂/m²/an" })
            Row(label: "Date du DPE", value: energy?["dpe_date"]?.stringValue.map { String($0.prefix(10)) })
            Row(label: "N° DPE officiel", value: officialDPE?["dpe_number"]?.stringValue)
            Row(label: "Surface habitable",
                value: officialDPE?["surface_habitable_m2"]?.doubleValue.map { "\(Int($0)) m²" })
            Row(label: "Coût annuel d'énergie",
                value: officialDPE?["annual_cost_eur"]?.doubleValue.map { "\(Int($0)) €/an" })
        }
    }
}

private struct BuildingSection: View {
    let building: JSONValue
    var body: some View {
        SectionBox(title: "Bâtiment") {
            Row(label: "Année de construction", value: building["construction_year"]?.intValue.map(String.init))
            Row(label: "Hauteur", value: building["height_m"]?.doubleValue.map { "\(Int($0)) m" })
            // « Niveaux » et non « Étages » : en français, « 1 étage » se
            // comprend comme rez-de-chaussée + 1, alors que la BDNB compte des
            // niveaux — le rez-de-chaussée inclus.
            Row(label: "Niveaux", value: building["floors"]?.intValue.map(String.init))
            Row(label: "Logements", value: building["dwellings"]?.intValue.map(String.init))
            Row(label: "Murs", value: building["wall_material"]?.stringValue?.capitalized)
            Row(label: "Toiture", value: building["roof_material"]?.stringValue?.capitalized)
        }
    }
}

private struct RisksSection: View {
    let risks: JSONValue?
    var body: some View {
        let natural = (risks?["risques_naturels"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let techno = (risks?["risques_technologiques"]?.arrayValue ?? []).compactMap { $0.stringValue }
        if !natural.isEmpty || !techno.isEmpty {
            SectionBox(title: "Risques (Géorisques)") {
                if !natural.isEmpty {
                    Row(label: "Naturels", value: natural.map(Self.humanize).joined(separator: ", "))
                }
                if !techno.isEmpty {
                    Row(label: "Technologiques", value: techno.map(Self.humanize).joined(separator: ", "))
                }
                Row(label: "Argiles", value: risks?["clay_shrink_swell"]?.stringValue)
            }
        }
    }

    /// Les clés de Géorisques arrivent en langage machine (« retraitGonflementArgile ») :
    /// personne ne doit lire ça dans une fiche.
    static func humanize(_ key: String) -> String {
        let known = [
            "inondation": "Inondation", "remonteeNappe": "Remontée de nappe",
            "seisme": "Séisme", "mouvementTerrain": "Mouvement de terrain",
            "retraitGonflementArgile": "Retrait-gonflement des argiles",
            "feuForet": "Feu de forêt", "radon": "Radon", "icpe": "ICPE",
            "pollutionSols": "Pollution des sols", "nucleaire": "Nucléaire",
            "ruptureBarrage": "Rupture de barrage", "risqueMinier": "Risque minier",
            "cavite": "Cavité souterraine", "avalanche": "Avalanche",
            "canalisationsMatieresDangereuses": "Canalisations (matières dangereuses)",
        ]
        if let v = known[key] { return v }
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
            SectionBox(title: "Environnement") {
                Row(label: "Nappe phréatique", value: depth.map { String(format: "%.1f m", $0) })
                Row(label: "Productible solaire", value: yield.map { "\(Int($0)) kWh/an par kWc" })
                Row(label: "Rendement du réseau d'eau", value: eff.map { String(format: "%.1f %%", $0) })
                Row(label: "Prix de l'eau", value: water?["price_eur_m3"]?.doubleValue.map {
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
            SectionBox(title: "Quartier") {
                ForEach(medians.keys.sorted(), id: \.self) { k in
                    Row(label: "Médiane \(k.lowercased())",
                        value: medians[k]?["median"]?.intValue.map { "\($0) €/m²" })
                }
                Row(label: "Taxe foncière (bâti)", value: tax.map { String(format: "%.2f %%", $0) })
                Row(label: "Ordures ménagères",
                    value: taxes?["waste_tax_pct"]?.doubleValue.map { String(format: "%.2f %%", $0) })
                Row(label: "Écoles à proximité", value: nbSchools > 0 ? "\(nbSchools)" : nil)
            }
        }
    }
}

private struct IdentitySection: View {
    let building: JSONValue
    let rnb: JSONValue?
    var body: some View {
        SectionBox(title: "Identifiants") {
            Row(label: "ID-RNB", value: rnb?["rnb_id"]?.stringValue)
            Row(label: "ID BDNB", value: building["bdnb_id"]?.stringValue)
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
