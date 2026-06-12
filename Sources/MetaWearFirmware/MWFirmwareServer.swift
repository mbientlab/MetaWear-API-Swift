//
//  MWFirmwareServer.swift
//  MetaWearFirmware
//
//  HTTP client for MbientLab's firmware catalog + downloads. Designed so the
//  network layer is mockable — callers (and tests) can supply any conforming
//  `MWFirmwareFetcher`. The default implementation wraps `URLSession`.
//

import Foundation

// MARK: - Fetcher protocol

/// Minimal HTTP surface the firmware server needs. Conformed to by
/// `URLSessionFetcher` (production) and any test double.
///
/// Two methods, both `async`:
///   • `data(from:)`     — fetch raw bytes, used for the catalog JSON
///   • `download(from:)` — fetch and save to a temporary file, used for the
///                         firmware artifact (avoids loading the whole image
///                         into memory and lets us hand a `URL` to NordicDFU).
public protocol MWFirmwareFetcher: Sendable {
    func data(from url: URL) async throws -> (Data, HTTPURLResponse)
    func download(from url: URL) async throws -> (URL, HTTPURLResponse)
}

// MARK: - URLSession-backed fetcher (production default)

public struct URLSessionFetcher: MWFirmwareFetcher {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw MWFirmwareError.invalidServerResponse(
                message: "Non-HTTP response for \(url.absoluteString)"
            )
        }
        return (data, http)
    }

    public func download(from url: URL) async throws -> (URL, HTTPURLResponse) {
        let (tempURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw MWFirmwareError.invalidServerResponse(
                message: "Non-HTTP response for \(url.absoluteString)"
            )
        }
        return (tempURL, http)
    }
}

// MARK: - Server

/// High-level firmware-catalog client.
///
/// Three responsibilities:
///   1. Fetch the catalog JSON from `info2.json` and parse it.
///   2. Filter the catalog by (hardwareRev, modelNumber, buildFlavor) and
///      pick the right build (latest, specific version, etc.).
///   3. Download the chosen build's firmware file to a local temp URL.
///
/// All three are pure of `MetaWearDevice` — they take values, not the device
/// actor — so tests can drive them with synthetic fixtures.
public struct MWFirmwareServer: Sendable {

    /// Default catalog URL. Mirrors the legacy SDK's hard-coded value.
    public static let defaultCatalogURL = URL(
        string: "https://mbientlab.com/releases/metawear/info2.json"
    )!

    /// SDK version string used to filter out catalog entries whose
    /// `min-ios-version` exceeds this value. Updated when the SDK is
    /// versioned for release; for now we mirror the legacy "3.2.0" floor.
    public static let sdkVersion = "3.2.0"

    private let fetcher: MWFirmwareFetcher
    private let catalogURL: URL
    private let sdkVersion: String

    public init(
        fetcher: MWFirmwareFetcher = URLSessionFetcher(),
        catalogURL: URL = MWFirmwareServer.defaultCatalogURL,
        sdkVersion: String = MWFirmwareServer.sdkVersion
    ) {
        self.fetcher = fetcher
        self.catalogURL = catalogURL
        self.sdkVersion = sdkVersion
    }

    // MARK: - Catalog reads

    /// Fetch every firmware on the catalog matching the given device
    /// (hardwareRev, modelNumber) at the specified `buildFlavor`. Sorted
    /// ascending by firmware version, filtered by SDK floor.
    public func availableBuilds(
        hardwareRev: String,
        modelNumber: String,
        buildFlavor: String = "vanilla"
    ) async throws -> [MWFirmwareBuild] {
        let json = try await fetchCatalog()
        let builds = MWFirmwareCatalog.matchingBuilds(
            from: json,
            hardwareRev: hardwareRev,
            modelNumber: modelNumber,
            buildFlavor: buildFlavor,
            sdkVersion: sdkVersion
        )
        return builds
    }

    /// Fetch the latest firmware on the catalog for this device, or throw
    /// `noAvailableFirmware` if none match.
    public func latestBuild(
        hardwareRev: String,
        modelNumber: String,
        buildFlavor: String = "vanilla"
    ) async throws -> MWFirmwareBuild {
        let builds = try await availableBuilds(
            hardwareRev: hardwareRev,
            modelNumber: modelNumber,
            buildFlavor: buildFlavor
        )
        guard let latest = builds.last else {
            throw MWFirmwareError.noAvailableFirmware(
                message: "Catalog has no \(buildFlavor) build for hardware \(hardwareRev) model \(modelNumber)."
            )
        }
        return latest
    }

    /// Look up a specific firmware version. Returns `nil` if the version
    /// isn't on the catalog (rather than throwing — callers often want to
    /// distinguish "not found" from "server unreachable").
    public func build(
        hardwareRev: String,
        modelNumber: String,
        firmwareRev: String,
        buildFlavor: String = "vanilla"
    ) async throws -> MWFirmwareBuild? {
        let builds = try await availableBuilds(
            hardwareRev: hardwareRev,
            modelNumber: modelNumber,
            buildFlavor: buildFlavor
        )
        return builds.first { $0.firmwareRev.isMetaWearVersion(equalTo: firmwareRev) }
    }

    /// Compare the device's current firmware against the latest build on
    /// the catalog. Returns the latest build if it's newer than `currentRev`,
    /// or `nil` if the device is already up to date.
    public func updateAvailable(
        currentRev: String,
        hardwareRev: String,
        modelNumber: String,
        buildFlavor: String = "vanilla"
    ) async throws -> MWFirmwareBuild? {
        let latest = try await latestBuild(
            hardwareRev: hardwareRev,
            modelNumber: modelNumber,
            buildFlavor: buildFlavor
        )
        return currentRev.isMetaWearVersion(lessThan: latest.firmwareRev) ? latest : nil
    }

    // MARK: - Firmware download

    /// Download the firmware artifact for `build` to a temporary file and
    /// return the local URL. The caller (orchestrator) is responsible for
    /// deleting the temp file after the DFU completes or fails.
    public func downloadFirmware(_ build: MWFirmwareBuild) async throws -> URL {
        // file:// builds can be used as-is; saves a copy.
        if build.firmwareURL.isFileURL {
            return build.firmwareURL
        }
        let (tempURL, response) = try await fetcher.download(from: build.firmwareURL)
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw MWFirmwareError.badServerResponse(status: response.statusCode)
        }
        // The session deletes its temp file when the closure exits, so we
        // copy to a stable location keyed by filename.
        do {
            let tempDir = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: build.firmwareURL,
                create: true
            )
            let dest = tempDir.appendingPathComponent(build.filename)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return dest
        } catch {
            throw MWFirmwareError.cannotSaveFile(message: error.localizedDescription)
        }
    }

    // MARK: - Internal

    private func fetchCatalog() async throws -> MWFirmwareCatalog.JSON {
        let (data, response) = try await fetcher.data(from: catalogURL)
        guard (200..<300).contains(response.statusCode) else {
            throw MWFirmwareError.badServerResponse(status: response.statusCode)
        }
        return try MWFirmwareCatalog.parse(data)
    }
}
