import AppKit

/// "Buy Me a Coffee" link, shown in the menu and the setup window.
enum Support {
    /// Your Buy Me a Coffee username (the part after buymeacoffee.com/). Empty = link hidden.
    static let buyMeACoffeeUser = "deco10"

    static var url: URL? {
        buyMeACoffeeUser.isEmpty ? nil : URL(string: "https://buymeacoffee.com/\(buyMeACoffeeUser)")
    }

    static func open() {
        if let url { NSWorkspace.shared.open(url) }
    }
}
