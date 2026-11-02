import Foundation

/// The names in the user's projects, so dictation can spell them.
///
/// A developer dictating to an editor or an agent says the names of things in
/// their code: "user service", "get user by id", "app delegate dosyası".
/// Whisper writes those as ordinary words, or mangles them. The index lists
/// the compound identifiers and the files of each project folder the user
/// named, and turns them into vocabulary terms whose alias is the spoken form.
/// Nothing is guessed: a correction can only produce a name that exists.
struct ProjectIndex: Sendable, Equatable {

    struct File: Sendable, Equatable {
        /// Path relative to the project root, as an agent's `@` mention takes.
        let path: String
        /// The file name without extension, split into spoken words.
        let spoken: String
    }

    /// Compound identifiers, most frequent first.
    var identifiers: [(name: String, count: Int)] = []
    var files: [File] = []

    static func == (lhs: ProjectIndex, rhs: ProjectIndex) -> Bool {
        lhs.files == rhs.files
            && lhs.identifiers.map(\.name) == rhs.identifiers.map(\.name)
            && lhs.identifiers.map(\.count) == rhs.identifiers.map(\.count)
    }

    static let empty = ProjectIndex()

    /// Limits that keep a scan of a large monorepo under a second or two.
    static let maxFiles = 6000
    static let maxFileBytes = 512 * 1024
    /// How many identifiers become vocabulary terms. More terms mean more
    /// chances of a false match in ordinary speech.
    static let maxTerms = 300
    /// Shorter compound names ("is ok") collide with speech too easily.
    static let minimumIdentifierLength = 6

    static let sourceExtensions: Set<String> = [
        "swift", "m", "h", "mm", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "js", "jsx",
        "ts", "tsx", "mjs", "cjs", "java", "kt", "kts", "scala", "cs", "fs", "php", "ex", "exs",
        "erl", "hs", "ml", "dart", "lua", "sql", "vue", "svelte", "astro", "zig", "nim", "jl",
        "r", "sh", "zsh", "fish", "toml", "yaml", "yml", "json", "graphql", "proto", "tf",
    ]

    static let skippedDirectories: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", "build", "dist", "out", "target",
        "Pods", "DerivedData", "vendor", ".next", ".nuxt", ".venv", "venv", "__pycache__",
        ".gradle", ".idea", ".swiftpm", "coverage", ".turbo", ".cache", ".open-next",
        ".wrangler",
    ]

    // MARK: - Scanning

    /// Index every folder in `paths`. Missing folders are skipped.
    static func scan(_ paths: [String]) -> ProjectIndex {
        var counts: [String: Int] = [:]
        var files: [File] = []
        var seenFiles = 0
        let manager = FileManager.default

        for path in paths {
            let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .standardizedFileURL
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if seenFiles >= maxFiles { break }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if skippedDirectories.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard sourceExtensions.contains(ext) else { continue }
                seenFiles += 1

                // The enumerator can hand back a resolved path (/private/var
                // for /var); fall back to the file name rather than a wrong cut.
                let full = url.standardizedFileURL.path
                let relative = full.hasPrefix(root.path + "/")
                    ? String(full.dropFirst(root.path.count + 1))
                    : url.lastPathComponent
                let stem = url.deletingPathExtension().lastPathComponent
                files.append(File(path: relative, spoken: Identifier.spoken(stem)))

                guard (values?.fileSize ?? 0) <= maxFileBytes,
                      let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                for name in identifiers(in: text) {
                    counts[name, default: 0] += 1
                }
            }
        }

        let ranked = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, count: $0.value) }
        return ProjectIndex(identifiers: ranked, files: files)
    }

    /// Compound identifiers in source text: camelCase, PascalCase,
    /// snake_case. Single words are left out on purpose.
    static func identifiers(in text: String) -> [String] {
        var found: [String] = []
        var current = ""
        func flush() {
            if current.count >= minimumIdentifierLength,
               current.first?.isLetter == true,
               Identifier.isCompound(current) {
                found.append(current)
            }
            current = ""
        }
        for ch in text {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_") {
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return found
    }

    // MARK: - Vocabulary

    /// The identifiers as vocabulary terms: canonical spelling, spoken alias.
    func vocabularyTerms(limit: Int = ProjectIndex.maxTerms) -> [VocabularyTerm] {
        var seenSpoken = Set<String>()
        var terms: [VocabularyTerm] = []
        for (name, _) in identifiers {
            guard terms.count < limit else { break }
            let spoken = Identifier.spoken(name)
            // `UserService` and `userService` sound the same: keep the more
            // frequent spelling, which comes first.
            guard seenSpoken.insert(spoken).inserted else { continue }
            terms.append(VocabularyTerm(canonical: name, aliases: [spoken]))
        }
        return terms
    }
}
