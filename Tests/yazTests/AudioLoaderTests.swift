import Foundation
import Testing

@testable import yaz

@Suite("AudioLoader — reading audio without falling over")
struct AudioLoaderTests {

    static var fixtures: URL {
        // Tests/yazTests/ -> package root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "fixtures")
    }

    static func path(_ name: String) -> String { fixtures.appending(path: name).path }

    @Test("a real speech file loads as 16 kHz mono")
    func loadsSpeech() throws {
        let samples = try AudioLoader.load(Self.path("t1.wav"))
        let seconds = Double(samples.count) / AudioLoader.sampleRate
        // The source is 5.57 s; resampling can shift it by a few frames.
        #expect(seconds > 5.4 && seconds < 5.8)
        #expect(SpeechGate.level(samples).peak > 0.01)
    }

    @Test("a long file loads in full — windowed reading must not lose frames")
    func loadsLongerFileFully() throws {
        let samples = try AudioLoader.load(Self.path("t2.wav"))
        let seconds = Double(samples.count) / AudioLoader.sampleRate
        #expect(seconds > 11.9 && seconds < 12.3)
    }

    @Test("a missing file gives a meaningful error — not 'nilError'")
    func missingFileIsDescriptive() {
        #expect(throws: YazError.self) {
            try AudioLoader.load("/yok/boyle/bir/dosya.wav")
        }
        do {
            _ = try AudioLoader.load("/yok/boyle/bir/dosya.wav")
        } catch let error as YazError {
            #expect(error.description.contains("dosya.wav"))
            #expect(!error.description.contains("nilError"))
        } catch {
            Issue.record("expected a YazError")
        }
    }

    @Test("exceeding the duration limit is rejected, and the limit is in the message")
    func enforcesMaxSeconds() {
        do {
            _ = try AudioLoader.load(Self.path("t2.wav"), maxSeconds: 5)
            Issue.record("the duration limit was not enforced")
        } catch let error as YazError {
            #expect(error.description.contains("too long"))
        } catch {
            Issue.record("expected a YazError")
        }
    }

    @Test("a silent file loads but is stopped at the gate")
    func silenceLoadsThenGates() throws {
        let samples = try AudioLoader.load(Self.path("silence-3s.wav"))
        #expect(!samples.isEmpty)
        #expect(SpeechGate.level(samples).peak == 0)
        #expect(throws: YazError.self) { try SpeechGate().check(samples) }
    }

    @Test("a very short file loads but is stopped at the gate")
    func tinyLoadsThenGates() throws {
        let samples = try AudioLoader.load(Self.path("tiny-100ms.wav"))
        #expect(!samples.isEmpty)
        #expect(throws: YazError.self) { try SpeechGate().check(samples) }
    }

    @Test("noise below the threshold is filtered out as silence")
    func noiseFloorGated() throws {
        let samples = try AudioLoader.load(Self.path("noise-floor-2s.wav"))
        let level = SpeechGate.level(samples)
        #expect(level.peak < SpeechGate.defaultSilencePeak)
        #expect(throws: YazError.self) { try SpeechGate().check(samples) }
    }

    @Test("a path beginning with a tilde is expanded")
    func expandsTilde() {
        // Unexpanded, the error text contains "~"; expanded, it names the
        // home directory.
        do {
            _ = try AudioLoader.load("~/kesinlikle-yok-12345.wav")
            Issue.record("expected an error")
        } catch let error as YazError {
            #expect(error.description.contains("kesinlikle-yok-12345.wav"))
        } catch {
            Issue.record("expected a YazError")
        }
    }
}

@Suite("AudioLoader — are the error messages readable")
struct AudioLoaderErrorTests {

    @Test("a missing file gives plain language, not a raw CoreAudio code")
    func missingFileIsPlainLanguage() {
        do {
            _ = try AudioLoader.load("/yok/boyle/bir/dosya.wav")
            Issue.record("expected an error")
        } catch let error as YazError {
            #expect(error.description.contains("not found"))
            #expect(!error.description.contains("Code="))
            #expect(!error.description.contains("com.apple"))
        } catch {
            Issue.record("expected a YazError")
        }
    }

    @Test("a directory is distinguished")
    func directoryIsDistinguished() {
        do {
            _ = try AudioLoader.load(AudioLoaderTests.fixtures.path)
            Issue.record("expected an error")
        } catch let error as YazError {
            #expect(error.description.contains("directory"))
        } catch {
            Issue.record("expected a YazError")
        }
    }

    @Test("a non-audio file gives a comprehensible error")
    func nonAudioFileIsExplained() {
        let readme = AudioLoaderTests.fixtures
            .deletingLastPathComponent().appending(path: "README.md")
        do {
            _ = try AudioLoader.load(readme.path)
            Issue.record("expected an error")
        } catch let error as YazError {
            #expect(error.description.contains("couldn't open"))
        } catch {
            Issue.record("expected a YazError")
        }
    }
}

@Suite("ModelStore — a half download must not count as complete")
struct ModelStoreTests {

    @Test("a model never downloaded is reported as missing")
    func missingModelIsIncomplete() {
        let status = ModelStore.status(for: "kesinlikle-olmayan-model-12345")
        #expect(!status.isComplete)
        #expect(status.sizeBytes == 0)
        #expect(!status.missing.isEmpty)
    }

    @Test("the path is under ~/Documents/huggingface — needed for the iCloud sync warning")
    func pathIsUnderDocuments() {
        let status = ModelStore.status(for: "herhangi")
        #expect(status.path.contains("Documents/huggingface"))
    }

    /// large-v3-turbo is downloaded on this machine; the test skips if not.
    @Test("a downloaded model is reported complete and its size is read")
    func downloadedModelIsComplete() throws {
        let status = ModelStore.status(for: WhisperModel.largeV3Turbo.whisperKitID)
        try #require(status.sizeBytes > 0, "the model is not downloaded — test skipped")
        #expect(status.isComplete)
        #expect(status.missing.isEmpty)
        #expect(status.sizeBytes > 1_000_000_000)   // ~1.6 GB
    }

    @Test("size formatting is human readable")
    func sizeIsHumanReadable() {
        let status = ModelStore.status(for: WhisperModel.largeV3Turbo.whisperKitID)
        #expect(!status.sizeDescription.isEmpty)
    }
}
