import XCTest

/// Drives the demo device (DemoBLETransport) through every major screen and
/// captures screenshots as attachments — design review and App Store
/// screenshot generation without hardware. Export the images with:
/// `xcrun xcresulttool export attachments --path <bundle>.xcresult --output-path <dir>`
final class DemoWalkthroughUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testDemoWalkthroughScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-MWDemo"]
        app.launch()

        snap("01-scan")

        // Connect to the simulated device.
        let demoRow = app.staticTexts["Simulated MetaWear"].firstMatch
        XCTAssertTrue(demoRow.waitForExistence(timeout: 8), "Demo row missing from scan list")
        demoRow.tap()

        let liveStreamTile = app.staticTexts["Live Stream"].firstMatch
        XCTAssertTrue(liveStreamTile.waitForExistence(timeout: 12), "Device detail never appeared")
        sleep(1)
        snap("02-device-detail")

        // Live streaming: configure → start → let the charts draw.
        liveStreamTile.tap()
        let start = app.buttons["Start"].firstMatch
        if start.waitForExistence(timeout: 6) {
            sleep(1)
            snap("03-sensor-config")
            start.tap()
            sleep(6)
            snap("04-live-stream")
            goBack(app)   // back to sensor config or detail
            sleep(1)
            goBack(app)
            sleep(1)
        }

        visitTile(app, "Controls", shot: "05-controls")
        visitTile(app, "Device Info", shot: "06-device-info")
        visitTile(app, "Settings", shot: "07-settings")
        visitTile(app, "Logging", shot: "08-logging")
    }

    // MARK: - Helpers

    @MainActor
    private func visitTile(_ app: XCUIApplication, _ title: String, shot: String) {
        let tile = app.staticTexts[title].firstMatch
        guard tile.waitForExistence(timeout: 6), tile.isHittable else { return }
        tile.tap()
        sleep(2)
        snap(shot)
        goBack(app)
        sleep(1)
    }

    @MainActor
    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable { back.tap() }
    }

    @MainActor
    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
