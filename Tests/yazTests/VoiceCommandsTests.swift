import Foundation
import Testing
@testable import yaz

@Suite("VoiceCommands — said at the end of a sentence, or not at all")
struct VoiceCommandsTests {

    @Test(
        "commands that end a sentence are carried out",
        arguments: [
            ("Toplantı bitti, yeni satır. Sonra görüşürüz.", "Toplantı bitti\nSonra görüşürüz."),
            ("Yeni paragraf. Bugün başladık.", "\n\nBugün başladık."),
            ("tamam yeni satır. iyi akşamlar", "tamam\nİyi akşamlar"),
            ("Geliyor musun soru işareti", "Geliyor musun?"),
            ("Geliyor musun, soru işareti.", "Geliyor musun?"),
            ("Harika ünlem işareti", "Harika!"),
            ("Gündem iki nokta üst üste", "Gündem:"),
        ])
    func carriedOut(_ said: String, _ written: String) {
        let result = VoiceCommands.apply(said)
        #expect(result.text == written)
        #expect(!result.commands.isEmpty)
    }

    @Test(
        "the same words inside a sentence stay words",
        arguments: [
            "Yeni satır ekledim.",
            "Soru işareti koydum ama gitmedi.",
            "Bu yeni paragrafı okudun mu?",
            "Yeni satırlar ekledim.",
            "Sabah erken kalktım.",
        ])
    func words(_ sentence: String) {
        let result = VoiceCommands.apply(sentence)
        #expect(result.text == sentence)
        #expect(result.commands.isEmpty)
    }

    @Test("in code, no line breaks: only punctuation")
    func code() {
        #expect(VoiceCommands.apply("Bitti yeni satır.", code: true).text == "Bitti yeni satır.")
        #expect(VoiceCommands.apply("Çalışıyor mu soru işareti", code: true).text == "Çalışıyor mu?")
    }

    @Test("a control command is the whole dictation")
    func control() {
        #expect(VoiceCommands.control("Geri al.") == .undoLast)
        #expect(VoiceCommands.control("bunu sil") == .undoLast)
        #expect(VoiceCommands.control("Son yazdığımı sil.") == .undoLast)
        #expect(VoiceCommands.control("Kitabı geri al.") == nil)
        #expect(VoiceCommands.control("geri al bunu yarın") == nil)
    }

    @Test("the last dictation is removed only if it ends at the caret")
    func undoRange() {
        let value = "Merhaba dünya"
        #expect(UndoDictation.range(value: value, caret: value.utf16.count, pasted: "dünya")
            == NSRange(location: 8, length: 5))
        #expect(UndoDictation.range(value: value, caret: 7, pasted: "dünya") == nil)
        #expect(UndoDictation.range(value: "Merhaba dünyam", caret: 14, pasted: "dünya") == nil)
        #expect(UndoDictation.range(value: "", caret: 0, pasted: "dünya") == nil)
    }

    @Test("ranges are counted in UTF-16, as Accessibility counts them")
    func utf16() {
        let value = "a 👍 b"
        #expect(UndoDictation.range(value: value, caret: value.utf16.count, pasted: "👍 b")
            == NSRange(location: 2, length: 4))
    }

    @Test("the pipeline runs commands last, without line breaks when typing")
    func pipeline() async {
        var config = Config()
        #expect(config.voiceCommands)
        let pasted = await TranscriptPipeline(config: config).process("Toplantı bitti, yeni satır. Sonra görüşürüz.")
        #expect(pasted.text == "Toplantı bitti\nSonra görüşürüz.")
        #expect(pasted.commands == ["yeni satır"])

        config.injectMode = .type
        let typed = await TranscriptPipeline(config: config).process("Toplantı bitti, yeni satır.")
        #expect(!typed.text.contains("\n"))

        config.injectMode = .paste
        config.voiceCommands = false
        let off = await TranscriptPipeline(config: config).process("Toplantı bitti, yeni satır.")
        #expect(off.text == "Toplantı bitti, yeni satır.")
    }

    @Test("the switch is read from the config file")
    func configKey() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "yaz-cmd-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{ "voice_commands": false }"#.utf8).write(to: url)
        #expect(Config.load(from: url).voiceCommands == false)
    }
}
