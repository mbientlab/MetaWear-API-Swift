//
//  MWFirmwareCatalogTests.swift
//  MetaWearFirmwareTests
//
//  Coverage for the JSON catalog parser and the build-selection logic on
//  top of it. Uses inline JSON fixtures mirroring the real
//  `info2.json` shape so a future server-side change is easy to spot.
//

import Foundation
import Testing
@testable import MetaWearFirmware

@Suite("MWFirmwareCatalog")
struct MWFirmwareCatalogTests {

    // MARK: - Fixtures

    /// A small but realistic catalog covering two hardware revs, two models,
    /// two build flavors, and three firmware versions with varying
    /// `min-ios-version` floors.
    static let catalogJSON = """
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
          },
          "bootloader": {
            "0.5": {
              "filename": "bootloader.zip",
              "required-bootloader": "0.4",
              "min-ios-version": "3.0.0"
            }
          }
        },
        "6": {
          "vanilla": {
            "2.0.0": {
              "filename": "firmware.zip",
              "required-bootloader": "0.7",
              "min-ios-version": "3.2.0"
            }
          }
        }
      },
      "0.3": {
        "5": {
          "vanilla": {
            "1.0.0": {
              "filename": "firmware.bin",
              "required-bootloader": "",
              "min-ios-version": "1.0.0"
            }
          }
        }
      }
    }
    """.data(using: .utf8)!

    // MARK: - parse(_:)

    @Test
    func parse_acceptsValidJSON() throws {
        let json = try MWFirmwareCatalog.parse(Self.catalogJSON)
        #expect(json["0.4"]?["5"]?["vanilla"]?.count == 3)
        #expect(json["0.4"]?["6"]?["vanilla"]?.count == 1)
        #expect(json["0.3"]?["5"]?["vanilla"]?.count == 1)
    }

    @Test
    func parse_rejectsMalformedJSON() {
        let garbage = "this is not json".data(using: .utf8)!
        #expect(throws: MWFirmwareError.self) {
            _ = try MWFirmwareCatalog.parse(garbage)
        }
    }

    @Test
    func parse_rejectsWrongJSONShape() {
        // Top-level array, not dictionary.
        let array = "[1, 2, 3]".data(using: .utf8)!
        #expect(throws: MWFirmwareError.self) {
            _ = try MWFirmwareCatalog.parse(array)
        }
    }

    // MARK: - matchingBuilds(...)

    @Test
    func matchingBuilds_returnsOnlyMatchingTuple() throws {
        let json = try MWFirmwareCatalog.parse(Self.catalogJSON)
        let builds = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla",
            sdkVersion: "5.0.0"
        )
        #expect(builds.count == 3)
        #expect(builds.allSatisfy { $0.hardwareRev == "0.4" })
        #expect(builds.allSatisfy { $0.modelNumber == "5" })
        #expect(builds.allSatisfy { $0.buildFlavor == "vanilla" })
    }

    @Test
    func matchingBuilds_emptyForUnknownHardware() throws {
        let json = try MWFirmwareCatalog.parse(Self.catalogJSON)
        let builds = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "9.9",
            modelNumber: "5",
            buildFlavor: "vanilla",
            sdkVersion: "5.0.0"
        )
        #expect(builds.isEmpty)
    }

    @Test
    func matchingBuilds_emptyForUnknownModel() throws {
        let json = try MWFirmwareCatalog.parse(Self.catalogJSON)
        let builds = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "0.4",
            modelNumber: "999",
            buildFlavor: "vanilla",
            sdkVersion: "5.0.0"
        )
        #expect(builds.isEmpty)
    }

    @Test
    func matchingBuilds_emptyForUnknownFlavor() throws {
        let json = try MWFirmwareCatalog.parse(Self.catalogJSON)
        let builds = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "experimental",
            sdkVersion: "5.0.0"
        )
        #expect(builds.isEmpty)
    }

    // MARK: - SDK floor filtering

    @Test
    func matchingBuilds_filtersByMinIosVersion() throws {
        let json = try MWFirmwareCatalog.parse(Self.catalogJSON)

        // SDK 3.0 only accepts 1.5.0 (which requires SDK 3.0). 1.7.3 needs
        // 3.2.0, and 2.0.0-beta needs 4.0.0 — both filtered out.
        let sdk3 = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla",
            sdkVersion: "3.0.0"
        )
        #expect(sdk3.map(\.firmwareRev) == ["1.5.0"])

        // SDK 3.2 accepts 1.5.0 + 1.7.3, not the 4.0-gated beta.
        let sdk32 = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla",
            sdkVersion: "3.2.0"
        )
        #expect(sdk32.map(\.firmwareRev) == ["1.5.0", "1.7.3"])

        // SDK 4.0 accepts everything.
        let sdk4 = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla",
            sdkVersion: "4.0.0"
        )
        #expect(sdk4.count == 3)
    }

    // MARK: - Sort order

    @Test
    func matchingBuilds_returnedAscendingByVersion() throws {
        let json = try MWFirmwareCatalog.parse(Self.catalogJSON)
        let builds = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla",
            sdkVersion: "5.0.0"
        )
        // Pairwise: each build sorts strictly before the next.
        for (a, b) in zip(builds, builds.dropFirst()) {
            #expect(a.firmwareRev.isMetaWearVersion(lessThan: b.firmwareRev),
                    "Expected \(a.firmwareRev) < \(b.firmwareRev) but builds are out of order")
        }
    }

    // MARK: - Field mapping

    @Test
    func matchingBuilds_mapsAttributesToBuildFields() throws {
        let json = try MWFirmwareCatalog.parse(Self.catalogJSON)
        let builds = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla",
            sdkVersion: "5.0.0"
        )
        guard let v17 = builds.first(where: { $0.firmwareRev == "1.7.3" }) else {
            Issue.record("Expected 1.7.3 in matched builds")
            return
        }
        #expect(v17.filename == "firmware.zip")
        #expect(v17.requiredBootloader == "0.5")
        #expect(v17.firmwareURL.absoluteString.hasSuffix("/0.4/5/vanilla/1.7.3/firmware.zip"))
    }

    @Test
    func matchingBuilds_handlesEmptyRequiredBootloader() throws {
        // The 0.3/5 entry has `"required-bootloader": ""`. We pass it
        // through verbatim — the orchestrator interprets empty as "any".
        let json = try MWFirmwareCatalog.parse(Self.catalogJSON)
        let builds = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "0.3",
            modelNumber: "5",
            buildFlavor: "vanilla",
            sdkVersion: "5.0.0"
        )
        #expect(builds.count == 1)
        #expect(builds.first?.requiredBootloader == "")
    }

    @Test
    func matchingBuilds_skipsEntriesMissingFilename() throws {
        // Synthetic catalog with one well-formed entry and one missing
        // `filename` key. The malformed entry is silently dropped rather
        // than crashing the parse.
        let badJSON = """
        {
          "0.4": { "5": { "vanilla": {
            "1.0.0": { "filename": "firmware.zip", "required-bootloader": "", "min-ios-version": "1.0" },
            "1.1.0": { "required-bootloader": "", "min-ios-version": "1.0" }
          }}}
        }
        """.data(using: .utf8)!
        let json = try MWFirmwareCatalog.parse(badJSON)
        let builds = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla",
            sdkVersion: "5.0.0"
        )
        #expect(builds.map(\.firmwareRev) == ["1.0.0"])
    }

    @Test
    func matchingBuilds_acceptsMissingMinIosVersion() throws {
        // Catalog entries without a `min-ios-version` key are accepted by
        // any SDK — no floor means "no requirement."
        let unfilteredJSON = """
        {
          "0.4": { "5": { "vanilla": {
            "1.0.0": { "filename": "firmware.zip", "required-bootloader": "" }
          }}}
        }
        """.data(using: .utf8)!
        let json = try MWFirmwareCatalog.parse(unfilteredJSON)
        let builds = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: "0.4",
            modelNumber: "5",
            buildFlavor: "vanilla",
            sdkVersion: "1.0.0"
        )
        #expect(builds.count == 1)
    }
}
