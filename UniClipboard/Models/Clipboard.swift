import Foundation
import CryptoKit

/// On-the-wire clipboard snapshot. Spec: docs/SYNC_PROTOCOL.md §3.
public struct Clipboard: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text  = "Text"
        case image = "Image"
        case file  = "File"
        case group = "Group"
    }

    public var type: Kind
    public var hash: String?
    public var text: String
    public var hasData: Bool
    public var dataName: String?
    public var size: Int?

    public init(
        type: Kind,
        hash: String? = nil,
        text: String,
        hasData: Bool,
        dataName: String? = nil,
        size: Int? = nil
    ) {
        self.type = type
        self.hash = Self.normalizeHash(hash)
        self.text = text
        self.hasData = hasData
        self.dataName = dataName
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case type, hash, text, hasData, dataName, size
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type    = try c.decode(Kind.self, forKey: .type)
        text    = try c.decode(String.self, forKey: .text)
        hasData = try c.decode(Bool.self, forKey: .hasData)
        hash    = Self.normalizeHash(try c.decodeIfPresent(String.self, forKey: .hash))
        dataName = try c.decodeIfPresent(String.self, forKey: .dataName)
        size     = try c.decodeIfPresent(Int.self, forKey: .size)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(hash, forKey: .hash)
        try c.encode(text, forKey: .text)
        try c.encode(hasData, forKey: .hasData)
        try c.encodeIfPresent(dataName, forKey: .dataName)
        try c.encodeIfPresent(size, forKey: .size)
    }

    /// §3.1 — empty / whitespace-only hash is normalized to nil so the encoder omits the key.
    private static func normalizeHash(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }
}

public extension Clipboard {
    /// §4.4 — null/empty `expected` matches anything.
    static func hashMatches(expected: String?, actual: String) -> Bool {
        guard let e = expected?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty else {
            return true
        }
        return e.uppercased() == actual.uppercased()
    }
}

public extension Clipboard {
    /// §4.1 — SHA-256 of UTF-8 bytes, uppercase hex.
    static func computeTextHash(_ text: String) -> String {
        sha256Upper(Data(text.utf8))
    }

    /// §4.2 — SHA-256 of raw bytes, uppercase hex. Used to verify image,
    /// file, and text-overflow payloads on download. Group ZIP hashing
    /// (§4.3) is a different algorithm and not covered here.
    static func computeBytesHash(_ data: Data) -> String {
        sha256Upper(data)
    }

    private static func sha256Upper(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    /// Build a `Clipboard` from a plain device-pasteboard string. Always
    /// computes the §4.1 hash; `hasData` is false and `size` is the
    /// grapheme count. The §3.4 long-text overflow transform is the
    /// publish path's job, not the observe path's.
    static func fromText(_ text: String) -> Clipboard {
        Clipboard(
            type: .text,
            hash: computeTextHash(text),
            text: text,
            hasData: false,
            size: text.count
        )
    }

    /// §3.4 — produce the publishable Clipboard + optional payload bytes
    /// for a piece of plain text. Long text (> 10240 chars) triggers the
    /// file-overflow branch: `hasData=true`, `dataName="text_<HASH>.txt"`,
    /// `text` is only the first 10240 chars, and the payload is the full
    /// UTF-8 bytes. Short text fits inline: `hasData=false`, full text,
    /// no payload.
    ///
    /// `text.count` (grapheme clusters) is used for the threshold.
    /// Other clients (Flutter / C#) may use UTF-16 code units; the two
    /// agree for ASCII and BMP content. Documented interop ambiguity.
    static func publishText(_ text: String) -> (clipboard: Clipboard, payload: Data?) {
        let threshold = 10_240
        let hash = computeTextHash(text)
        if text.count > threshold {
            let preview = String(text.prefix(threshold))
            let dataName = "text_\(hash).txt"
            let payload = Data(text.utf8)
            let entry = Clipboard(
                type: .text,
                hash: hash,
                text: preview,
                hasData: true,
                dataName: dataName,
                size: text.count
            )
            return (entry, payload)
        }
        let entry = Clipboard(
            type: .text,
            hash: hash,
            text: text,
            hasData: false,
            size: text.count
        )
        return (entry, nil)
    }
}
