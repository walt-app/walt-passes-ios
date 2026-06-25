import Foundation

/// Defensive ceiling check `JSONSerialization` does not natively enforce. Iterates source bytes
/// once, tracking nesting depth and the byte length of in-progress JSON string tokens. ASCII
/// scanning is safe over UTF-8: continuation bytes (`0x80..0xBF`) cannot collide with `{`, `}`,
/// `[`, `]`, `"`, or `\`.
///
/// String byte-counting uses source bytes (overcounts by escape-sequence shrinkage), bounding
/// JSON-bomb expansion before allocation - the overcount is conservative and never lets an
/// over-budget string through. Returns `nil` on success, else the first arm that tripped. JSON
/// well-formedness is intentionally not verified here; an unbalanced bracket sails through and
/// surfaces as `invalidJson` from the typed parse.
internal func enforceJsonLimits(_ bytes: [UInt8], config: ParserConfig) -> PassJsonFailure? {
    var state = JsonLimitTokenizer(maxDepth: config.maxJsonDepth, maxStringBytes: config.maxJsonStringBytes)
    var i = 0
    while i < bytes.count, state.failure == nil {
        state.consume(bytes[i])
        i += 1
    }
    return state.failure
}

private struct JsonLimitTokenizer {
    private let maxDepth: Int
    private let maxStringBytes: Int
    private(set) var failure: PassJsonFailure?

    private var depth = 0
    private var inString = false
    private var stringByteCount = 0
    private var escape = false

    init(maxDepth: Int, maxStringBytes: Int) {
        self.maxDepth = maxDepth
        self.maxStringBytes = maxStringBytes
    }

    mutating func consume(_ b: UInt8) {
        if inString { consumeInString(b) } else { consumeOutsideString(b) }
    }

    private mutating func consumeInString(_ b: UInt8) {
        if escape {
            escape = false
            bumpStringByte()
        } else if b == BACKSLASH {
            escape = true
            bumpStringByte()
        } else if b == doubleQuote {
            inString = false
        } else {
            bumpStringByte()
        }
    }

    private mutating func consumeOutsideString(_ b: UInt8) {
        switch b {
        case doubleQuote:
            inString = true
            stringByteCount = 0
        case LBRACE, LBRACKET:
            depth += 1
            if depth > maxDepth { failure = .jsonDepthExceeded }
        // Clamp at zero. Stray leading closers ("}}}{...") would otherwise drive depth negative
        // then climb back, leaving the peak at maxDepth + leadingClosers; keeping the invariant
        // 0 <= depth <= maxDepth is cheap. The typed parse rejects the mismatched JSON anyway.
        case RBRACE, RBRACKET:
            if depth > 0 { depth -= 1 }
        default:
            break
        }
    }

    private mutating func bumpStringByte() {
        stringByteCount += 1
        if stringByteCount > maxStringBytes { failure = .jsonStringTooLong }
    }
}

private let doubleQuote: UInt8 = 0x22
private let BACKSLASH: UInt8 = 0x5C
private let LBRACE: UInt8 = 0x7B
private let RBRACE: UInt8 = 0x7D
private let LBRACKET: UInt8 = 0x5B
private let RBRACKET: UInt8 = 0x5D
