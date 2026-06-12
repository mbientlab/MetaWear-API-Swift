//
//  String+MetaWearVersion.swift
//  MetaWearFirmware
//
//  Numeric version-string comparison for MetaWear firmware revisions.
//
//  MbientLab firmware versions follow loose dotted-numeric form ("1.5.0",
//  "1.5", "1.7.3"). The legacy Combine SDK exposed these helpers as a public
//  String extension; we keep them internal here because the only caller is
//  the firmware update pipeline.
//
//  Same rules as `String.compare(_:options: .numeric)`, padded with zeros so
//  "1.5" == "1.5.0". Ported from
//  `MetaWear-Swift-Combine-SDK/Sources/MetaWear/Helpers/String+VersionCompare.swift`.
//

import Foundation

extension String {

    /// Compare two MetaWear-style dotted version strings ("1.5.0", "1.5", "1.7.3").
    /// Components are compared numerically; if one string has fewer components
    /// the shorter is right-padded with zeros so "1.5" sorts equal to "1.5.0".
    fileprivate func compare(toVersion targetVersion: String) -> ComparisonResult {
        let delimiter = "."
        var versionComponents = components(separatedBy: delimiter)
        var targetComponents  = targetVersion.components(separatedBy: delimiter)
        let spareCount = versionComponents.count - targetComponents.count

        if spareCount == 0 {
            return compare(targetVersion, options: .numeric)
        }
        let pad = repeatElement("0", count: abs(spareCount))
        if spareCount > 0 {
            targetComponents.append(contentsOf: pad)
        } else {
            versionComponents.append(contentsOf: pad)
        }
        return versionComponents.joined(separator: delimiter)
            .compare(targetComponents.joined(separator: delimiter), options: .numeric)
    }

    func isMetaWearVersion(equalTo other: String) -> Bool {
        compare(toVersion: other) == .orderedSame
    }

    func isMetaWearVersion(greaterThan other: String) -> Bool {
        compare(toVersion: other) == .orderedDescending
    }

    func isMetaWearVersion(greaterThanOrEqualTo other: String) -> Bool {
        compare(toVersion: other) != .orderedAscending
    }

    func isMetaWearVersion(lessThan other: String) -> Bool {
        compare(toVersion: other) == .orderedAscending
    }

    func isMetaWearVersion(lessThanOrEqualTo other: String) -> Bool {
        compare(toVersion: other) != .orderedDescending
    }
}
