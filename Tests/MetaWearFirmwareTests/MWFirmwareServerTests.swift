//
//  MWFirmwareServerTests.swift
//  MetaWearFirmwareTests
//
//  Coverage for `MWFirmwareServer` — the layer above `MWFirmwareCatalog`
//  that coordinates HTTP fetches, build selection, and update detection.
//
//  All tests use `MockFirmwareFetcher` so nothing actually hits the network.
//  The mock can be configured to return canned data, simulate HTTP errors,
//  and observe which URLs were requested.
//

import Foundation
import Testing
@testable import MetaWearFirmware

@Suite("MWFirmwareServer")
struct MWFirmwareServerTests {

    // MARK: - Catalog reads

    @Test
    func availableBuilds_returnsFilteredAndSorted() async throws {
        let server = MWFirmwareServer(
            fetcher: MockFirmwareFetcher(catalog: Fixtures.catalogJSON),
            catalogURL: Fixtures.catalogURL,
            sdkVersion: "5.0.0"
        )
        let builds = try await server.availableBuilds(
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla"
        )
        // Three matching builds, ascending by version.
        #expect(builds.map(\.firmwareRev) == ["1.5.0", "1.7.3", "2.0.0-beta"])
    }

    @Test
    func latestBuild_returnsHighestVersion() async throws {
        let server = MWFirmwareServer(
            fetcher: MockFirmwareFetcher(catalog: Fixtures.catalogJSON),
            catalogURL: Fixtures.catalogURL,
            sdkVersion: "5.0.0"
        )
        let latest = try await server.latestBuild(
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla"
        )
        #expect(latest.firmwareRev == "2.0.0-beta")
    }

    @Test
    func latestBuild_filteredBySDK() async throws {
        // SDK 3.2 can't see the 4.0-gated 2.0.0-beta — latest is 1.7.3.
        let server = MWFirmwareServer(
            fetcher: MockFirmwareFetcher(catalog: Fixtures.catalogJSON),
            catalogURL: Fixtures.catalogURL,
            sdkVersion: "3.2.0"
        )
        let latest = try await server.latestBuild(
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla"
        )
        #expect(latest.firmwareRev == "1.7.3")
    }

    @Test
    func latestBuild_throwsWhenNoneMatch() async throws {
        let server = MWFirmwareServer(
            fetcher: MockFirmwareFetcher(catalog: Fixtures.catalogJSON),
            catalogURL: Fixtures.catalogURL,
            sdkVersion: "5.0.0"
        )
        await #expect(throws: MWFirmwareError.self) {
            _ = try await server.latestBuild(
                hardwareRev: "9.9",
                modelNumber: "5",
                buildFlavor: "vanilla"
            )
        }
    }

    // MARK: - Specific-version lookup

    @Test
    func build_returnsRequestedVersion() async throws {
        let server = MWFirmwareServer(
            fetcher: MockFirmwareFetcher(catalog: Fixtures.catalogJSON),
            catalogURL: Fixtures.catalogURL,
            sdkVersion: "5.0.0"
        )
        let build = try await server.build(
            hardwareRev: "0.4",
            modelNumber: "5",
            firmwareRev: "1.5.0",
            buildFlavor: "vanilla"
        )
        #expect(build?.firmwareRev == "1.5.0")
        #expect(build?.requiredBootloader == "0.4")
    }

    @Test
    func build_returnsNilForUnknownVersion() async throws {
        let server = MWFirmwareServer(
            fetcher: MockFirmwareFetcher(catalog: Fixtures.catalogJSON),
            catalogURL: Fixtures.catalogURL,
            sdkVersion: "5.0.0"
        )
        let build = try await server.build(
            hardwareRev: "0.4",
            modelNumber: "5",
            firmwareRev: "99.99.99",
            buildFlavor: "vanilla"
        )
        #expect(build == nil)
    }

    // MARK: - updateAvailable

    @Test
    func updateAvailable_returnsNilWhenAlreadyLatest() async throws {
        let server = MWFirmwareServer(
            fetcher: MockFirmwareFetcher(catalog: Fixtures.catalogJSON),
            catalogURL: Fixtures.catalogURL,
            sdkVersion: "5.0.0"
        )
        // Device is already on the latest visible version.
        let update = try await server.updateAvailable(
            currentRev: "2.0.0-beta",
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla"
        )
        #expect(update == nil)
    }

    @Test
    func updateAvailable_returnsLatestWhenOlder() async throws {
        let server = MWFirmwareServer(
            fetcher: MockFirmwareFetcher(catalog: Fixtures.catalogJSON),
            catalogURL: Fixtures.catalogURL,
            sdkVersion: "5.0.0"
        )
        let update = try await server.updateAvailable(
            currentRev: "1.5.0",
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla"
        )
        #expect(update?.firmwareRev == "2.0.0-beta")
    }

    @Test
    func updateAvailable_returnsLatestWhenAheadOfSDK() async throws {
        // Device ahead of what THIS SDK can flash — return the latest the
        // SDK can support, even if it's a downgrade. This matches the
        // legacy Combine SDK's behaviour and lets users pin a known-good
        // version when the SDK isn't ready for the latest beta.
        let server = MWFirmwareServer(
            fetcher: MockFirmwareFetcher(catalog: Fixtures.catalogJSON),
            catalogURL: Fixtures.catalogURL,
            sdkVersion: "3.2.0"
        )
        let update = try await server.updateAvailable(
            currentRev: "0.9.0",
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla"
        )
        // SDK 3.2 caps at 1.7.3; the device on 0.9.0 should see 1.7.3.
        #expect(update?.firmwareRev == "1.7.3")
    }

    // MARK: - HTTP errors

    @Test
    func availableBuilds_throwsBadServerResponseOn500() async throws {
        let mock = MockFirmwareFetcher(
            catalog: Fixtures.catalogJSON,
            statusCode: 500
        )
        let server = MWFirmwareServer(
            fetcher: mock,
            catalogURL: Fixtures.catalogURL,
            sdkVersion: "5.0.0"
        )
        await #expect(throws: MWFirmwareError.self) {
            _ = try await server.availableBuilds(
                hardwareRev: "0.4",
                modelNumber: "5",
                buildFlavor: "vanilla"
            )
        }
    }

    @Test
    func availableBuilds_throwsInvalidServerResponseOnBadJSON() async throws {
        let mock = MockFirmwareFetcher(catalog: "not json".data(using: .utf8)!)
        let server = MWFirmwareServer(
            fetcher: mock,
            catalogURL: Fixtures.catalogURL,
            sdkVersion: "5.0.0"
        )
        await #expect(throws: MWFirmwareError.self) {
            _ = try await server.availableBuilds(
                hardwareRev: "0.4",
                modelNumber: "5",
                buildFlavor: "vanilla"
            )
        }
    }

    // MARK: - Catalog URL is honoured

    @Test
    func server_fetchesCatalogFromConfiguredURL() async throws {
        let mock = MockFirmwareFetcher(catalog: Fixtures.catalogJSON)
        let custom = URL(string: "https://staging.example.com/info2.json")!
        let server = MWFirmwareServer(
            fetcher: mock,
            catalogURL: custom,
            sdkVersion: "5.0.0"
        )
        _ = try await server.availableBuilds(
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla"
        )
        #expect(await mock.requestedDataURLs == [custom])
    }
}

// MARK: - Mock fetcher

/// In-memory implementation of `MWFirmwareFetcher` for unit tests. Returns
/// canned bytes for `data(from:)` and a synthesized temp file for
/// `download(from:)`. Records every URL requested so tests can assert on
/// call shape.
actor MockFirmwareFetcher: MWFirmwareFetcher {

    private let catalog: Data
    private let firmware: Data
    private let statusCode: Int

    private(set) var requestedDataURLs: [URL] = []
    private(set) var requestedDownloadURLs: [URL] = []

    init(
        catalog: Data,
        firmware: Data = Data("MOCK-FIRMWARE-BYTES".utf8),
        statusCode: Int = 200
    ) {
        self.catalog = catalog
        self.firmware = firmware
        self.statusCode = statusCode
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        requestedDataURLs.append(url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (catalog, response)
    }

    func download(from url: URL) async throws -> (URL, HTTPURLResponse) {
        requestedDownloadURLs.append(url)
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("mock-\(UUID().uuidString).bin")
        try firmware.write(to: tempURL)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (tempURL, response)
    }
}

// MARK: - Fixtures

private enum Fixtures {

    static let catalogURL = URL(string: "https://test.example.com/info2.json")!

    /// Same shape as `MWFirmwareCatalogTests.catalogJSON` — duplicated so
    /// each test file is self-contained.
    static let catalogJSON: Data = """
    {
      "0.4": {
        "5": {
          "vanilla": {
            "1.5.0": {
              "filename": "firmware.zip",
              "required-bootloader": "0.4",
              "min-ios-version": "3.0.0"
            },
            "1.7.3": {
              "filename": "firmware.zip",
              "required-bootloader": "0.5",
              "min-ios-version": "3.2.0"
            },
            "2.0.0-beta": {
              "filename": "firmware.zip",
              "required-bootloader": "0.5",
              "min-ios-version": "4.0.0"
            }
          }
        }
      }
    }
    """.data(using: .utf8)!
}
