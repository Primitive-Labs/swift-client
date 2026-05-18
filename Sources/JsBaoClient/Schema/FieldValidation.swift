import Foundation

/// Errors from declarative field-level validation.
///
/// Mirrors js-bao browser's `validateBeforeSave` (browser.js:3010-3032):
/// required-field presence + stringset bounds (`maxCount`, `maxLength`).
public enum FieldValidationError: Error, Equatable, Sendable {
    /// A field declared `required: true` was not supplied and no
    /// default resolved to a value. Matches js-bao's `null || undefined`
    /// guard — empty strings are considered present and pass.
    case requiredFieldMissing(field: String, modelName: String)

    /// A stringset write would exceed the field's declared `maxCount`.
    /// Mirrors js-bao's per-stringset count check (browser.js:3017).
    case stringsetMaxCountExceeded(
        field: String, modelName: String, limit: Int, got: Int
    )

    /// A single member in a stringset exceeds the field's declared
    /// `maxLength`. Mirrors js-bao's per-member length check
    /// (browser.js:3023). `member` names the offending string so the
    /// caller can diagnose without scanning the whole set.
    case stringsetMemberTooLong(
        field: String, modelName: String, limit: Int, member: String
    )
}
