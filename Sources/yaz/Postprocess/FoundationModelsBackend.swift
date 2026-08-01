import Foundation
import FoundationModels

/// Apple's on-device language model, used to tidy dictation.
///
/// Chosen over a downloaded model (Ollama, llama.cpp) for one reason that
/// matters at this layer: it ships with macOS 26. No extra gigabytes, no
/// second runtime, nothing for the user to install or keep updated — the same
/// argument that makes on-device transcription worth the trouble in the first
/// place.
///
/// It is not a general rewriter and is not asked to be one. The instructions
/// below are narrow on purpose, and `RefinementGuard` assumes they will
/// sometimes be ignored anyway.
struct FoundationModelsBackend: RefinerBackend {

    /// Kept deliberately blunt. The measured failure mode when asked to do more
    /// — repair garbled technical terms against a supplied list — was that the
    /// model returned the input unchanged after 1.4 s. Asking only for removal
    /// and punctuation is a task it actually performs.
    static let instructions = """
        Sen bir Türkçe dikte temizleme asistanısın.

        Görevin SADECE şunlar:
        - Kekeleme, tereddüt sesleri ve dolgu kelimeleri at ("ıı", "ee", \
        bağlam gereği anlamsız kalan "yani", "şey", "hani", "işte").
        - Noktalama ve cümle sınırlarını düzelt.
        - Cümle başlarını büyük harf yap.

        KESİNLİKLE YAPMA:
        - Kelimeleri eş anlamlılarıyla değiştirme.
        - Cümleyi yeniden yazma, özetleme veya kısaltma.
        - Yeni bilgi, açıklama veya yorum ekleme.
        - Yabancı terimlerin yazımını değiştirme.
        - Soru varsa cevaplama — sadece metni temizle.

        Yanıt olarak SADECE temizlenmiş metni ver. Açıklama, tırnak, başlık ekleme.
        """

    static func availability() -> RefinerAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(describe(reason))
        @unknown default:
            return .unavailable("unknown state")
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "this Mac does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off — System Settings → Apple Intelligence & Siri"
        case .modelNotReady:
            return "the model has not downloaded yet — wait a while and try again"
        @unknown default:
            return "unavailable"
        }
    }

    func rewrite(_ text: String) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw YazError.refinerUnavailable(detail: Self.availabilityDetail())
        }

        // A fresh session per utterance: dictation turns are unrelated, and
        // carrying context between them invites the model to "continue" the
        // previous sentence instead of cleaning this one.
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(
            to: text,
            options: GenerationOptions(temperature: 0)
        )
        return response.content
    }

    private static func availabilityDetail() -> String {
        guard case .unavailable(let reason) = availability() else { return "unavailable" }
        return reason
    }
}
