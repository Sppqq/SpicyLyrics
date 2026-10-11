import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SpicyLyricsWidgets: WidgetBundle {
    var body: some Widget {
        LyricsLiveActivity()
    }
}

/// The current lyric line on the lock screen and in the Dynamic Island.
struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LockScreenLyrics(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(state.tintColor)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(state.tintColor)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.heading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LyricsBlock(state: state, lineFont: .headline.weight(.bold))
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundStyle(state.tintColor)
            } compactTrailing: {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(state.tintColor)
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundStyle(state.tintColor)
            }
            .keylineTint(state.tintColor)
        }
    }
}

private struct LockScreenLyrics: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 22, height: 22)
                    .background(state.tintColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(state.heading)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !state.isPlaying {
                    Image(systemName: "pause.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            LyricsBlock(state: state, lineFont: .title3.weight(.bold))
        }
        .padding(16)
    }
}

/// The line, its translation, the next line and the song's progress.
private struct LyricsBlock: View {
    let state: LyricsActivityAttributes.ContentState
    let lineFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.line)
                .font(lineFont)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
            if let translation = state.translation, !translation.isEmpty {
                Text(translation)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
            if let next = state.next, !next.isEmpty {
                Text(next)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            progress
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var progress: some View {
        if state.isPlaying, state.songEnd > state.songStart {
            ProgressView(timerInterval: state.songStart...state.songEnd, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(state.tintColor)
        } else {
            ProgressView(value: min(1, max(0, state.progress)))
                .progressViewStyle(.linear)
                .tint(state.tintColor)
        }
    }
}

private extension LyricsActivityAttributes.ContentState {
    var tintColor: Color {
        guard tint.count == 3 else { return .white }
        return Color(red: tint[0], green: tint[1], blue: tint[2])
    }

    var heading: String {
        artist.isEmpty ? title : "\(title) · \(artist)"
    }
}
