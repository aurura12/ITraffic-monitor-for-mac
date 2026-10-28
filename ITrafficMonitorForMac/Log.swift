//
//  Log.swift
//  ITrafficMonitorForMac
//
//  Unified logging entry points. Everything the app reports (database
//  failures, migration outcomes, nettop restarts) goes through os.Logger,
//  because a bundle launched by LaunchServices has no stdout: a print() there
//  is discarded. `scripts/update.sh --telemetry` streams this subsystem, so
//  `subsystem` must stay equal to PRODUCT_BUNDLE_IDENTIFIER in project.yml
//  (scripts/update_test.sh asserts the three stay in sync).
//

import os

enum Log {
    static let subsystem = "com.foamzou.ITrafficMonitorV2"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let db = Logger(subsystem: subsystem, category: "database")
    static let nettop = Logger(subsystem: subsystem, category: "nettop")
    static let recorder = Logger(subsystem: subsystem, category: "recorder")
}
