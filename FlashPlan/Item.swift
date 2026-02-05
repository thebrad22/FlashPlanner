//
//  Item.swift
//  FlashPlan
//
//  Created by Bradly Belcher on 2/4/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
