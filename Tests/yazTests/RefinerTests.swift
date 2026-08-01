import Foundation
import Testing

@testable import yaz

/// Stands in for the on-device model so the guards can be tested on any
/// machine, including one where Apple Intelligence is switched off.
private struct StubBackend: RefinerBackend {
    let response: String
    var delay: Duration = .zero
    var failure: Error?

    func rewrite(_ text: String) async throws -> String {
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return response
    }
}

private struct Boom: Error {}

@Suite("FillerFilter — modelsiz, risksiz temizlik")
struct FillerFilterTests {

    @Test("tereddüt sesleri atılır")
    func stripsHesitations() {
        #expect(FillerFilter.strip("ıı yarın toplantı var") == "yarın toplantı var")
        #expect(FillerFilter.strip("yarın eee toplantı var") == "yarın toplantı var")
        #expect(FillerFilter.strip("mmm tamam") == "tamam")
    }

    @Test("birden fazla tereddüt aynı anda atılır")
    func stripsMultiple() {
        #expect(FillerFilter.strip("ıı yarın ee saat ikide mmm toplantı")
            == "yarın saat ikide toplantı")
    }

    /// Bunlar gerçek kelime; bağlam olmadan atılamaz. Karar dil modelinin.
    @Test(
        "gerçek kelimeler korunur — bağlam gerektiren dolgu sözcükleri LLM'in işi",
        arguments: [
            "yani böyle oldu",
            "şey lazım bize",
            "hani söylemiştim",
            "işte bu kadar",
            "ya sen ne dedin",
            "ha tamam anladım",
        ]
    )
    func keepsRealWords(_ text: String) {
        #expect(FillerFilter.strip(text) == text)
    }

    /// "o" zamir, "a" bağlaç. Tek harfli sesli yalnız başka bir tereddüdün
    /// yanındayken tereddüt sayılır.
    @Test("tek harfli sesli tek başına atılmaz")
    func singleVowelKept() {
        #expect(FillerFilter.strip("o proje için") == "o proje için")
        #expect(FillerFilter.strip("bu o değil") == "bu o değil")
    }

    @Test("art arda gelen tek harfli sesliler tereddüt sayılır")
    func adjacentSingleVowelsAreHesitation() {
        #expect(FillerFilter.strip("ı ı yarın gidiyorum") == "yarın gidiyorum")
    }

    @Test("ekli kelime asla atılmaz")
    func suffixedWordsKept() {
        #expect(FillerFilter.strip("E'nin anlamı") == "E'nin anlamı")
    }

    @Test("temizlik sonrası noktalama toparlanır")
    func tidiesPunctuation() {
        #expect(FillerFilter.strip("yarın ıı , toplantı var") == "yarın, toplantı var")
        #expect(FillerFilter.strip("ıı, yarın toplantı") == "yarın toplantı")
    }

    @Test("değişiklik yoksa metin aynen döner")
    func noChangeIsIdentity() {
        let text = "Yarın saat ikide toplantımız var."
        #expect(FillerFilter.strip(text) == text)
    }

    @Test("boş girdi çökmez")
    func emptyInput() {
        #expect(FillerFilter.strip("") == "")
        #expect(FillerFilter.strip("   ").isEmpty)
    }
}

@Suite("RefinementGuard — modelin çıktısı hak ederek girer")
struct RefinementGuardTests {

    static let original = "ıı yarın saat ikide toplantımız var hani o proje için hazırlık lazım"

    @Test("makul bir temizlik kabul edilir")
    func acceptsPlausibleCleanup() {
        let candidate = "Yarın saat ikide toplantımız var. O proje için hazırlık lazım."
        #expect(RefinementGuard.reject(original: Self.original, candidate: candidate) == nil)
    }

    @Test("boş çıktı reddedilir")
    func rejectsEmpty() {
        #expect(RefinementGuard.reject(original: Self.original, candidate: "") != nil)
    }

    /// Özetleme en olası kötü davranış: model "temizle" yerine "kısalt" anlıyor.
    @Test("özetleme reddedilir")
    func rejectsSummary() {
        let reason = RefinementGuard.reject(original: Self.original, candidate: "Toplantı var.")
        #expect(reason != nil)
    }

    @Test("ekleme yapan çıktı reddedilir")
    func rejectsAddition() {
        let candidate = Self.original
            + " Ayrıca size yardımcı olabileceğim başka bir konu var mı? Umarım bu yardımcı olmuştur."
        #expect(RefinementGuard.reject(original: Self.original, candidate: candidate) != nil)
    }

    @Test("soruyu cevaplayan çıktı reddedilir")
    func rejectsAnswering() {
        let question = "ıı yarın hava nasıl olacak acaba sence"
        let answer = "Yarın hava güneşli ve sıcak olacak, sıcaklık 25 derece civarında."
        #expect(RefinementGuard.reject(original: question, candidate: answer) != nil)
    }

    @Test("içerik kelimeleri kaybolursa reddedilir")
    func rejectsContentLoss() {
        let candidate = "Yarın saat ikide bir şeyler yapacağız herhalde böyle."
        #expect(RefinementGuard.reject(original: Self.original, candidate: candidate) != nil)
    }

    @Test("noktalama ve büyük harf düzeltmesi kayıp sayılmaz")
    func punctuationOnlyIsFullRetention() {
        let source = "toplantımızı ertelediler proje hazırlığını bekliyoruz"
        let candidate = "Toplantımızı ertelediler. Proje hazırlığını bekliyoruz."
        #expect(RefinementGuard.contentRetention(original: source, candidate: candidate) == 1)
        #expect(RefinementGuard.reject(original: source, candidate: candidate) == nil)
    }

    @Test("küçük ek farkları tolere edilir")
    func minorSuffixDriftTolerated() {
        let source = "yarınki toplantıya hazırlığımızı bitirelim"
        let candidate = "Yarınki toplantıya hazırlığımızı bitirelim."
        #expect(RefinementGuard.contentRetention(original: source, candidate: candidate) >= 0.75)
    }

    /// Çatı değişimi (etken → edilgen) anlamı değiştirir; temizlik değildir.
    /// Ölçüldü: bu adayda içerik kelimelerinin %40'ı tanınmıyor.
    @Test("etken/edilgen çatı değişimi reddedilir")
    func rejectsVoiceChange() {
        let source = "toplantımızı ertelediler proje hazırlığını bekliyoruz"
        let candidate = "Toplantımız ertelendi. Proje hazırlığı bekleniyor."
        #expect(RefinementGuard.reject(original: source, candidate: candidate) != nil)
    }

    /// Ölçülerek bulundu: model "yani" ve "hani" kelimelerini doğru biçimde
    /// attı, koruma bunu %30 içerik kaybı sayıp iyi bir temizliği çöpe attı.
    /// Modelden atmasını istediğimiz kelimeler kayıp sayılamaz.
    @Test("bağlamsal dolgu kelimelerinin atılması kayıp sayılmaz")
    func removingFillerWordsIsNotLoss() {
        let source = "yarın şey saat ikide yani toplantımız var hani o proje için hazırlık yapmamız lazım"
        let candidate = "Yarın saat ikide toplantımız var. O proje için hazırlık yapmamız lazım."
        #expect(RefinementGuard.reject(original: source, candidate: candidate) == nil)
    }

    @Test("gerçek içerik kaybı hâlâ yakalanır")
    func realContentLossStillCaught() {
        let source = "yarın saat ikide toplantımız var proje için hazırlık yapmamız lazım"
        let candidate = "Yarın toplantı var."
        #expect(RefinementGuard.reject(original: source, candidate: candidate) != nil)
    }

    @Test("model başlığı ve tırnakları soyulur")
    func cleansWrappers() {
        #expect(RefinementGuard.clean("\"Yarın toplantı var.\"") == "Yarın toplantı var.")
        #expect(RefinementGuard.clean("İşte temizlenmiş metin:\nYarın toplantı var.")
            == "Yarın toplantı var.")
    }

    @Test("boşluklar kırpılır")
    func trims() {
        #expect(RefinementGuard.clean("  metin  ") == "metin")
    }
}

@Suite("Refiner — hiçbir koşulda dikteyi kaybetme")
struct RefinerTests {

    static let messy = "ıı yarın saat ikide toplantımız var hani o proje için hazırlık lazım"

    @Test("off modu metne dokunmaz")
    func offIsIdentity() async {
        let result = await Refiner(mode: .off, backend: StubBackend(response: "x")).refine(Self.messy)
        #expect(result.text == Self.messy)
        #expect(!result.changed)
    }

    @Test("fillers modu modeli hiç çağırmaz")
    func fillersSkipsModel() async {
        let refiner = Refiner(mode: .fillers, backend: StubBackend(response: "MODEL ÇAĞRILDI"))
        let result = await refiner.refine(Self.messy)
        #expect(!result.text.contains("MODEL"))
        #expect(result.text.hasPrefix("yarın"))
        #expect(result.changed)
    }

    @Test("llm modu iyi çıktıyı kabul eder")
    func llmAcceptsGoodOutput() async {
        let good = "Yarın saat ikide toplantımız var. O proje için hazırlık lazım."
        let refiner = Refiner(mode: .llm, backend: StubBackend(response: good))
        let result = await refiner.refine(Self.messy)
        #expect(result.text == good)
        #expect(result.rejection == nil)
    }

    /// En önemli davranış: temizleme adımı yüzünden dikte kaybolmamalı.
    @Test("model hata verirse deterministik sonuca düşülür")
    func fallsBackOnError() async {
        let refiner = Refiner(mode: .llm, backend: StubBackend(response: "", failure: Boom()))
        let result = await refiner.refine(Self.messy)
        #expect(result.text == FillerFilter.strip(Self.messy))
        #expect(result.rejection != nil)
    }

    @Test("model zaman aşımına uğrarsa deterministik sonuca düşülür")
    func fallsBackOnTimeout() async {
        let slow = StubBackend(response: "geç kaldı", delay: .seconds(5))
        let refiner = Refiner(mode: .llm, timeout: .milliseconds(120), backend: slow)

        let started = Date()
        let result = await refiner.refine(Self.messy)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(result.text == FillerFilter.strip(Self.messy))
        #expect(result.rejection != nil)
    }

    @Test("koruma reddederse deterministik sonuca düşülür")
    func fallsBackOnRejection() async {
        let refiner = Refiner(mode: .llm, backend: StubBackend(response: "Toplantı."))
        let result = await refiner.refine(Self.messy)
        #expect(result.text == FillerFilter.strip(Self.messy))
        #expect(result.rejection != nil)
    }

    @Test("boş metin modeli hiç çağırmaz")
    func emptyTextSkipsModel() async {
        let refiner = Refiner(mode: .llm, backend: StubBackend(response: "uydurma"))
        let result = await refiner.refine("   ")
        #expect(!result.text.contains("uydurma"))
    }

    @Test("off ve fillers her makinede kullanılabilir")
    func cheapModesAlwaysAvailable() {
        #expect(Refiner.availability(for: .off).isAvailable)
        #expect(Refiner.availability(for: .fillers).isAvailable)
    }
}
