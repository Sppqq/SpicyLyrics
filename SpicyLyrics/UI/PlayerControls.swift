import AVKit
import MediaPlayer
import QuartzCore
import SwiftUI

/// Apple Music style transport: scrubber, play controls, volume and the bottom icon row.
struct PlaybackBar: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    /// Called on every touch, so the auto-hide timer starts over.
    var onInteraction: () -> Void = {}
    var onShowQueue: () -> Void = {}
    var onHideControls: () -> Void = {}
    /// False while the controls are faded out: the scrubber stops ticking.
    var isVisible = true
    /// Landscape: tighter spacing and no bottom icon row (it does not fit beside the lyrics).
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            Scrubber(onInteraction: onInteraction, isVisible: isVisible)
                .padding(.bottom, compact ? 4 : 14)

            HStack(spacing: 0) {
                TransportButton(systemName: "backward.fill", size: 30, height: compact ? 52 : 64) {
                    onInteraction()
                    player.previous()
                }
                TransportButton(systemName: player.isPlaying ? "pause.fill" : "play.fill", size: 42, height: compact ? 52 : 64) {
                    onInteraction()
                    player.togglePlay()
                }
                TransportButton(systemName: "forward.fill", size: 30, height: compact ? 52 : 64) {
                    onInteraction()
                    player.next()
                }
            }
            .padding(.bottom, compact ? 6 : 18)

            if settings.showVolumeSlider {
                VolumeRow()
                    .padding(.bottom, compact ? 0 : 20)
            }

            if !compact {
                accessoryRow
            }
        }
    }

    /// Lyrics toggle, AirPlay and the track list under the volume (portrait only).
    private var accessoryRow: some View {
        HStack {
            Button {
                onHideControls()
            } label: {
                Image(systemName: "quote.bubble.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.75))
                    .frame(width: 34, height: 30)
                    .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel(String(localized: "Скрыть элементы управления"))
            Spacer()
            AirPlayButton()
                .frame(width: 34, height: 30)
            Spacer()
            Button {
                onInteraction()
                onShowQueue()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 34, height: 30)
            }
            .accessibilityLabel(String(localized: "Выбрать трек"))
        }
        .padding(.horizontal, 26)
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Scrubber

/// Thin translucent bar that thickens while dragged, times underneath (Apple Music's scrubber).
private struct Scrubber: View {
    @Environment(PlayerModel.self) private var player
    var onInteraction: () -> Void
    var isVisible: Bool
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !isVisible)) { _ in
            let duration = max(player.track?.duration ?? 0, 0.001)
            let position = player.playbackPosition(at: CACurrentMediaTime())
            let fraction = dragFraction ?? clamp(position / duration, 0, 1)
            let dragging = dragFraction != nil

            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(dragging ? 0.3 : 0.2))
                        Capsule().fill(.white.opacity(dragging ? 0.95 : 0.6))
                            .frame(width: max(0, geometry.size.width * fraction))
                    }
                    .frame(height: dragging ? 12 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                onInteraction()
                                dragFraction = Double(clamp(value.location.x / max(geometry.size.width, 1), 0, 1))
                            }
                            .onEnded { value in
                                let f = Double(clamp(value.location.x / max(geometry.size.width, 1), 0, 1))
                                player.seek(to: f * duration)
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 16)
                .scaleEffect(x: dragging ? 1.03 : 1, y: 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragging)

                HStack {
                    Text(PlaybackBar.format(fraction * duration))
                    Spacer()
                    Text("-" + PlaybackBar.format(duration - fraction * duration))
                }
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(dragging ? 0.85 : 0.5))
            }
        }
        .disabled(player.track == nil)
    }
}

// MARK: - Transport

private struct TransportButton: View {
    let systemName: String
    let size: CGFloat
    var height: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressedCircleStyle())
        .foregroundStyle(.white)
        .hoverEffect(.highlight)
    }
}

/// Shrinks the glyph and shows a soft disc behind it while pressed, like Apple Music.
private struct PressedCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .background(
                Circle()
                    .fill(.white.opacity(configuration.isPressed ? 0.14 : 0))
                    .frame(width: 72, height: 72)
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Volume & AirPlay

private struct VolumeRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
            SystemVolumeSlider()
                .frame(height: 30)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11))
        }
        .foregroundStyle(.white.opacity(0.55))
    }
}

/// The device's system volume (what Apple Music shows). Affects Spotify when it plays on this iPhone.
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = UIColor.white.withAlphaComponent(0.75)
        view.setVolumeThumbImage(Self.thumb, for: .normal)
        view.setVolumeThumbImage(Self.thumb, for: .highlighted)
        view.setMaximumVolumeSliderImage(Self.track(alpha: 0.2), for: .normal)
        view.setMinimumVolumeSliderImage(Self.track(alpha: 0.75), for: .normal)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}

    private static let thumb: UIImage = {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }
    }()

    private static func track(alpha: CGFloat) -> UIImage {
        let size = CGSize(width: 8, height: 6)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.withAlphaComponent(alpha).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3).fill()
        }
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: 3, bottom: 0, right: 3))
    }
}

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.6)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
