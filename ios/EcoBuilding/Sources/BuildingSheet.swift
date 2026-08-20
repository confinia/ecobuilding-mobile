import SwiftUI

/// Fiche d'un bâtiment, remplie **au fil de l'eau**.
///
/// Le serveur émet le bâtiment dès que la BDNB a répondu (~0,6 s), puis un
/// événement par source. On affiche donc immédiatement ce qu'on sait, et on
/// complète — au lieu d'attendre la source la plus lente, qui met plus de 5 s.
/// Ce qui manque encore est annoncé, jamais masqué.
@MainActor
final class BuildingModel: ObservableObject {
    @Published var address: String?
    @Published var building: JSONValue?
    @Published var blocks: [String: JSONValue] = [:]
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

    func load(buildingID: String, lon: Double, lat: Double) async {
        let stream = buildingID.isEmpty
            ? API.lookupStream(q: "\(lat),\(lon)")
            : API.buildingStream(id: buildingID, lon: lon, lat: lat)
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
    let buildingID: String
    let lon: Double
    let lat: Double
    @StateObject private var model = BuildingModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.address ?? "Bâtiment")
                    .font(.title3.bold())

                if let failure = model.failure {
                    Text(failure).foregroundStyle(.secondary)
                } else if let b = model.building {
                    DPEBadge(building: b)
                    Rows(building: b, blocks: model.blocks)
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
        .task { await model.load(buildingID: buildingID, lon: lon, lat: lat) }
    }
}

private struct DPEBadge: View {
    let building: JSONValue
    var body: some View {
        let cls = building["energy"]?["dpe_class"]?.stringValue
        HStack(spacing: 10) {
            Text(cls ?? "?")
                .font(.title2.bold()).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Self.color(cls), in: RoundedRectangle(cornerRadius: 10))
            if let kwh = building["energy"]?["consumption_kwh_m2y"]?.doubleValue {
                Text("\(Int(kwh)) kWh/m²/an").foregroundStyle(.secondary)
            }
        }
    }

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

/// Les lignes réellement disponibles, et rien d'autre : une valeur absente
/// disparaît au lieu d'afficher « — », qui donne l'impression d'un produit vide.
private struct Rows: View {
    let building: JSONValue
    let blocks: [String: JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Année de construction", building["construction_year"]?.intValue.map(String.init))
            row("Hauteur", building["height_m"]?.doubleValue.map { "\(Int($0)) m" })
            row("Logements", building["dwellings"]?.intValue.map(String.init))
            if let ban = building["energy"]?["rental_ban"]?["rental_ban_date"]?.stringValue {
                Text("⚠ Location interdite à partir de \(ban.prefix(4))")
                    .font(.callout).foregroundStyle(.orange)
            }
            row("ID-RNB", blocks["rnb"]?["rnb_id"]?.stringValue)
            if let med = blocks["prices"]?["commune_eur_m2"]?.objectValue {
                ForEach(med.keys.sorted(), id: \.self) { k in
                    row("Médiane \(k.lowercased())",
                        med[k]?["median"]?.intValue.map { "\($0) €/m²" })
                }
            }
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
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
