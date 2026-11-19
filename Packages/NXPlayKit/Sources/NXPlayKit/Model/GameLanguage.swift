/// A Switch game language: the DM_LANG codes of nxnative's dm/tools/nacp.py, in the order of the
/// control data's supported-language bits.
public struct GameLanguage: Hashable, Identifiable, Sendable {
    public let code: String
    public let name: String

    public var id: String { code }

    public static let all: [GameLanguage] = [
        ("en-US", "American English"), ("en-GB", "British English"), ("ja", "Japanese"),
        ("fr", "French"),
        ("de", "German"), ("es-419", "Latin American Spanish"), ("es", "Spanish"),
        ("it", "Italian"),
        ("nl", "Dutch"), ("fr-CA", "Canadian French"), ("pt", "Portuguese"), ("ru", "Russian"),
        ("ko", "Korean"), ("zh-Hant", "Traditional Chinese"), ("zh-Hans", "Simplified Chinese"),
        ("pt-BR", "Brazilian Portuguese"), ("pl", "Polish"), ("th", "Thai"),
    ].map { GameLanguage(code: $0.0, name: $0.1) }

    /// The same language for another region (build_ipa_from_nsp.py's LANG_NEAR).
    static let near = [
        "en-US": "en-GB", "en-GB": "en-US", "fr": "fr-CA", "fr-CA": "fr",
        "es": "es-419", "es-419": "es", "pt": "pt-BR", "pt-BR": "pt",
    ]

    /// The language to give a game: the preferred one when the game has it (or lists none),
    /// else the same language for another region; nil keeps the language of the game's build.
    public static func choose(_ preferred: String, for game: Game) -> String? {
        guard !preferred.isEmpty else { return nil }
        if game.languages.isEmpty || game.languages.contains(preferred) { return preferred }
        return near[preferred].flatMap { game.languages.contains($0) ? $0 : nil }
    }
}
