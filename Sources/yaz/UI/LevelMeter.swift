import Foundation

/// The bars behind the recording indicator's waveform.
///
/// Kept as a value type with no AppKit in sight, because the interesting part
/// — how a raw peak becomes a bar height — is arithmetic that should be
/// testable without launching a window server.
///
/// Speech peaks land roughly in 0.05–0.7 on a built-in microphone. Drawn
/// linearly that is a flat, dead-looking line, so levels are shaped before
/// display. This is cosmetic on purpose: the meter exists to tell the user the
/// microphone is live, and it must never be mistaken for the signal check that
/// `SpeechGate` performs on the real samples.
struct LevelMeter: Sendable, Equatable {

    /// How many bars the overlay draws.
    static let barCount = 24

    /// Multiplier applied before clamping. Chosen so ordinary speech fills
    /// most of the height without pinning at the top.
    static let gain: Float = 3.4

    /// Bars sit at this height when idle so the pill never looks broken.
    static let floor: Float = 0.06

    private(set) var bars: [Float]

    init(barCount: Int = LevelMeter.barCount) {
        bars = Array(repeating: LevelMeter.floor, count: max(1, barCount))
    }

    /// Append a new peak, dropping the oldest bar.
    mutating func push(_ level: Float) {
        bars.removeFirst()
        bars.append(Self.shape(level))
    }

    /// Return every bar to the resting height.
    mutating func reset() {
        bars = Array(repeating: Self.floor, count: bars.count)
    }

    /// Map a raw peak (0…1) onto a bar height (floor…1).
    ///
    /// `sqrt` before the gain compresses the top of the range, so a shout does
    /// not flatten the whole meter against the ceiling while a quiet sentence
    /// stays visible.
    ///
    /// A non-finite input rests at the floor rather than pinning to the top.
    /// `NaN` or `infinity` arriving here means the reading is broken, not that
    /// the room is loud, and a meter slammed against the ceiling would be a
    /// more confident lie than a flat one.
    static func shape(_ level: Float) -> Float {
        guard level.isFinite, level > 0 else { return floor }
        let shaped = sqrt(min(level, 1)) * gain
        return min(1, max(floor, shaped))
    }
}

/// What the indicator is showing.
///
/// Separate from the daemon's own bookkeeping so the display can be driven and
/// asserted on without a microphone.
enum IndicatorState: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case refining

    var isVisible: Bool { self != .idle }

    var label: String {
        switch self {
        case .idle: ""
        case .recording: "listening"
        case .transcribing: "transcribing"
        case .refining: "refining"
        }
    }

    /// True while the waveform should animate. In the later states the audio
    /// has already been captured, so a moving meter would be lying.
    var showsWaveform: Bool { self == .recording }
}
