import SwiftUI

/// The app's candy palette: soft pink, peach, lilac, mint and sky. The lyrics keep the colours of
/// the cover; these are for everything the app draws itself (settings, queue, first run, and the
/// background before a cover has loaded).
enum Sweet {
    static let pink = Color(red: 1.0, green: 0.48, blue: 0.66)
    static let peach = Color(red: 1.0, green: 0.66, blue: 0.53)
    static let lilac = Color(red: 0.71, green: 0.55, blue: 1.0)
    static let mint = Color(red: 0.42, green: 0.89, blue: 0.76)
    static let sky = Color(red: 0.47, green: 0.77, blue: 1.0)
    static let butter = Color(red: 1.0, green: 0.85, blue: 0.48)
    static let coral = Color(red: 1.0, green: 0.52, blue: 0.52)

    /// Pink into peach: buttons and the selected tab.
    static let gradient = LinearGradient(colors: [pink, peach], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// A deep plum night with a pink glow: the background where there is no cover (yet).
    static let night = LinearGradient(
        colors: [Color(red: 0.24, green: 0.09, blue: 0.27), Color(red: 0.12, green: 0.06, blue: 0.16)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}
