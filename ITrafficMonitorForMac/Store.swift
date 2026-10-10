//
//  Store.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//

import SwiftUI

enum SharedStore {
    static let statusDataModel = StatusDataModel()
    static let recorder = TrafficRecorder()
    static let trafficSamplingDiagnostics = TrafficSamplingDiagnostics()
}

extension View {
    func withGlobalEnvironmentObjects() -> some View {
        environmentObject(SharedStore.statusDataModel)
        .environmentObject(LocalizationManager.shared)
    }
}
