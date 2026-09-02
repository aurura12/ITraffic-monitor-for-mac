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

    func testParsesExternalInterfaceCountersOnlyOncePerLinkInterface() {
        let output = """
        Name       Mtu   Network            Address            Ipkts Ierrs    Ibytes    Opkts Oerrs    Obytes Coll
        en0        1500  <Link#...>         xx:xx             100   0        8000      90   0        7000   0
        en0        1500  192.168.1         192.168.1.20       100   0           0      90   0           0   0
        en1        1500  <Link#...>         yy:yy              10   0        1200      12   0        2400   0
        utun2      1380  <Link#...>         zz:zz              10   0        9000      12   0        9000   0
        """

        XCTAssertEqual(
            parseExternalInterfaceCounters(output),
            UTunInterfaceCounters(inBytes: 9200, outBytes: 9400)
        )
    }

    func testExternalCounterRollbackProducesNoDelta() {
        XCTAssertNil(interfaceCounterDelta(
            previous: UTunInterfaceCounters(inBytes: 100, outBytes: 200),
            current: UTunInterfaceCounters(inBytes: 90, outBytes: 250)
        ))
    }

    func testNettopSamplingStatusMarksRestartAndRecoversOnFrame() {
        XCTAssertEqual(
            nextNettopSamplingStatus(.active, event: .restart),
            .restarting
        )
        XCTAssertEqual(
            nextNettopSamplingStatus(.restarting, event: .frame),
            .active
        )
    }

    func testFreeAttributionCompatibilityPathNeverChangesRawEntities() {
        let entities = [
            ProcessEntity(pid: 10, name: "Safari", inBytes: 600, outBytes: 200)
        ]

        let result = calibrateFreeAttribution(
            entities: entities,
            reference: UTunTrafficCounters(inBytes: 1_000, outBytes: 300)
        )

        XCTAssertEqual(result.confidence, .noReference)
        XCTAssertEqual(result.entities.count, entities.count)
        XCTAssertEqual(result.entities.first?.pid, entities.first?.pid)
        XCTAssertEqual(result.entities.first?.name, entities.first?.name)
        XCTAssertEqual(result.entities.first?.inBytes, entities.first?.inBytes)
        XCTAssertEqual(result.entities.first?.outBytes, entities.first?.outBytes)
        XCTAssertEqual(result.positiveGap, UTunTrafficCounters(inBytes: 0, outBytes: 0))
    }

    func testMenuBarSnapshotNormalizesRatesAndReportsIdleState() {
        let snapshot = MenuBarSnapshot(downloadRate: -10, uploadRate: 0)

        XCTAssertEqual(snapshot.downloadRate, 0)
        XCTAssertEqual(snapshot.uploadRate, 0)
        XCTAssertTrue(snapshot.isIdle)
    }

    func testMenuBarRateTextPlacesUploadAboveDownloadInCompactRows() {
        let text = MenuBarRateText(downloadRate: 1_572_864, uploadRate: 327_680)

        XCTAssertEqual(text.rows, ["↑ 320K/s", "↓ 1.5M/s"])
    }

    func testMenuBarLayoutUsesNarrowStatusItem() {
        XCTAssertEqual(MenuBarLayout.statusItemWidth, 62)
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
