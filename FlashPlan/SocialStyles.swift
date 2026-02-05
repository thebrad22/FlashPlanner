import SwiftUI

struct SocialListModifier: ViewModifier {
    let background: AnyView
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(background)
    }
}

extension View {
    func socialListBackground(_ bg: some View) -> some View {
        modifier(SocialListModifier(background: AnyView(bg)))
    }
}
