import Foundation
import Testing

@testable import yaz

@Suite("LevelMeter — the waveform arithmetic")
struct LevelMeterTests {

    @Test("every bar starts at the floor height")
    func startsAtFloor() {
        let meter = LevelMeter()
        #expect(meter.bars.count == LevelMeter.barCount)
        #expect(meter.bars.allSatisfy { $0 == LevelMeter.floor })
    }

    @Test("push does not change the bar count — it is a ring buffer")
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

    @Test("reset returns everything to the floor")
    func resetClears() {
        var meter = LevelMeter()
        for _ in 0..<5 { meter.push(0.8) }
        meter.reset()
        #expect(meter.bars.allSatisfy { $0 == LevelMeter.floor })
    }

    @Test("bar height always lands between the floor and 1")
    func heightsStayInRange() {
        for raw in stride(from: Float(-1), through: 5, by: 0.13) {
            let height = LevelMeter.shape(raw)
            #expect(height >= LevelMeter.floor && height <= 1, "girdi \(raw) → \(height)")
        }
    }

    @Test("silence rests at the floor")
    func silenceStaysAtFloor() {
        #expect(LevelMeter.shape(0) == LevelMeter.floor)
        #expect(LevelMeter.shape(-0.5) == LevelMeter.floor)
    }

    @Test("a loud level pins to the ceiling without overflowing")
    func loudClampsToCeiling() {
        #expect(LevelMeter.shape(1) == 1)
        #expect(LevelMeter.shape(50) == 1)
    }

    @Test("a louder input gives a taller bar")
    func monotonic() {
        var previous = LevelMeter.shape(0.001)
        for raw in stride(from: Float(0.01), through: 0.08, by: 0.01) {
            let height = LevelMeter.shape(raw)
            #expect(height >= previous, "\(raw) is not monotonic")
            previous = height
        }
    }

    /// Speech peaks land roughly in 0.05–0.7 on a built-in microphone. Drawn
    /// linearly that is a dead flat line; shaping has to make that range
    /// visible.
    @Test("the ordinary speech range produces visible height")
    func speechRangeIsVisible() {
        let quiet = LevelMeter.shape(0.05)
        let normal = LevelMeter.shape(0.2)
        #expect(quiet > LevelMeter.floor * 2, "quiet speech is invisible: \(quiet)")
        #expect(normal > 0.5, "ordinary speech is not tall enough: \(normal)")
    }

    /// A non-finite value means "the reading is broken", not "the room is
    /// loud" — a meter slammed against the ceiling is a more confident lie
    /// than a flat one.
    @Test("non-finite values rest at the floor")
    func handlesNonFinite() {
        #expect(LevelMeter.shape(.nan) == LevelMeter.floor)
        #expect(LevelMeter.shape(.infinity) == LevelMeter.floor)
        #expect(LevelMeter.shape(-.infinity) == LevelMeter.floor)
    }

    @Test("a broken value does not corrupt the ring buffer")
    func nonFiniteDoesNotCorruptBuffer() {
        var meter = LevelMeter()
        meter.push(.nan)
        meter.push(.infinity)
        #expect(meter.bars.count == LevelMeter.barCount)
        #expect(meter.bars.allSatisfy { $0.isFinite })
    }

    @Test("a custom bar count is supported")
    func customBarCount() {
        var meter = LevelMeter(barCount: 8)
        #expect(meter.bars.count == 8)
        meter.push(0.4)
        #expect(meter.bars.count == 8)
    }

    @Test("asking for zero bars still yields one")
    func degenerateBarCount() {
        #expect(LevelMeter(barCount: 0).bars.count == 1)
    }
}

@Suite("IndicatorState — the indicator state machine")
struct IndicatorStateTests {

    @Test("only idle is invisible")
    func visibility() {
        #expect(!IndicatorState.idle.isVisible)
        for state in [IndicatorState.recording, .transcribing, .refining] {
            #expect(state.isVisible)
        }
    }

    /// A waveform still moving after recording ends is lying: the audio has
    /// already been captured by then.
    @Test("the waveform animates only while recording")
    func waveformOnlyWhileRecording() {
        #expect(IndicatorState.recording.showsWaveform)
        #expect(!IndicatorState.transcribing.showsWaveform)
        #expect(!IndicatorState.refining.showsWaveform)
        #expect(!IndicatorState.idle.showsWaveform)
    }

    @Test("visible states have a label; idle does not")
    func labels() {
        #expect(IndicatorState.idle.label.isEmpty)
        for state in [IndicatorState.recording, .transcribing, .refining] {
            #expect(!state.label.isEmpty)
        }
    }

    @Test("labels are distinguishable from one another")
    func labelsAreDistinct() {
        let labels = [IndicatorState.recording, .transcribing, .refining].map(\.label)
        #expect(Set(labels).count == labels.count)
    }
}

@Suite("Config — the indicator switches")
struct IndicatorConfigTests {

    @Test("both are on by default")
    func defaultsOn() {
        #expect(Config().overlay)
        #expect(Config().menuBar)
    }

    @Test("both can be turned off from config")
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

    @Test("the sample config includes the indicator switches")
    func exampleMentionsThem() {
        #expect(Config.example.contains("overlay"))
        #expect(Config.example.contains("menu_bar"))
    }
}
