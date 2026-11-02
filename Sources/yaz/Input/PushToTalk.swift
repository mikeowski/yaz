import Foundation

/// Turns the hotkey's raw press and release edges into recording commands.
///
/// Two ways to dictate:
///
/// - **Hold.** Press, speak, release. The release stops the recording.
/// - **Hands-free.** Tap twice quickly: the recording keeps going without the
///   key held, for a long message or a dictation while typing notes. The next
///   press stops it.
///
/// A single short tap followed by nothing is an accidental brush of the key.
/// It is discarded quietly once the second-tap window has passed, rather than
/// sent to Whisper (which would return nothing for it anyway).
///
/// Pure logic with explicit timestamps, so it is tested without a keyboard.
struct PushToTalk: Sendable, Equatable {

    enum Command: Sendable, Equatable {
        /// Begin capturing.
        case start
        /// Stop capturing and transcribe.
        case stop
        /// Stop capturing and drop the audio: it was an accidental tap.
        case discard
        /// The recording is now hands-free; keep capturing.
        case lock
        /// Nothing to do.
        case none
    }

    enum State: Sendable, Equatable {
        case idle
        /// Key down, recording.
        case held(since: TimeInterval)
        /// A short tap: still recording, waiting for a second tap until `until`.
        case armed(until: TimeInterval)
        /// The second tap is still down; its release must not stop anything.
        case locking
        /// Hands-free: recording with the key up.
        case locked
        /// The press that stopped a hands-free recording is still down.
        case stopping
    }

    /// A press shorter than this is a tap, not a hold.
    static let tapMax: TimeInterval = 0.3
    /// How long after a tap the second tap may come.
    static let secondTapWindow: TimeInterval = 0.4

    /// With hands-free off, every press is a plain hold.
    var handsFree: Bool = true
    private(set) var state: State = .idle

    init(handsFree: Bool = true) {
        self.handsFree = handsFree
    }

    var isRecording: Bool { state != .idle }

    mutating func press(at time: TimeInterval) -> Command {
        switch state {
        case .idle:
            state = .held(since: time)
            return .start
        case .armed(let until) where time <= until:
            state = .locking
            return .lock
        case .armed:
            // The window passed without a tick to close it: treat this press
            // as the start of a hold on the same recording.
            state = .held(since: time)
            return .none
        case .locked:
            state = .stopping
            return .stop
        case .held, .locking, .stopping:
            return .none
        }
    }

    mutating func release(at time: TimeInterval) -> Command {
        switch state {
        case .held(let since):
            if handsFree && time - since < Self.tapMax {
                state = .armed(until: time + Self.secondTapWindow)
                return .none
            }
            state = .idle
            return .stop
        case .locking:
            state = .locked
            return .none
        case .stopping:
            state = .idle
            return .none
        case .idle, .armed, .locked:
            return .none
        }
    }

    /// Call after `secondTapWindow`: closes a tap that never got its second.
    mutating func tick(at time: TimeInterval) -> Command {
        if case .armed(let until) = state, time > until {
            state = .idle
            return .discard
        }
        return .none
    }

    /// Back to idle after the recording was ended some other way (an error,
    /// the length limit, quitting).
    mutating func reset() {
        state = .idle
    }
}
