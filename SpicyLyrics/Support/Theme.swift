import SwiftUI
import UIKit

/// The app's look outside the lyrics' own colours: what is behind everything and the accent of
/// the controls. "Cover" takes both from the song; the others are fixed (and the background does
/// not move, which also costs less battery).
enum AppTheme: String, CaseIterable, Identifiable {
    case cover, midnight, graphite, oled, plum, forest, dusk, ocean

    var id: String { rawValue }

    var isCover: Bool { self == .cover }

    var title: String {
        switch self {
        case .cover: return String(localized: "Обложка")
        case .midnight: return String(localized: "Полночь")
        case .graphite: return String(localized: "Графит")
        case .oled: return "OLED"
        case .plum: return String(localized: "Слива")
        case .forest: return String(localized: "Лес")
        case .dusk: return String(localized: "Закат")
        case .ocean: return String(localized: "Океан")
        }
    }

    /// The background from the top left to the bottom right (empty: the cover decides).
    var colors: [UIColor] {
        switch self {
        case .cover: return []
        case .midnight: return [UIColor(red: 0.06, green: 0.09, blue: 0.20, alpha: 1), UIColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1)]
        case .graphite: return [UIColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1), UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)]
        case .oled: return [.black, .black]
        case .plum: return [UIColor(red: 0.27, green: 0.10, blue: 0.25, alpha: 1), UIColor(red: 0.07, green: 0.03, blue: 0.08, alpha: 1)]
        case .forest: return [UIColor(red: 0.07, green: 0.22, blue: 0.18, alpha: 1), UIColor(red: 0.02, green: 0.07, blue: 0.06, alpha: 1)]
        case .dusk: return [UIColor(red: 0.20, green: 0.14, blue: 0.38, alpha: 1), UIColor(red: 0.36, green: 0.15, blue: 0.20, alpha: 1),
                            UIColor(red: 0.07, green: 0.04, blue: 0.10, alpha: 1)]
        case .ocean: return [UIColor(red: 0.04, green: 0.24, blue: 0.34, alpha: 1), UIColor(red: 0.02, green: 0.07, blue: 0.12, alpha: 1)]
        }
    }

    /// Selected tab, equalizer, toggles and sliders.
    var accent: Color {
        switch self {
        case .cover, .oled: return .white
        case .midnight: return Color(red: 0.56, green: 0.69, blue: 1.0)
        case .graphite: return Color(white: 0.9)
        case .plum: return Color(red: 0.93, green: 0.62, blue: 0.75)
        case .forest: return Color(red: 0.56, green: 0.83, blue: 0.69)
        case .dusk: return Color(red: 1.0, green: 0.71, blue: 0.54)
        case .ocean: return Color(red: 0.46, green: 0.83, blue: 0.91)
        }
    }

    /// Something to draw behind everything; nil for "cover".
    var gradient: LinearGradient? {
        guard !colors.isEmpty else { return nil }
        return LinearGradient(colors: colors.map(Color.init(uiColor:)), startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
