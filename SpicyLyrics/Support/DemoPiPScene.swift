#if DEBUG
import SwiftUI

/// The README's PiP recording (`-demoPiP YES` in the Simulator, which has no Picture in
/// Picture): the floating window's real frames, over a stand-in home screen.
struct DemoPiPScene: View {
    let pip: LyricsPictureInPicture

    private struct App: Identifiable {
        let name: String
        let symbol: String
        let colors: [Color]
        var glyph: Color = .white
        var id: String { name }
    }

    private static let green = [Color(red: 0.4, green: 0.88, blue: 0.4), Color(red: 0.1, green: 0.7, blue: 0.3)]
    private static let apps: [App] = [
        App(name: "FaceTime", symbol: "video.fill", colors: green),
        App(name: "Calendar", symbol: "calendar", colors: [.white, Color(white: 0.92)], glyph: .red),
        App(name: "Photos", symbol: "camera.macro", colors: [.white, Color(white: 0.92)], glyph: .orange),
        App(name: "Camera", symbol: "camera.fill", colors: [Color(white: 0.6), Color(white: 0.35)]),
        App(name: "Mail", symbol: "envelope.fill", colors: [Color(red: 0.3, green: 0.75, blue: 1), .blue]),
        App(name: "Notes", symbol: "note.text", colors: [Color(red: 1, green: 0.85, blue: 0.3), .orange]),
        App(name: "Reminders", symbol: "checklist", colors: [.white, Color(white: 0.92)], glyph: .blue),
        App(name: "Clock", symbol: "clock.fill", colors: [Color(white: 0.18), .black]),
        App(name: "Maps", symbol: "map.fill", colors: [Color(red: 0.45, green: 0.85, blue: 0.5), Color(red: 0.2, green: 0.6, blue: 0.9)]),
        App(name: "Weather", symbol: "cloud.sun.fill", colors: [Color(red: 0.35, green: 0.65, blue: 1), Color(red: 0.1, green: 0.3, blue: 0.8)]),
        App(name: "Books", symbol: "book.fill", colors: [Color(red: 1, green: 0.65, blue: 0.2), Color(red: 0.95, green: 0.45, blue: 0.1)]),
        App(name: "Podcasts", symbol: "mic.fill", colors: [Color(red: 0.8, green: 0.4, blue: 1), Color(red: 0.5, green: 0.2, blue: 0.8)]),
        App(name: "App Store", symbol: "a.circle.fill", colors: [Color(red: 0.25, green: 0.75, blue: 1), .blue]),
        App(name: "Health", symbol: "heart.fill", colors: [.white, Color(white: 0.92)], glyph: .pink),
        App(name: "Wallet", symbol: "wallet.pass.fill", colors: [Color(white: 0.22), .black]),
        App(name: "Settings", symbol: "gearshape.fill", colors: [Color(white: 0.65), Color(white: 0.42)]),
    ]
    private static let dock: [App] = [
        App(name: "Phone", symbol: "phone.fill", colors: green),
        App(name: "Safari", symbol: "safari.fill", colors: [.white, Color(white: 0.92)], glyph: .blue),
        App(name: "Messages", symbol: "message.fill", colors: green),
        App(name: "Music", symbol: "music.note", colors: [Color(red: 1, green: 0.4, blue: 0.5), .red]),
    ]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let icon = (width - 28 * 2 - 22 * 3) / 4
            ZStack(alignment: .top) {
                // Wallpaper.
                ZStack {
                    LinearGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.35), Color(red: 0.45, green: 0.2, blue: 0.6),
                                            Color(red: 0.1, green: 0.15, blue: 0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(Color(red: 1, green: 0.75, blue: 0.4).opacity(0.55))
                        .frame(width: width * 1.1).blur(radius: 60).offset(x: -width * 0.35, y: -width * 0.6)
                    Circle().fill(Color(red: 0.2, green: 0.5, blue: 1).opacity(0.5))
                        .frame(width: width).blur(radius: 70).offset(x: width * 0.4, y: width * 0.7)
                }
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(icon), spacing: 22), count: 4), spacing: 18) {
                        ForEach(Self.apps) { app in
                            VStack(spacing: 5) {
                                iconView(app, size: icon)
                                Text(app.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.3), radius: 2)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 64 + (width - 32) / 2 + 28)
                    Spacer()
                    HStack(spacing: 22) {
                        ForEach(Self.dock) { app in iconView(app, size: icon) }
                    }
                    .padding(16)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .padding(.bottom, 14)
                }
                .frame(width: width)

                PictureInPictureHost(pip: pip)
                    .frame(width: width - 32, height: (width - 32) / 2)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    .padding(.top, 64)
            }
        }
        .allowsHitTesting(false)
    }

    private func iconView(_ app: App, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: app.colors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: app.symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(app.glyph)
            }
    }
}
#endif
