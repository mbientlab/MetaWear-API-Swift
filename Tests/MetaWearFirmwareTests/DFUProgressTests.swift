//
//  DFUProgressTests.swift
//  MetaWearFirmwareTests
//
//  Coverage for the `DFUProgress` value type. It's a plain struct with
//  defaults, but the defaults define what observers see during non-upload
//  phases, so they're worth pinning.
//

import Foundation
import Testing
@testable import MetaWearFirmware

@Suite("DFUProgress")
struct DFUProgressTests {

    // MARK: - Defaults

    @Test
    func defaults_zeroExceptForState() {
        let progress = DFUProgress(state: .scanning)
        #expect(progress.state == .scanning)
        #expect(progress.percentComplete == 0)
        #expect(progress.currentPart == 1)
        #expect(progress.totalParts == 1)
        #expect(progress.bytesPerSecond == 0)
    }

    @Test
    func uploadingProgress_carriesAllFields() {
        let progress = DFUProgress(
            state: .uploading,
            percentComplete: 42,
            currentPart: 1,
            totalParts: 2,
            bytesPerSecond: 12_345
        )
        #expect(progress.state == .uploading)
        #expect(progress.percentComplete == 42)
        #expect(progress.currentPart == 1)
        #expect(progress.totalParts == 2)
        #expect(progress.bytesPerSecond == 12_345)
    }

    // MARK: - Equatable

    @Test
    func progress_equalWhenAllFieldsMatch() {
        let a = DFUProgress(state: .uploading, percentComplete: 50)
        let b = DFUProgress(state: .uploading, percentComplete: 50)
        #expect(a == b)
    }

    @Test
    func progress_differWhenStatesDiffer() {
        #expect(DFUProgress(state: .uploading) != DFUProgress(state: .completed))
    }

    @Test
    func progress_differWhenPercentDiffers() {
        let a = DFUProgress(state: .uploading, percentComplete: 50)
        let b = DFUProgress(state: .uploading, percentComplete: 51)
        #expect(a != b)
    }

    // MARK: - State enum is exhaustive (compile-time pin)

    @Test
    func stateEnum_coversFullDFULifecycle() {
        // Touch every case so removing one fails compilation. If a new
        // case is added the switch must be updated.
        let states: [DFUProgress.State] = [
            .fetchingCatalog,
            .downloadingFirmware,
            .bootloaderHandoff,
            .scanning,
            .connecting,
            .starting,
            .validating,
            .uploading,
            .disconnecting,
            .completed,
            .aborted
        ]
        for state in states {
            switch state {
            case .fetchingCatalog,
                 .downloadingFirmware,
                 .bootloaderHandoff,
                 .scanning,
                 .connecting,
                 .starting,
                 .validating,
                 .uploading,
                 .disconnecting,
                 .completed,
                 .aborted:
                break
            }
        }
        #expect(states.count == 11)
    }
}
