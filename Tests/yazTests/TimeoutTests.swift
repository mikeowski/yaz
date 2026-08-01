import Foundation
import Testing

@testable import yaz

/// The timeout wrapper is the only thing standing between a wedged Core ML
/// call and a daemon that never dictates again. It had no test until now.
@Suite("withTranscriptionTimeout — takılan çıkarımdan kurtulma")
struct TimeoutTests {

    @Test("zamanında biten iş sonucunu döndürür")
    func fastWorkReturns() async throws {
        let value = try await withTranscriptionTimeout(.seconds(5), engine: "test") { 42 }
        #expect(value == 42)
    }

    @Test("takılan iş zaman aşımına uğrar ve çağıranı serbest bırakır")
    func hungWorkTimesOut() async {
        let started = Date()
        do {
            _ = try await withTranscriptionTimeout(.milliseconds(120), engine: "test") {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
            Issue.record("zaman aşımı bekleniyordu")
        } catch let error as YazError {
            guard case .transcriptionTimedOut(let engine, _) = error else {
                Issue.record("transcriptionTimedOut bekleniyordu, gelen: \(error)")
                return
            }
            #expect(engine == "test")
        } catch {
            Issue.record("YazError bekleniyordu, gelen: \(error)")
        }
        // Asıl garanti bu: çağıran 30 sn beklemedi.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("işin kendi hatası zaman aşımı hatasına dönüşmez")
    func workErrorPropagates() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withTranscriptionTimeout(.seconds(5), engine: "test") {
                throw Boom()
            }
        }
    }

    @Test("zaman aşımı sonrası takılan iş iptal edilir — sızıntı bırakmamalı")
    func losingBranchIsCancelled() async throws {
        let cancelled = CancellationFlag()
        do {
            _ = try await withTranscriptionTimeout(.milliseconds(80), engine: "test") {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.set()          // Task.sleep iptalde fırlatır
                    throw error
                }
                return 1
            }
        } catch {}

        // İptalin yayılması için kısa bir pencere tanı.
        try await Task.sleep(for: .milliseconds(150))
        #expect(cancelled.value)
    }

    @Test("zaman aşımı süresi hata mesajında geçer")
    func messageNamesTheLimit() async {
        do {
            _ = try await withTranscriptionTimeout(.seconds(1), engine: "whisper") {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        } catch let error as YazError {
            #expect(error.description.contains("whisper"))
            #expect(error.description.contains("1"))
        } catch {
            Issue.record("YazError bekleniyordu")
        }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
