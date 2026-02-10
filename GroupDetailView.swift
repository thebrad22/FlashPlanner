import SwiftUI

struct Group: Identifiable {
    let id = UUID()
    let name: String
    let code: String
}

struct GroupDetailView: View {
    let group: Group
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(group.name)
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Code: \(group.code)")
                .font(.title2)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding()
    }
}

#Preview {
    GroupDetailView(group: Group(name: "Sample Group", code: "ABC123"))
}
