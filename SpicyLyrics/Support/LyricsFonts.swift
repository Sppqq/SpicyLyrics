import CoreText
import Observation
import SwiftUI
import UIKit

/// What the lyrics are set in: one of the system's designs, or a font family (one of iOS's own,
/// or one the user imported). Stored in the settings as a short string.
struct LyricsFontChoice: Equatable {
    enum Kind: Equatable {
        case system(LyricsFont)
        case family(String)
    }

    var kind: Kind

    static let familyPrefix = "family:"

    init(stored: String) {
        if stored.hasPrefix(Self.familyPrefix) {
            kind = .family(String(stored.dropFirst(Self.familyPrefix.count)))
        } else {
            kind = .system(LyricsFont(rawValue: stored) ?? .standard)
        }
    }

    static func stored(family: String) -> String { familyPrefix + family }

    var title: String {
        switch kind {
        case .system(let font): return font.title
        case .family(let name): return name
        }
    }

    /// The font family, when it is not one of the system designs.
    var family: String? {
        if case .family(let name) = kind { return name }
        return nil
    }

    var uiDesign: UIFontDescriptor.SystemDesign {
        guard case .system(let font) = kind else { return .default }
        switch font {
        case .standard: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }

    private var design: Font.Design {
        guard case .system(let font) = kind else { return .default }
        switch font {
        case .standard: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }

    /// A family that has gone missing (an imported font that was removed) falls back to the
    /// system font by itself.
    func font(size: CGFloat, weight: Font.Weight) -> Font {
        switch kind {
        case .system: return .system(size: size, weight: weight, design: design)
        case .family(let name): return .custom(name, size: size).weight(weight)
        }
    }
}

/// Font families that ship with iOS and look good as lyrics.
enum BuiltInFonts {
    private static let candidates = [
        "Avenir Next", "Avenir", "Helvetica Neue", "Gill Sans", "Optima", "Futura", "Trebuchet MS", "Verdana",
        "Georgia", "Palatino", "Baskerville", "Hoefler Text", "Cochin", "Didot", "Copperplate",
        "American Typewriter", "Courier New", "Menlo",
        "Marker Felt", "Chalkboard SE", "Noteworthy", "Bradley Hand", "Snell Roundhand", "Papyrus",
    ]

    /// Only those this iOS has.
    static var available: [String] {
        let installed = Set(UIFont.familyNames)
        return candidates.filter(installed.contains)
    }
}

/// Fonts the user brought along (TTF, OTF, TTC): copied into the app's Documents/Fonts and
/// registered for this app on every launch.
@MainActor
@Observable
final class CustomFonts {
    struct ImportedFont: Identifiable, Equatable {
        var id: String { file }
        let file: String
        let families: [String]
    }

    enum ImportError: LocalizedError {
        case notAFont

        var errorDescription: String? {
            String(localized: "Это не шрифт или файл повреждён. Подойдут файлы .ttf, .otf и .ttc.")
        }
    }

    static let shared = CustomFonts()
    private(set) var imported: [ImportedFont] = []

    private static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Fonts", isDirectory: true)
    }

    /// At launch: registers every font in the folder.
    func registerAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        imported = files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            let families = Self.families(in: url)
            guard !families.isEmpty else { return nil }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            return ImportedFont(file: url.lastPathComponent, families: families)
        }
    }

    /// Copies the file in and registers it; returns the family names it brings.
    @discardableResult
    func importFont(from url: URL) throws -> [String] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard !Self.families(in: url).isEmpty else { throw ImportError.notAFont }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var target = Self.directory.appendingPathComponent(url.lastPathComponent)
        var copy = 1
        while FileManager.default.fileExists(atPath: target.path) {
            copy += 1
            let name = url.deletingPathExtension().lastPathComponent
            target = Self.directory.appendingPathComponent("\(name) \(copy).\(url.pathExtension)")
        }
        try FileManager.default.copyItem(at: url, to: target)
        CTFontManagerRegisterFontsForURL(target as CFURL, .process, nil)
        registerAll()
        return Self.families(in: target)
    }

    func remove(_ font: ImportedFont) {
        let url = Self.directory.appendingPathComponent(font.file)
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: url)
        imported.removeAll { $0.file == font.file }
    }

    private static func families(in url: URL) -> [String] {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        var names: [String] = []
        for descriptor in descriptors {
            if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
               !names.contains(family) {
                names.append(family)
            }
        }
        return names
    }
}
