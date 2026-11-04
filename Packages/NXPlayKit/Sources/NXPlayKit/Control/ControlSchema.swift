import Foundation

/// A command parameter's type, as a JSON Schema for clients (MCP's inputSchema) and as the check the API runs on the
/// arguments before the command sees them.
indirect enum ControlType: Sendable {
    case string(choices: [String]? = nil, maxLength: Int = 4096)
    case integer(min: Int, max: Int)
    case boolean
    case array(ControlType, maxItems: Int)
    /// An object with any keys, each value of this type (Settings › Games' values by variable).
    case map(ControlType, maxCount: Int)
    /// An object with these keys and no others.
    case object([ControlParam])
    case nullable(ControlType)
    /// Any JSON value: a command's own arguments, which that command checks.
    case anyValue

    var schema: [String: Any] {
        switch self {
        case .anyValue: return [:]
        case .string(let choices, let maxLength):
            var schema: [String: Any] = ["type": "string", "maxLength": maxLength]
            if let choices { schema["enum"] = choices }
            return schema
        case .integer(let min, let max): return ["type": "integer", "minimum": min, "maximum": max]
        case .boolean: return ["type": "boolean"]
        case .array(let item, let maxItems): return ["type": "array", "items": item.schema, "maxItems": maxItems]
        case .map(let value, let maxCount):
            return ["type": "object", "additionalProperties": value.schema, "maxProperties": maxCount]
        case .object(let params): return ControlParam.objectSchema(params)
        case .nullable(let inner):
            var schema = inner.schema
            if let type = schema["type"] as? String { schema["type"] = [type, "null"] }
            if var choices = schema["enum"] as? [Any] {
                choices.append(NSNull())
                schema["enum"] = choices
            }
            return schema
        }
    }

    /// Why `value` doesn't fit, nil when it does. `at` names the place for the message.
    func problem(_ value: Any, at path: String) -> String? {
        switch self {
        case .anyValue: return nil
        case .nullable(let inner):
            return value is NSNull ? nil : inner.problem(value, at: path)
        case .string(let choices, let maxLength):
            guard let text = value as? String else { return "\(path) must be a string" }
            guard text.count <= maxLength else { return "\(path) is longer than \(maxLength) characters" }
            if let choices, !choices.contains(text) {
                return "\(path) must be one of: \(choices.joined(separator: ", "))"
            }
            return nil
        case .integer(let min, let max):
            guard let number = value as? NSNumber, !ControlType.isBool(number),
                CFNumberIsFloatType(number) == false || number.doubleValue.rounded() == number.doubleValue
            else { return "\(path) must be an integer" }
            guard (min...max).contains(number.intValue) else { return "\(path) must be from \(min) to \(max)" }
            return nil
        case .boolean:
            guard let number = value as? NSNumber, ControlType.isBool(number) else {
                return "\(path) must be true or false"
            }
            return nil
        case .array(let item, let maxItems):
            guard let array = value as? [Any] else { return "\(path) must be an array" }
            guard array.count <= maxItems else { return "\(path) has more than \(maxItems) items" }
            for (index, element) in array.enumerated() {
                if let problem = item.problem(element, at: "\(path)[\(index)]") { return problem }
            }
            return nil
        case .map(let valueType, let maxCount):
            guard let object = value as? [String: Any] else { return "\(path) must be an object" }
            guard object.count <= maxCount else { return "\(path) has more than \(maxCount) keys" }
            for key in object.keys.sorted() {
                if let problem = valueType.problem(object[key]!, at: "\(path).\(key)") { return problem }
            }
            return nil
        case .object(let params):
            guard let object = value as? [String: Any] else { return "\(path) must be an object" }
            return ControlParam.problem(object, params, at: path)
        }
    }

    /// JSONSerialization reads `true` and `1` both as NSNumber: only a CFBoolean is a boolean.
    static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

struct ControlParam: Sendable {
    let name: String
    let type: ControlType
    let required: Bool
    let description: String

    init(_ name: String, _ type: ControlType, required: Bool = true, _ description: String) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
    }

    static func objectSchema(_ params: [ControlParam]) -> [String: Any] {
        var properties: [String: Any] = [:]
        for param in params {
            var schema = param.type.schema
            schema["description"] = param.description
            properties[param.name] = schema
        }
        return [
            "type": "object", "properties": properties, "additionalProperties": false,
            "required": params.filter(\.required).map(\.name),
        ]
    }

    /// A missing parameter is one whose key is absent; an unknown key is refused (a typo would otherwise be ignored).
    static func problem(_ object: [String: Any], _ params: [ControlParam], at path: String) -> String? {
        let known = Set(params.map(\.name))
        if let unknown = object.keys.sorted().first(where: { !known.contains($0) }) {
            let prefix = path.isEmpty ? "" : "\(path)."
            return "unknown argument \(prefix)\(unknown) (takes: \(params.map(\.name).joined(separator: ", ")))"
        }
        for param in params {
            let place = path.isEmpty ? param.name : "\(path).\(param.name)"
            guard let value = object[param.name] else {
                if param.required { return "missing argument \(place)" }
                continue
            }
            if let problem = param.type.problem(value, at: place) { return problem }
        }
        return nil
    }
}

/// A command's checked arguments.
struct ControlArgs {
    let values: [String: Any]

    func string(_ name: String) -> String? { values[name] as? String }
    func bool(_ name: String) -> Bool? {
        (values[name] as? NSNumber).flatMap { ControlType.isBool($0) ? $0.boolValue : nil }
    }
    func int(_ name: String) -> Int? {
        (values[name] as? NSNumber).flatMap { ControlType.isBool($0) ? nil : $0.intValue }
    }
    func strings(_ name: String) -> [String]? { values[name] as? [String] }
    func object(_ name: String) -> [String: Any]? { values[name] as? [String: Any] }
    func isNull(_ name: String) -> Bool { values[name] is NSNull }
    func has(_ name: String) -> Bool { values[name] != nil }
}

/// What a job keeps of a call never holds a secret: values under secret-looking keys, and the credentials an address
/// can carry anywhere in a string (its user and password, and secret-looking query parameters), are shown as `***`.
/// Applied before anything is kept, so a call the backend refuses for such an address doesn't keep it either.
///
/// A query parameter's name is judged as a server reads it, percent-decoded: `%74oken` is `token`. It's decoded again
/// and again (`%2574oken` is `token` twice decoded) until nothing changes, malformed escapes are left as they are
/// rather than stopping the decoding. The address keeps its own encoding: only the secret values become `***`. What
/// was hidden from the arguments is hidden from the rest of the job too (`Removed`), wherever it shows up in another
/// form: decoded, or quoted without its address around it.
///
/// Every check here reads encoded text the same way, through `decodedLayers` and one `Budget` per field: the
/// address in it, its parameters, their names and values, a redirect's address inside one, layer after layer. The
/// budget bounds the work, not the depth, so no encoding is deep enough to be left unread while ordinary text, however
/// deeply encoded, is read to the end. A field whose reading runs out of budget is hidden whole (fail closed), and
/// the Sources check refuses such an address (`RepositoryAddress.secretQueryProblem`).
enum ControlRedaction {
    static func isSecret(_ key: String) -> Bool {
        let key = key.lowercased()
        return ["token", "secret", "password", "authorization", "credential", "cookie", "code"].contains {
            key.contains($0)
        }
    }

    /// Query parameters an address can carry a credential in (signed URLs, API keys, OAuth).
    static func isSecretQuery(_ name: String) -> Bool {
        let name = name.lowercased()
        return isSecret(name) || ["key", "sig", "auth", "session", "jwt", "pass", "bearer"].contains { name.contains($0) }
    }

    /// A query parameter's name as written in an address: secret-looking as it is or at any of its decoded layers,
    /// or too costly to read to the end (nothing shows it isn't one).
    static func isSecretQueryName(_ encoded: String) -> Bool {
        (try? isSecretQueryName(encoded, budget: Budget(for: encoded))) ?? true
    }

    static func isSecretQueryName(_ encoded: String, budget: Budget) throws -> Bool {
        try decodedLayers(encoded, budget: budget).contains(where: isSecretQuery)
    }

    // MARK: Reading encoded text

    /// One field's reading ran out of its budget before it could be shown free of a credential.
    struct Exhausted: Error {}

    /// The bytes one field's checks may still read, the nested ones included (an address in it, its parameters, a
    /// redirect's address in a value, every decoded layer of each). It grows with the field, so text of any size is
    /// read many times over (`perByte`), and has a floor for short text encoded over and over. Spending is linear in
    /// what is read, so a field costs at most `floor + perByte × its size`, however it is built. Reading a value
    /// encoded L times costs about L times its size, and each address nested in a value reads what's inside it again,
    /// so the allowance covers, measured: any argument (at most 4096 characters) made of distinct redirects six deep,
    /// and larger text made of them three to four deep throughout; past that a field is hidden, never shown unread.
    /// Addresses nested in
    /// values are read by recursion, so how deep it goes is bounded too (`maxNesting`, far beyond any real redirect
    /// chain); going deeper is running out like any other, not a reason to stop reading and show the rest.
    ///
    /// The same text is read once per field: what its layers are, and what it comes to when nothing is being
    /// remembered (`removed` nil, the checks of whether a value carries a credential), are kept for the field's
    /// reading and handed back for the price of looking at it again. Without that, each address nested in a value
    /// is read by both the address and the word passes, which doubles the work with every level, and an ordinary
    /// chain of redirects could cost more than any per-byte allowance.
    final class Budget {
        static let perByte = 32
        static let floor = 256 * 1024
        static let maxNesting = 64
        private(set) var remaining: Int
        private var nesting = 0
        fileprivate var layers: [String: [String]] = [:]
        fileprivate var scrubbed: [String: String] = [:]
        fileprivate var pairs: [String: String?] = [:]

        init(bytes: Int) { remaining = bytes }
        convenience init(for text: String) { self.init(bytes: Self.floor + Self.perByte * text.utf8.count) }

        func spend(_ bytes: Int) throws {
            remaining -= max(bytes, 1)
            if remaining < 0 { throw Exhausted() }
        }

        /// `body` one level of nesting deeper.
        func nested<T>(_ body: () throws -> T) throws -> T {
            nesting += 1
            defer { nesting -= 1 }
            if nesting > Self.maxNesting { throw Exhausted() }
            return try body()
        }
    }

    /// `text`, then what it reads as percent-decoded once, twice…, until nothing changes. That always comes: a
    /// decoding that changes anything leaves the text shorter or with fewer `%` (valid escapes become one byte,
    /// malformed ones stay, bytes that aren't UTF-8 become U+FFFD, never `%`). Each layer is paid for from `budget`,
    /// which throws when it runs out first: there is no depth after which the rest goes unread.
    static func decodedLayers(_ text: String, budget: Budget) throws -> [String] {
        guard text.contains("%") else { return [text] }
        if let known = budget.layers[text] {
            try budget.spend(text.utf8.count)
            return known
        }
        var layers = [text]
        while let last = layers.last, last.contains("%") {
            try budget.spend(last.utf8.count)
            let next = lenientlyDecoded(last)
            if next == last { break }
            layers.append(next)
        }
        budget.layers[text] = layers
        return layers
    }

    /// `decodedLayers` within a budget for `text` alone: nil when even that runs out.
    static func decodedLayers(_ text: String) -> [String]? {
        try? decodedLayers(text, budget: Budget(for: text))
    }

    /// Whether reading `text` as `scrub` does runs out of budget: what `scrub` would hide whole.
    static func exhausts(_ text: String) -> Bool {
        do {
            _ = try scrub(text, removed: nil, budget: Budget(for: text))
            return false
        } catch {
            return true
        }
    }

    /// Every valid `%XX` decoded; a malformed one (`%zz`, a `%` at the end) kept as it is. Bytes that aren't UTF-8
    /// become U+FFFD.
    static func lenientlyDecoded(_ text: String) -> String {
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        let bytes = Array(text.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
                let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2])
            {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    /// What redaction took out of a call's arguments, each as written and as decoded, so the job can hide it wherever
    /// else it shows up (`hide`). Shorter than `minimum` isn't remembered: hiding it would garble ordinary text.
    final class Removed {
        static let minimum = 4
        private(set) var values: Set<String> = []

        func add(_ value: String?) {
            guard let value else { return }
            for layer in ControlRedaction.decodedLayers(value) ?? [value] where layer.count >= Self.minimum && layer != "***" {
                values.insert(layer)
            }
        }

        /// `text` with every remembered value in it shown as `***`, the longest first.
        func hide(_ text: String) -> String {
            guard !values.isEmpty else { return text }
            return values.sorted { $0.count > $1.count }.reduce(text) {
                $0.replacingOccurrences(of: $1, with: "***")
            }
        }

        /// Every string anywhere in `value` through `hide`; keys stay.
        func hideStrings(_ value: Any) -> Any {
            guard !values.isEmpty else { return value }
            switch value {
            case let object as [String: Any]: return object.mapValues(hideStrings)
            case let array as [Any]: return array.map(hideStrings)
            case let text as String: return hide(text)
            default: return value
            }
        }
    }

    /// Strings anywhere in `value` scrubbed of credentials, keys left as they are: for answers, whose keys are the
    /// API's own (a source's `"token": "none"` says whether one is saved, never what it is).
    static func scrubStrings(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]: return object.mapValues(scrubStrings)
        case let array as [Any]: return array.map(scrubStrings)
        case let text as String: return scrub(text)
        default: return value
        }
    }

    /// `value` without secrets; what was taken out goes into `removed`.
    static func redact(_ value: Any, removed: Removed? = nil) -> Any {
        switch value {
        case let object as [String: Any]:
            return Dictionary(
                uniqueKeysWithValues: object.map { key, value in
                    guard isSecret(key) else { return (key, redact(value, removed: removed)) }
                    if let text = value as? String { removed?.add(text) }
                    return (key, "***")
                })
        case let array as [Any]: return array.map { redact($0, removed: removed) }
        case let text as String: return scrub(text, removed: removed)
        default: return value
        }
    }

    // scheme://… up to whitespace, quotes or angle brackets: an address inside free text (an error message, a name)
    private static let addressPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>“”]+"#)

    // what's left of an address that didn't parse as one: a user and password before "@", and each query-like word
    // (between spaces, quotes, "?", "&", "#" and "/") that is a secret-looking name=value, also encoded (`%3D`)
    private static let userinfoPattern = try! NSRegularExpression(pattern: #"[^\s/@"'<>“”]+@"#)
    private static let wordPattern = try! NSRegularExpression(pattern: #"[^\s"'<>“”?&#/]+"#)

    /// A query name a scrubbed address or word shows in place of one decoded to `name`: encoded so it stays one name.
    private static let nameCharacters = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#%"))

    /// `text` with every address in it scrubbed of credentials (the reading below), within a budget for this field
    /// alone. A field that can't be read to the end within it is hidden whole and remembered in `removed`: nothing
    /// showed it free of a credential, and showing part of it could show the part that holds one.
    static func scrub(_ text: String, removed: Removed? = nil) -> String {
        do {
            return try scrub(text, removed: removed, budget: Budget(for: text))
        } catch {
            removed?.add(text)
            return "***"
        }
    }

    /// Text without "://" is returned as it is (unless it is an address written fully encoded, `https%3A%2F%2F…`,
    /// however many times: judged and shown decoded when that hides something); text with it loses, besides, anything
    /// that looks like a user and password or a secret-looking `name=value`, also where it isn't a well-formed address
    /// (what a refusal quotes back of a mistyped one).
    private static func scrub(_ text: String, removed: Removed?, budget: Budget) throws -> String {
        guard removed == nil else { return try budget.nested { try scrubOneLevel(text, removed: removed, budget: budget) } }
        if let known = budget.scrubbed[text] {
            try budget.spend(text.utf8.count)
            return known
        }
        let cleaned = try budget.nested { try scrubOneLevel(text, removed: nil, budget: budget) }
        budget.scrubbed[text] = cleaned
        return cleaned
    }

    private static func scrubOneLevel(_ text: String, removed: Removed?, budget: Budget) throws -> String {
        try budget.spend(text.utf8.count)
        guard text.contains("://") else {
            guard text.contains("%") else { return text }
            for layer in try decodedLayers(text, budget: budget).dropFirst() where layer.contains("://") {
                let cleaned = try scrub(layer, removed: removed, budget: budget)
                if cleaned != layer { return cleaned }
            }
            return text
        }
        var result = text
        for match in addressPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let address = String(result[range])
            let cleaned = try scrubAddress(address, removed: removed, budget: budget)
            if cleaned != address { result.replaceSubrange(range, with: cleaned) }
        }
        for match in userinfoPattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result), result[range] != "***@" else { continue }
            removed?.add(String(result[range].dropLast()))
            result.replaceSubrange(range, with: "***@")
        }
        for match in wordPattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result),
                let cleaned = try scrubPair(String(result[range]), removed: removed, budget: budget)
            else { continue }
            result.replaceSubrange(range, with: cleaned)
        }
        return result
    }

    /// One query item, `name=value` as written (either part may be encoded, and the "=" too): nil when it holds no
    /// secret, else what shows instead, `name=***`. A secret-looking name's value goes; so does the value of any name
    /// when, decoded, it carries a credential of its own (a redirect's address), and a name that carries a whole
    /// `name=value` itself (`token%3DSECRET`).
    private static func scrubPair(_ word: String, removed: Removed?, budget: Budget) throws -> String? {
        guard removed == nil else { return try budget.nested { try scrubPairOneLevel(word, removed: removed, budget: budget) } }
        if let known = budget.pairs[word] {
            try budget.spend(word.utf8.count)
            return known
        }
        let pair = try budget.nested { try scrubPairOneLevel(word, removed: nil, budget: budget) }
        budget.pairs[word] = pair
        return pair
    }

    private static func scrubPairOneLevel(_ word: String, removed: Removed?, budget: Budget) throws -> String? {
        try budget.spend(word.utf8.count)
        let layers = try decodedLayers(word, budget: budget)
        guard let (depth, layer) = layers.enumerated().first(where: { $0.element.contains("=") }),
            let equals = layer.firstIndex(of: "=")
        else { return nil }
        let name = String(layer[..<equals])
        let value = String(layer[layer.index(after: equals)...])
        if let inner = try scrubPair(name, removed: removed, budget: budget) {
            removed?.add(value)
            removed?.add(word)
            return inner
        }
        guard !value.isEmpty, value != "***" else { return nil }
        guard try isSecretQueryName(name, budget: budget) || carriesSecret(value, budget: budget) else { return nil }
        removed?.add(value)
        removed?.add(word)
        let shown = depth == 0 ? name : (name.addingPercentEncoding(withAllowedCharacters: nameCharacters) ?? "***")
        return (shown.isEmpty ? "***" : shown) + "=***"
    }

    /// A value that, once decoded, holds an address or a query with a credential in it.
    private static func carriesSecret(_ value: String, budget: Budget) throws -> Bool {
        for layer in try decodedLayers(value, budget: budget).dropFirst() {
            if layer.contains("://"), try scrub(layer, removed: nil, budget: budget) != layer { return true }
            for match in wordPattern.matches(in: layer, range: NSRange(layer.startIndex..., in: layer)) {
                if let range = Range(match.range, in: layer),
                    try scrubPair(String(layer[range]), removed: nil, budget: budget) != nil
                {
                    return true
                }
            }
        }
        return false
    }

    /// One address without its user, password or secret-looking query values; when it can't be parsed, everything
    /// after the scheme is hidden (it can't be shown to be free of a credential), as is the whole address when it
    /// can't be read within its budget.
    static func scrubAddress(_ address: String, removed: Removed? = nil) -> String {
        do {
            return try scrubAddress(address, removed: removed, budget: Budget(for: address))
        } catch {
            removed?.add(address)
            return "***"
        }
    }

    private static func scrubAddress(_ address: String, removed: Removed?, budget: Budget) throws -> String {
        try budget.spend(address.utf8.count)
        guard let separator = address.range(of: "://") else { return address }
        let hidden = String(address[..<separator.upperBound]) + "***"
        guard var components = URLComponents(string: address) else {
            removed?.add(String(address[separator.upperBound...]))
            return hidden
        }
        var changed = false
        if components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
            removed?.add(components.percentEncodedUser)
            removed?.add(components.percentEncodedPassword)
            components.percentEncodedUser = "***"
            components.percentEncodedPassword = nil
            changed = true
        }
        if let items = components.percentEncodedQueryItems {
            let cleaned = try items.map { item -> URLQueryItem in
                let written = item.name + (item.value.map { "=" + $0 } ?? "")
                guard let pair = try scrubPair(written, removed: removed, budget: budget) else { return item }
                removed?.add(item.value)
                // the name as written when it is only the value that goes, else (it carried the secret) decoded
                let name = String(pair.dropLast(4))  // "=***"
                return URLQueryItem(name: name, value: "***")
            }
            if cleaned != items {
                components.percentEncodedQueryItems = cleaned
                changed = true
            }
        }
        if let fragment = components.percentEncodedFragment,
            try decodedLayers(fragment, budget: budget).contains(where: { $0.contains("=") })
        {
            // a token in a fragment (OAuth's implicit flow), also with its "=" encoded: the fragment goes
            removed?.add(fragment)
            components.percentEncodedFragment = "***"
            changed = true
        }
        guard changed else { return address }
        return components.string ?? hidden
    }
}
