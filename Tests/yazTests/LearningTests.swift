import Foundation
import Testing
@testable import yaz

@Suite("Evaluator — one number, fixed set")
struct EvaluatorTests {

    @Test("the shipped defaults score zero: every measured mangling fixed, no false match")
    func baseline() {
        let score = Evaluator.score()
        #expect(score.falseMatches == 0, "\(score.offenders)")
        #expect(score.misses == 0)
        #expect(score.value == 0)
    }

    @Test("a loose threshold is caught by the precision set")
    func looseThresholdIsWorse() {
        let loose = Evaluator.score(threshold: 0.3, skeletonThreshold: 0.3)
        #expect(loose.value > Evaluator.score().value)
    }

    @Test("a false match costs three misses")
    func weighting() {
        let score = Evaluator.Score(falseMatches: 1, misses: 2, recallCases: 7, precisionCases: 60)
        #expect(score.value == 5)
    }

    @Test("the gate keeps a rule that fixes its case and harms nothing")
    func gateAccepts() {
        let verdict = Evaluator.gate(
            VocabularyTerm(canonical: "Vercel", aliases: ["Vörsel"]), heard: "Vörsel ile yayınladım")
        #expect(verdict.accepted, "\(verdict.reason)")
    }

    @Test("the gate rejects a rule that rewrites ordinary Turkish")
    func gateRejectsFalseMatch() {
        let verdict = Evaluator.gate(
            VocabularyTerm(canonical: "Docker", aliases: ["doktor"]), heard: "doktor")
        #expect(!verdict.accepted)
    }
}

@Suite("Vocabulary — blocked pairs")
struct VocabularyBlockTests {

    @Test("a blocked pair is never replaced again")
    func blocked() {
        let terms = [VocabularyTerm(canonical: "Slack")]
        #expect(Vocabulary(terms: terms).correct("Sılacık üzerinden yaz").didChange)
        let blocked = Vocabulary(
            terms: terms, blocked: [Vocabulary.Block(heard: "Sılacık", term: "Slack")])
        #expect(!blocked.correct("Sılacık üzerinden yaz").didChange)
    }

    @Test("a block is specific to its term")
    func blockIsNarrow() {
        let vocabulary = Vocabulary(
            terms: [VocabularyTerm(canonical: "Slack")],
            blocked: [Vocabulary.Block(heard: "Sılacık", term: "Notion")])
        #expect(vocabulary.correct("Sılacık üzerinden yaz").text.contains("Slack"))
    }
}

@Suite("CorrectionDiff — what the user changed")
struct CorrectionDiffTests {

    @Test("a replaced word inside a longer field is found")
    func replacement() {
        let edits = CorrectionDiff.edits(
            pasted: "Ahmet'e Sılacık üzerinden yaz",
            field: "Merhaba. Ahmet'e Slack üzerinden yaz")
        #expect(edits == [CorrectionDiff.Edit(heard: "Sılacık", meant: "Slack")])
    }

    @Test("multi-word replacements stay together")
    func multiWord() {
        let edits = CorrectionDiff.edits(
            pasted: "Puhrıkı Esti açtım, akşam merge ederim",
            field: "pull request açtım, akşam merge ederim")
        #expect(edits == [CorrectionDiff.Edit(heard: "Puhrıkı Esti", meant: "pull request")])
    }

    @Test("a short dictation that is mostly rewritten is not trusted")
    func tooLittleLeft() {
        #expect(CorrectionDiff.edits(
            pasted: "Puhrıkı Esti açtım bugün", field: "pull request açtım bugün").isEmpty)
    }

    @Test("an untouched dictation gives nothing")
    func untouched() {
        #expect(CorrectionDiff.edits(pasted: "deploy ettim", field: "deploy ettim").isEmpty)
    }

    @Test("added words alone are not mishearings")
    func insertionOnly() {
        #expect(CorrectionDiff.edits(
            pasted: "deploy ettim", field: "deploy ettim ve kontrol ettim").isEmpty)
    }

    @Test("a field that no longer holds the dictation gives nothing")
    func unrelated() {
        #expect(CorrectionDiff.edits(
            pasted: "Sılacık üzerinden yaz", field: "tamamen başka bir metin oldu").isEmpty)
    }
}

@Suite("Learner — keep only what passes the evaluation")
struct LearnerTests {

    @Test("a fix seen once is noted, seen twice is learned")
    func promotesAfterTwo() {
        var learner = Learner(rules: LearnedRules())
        let edit = CorrectionDiff.Edit(heard: "Vörsel", meant: "Vercel")
        let first = learner.observe(edits: [edit], corrections: [], userTerms: [])
        #expect(first == [.noted(heard: "Vörsel", meant: "Vercel", count: 1)])
        let second = learner.observe(edits: [edit], corrections: [], userTerms: [])
        #expect(second == [.learned(heard: "Vörsel", meant: "Vercel")])
        #expect(learner.rules.terms == [VocabularyTerm(canonical: "Vercel", aliases: ["Vörsel"])])
    }

    @Test("a learned rule is not learned again")
    func idempotent() {
        var learner = Learner(rules: LearnedRules())
        let edit = CorrectionDiff.Edit(heard: "Vörsel", meant: "Vercel")
        for _ in 0..<4 { _ = learner.observe(edits: [edit], corrections: [], userTerms: []) }
        #expect(learner.rules.rules.count == 1)
    }

    @Test("a rule the term alone could never match is still learned")
    func farAliasIsLearned() {
        var learner = Learner(rules: LearnedRules())
        let edit = CorrectionDiff.Edit(heard: "kates", meant: "Kubernetes")
        _ = learner.observe(edits: [edit], corrections: [], userTerms: [])
        let events = learner.observe(edits: [edit], corrections: [], userTerms: [])
        #expect(events == [.learned(heard: "kates", meant: "Kubernetes")])
    }

    @Test("an undone repair is blocked at once")
    func undoBlocks() {
        var learner = Learner(rules: LearnedRules())
        let correction = Vocabulary.Correction(
            from: "doktor", to: "Docker", score: 0.8, matchedBy: .skeleton)
        let events = learner.observe(
            edits: [CorrectionDiff.Edit(heard: "Docker", meant: "doktor")],
            corrections: [correction], userTerms: [])
        #expect(events == [.blocked(heard: "doktor", term: "Docker")])
        #expect(learner.rules.blocks == [Vocabulary.Block(heard: "doktor", term: "Docker")])
    }

    @Test("rewording into ordinary Turkish is not a mishearing")
    func meaningEdit() {
        #expect(!Learner.isMishearing(heard: "yaz", meant: "gönder"))
        #expect(!Learner.isMishearing(heard: "Sılacık", meant: "bugün"))
    }

    @Test("sound-alike term fixes are mishearings")
    func soundAlike() {
        #expect(Learner.isMishearing(heard: "Sılacık", meant: "Slack"))
        #expect(Learner.isMishearing(heard: "Vörsel", meant: "Vercel"))
    }

    @Test("apostrophe suffixes and punctuation are stripped before learning")
    func stems() {
        #expect(Learner.stem("Slack'ten,") == "Slack")
    }

    @Test("forget removes a term's rules and blocks")
    func forget() {
        var rules = LearnedRules()
        rules.learn(heard: "Vörsel", meant: "Vercel", at: Date())
        rules.blocks.append(Vocabulary.Block(heard: "versel", term: "Vercel"))
        rules.forget(term: "vercel")
        #expect(rules.rules.isEmpty)
        #expect(rules.blocks.isEmpty)
    }

    @Test("rules survive a round trip to disk")
    func persistence() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "yaz-learned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var rules = LearnedRules()
        rules.learn(heard: "Vörsel", meant: "Vercel", at: Date(timeIntervalSince1970: 1_800_000_000))
        rules.blocks.append(Vocabulary.Block(heard: "doktor", term: "Docker"))
        try rules.save(to: url)
        #expect(LearnedRules.load(from: url) == rules)
    }

    @Test("a missing file is an empty rule set")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory.appending(path: "yaz-none-\(UUID()).json")
        #expect(LearnedRules.load(from: url) == LearnedRules())
    }
}
