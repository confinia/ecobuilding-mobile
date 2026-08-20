import Foundation

/// Valeur JSON dynamique.
///
/// La fiche d'un bâtiment agrège neuf sources ouvertes dont la forme évolue au
/// rythme des producteurs de données (BDNB, Géorisques, Hub'Eau, ADEME…). Des
/// structures Swift figées obligeraient à publier une version de l'app à chaque
/// champ ajouté côté serveur — et casseraient l'affichage pour tous les
/// utilisateurs qui n'auraient pas mis à jour. On décode donc librement, et
/// l'écran ne lit que ce qu'il sait afficher.
indirect enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "valeur JSON non reconnue")
        }
    }

    // Accès tolérants : un champ absent ou d'un autre type renvoie nil plutôt
    // que de faire échouer tout l'affichage.
    var objectValue: [String: JSONValue]? { if case let .object(v) = self { return v }; return nil }
    var arrayValue: [JSONValue]? { if case let .array(v) = self { return v }; return nil }
    var stringValue: String? { if case let .string(v) = self { return v }; return nil }
    var doubleValue: Double? {
        switch self {
        case let .number(v): return v
        case let .string(v): return Double(v)
        default: return nil
        }
    }
    var intValue: Int? { doubleValue.map(Int.init) }
    var boolValue: Bool? { if case let .bool(v) = self { return v }; return nil }
    var isEmpty: Bool {
        switch self {
        case .null: return true
        case let .array(v): return v.isEmpty
        case let .object(v): return v.isEmpty
        case let .string(v): return v.isEmpty
        default: return false
        }
    }

    /// Accès par chemin : `data["energy"]?["dpe_class"]`.
    subscript(key: String) -> JSONValue? { objectValue?[key] }
    subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, a.indices.contains(index) else { return nil }
        return a[index]
    }
}
