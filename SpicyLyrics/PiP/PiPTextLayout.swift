import Accelerate
import CoreGraphics
import CoreText
import Foundation

/// A block of text in a Picture in Picture row: one font, wrapped to the row's width.
struct PiPTextBlock {
    /// The text in pieces that animate on their own (syllables, letters, spaces).
    var runs: [String]
    var font: CTFont
    /// How opaque the block is when its mask is filled with white (translations are dimmer).
    var gray: CGFloat = 1
    /// 0 leading, 0.5 centred, 1 trailing.
    var alignment: CGFloat = 0
    /// Space above the block.
    var spacing: CGFloat = 0
    /// Cut to one line with an ellipsis.
    var singleLine = false
}

/// A row of lyrics laid out once with CoreText and rasterized once into 8-bit masks. A frame
/// only fills those masks: setting text was what made the window expensive, and a row that is
/// never re-laid out can never re-wrap while it moves or grows.
final class PiPTextLayout {
    struct Piece {
        /// Index of the run in the first block.
        var run: Int
        /// Glyph box of this part of the run (a run broken over two lines has two pieces).
        var glyphRect: CGRect
        /// Integral crop of the masks, a little larger than the glyphs at the outer edges.
        var rect: CGRect
        /// Width of the run's pieces before this one.
        var advance: CGFloat
    }

    /// Room around the text in the masks for glow and overhanging glyphs.
    static let pad: CGFloat = 14

    let size: CGSize
    /// Pieces of the first block's visible runs, in reading order.
    let pieces: [Piece]
    /// Total width of each run of the first block.
    let runWidths: [CGFloat]
    /// Mask crops (integral) of the first block and of everything after it.
    let firstRect: CGRect
    let restRect: CGRect?

    private struct Placed {
        var line: CTLine
        var origin: CGPoint
        var gray: CGFloat
        /// Part of the first block (the lyric itself) rather than a translation or backing vocal.
        var isFirst: Bool
    }
    private let placed: [Placed]

    init(blocks: [PiPTextBlock], width: CGFloat) {
        var placed: [Placed] = []
        var pieces: [Piece] = []
        var runWidths: [CGFloat] = []
        var first = CGRect.null
        var rest = CGRect.null
        var y: CGFloat = 0
        let pad = Self.pad

        for (b, block) in blocks.enumerated() {
            if b > 0 { y += block.spacing }
            let text = block.runs.joined()
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): block.font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let length = (text as NSString).length
            let ascent = CTFontGetAscent(block.font)
            let lineHeight = ceil(ascent + CTFontGetDescent(block.font) + CTFontGetLeading(block.font))
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)

            // Run boundaries in UTF-16 offsets, as CoreText counts.
            var bounds: [(start: Int, end: Int, blank: Bool)] = []
            var offset = 0
            for run in block.runs {
                let count = (run as NSString).length
                bounds.append((offset, offset + count, run.allSatisfy(\.isWhitespace)))
                offset += count
            }
            if b == 0 { runWidths = Array(repeating: 0, count: block.runs.count) }

            var lines: [(line: CTLine, start: Int, end: Int)] = []
            var start = 0
            while start < length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                if count <= 0 { count = length - start }
                var line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                if block.singleLine, start + count < length {
                    let whole = CTLineCreateWithAttributedString(attributed)
                    let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                    line = CTLineCreateTruncatedLine(whole, Double(width), .end, token) ?? line
                    count = length - start
                }
                lines.append((line, start, start + count))
                start += count
                if block.singleLine { break }
            }

            for (index, entry) in lines.enumerated() {
                let line = entry.line
                let full = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let used = full - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
                let x = max(0, (width - used) * block.alignment)
                placed.append(Placed(line: line, origin: CGPoint(x: x, y: y + ascent), gray: block.gray, isFirst: b == 0))
                let box = CGRect(x: x, y: y, width: used, height: lineHeight)
                if b == 0 { first = first.union(box) } else { rest = rest.union(box) }

                if b == 0 {
                    for (r, run) in bounds.enumerated() where !run.blank {
                        let a = max(run.start, entry.start), z = min(run.end, entry.end)
                        guard a < z else { continue }
                        let x0 = CGFloat(CTLineGetOffsetForStringIndex(line, a, nil))
                        let x1 = z >= entry.end ? full : CGFloat(CTLineGetOffsetForStringIndex(line, z, nil))
                        let glyph = CGRect(x: x + min(x0, x1), y: y, width: abs(x1 - x0), height: lineHeight)
                        guard glyph.width > 0 else { continue }
                        // Outer edges (line ends, next to a space) get room for overhangs; edges
                        // inside a word stay tight so neighbouring syllables don't double up.
                        let before = r > 0 ? bounds[r - 1].blank : true
                        let after = r + 1 < bounds.count ? bounds[r + 1].blank : true
                        let left: CGFloat = a == entry.start ? pad : (before ? 6 : 0.5)
                        let right: CGFloat = z >= entry.end ? pad : (after ? 6 : 0.5)
                        let top: CGFloat = index == 0 ? pad : 0
                        let bottom: CGFloat = index == lines.count - 1 ? pad : 0
                        let rect = CGRect(x: glyph.minX - left, y: glyph.minY - top,
                                          width: glyph.width + left + right, height: glyph.height + top + bottom)
                            .integral
                        pieces.append(Piece(run: r, glyphRect: glyph, rect: rect, advance: runWidths[r]))
                        runWidths[r] += glyph.width
                    }
                }
                y += lineHeight
            }
        }

        self.placed = placed
        self.pieces = pieces
        self.runWidths = runWidths
        size = CGSize(width: width, height: y)
        firstRect = first.isNull ? .zero : first.insetBy(dx: -pad, dy: -pad).integral
        restRect = rest.isNull ? nil : rest.insetBy(dx: -pad, dy: -pad).integral
    }

    // MARK: Masks

    /// Masks of the text, white on black: the crops a frame fills.
    struct Masks {
        var pieces: [CGImage?]
        var first: CGImage?
        var rest: CGImage?
    }
    private var sharpMasks: Masks?
    private var softMasks: Masks?
    private var glowMasks: [CGImage?]?

    /// The text as laid out.
    var sharp: Masks {
        if let sharpMasks { return sharpMasks }
        let masks = masks(blur: 0)
        sharpMasks = masks
        return masks
    }

    /// A soft copy, for distance blur and glow.
    var soft: Masks {
        if let softMasks { return softMasks }
        let masks = masks(blur: 6)
        softMasks = masks
        return masks
    }

    /// One glow per piece: only that piece's glyphs, blurred on their own with room all round.
    /// Cropping the soft copy of the whole line instead cut a syllable's halo off at its tight
    /// edges inside a word and brought the neighbours' blur along: a lit box around the letter.
    var glows: [CGImage?] {
        if let glowMasks { return glowMasks }
        let masks = pieces.map(renderGlow)
        glowMasks = masks
        return masks
    }

    /// Where a piece's glow mask goes.
    func glowRect(_ piece: Piece) -> CGRect {
        piece.glyphRect.insetBy(dx: -Self.pad, dy: -Self.pad).integral
    }

    /// Whether any bitmap is held, so the owner knows what to drop.
    var isRasterized: Bool { sharpMasks != nil || softMasks != nil || glowMasks != nil }

    /// Drops the bitmaps (they come back on demand); the layout stays.
    func purge() {
        sharpMasks = nil
        softMasks = nil
        glowMasks = nil
    }

    /// The first block and the rest are rendered apart: their padded crops overlap, and from
    /// one shared image the lyric's descenders (p, g, y) were filled again with the translation.
    private func masks(blur: Int) -> Masks {
        let first = render(blur: blur, first: true)
        let rest = restRect == nil ? nil : render(blur: blur, first: false)
        return Masks(pieces: pieces.map { crop(first, $0.rect) }, first: crop(first, firstRect),
                     rest: restRect.flatMap { crop(rest, $0) })
    }

    private func crop(_ image: CGImage?, _ rect: CGRect) -> CGImage? {
        image?.cropping(to: rect.offsetBy(dx: Self.pad, dy: Self.pad))
    }

    private func render(blur radius: Int, first: Bool) -> CGImage? {
        let width = Int(ceil(size.width + Self.pad * 2))
        let height = Int(ceil(size.height + Self.pad * 2))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldSmoothFonts(false)
        context.textMatrix = .identity
        for item in placed where item.isFirst == first {
            context.setFillColor(gray: item.gray, alpha: 1)
            context.textPosition = CGPoint(x: Self.pad + item.origin.x, y: CGFloat(height) - Self.pad - item.origin.y)
            CTLineDraw(item.line, context)
        }
        guard radius > 0 else { return context.makeImage() }
        return Self.blurred(context, width: width, height: height, radius: radius)
    }

    private func renderGlow(_ piece: Piece) -> CGImage? {
        let rect = glowRect(piece)
        let width = Int(rect.width), height = Int(rect.height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldSmoothFonts(false)
        context.textMatrix = .identity
        // Layout (top-left origin) → this bitmap (bottom-left origin).
        let glyph = piece.glyphRect.insetBy(dx: -1, dy: 0)
        context.clip(to: CGRect(x: glyph.minX - rect.minX, y: CGFloat(height) - (glyph.maxY - rect.minY),
                                width: glyph.width, height: glyph.height))
        for item in placed where item.isFirst {
            context.setFillColor(gray: item.gray, alpha: 1)
            context.textPosition = CGPoint(x: item.origin.x - rect.minX, y: CGFloat(height) - (item.origin.y - rect.minY))
            CTLineDraw(item.line, context)
        }
        context.resetClip()
        return Self.blurred(context, width: width, height: height, radius: 6)
    }

    private static func blurred(_ context: CGContext, width: Int, height: Int, radius: Int) -> CGImage? {
        guard let data = context.data else { return context.makeImage() }
        var source = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: context.bytesPerRow)
        guard let output = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let outputData = output.data
        else { return nil }
        var destination = vImage_Buffer(data: outputData, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: output.bytesPerRow)
        let kernel = UInt32(radius * 2 + 1)
        // Two tent passes come close to a Gaussian.
        vImageTentConvolve_Planar8(&source, &destination, nil, 0, 0, kernel, kernel, 0, vImage_Flags(kvImageEdgeExtend))
        vImageTentConvolve_Planar8(&destination, &source, nil, 0, 0, kernel, kernel, 0, vImage_Flags(kvImageEdgeExtend))
        return context.makeImage()
    }
}

extension CGContext {
    /// Fills `rect` (top-left origin user space) through `mask`, which is drawn upright.
    func fill(mask: CGImage, in rect: CGRect, _ paint: (CGContext, CGRect) -> Void) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: rect.size)
        clip(to: local, mask: mask)
        paint(self, local)
        restoreGState()
    }

    func fill(mask: CGImage, in rect: CGRect, white alpha: CGFloat) {
        guard alpha > 0.002 else { return }
        fill(mask: mask, in: rect) { context, local in
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: min(1, alpha))
            context.fill(local)
        }
    }
}
