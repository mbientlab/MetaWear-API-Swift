import Testing
@testable import MetaWearApp

/// Recovered anonymous signals must be labelled in the app's standard sensor
/// vocabulary — `CSVExporter.streamingTag(forLabel:)` derives the export
/// filename's sensor tag from the label's leading display name, so a raw
/// identifier label ("Unknown · acceleration") produced CSVs that said
/// nothing about the sensor. Field-reported on the first successful foreign
/// accelerometer download.
@MainActor
struct ForeignLabelTests {

    @Test func accelerationMapsToAccelerometer() {
        #expect(DownloadViewModel.label(forAnonymousIdentifier: "acceleration")
                == "Accelerometer · Recovered")
    }

    @Test func singleAxisKeepsSensorName() {
        #expect(DownloadViewModel.label(forAnonymousIdentifier: "acceleration[0]")
                == "Accelerometer · Recovered")
    }

    @Test func gyroAndMagMap() {
        #expect(DownloadViewModel.label(forAnonymousIdentifier: "angular-velocity")
                == "Gyroscope · Recovered")
        #expect(DownloadViewModel.label(forAnonymousIdentifier: "magnetic-field")
                == "Magnetometer · Recovered")
    }

    @Test func temperatureChannelMaps() {
        #expect(DownloadViewModel.label(forAnonymousIdentifier: "temperature[1]")
                == "Temperature · Recovered")
    }

    @Test func fusionSignalsUseFusionVocabulary() {
        #expect(DownloadViewModel.label(forAnonymousIdentifier: "quaternion")
                == "Fusion · Quaternion · Recovered")
        #expect(DownloadViewModel.label(forAnonymousIdentifier: "linear-acceleration")
                == "Fusion · Linear Acceleration · Recovered")
    }

    @Test func processorChainStaysVisible() {
        #expect(DownloadViewModel.label(forAnonymousIdentifier: "acceleration:rms?id=0:accumulate?id=1")
                == "Accelerometer · acceleration:rms?id=0:accumulate?id=1")
    }

    @Test func unknownIdentifierFallsBack() {
        #expect(DownloadViewModel.label(forAnonymousIdentifier: "mystery-signal")
                == "Unknown · mystery-signal")
    }

    /// The whole point: the CSV filename tag must resolve to the sensor.
    @Test func labelDrivesTheCSVTag() {
        let label = DownloadViewModel.label(forAnonymousIdentifier: "acceleration")
        #expect(label.hasPrefix("Accelerometer"))
        let fusion = DownloadViewModel.label(forAnonymousIdentifier: "quaternion")
        #expect(fusion.hasPrefix("Fusion · Quaternion"))
    }
}
