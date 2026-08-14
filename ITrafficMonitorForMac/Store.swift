//
//  Store.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//

import SwiftUI

enum SharedStore {
    static let listViewModel = ListViewModel()
    static let statusDataModel = StatusDataModel()
    static let recorder = TrafficRecorder()
    static let realtimeRateStore = RealtimeRateStore()
    static let perAppRateStore = PerAppRateStore()
    static let proxyAttributor = ProxyAttributor()
    static let utunTrafficSampler = UTunTrafficSampler()
    static let trafficFilterManager = TrafficFilterManager()
}

extension View {
    func withGlobalEnvironmentObjects() -> some View {
        environmentObject(SharedStore.listViewModel)
        .environmentObject(SharedStore.statusDataModel)
        .environmentObject(SharedStore.realtimeRateStore)
        .environmentObject(SharedStore.perAppRateStore)
        .environmentObject(SharedStore.proxyAttributor)
        .environmentObject(LocalizationManager.shared)
    }
}
