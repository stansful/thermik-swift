import CoreGraphics

enum PopoverPanelSizing {
    case automatic(maxHeight: CGFloat)
    case custom(height: CGFloat)
}

struct PopoverListLayout {
    let maxHeight: CGFloat
    let exactHeight: CGFloat?
}

extension PopoverPanelSizing {
    func listLayout(headerHeight: CGFloat, footerHeight: CGFloat) -> PopoverListLayout {
        switch self {
        case .automatic(let height):
            return PopoverListLayout(maxHeight: max(height - headerHeight - footerHeight, 88), exactHeight: nil)
        case .custom(let height):
            let remaining = max(height - headerHeight - footerHeight, 1)
            return PopoverListLayout(maxHeight: remaining, exactHeight: remaining)
        }
    }
}
