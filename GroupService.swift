import Foundation

struct Group {
    let name: String
}

enum JoinError: Error {
    case invalidCode
}

class GroupService {
    static let shared = GroupService()
    private init() {}
    
    func joinGroup(code: String) async throws -> Group {
        try await Task.sleep(nanoseconds: 1_000_000_000) // Simulate 1 second network delay
        guard code.count >= 4 else {
            throw JoinError.invalidCode
        }
        let groupName = "Group_" + code.uppercased()
        return Group(name: groupName)
    }
}
