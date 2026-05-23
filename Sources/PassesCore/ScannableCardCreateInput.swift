import Foundation

/// Raw, pre-validation input the consumer passes in when the user submits the create form.
/// Separate type from `ScannableCard` so the validation boundary is explicit: anything of
/// type `ScannableCardCreateInput` has NOT been checked against length caps, charset rules,
/// or bidi/control-character hygiene yet, and anything of type `ScannableCard` has.
///
/// Construction is deliberately permissive — the validator (Child 4) is the choke point.
public struct ScannableCardCreateInput: Sendable, Equatable {
    public let payload: String
    public let format: ScannableFormat
    public let label: String

    public init(payload: String, format: ScannableFormat, label: String) {
        self.payload = payload
        self.format = format
        self.label = label
    }
}
