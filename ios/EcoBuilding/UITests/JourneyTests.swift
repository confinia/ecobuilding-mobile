import XCTest

/// Parcours de bout en bout, joué sur l'application réelle.
///
/// Pourquoi une cible XCUITest plutôt que `simctl` : `simctl` sait lancer
/// l'app, lui poser une position et capturer l'écran, mais il ne sait pas
/// **toucher**. Sans cela, aucun parcours ne peut être rejoué — or les défauts
/// les plus coûteux de ce produit (fiche qui ne s'ouvre pas, bouton hors écran,
/// donnée nulle qui fait tomber l'app) ne se voient qu'en jouant le parcours.
///
/// Les mêmes étapes sont jouées côté Android avec `adb`. Les deux scénarios
/// suivent volontairement le même ordre, pour que les captures se comparent
/// écran par écran.
final class JourneyTests: XCTestCase {

    /// L'adresse d'essai : un pavillon de plain-pied, sans DPE publié — un cas
    /// ordinaire, et justement celui qui faisait tomber la version Android.
    private let address = "16 impasse jean jaures"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // On coupe l'animation : sans cela, les attentes se calent sur des
        // transitions et non sur l'arrivée réelle des données.
        app.launchArguments += ["-UIAnimationDragCoefficient", "1"]
        app.launch()
        // La demande de position s'invite au premier lancement et vole les
        // touchers suivants. On la traite si elle apparaît, sans en dépendre.
        addUIInterruptionMonitor(withDescription: "Position") { alert in
            let allow = alert.buttons["Allow While Using App"]
            if allow.exists { allow.tap(); return true }
            let autoriser = alert.buttons["Autoriser lorsque l'app est active"]
            if autoriser.exists { autoriser.tap(); return true }
            return false
        }
        app.tap()
        return app
    }

    /// Chercher une adresse, choisir une suggestion, lire la fiche.
    func testFindAddressAndOpenSheet() throws {
        let app = launch()

        let field = app.textFields["Adresse en France…"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "champ de recherche absent")
        field.tap()
        field.typeText(address)

        // La suggestion vient de la Base Adresse Nationale : on attend le
        // RÉSEAU, pas une animation.
        let suggestion = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Impasse Jean Jaur")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 25), "aucune suggestion")
        suggestion.tap()

        // Le serveur émet le bâtiment avant les neuf sources : la fiche doit
        // s'afficher bien avant d'être complète.
        let title = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Jean Jaur")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "la fiche ne s'est pas ouverte")

        // Le bouton PDF doit être là SANS avoir à faire défiler : c'est l'objet
        // vendu, et il tombait sous le pli côté Android.
        let pdf = app.buttons["Obtenir la fiche PDF"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 20), "bouton PDF absent")
        XCTAssertTrue(pdf.isHittable, "bouton PDF présent mais hors d'atteinte")

        attach(app, named: "fiche")
    }

    /// La fiche PDF doit s'ouvrir ET pouvoir se refermer.
    func testReportOpensAndCloses() throws {
        let app = launch()

        let field = app.textFields["Adresse en France…"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(address)

        let suggestion = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Impasse Jean Jaur")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 25))
        suggestion.tap()

        let pdf = app.buttons["Obtenir la fiche PDF"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 30))
        pdf.tap()

        // Le serveur collecte, rend la carte 3D et met en page : 10 à 45 s.
        let close = app.buttons["Fermer la fiche"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 90), "la fiche PDF ne s'est pas ouverte")
        attach(app, named: "pdf")

        // Le défaut qui a motivé ce test : la croix existait mais n'était
        // jamais rendue, et l'utilisateur restait coincé sur le document.
        close.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 20), "impossible de revenir à la carte")
    }

    private func attach(_ app: XCUIApplication, named: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = named
        shot.lifetime = .keepAlways
        add(shot)
    }
}
