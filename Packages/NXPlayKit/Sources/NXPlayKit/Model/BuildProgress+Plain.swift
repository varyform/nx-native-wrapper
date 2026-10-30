import Foundation

/// The build's stages in a player's words, for Console Mode: the script's names are for developers ("Mac shaders",
/// "rewrite", "survey: code modules"). Matched by prefix; a stage this doesn't know shows its own name.
extension BuildProgress {
    static let plainNames: [(prefix: String, name: String)] = [
        ("decompress NSZ", "Unpacking the game files"),
        ("extract DLC", "Unpacking the DLC"),
        ("extract", "Unpacking the game"),
        ("survey", "Getting to know the game"),
        ("build nx_extract", "Getting to know the game"),
        ("build ID lookup", "Getting to know the game"),
        ("address regions", "Getting to know the game"),
        ("heap check", "Getting to know the game"),
        ("rewrite", "Translating the game's code"),
        ("shader split", "Finding the graphics"),
        ("UE shader decode", "Finding the graphics"),
        ("GLSLC capture", "Finding the graphics"),
        ("Mac shaders", "Preparing the graphics"),
        ("Vulkan shaders", "Preparing the graphics"),
        ("GL shaders", "Preparing the graphics"),
        ("Pipeline", "Warming up the graphics"),
        ("Mac host", "Building the engine"),
        ("Mac app", "Packing it up"),
        ("app build", "Packing it up"),
        ("IPA pack", "Packing it up"),
        ("prepare Xcode", "Packing it up"),
    ]

    /// "Preparing the graphics" for "Mac shaders"; a shader capture ("<engine> shader capture") finds the graphics too.
    static func plainName(_ stage: String) -> String {
        if stage.hasSuffix("shader capture") { return "Finding the graphics" }
        return plainNames.first { stage.hasPrefix($0.prefix) }?.name ?? stage
    }

    /// "Step 8 of 9 · Preparing the graphics · 12,339/18,503 shaders · 15:33 left"
    public var plainSummary: String {
        var parts = ["Step \(stage) of \(stages)", Self.plainName(name)]
        if !finished {
            if let count { parts.append(count) }
            if let eta { parts.append("\(Self.duration(eta)) left") }
        }
        return parts.joined(separator: " · ")
    }
}
