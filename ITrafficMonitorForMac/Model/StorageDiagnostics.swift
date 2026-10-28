//
//  StorageDiagnostics.swift
//  ITrafficMonitorForMac
//
//  Whether the on-disk store can actually be read and written. Before this,
//  a failed open was only a log line: the dashboard then showed zero traffic
//  with no explanation, which reads as "the app is broken" rather than
//  "storage is broken". Settings surfaces the state instead.
//

import Foundation

enum TrafficStorageState: Equatable {
    /// Nothing has been opened yet (launch, or the store is still migrating).
    case opening
    case ready
    /// The store could not be opened or has no query surface; the associated
    /// value is the sqlite message shown in Settings.
    case failed(String)
}

final class TrafficStorageDiagnostics: ObservableObject {
    @Published private(set) var state: TrafficStorageState = .opening

    private let lock = NSLock()
    private var value: TrafficStorageState = .opening

    /// Called on the database queue once the store is proven usable.
    func markReady() {
        publish(.ready)
    }

    /// Called on the database queue when the store cannot serve history.
    func markFailed(_ reason: String) {
        publish(.failed(reason))
    }

    private func publish(_ next: TrafficStorageState) {
        lock.lock()
        guard value != next else {
            lock.unlock()
            return
        }
        value = next
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.state = next
        }
    }
}
