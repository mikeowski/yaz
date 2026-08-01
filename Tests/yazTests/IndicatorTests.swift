import Foundation
import Testing

@testable import yaz

@Suite("LevelMeter — dalga formu aritmetiği")
struct LevelMeterTests {

    @Test("başlangıçta tüm çubuklar taban yüksekliğinde")
    func startsAtFloor() {
        let meter = LevelMeter()
        #expect(meter.bars.count == LevelMeter.barCount)
        #expect(meter.bars.allSatisfy { $0 == LevelMeter.floor })
    }

    @Test("push çubuk sayısını değiştirmez — halka tampon")
    func pushKeepsCount() {
        var meter = LevelMeter()
        for _ in 0..<100 { meter.push(0.3) }
        #expect(meter.bars.count == LevelMeter.barCount)
    }

    @Test("en yeni seviye sonda")
    func newestIsLast() {
        var meter = LevelMeter()
        meter.push(0.5)
        #expect(meter.bars.last == LevelMeter.shape(0.5))
        #expect(meter.bars.first == LevelMeter.floor)
    }

    @Test("reset her şeyi tabana döndürür")
    func resetClears() {
        var meter = LevelMeter()
        for _ in 0..<5 { meter.push(0.8) }
        meter.reset()
        #expect(meter.bars.allSatisfy { $0 == LevelMeter.floor })
    }

    @Test("çubuk yüksekliği her zaman taban ile 1 arasında")
    func heightsStayInRange() {
        for raw in stride(from: Float(-1), through: 5, by: 0.13) {
            let height = LevelMeter.shape(raw)
            #expect(height >= LevelMeter.floor && height <= 1, "girdi \(raw) → \(height)")
        }
    }

    @Test("sessizlik tabanda kalır")
    func silenceStaysAtFloor() {
        #expect(LevelMeter.shape(0) == LevelMeter.floor)
        #expect(LevelMeter.shape(-0.5) == LevelMeter.floor)
    }

    @Test("yüksek seviye tavana yapışır ama taşmaz")
    func loudClampsToCeiling() {
        #expect(LevelMeter.shape(1) == 1)
        #expect(LevelMeter.shape(50) == 1)
    }

    @Test("daha yüksek girdi daha yüksek çubuk verir")
    func monotonic() {
        var previous = LevelMeter.shape(0.001)
        for raw in stride(from: Float(0.01), through: 0.08, by: 0.01) {
            let height = LevelMeter.shape(raw)
            #expect(height >= previous, "\(raw) monotonik değil")
            previous = height
        }
    }

    /// Konuşma tepe değerleri dahili mikrofonda kabaca 0.05–0.7 arasında.
    /// Doğrusal çizilse ölü bir çizgi olurdu; şekillendirme bu aralığı
    /// görünür kılmalı.
    @Test("normal konuşma aralığı görünür yükseklik üretir")
    func speechRangeIsVisible() {
        let quiet = LevelMeter.shape(0.05)
        let normal = LevelMeter.shape(0.2)
        #expect(quiet > LevelMeter.floor * 2, "sessiz konuşma görünmüyor: \(quiet)")
        #expect(normal > 0.5, "normal konuşma yeterince yüksek değil: \(normal)")
    }

    /// Sonlu olmayan değer "çok yüksek" değil "okuma bozuk" demek; tavana
    /// yapışmış bir metre, düz olandan daha kendinden emin bir yalan olur.
    @Test("sonlu olmayan değerler tabanda kalır")
    func handlesNonFinite() {
        #expect(LevelMeter.shape(.nan) == LevelMeter.floor)
        #expect(LevelMeter.shape(.infinity) == LevelMeter.floor)
        #expect(LevelMeter.shape(-.infinity) == LevelMeter.floor)
    }

    @Test("bozuk değer halka tamponu bozmaz")
    func nonFiniteDoesNotCorruptBuffer() {
        var meter = LevelMeter()
        meter.push(.nan)
        meter.push(.infinity)
        #expect(meter.bars.count == LevelMeter.barCount)
        #expect(meter.bars.allSatisfy { $0.isFinite })
    }

    @Test("özel çubuk sayısı desteklenir")
    func customBarCount() {
        var meter = LevelMeter(barCount: 8)
        #expect(meter.bars.count == 8)
        meter.push(0.4)
        #expect(meter.bars.count == 8)
    }

    @Test("sıfır çubuk istenirse yine de bir çubuk olur")
    func degenerateBarCount() {
        #expect(LevelMeter(barCount: 0).bars.count == 1)
    }
}

@Suite("IndicatorState — gösterge durum makinesi")
struct IndicatorStateTests {

    @Test("yalnızca idle görünmez")
    func visibility() {
        #expect(!IndicatorState.idle.isVisible)
        for state in [IndicatorState.recording, .transcribing, .refining] {
            #expect(state.isVisible)
        }
    }

    /// Kayıt bittikten sonra dalga formu oynamaya devam ederse yalan söyler:
    /// o noktada ses çoktan yakalanmış olur.
    @Test("dalga formu yalnızca kayıt sırasında oynar")
    func waveformOnlyWhileRecording() {
        #expect(IndicatorState.recording.showsWaveform)
        #expect(!IndicatorState.transcribing.showsWaveform)
        #expect(!IndicatorState.refining.showsWaveform)
        #expect(!IndicatorState.idle.showsWaveform)
    }

    @Test("görünür durumların etiketi var, idle'ın yok")
    func labels() {
        #expect(IndicatorState.idle.label.isEmpty)
        for state in [IndicatorState.recording, .transcribing, .refining] {
            #expect(!state.label.isEmpty)
        }
    }

    @Test("etiketler birbirinden ayırt edilebilir")
    func labelsAreDistinct() {
        let labels = [IndicatorState.recording, .transcribing, .refining].map(\.label)
        #expect(Set(labels).count == labels.count)
    }
}

@Suite("Config — gösterge anahtarları")
struct IndicatorConfigTests {

    @Test("varsayılan olarak ikisi de açık")
    func defaultsOn() {
        #expect(Config().overlay)
        #expect(Config().menuBar)
    }

    @Test("config'den kapatılabilir")
    func canBeDisabled() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "yaz-ui-\(UUID().uuidString).json")
        try #"{ "overlay": false, "menu_bar": false }"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Config.load(from: url)
        #expect(!config.overlay)
        #expect(!config.menuBar)
    }

    @Test("örnek config gösterge anahtarlarını içeriyor")
    func exampleMentionsThem() {
        #expect(Config.example.contains("overlay"))
        #expect(Config.example.contains("menu_bar"))
    }
}
