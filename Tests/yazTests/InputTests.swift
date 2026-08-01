import Foundation
import Testing

@testable import yaz

@Suite("Hotkey — parrot'un belgeleyip yazmadığı özellik")
struct HotkeyTests {

    @Test("config'de kullanılan tüm isimler çözülür")
    func allNamesParse() {
        for key in Hotkey.allCases {
            #expect(Hotkey(rawValue: key.rawValue) == key)
        }
    }

    @Test("bilinmeyen isim reddedilir — sessizce fn'e düşmemeli")
    func unknownNameIsRejected() {
        #expect(Hotkey(rawValue: "caps-lock") == nil)
        #expect(Hotkey(rawValue: "") == nil)
    }

    @Test("sağ/sol ayrımı gereken tuşların keycode'u var, fn'in yok")
    func sidedKeysCarryKeyCodes() {
        #expect(Hotkey.fn.keyCode == nil)
        for key in Hotkey.allCases where key != .fn {
            #expect(key.keyCode != nil, "\(key.rawValue) keycode'suz — sağ/sol ayrılamaz")
        }
    }

    @Test("her tuşun ayrı maskesi ve keycode'u var")
    func keyCodesAreDistinct() {
        let codes = Hotkey.allCases.compactMap(\.keyCode)
        #expect(Set(codes).count == codes.count)
    }

    @Test("yalnızca fn sistem ayarıyla çakışıyor")
    func onlyFnConflicts() {
        #expect(Hotkey.fn.conflictsWithSystemFnAction)
        for key in Hotkey.allCases where key != .fn {
            #expect(!key.conflictsWithSystemFnAction)
        }
    }
}

@Suite("TextInjector — parçalama Türkçeyi bozmamalı")
struct TextInjectorTests {

    @Test("parçalar sınırı aşmaz")
    func chunksRespectLimit() {
        let text = String(repeating: "abcdefghij", count: 12)
        for chunk in TextInjector.chunks(of: text, maxUnits: 20) {
            #expect(chunk.utf16.count <= 20)
        }
    }

    @Test("parçalar birleşince orijinali verir")
    func chunksRoundTrip() {
        let text = "Yarın saat 14'te toplantı var, pull request'i merge etmem lazım."
        #expect(TextInjector.chunks(of: text, maxUnits: 20).joined() == text)
    }

    /// parrot UTF-16 dizisini körlemesine 20'şer kesiyor. Bu, birleşik
    /// karakterlerin ortasından bölebilir; Türkçe metin bunlarla dolu.
    @Test("grafem kümesi ortadan bölünmez")
    func neverSplitsGraphemeClusters() {
        let text = "çğıöşü ÇĞİÖŞÜ değişmedi güncelleştirilebilir"
        let chunks = TextInjector.chunks(of: text, maxUnits: 8)
        #expect(chunks.joined() == text)
        // Her parça kendi başına geçerli bir String olmalı.
        for chunk in chunks {
            #expect(chunk.unicodeScalars.allSatisfy { $0.value != 0xFFFD })
        }
    }

    @Test("emoji ve birleşik işaretler bölünmez")
    func handlesWidePairs() {
        let text = "tamam 👍🏽 bitti 👨‍👩‍👧 son"
        let chunks = TextInjector.chunks(of: text, maxUnits: 4)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { !$0.isEmpty })
    }

    @Test("boş metin boş liste verir")
    func emptyText() {
        #expect(TextInjector.chunks(of: "", maxUnits: 20).isEmpty)
    }

    @Test("tek grafem sınırdan büyükse yine de bütün kalır")
    func oversizedGraphemeStaysWhole() {
        let flag = "👨‍👩‍👧‍👦"   // sınırdan geniş
        let chunks = TextInjector.chunks(of: flag, maxUnits: 2)
        #expect(chunks.joined() == flag)
    }

    @Test("varsayılan mod pano — Electron'da karakter düşmemesi için")
    func defaultModeIsPaste() {
        #expect(Config().injectMode == .paste)
    }
}
