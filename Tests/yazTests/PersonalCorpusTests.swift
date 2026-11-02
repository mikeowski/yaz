import Foundation
import Testing
@testable import yaz

@Suite("PersonalCorpus — the user's own evaluation set")
struct PersonalCorpusTests {

    private let vercel = VocabularyTerm(canonical: "Vercel", aliases: ["Vörsel"])

    @Test("a fix is right once the vocabulary makes it")
    func fixScore() {
        var corpus = PersonalCorpus()
        corpus.recordFix(sentence: "Vörsel'e deploy ettim", heard: "Vörsel", meant: "Vercel")
        #expect(corpus.score(Vocabulary(terms: [])).misses == 1)
        #expect(corpus.score(Vocabulary(terms: [vercel])).misses == 0)
    }

    @Test("a kept dictation that changes is a false match")
    func keptScore() {
        var corpus = PersonalCorpus()
        corpus.recordKept("Versel'e gittik dün akşam")
        #expect(corpus.score(Vocabulary(terms: [])).falseMatches == 0)
        let score = corpus.score(Vocabulary(terms: [vercel]))
        #expect(score.falseMatches == 1)
        #expect(score.value == 3)
    }

    @Test("duplicates and short dictations are not recorded")
    func recording() {
        var corpus = PersonalCorpus()
        corpus.recordKept("tamam")
        corpus.recordKept("bu bir cümle")
        corpus.recordKept("  bu bir cümle  ")
        corpus.recordFix(sentence: "a b c", heard: "x", meant: "Y")
        corpus.recordFix(sentence: "a b c", heard: "x", meant: "Y")
        #expect(corpus.kept == ["bu bir cümle"])
        #expect(corpus.fixes.count == 1)
    }

    @Test("the oldest cases go first past the limit")
    func caps() {
        var corpus = PersonalCorpus()
        for i in 0..<(PersonalCorpus.maxKept + 5) { corpus.recordKept("cümle numara \(i) burada") }
        #expect(corpus.kept.count == PersonalCorpus.maxKept)
        #expect(corpus.kept.first == "cümle numara 5 burada")
    }

    @Test("the gate rejects a rule that breaks one of your own sentences")
    func gateUsesPersonal() {
        var corpus = PersonalCorpus()
        corpus.recordKept("Versel'e gittik dün akşam")
        #expect(Evaluator.gate(vercel, heard: "Vörsel").accepted)
        let verdict = Evaluator.gate(vercel, heard: "Vörsel", personal: corpus)
        #expect(!verdict.accepted)
        #expect(verdict.reason.contains("personal"))
    }

    @Test("the learner records each mishearing with its sentence")
    func learnerRecords() {
        var learner = Learner(rules: LearnedRules())
        _ = learner.observe(
            edits: [CorrectionDiff.Edit(heard: "Vörsel", meant: "Vercel")],
            corrections: [], userTerms: [], sentence: "Vörsel'e deploy ettim")
        #expect(learner.personal.fixes.map(\.meant) == ["Vercel"])
    }

    @Test("a learner with your sentences will not learn what breaks them")
    func learnerRejects() {
        var learner = Learner(rules: LearnedRules())
        learner.personal.recordKept("Versel'e gittik dün akşam")
        let edit = CorrectionDiff.Edit(heard: "Vörsel", meant: "Vercel")
        _ = learner.observe(edits: [edit], corrections: [], userTerms: [])
        let events = learner.observe(edits: [edit], corrections: [], userTerms: [])
        guard case .rejected = events.first else {
            Issue.record("expected a rejection, got \(events)")
            return
        }
        #expect(learner.rules.rules.isEmpty)
    }

    @Test("forget removes a term's fixes")
    func forget() {
        var corpus = PersonalCorpus()
        corpus.recordFix(sentence: "Vörsel'e deploy ettim", heard: "Vörsel", meant: "Vercel")
        corpus.forget(term: "vercel")
        #expect(corpus.fixes.isEmpty)
    }

    @Test("cases survive a round trip to disk")
    func persistence() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "yaz-personal-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var corpus = PersonalCorpus()
        corpus.recordKept("bu bir cümle")
        corpus.recordFix(
            sentence: "Vörsel'e deploy ettim", heard: "Vörsel", meant: "Vercel",
            at: Date(timeIntervalSince1970: 1_800_000_000))
        try corpus.save(to: url)
        #expect(PersonalCorpus.load(from: url) == corpus)
        corpus.remove(at: url)
        #expect(PersonalCorpus.load(from: url).isEmpty)
    }
}
