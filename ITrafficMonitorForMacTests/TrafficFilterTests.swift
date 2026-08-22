import XCTest
@testable import ITraffic

final class TrafficFilterTests: XCTestCase {
    func testTrafficFilterRecordRoundTripsThroughJSON() throws {
        let record = TrafficFilterRecord(
            schemaVersion: 1,
            sequence: 7,
            timestamp: 100,
            appKey: "com.google.Chrome",
            displayName: "Google Chrome",
            inBytes: 120,
            outBytes: 30,
            flowCount: 2
        )

        let data = try JSONEncoder().encode(record)

        XCTAssertEqual(try JSONDecoder().decode(TrafficFilterRecord.self, from: data), record)
    }

    func testAggregateCombinesBytesByApp() {
        var aggregate = TrafficFilterAggregate()
        aggregate.add(
            appKey: "com.google.Chrome",
            displayName: "Google Chrome",
            inBytes: 100,
            outBytes: 20
        )
        aggregate.add(
            appKey: "com.google.Chrome",
            displayName: "Google Chrome",
            inBytes: 50,
            outBytes: 5
        )

        let records = aggregate.flush(timestamp: 100, startingSequence: 10)

        XCTAssertEqual(records, [TrafficFilterRecord(
            schemaVersion: 1,
            sequence: 10,
            timestamp: 100,
            appKey: "com.google.Chrome",
            displayName: "Google Chrome",
            inBytes: 150,
            outBytes: 25,
            flowCount: 2
        )])
    }

    func testSequenceConsumerDoesNotReturnDuplicateRecords() {
        let records = [TrafficFilterRecord(
            schemaVersion: 1,
            sequence: 3,
            timestamp: 100,
            appKey: "com.apple.Safari",
            displayName: "Safari",
            inBytes: 4,
            outBytes: 2,
            flowCount: 1
        )]

        var consumer = TrafficFilterSequenceConsumer(lastSequence: 3)

        XCTAssertTrue(consumer.consume(records).isEmpty)
    }

    func testMissingSourceAppFallsBackToClash() {
        XCTAssertEqual(normalizedTrafficAppKey(sourceAppIdentifier: nil), "Clash Verge")
    }

    func testBundleIDIsUsedAsStableAppKey() {
        XCTAssertEqual(
            normalizedTrafficAppKey(sourceAppIdentifier: "com.apple.Safari"),
            "com.apple.Safari"
        )
    }

    func testReportAccumulatorSeparatesAppsAndDirections() {
        var accumulator = TrafficFilterReportAccumulator()
        accumulator.consume(ReportInput(
            appKey: "com.google.Chrome",
            displayName: "Google Chrome",
            inBytes: 100,
            outBytes: 20
        ))
        accumulator.consume(ReportInput(
            appKey: "com.google.Chrome",
            displayName: "Google Chrome",
            inBytes: 50,
            outBytes: 5
        ))

        let records = accumulator.flush(timestamp: 200, startingSequence: 1)

        XCTAssertEqual(records[0].inBytes, 150)
        XCTAssertEqual(records[0].outBytes, 25)
        XCTAssertEqual(records[0].flowCount, 2)
    }

    func testReportAccumulatorFallsBackToClashForMissingApp() {
        var accumulator = TrafficFilterReportAccumulator()
        accumulator.consume(ReportInput(
            appKey: "Clash Verge",
            displayName: "Clash Verge",
            inBytes: 8,
            outBytes: 3
        ))

        XCTAssertEqual(
            accumulator.flush(timestamp: 200, startingSequence: 1).first?.appKey,
            "Clash Verge"
        )
    }

    func testStatsStoreConsumesEachSequenceOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("traffic-filter-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try TrafficFilterStatsStore(directory: directory)
        try store.write(records: [sampleRecord(sequence: 1), sampleRecord(sequence: 2)])

        XCTAssertEqual(try store.readNewRecords().map(\.sequence), [1, 2])
        try store.markConsumedThrough(sequence: 2)
        XCTAssertTrue(try store.readNewRecords().isEmpty)
    }

    func testTrafficTotalsReportSmallExpectedDifference() {
        let result = reconcileTrafficTotals(
            filterTotal: 1_000,
            attributedTotal: 990,
            unattributedTotal: 5
        )

        XCTAssertEqual(result.status, .withinTolerance)
    }

    func testTrafficTotalsReportLargeDifference() {
        let result = reconcileTrafficTotals(
            filterTotal: 1_000_000,
            attributedTotal: 700_000,
            unattributedTotal: 5
        )

        XCTAssertEqual(result.status, .mismatch)
    }

    func testParsesOnlyUtunInterfaceCounters() {
        let output = """
        Name       Mtu   Network       Address            Ipkts Ierrs    Ibytes    Opkts Oerrs    Obytes Coll
        en0        1500  <Link#...>    xx:xx             100   0        8000      90   0        7000   0
        utun2      1380  <Link#...>    xx:xx              10   0        1200      12   0        2400   0
        utun3      1380  <Link#...>    xx:xx               5   0         300       4   0         500   0
        """

        XCTAssertEqual(
            parseUTunInterfaceCounters(output),
            UTunInterfaceCounters(inBytes: 1500, outBytes: 2900)
        )
    }

    func testUtunCounterRollbackProducesNoDelta() {
        XCTAssertNil(utunDelta(
            previous: UTunInterfaceCounters(inBytes: 100, outBytes: 200),
            current: UTunInterfaceCounters(inBytes: 90, outBytes: 250)
        ))
    }

    func testFreeCalibrationDistributesPositiveGapToActiveApp() {
        let entities = [
            ProcessEntity(pid: 10, name: "Safari", inBytes: 600, outBytes: 200)
        ]

        let result = calibrateFreeAttribution(
            entities: entities,
            reference: UTunTrafficCounters(inBytes: 1_000, outBytes: 300)
        )

        XCTAssertEqual(result.confidence, .calibratedWithProxyFallback)
        XCTAssertEqual(result.entities.map(\.inBytes).reduce(0, +), 1_000)
        XCTAssertEqual(result.entities.map(\.outBytes).reduce(0, +), 300)
        XCTAssertEqual(result.entities.last?.name, "Safari")
        XCTAssertEqual(result.entities.last?.inBytes, 1_000)
        XCTAssertEqual(result.entities.last?.outBytes, 300)
        XCTAssertTrue(result.entities.allSatisfy { $0.name != "Clash Verge" })
    }

    func testFreeCalibrationDistributesGapProportionallyAcrossApps() {
        let entities = [
            ProcessEntity(pid: 11, name: "Safari", inBytes: 600, outBytes: 0),
            ProcessEntity(pid: 12, name: "Chrome", inBytes: 200, outBytes: 0),
            ProcessEntity(pid: 13, name: "Clash Verge", inBytes: 0, outBytes: 0)
        ]

        let result = calibrateFreeAttribution(
            entities: entities,
            reference: UTunTrafficCounters(inBytes: 1_000, outBytes: 0)
        )

        // Gap is 200 (1_000 - 800). Safari gets 3/4 (150), Chrome 1/4 (50).
        XCTAssertEqual(result.confidence, .calibratedWithProxyFallback)
        XCTAssertEqual(result.entities.map(\.inBytes).reduce(0, +), 1_000)
        XCTAssertEqual(result.entities.first { $0.name == "Safari" }?.inBytes, 750)
        XCTAssertEqual(result.entities.first { $0.name == "Chrome" }?.inBytes, 250)
        XCTAssertTrue(result.entities.allSatisfy { $0.name != "Clash Verge" })
    }

    func testFreeCalibrationClearsClashResidualWhenAppsExist() {
        let entities = [
            ProcessEntity(pid: 11, name: "Chrome", inBytes: 800, outBytes: 100),
            ProcessEntity(pid: 13, name: "Clash Verge", inBytes: 200, outBytes: 50)
        ]

        let result = calibrateFreeAttribution(
            entities: entities,
            reference: UTunTrafficCounters(inBytes: 1_000, outBytes: 150)
        )

        // Attributed total matches the reference (gap = 0), but the residual on
        // the Clash Verge row is still redistributed to the active app and the
        // now-empty fallback row is dropped from the frame.
        XCTAssertEqual(result.confidence, .calibratedWithProxyFallback)
        XCTAssertEqual(result.entities.map(\.inBytes).reduce(0, +), 1_000)
        XCTAssertEqual(result.entities.map(\.outBytes).reduce(0, +), 150)
        XCTAssertEqual(result.entities.first { $0.name == "Chrome" }?.inBytes, 1_000)
        XCTAssertEqual(result.entities.first { $0.name == "Chrome" }?.outBytes, 150)
        XCTAssertTrue(result.entities.allSatisfy { $0.name != "Clash Verge" })
    }

    func testFreeCalibrationFallsBackToClashWhenNoActiveApp() {
        let entities = [
            ProcessEntity(pid: 13, name: "Clash Verge", inBytes: 100, outBytes: 20)
        ]

        let result = calibrateFreeAttribution(
            entities: entities,
            reference: UTunTrafficCounters(inBytes: 200, outBytes: 40)
        )

        XCTAssertEqual(result.confidence, .calibratedWithProxyFallback)
        XCTAssertEqual(result.entities.map(\.inBytes).reduce(0, +), 200)
        XCTAssertEqual(result.entities.map(\.outBytes).reduce(0, +), 40)
        XCTAssertEqual(result.entities.first { $0.name == "Clash Verge" }?.inBytes, 200)
        XCTAssertEqual(result.entities.first { $0.name == "Clash Verge" }?.outBytes, 40)
    }

    func testFreeCalibrationDoesNotInventBytesWhenReferenceIsLower() {
        let entities = [
            ProcessEntity(pid: 10, name: "Safari", inBytes: 600, outBytes: 200)
        ]

        let result = calibrateFreeAttribution(
            entities: entities,
            reference: UTunTrafficCounters(inBytes: 500, outBytes: 100)
        )

        XCTAssertEqual(result.confidence, .referenceMismatch)
        XCTAssertEqual(result.entities.map(\.inBytes).reduce(0, +), 600)
        XCTAssertEqual(result.entities.map(\.outBytes).reduce(0, +), 200)
        XCTAssertTrue(result.entities.allSatisfy { $0.name != "Clash Verge" })
    }

    private func sampleRecord(sequence: Int64) -> TrafficFilterRecord {
        TrafficFilterRecord(
            schemaVersion: 1,
            sequence: sequence,
            timestamp: 100,
            appKey: "com.apple.Safari",
            displayName: "Safari",
            inBytes: 4,
            outBytes: 2,
            flowCount: 1
        )
    }
}
