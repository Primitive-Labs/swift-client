import Foundation

// MARK: - LLM: typed request & response models
//
// These mirror the interfaces published by the JS client (`api/llmApi.d.ts`)
// so the two surfaces line up field-for-field. Fields the JS surface types as
// `any` (a message's `content`, `tools`, `tool_choice`, `plugins`, and the
// provider `raw`/`annotations` echo) round-trip verbatim as `JSONValue` (see
// JSONValue.swift) — the *shape* is the caller's to define, but the value
// encodes/decodes losslessly instead of leaking `[String: Any]`.

// MARK: Reasoning

/// Controls extended-thinking behavior on a `chat` request. Mirrors JS
/// `ReasoningOptions`.
public struct ReasoningOptions: Encodable, Sendable {
    /// `.low`, `.medium`, or `.high`.
    public enum Effort: String, Encodable, Sendable {
        case low, medium, high
    }

    public var effort: Effort?
    public var maxTokens: Int?
    /// Exclude reasoning tokens from the returned response.
    public var exclude: Bool?
    public var enabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case effort
        case maxTokens = "max_tokens"
        case exclude, enabled
    }

    public init(
        effort: Effort? = nil,
        maxTokens: Int? = nil,
        exclude: Bool? = nil,
        enabled: Bool? = nil
    ) {
        self.effort = effort
        self.maxTokens = maxTokens
        self.exclude = exclude
        self.enabled = enabled
    }
}

// MARK: Messages

/// A single chat message. `content` is `any` on the JS side — a plain string
/// or a structured multi-part array — so it is carried as `JSONValue`.
public struct ChatMessage: Encodable, Sendable {
    public var role: String
    public var content: JSONValue?

    public init(role: String, content: JSONValue? = nil) {
        self.role = role
        self.content = content
    }

    /// Convenience for the common "plain text" message.
    public init(role: String, text: String) {
        self.role = role
        self.content = .string(text)
    }
}

// MARK: Attachments

/// An image, audio clip, or PDF attached to a `chat` request. Mirrors the JS
/// `attachments` union: each case carries exactly the fields that variant
/// accepts, and encodes a `type` discriminator (`"image"`/`"audio"`/`"pdf"`).
public enum ChatAttachment: Encodable, Sendable {
    /// `type: "image"` — supply `base64` or `url`.
    case image(mime: String? = nil, base64: String? = nil, url: String? = nil)
    /// `type: "audio"` — `base64` is required.
    case audio(mime: String? = nil, base64: String)
    /// `type: "pdf"` — supply `base64` or `url`.
    case pdf(filename: String? = nil, base64: String? = nil, url: String? = nil)

    private enum CodingKeys: String, CodingKey {
        case type, mime, base64, url, filename
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .image(mime, base64, url):
            try c.encode("image", forKey: .type)
            try c.encodeIfPresent(mime, forKey: .mime)
            try c.encodeIfPresent(base64, forKey: .base64)
            try c.encodeIfPresent(url, forKey: .url)
        case let .audio(mime, base64):
            try c.encode("audio", forKey: .type)
            try c.encodeIfPresent(mime, forKey: .mime)
            try c.encode(base64, forKey: .base64)
        case let .pdf(filename, base64, url):
            try c.encode("pdf", forKey: .type)
            try c.encodeIfPresent(filename, forKey: .filename)
            try c.encodeIfPresent(base64, forKey: .base64)
            try c.encodeIfPresent(url, forKey: .url)
        }
    }
}

// MARK: Chat input

/// Options for `chat`. Mirrors JS `LlmChatOptions`. `messages` is required;
/// `tools`, `tool_choice`, and `plugins` are `any` on the JS side and are
/// carried verbatim as `JSONValue`.
public struct LlmChatOptions: Encodable, Sendable {
    /// LLM model identifier; falls back to the server default when omitted.
    public var model: String?
    public var messages: [ChatMessage]
    public var attachments: [ChatAttachment]?
    public var temperature: Double?
    public var plugins: [JSONValue]?
    public var tools: JSONValue?
    public var toolChoice: JSONValue?
    public var topP: Double?
    public var maxTokens: Int?
    public var reasoning: ReasoningOptions?

    private enum CodingKeys: String, CodingKey {
        case model, messages, attachments, temperature, plugins, tools
        case toolChoice = "tool_choice"
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case reasoning
    }

    public init(
        model: String? = nil,
        messages: [ChatMessage],
        attachments: [ChatAttachment]? = nil,
        temperature: Double? = nil,
        plugins: [JSONValue]? = nil,
        tools: JSONValue? = nil,
        toolChoice: JSONValue? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        reasoning: ReasoningOptions? = nil
    ) {
        self.model = model
        self.messages = messages
        self.attachments = attachments
        self.temperature = temperature
        self.plugins = plugins
        self.tools = tools
        self.toolChoice = toolChoice
        self.topP = topP
        self.maxTokens = maxTokens
        self.reasoning = reasoning
    }
}

// MARK: Chat output

/// The assistant message returned by `chat`. Mirrors JS
/// `{ role, content, annotations?, raw? }`; `content`, `annotations`, and the
/// provider `raw` echo are `any` on the JS side and decode as `JSONValue`.
public struct LlmChatResponse: Decodable, Sendable {
    public let role: String
    public let content: JSONValue?
    public let annotations: JSONValue?
    public let raw: JSONValue?
}

// MARK: Models output

/// Result of `models`. Mirrors JS `{ models: string[]; defaultModel: string }`.
public struct LlmModelsResponse: Decodable, Sendable {
    public let models: [String]
    public let defaultModel: String
}
