import Foundation
import Testing

@testable import yaz

@Suite("Identifier — how code names are said and written")
struct IdentifierTests {

    @Test("splits camel, pascal, snake and acronyms into spoken words")
    func words() {
        #expect(Identifier.words("getUserById") == ["get", "user", "by", "id"])
        #expect(Identifier.words("HTTPServer") == ["http", "server"])
        #expect(Identifier.words("user_service") == ["user", "service"])
        #expect(Identifier.words("parseJSON") == ["parse", "json"])
        #expect(Identifier.spoken("AppDelegate") == "app delegate")
    }

    @Test("a single word is not a compound name")
    func compound() {
        #expect(Identifier.isCompound("UserService"))
        #expect(!Identifier.isCompound("Session"))
    }

    @Test("joins words in every style")
    func join() {
        let words = ["user", "name"]
        #expect(Identifier.join(words, style: .camel) == "userName")
        #expect(Identifier.join(words, style: .pascal) == "UserName")
        #expect(Identifier.join(words, style: .snake) == "user_name")
        #expect(Identifier.join(words, style: .kebab) == "user-name")
        #expect(Identifier.join(words, style: .screaming) == "USER_NAME")
    }
}

@Suite("ProjectIndex — the names in the user's code")
struct ProjectIndexTests {

    @Test("finds compound identifiers and skips single words and short ones")
    func identifiers() {
        let source = """
            final class UserService { func getUserById(_ id: Int) {} }
            let user_id = 3; let isOk = true; var session = Session()
            """
        let found = Set(ProjectIndex.identifiers(in: source))
        #expect(found.contains("UserService"))
        #expect(found.contains("getUserById"))
        #expect(!found.contains("Session"))   // a single word
        #expect(!found.contains("isOk"))      // too short
        #expect(!found.contains("user_id"))   // too short
    }

    @Test("scans a folder, skips build output, ranks by frequency")
    func scan() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yaz-proj-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "Sources/App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appending(path: "node_modules/pkg"), withIntermediateDirectories: true)
        try "class AppDelegate { let paymentGateway = PaymentGateway() }\nPaymentGateway"
            .write(to: root.appending(path: "Sources/App/AppDelegate.swift"), atomically: true, encoding: .utf8)
        try "class IgnoredThing {}".write(
            to: root.appending(path: "node_modules/pkg/index.js"), atomically: true, encoding: .utf8)

        let index = ProjectIndex.scan([root.path])
        #expect(index.files.map(\.path) == ["Sources/App/AppDelegate.swift"])
        #expect(index.files.first?.spoken == "app delegate")
        #expect(index.identifiers.first?.name == "PaymentGateway")
        #expect(!index.identifiers.map(\.name).contains("IgnoredThing"))

        let terms = index.vocabularyTerms()
        #expect(terms.contains(VocabularyTerm(canonical: "PaymentGateway", aliases: ["payment gateway"])))
        // paymentGateway sounds the same as PaymentGateway: one term
        #expect(terms.filter { $0.aliases == ["payment gateway"] }.count == 1)
    }
}

@Suite("CodeFormatter — spoken code into written code")
struct CodeFormatterTests {

    static let files = [
        ProjectIndex.File(path: "App/AppDelegate.swift", spoken: "app delegate"),
        ProjectIndex.File(path: "Sources/Billing/PaymentGateway.swift", spoken: "payment gateway"),
    ]

    @Test("a casing command writes the identifier")
    func casing() {
        let result = CodeFormatter().format("değişkenin adı camel case user name olsun")
        #expect(result.text == "değişkenin adı userName olsun")
        #expect(result.changes == [CodeFormatter.Change(from: "camel case user name", to: "userName")])
    }

    @Test("a casing command stops at the end of the clause")
    func casingStopsAtPunctuation() {
        let result = CodeFormatter().format("snake case max retry count, sonra devam")
        #expect(result.text == "max_retry_count, sonra devam")
    }

    @Test("without a command the text is untouched, whitespace included")
    func untouched() {
        let text = "bugün  hava güzel"
        #expect(CodeFormatter().format(text).text == text)
    }

    @Test("a file named before 'dosya' becomes an @ mention, the suffix stays")
    func fileMention() {
        let result = CodeFormatter(files: Self.files).format("app delegate dosyasına bak")
        #expect(result.text == "@App/AppDelegate.swift dosyasına bak")
    }

    @Test("works with English 'file' and a Turkish-mangled name")
    func fileMentionMangled() {
        let result = CodeFormatter(files: Self.files).format("open the peyment gateway file")
        #expect(result.text == "open the @Sources/Billing/PaymentGateway.swift file")
    }

    @Test("no file that sounds like it: nothing changes")
    func noMatch() {
        let text = "bu dosyayı sil"
        #expect(CodeFormatter(files: Self.files).format(text).text == text)
    }
}

@Suite("CodeContext — which apps take code")
struct CodeContextTests {

    @Test("terminals, editors and agents are code; mail is not")
    func apps() {
        #expect(CodeContext.isCode(bundleID: "com.apple.Terminal"))
        #expect(CodeContext.isCode(bundleID: "com.microsoft.VSCode"))
        #expect(CodeContext.isCode(bundleID: "com.jetbrains.fleet"))
        #expect(!CodeContext.isCode(bundleID: "com.apple.mail"))
        #expect(!CodeContext.isCode(bundleID: nil))
        #expect(CodeContext.isCode(bundleID: "com.example.mine", extra: ["com.example.mine"]))
    }
}

@Suite("TranscriptPipeline — code mode only where code goes")
struct CodePipelineTests {

    static func pipeline() -> TranscriptPipeline {
        let index = ProjectIndex(
            identifiers: [(name: "PaymentGateway", count: 4)],
            files: CodeFormatterTests.files)
        var config = Config()
        config.refine = .off
        return TranscriptPipeline(config: config, project: index)
    }

    @Test("in code, the spoken name becomes the identifier")
    func code() async {
        let output = await Self.pipeline().process("payment gateway testini yaz", code: true)
        #expect(output.text.hasPrefix("PaymentGateway"))
    }

    @Test("in prose, the same words stay words")
    func prose() async {
        let output = await Self.pipeline().process("payment gateway testini yaz", code: false)
        #expect(output.text == "payment gateway testini yaz")
        #expect(output.codeChanges.isEmpty)
    }
}
