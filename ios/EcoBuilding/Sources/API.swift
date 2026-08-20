import Foundation

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

    static func suggest(_ text: String) async throws -> [Suggestion] {
        let (data, _) = try await URLSession.shared.data(
            for: request("suggest", query: [.init(name: "q", value: text)]))
        struct Wrapper: Decodable {
            struct Item: Decodable {
                let label: String, lon: Double, lat: Double
                let ban_id: String?
            }
            let results: [Item]
        }
        let w = try JSONDecoder().decode(Wrapper.self, from: data)
        return w.results.map { .init(label: $0.label, lon: $0.lon, lat: $0.lat, banID: $0.ban_id) }
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

    /// Flux d'une recherche par adresse. Chaque ligne du corps est un événement.
    static func lookupStream(q: String) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(request("lookup/stream", query: [.init(name: "q", value: q)]))
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
            throw QuotaExhausted(message: "Quota atteint")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ecobuilding-\(buildingID).pdf")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
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
