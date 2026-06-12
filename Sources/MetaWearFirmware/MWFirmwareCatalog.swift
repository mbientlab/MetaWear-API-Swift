//
//  MWFirmwareCatalog.swift
//  MetaWearFirmware
//
//  Parser for the MbientLab firmware-catalog JSON served at
//  `https://mbientlab.com/releases/metawear/info2.json`.
//
//  Catalog shape (4 levels of dictionary nesting, leaf values are short
//  string-keyed dictionaries):
//
//  ```json
//  {
//    "<hardwareRev>": {                   e.g. "0.4"
//      "<modelNumber>": {                 e.g. "5"
//        "<buildFlavor>": {               e.g. "vanilla", "bootloader"
//          "<firmwareRev>": {             e.g. "1.7.3"
//            "filename": "firmware.zip",
//            "required-bootloader": "0.5",
//            "min-ios-version": "3.2.0"
//          },
//          ...
//        }
//      }
//    }
//  }
//  ```
//
//  The parser is split out so unit tests can feed canned JSON without going
//  through HTTP.
//

import Foundation

enum MWFirmwareCatalog {

    /// Type alias for the raw JSON dictionary produced by `JSONSerialization`.
    /// The inner-leaf values are `[String: String]` — `filename`,
    /// `required-bootloader`, `min-ios-version`. We keep them stringly-typed
    /// because that's how the server emits them.
    typealias JSON = [String: [String: [String: [String: [String: String]]]]]

    /// Parse the raw `Data` returned by the catalog server into the typed
    /// JSON dictionary. Throws `MWFirmwareError.invalidServerResponse` if
    /// the bytes don't deserialize or don't match the expected shape.
    static func parse(_ data: Data) throws -> JSON {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw MWFirmwareError.invalidServerResponse(
                message: "JSON deserialization failed: \(error.localizedDescription)"
            )
        }
        guard let typed = object as? JSON else {
            throw MWFirmwareError.invalidServerResponse(
                message: "JSON shape mismatch — expected [hwRev: [model: [flavor: [version: {…}]]]]."
            )
        }
        return typed
    }

    /// Extract every build that matches the requested (hardwareRev,
    /// modelNumber, buildFlavor) tuple AND whose `min-ios-version` is ≤ the
    /// current SDK version, sorted ascending by firmware revision.
    ///
    /// - Parameters:
    ///   - json:        The parsed catalog (from `parse(_:)`).
    ///   - hardwareRev: Hardware revision string from the connected device.
    ///   - modelNumber: Model number string from the connected device.
    ///   - buildFlavor: `"vanilla"` for end-user firmware, `"bootloader"`
    ///                  for bootloader-only builds.
    ///   - sdkVersion:  This SDK's own version string, used to filter out
    ///                  firmware that requires a newer SDK than the caller.
    /// - Returns: Builds sorted ascending by `firmwareRev`. Empty array if
    ///   nothing matches (the orchestrator promotes that to a thrown
    ///   `MWFirmwareError.noAvailableFirmware`).
    static func matchingBuilds(
        from json: JSON,
        hardwareRev: String,
        modelNumber: String,
        buildFlavor: String,
        sdkVersion: String
    ) -> [MWFirmwareBuild] {
        guard let candidates = json[hardwareRev]?[modelNumber]?[buildFlavor] else {
            return []
        }
        return candidates
            // Filter by SDK floor — a missing `min-ios-version` key is
            // treated as "any SDK supports this" for forward compatibility.
            .filter { _, attrs in
                guard let required = attrs["min-ios-version"] else { return true }
                return sdkVersion.isMetaWearVersion(greaterThanOrEqualTo: required)
            }
            // Stable sort by firmware version ascending.
            .sorted { lhs, rhs in
                lhs.key.isMetaWearVersion(lessThan: rhs.key)
            }
            // Map to MWFirmwareBuild. `filename` is required; missing means
            // the catalog entry is malformed and we just skip it (rather than
            // thread a throws through `compactMap` for one bad row).
            .compactMap { firmwareRev, attrs -> MWFirmwareBuild? in
                guard let filename = attrs["filename"] else { return nil }
                let requiredBootloader = attrs["required-bootloader"]
                return MWFirmwareBuild(
                    hardwareRev: hardwareRev,
                    modelNumber: modelNumber,
                    buildFlavor: buildFlavor,
                    firmwareRev: firmwareRev,
                    filename: filename,
                    requiredBootloader: requiredBootloader
                )
            }
    }
}
