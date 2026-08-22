import CoreLocation
import Foundation

extension ISO8601DateFormatter {
    /// Le serveur peut inclure des fractions de seconde selon la plateforme.
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Client de l'API EcoBuilding (`/v1`).
///
/// L'app ne calcule rien : toute l'intelligence métier est côté serveur, et les
/// prix eux-mêmes viennent de `/v1/config` — on n'écrit jamais un tarif en dur
/// (même règle que sur le web, où chaque montant codé en dur a fini par mentir).
enum API {
    static let base = URL(string: "https://ecobuilding.confinia.io/api/v1")!

    private static func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.setValue(InstallID.current, forHTTPHeaderField: "X-Install-Id")
        return req
    }

    // MARK: - Recherche d'adresse

    struct Suggestion: Decodable, Identifiable, Hashable {
        let label: String
        let lon: Double
        let lat: Double
        let banID: String?
        var id: String { banID ?? "\(lon),\(lat)" }
    }

    /// Suggestions d'adresses, CLASSÉES PAR PROXIMITÉ quand la position est
    /// connue. L'usage mobile est local : on est devant le bâtiment, ou on
    /// prépare une visite dans le quartier. Sans ce repère, chercher « ecole »
    /// proposait des écoles de toute la France.
    static func suggest(_ text: String,
                        near: CLLocationCoordinate2D? = nil) async throws -> [Suggestion] {
        var query = [URLQueryItem(name: "q", value: text)]
        if let near, CLLocationCoordinate2DIsValid(near) {
            query.append(.init(name: "lat", value: String(near.latitude)))
            query.append(.init(name: "lon", value: String(near.longitude)))
        }
        let (data, _) = try await URLSession.shared.data(for: request("suggest", query: query))
        // La clé est « suggestions » : elle était lue comme « results », donc le
        // décodage échouait TOUJOURS — et un try? avalait l'erreur, ce qui
        // donnait une liste vide sans le moindre signe de panne.
        struct Wrapper: Decodable {
            struct Item: Decodable {
                let label: String, lon: Double, lat: Double
                let ban_id: String?
            }
            let suggestions: [Item]
        }
        let w = try JSONDecoder().decode(Wrapper.self, from: data)
        return w.suggestions.map { .init(label: $0.label, lon: $0.lon, lat: $0.lat, banID: $0.ban_id) }
    }

    // MARK: - Fiche bâtiment, AU FIL DE L'EAU

    /// Un événement du flux NDJSON (`/v1/lookup/stream`).
    ///
    /// Neuf sources ouvertes sont interrogées par bâtiment ; attendre la plus
    /// lente laissait l'utilisateur devant un écran vide plusieurs secondes
    /// (mesuré : 5,7 s côté web avant ce flux, contre 0,6 s pour le bâtiment).
    /// L'app affiche donc le bâtiment dès qu'il arrive, puis chaque bloc à son
    /// tour.
    enum StreamEvent {
        case core(query: [String: JSONValue], buildings: [JSONValue])
        case block(name: String, value: JSONValue)
        case done(query: [String: JSONValue], sources: [String])
        case failure(status: Int, detail: String)
    }

    /// Flux d'une recherche par adresse libre (ce que l'utilisateur a tapé).
    static func lookupStream(q: String) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(request("lookup/stream", query: [.init(name: "q", value: q)]))
    }

    /// Flux d'une suggestion CHOISIE : on tient déjà l'identifiant BAN et le
    /// point, inutile de refaire géocoder un libellé — et surtout, il ne faut
    /// pas envoyer « latitude,longitude » dans un champ qui attend une adresse.
    static func lookupStream(banID: String, lon: Double, lat: Double)
        -> AsyncThrowingStream<StreamEvent, Error>
    {
        stream(request("lookup/stream", query: [
            .init(name: "ban_id", value: banID),
            .init(name: "lon", value: String(lon)),
            .init(name: "lat", value: String(lat)),
        ]))
    }

    /// Flux d'un bâtiment déjà identifié (touche sur la carte).
    static func buildingStream(id: String, lon: Double, lat: Double)
        -> AsyncThrowingStream<StreamEvent, Error>
    {
        stream(request("buildings/\(id)/stream", query: [
            .init(name: "lon", value: String(lon)),
            .init(name: "lat", value: String(lat)),
        ]))
    }

    private static func stream(_ req: URLRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        continuation.yield(.failure(status: http.statusCode, detail: ""))
                        continuation.finish()
                        return
                    }
                    // NDJSON : une ligne = un événement. `bytes.lines` respecte
                    // le découpage même si un paquet TCP coupe au milieu.
                    for try await line in bytes.lines {
                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let obj = try? JSONDecoder().decode(JSONValue.self, from: data),
                              case let .object(fields) = obj,
                              case let .string(type)? = fields["type"]
                        else { continue }
                        switch type {
                        case "core":
                            continuation.yield(.core(
                                query: fields["query"]?.objectValue ?? [:],
                                buildings: fields["buildings"]?.arrayValue ?? []))
                        case "block":
                            if case let .string(name)? = fields["name"] {
                                continuation.yield(.block(name: name,
                                                          value: fields["value"] ?? .null))
                            }
                        case "done":
                            continuation.yield(.done(
                                query: fields["query"]?.objectValue ?? [:],
                                sources: (fields["sources"]?.arrayValue ?? [])
                                    .compactMap { $0.stringValue }))
                        case "error":
                            continuation.yield(.failure(
                                status: Int(fields["status"]?.doubleValue ?? 0),
                                detail: fields["detail"]?.stringValue ?? ""))
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Fiche PDF

    /// Télécharge la fiche et renvoie le fichier local (à partager ou à garder
    /// hors ligne). Un 429 signifie « quota épuisé » : l'appelant doit ouvrir le
    /// mur payant, jamais afficher une erreur technique.
    struct QuotaExhausted: Error { let message: String }

    static func report(buildingID: String, lon: Double?, lat: Double?) async throws -> URL {
        var query: [URLQueryItem] = []
        if let lon, let lat {
            query = [.init(name: "lon", value: String(lon)),
                     .init(name: "lat", value: String(lat))]
        }
        let req = request("report/\(buildingID).pdf", query: query)
        let (tmp, response) = try await URLSession.shared.download(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            // Le message vient du SERVEUR : lui seul sait ce qui a été consommé
            // et quand la limite rouvre. « Quota atteint » ne disait rien à
            // personne — ni ce qu'on avait utilisé, ni quand cela repartait.
            let detail = (try? Data(contentsOf: tmp))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0?["detail"] as? String }
            throw QuotaExhausted(message: detail ?? "Vous avez atteint la limite de fiches.")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ecobuilding-\(buildingID).pdf")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: - Quota

    /// Ce qu'il reste, lu AVANT de proposer une fiche.
    struct Quota: Decodable {
        let plan: String
        let reports_used: Int
        let reports_included: Int?      // nul = sans limite
        let reports_left: Int?
        let units: Int?                 // fiches achetées à l'unité
        let period: String?             // "day" ou "month"
        let free_again: [String]?       // bâtiments déjà obtenus, regratuits
        let resets_at: String?          // ISO 8601 : instant de réouverture

        /// « dans 3 heures », « dans 12 minutes ». Une durée se comprend d'un
        /// coup d'œil, là où « demain » ne dit rien à 23 h 50.
        var reopensIn: String? {
            guard let iso = resets_at,
                  let when = ISO8601DateFormatter().date(from: iso)
                    ?? ISO8601DateFormatter.withFractional.date(from: iso)
            else { return nil }
            let seconds = when.timeIntervalSinceNow
            guard seconds > 0 else { return nil }
            if seconds < 3600 {
                let m = max(1, Int(seconds / 60))
                return "dans \(m) minute" + (m > 1 ? "s" : "")
            }
            let h = Int(seconds / 3600)
            return "dans \(h) heure" + (h > 1 ? "s" : "")
        }

        /// Ce qu'on affiche sous le bouton, ou nil quand il n'y a rien à dire.
        ///
        /// `building` permet de signaler qu'une fiche DÉJÀ obtenue ne coûtera
        /// rien : sans ce mot, l'utilisateur qui voit « 2 restantes » hésite à
        /// rouvrir un document qu'il a pourtant déjà payé.
        func summary(for building: String?) -> String? {
            if let b = building, free_again?.contains(b) == true {
                return "Fiche déjà obtenue aujourd'hui — nouveau téléchargement gratuit"
            }
            guard let total = reports_included else { return nil }   // sans limite
            // Sans indication du serveur, on n'invente pas : un vieux serveur
            // compte au MOIS, et annoncer « aujourd'hui » serait faux.
            let when = period == "month" ? "ce mois-ci"
                     : period == "day" ? "aujourd'hui" : ""
            var text: String
            if reports_left == 0 {
                // Un mur doit DIRE quand il rouvre : « limite atteinte » seul
                // laisse croire à un blocage définitif.
                text = "\(total)/\(total)"
                if let again = reopensIn { text += " — la limite repart \(again)" }
            } else {
                // CONSOMMATION, et non solde restant : « 10 bâtiments restants
                // sur 10 » se lisait comme un compteur déjà plein, et alarmait
                // avant même le premier usage.
                text = "\(reports_used)/\(total) fiches"
                if !when.isEmpty { text += " \(when)" }
            }
            if let u = units, u > 0 { text += " · \(u) à l'unité" }
            return text
        }

        /// Le mur est-il atteint ? Sert à le montrer en orange plutôt qu'en gris.
        var blocked: Bool { reports_left == 0 }
    }

    static func quota() async throws -> Quota {
        let (data, _) = try await URLSession.shared.data(for: request("quota"))
        return try JSONDecoder().decode(Quota.self, from: data)
    }

    // MARK: - Offre (jamais de prix en dur dans l'app)

    struct MobileOffer: Decodable {
        struct Tier: Decodable {
            let eur: Double
            let fiches_month: Int?
            let label: String
        }
        let tiers: [String: Tier]
        let unit_eur: Double
        let free_reports: Int
    }

    static func offer() async throws -> MobileOffer {
        let (data, _) = try await URLSession.shared.data(for: request("config"))
        struct Config: Decodable { let mobile: MobileOffer }
        return try JSONDecoder().decode(Config.self, from: data).mobile
    }
}
