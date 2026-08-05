import AppKit
import Testing

@testable import yaz

@Suite("StatusIcon — the menu bar mark")
@MainActor
struct StatusIconTests {

    @Test("an image is produced for every state", arguments: [
        IndicatorState.idle, .recording, .transcribing, .refining,
    ])
    func producesImage(_ state: IndicatorState) {
        let image = StatusIcon.image(for: state)
        #expect(image.size == StatusIcon.size)
        #expect(image.isValid)
    }

    /// A non-template image goes invisible in dark mode.
    @Test("images are templates — macOS does the colouring", arguments: [
        IndicatorState.idle, .recording, .transcribing, .refining,
    ])
    func imagesAreTemplates(_ state: IndicatorState) {
        #expect(StatusIcon.image(for: state).isTemplate)
    }

    @Test("sized for the menu bar")
    func menuBarSized() {
        #expect(StatusIcon.size.width == 18)
        #expect(StatusIcon.size.height == 18)
    }

    /// An empty image means a zero-width status item, which looks exactly
    /// like "the daemon did not start".
    @Test("no state produces an empty pixel buffer", arguments: [
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
        #expect(inked > 20, "\(state) is nearly blank: \(inked) pixels")
    }

    /// Recording must look visibly fuller than idle, or the user cannot tell
    /// the microphone is live.
    @Test("recording uses more ink than idle")
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
