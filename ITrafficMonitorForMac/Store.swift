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
    static let globalModel = GlobalModel()
    static let recorder = TrafficRecorder()
    static let realtimeRateStore = RealtimeRateStore()
    static let perAppRateStore = PerAppRateStore()
}

extension View {
    func withGlobalEnvironmentObjects() -> some View {
        environmentObject(SharedStore.listViewModel)
        .environmentObject(SharedStore.statusDataModel)
        .environmentObject(SharedStore.globalModel)
        .environmentObject(SharedStore.realtimeRateStore)
        .environmentObject(SharedStore.perAppRateStore)
    }
}
