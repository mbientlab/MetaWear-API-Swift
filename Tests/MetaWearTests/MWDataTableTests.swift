import Testing
import Foundation
@testable import MetaWear

// MARK: - MWDataConvertible conformances

@Suite("MWDataConvertible")
struct MWDataConvertibleTests {

    // MARK: CartesianFloat

    @Test func cartesianFloat_headers() {
        #expect(CartesianFloat.columnHeaders == ["x", "y", "z"])
    }

    @Test func cartesianFloat_values_positiveAndNegative() {
        let v = CartesianFloat(x: 1.0, y: -2.5, z: 0.0)
        let vals = v.columnValues
        #expect(vals.count == 3)
        #expect(vals[0] == "1.000000")
        #expect(vals[1] == "-2.500000")
        #expect(vals[2] == "0.000000")
    }

    // MARK: Quaternion

    @Test func quaternion_headers() {
        #expect(Quaternion.columnHeaders == ["w", "x", "y", "z"])
    }

    @Test func quaternion_unitValues() {
        let q = Quaternion(w: 1.0, x: 0.0, y: 0.0, z: 0.0)
        let vals = q.columnValues
        #expect(vals.count == 4)
        #expect(vals[0] == "1.000000")
        #expect(vals[1] == "0.000000")
    }

    // MARK: EulerAngles

    @Test func eulerAngles_headers() {
        #expect(EulerAngles.columnHeaders == ["heading", "pitch", "roll", "yaw"])
    }

    @Test func eulerAngles_values() {
        let e = EulerAngles(heading: 90.0, pitch: -45.0, roll: 0.0, yaw: 180.0)
        let vals = e.columnValues
        #expect(vals.count == 4)
        #expect(vals[0] == "90.0000")
        #expect(vals[1] == "-45.0000")
    }

    // MARK: CorrectedCartesianFloat

    @Test func correctedCartesian_headers() {
        #expect(CorrectedCartesianFloat.columnHeaders == ["x", "y", "z", "accuracy"])
    }

    @Test func correctedCartesian_includesAccuracy() {
        let v = CorrectedCartesianFloat(x: 1.0, y: 0.0, z: 0.0, accuracy: 3)
        let vals = v.columnValues
        #expect(vals.count == 4)
        #expect(vals[3] == "3")
    }

    // MARK: Float

    @Test func float_header() {
        #expect(Float.columnHeaders == ["value"])
    }

    @Test func float_value() {
        let f: Float = 3.14
        #expect(f.columnValues.count == 1)
        #expect(f.columnValues[0] == "3.140000")
    }

    // MARK: Bool

    @Test func bool_header() {
        #expect(Bool.columnHeaders == ["value"])
    }

    @Test func bool_trueIsOne() {
        #expect(true.columnValues == ["1"])
    }

    @Test func bool_falseIsZero() {
        #expect(false.columnValues == ["0"])
    }
}

// MARK: - MWDataTable factory

@Suite("MWDataTable Factory")
struct MWDataTableFactoryTests {

    // MARK: Streamed

    @Test func streamed_columns_includeEpochThenSensorHeaders() {
        let samples = [Timestamped(time: Date(timeIntervalSince1970: 0),
                                   value: CartesianFloat(x: 1, y: 2, z: 3))]
        let table = MWDataTable.from(streamed: samples, name: "accel")
        #expect(table.name == "accel")
        #expect(table.columns == ["epoch", "x", "y", "z"])
    }

    @Test func streamed_rowCount_matchesSamples() {
        let samples = (0..<5).map { i in
            Timestamped(time: Date(timeIntervalSince1970: Double(i)),
                        value: CartesianFloat(x: Float(i), y: 0, z: 0))
        }
        let table = MWDataTable.from(streamed: samples, name: "t")
        #expect(table.rows.count == 5)
    }

    @Test func streamed_rowColumnCount_matchesHeaders() {
        let samples = [Timestamped(time: Date(), value: CartesianFloat(x: 0, y: 0, z: 1))]
        let table = MWDataTable.from(streamed: samples, name: "t")
        #expect(table.rows[0].count == table.columns.count)
    }

    @Test func streamed_empty_hasNoRows() {
        let table = MWDataTable.from(streamed: [Timestamped<CartesianFloat>](), name: "t")
        #expect(table.rows.isEmpty)
        #expect(table.columns == ["epoch", "x", "y", "z"])
    }

    // MARK: Logged

    @Test func logged_columns_includeEpochElapsedThenSensorHeaders() {
        let s = MWLoggedSample(date: Date(timeIntervalSince1970: 0), tickMs: 0, value: CartesianFloat(x: 0, y: 0, z: 1))
        let table = MWDataTable.from(logged: [s], name: "log")
        #expect(table.columns == ["epoch", "elapsed_ms", "x", "y", "z"])
    }

    @Test func logged_elapsedMs_formattedToThreeDecimals() {
        let s = MWLoggedSample(date: Date(timeIntervalSince1970: 0), tickMs: 1234.5, value: CartesianFloat(x: 0, y: 0, z: 0))
        let table = MWDataTable.from(logged: [s], name: "t")
        #expect(table.rows[0][1] == "1234.500")
    }

    @Test func logged_rowColumnCount_matchesHeaders() {
        let s = MWLoggedSample(date: Date(), tickMs: 0, value: Quaternion(w: 1, x: 0, y: 0, z: 0))
        let table = MWDataTable.from(logged: [s], name: "t")
        #expect(table.rows[0].count == table.columns.count)
    }
}

// MARK: - MWDataTable CSV

@Suite("MWDataTable CSV")
struct MWDataTableCSVTests {

    @Test func csvString_firstLineIsHeader() {
        let table = MWDataTable(name: "t", columns: ["a", "b"], rows: [["1", "2"]])
        let lines = table.csvString.components(separatedBy: "\n")
        #expect(lines[0] == "a,b")
    }

    @Test func csvString_dataRows() {
        let table = MWDataTable(name: "t", columns: ["a", "b"], rows: [["1", "2"], ["3", "4"]])
        let lines = table.csvString.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[1] == "1,2")
        #expect(lines[2] == "3,4")
    }

    @Test func csvString_emptyRows_onlyHeader() {
        let table = MWDataTable(name: "t", columns: ["a", "b"], rows: [])
        let lines = table.csvString.components(separatedBy: "\n")
        #expect(lines.count == 1)
        #expect(lines[0] == "a,b")
    }

    @Test func csvString_quotesFieldWithComma() {
        let table = MWDataTable(name: "t", columns: ["v"], rows: [["hello,world"]])
        #expect(table.csvString.contains("\"hello,world\""))
    }

    @Test func csvString_quotesFieldWithQuote() {
        let table = MWDataTable(name: "t", columns: ["v"], rows: [["say \"hi\""]])
        // Should be escaped: "say ""hi"""
        #expect(table.csvString.contains("\"say \"\"hi\"\"\""))
    }

    @Test func csvString_plainField_notQuoted() {
        let table = MWDataTable(name: "t", columns: ["v"], rows: [["1.234"]])
        #expect(!table.csvString.contains("\""))
    }

    @Test func csvRoundtrip_columnCount() {
        let samples = [Timestamped(time: Date(timeIntervalSince1970: 1000),
                                   value: CartesianFloat(x: 1.0, y: 2.0, z: 3.0))]
        let table = MWDataTable.from(streamed: samples, name: "accel")
        let lines = table.csvString.components(separatedBy: "\n")
        let headerCols = lines[0].components(separatedBy: ",").count
        let dataCols   = lines[1].components(separatedBy: ",").count
        #expect(headerCols == dataCols)
        #expect(headerCols == 4)  // epoch + x + y + z
    }
}
