import Foundation

/// Accès aux chaînes traduites.
///
/// Les tables `fr.lproj` et `en.lproj` sont ENGENDRÉES depuis les ressources
/// Android : mêmes clés, mêmes textes. Une décision de vocabulaire se prend
/// donc une fois pour les deux applications, et elles ne peuvent pas diverger.
///
/// Le parti retenu : les termes administratifs FRANÇAIS sont conservés avec une
/// glose anglaise. Un DPE n'est pas un EPC britannique — méthode de calcul,
/// échelle et portée juridique diffèrent — et la taxe foncière n'est pas la
/// council tax. Le lecteur apprend le mot qu'il verra sur l'acte notarié.
func t(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func t(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}
