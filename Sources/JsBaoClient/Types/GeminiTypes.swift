import Foundation

// MARK: - Gemini: typed request & response models
//
// These mirror the interfaces published by the JS client
// (`api/geminiApi.d.ts`) so the two surfaces line up field-for-field.
// Fields JS types as `any` / `unknown` (response schemas, raw passthrough
// payloads, candidate bodies) become `JSONValue` (see JSONValue.swift) so
// they round-trip losslessly while still participating in `Codable`.

// MARK: Content parts

/// The author of a Gemini message. Mirrors JS `GeminiRole`
/// (`"user" | "assistant" | "system"`).
///
/// JS types `GeminiRole` as a fixed union but never validates it at runtime:
/// `gemini-controller`'s `normalizeCandidateContent` maps `"model"` →
/// `"assistant"` and otherwise passes the provider's `content.role` through
/// verbatim, casting it to `GeminiRole` without a check. So a response can
/// carry a role string outside the union (e.g. `"function"`, `"tool"`). A
/// strict raw-value enum would throw on those, breaking decode where JS keeps
/// going — so any unrecognized role is preserved as `.other(rawValue)` and
/// round-trips losslessly.
public enum GeminiRole: Codable, Sendable, Equatable {
    case user
    case assistant
    case system
    /// Any role string the provider returns that isn't one of the known
    /// cases. Preserved verbatim so encode round-trips it back unchanged.
    case other(String)

    /// The wire string for this role (the value JS would carry).
    public var rawValue: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        case let .other(value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "user": self = .user
        case "assistant": self = .assistant
        case "system": self = .system
        default: self = .other(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One part of a message's content. A discriminated union on `type`,
/// matching JS `GeminiContentPart` (`text` | `image` | `file`).
public enum GeminiContentPart: Codable, Sendable, Equatable {
    /// `{ type: "text", text }`
    case text(String)
    /// `{ type: "image", mimeType?, base64Data }`
    case image(mimeType: String? = nil, base64Data: String)
    /// `{ type: "file", mimeType?, base64Data, displayName? }`
    case file(mimeType: String? = nil, base64Data: String, displayName: String? = nil)

    private enum CodingKeys: String, CodingKey {
        case type, text, mimeType, base64Data, displayName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType),
                base64Data: try c.decode(String.self, forKey: .base64Data)
            )
        case "file":
            self = .file(
                mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType),
                base64Data: try c.decode(String.self, forKey: .base64Data),
                displayName: try c.decodeIfPresent(String.self, forKey: .displayName)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown Gemini content part type `\(type)`"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case let .image(mimeType, base64Data):
            try c.encode("image", forKey: .type)
            try c.encodeIfPresent(mimeType, forKey: .mimeType)
            try c.encode(base64Data, forKey: .base64Data)
        case let .file(mimeType, base64Data, displayName):
            try c.encode("file", forKey: .type)
            try c.encodeIfPresent(mimeType, forKey: .mimeType)
            try c.encode(base64Data, forKey: .base64Data)
            try c.encodeIfPresent(displayName, forKey: .displayName)
        }
    }
}

/// A single conversation message. Mirrors JS `GeminiMessage`.
public struct GeminiMessage: Codable, Sendable, Equatable {
    public var role: GeminiRole
    public var parts: [GeminiContentPart]

    public init(role: GeminiRole, parts: [GeminiContentPart]) {
        self.role = role
        self.parts = parts
    }
}

// MARK: Generation config

/// A safety filter threshold for one content category. Mirrors JS
/// `GeminiSafetySetting`.
public struct GeminiSafetySetting: Codable, Sendable, Equatable {
    public var category: String
    public var threshold: String

    public init(category: String, threshold: String) {
        self.category = category
        self.threshold = threshold
    }
}

/// Low-level generation parameters. Mirrors JS `GeminiGenerationConfig`.
/// `responseSchema` / `responseJsonSchema` are JS `any` → `JSONValue`.
public struct GeminiGenerationConfig: Codable, Sendable, Equatable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Double?
    public var maxOutputTokens: Int?
    public var stopSequences: [String]?
    public var candidateCount: Int?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    public var responseMimeType: String?
    public var responseSchema: JSONValue?
    public var responseJsonSchema: JSONValue?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Double? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String]? = nil,
        candidateCount: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        responseMimeType: String? = nil,
        responseSchema: JSONValue? = nil,
        responseJsonSchema: JSONValue? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxOutputTokens = maxOutputTokens
        self.stopSequences = stopSequences
        self.candidateCount = candidateCount
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.responseMimeType = responseMimeType
        self.responseSchema = responseSchema
        self.responseJsonSchema = responseJsonSchema
    }
}

/// Constrains the response to a MIME type and/or JSON schema. Mirrors JS
/// `GeminiStructuredOutput`.
public struct GeminiStructuredOutput: Codable, Sendable, Equatable {
    public var responseMimeType: String
    public var responseSchema: JSONValue?
    public var responseJsonSchema: JSONValue?

    public init(
        responseMimeType: String,
        responseSchema: JSONValue? = nil,
        responseJsonSchema: JSONValue? = nil
    ) {
        self.responseMimeType = responseMimeType
        self.responseSchema = responseSchema
        self.responseJsonSchema = responseJsonSchema
    }
}

// MARK: Prompt inputs

/// Options for `generate` / `countTokens`. Mirrors JS `GeminiPromptOptions`
/// (and its `GeminiGenerateOptions` alias). `messages` is required; the rest
/// are optional. `model` falls back to the server default when omitted.
public struct GeminiPromptOptions: Encodable, Sendable {
    public var model: String?
    public var system: [GeminiContentPart]?
    public var messages: [GeminiMessage]
    public var safety: [GeminiSafetySetting]?
    public var generationConfig: GeminiGenerationConfig?
    public var structuredOutput: GeminiStructuredOutput?

    public init(
        model: String? = nil,
        system: [GeminiContentPart]? = nil,
        messages: [GeminiMessage],
        safety: [GeminiSafetySetting]? = nil,
        generationConfig: GeminiGenerationConfig? = nil,
        structuredOutput: GeminiStructuredOutput? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.safety = safety
        self.generationConfig = generationConfig
        self.structuredOutput = structuredOutput
    }
}

/// Alias matching JS `GeminiGenerateOptions = GeminiPromptOptions`.
public typealias GeminiGenerateOptions = GeminiPromptOptions

/// Options for `generateRaw`. Mirrors JS `GeminiGenerateRawOptions`.
/// `model` and `body` are required. `body` is forwarded verbatim, so it is a
/// `JSONValue` object; `query` values are stringified into the URL.
public struct GeminiGenerateRawOptions: Sendable {
    public var model: String
    public var body: JSONValue
    public var query: [String: JSONValue]?

    public init(model: String, body: JSONValue, query: [String: JSONValue]? = nil) {
        self.model = model
        self.body = body
        self.query = query
    }
}

// MARK: Generation results

/// One candidate in a generation response. Mirrors JS `GeminiCandidate`,
/// whose `content` / `safetyRatings` are `any` plus an open index signature —
/// surfaced here as `JSONValue` fields and a `raw` catch-all.
public struct GeminiCandidate: Decodable, Sendable, Equatable {
    public let content: JSONValue?
    public let finishReason: String?
    public let safetyRatings: [JSONValue]?
    /// The full candidate object, preserving any keys not named above
    /// (JS `[key: string]: any`).
    public let raw: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case content, finishReason, safetyRatings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(JSONValue.self, forKey: .content)
        finishReason = try c.decodeIfPresent(String.self, forKey: .finishReason)
        safetyRatings = try c.decodeIfPresent([JSONValue].self, forKey: .safetyRatings)
        raw = try? JSONValue(from: decoder)
    }
}

/// Token usage for a generation. Mirrors the inline `usage` object on JS
/// `GeminiGenerateResult`.
public struct GeminiUsage: Decodable, Sendable, Equatable {
    public let promptTokens: Int?
    public let responseTokens: Int?
    public let totalTokens: Int?
}

/// Result of `generate`. Mirrors JS `GeminiGenerateResult`.
public struct GeminiGenerateResult: Decodable, Sendable, Equatable {
    public let message: GeminiMessage
    public let candidates: [GeminiCandidate]?
    public let usage: GeminiUsage?
    /// The raw provider response (JS `raw?: unknown`).
    public let raw: JSONValue?
}

/// Result of `models`. Mirrors JS `Promise<{ models, defaultModel }>`.
public struct GeminiModelsResult: Decodable, Sendable, Equatable {
    public let models: [String]
    public let defaultModel: String
}

/// A richer model descriptor. Mirrors JS `GeminiModelSummary`. Not returned
/// by `models()` (which yields bare name strings) but kept for parity with
/// the published interface.
public struct GeminiModelSummary: Codable, Sendable, Equatable {
    /// Whether a model accepts text only or also images/files.
    public enum InputType: String, Codable, Sendable, Equatable {
        case text
        case multimodal
    }

    public var name: String
    public var displayName: String?
    public var inputType: InputType
    public var maxOutputTokens: Int?

    public init(
        name: String,
        displayName: String? = nil,
        inputType: InputType,
        maxOutputTokens: Int? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.inputType = inputType
        self.maxOutputTokens = maxOutputTokens
    }
}

/// Result of `countTokens`. Mirrors JS
/// `Promise<{ totalTokens, promptTokens?, candidates?, raw? }>`.
public struct GeminiCountTokensResult: Decodable, Sendable, Equatable {
    public let totalTokens: Int
    public let promptTokens: Int?
    public let candidates: Int?
    public let raw: JSONValue?
}
