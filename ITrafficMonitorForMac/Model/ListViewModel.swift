//
//  ListViewModel.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//

import Foundation

class ListViewModel: ObservableObject {

    @Published var items: [ProcessEntity] = []

    public func updateData(newItems: [ProcessEntity]) {
        var pid2IndexForItems = [String: Int]()
        var pidInNewItems = [String: Int]()
        for i in 0..<items.count {
            pid2IndexForItems["\(items[i].pid)"] = i
        }
        
        for newItem in newItems {
            var normalizedItem = newItem
            normalizedItem.name = canonicalProcessDisplayName(newItem.name)
            let i = pid2IndexForItems["\(normalizedItem.pid)"] ?? -1
            if i != -1 {
                items[i].icon = normalizedItem.icon
                items[i].name = normalizedItem.name
                items[i].inBytes = normalizedItem.inBytes
                items[i].outBytes = normalizedItem.outBytes
            } else {
                items.append(normalizedItem)
            }
            pidInNewItems["\(normalizedItem.pid)"] = 1
        }
        
        items = items.filter(){ pidInNewItems["\($0.pid)"] ?? -1 != -1 }
        
        items = sort(items: items)
    }
    
    func sort(items: [ProcessEntity]) -> [ProcessEntity] {
        return items.sorted {  (lhs:ProcessEntity, rhs:ProcessEntity) in
            let lTotalBytes = lhs.inBytes + lhs.outBytes
            let rTotalBytes = rhs.inBytes + rhs.outBytes
            if lTotalBytes != rTotalBytes {
                return lTotalBytes > rTotalBytes
            }
            return lhs.name < rhs.name
        }
    }
}
