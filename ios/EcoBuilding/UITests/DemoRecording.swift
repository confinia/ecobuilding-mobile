import XCTest

/// Parcours de DÉMONSTRATION, joué pour l'enregistrement d'écran demandé par
/// App Review (guideline 2.1) : lancement → autorisation de position → carte →
/// recherche → fiche bâtiment → fiche PDF → retour à la carte.
///
/// Les pauses donnent au spectateur le temps de lire ; les assertions restent
/// réelles, pour que la vidéo ne puisse pas montrer un parcours cassé.
/// L'adresse est un immeuble parisien à nombreux diagnostics : c'est lui qui
/// montre les blocs DPE par logement, le cœur du produit.
final class DemoRecording: XCTestCase {

    func testDemoJourney() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        addUIInterruptionMonitor(withDescription: "Position") { alert in
            for label in ["Allow While Using App",
                          "Autoriser lorsque l'app est active"] {
                let b = alert.buttons[label]
                if b.exists { sleep(2); b.tap(); return true }
            }
            return false
        }
        app.tap()
        sleep(4)                       // la carte s'installe à l'écran

        let field = app.textFields["Adresse en France…"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "champ de recherche absent")
        field.tap()
        // L'adresse PRINCIPALE de l'immeuble aux 23 diagnostics (C à G) :
        // « 21 rue duvivier » retombe sur un bâtiment voisin sans DPE, et la
        // vidéo montrait « DPE non renseigné » — l'inverse d'une démonstration.
        field.typeText("16 rue dupont des loges paris")

        let suggestion = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Dupont des Loges")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 25), "aucune suggestion")
        sleep(2)
        suggestion.tap()

        let pdf = app.buttons["Obtenir la fiche PDF"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 30), "bouton PDF absent")
        sleep(3)
        app.swipeUp()                  // parcourir la fiche : les blocs DPE
        sleep(2)
        app.swipeUp()
        sleep(2)
        app.swipeDown()
        app.swipeDown()
        sleep(2)
        XCTAssertTrue(pdf.isHittable, "bouton PDF hors d'atteinte")
        pdf.tap()

        // Le serveur collecte, rend la carte 3D et met en page : 10 à 45 s.
        let close = app.buttons["Fermer la fiche"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 90), "la fiche PDF ne s'est pas ouverte")
        sleep(3)
        app.swipeUp()                  // feuilleter le document
        sleep(2)
        app.swipeUp()
        sleep(2)
        close.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 20), "impossible de revenir à la carte")
        sleep(2)
    }
}
