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

    /* Pourquoi il n'y a pas de bâtiment — et non « données indisponibles ».
     *
     * Sans ce champ, une adresse sans bâtiment BDNB laissait `failure` et
     * `building` tous deux nils, et le rendu tombait sur `ProgressView` : la
     * fiche tournait indéfiniment sur une adresse parfaitement valide. C'est
     * le cas de TOUTE l'outre-mer, où la BDNB n'a aucun bâtiment. */
    @Published var sansBatiment: String?

    // Les blocs que le serveur émet (confinia/ecobuilding, `/v1/buildings/{id}/stream`).
    // `urbanisme` (PLU, #376) et `ppri` (#377) arrivaient déjà en 1.0 et étaient
    // ignorés : l'app affichait moins que le web pour la même adresse.
    static let expected = ["area_risks", "groundwater", "solar_pv", "water_network",
                           "official_dpe", "local_taxes", "schools", "prices", "rnb",
                           "commune", "dpe_spread", "urbanisme", "ppri", "construction"]
    static let labels = [
        "area_risks": "Risques", "groundwater": "Nappe phréatique",
        "solar_pv": "Solaire", "water_network": "Eau potable",
        "official_dpe": "DPE officiel", "local_taxes": "Fiscalité locale",
        "schools": "Écoles", "prices": "Prix de vente", "rnb": "ID-RNB",
        "commune": t("block_commune"), "dpe_spread": t("block_dpe_spread"),
        "urbanisme": t("block_urbanisme"), "ppri": t("block_ppri"),
        "construction": t("block_construction"),
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
                case let .core(query, buildings, noBuilding):
                    address = query["address"]?.stringValue
                    building = buildings.first
                    sansBatiment = building == nil
                        ? (noBuilding?["text"]?.stringValue ?? t("no_building_here"))
                        : nil
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
                    EnergySection(building: b, officialDPE: model.blocks["official_dpe"],
                                  spread: model.blocks["dpe_spread"], model: model)
                    BuildingSection(building: b, construction: model.blocks["construction"])
                    RisksSection(risks: model.blocks["area_risks"], ppri: model.blocks["ppri"])
                    UrbanismeSection(plu: model.blocks["urbanisme"], lon: model.lon, lat: model.lat)
                    EnvironmentSection(groundwater: model.blocks["groundwater"],
                                       solar: model.blocks["solar_pv"],
                                       water: model.blocks["water_network"])
                    NeighbourhoodSection(taxes: model.blocks["local_taxes"],
                                         schools: model.blocks["schools"],
                                         prices: model.blocks["prices"])
                    CommuneSection(commune: model.blocks["commune"])
                    IdentitySection(building: b, rnb: model.blocks["rnb"])
                } else if let sansBatiment = model.sansBatiment {
                    // Le motif AVANT l'attente : sinon on tourne sur une adresse
                    // dont on sait déjà qu'elle n'aura jamais de bâtiment.
                    Text(sansBatiment).foregroundStyle(.secondary)
                    RisksSection(risks: model.blocks["area_risks"])
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
    var spread: JSONValue? = nil
    var model: BuildingModel? = nil
    @State private var enCours: String?
    @State private var ficheLogement: URL?

    var body: some View {
        let energy = building["energy"]
        let cls = energy?["dpe_class"]?.stringValue
        /* Le badge dit l'ÉVENTAIL quand les logements de l'immeuble diffèrent.
         *
         * Une grosse lettre colorée a l'air catégorique, et le lecteur pressé
         * ne voit qu'elle. Mesuré : dès qu'une adresse porte plusieurs
         * diagnostics, deux fois sur trois les classes diffèrent — la lettre
         * affirmait donc une certitude fausse pour presque tous les logements. */
        let basse = spread?["classe_min"]?.stringValue
        let haute = spread?["classe_max"]?.stringValue
        let identiques = spread?["identiques"]?.boolValue ?? true
        let eventail = !identiques && basse != nil && haute != nil
        /* VALIDITÉ (confinia/ecobuilding#414) : un DPE vaut dix ans, et ceux
         * d'avant la réforme du 1er juillet 2021 sont tous sans valeur depuis
         * le 1er janvier 2025. Un DPE périmé garde sa lettre — c'est l'histoire
         * du bâtiment — mais en GRIS : une lettre colorée affirme une classe
         * opposable, et celle-ci ne l'est plus. Même règle que `dpe-validite.js`
         * côté web ; les dates ISO se comparent comme des chaînes. */
        let etabli = officialDPE?["established_on"]?.stringValue ?? energy?["dpe_date"]?.stringValue
        let valable = officialDPE?["valid_until"]?.stringValue ?? energy?["dpe_valid_until"]?.stringValue
        let aujourdhui = Self.isoToday
        let avantReforme = etabli.map { String($0.prefix(10)) < "2021-07-01" } ?? false
        let perime = cls != nil && (avantReforme || valable.map { String($0.prefix(10)) < aujourdhui } == true)
        SectionBox(title: t("section_energy")) {
            HStack(spacing: 12) {
                Text(eventail ? "\(basse!)–\(haute!)" : (cls ?? "?"))
                    .font(eventail ? .caption.bold() : .title2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        eventail
                            ? AnyShapeStyle(LinearGradient(
                                colors: [DPE.color(basse), DPE.color(haute)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(DPE.color(cls)),
                        in: RoundedRectangle(cornerRadius: 10))
                    .saturation(perime ? 0 : 1)
                    .opacity(perime ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    // Un « ? » nu n'explique rien : on dit ce qu'il signifie.
                    Text(cls.map { t("dpe_class", $0) } ?? t("dpe_missing"))
                        .font(.callout.weight(.medium))
                    if perime {
                        Text(avantReforme ? t("dpe_pre_reform")
                             : valable.map { t("dpe_expired_since", Self.fmtDate($0)) } ?? t("dpe_expired"))
                            .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                    if eventail {
                        Text(t("dpe_spread_range",
                               Int(spread?["diagnostics"]?.doubleValue ?? 0),
                               basse!, haute!))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if cls == nil {
                        Text(t("dpe_none_published"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let kwh = energy?["consumption_kwh_m2y"]?.doubleValue {
                        Text(t("unit_kwh_m2y", Int(kwh))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            /* L'interdiction de location au PASSÉ quand elle court déjà : « à
             * partir du 2025-01-01 » lu en 2026 se comprend comme un futur. Et
             * pour A–E, le dire POSITIVEMENT : le silence laissait croire qu'on
             * n'avait pas regardé. */
            if let ban = energy?["rental_ban"]?["rental_ban_date"]?.stringValue {
                let date = String(ban.prefix(10))
                Text(date <= aujourdhui ? t("rental_ban_since", Self.fmtDate(date))
                                        : t("rental_ban", String(ban.prefix(4))))
                    .font(.callout).foregroundStyle(.orange)
                if perime {
                    Text(t("rental_ban_expired_note")).font(.caption).foregroundStyle(.secondary)
                }
            } else if let cls, ["A", "B", "C", "D", "E"].contains(cls) {
                Text(t(perime ? "no_rental_ban_expired" : "no_rental_ban", cls))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Row(label: t("ghg"), value: energy?["ghg_kgco2_m2y"]?.doubleValue.map { t("unit_ghg", Int($0)) })
            Row(label: t("dpe_date"), value: etabli.map { Self.fmtDate($0) })
            Row(label: t("dpe_valid_until"), value: valable.map { Self.fmtDate($0) })
            Row(label: t("dpe_number"), value: officialDPE?["dpe_number"]?.stringValue)
            // Le DPE OFFICIEL est chez l'ADEME (confinia/ecobuilding#418) : la
            // fiche EcoBuilding n'en est pas un, et le lien par numéro y mène
            // sans recopier quoi que ce soit.
            if let numero = officialDPE?["dpe_number"]?.stringValue,
               let url = URL(string: "https://observatoire-dpe-audit.ademe.fr/afficher-dpe/\(numero)") {
                Link(destination: url) {
                    Label(t("dpe_official_link"), systemImage: "arrow.up.right.square")
                        .font(.callout)
                }
            }
            Row(label: t("living_area"),
                value: officialDPE?["surface_habitable_m2"]?.doubleValue.map { t("unit_m2", Int($0)) })
            Row(label: t("annual_cost"),
                value: officialDPE?["annual_cost_eur"]?.doubleValue.map { t("unit_eur_year", Int($0)) })

            /* Les logements diagnostiqués, en lignes COMPACTES (#22) : classe,
             * surface, coût — le détail complet vit dans la fiche PDF ciblée
             * (décision opérateur : « less info at first, and then all in
             * PDF »). */
            if let model, let logements = spread?["logements"]?.arrayValue,
               logements.count >= 2 {
                Divider()
                ForEach(Array(logements.enumerated()), id: \.offset) { _, l in
                    if let numero = l["numero_dpe"]?.stringValue {
                        HStack(spacing: 8) {
                            Text(l["classe"]?.stringValue ?? "?")
                                .font(.caption.bold()).foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(DPE.color(l["classe"]?.stringValue),
                                            in: RoundedRectangle(cornerRadius: 5))
                            Text([l["surface_m2"]?.doubleValue.map { t("unit_m2_txt", Self.fmtSurface($0)) },
                                  l["cout_annuel_eur"]?.doubleValue.map { t("unit_eur_year", Int($0)) }]
                                .compactMap(\.self).joined(separator: " · "))
                                .font(.footnote)
                            Spacer()
                            if enCours == numero {
                                ProgressView().controlSize(.small)
                            } else {
                                Button {
                                    telecharge(numero: numero, model: model)
                                } label: {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(Color(red: 0.17, green: 0.48, blue: 0.29))
                                }
                                .disabled(enCours != nil)
                                .accessibilityLabel(t("report_this_dwelling"))
                            }
                        }
                    }
                }
            }
        }
        .fullScreenCover(item: $ficheLogement) { url in PDFPreview(url: url) }
    }

    private func telecharge(numero: String, model: BuildingModel) {
        guard let id = model.buildingID else { return }
        enCours = numero
        Task {
            defer { enCours = nil }
            if let url = try? await API.report(buildingID: id, lon: model.lon,
                                               lat: model.lat, dpe: numero) {
                ficheLogement = url
            }
        }
    }

    /// 15.6 -> « 15,6 » ; 57.0 -> « 57 » : la surface telle qu'une annonce l'écrit.
    private static func fmtSurface(_ m2: Double) -> String {
        m2 == m2.rounded() ? String(Int(m2))
            : String(format: "%.1f", m2).replacingOccurrences(of: ".", with: ",")
    }

    /// « 2026-09-10 » : la forme dans laquelle le serveur écrit ses dates, et
    /// dans laquelle elles se comparent.
    static var isoToday: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Une date ISO du serveur dans la langue de l'écran (« 5 sept. 2031 »),
    /// ou telle quelle si elle ne se lit pas.
    static func fmtDate(_ iso: String) -> String {
        let jour = String(iso.prefix(10))
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: jour) else { return jour }
        return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .none)
    }
}

private struct BuildingSection: View {
    let building: JSONValue
    var construction: JSONValue?
    var body: some View {
        // L'année vient des Fichiers fonciers, au niveau de la PARCELLE : une
        // extension déclarée la remplace (confinia/ecobuilding#432). On dit
        // d'où elle vient, ce que disent les diagnostiqueurs, et le permis
        // quand c'est lui qui explique l'écart.
        let c = construction
        let annee = c?["year"]?.intValue ?? building["construction_year"]?.intValue
        let dpeAnnees = c?["dpe_years"]?.arrayValue?.compactMap { $0.intValue } ?? []
        let permis = c?["permit"]
        let caveat = c?["caveat"]?.stringValue
        SectionBox(title: t("section_building")) {
            Row(label: t("build_year"),
                value: annee.map { c == nil ? String($0) : t("build_year_ffo", String($0)) })
            if dpeAnnees.count == 2 {
                let span = dpeAnnees[0] == dpeAnnees[1]
                    ? (c?["dpe_period"]?.stringValue ?? String(dpeAnnees[0]))
                    : "\(dpeAnnees[0])–\(dpeAnnees[1])"
                let n = c?["dpe_count"]?.intValue ?? 0
                let qui = n > 1 ? t("build_dpe_n", n) : t("build_dpe_one")
                Row(label: t("build_dpe_period"),
                    value: caveat == "dpe_disagrees" ? t("build_dpe_disagrees", span, qui) : "\(span) (\(qui))")
            }
            if caveat == "works", let y = permis?["first_year"]?.intValue {
                let kind = (permis?["raised"]?.boolValue ?? false) ? t("build_works_raised")
                    : (permis?["extension"]?.boolValue ?? false) ? t("build_works_extension")
                    : t("build_works_existing")
                Text(t("build_works_caveat", kind, String(y)))
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let y = c?["works_since"]?.intValue {
                Row(label: t("build_permit"), value: t("build_works_since", String(y)))
            }
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
    var ppri: JSONValue? = nil
    var body: some View {
        let natural = (risks?["risques_naturels"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let techno = (risks?["risques_technologiques"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let codePPRI = ppri?["code"]?.stringValue
        let inondable = natural.contains { $0.lowercased().contains("inond") }
        if !natural.isEmpty || !techno.isEmpty || codePPRI != nil {
            SectionBox(title: t("section_risks")) {
                if !natural.isEmpty {
                    Row(label: t("risks_natural"), value: natural.map(Self.humanize).joined(separator: ", "))
                }
                if !techno.isEmpty {
                    Row(label: t("risks_techno"), value: techno.map(Self.humanize).joined(separator: ", "))
                }
                Row(label: t("clay_hazard"), value: risks?["clay_shrink_swell"]?.stringValue)
                /* Le zonage PPRI en BLEU / ROUGE (confinia/ecobuilding#377) : la
                 * couleur que l'agent cherche pendant une estimation. Sans PPRI
                 * cartographié mais en zone inondable selon Géorisques, on le dit
                 * sans inventer de couleur. */
                if let codePPRI {
                    let couleur = ppri?["couleur"]?.stringValue
                    let libelle = couleur == "bleue" ? t("ppri_bleue")
                                : couleur == "rouge" ? t("ppri_rouge") : codePPRI
                    HStack(alignment: .firstTextBaseline) {
                        Text(t("ppri")).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(libelle).fontWeight(.semibold)
                            .foregroundStyle(couleur == "rouge" ? Color.red
                                             : couleur == "bleue" ? Color.blue : Color.primary)
                    }
                    .font(.callout)
                    if let nom = ppri?["nom_ppr"]?.stringValue {
                        Text(nom).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let lien = ppri?["url_reglement"]?.stringValue, let url = URL(string: lien) {
                        Link(destination: url) {
                            Label(t("ppri_regulation"), systemImage: "arrow.up.right.square").font(.callout)
                        }
                    }
                } else if inondable {
                    Text(t("ppri_uncharted")).font(.caption).foregroundStyle(.secondary)
                }
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

/// La zone du PLU (confinia/ecobuilding#376), depuis le Géoportail de
/// l'Urbanisme. N'apparaît QUE si une zone numérisée couvre le point : une
/// parcelle sans zone n'affiche rien, jamais « aucune contrainte ».
private struct UrbanismeSection: View {
    let plu: JSONValue?
    var lon: Double? = nil
    var lat: Double? = nil
    var body: some View {
        if let libelle = plu?["libelle"]?.stringValue {
            let long = plu?["libelong"]?.stringValue
            let type = plu?["typezone"]?.stringValue
            SectionBox(title: t("section_urbanisme")) {
                Row(label: t("plu_zone"), value: long.map { "\(libelle) — \($0)" } ?? libelle)
                Row(label: t("plu_zone_type"),
                    value: type.flatMap { ["U", "AU", "A", "N"].contains($0) ? t("plu_type_" + $0) : nil })
                if let lon, let lat,
                   let url = URL(string: "https://www.geoportail-urbanisme.gouv.fr/map/#tile=1&lon=\(lon)&lat=\(lat)&zoom=18") {
                    Link(destination: url) {
                        Label(t("plu_gpu_link"), systemImage: "arrow.up.right.square").font(.callout)
                    }
                }
            }
        }
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

/// La commune au sens CIVIL, et le nom qu'elle portait avant (#275).
///
/// Un acte ancien nomme parfois une commune qui n'existe plus. Et quand rien
/// n'a bougé, le dire — daté et sourcé — vaut aussi la peine.
///
/// Les réserves de la source sont reprises, jamais résumées : répéter ses
/// chiffres sans ses réserves affirmerait plus qu'elle.
private struct CommuneSection: View {
    let commune: JSONValue?
    var body: some View {
        if let nom = commune?["nom"]?.stringValue {
            let code = commune?["code"]?.stringValue
            let encore = commune?["existe_encore"]?.boolValue ?? true
            let avant = commune?["precedent"]
            let reserves = (commune?["limites"]?.arrayValue ?? []).compactMap { $0.stringValue }
                + (commune?["non_etablis"]?.arrayValue ?? []).compactMap { $0["texte"]?.stringValue }
            SectionBox(title: t("section_commune")) {
                Row(label: t("commune_name"), value: code.map { "\(nom) (\($0))" } ?? nom)
                // La date de FIN quand la commune a cessé d'exister, et non
                // celle de début : la fiche annonçait « a cessé d'exister le
                // 1ᵉʳ janvier 1870 » en affichant le commencement de la version.
                Row(label: encore ? t("commune_since") : t("commune_ended"),
                    value: commune?[encore ? "depuis_fr" : "jusqu_au_fr"]?.stringValue)
                if let n = avant?["nom"]?.stringValue {
                    Row(label: t("commune_before"),
                        value: avant?["jusqu_au_fr"]?.stringValue.map { t("commune_until", n, $0) } ?? n)
                }
                Row(label: t("commune_asof"), value: commune?["arret_des_donnees_fr"]?.stringValue)
                if !reserves.isEmpty {
                    Text(reserves.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct NeighbourhoodSection: View {
    let taxes: JSONValue?
    let schools: JSONValue?
    let prices: JSONValue?
    /// DVF nomme le bien en français (« Appartement », « Maison ») ; l'écran
    /// anglais lisait « Median price (appartement) » (confinia/ecobuilding#450).
    static func typeLocal(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "appartement": return t("local_apartment")
        case "maison": return t("local_house")
        default: return raw ?? "?"
        }
    }

    static func taxHeadline(_ taxes: JSONValue?, _ levelKey: String, _ rankKey: String) -> String? {
        guard let level = taxes?[levelKey]?.stringValue,
              let rank = taxes?[rankKey]?.doubleValue else { return nil }
        return t("tax_headline", t("tax_level_" + level), Int(rank))
    }

    var body: some View {
        let medians = prices?["commune_eur_m2"]?.objectValue ?? [:]
        // Les trois dernières VENTES du bâtiment (DVF), comme sur le web : la
        // première chose qu'un agent demande (« vendu ? à quel prix ? »), et
        // que les apps taisaient en n'affichant que les médianes communales.
        let ventes = Array((prices?["sales"]?.arrayValue ?? []).prefix(3))
        let nbSchools = schools?.arrayValue?.count ?? 0
        let tax = taxes?["property_tax_built_pct"]?.doubleValue
        if !medians.isEmpty || nbSchools > 0 || tax != nil || !ventes.isEmpty {
            SectionBox(title: t("section_area")) {
                ForEach(Array(ventes.enumerated()), id: \.offset) { _, v in
                    if let prix = v["valeur_fonciere"]?.doubleValue {
                        let quand = v["date"]?.stringValue.map { EnergySection.fmtDate($0) } ?? "?"
                        let type = Self.typeLocal(v["type_local"]?.stringValue)
                        let surface = v["surface_m2"]?.doubleValue.map { t("unit_m2", Int($0)) } ?? "—"
                        Row(label: t("sale_line", quand, type, surface),
                            value: t("unit_eur", Self.fmtEuros(prix)))
                    }
                }
                ForEach(medians.keys.sorted(), id: \.self) { k in
                    Row(label: t("median_price", Self.typeLocal(k).lowercased()),
                        value: medians[k]?["median"]?.intValue.map { t("unit_eur_m2", $0) })
                }
                // Le taux voté seul ne parle à personne (#439) : d'abord la
                // position parmi les communes de France, le taux en dessous.
                Row(label: t("property_tax"),
                    value: Self.taxHeadline(taxes, "property_tax_level", "property_tax_rank_pct"))
                Row(label: t("waste_tax"),
                    value: Self.taxHeadline(taxes, "waste_tax_level", "waste_tax_rank_pct"))
                Row(label: t("property_tax_rate"), value: tax.map { String(format: "%.2f %%", $0) })
                Row(label: t("waste_tax_rate"),
                    value: taxes?["waste_tax_pct"]?.doubleValue.map { String(format: "%.2f %%", $0) })
                Row(label: t("schools"), value: nbSchools > 0 ? "\(nbSchools)" : nil)
            }
        }
    }

    /// 345000 -> « 345 000 » (séparateur de la langue de l'écran).
    private static func fmtEuros(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(Int(v))
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
