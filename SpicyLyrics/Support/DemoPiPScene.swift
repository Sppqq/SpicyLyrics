#if DEBUG
import SwiftUI

/// The README's PiP recording (`-demoPiP YES` in the Simulator, which has no Picture in
/// Picture): the floating window's real frames, shown as a window over a stand-in home screen.
struct DemoPiPScene: View {
    let pip: LyricsPictureInPicture

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 32
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.3), Color(red: 0.05, green: 0.2, blue: 0.32)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                // Placeholder app icons, so it reads as "over other apps".
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22), count: 4), spacing: 26) {
                    ForEach(0..<20, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.1 + Double(index % 5) * 0.025))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 120 + width / 2)

                PictureInPictureHost(pip: pip)
                    .frame(width: width, height: width / 2)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    .padding(.top, 70)
            }
        }
        .allowsHitTesting(false)
    }
}
#endif
