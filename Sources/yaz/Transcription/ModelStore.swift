import Foundation

/// Where WhisperKit keeps its weights, and whether they are actually complete.
///
/// Two things are worth stating plainly. First, the location: WhisperKit
/// downloads into **`~/Documents/huggingface`**, not a cache directory. On a
/// Mac with iCloud Documents sync that means 1.6 GB of model weights get
/// pushed to the cloud. yaz cannot change the library's choice, but `yaz
/// doctor` can at least tell the user where the bytes went.
///
/// Second, completeness. Checking "does the folder exist" calls an interrupted
/// download finished, and the failure then surfaces minutes later as a Core ML
/// load error. A model is only present when every required component is on
/// disk and non-trivial in size.
enum ModelStore {

    static var whisperRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/huggingface/models/argmaxinc/whisperkit-coreml")
    }

    static func directory(for whisperKitID: String) -> URL {
        whisperRoot.appending(path: whisperKitID)
    }

    /// Component folders every WhisperKit checkpoint ships, with a floor on
    /// the size we expect each to reach once complete.
    ///
    /// The floors are deliberately far below the real sizes (the turbo decoder
    /// is 342 MB, the encoder 1.2 GB) — they exist to catch a truncated or
    /// zero-byte artefact, not to pin exact bytes that differ per checkpoint.
    private static let requiredComponents: [(name: String, minBytes: Int64)] = [
        ("AudioEncoder.mlmodelc", 1_000_000),
        ("TextDecoder.mlmodelc", 1_000_000),
        ("MelSpectrogram.mlmodelc", 10_000),
        ("config.json", 10),
    ]

    struct Status: Sendable, Equatable {
        var isComplete: Bool
        var missing: [String]
        var sizeBytes: Int64
        var path: String

        var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    /// Inspect a checkpoint on disk.
    static func status(for whisperKitID: String) -> Status {
        let root = directory(for: whisperKitID)
        let fm = FileManager.default

        guard fm.fileExists(atPath: root.path) else {
            return Status(isComplete: false, missing: ["(hiç indirilmemiş)"], sizeBytes: 0, path: root.path)
        }

        var missing: [String] = []
        for component in requiredComponents {
            let url = root.appending(path: component.name)
            guard fm.fileExists(atPath: url.path) else {
                missing.append(component.name)
                continue
            }
            if size(of: url) < component.minBytes {
                missing.append("\(component.name) (eksik/bozuk)")
            }
        }

        return Status(
            isComplete: missing.isEmpty,
            missing: missing,
            sizeBytes: size(of: root),
            path: root.path
        )
    }

    /// Total bytes under `url`, following the directory tree. Returns 0 for a
    /// path that cannot be read rather than throwing — callers are reporting
    /// status, not depending on the number.
    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if !isDirectory.boolValue {
            let attributes = try? fm.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? Int64) ?? 0
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
