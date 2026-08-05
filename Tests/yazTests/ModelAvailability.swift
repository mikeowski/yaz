import Foundation

@testable import yaz

/// Whether the 1.6 GB `large-v3-turbo` weights are on this machine.
///
/// A handful of tests can only assert anything real once the model is present.
/// They must not fail without it: the weights are a deliberate download, not a
/// checkout artefact, so a fresh clone and a CI runner both start without them.
///
/// The first attempt at this used `try #require(status.isComplete, "test
/// skipped")`, which reads like a skip and is not one — `#require` records an
/// issue and fails. The tests passed on the machine that happened to have the
/// model and turned CI red on every push. `.enabled(if:)` is the trait that
/// actually skips, and it is evaluated when the test runs rather than when the
/// suite is built.
enum ModelAvailability {
    static var largeV3TurboIsDownloaded: Bool {
        ModelStore.status(for: WhisperModel.largeV3Turbo.whisperKitID).isComplete
    }
}
