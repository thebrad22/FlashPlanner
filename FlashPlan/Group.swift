//
//  Group.swift
//  FlashPlan
//
//  Created by Bradly Belcher on 2/4/26.
//

import Foundation
import SwiftData

@Model
final class Group {
    // Stable identifier for navigation and equality checks
    var id: UUID
    
    // Display name for the group
    var name: String
    
    // Join code for the group (assumed unique for demo purposes)
    @Attribute(.unique) var code: String
    
    init(id: UUID = UUID(), name: String, code: String) {
        self.id = id
        self.name = name
        self.code = code
    }
}
