import Foundation

/// A stretch of AirPods motion saved to disk, with what the user was doing.
///
/// Both approaches being compared (matching against examples, and a trained
/// classifier) learn from these same files, so the comparison is fair. The
/// format is plain JSON so the comparison notebook can read it without Swift.
public struct Recording: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// One prompted go at a gesture, with about a second of stillness
        /// before it. Lots of these teach what the gesture looks like.
        case take
        /// Minutes of ordinary use: typing, reading, talking, looking around.
        /// Teaches what to ignore. Without it, a classifier has only ever seen
        /// gestures and will call any movement one of them.
        case background
    }

    public var id: UUID
    public var label: String
    public var kind: Kind
    public var recordedAt: Date
    /// For takes: seconds into `samples` at which the user was told "now".
    /// Kept so the notebook can check how quickly people react, and so a
    /// take that started early can be spotted.
    public var promptOffset: TimeInterval?
    public var samples: [MotionSample]

    public init(id: UUID = UUID(), label: String, kind: Kind, recordedAt: Date = Date(),
                promptOffset: TimeInterval? = nil, samples: [MotionSample]) {
        self.id = id
        self.label = label
        self.kind = kind
        self.recordedAt = recordedAt
        self.promptOffset = promptOffset
        self.samples = samples
    }

    public var duration: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.timestamp - first.timestamp
    }

    /// The label every background recording carries, and the "nothing
    /// happening" class a classifier learns.
    public static let backgroundLabel = "background"
}
