import Foundation
import Security

/// Identifiant d'INSTALLATION, envoyé en en-tête `X-Install-Id`.
///
/// C'est lui qui porte le quota des 3 fiches offertes (MOBILE.md §5.2.1). Il ne
/// peut pas être remplacé par l'adresse IP : sur réseau mobile, des milliers
/// d'abonnés d'un même opérateur la partagent, et les fiches offertes d'un
/// utilisateur seraient consommées par de parfaits inconnus.
///
/// Ce n'est **pas** de l'authentification : réinstaller l'app remet le compteur
/// à zéro. C'est assumé — l'enjeu vaut 0,99 €, et un contrôle plus dur coûterait
/// plus en adhésion qu'il ne rapporterait.
///
/// Stocké dans le trousseau plutôt que dans les réglages, pour deux raisons :
/// il survit à une restauration de sauvegarde, et il n'est pas lisible par une
/// autre app.
enum InstallID {
    private static let service = "io.confinia.ecobuilding"
    private static let account = "install-id"

    /// Identifiant courant, créé au premier appel.
    static var current: String = {
        if let existing = read() { return existing }
        let fresh = UUID().uuidString
        write(fresh)
        return fresh
    }()

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func write(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            // L'app doit pouvoir lire l'identifiant appareil verrouillé (une
            // fiche peut se télécharger en arrière-plan), mais il ne doit pas
            // se propager vers un autre appareil par iCloud : ce serait deux
            // installations partageant un même quota.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}
