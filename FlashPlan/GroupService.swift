import Foundation
import SwiftData

enum JoinError: LocalizedError, Equatable {
    case invalidCode
    case networkUnavailable
    case serverError

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            return "That join code isn't valid. Check the code and try again."
        case .networkUnavailable:
            return "You're offline. Please check your connection and try again."
        case .serverError:
            return "We couldn’t join the group right now. Please try again later."
        }
    }
}

final class GroupService {
    static let shared = GroupService()
    private init() {}

    // Simulated async join call. Replace with real networking later.
    func joinGroup(code: String) async throws -> Group {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // Basic validation
        guard !trimmed.isEmpty, trimmed.count >= 4 else { throw JoinError.invalidCode }

        // Simulate latency
        try await Task.sleep(nanoseconds: 400_000_000)

        // In a real implementation, make a network call here and decode a Group
        // For now, accept any non-empty code and fabricate a Group
        // If you already have a convenience initializer for Group, adjust as needed
        return Group(name: "Group " + trimmed.uppercased(), code: trimmed.uppercased())
    }
}
