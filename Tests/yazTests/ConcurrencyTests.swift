import Foundation
import Testing

@testable import yaz

/// Thread-safe counter for observing what the concurrency helpers actually do.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _starts = 0
    private var _finishes = 0
    private var _peakConcurrent = 0
    private var _live = 0

    func begin() {
        lock.lock()
        _starts += 1
        _live += 1
        _peakConcurrent = max(_peakConcurrent, _live)
        lock.unlock()
    }

    func end() {
        lock.lock()
        _live -= 1
        _finishes += 1
        lock.unlock()
    }

    var starts: Int { lock.withLock { _starts } }
    var finishes: Int { lock.withLock { _finishes } }
    var peakConcurrent: Int { lock.withLock { _peakConcurrent } }
}

@Suite("SingleFlight — aynı yüklemeyi iki kez yapma")
struct SingleFlightTests {

    @Test("eşzamanlı çağrılar tek yüklemeye indirgenir — 1.6 GB modeli iki kez yükleme hatası")
    func collapsesConcurrentCalls() async throws {
        let flight = SingleFlight()
        let counter = Counter()

        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await flight.run {
                        counter.begin()
                        try await Task.sleep(for: .milliseconds(50))
                        counter.end()
                    }
                }
            }
            while let _ = try? await group.next() {}
        }

        #expect(counter.starts == 1)
        #expect(counter.finishes == 1)
    }

    @Test("tamamlandıktan sonraki çağrı yeniden çalışır")
    func runsAgainAfterCompletion() async throws {
        let flight = SingleFlight()
        let counter = Counter()
        let work: @Sendable () async throws -> Void = {
            counter.begin()
            counter.end()
        }
        try await flight.run(work)
        try await flight.run(work)
        #expect(counter.starts == 2)
    }

    /// Başarısız bir indirme genellikle geçicidir; sonraki çağrı yeniden
    /// denemeli, hatayı önbelleğe almamalı.
    @Test("başarısız yükleme önbelleğe alınmaz")
    func failureIsNotCached() async {
        struct Boom: Error {}
        let flight = SingleFlight()
        let counter = Counter()
        let work: @Sendable () async throws -> Void = {
            counter.begin()
            counter.end()
            throw Boom()
        }
        await #expect(throws: Boom.self) { try await flight.run(work) }
        await #expect(throws: Boom.self) { try await flight.run(work) }
        #expect(counter.starts == 2)
    }

    @Test("bekleyen çağrılar da hatayı görür")
    func waitersObserveFailure() async {
        struct Boom: Error {}
        let flight = SingleFlight()
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do {
                        try await flight.run {
                            try await Task.sleep(for: .milliseconds(30))
                            throw Boom()
                        }
                        return false
                    } catch { return true }
                }
            }
            for await threw in group { #expect(threw) }
        }
    }
}

@Suite("SerialGate — çıkarımı sıraya sok")
struct SerialGateTests {

    @Test("işler asla üst üste binmez — WhisperKit reentrancy garantisi vermiyor")
    func neverOverlaps() async throws {
        let gate = SerialGate()
        let counter = Counter()

        await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await gate.run {
                        counter.begin()
                        try await Task.sleep(for: .milliseconds(10))
                        counter.end()
                        return i
                    }
                }
            }
            while let _ = try? await group.next() {}
        }

        #expect(counter.peakConcurrent == 1)
        #expect(counter.finishes == 10)
    }

    @Test("hata veren iş zinciri koparmaz")
    func failureDoesNotBreakChain() async throws {
        struct Boom: Error {}
        let gate = SerialGate()

        await #expect(throws: Boom.self) {
            try await gate.run { throw Boom() }
        }
        let value = try await gate.run { 42 }
        #expect(value == 42)
    }

    @Test("sonuçlar doğru çağırana döner")
    func resultsGoToTheRightCaller() async throws {
        let gate = SerialGate()
        var seen: Set<Int> = []
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<12 {
                group.addTask { try await gate.run { i } }
            }
            for try await value in group { seen.insert(value) }
        }
        #expect(seen == Set(0..<12))
    }
}
