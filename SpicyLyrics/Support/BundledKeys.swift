import Foundation

/// The Spicy Lyrics client key built into the app (see `scripts/generate-bundled-keys.sh`),
/// stored XOR-masked so it doesn't show up in plain text in the bundle. That stops casual
/// inspection only: it is a public client key that the app sends over the network anyway.
/// There is deliberately no built-in Spotify Client ID: every user signs in with their own.
enum BundledKeys {
    typealias Masked = (mask: [UInt8], data: [UInt8])

    static var spicyLyricsKey: String? { reveal(maskedSpicyLyricsKey) }

    private static func reveal(_ masked: Masked) -> String? {
        guard !masked.data.isEmpty, masked.data.count == masked.mask.count else { return nil }
        let bytes = zip(masked.data, masked.mask).map { $0 ^ $1 }
        return String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }
}
