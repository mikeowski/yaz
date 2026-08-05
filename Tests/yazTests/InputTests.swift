import Foundation
import Testing

@testable import yaz

@Suite("Hotkey — the feature parrot documented but never wrote")
struct HotkeyTests {

    @Test("every name used in config resolves")
    func allNamesParse() {
        for key in Hotkey.allCases {
            #expect(Hotkey(rawValue: key.rawValue) == key)
        }
    }

    @Test("an unknown name is rejected — it must not fall back to fn silently")
    func unknownNameIsRejected() {
        #expect(Hotkey(rawValue: "caps-lock") == nil)
        #expect(Hotkey(rawValue: "") == nil)
    }

    @Test("keys needing left/right disambiguation carry a keycode; fn does not")
    func sidedKeysCarryKeyCodes() {
        #expect(Hotkey.fn.keyCode == nil)
        for key in Hotkey.allCases where key != .fn {
            #expect(key.keyCode != nil, "\(key.rawValue) has no keycode — left and right cannot be told apart")
        }
    }

    @Test("each key has its own mask and keycode")
    func keyCodesAreDistinct() {
        let codes = Hotkey.allCases.compactMap(\.keyCode)
        #expect(Set(codes).count == codes.count)
    }

    @Test("only fn collides with a system setting")
    func onlyFnConflicts() {
        #expect(Hotkey.fn.conflictsWithSystemFnAction)
        for key in Hotkey.allCases where key != .fn {
            #expect(!key.conflictsWithSystemFnAction)
        }
    }
}

@Suite("TextInjector — chunking must not break Turkish")
struct TextInjectorTests {

    @Test("chunks stay within the limit")
    func chunksRespectLimit() {
        let text = String(repeating: "abcdefghij", count: 12)
        for chunk in TextInjector.chunks(of: text, maxUnits: 20) {
            #expect(chunk.utf16.count <= 20)
        }
    }

    @Test("chunks rejoin into the original")
    func chunksRoundTrip() {
        let text = "Yarın saat 14'te toplantı var, pull request'i merge etmem lazım."
        #expect(TextInjector.chunks(of: text, maxUnits: 20).joined() == text)
    }

    /// parrot slices the UTF-16 sequence blindly into 20s, which can cut
    /// through a composed character — and Turkish text is full of them.
    @Test("a grapheme cluster is never split down the middle")
    func neverSplitsGraphemeClusters() {
        let text = "çğıöşü ÇĞİÖŞÜ değişmedi güncelleştirilebilir"
        let chunks = TextInjector.chunks(of: text, maxUnits: 8)
        #expect(chunks.joined() == text)
        // Every chunk must be a valid String on its own.
        for chunk in chunks {
            #expect(chunk.unicodeScalars.allSatisfy { $0.value != 0xFFFD })
        }
    }

    @Test("emoji and combining marks are not split")
    func handlesWidePairs() {
        let text = "tamam 👍🏽 bitti 👨‍👩‍👧 son"
        let chunks = TextInjector.chunks(of: text, maxUnits: 4)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { !$0.isEmpty })
    }

    @Test("empty text gives an empty list")
    func emptyText() {
        #expect(TextInjector.chunks(of: "", maxUnits: 20).isEmpty)
    }

    @Test("a single grapheme wider than the limit still stays whole")
    func oversizedGraphemeStaysWhole() {
        let flag = "👨‍👩‍👧‍👦"   // wider than the limit
        let chunks = TextInjector.chunks(of: flag, maxUnits: 2)
        #expect(chunks.joined() == flag)
    }

    @Test("the default mode is the clipboard — typing drops characters in Electron")
    func defaultModeIsPaste() {
        #expect(Config().injectMode == .paste)
    }
}
