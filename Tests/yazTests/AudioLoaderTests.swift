import Foundation
import Testing

@testable import yaz

@Suite("AudioLoader — dayanıklı ses okuma")
struct AudioLoaderTests {

    static var fixtures: URL {
        // Tests/yazTests/ -> paket kökü
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "fixtures")
    }

    static func path(_ name: String) -> String { fixtures.appending(path: name).path }

    @Test("gerçek konuşma dosyası 16 kHz mono olarak yüklenir")
    func loadsSpeech() throws {
        let samples = try AudioLoader.load(Self.path("t1.wav"))
        let seconds = Double(samples.count) / AudioLoader.sampleRate
        // Kaynak 5.57 sn; yeniden örnekleme birkaç kare oynatabilir.
        #expect(seconds > 5.4 && seconds < 5.8)
        #expect(SpeechGate.level(samples).peak > 0.01)
    }

    @Test("uzun dosya da tam yüklenir — pencereli okuma kare kaybetmemeli")
    func loadsLongerFileFully() throws {
        let samples = try AudioLoader.load(Self.path("t2.wav"))
        let seconds = Double(samples.count) / AudioLoader.sampleRate
        #expect(seconds > 11.9 && seconds < 12.3)
    }

    @Test("olmayan dosya anlamlı hata verir — 'nilError' değil")
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
            Issue.record("YazError bekleniyordu")
        }
    }

    @Test("süre sınırı aşılırsa reddedilir ve sınır mesajda geçer")
    func enforcesMaxSeconds() {
        do {
            _ = try AudioLoader.load(Self.path("t2.wav"), maxSeconds: 5)
            Issue.record("süre sınırı uygulanmadı")
        } catch let error as YazError {
            #expect(error.description.contains("çok uzun"))
        } catch {
            Issue.record("YazError bekleniyordu")
        }
    }

    @Test("sessiz dosya yüklenir ama kapıda takılır")
    func silenceLoadsThenGates() throws {
        let samples = try AudioLoader.load(Self.path("silence-3s.wav"))
        #expect(!samples.isEmpty)
        #expect(SpeechGate.level(samples).peak == 0)
        #expect(throws: YazError.self) { try SpeechGate().check(samples) }
    }

    @Test("çok kısa dosya yüklenir ama kapıda takılır")
    func tinyLoadsThenGates() throws {
        let samples = try AudioLoader.load(Self.path("tiny-100ms.wav"))
        #expect(!samples.isEmpty)
        #expect(throws: YazError.self) { try SpeechGate().check(samples) }
    }

    @Test("eşik altı gürültü sessizlik olarak elenir")
    func noiseFloorGated() throws {
        let samples = try AudioLoader.load(Self.path("noise-floor-2s.wav"))
        let level = SpeechGate.level(samples)
        #expect(level.peak < SpeechGate.defaultSilencePeak)
        #expect(throws: YazError.self) { try SpeechGate().check(samples) }
    }

    @Test("tilde ile başlayan yol genişletilir")
    func expandsTilde() {
        // Yol genişlemezse hata metni "~" içerir; genişlerse ev dizinini gösterir.
        do {
            _ = try AudioLoader.load("~/kesinlikle-yok-12345.wav")
            Issue.record("hata bekleniyordu")
        } catch let error as YazError {
            #expect(error.description.contains("kesinlikle-yok-12345.wav"))
        } catch {
            Issue.record("YazError bekleniyordu")
        }
    }
}

@Suite("AudioLoader — hata mesajlarının okunabilirliği")
struct AudioLoaderErrorTests {

    @Test("olmayan dosya ham CoreAudio kodu değil, düz Türkçe döner")
    func missingFileIsPlainLanguage() {
        do {
            _ = try AudioLoader.load("/yok/boyle/bir/dosya.wav")
            Issue.record("hata bekleniyordu")
        } catch let error as YazError {
            #expect(error.description.contains("bulunamadı"))
            #expect(!error.description.contains("Code="))
            #expect(!error.description.contains("com.apple"))
        } catch {
            Issue.record("YazError bekleniyordu")
        }
    }

    @Test("klasör verilirse ayırt edilir")
    func directoryIsDistinguished() {
        do {
            _ = try AudioLoader.load(AudioLoaderTests.fixtures.path)
            Issue.record("hata bekleniyordu")
        } catch let error as YazError {
            #expect(error.description.contains("klasör"))
        } catch {
            Issue.record("YazError bekleniyordu")
        }
    }

    @Test("ses olmayan dosya anlaşılır hata verir")
    func nonAudioFileIsExplained() {
        let readme = AudioLoaderTests.fixtures
            .deletingLastPathComponent().appending(path: "README.md")
        do {
            _ = try AudioLoader.load(readme.path)
            Issue.record("hata bekleniyordu")
        } catch let error as YazError {
            #expect(error.description.contains("açılamadı"))
        } catch {
            Issue.record("YazError bekleniyordu")
        }
    }
}

@Suite("ModelStore — yarım indirme tam sayılmamalı")
struct ModelStoreTests {

    @Test("hiç indirilmemiş model eksik raporlanır")
    func missingModelIsIncomplete() {
        let status = ModelStore.status(for: "kesinlikle-olmayan-model-12345")
        #expect(!status.isComplete)
        #expect(status.sizeBytes == 0)
        #expect(!status.missing.isEmpty)
    }

    @Test("yol ~/Documents/huggingface altında — iCloud senkronu uyarısı için gerekli")
    func pathIsUnderDocuments() {
        let status = ModelStore.status(for: "herhangi")
        #expect(status.path.contains("Documents/huggingface"))
    }

    /// Bu makinede large-v3-turbo indirili; indirili değilse test atlanır.
    @Test("indirili model tam raporlanır ve boyutu okunur")
    func downloadedModelIsComplete() throws {
        let status = ModelStore.status(for: WhisperModel.largeV3Turbo.whisperKitID)
        try #require(status.sizeBytes > 0, "model indirili değil — test atlandı")
        #expect(status.isComplete)
        #expect(status.missing.isEmpty)
        #expect(status.sizeBytes > 1_000_000_000)   // ~1.6 GB
    }

    @Test("boyut biçimlendirmesi insan okunabilir")
    func sizeIsHumanReadable() {
        let status = ModelStore.status(for: WhisperModel.largeV3Turbo.whisperKitID)
        #expect(!status.sizeDescription.isEmpty)
    }
}
