import SwiftUI

/// The current cover, blurred and dimmed, behind sheets: settings and the queue take their colour
/// from the song, like the player itself. Static, so it costs nothing while scrolling.
struct ArtworkBackdrop: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let gradient = settings.appTheme.gradient {
            Rectangle().fill(gradient)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        } else {
            coverBackdrop
        }
    }

    private var coverBackdrop: some View {
        // The black base decides the size; the cover is only painted over it and clipped.
        Color.black
            .overlay {
                AsyncImage(url: player.track?.artworkURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .saturation(1.35)
                            .blur(radius: 70, opaque: true)
                            .scaleEffect(1.4)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.6), value: player.track?.artworkURL)
            }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

extension View {
    /// A settings page on the cover backdrop instead of flat grey.
    func settingsPage() -> some View {
        scrollContentBackground(.hidden)
            .background { ArtworkBackdrop() }
    }
}

/// Press feedback shared by the custom buttons: a quick squeeze, then a spring back.
struct SquishButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.62),
                       value: configuration.isPressed)
    }
}

/// Four bars bouncing out of phase: "this one is playing". Still when paused or with Reduce Motion.
struct EqualizerBars: View {
    var playing: Bool
    var color: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !playing || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 4 + 12 * level(time, index))
                }
            }
            .frame(height: 16, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    private func level(_ time: Double, _ index: Int) -> Double {
        guard playing, !reduceMotion else { return 0.3 }
        let i = Double(index)
        return 0.5 + 0.5 * sin(time * (3.2 + i * 1.3) + i * 1.7)
    }
}
