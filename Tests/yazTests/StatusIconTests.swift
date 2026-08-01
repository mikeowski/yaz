import AppKit
import Testing

@testable import yaz

@Suite("StatusIcon — menü barı işareti")
@MainActor
struct StatusIconTests {

    @Test("her durum için görsel üretilir", arguments: [
        IndicatorState.idle, .recording, .transcribing, .refining,
    ])
    func producesImage(_ state: IndicatorState) {
        let image = StatusIcon.image(for: state)
        #expect(image.size == StatusIcon.size)
        #expect(image.isValid)
    }

    /// Şablon olmayan bir görsel koyu modda görünmez olur.
    @Test("görseller şablon — macOS renklendirir", arguments: [
        IndicatorState.idle, .recording, .transcribing, .refining,
    ])
    func imagesAreTemplates(_ state: IndicatorState) {
        #expect(StatusIcon.image(for: state).isTemplate)
    }

    @Test("menü barı boyutunda")
    func menuBarSized() {
        #expect(StatusIcon.size.width == 18)
        #expect(StatusIcon.size.height == 18)
    }

    /// Boş bir görsel, sıfır genişlikte bir status item demek — bu da
    /// "daemon başlamadı" gibi görünür.
    @Test("hiçbir durum boş piksel üretmiyor", arguments: [
        IndicatorState.idle, .recording, .transcribing, .refining,
    ])
    func drawsSomething(_ state: IndicatorState) throws {
        let image = StatusIcon.image(for: state)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))

        var inked = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.1 {
                    inked += 1
                }
            }
        }
        #expect(inked > 20, "\(state) neredeyse boş: \(inked) piksel")
    }

    /// Kayıt hâli boşta hâlinden görünür biçimde daha "dolu" olmalı, yoksa
    /// kullanıcı mikrofonun açık olduğunu anlamaz.
    @Test("kayıt hâli boştan daha çok mürekkep kullanır")
    func recordingIsDenserThanIdle() throws {
        func ink(_ state: IndicatorState) throws -> Int {
            let tiff = try #require(StatusIcon.image(for: state).tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            var count = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.1 {
                        count += 1
                    }
                }
            }
            return count
        }
        #expect(try ink(.recording) > ink(.idle))
    }
}
