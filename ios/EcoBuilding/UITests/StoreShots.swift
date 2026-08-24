import XCTest

/// Captures pour la fiche App Store, jouées sur l'app réelle.
///
/// Les captures ne sont pas des maquettes : ce sont les écrans que l'acheteur
/// verra. Les fabriquer depuis le simulateur garantit qu'elles ne promettent
/// rien que le produit ne tienne — et qu'elles restent justes après chaque
/// changement, puisqu'il suffit de rejouer le scénario.
final class StoreShots: XCTestCase {

    /// Une adresse PARISIENNE, publique et anodine : un immeuble de rapport,
    /// classé DPE, aux risques renseignés. Surtout pas le domicile de qui que
    /// ce soit — une capture d'écran d'App Store est publique et indexée, et
    /// l'adresse y figure en gros caractères.
    private let address = "12 rue lecourbe paris"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCaptureStoreScreenshots() throws {
        let app = XCUIApplication()
        app.launch()
        addUIInterruptionMonitor(withDescription: "Position") { alert in
            for label in ["Allow While Using App", "Autoriser lorsque l'app est active"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.tap()

        let field = app.textFields["Adresse en France…"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "champ de recherche absent")
        field.tap()
        field.typeText(address)

        let suggestion = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Lecourbe")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 25), "aucune suggestion")
        suggestion.tap()

        // 1 — la fiche, remplie : c'est ce qu'on vient chercher.
        let pdf = app.buttons["Obtenir la fiche PDF"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 30), "fiche non ouverte")
        Thread.sleep(forTimeInterval: 6)          // laisser les neuf sources arriver
        shot(app, "1-fiche")

        // 2 — la carte 3D seule, sans fiche : le produit se reconnaît d'un coup d'œil.
        app.swipeDown()
        Thread.sleep(forTimeInterval: 3)
        shot(app, "2-carte-3d")

        // 3 — la vue satellite avec les limites de parcelles.
        let aerial = app.buttons["Afficher la photo aérienne"].firstMatch
        if aerial.waitForExistence(timeout: 10) {
            aerial.tap()
            Thread.sleep(forTimeInterval: 10)     // laisser l'orthophoto se charger
            shot(app, "3-satellite-cadastre")
        }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
