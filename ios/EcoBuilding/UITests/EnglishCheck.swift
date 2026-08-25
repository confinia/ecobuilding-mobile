import XCTest

/// Contrôle de l'affichage ANGLAIS, joué sur l'app réelle.
///
/// La leçon d'Android : les fuites ne sont pas dans les libellés évidents mais
/// dans les lambdas de formatage — « Classe DPE C » et « kWh/an par kWc »
/// avaient traversé une première passe pourtant méthodique. On relit donc
/// l'écran, on ne se fie pas au code.
final class EnglishCheck: XCTestCase {

    func testSheetIsEnglish() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        addUIInterruptionMonitor(withDescription: "Position") { alert in
            for l in ["Allow While Using App", "Autoriser lorsque l'app est active"] {
                if alert.buttons[l].exists { alert.buttons[l].tap(); return true }
            }
            return false
        }
        app.tap()

        let field = app.textFields["Address in France…"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "le champ n'est pas en anglais")
        field.tap()
        field.typeText("12 rue lecourbe paris")

        let suggestion = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Lecourbe")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 25))
        suggestion.tap()

        XCTAssertTrue(app.buttons["Get the PDF report"].firstMatch.waitForExistence(timeout: 30),
                      "le bouton PDF n'est pas en anglais")
        Thread.sleep(forTimeInterval: 6)

        // Ce qui avait fui sur Android : on l'exige explicitement ici.
        for attendu in ["Energy rating (DPE) C", "Greenhouse gas", "Year built",
                        "Storeys", "Solar potential"] {
            let found = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", attendu)).firstMatch
            XCTAssertTrue(found.waitForExistence(timeout: 8), "absent en anglais : \(attendu)")
        }
        // Et ce qui ne doit PLUS apparaître.
        // « fiches aujourd'hui » avait traversé la première passe : le solde de
        // quota se fabrique dans le client d'API, pas dans une vue.
        for interdit in ["Classe DPE", "kWh/m²/an", "Année de construction",
                         "fiches", "aujourd'hui"] {
            let leak = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", interdit)).firstMatch
            XCTAssertFalse(leak.exists, "resté en français : \(interdit)")
        }

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "fiche-en"; shot.lifetime = .keepAlways
        add(shot)
    }
}
