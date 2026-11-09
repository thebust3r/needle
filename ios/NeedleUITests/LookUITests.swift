import XCTest

/// Every built-in look, photographed on the main screens, plus the Appearance editor itself.
final class LookUITests: PlatterUITestCase {
    static let looks = ["chrome", "burned", "neon", "analog", "glow", "vinyl", "classic"]

    func launch(look: String) {
        app.terminate()
        app.launchEnvironment["UITEST_LOOK"] = look
        app.launch()
        waitFor(tab("home"))
    }

    func testEveryLookOnTheMainScreens() {
        for (n, look) in Self.looks.enumerated() {
            launch(look: look)
            sleep(2)
            shot("look-\(n)-\(look)-1-home")
            openFirstAlbum()
            sleep(1)
            shot("look-\(n)-\(look)-2-album")
            // play the second song and open Now Playing
            app.otherElements.matching(identifier: "track-row").element(boundBy: 1).tap()
            let mini = waitFor(app.otherElements["mini-player"], 10)
            sleep(1)
            shot("look-\(n)-\(look)-3-mini")
            mini.tap()
            waitFor(app.buttons["np-close"], 10)
            sleep(2)
            shot("look-\(n)-\(look)-4-nowplaying")
            app.buttons["np-close"].tap()
            sleep(1)
            tab("settings").tap()
            sleep(1)
            shot("look-\(n)-\(look)-5-settings")
        }
    }

    func testTheAppearanceEditor() {
        launch(look: "chrome")
        tab("settings").tap()
        let link = app.buttons["settings-appearance"].firstMatch
        if !link.waitForExistence(timeout: 5) { app.swipeUp() }
        waitFor(link).tap()
        waitFor(app.buttons["look-chrome"].firstMatch)
        shot("editor-1-top")
        // pick another look, then change single settings
        app.buttons["look-neon"].firstMatch.tap()
        sleep(1)
        shot("editor-2-neon")
        app.swipeUp()
        sleep(1)
        shot("editor-3-options")
        for chip in ["chip-Glossy", "chip-Dock", "chip-Sparkles", "chip-Bubbly"] {
            let c = app.buttons[chip].firstMatch
            if !c.isHittable { app.swipeUp() }
            waitFor(c).tap()
        }
        sleep(1)
        shot("editor-4-customized")
        app.swipeUp()
        app.swipeUp()
        let cassette = app.buttons["chip-Cassette"].firstMatch
        waitFor(cassette).tap()
        waitFor(app.buttons["look-save"]).tap()
        let field = app.alerts.textFields.firstMatch
        waitFor(field, 5).tap()
        field.typeText(" Test")
        app.alerts.buttons["Save"].tap()
        sleep(1)
        shot("editor-5-saved")
        // the saved look is first in the list now
        app.swipeDown()
        app.swipeDown()
        sleep(1)
        shot("editor-6-your-looks")
    }

    func testHomeLayoutEditor() {
        launch(look: "chrome")
        tab("settings").tap()
        let link = app.buttons["settings-home-layout"].firstMatch
        if !link.waitForExistence(timeout: 5) { app.swipeUp() }
        waitFor(link).tap()
        sleep(1)
        shot("layout-1")
        let toggle = app.switches["Show Quick Picks"].firstMatch
        waitFor(toggle).tap()
        sleep(1)
        shot("layout-2-quick-picks-off")
        tab("home").tap()
        sleep(2)
        shot("layout-3-home-without-quick-picks")
        // put it back for other tests
        tab("settings").tap()
        waitFor(app.switches["Show Quick Picks"].firstMatch).tap()
    }
}
