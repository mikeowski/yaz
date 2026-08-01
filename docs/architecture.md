# yaz — mimari

## Neden var

parrot (digimata) macOS için mükemmel bir dikte iskeleti kurmuş, ama üç şeyi
tasarım gereği reddediyor. Türkçe konuşan bir geliştirici için bu üçü tam da
ihtiyaç duyulan şeyler:

1. **Çok dilli varsayılan** — parrot `whisper-base.en` ile geliyor, Türkçe hiç çalışmıyor.
2. **Güvenilir metin yerleştirme** — parrot 20 karakterlik `CGEvent` parçaları
   yazıyor; Electron uygulamalarında (Slack, Notion, Cursor) karakter düşüyor.
3. **Son işleme yok** — "No custom vocabulary, prompts, or post-processing."
   Dikte çıktısı ham geliyor: dolgu kelimeler, bozuk teknik terimler.

yaz bu üçünü hedefliyor. İskelet parrot'tan, hedefler ondan farklı.

## Ölçülmüş gerçekler (M4 Pro, 24 GB, macOS 26.5)

Bu sayılar iddia değil, bu makinede ölçüldü. `fixtures/` altındaki sabit
Türkçe seslerle `yaz transcribe` üzerinden tekrarlanabilir.

| | whisper large-v3-turbo |
|---|---|
| İlk model yükleme (CoreML derlemesi) | ~115–210 sn, tek seferlik |
| Sonraki her açılış | ~6.5–7 sn |
| 5.6 sn konuşma → metin | **506 ms** (RTF 0.091) |
| 12.1 sn konuşma → metin | **855 ms** (RTF 0.071) |
| RAM | ~210–260 MB |
| 0.6 sn'lik ifade | boş dönüyor |

## Motor seçimi — ve neden Parakeet değil

İlk plan Parakeet TDT v3'e geçmekti: 600 MB (Whisper'ın 1.6 GB'ına karşı),
ANE'de çok daha hızlı, "25 Avrupa dili" desteği. **Bu plan yanlıştı.**

Parakeet TDT v3'ün dil listesi 25 AB dili + Rusça + Ukraynaca:
bg, hr, cs, da, nl, en, et, fi, fr, de, el, hu, it, lv, lt, mt, pl, pt, ro,
sk, sl, es, sv, ru, uk. **Türkçe yok.** İki bağımsız kaynakla doğrulandı:
NVIDIA'nın model kartı ve FluidAudio'nun kendi `Language` enum'u (`tr` case'i
yok; kütüphanenin tamamında `"tr"` yalnızca bir TTS sabit listesinde geçiyor).

Dolayısıyla **Türkçe için Whisper tek on-device seçenek.** Bedeli: 1.6 GB
ağırlık ve utterance başına 500–900 ms. Parakeet `--engine-name parakeet` ile
duruyor; İngilizce dikte için hâlâ çok daha hızlı.

## Özel sözlük — neden ASR seviyesinde çözülemedi

Asıl doğruluk sorunu düz Türkçede değil, İngilizce teknik terimlerde:

```
girdi : "Ahmet'e Slack üzerinden yaz, pull request'i merge et, CI pipeline yeşile dönsün"
çıktı : "Ahmet'e Sılacık üzerinden yaz, Puhrıkı Esti'de merge et, C.I.P. eline yeşile dönsün"
```

Denenen ve **elenen** iki yol:

1. **Whisper initial-prompt biasing** (`DecodingOptions.promptTokens`) — ASR'a
   jargonu öğretmenin standart yolu. WhisperKit'te `large-v3-turbo` ile
   **her seferinde boş çıktı** veriyor (0 segment, sıfır istatistik).
   `prefixTokens` ise prompt'u olduğu gibi echo'luyor — o farklı bir özellik.
2. **LLM'e sözlük verip düzelttirme** — Apple FoundationModels'a hedef terim
   listesi verildi, yine de "Sılacık"ı düzeltemedi (1.40 sn harcandı).
   ~3B'lik on-device model bu bulanık fonetik eşlemeyi Türkçede yapamıyor.

Dolayısıyla özel sözlük **deterministik bir son işleme katmanı** olacak:
kullanıcı sözlüğüne karşı fonetik normalizasyon + düzenleme mesafesi eşleşmesi.
Model tahmininden değil, kullanıcının verdiği listeden çalışır.

## Son işleme — LLM'in gerçekten iyi olduğu yer

Aynı FoundationModels, dolgu temizlemede çok başarılı (**0.46 sn**):

```
girdi : "ıı yarın şey saat ikide yani toplantımız var hani o proje için ee hazırlık yapmamız lazım"
çıktı : "Yarın saat ikide toplantımız var. O proje için hazırlık yapmamız lazım."
```

Yani katman ayrımı net:

| Sorun | Çözen |
|---|---|
| Bozuk özel isim / teknik terim | deterministik sözlük eşleştirme |
| Dolgu kelime, kekeleme, noktalama | FoundationModels (on-device, indirme yok) |

FoundationModels macOS 26 ile geliyor — sıfır indirme, sıfır bağımlılık.
Paketin `platforms: [.macOS(.v26)]` olmasının sebebi bu.

## Katmanlar

```
hotkey (CGEventTap)
   ↓ .pressed / .released
AudioCapture (AVAudioEngine → 16 kHz mono Float32)
   ↓ [Float]
Transcriber  ← protokol; motor buradan takılır
   ├── WhisperTranscriber   (varsayılan, Türkçe)
   └── ParakeetTranscriber  (opsiyonel, hızlı, İngilizce)
   ↓ TranscriptionOutput
Vocabulary   (deterministik terim düzeltme)
   ↓
Refiner      (FoundationModels: dolgu temizleme, noktalama)
   ↓ String
TextInjector (pano yapıştırma; CGEvent yazımı yedek)
```

`Transcriber` protokolü kasıtlı olarak küçük: `prepare / transcribe / release`.
`transcribe` dosya URL'i değil `[Float]` alıyor — dikte utterance'ları saniyeler
uzunluğunda ve bellekte; sırf geri okumak için diske yazmak, gecikmenin ürünün
kendisi olduğu tek yola gecikme ekler.

`release()` protokolde çünkü yaz gün boyu açık duran bir daemon; boştayken
yüzlerce megabaytlık CoreML ağırlığını resident tutmamalı.


## Sağlamlaştırma katmanı

Motor katmanı "çalışıyor"dan "güvenilir"e taşındı. Dikte, çıktısı doğrudan
kullanıcının imlecine yazılan bir araç: yanlış metin, hata mesajından daha
pahalı. Bu yüzden üç savunma hattı var.

### 1. Çıkarımdan önce — `SpeechGate`

Ölçülen iki gerçek: 0.6 sn'lik ifade Whisper'dan **boş** dönüyor, ve sessizlik
verildiğinde model susmuyor — `[BLANK_AUDIO]`, `(müzik)` ya da düpedüz uydurma
bir cümle üretiyor.

Kısa/sessiz tamponu burada elemek mikrosaniye sürüyor; çıkarımdan sonra elemek
~500 ms. Kapılar: en az 0.35 sn süre, en az 0.005 tepe genlik.

Bu reddedişler `isBenignInput` ile işaretli — kısayola yanlışlıkla basmak hata
değil, daemon bunları sessizce atmalı.

### 2. Çıkarımdan sonra — `TranscriptionQuality`

Whisper asla "bilmiyorum" demez, her zaman metin döndürür. Ama decoder segment
başına üç sinyal veriyor ve parrot bunları yere düşürüyor:

| Sinyal | Yakaladığı |
|---|---|
| `noSpeechProb` > 0.6 | konuşma değil |
| `compressionRatio` > 2.4 | tekrar döngüsü ("teşekkürler teşekkürler…") |
| `avgLogprob` < -1.0 | uydurma metin |
| `avgLogprob` < -0.7 | düşük güven (kullanılabilir ama işaretli) |

Ek olarak doğrudan kelime-tekrarı tespiti var: kısa bir ifadede sıkıştırma
oranı eşiği geçmeden döngü oluşabiliyor.

Eşikler OpenAI'nin referans decoder'ından. Segment sinyalleri süreye göre
ağırlıklı ortalanıyor — tek kelimelik bir segment kararı çekmesin diye. Ama
sıkıştırma oranında **en kötü** segment alınıyor: tek döngüye giren segment
tüm ifadeyi mahkûm eder, ortalamada erimemeli.

### 3. Sınırlarda — tip güvenli hatalar ve zaman aşımı

`YazError` her başarısızlığı adlandırıyor. Sebebi somut: ilk prototipte
`AVAudioFile` çağrısı patladı, Foundation onu çıplak
`_GenericObjCError.nilError`'a çevirdi, CLI `Error: nilError` yazdı. Bu kimseye
bir şey söylemiyor.

`withTranscriptionTimeout` takılan bir Core ML çağrısının daemon'ı kilitlemesini
engelliyor. Dürüst sınır: çağıran serbest kalır, ANE hemen durmaz.

### Dil doğrulaması — sessiz yanlıştan iyi hata

Parakeet, Türkçe sese kendinden emin saçmalık üretiyor, reddetmiyor:

```
$ yaz transcribe --engine-name parakeet --language en fixtures/t1.wav
Bugun Parot Krojesini in Jeledimweon device transcription mimari sinichosdum.
```

Bu yüzden `supportedLanguages` motor protokolünde. Desteklenmeyen çift model
indirilmeden önce reddediliyor:

```
$ yaz transcribe --engine-name parakeet --language tr fixtures/t1.wav
Error: parakeet motoru 'tr' dilini desteklemiyor (desteklenen: bg, hr, cs, da, nl, en, et, fi…)
```

### Ses yükleme — pencereli ve sınırlı

Bir saatlik 48 kHz stereo kayıt tek Float32 tamponda ~690 MB. `AudioLoader`
kaynak sesi 32768 karelik pencerelerde okuyup dönüştürüyor; bellekte tek pencere
duruyor. `maxSeconds` ile üst sınır var.

**Bulunan hata:** `AVAudioFile.read(into:)` dosya sonunda 0 kare döndürmüyor,
**hata fırlatıyor** — ve Foundation bunu yine `nilError`'a çeviriyor. Döngü
`frameLength == 0` yerine `framePosition < length` ile sürülmeli. Bu hatayı
test paketi yazıldığı gün yakaladı.

Ayrıca dosya varlığı önden kontrol ediliyor: AVAudioFile eksik dosyayı
`Code=2003334207` diye bildiriyor, bu da kullanıcının bilmesi gereken tek şeyi
gömüyor.

### Test paketi

37 test, 5 suite (`swift test`). Kapsam: kapı eşikleri, kalite kararları,
temizleme regex'leri, ses yükleme, hata mesajlarının okunabilirliği.

Düşmanca fixture'lar `fixtures/` altında: tam sessizlik, 100 ms'lik ifade,
eşik altı gürültü. Sağlamlaştırmanın kanıtı bunların uçtan uca elenmesi:

```
$ yaz transcribe --strict fixtures/t1.wav fixtures/silence-3s.wav fixtures/tiny-100ms.wav
═══ t1.wav (5.57 sn) ═══
  gecikme 567 ms · RTF 0.102 · tepe 0.702 · rms 0.151
  noSpeech 0.00 · logProb -0.21 · sıkıştırma 1.07
  Bugün Pilot Projesini inceledim ve On Device Transcription Mimarisini çözdüm.

═══ silence-3s.wav ═══
  ✗ kayıtta ses yok (tepe 0.0000, eşik 0.0050)

═══ tiny-100ms.wav ═══
  ✗ kayıt çok kısa (0.10 sn, en az 0.35 sn gerekli)
```

`sanitize` de sıkılaştırıldı. parrot her `(...)` içeriğini siliyor — bu, dikte
edilen gerçek parantezli ifadeleri de götürüyor. yaz yalnızca bilinen not
sözcüklerini (`sessizlik`, `müzik`, `applause`…) ve 40 karakteri aşmayan
span'ları siliyor; "toplantı (yarın değil, öbür gün) yapılacak" olduğu gibi kalıyor.


## Sağlamlaştırma — ikinci tur

İlk tur girdi ve çıktıyı savundu. İkinci tur kodu kendine karşı savunuyor:
üç gerçek hata bulundu, üçü de kod okunarak.

### Actor reentrancy — modeli iki kez yükleme

```swift
func prepare() async throws {
    guard box.kit == nil else { return }        // ← 1. çağrı buradan geçer
    box.kit = try await WhisperKit(...)         // ← burada askıya alınır
}                                               //   2. çağrı guard'ı geçer!
```

Actor **ifadeleri** serileştirir, askıya alma noktasını aşan **işlemleri**
değil. `await` sırasında ikinci çağrı içeri girip aynı 1.6 GB modeli bir daha
yüklüyordu.

`SingleFlight` bunu tek uçuşa indiriyor. Bekleyenler kazananın sonucunu görür.
Başarısız yükleme **önbelleğe alınmaz** — sebebi genelde geçici bir indirme
hatası, sonraki çağrı yeniden denemeli.

### Sinyal yokluğu ≠ kusursuz sinyal

`Signals` alanlarının hepsi sıfır varsayılanlı. Ama `avgLogProb: 0` = log(1.0) =
**mümkün olan en yüksek güven**, `noSpeechProb: 0` = kesinlikle konuşma. Yani
sıfırlanmış bir `Signals`, "veri yok"u "kusursuz decode" diye raporluyordu.

Parakeet segment başına güven vermiyor ve tam da bunu geçiyordu — sonuç:
**her Parakeet transkripti kalite kapılarından otomatik geçiyordu.**

Artık tip bunu ifade ediyor: `signals: Signals?`. `nil` geçildiğinde yalnızca
metin-temelli kontroller (boş çıktı, tekrar döngüsü) uygulanıyor — bunlar
motordan bağımsız olarak imlece ulaşan hata türleri. CLI de sıfır basmak
yerine durumu söylüyor:

```
  (motor güven sinyali vermiyor — karar yalnızca metne dayanıyor)
```

### İki gerçek veri yarışı

`PipelineBox` `@unchecked Sendable`'dı ama senkronizasyonu yoktu. `box.kit`
actor üzerinde `prepare()`/`release()` tarafından yazılıyor, zaman aşımı
sarmalayıcısının **task-group child task'ından** okunuyordu. Artık `NSLock`
korumalı ve `current()` güçlü referans döndürüyor: eşzamanlı bir `release()`
uçuştaki transkripsiyonun altından pipeline'ı çekemez.

İkincisi daha sinsi: actor `transcribe()`'ı serileştirmiyor. Method `await`'te
askıya alınınca ikinci çağrı içeri girip Core ML pipeline'ına **paralel**
ulaşabiliyordu. WhisperKit reentrancy garantisi vermiyor — bu yavaşlık değil,
tanımsız davranış. `SerialGate` işleri geliş sırasına göre kuyruğa alıyor;
hata veren iş zinciri koparmıyor.

`release()` de artık kuyruğu boşaltmadan ağırlıkları düşürmüyor.

### Ölçüm kapısı ölçülmeye değmemeli

`SpeechGate.level` skaler döngüydü. Bu kapı her ifadede çalışıyor ve uzun bir
dosyada tampon on milyonlarca örnek (bir saat @ 16 kHz = 57.6 M). Çıkarımdan
ucuz olması gereken kontrol, maliyetin kendisi olmamalı — `vDSP_maxmgv` /
`vDSP_rmsqv`'ye geçildi. Skaler referansla birebir eşleştiği test ediliyor.

### Gerçek mikrofon formatları

Gerçek girişler 16 kHz mono değil: dahili mikrofonlar 48 kHz, USB arayüzler
44.1 kHz, kulaklıklar bazen 8 kHz, ve quill'in rca-001'i **dokuz kanallı** bir
route bulmuştu. Fixture'lara stereo 44.1 kHz, mono 48 kHz ve mono 8 kHz
varyantları eklendi.

Test yalnızca süreyi değil **sinyalin hayatta kaldığını** da doğruluyor —
rca-001'in tuzağı tam olarak doğru süreli ama dijital sessiz dosyaydı. Stereo
44.1 kHz girdi, 16 kHz mono ile birebir aynı transkripti veriyor.

### Sayılar

57 test, 10 suite. Yeni kapsam: tek-uçuş yükleme, seri kuyruk, sinyal
yokluğu, vDSP doğruluğu, dört giriş formatı, pencere sınırında kare kaybı.

## Durum

- **M1 — tamam.** Motor katmanı, `Transcriber` protokolü, Whisper + Parakeet
  conformance'ları, `yaz transcribe` ölçüm koşum takımı, sabit Türkçe fixture'lar.
- **M1.5 — tamam.** Sağlamlaştırma turu 1: `SpeechGate`, `TranscriptionQuality`,
  `YazError`, zaman aşımı, dil doğrulaması, pencereli `AudioLoader`.
- **M1.6 — tamam.** Sağlamlaştırma turu 2: actor reentrancy düzeltmesi
  (`SingleFlight`), çıkarım serileştirme (`SerialGate`), veri yarışı kapatma,
  `Signals?` ayrımı, vDSP ölçüm, çok formatlı ses testleri. 57 test.
- **M2** — mikrofon yakalama + yapılandırılabilir kısayol (parrot'ta `--hotkey`
  belgelenmiş ama kodda yok; burada gerçekten olacak).
- **M3** — pano yapıştırma ile metin yerleştirme, CGEvent yedeği.
- **M4** — sözlük katmanı.
- **M5** — FoundationModels ile dolgu temizleme.
- **M6** — `~/.config/yaz/config.json` (parrot config dosyasını hiç göndermedi).
- **M7** — menü barı + kayıt göstergesi, LaunchAgent.

## Ölçüm disiplini

`yaz transcribe` daemon'dan önce yazıldı, bilerek. Her değişiklik (motor sürümü,
sözlük, son işleme) mikrofona o an ne söylendiğine göre değil, `fixtures/`
altındaki sabit seslerle ölçülür. Doğruluk iddiası ancak bu şekilde
karşılaştırılabilir olur.

Fixture'lar macOS `say -v Yelda` ile üretildi — sentetik. Gerçek konuşma
farklılık gösterir; özellikle İngilizce alıntı kelimelerde sentetik ses
Türkçe fonetikle okuduğu için gerçekte biraz daha iyi sonuç beklenebilir.
Hata *türü* yine de gerçek.
