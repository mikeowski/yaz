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


## M2 + M3 — dikte döngüsü kapandı

Motor katmanı iki tur sağlamlaştırmadan sonra üstüne inşa edilecek kadar
sağlam. Bu tur döngüyü kapatıyor: kısayol → mikrofon → çeviri → imleç.

### Yapılandırılabilir kısayol

parrot README'sinde `--hotkey right-option` yazıyor ama böyle bir bayrak yok
ve monitor Fn'e sabit. yaz'da `Hotkey` gerçek bir tip: fn, sağ option, sağ
command, sağ control, sağ shift.

Sağ/sol ayrımı maske ile yapılamıyor — `.maskAlternate` iki option tuşunda da
yanıyor. Bu yüzden `Hotkey.keyCode` var ve olay keycode'u ile doğrulanıyor.
Fn'in ayrı keycode'u yok, orada maske yeterli.

**Kendi kendini onaran tap.** macOS uzun süren veya bloke eden tap'leri
kapatıyor. parrot'un cevabı bir yorum satırı: *"we'll need to re-enable. For
now just no-op and let the user restart parrot."* Gün boyu açık duran bir
daemon için bu sessiz ölüm demek. yaz `tapDisabledByTimeout` /
`tapDisabledByUserInput` olaylarında tap'i yeniden açıyor.

### Pano ile yerleştirme — parrot'un asıl zayıf noktası

parrot `CGEventKeyboardSetUnicodeString` ile yazıyor; API olay başına ~20
UTF-16 birimi kabul ettiği için bir cümle onlarca sentetik tuş olayına
bölünüyor. İki sonuç, ikisi de dikte aracının en çok kullanıldığı yerde:
Electran uygulamaları (Slack, Notion, Cursor) böyle patlamalardan karakter
düşürüyor, ve süre söylediğin şeyin uzunluğuyla büyüyor.

yaz panoya yazıp ⌘V gönderiyor: tek olay, uzunluk sınırı yok, hedef uygulama
sıradan bir yapıştırma görüyor. Panonun eski içeriği **tüm tipleriyle**
(`NSPasteboardItem` bazında) kaydedilip 0.25 sn sonra geri konuyor — sadece
metin değil, görsel ve dosya da. Dikte sonrası panosunu kaybetmek, diktenin
başarısız olmasından kötü.

⌘V olayları `privateState` kaynağıyla ve açıkça `.maskCommand` ile
gönderiliyor: kullanıcı hâlâ push-to-talk tuşunu basılı tutuyor olabilir, o
modifier yapıştırmayı başka bir kısayola çevirmemeli.

Tuş tuş yazma `--inject-mode type` ile duruyor. Orada da bir düzeltme var:
parrot UTF-16 dizisini körlemesine kesiyor, bu birleşik karakterlerin
ortasından bölebiliyor. yaz grafem kümesi sınırlarında bölüyor — Türkçe metin
ve emoji bunlarla dolu.

### Mikrofon — voice processing bilerek kapalı

`AudioCapture`, `AVAudioEngine` tap'i kuruyor ve cihazın kendi formatında
dinleyip callback içinde 16 kHz mono'ya çeviriyor. Donanımın üretmediği bir
formatı tap'ten istemek, boş dosyaya giden yol.

Voice processing **açılmıyor**. rca-001'in bedeli belli: duplex I/O unit'i
yanlış kurmak doğru süreli ama dijital sessiz kayıt üretiyor, hiçbir yerde
hata yok. Tek faydası echo cancellation ve bas-konuş diktesinde iptal edilecek
bir echo yok.

Liveness kontrolü yine de kaldı, çünkü asıl arıza voice processing'e özgü
değil: bir cihaz sıfır dolu callback'ler gönderebiliyor. `didSeeSignal`
"sessiz kaldın" ile "mikrofon ölü" arasını ayırıyor.

**Üst sınır.** Takılı kalan bir modifier tuşu tamponu makine takas edene kadar
büyütür — 16 kHz mono Float32 dakikada 3.7 MB. On dakikada kesiliyor.

### Sıralama — ucuz hatalar önce

İlk yazımda `run` önce 1.6 GB modeli yüklüyor, sonra kısayolu kuruyordu.
Erişilebilirlik izni yoksa kullanıcı 7 saniye bekleyip izin hatası alıyordu.
Artık tap önce kuruluyor: **0.54 sn**'de başarısız oluyor.

Tap yükleme bitmeden var olduğu için `ready` bayrağı eklendi; henüz model
yokken gelen basış sessizce yutulmuyor, durum söyleniyor.

### Config dosyası

parrot'un mimari dokümanı `~/.config/parrot/config.toml` anlatıyor; kaynakta
`Config` diye bir tip **yok**, dosya hiç okunmuyor. LaunchAgent ile başlatılan
bir daemon yalnızca plist düzenlenerek yeniden yapılandırılabiliyor.

yaz `~/.config/yaz/config.json` okuyor. Tanınmayan bir *değer* stderr'e
yazılıyor — sessizce varsayılana düşmek kullanıcıyı "kısayolum neden
değişmedi" sorusuyla baş başa bırakır.

### doctor

İzin, model bütünlüğü, yerleştirme modu ve Fn tuşu ayarı tek yerde. Her
başarısız kontrol ne yapılacağını söylüyor. Erişilebilirlik satırı **ebeveyn
süreci adlandırıyor** — macOS izni binary'ye değil onu başlatana verir, bu da
eyleme geçirilebilir mesaj ile bilmece arasındaki fark.

Model kontrolü artık bütünlük bakıyor: klasörün varlığı yarım indirmeyi tam
sayıyordu ve hata dakikalar sonra Core ML yükleme hatası olarak çıkıyordu.
`ModelStore` her bileşeni ve boyutunu doğruluyor.


## M4 — sözlük katmanı

Projenin varlık sebebi olan doğruluk problemi. Ölçüm baştan beri buydu:

```
girdi : "Ahmet'e Slack üzerinden yaz, pull request'i merge et, CI pipeline yeşile dönsün"
çıktı : "Ahmet'e Sılacık üzerinden yaz, Puhrıkı Esti'de merge et, C.I.P. eline yeşile dönsün"
```

Düz Türkçe iyi; çöken şey İngilizce teknik terimler — yani bir yazılımcının
dikte ettiği her cümlenin yarısı.

### Neden ASR seviyesinde değil

İki standart yol denendi, ikisi de bu yığında çalışmadı:

1. **Whisper initial-prompt biasing** (`DecodingOptions.promptTokens`) —
   `large-v3-turbo` üzerinde denenen her varyantta **boş çıktı**.
2. **LLM'e sözlüğü verip düzelttirme** — Apple FoundationModels'a hedef terim
   listesi verildi, `Sılacık` yine düzelmedi. 1.40 sn harcandı.

Dolayısıyla düzeltme kural tabanlı. Bunun bir yan faydası var: motor yalnızca
kullanıcının kendi listesine koyduğu kelimeleri üretebilir, uydurma yapamaz.

### Ünsüz iskeleti

Türkçe fonotaktiği ünsüz kümelerini sevmez; konuşmacı da akustik model de
araya ünlü sokar: `sl` → `sıl`. Yani **ünlüler sinyalin en güvenilmez, ünsüzler
en güvenilir kısmı.**

```
Slack        → slk    ·  Sılacık      → slkk
pull request → plrkst ·  Puhrıkı Esti → phrkst
CI pipeline  → sppln  ·  C.I.P. eline → spln
```

Normalizasyon Türkçe I/İ katlaması, aksan katlaması ve İngilizce grafemlerin
(`ck`, `ph`, `qu`, `x`) Türkçe karşılıklarına çevrilmesini içeriyor.

**İngilizce C kuralı** ayrı bir kazanç: İngilizce `c`, arka ünlü ve ünsüzden
önce /k/, ön ünlüden önce /s/. `Cursor` → `kursor` → iskelet `krsr`; duyulan
`Körsır` → `krsr`. **Tam eşleşme (1.000).** Bu kural olmadan c/k farkı iki
kelimeyi alakasız gösteriyordu.

Sıralama önemli: aksan katlaması C kuralından **sonra** çalışıyor. Önce
çalışsaydı Türkçe `ç` (kendi başına bir ses) `c`'ye düşüp `k`'ye çevrilir ve
"saç" kelimesi "Slack"e benzemeye başlardı — bu tam olarak yaşandı ve
düzeltildi.

### Oran eşiği neden yetmiyor

Ölçüm bunu tartışmasız gösterdi. İskelet olarak karşılaştırıldığında:

```
Slack  (slk)  vs  Sılacık (slkk)  → 0.75   ← değişmeli
Docker (dkr)  vs  Doktor  (dktr)  → 0.75   ← ASLA değişmemeli
Sentry (sntr) vs  sonra   (snr)   → 0.75   ← ASLA değişmemeli
```

**Aynı puan, zıt beklenti.** Hiçbir eşik bunları ayıramaz. Ayıran şey şu:
`doktor` ve `sonra` konuşmacının açıkça söylediği sıradan Türkçe kelimeler;
`Sılacık` ise hiçbir dilde kelime değil — yalnızca akustik modelin İngilizce
ünsüz kümesini ünlüyle kırmasından doğdu.

Üç savunma birlikte çalışıyor:

1. **Türkçe yaygın kelime vetosu** (`TurkishLexicon`) — pencerede sıradan bir
   Türkçe kelime varsa yalnızca 0.90+ tam-form kanıtıyla değiştirilebilir,
   iskelet tahminiyle asla. ~450 kelime, ek soyma ile çekimli hâlleri de
   yakalıyor.
2. **Baş ünsüz kısıtı** — ünlü türemesi araya ünlü sokar ama kelimenin neyle
   başladığını değiştirmez. `Redis (rds)` / `neredeyse (nrds)` 0.75 alıyordu;
   `r ≠ n` olduğu için reddediliyor.
3. **Pencere genişletme sınırı** — tek kelimelik kısa terim iki kelimelik
   pencereye eşleşemez. Bu kural olmadan "ama kargo" → "merge" oluyordu ve
   "merge et" içindeki "et" yutuluyordu.

### Türkçe ek koruması

Türkçe özel isimlere ekleri kesme işaretiyle bağlar. `Sılacık'ten` düzeltilip
`'ten` düşürülürse cümle bozulur. `Tokenizer` her kelimeyi baştaki noktalama /
gövde / kesme-eki / sondaki noktalama olarak ayırıyor ve yalnızca gövdeyi
değiştiriyor. Tipografik kesme işareti (`’`) de tanınıyor — Whisper bunu
üretiyor.

Çok kelimeli terimde ek son kelimede kalıyor: `Puhrıkı Esti'de` →
`pull request'de`.

### Ölçülen sonuç

Gerçek ses dosyası üzerinde uçtan uca:

```
$ yaz transcribe --vocabulary fixtures/t2.wav
  sözlük: Sılacık → Slack (0.749, skeleton)
  sözlük: Puhrıkı Esti'de → pull request'de (0.832, skeleton)
  sözlük: C.I.P. eline → CI pipeline (0.799, skeleton)
  Yarın saat 14'te toplantı var. Ahmet'e Slack üzerinden mesaj atmayı unutma.
  pull request'de merge etmem lazım. CI pipeline yeşile döndüğünde deploy ederiz.
```

Üç bozulmanın üçü de düzeldi, Türkçe eki korundu, Türkçe metne dokunulmadı.

### Yanlış eşleşme testi

Asıl risk kullanıcının gerçekten söylediği bir kelimeyi değiştirmek: bozuk
terim görünür kalır, yanlış değiştirme görünmez. 30 cümlelik sıradan Türkçe
korpus var (teknik terim içermeyen günlük cümleler) ve iki sözlükle
sınanıyor — biri gerçek geliştirici terimleri, diğeri kasıtlı olarak Türkçeye
benzeyen terimler (`Docker`, `Redis`, `Vercel`, `Sentry`, `Linear`, `Figma`).
Sıfır yanlış eşleşme.

Bu korpus eşikleri belirledi: 0.74 iskelet eşiği ilk denemede beş yanlış
eşleşme üretti, tam-form eşiği 0.72 iken "Saç" → "Slack" oldu.

### Ayar araçları

Eşikler tahminle değil gerçek bozuk çıktıyla ayarlanır, o yüzden bunlar CLI'da:

```
yaz vocab test "Sılacık'ten yazdım"     # düzelt ve puanları göster
yaz vocab explain "Cursor" "Körsır"      # fonetik anahtarları karşılaştır
```

### Bilinen sınır

Vetonun gücü sözlük kapsamına bağlı. `TurkishLexicon` bir sözlük değil, sık
kullanılan kelimeler listesi; listede olmayan nadir bir Türkçe kelime, ona
fonetik olarak yakın bir terimle çakışırsa yanlış değiştirilebilir. Kullanıcı
tarafındaki çare `min_similarity` ile terim başına eşiği yükseltmek.


## M5 — son işleme katmanı

Dikte çıktısı ham gelir: kekelemeler, tereddüt sesleri, noktalama yok. parrot
bunu tasarım gereği reddediyor ("No AI post-processing"). yaz iki kademede
yapıyor, çünkü işin bir kısmı risksiz, bir kısmı değil.

### Kademe 1 — deterministik, ~1 ms

`FillerFilter` yalnızca **hiçbir dilde kelime olmayan** sesleri atıyor: `ııı`,
`eee`, `mmm`, `hmm`. Kapsam bilerek dar. Türkçede `yani`, `şey`, `hani`,
`işte`, `falan` bağlama göre gerçek kelimeler; kör bir "dolgu kelime listesi"
bunları silerse kullanıcının söylediğini değiştirir.

Tek harfli sesliler ayrı bir tuzak: `o` zamir, `a` bağlaç. Bunlar yalnızca
başka bir tereddüdün yanındayken (`ı ı yarın`) atılıyor.

Bu kademe varsayılan. Bedava, modelsiz, anlamı değiştiremez.

### Kademe 2 — dil modeli, opsiyonel

Bağlama bağlı dolgu kelimeler, noktalama ve cümle sınırları için Apple
FoundationModels. macOS 26 ile geliyor — indirme yok, ikinci çalışma zamanı
yok; on-device transkripsiyonu değerli kılan argümanın aynısı.

```
girdi : ıı yarın şey saat ikide yani toplantımız var hani o proje için ee hazırlık yapmamız lazım
çıktı : Yarın saat ikide toplantımız var. O proje için hazırlık yapmamız lazım.
```

**Ölçülen maliyet:** M4 Pro'da 0.3–1.4 sn (uzunluğa göre), motorun zaten
harcadığı 0.5–0.9 sn'nin üstüne. Bu yüzden opt-in.

### Korumalar — model çıktısı hak ederek girer

Bir dil modeline "temizle" demek, onun özetleyebileceği, çevirebileceği, soruyu
cevaplayabileceği veya reddedebileceği anlamına gelir. Bunlardan biri
kullanıcının imlecine giderse, temizlemeye çalıştığımız kekelemeden kötü olur.

`RefinementGuard` reddediyor:

| Kontrol | Yakaladığı |
|---|---|
| Uzunluk oranı < 0.55 | özetleme |
| Uzunluk oranı > 1.25 | model ekleme yapmış / soruyu cevaplamış |
| İçerik kelimesi tutulumu < 0.75 | cümle parçası düşmüş, çatı değişmiş |
| Boş çıktı | model reddetmiş |

Ayrıca sohbet modellerinin sevdiği sarmalayıcılar soyuluyor: `"İşte
düzeltilmiş metin:"` başlığı ve çevreleyen tırnaklar.

**Her başarısızlık yumuşak.** Hata, zaman aşımı veya red durumunda deterministik
sonuca dönülüyor. Bir temizlik adımı yüzünden dikte kaybolamaz.

### Korumanın kendi hatası

İlk sürüm iyi bir temizliği çöpe attı. Model `yani` ve `hani` kelimelerini
doğru biçimde atmıştı; tutulum kontrolü bunları 4+ harfli "içerik kelimesi"
sayıp %30 kayıp raporladı.

Yani koruma, modelden **istediğimiz** davranışı cezalandırıyordu. Bağlamsal
dolgu kelimeleri tutulum hesabından çıkarıldı. Gerçek içerik kaybı hâlâ
yakalanıyor — ikisi de test edilmiş durumda.

### Sıralama: sözlük önce, son işleme sonra

`TranscriptPipeline` sırayı bir karar olarak sabitliyor.

Sözlük **önce** çalışıyor ki model doğru yazılmış terimleri görsün: `Sılacık`
verilen bir dil modeli onu makul görünen başka bir şeyle değiştirebilir ve o
noktadan sonra deterministik katman onu tanıyamaz. `Slack` verilince
düzeltecek bir şey bulmaz.

Ters risk de kapalı: son işlemeden sonra, sözlüğün onardığı her terimin hâlâ
metinde olduğu doğrulanıyor. Biri düştüyse temizlik atılıyor. Deterministik
katman her iki yönde de kazanıyor.

Ölçülen tam zincir:

```
$ yaz transcribe --vocabulary --refine llm fixtures/t2.wav
  gecikme 907 ms · RTF 0.075
  sözlük: Sılacık → Slack (0.749, skeleton)
  sözlük: Puhrıkı Esti'de → pull request'de (0.832, skeleton)
  sözlük: C.I.P. eline → CI pipeline (0.799, skeleton)
  son işleme 1310 ms
  Yarın saat 14'te toplantı var. Ahmet'e Slack üzerinden mesaj atmayı unutma.
  Pull request'de merge etmem lazım. CI pipeline yeşile döndüğünde deploy ederiz.
```

Model cümle başındaki `pull` kelimesini büyüttü — meşru bir düzeltme, ve terim
doğrulaması bunu (normalize ederek karşılaştırdığı için) kayıp saymadı.

### Ayar aracı

```
yaz vocab refine --mode llm "ıı yarın şey toplantı var"
```


## M6 — kayıt göstergesi ve menü barı

Bas-konuş'un tek dürüst arıza biçimi şu: tuşu basılı tutuyorsun, konuşuyorsun,
ama kimse dinlemiyormuş. Geri bildirim olmadan bunu ancak metin gelmeyince
anlarsın. Gösterge bu sorunun tamamının cevabı.

### Test edilebilir çekirdek ayrı

`LevelMeter` ve `IndicatorState` içinde hiç AppKit yok. İlginç kısım —
ham tepe değerinin çubuk yüksekliğine dönüşmesi — pencere sunucusu
başlatmadan sınanabilecek bir aritmetik.

Konuşma tepe değerleri dahili mikrofonda kabaca 0.05–0.7. Doğrusal çizilirse
ölü bir çizgi çıkıyor, o yüzden `sqrt` ile sıkıştırılıp 3.4 kazançla
ölçekleniyor: bağırınca metre tavana yapışıp düzleşmiyor, sessiz cümle
görünür kalıyor.

Sonlu olmayan bir değer **tabanda** kalıyor, tavanda değil. `NaN` veya
`infinity` buraya geldiyse okuma bozuk demektir, oda gürültülü demek değil —
tavana yapışmış bir metre, düz olandan daha kendinden emin bir yalan olur.

`showsWaveform` yalnızca `.recording` durumunda doğru. Kayıt bittikten sonra
oynayan bir dalga formu yalan söyler: o noktada ses çoktan yakalanmıştır.

### Pil — tıklamayı geçiren panel

Borderless, `nonactivatingPanel` bir `NSPanel`. Üç ayar taşıyıcı:

- `ignoresMouseEvents` — tıklamalar altındaki uygulamaya geçiyor.
- `orderFrontRegardless`, `makeKeyAndOrderFront` değil — panel dikte edilen
  alandan **asla** key durumunu almamalı. Alsaydı ürünün kendisi bozulurdu,
  çünkü metin imlecin bulunduğu yere yapıştırılıyor.
- `canJoinAllSpaces` + `fullScreenAuxiliary` — tam ekran uygulamada da görünür.

Konum, farenin bulunduğu ekranın alt ortası: çok monitörlü masada pil
kullanıcıyı takip ediyor, dizüstünde kalmıyor.

### Menü barı

yaz dock ikonu ve penceresi olmayan bir `.accessory` süreç. Terminalden
çalıştırıldığında log yeterli; **login'de başlayan bir LaunchAgent için
değil** — kullanıcının daemon'ın orada olduğunu görecek ve onu kapatacak bir
yolu olmalı.

SF Symbols kullanılıyor, ama çizilmiş bir yedek var: yüklenemeyen bir görsel
sıfır genişlikte bir status item bırakır, bu da tam olarak "daemon başlamadı"
gibi görünür.

### UI kodu derlenmekle kalmadı, çalıştırıldı

Overlay ve menü barı testten erişilemeyen tek parça: run loop, ekran ve
daemon üzerinden erişilebilirlik izni istiyorlar. `yaz preview` bunları
doğrudan sürüyor — mikrofon ve kısayol olmadan, durumlar arasında gezerek ve
dalga formunu gerçekçi değerlerle besleyerek.

```
$ yaz preview
gösterge önizlemesi — ekranın altına bak, menü barını kontrol et
  dinliyor
  çeviriyor
  düzeltiyor
önizleme bitti
```

Böylece AppKit/SwiftUI yolu "derleniyor" seviyesinden "çalışıyor" seviyesine
çıkıyor.

### Config

`overlay` ve `menu_bar` ayrı ayrı kapatılabiliyor. Ön planda terminal
çalıştırması için ikisi de gereksiz olabilir; log zaten her şeyi söylüyor.


## M7 — kurulum ve girişte başlatma

### Gömülü Info.plist — parrot'un eksiği

yaz `.app` paketi olmayan tek bir ikili. TCC'nin mikrofon istemini **yaz'a**
atfetmesinin ve kullanıcı için yazılmış bir açıklama metni göstermesinin tek
yolu, plist'i ikilinin `__TEXT,__info_plist` bölümüne linker ile gömmek.

quill bunu yapıyor, parrot yapmıyor — ve parrot'un kendi dokümanı kod
imzalamayı "açık soru" olarak bırakmış durumda. launchd altında bu fark, izin
isteminin kime ait olduğu demek.

Doğrulandı:

```
$ launchctl plist __TEXT,__info_plist .build/release/yaz
{
    "CFBundleIdentifier" = "com.mikeowski.yaz";
    "NSMicrophoneUsageDescription" = "yaz, kısayola basılı tuttuğunuz sürece...";
    "LSBackgroundOnly" = true;
};
```

`CFBundleIdentifier` ile LaunchAgent etiketi kasıtlı olarak aynı: launchd işi
ve TCC kimliği aynı şeye işaret etmeli. Test bunu doğruluyor.

### launchd iş tanımı

`SMAppService` değil — o gerçek bir `.app` paketi istiyor, yaz ise
`/usr/local/bin` altında tek bir ikili. Düz bir launchd plist'i bunun dürüst
karşılığı.

Plist üretimi dosya sistemi ve `launchctl` çağrılarından ayrı tutuldu, çünkü
**girişte başlamayan bir daemon kullanıcıya hata ayıklayacak hiçbir şey
vermiyor.** İki karar test edilmiş durumda:

- `KeepAlive` yalnızca **başarısız** çıkışta yeniden başlatıyor. Menü barından
  "Çık" temiz bir çıkış ve kapalı kalmalı; koşulsuz `KeepAlive` o menü öğesini
  yalancı yapardı.
- `EnvironmentVariables.PATH` tanımlı. launchd giriş ajanlarına çıplak bir
  ortam veriyor; PATH olmadan `on_transcript` kancası hiçbir komutu bulamaz.

### Bayat kayıt — sessiz arızanın kaynağı

En kötü senaryo: plist duruyor ama ikili taşınmış. launchd denemeye devam
eder, kullanıcı hiçbir şey görmez. `LaunchAgent.status()` bunu ayrı bir durum
olarak raporluyor ve `doctor` sert hata veriyor.

Gerçekten denendi: ikili geçici olarak gizlendi, `doctor` doğru şekilde
`✗ kayıtlı ikili dosya yok` dedi.

### launchd altında çalıştırınca çıkan iki gerçek hata

Bu ikisi kodu okuyarak değil, LaunchAgent'ı gerçekten kurup log'a bakarak
bulundu.

**1. Bölünmüş çıktı.** Bir LaunchAgent'ın stdout ve stderr'i *farklı
dosyalara* gidiyor. Başlangıç hatası stderr'e "kontroller başarısız" yazıp
sebepleri stdout'a listeleyince, kullanıcı `/tmp/yaz.err.log` dosyasında
altı boş bir başlıkla kalıyordu. `DoctorReport.render` artık hedef akışı
parametre alıyor.

**2. "launchd etkinleştir".** Erişilebilirlik mesajı ebeveyn süreci
adlandırıyor — kabuktan çalışınca doğru davranış, çünkü macOS izni terminale
atfediyor. launchd altında ebeveyn `launchd` ve kullanıcıya "launchd'ı
etkinleştir" demek işe yaramaz olmanın ötesinde yanlış: orada izin, gömülü
Info.plist sayesinde kendi kimliği olan yaz'a ait. `accessibilityOwner`
ayrıştırıldı ve test edildi.

### Kurulum betiği

`curl | sh` **değil**, bilerek: bu betik sudo istiyor ve TCC izinleri talep
eden bir daemon kuruyor, okunmadan çalıştırılmamalı.

Ön koşullar sert: macOS, arm64, macOS 26+. Whisper ve Parakeet ANE üzerinde
çalışıyor; Intel'de model yüklense bile kullanılabilir gecikme alınamaz.

sudo yalnızca gerçekten gerekliyse isteniyor. İlk sürüm `~/bin` gibi bir
hedefe kurarken de parola soruyordu, çünkü henüz var olmayan bir dizini
"yazılamaz" sayıyordu — dizin yoksa karar ebeveyninin yazılabilirliğine bağlı.
Aynı hata kaldırma yolunda da vardı, ikisi de ortak bir `writable` yardımcısına
bağlandı.

Ad-hoc imza atılıyor (`codesign -s -`). Bu bir dağıtım imzası değil; imzasız
bir ikilinin her derlemede TCC kimliğini kaybetmesini bir nebze yavaşlatıyor.
Gerçek çözüm Developer ID ile imzalamak — bu proje için açık bir konu.

### Doğrulama

Kurulum ve kaldırma gerçekten çalıştırıldı, makinede net etki sıfır:

- `yaz install --launch-at-login` → plist yazıldı, `launchctl print` işi
  `state = running` olarak gösterdi
- daemon launchd altında doğru şekilde erişilebilirlik hatası verdi
- ikili gizlendi → `doctor` bayat kaydı yakaladı
- `yaz install --uninstall` → plist silindi, launchd artık tanımıyor
- `scripts/install.sh` izole bir `PREFIX` ile derledi, kurdu, imzaladı,
  `doctor` çalıştırdı; `--uninstall` temiz kaldırdı

## Durum

- **M1 — tamam.** Motor katmanı, `Transcriber` protokolü, Whisper + Parakeet
  conformance'ları, `yaz transcribe` ölçüm koşum takımı, sabit Türkçe fixture'lar.
- **M1.5 — tamam.** Sağlamlaştırma turu 1: `SpeechGate`, `TranscriptionQuality`,
  `YazError`, zaman aşımı, dil doğrulaması, pencereli `AudioLoader`.
- **M1.6 — tamam.** Sağlamlaştırma turu 2: actor reentrancy düzeltmesi
  (`SingleFlight`), çıkarım serileştirme (`SerialGate`), veri yarışı kapatma,
  `Signals?` ayrımı, vDSP ölçüm, çok formatlı ses testleri. 57 test.
- **M2 — tamam.** `AudioCapture`, yapılandırılabilir `Hotkey`, kendi kendini
  onaran event tap.
- **M3 — tamam.** Pano ile yerleştirme (+ grafem güvenli yazma yedeği),
  `Config`, `doctor`, `models`, `Daemon`. 87 test.
- **M4 — tamam.** Sözlük katmanı: fonetik iskelet eşleştirme, Türkçe kelime
  vetosu, ek koruması, `vocab test`/`vocab explain`. 126 test.
- **M5 — tamam.** Son işleme: `FillerFilter` (deterministik),
  `Refiner` + FoundationModels (opsiyonel), `RefinementGuard`,
  `TranscriptPipeline`. 156 test.
- **M6 — tamam.** `LevelMeter`, `IndicatorState`, tıklama geçiren overlay
  pili, `MenuBarController`, `yaz preview`. 176 test.
- **M7 — tamam.** Gömülü Info.plist, `LaunchAgent`, `yaz install`,
  `scripts/install.sh`. 197 test.

Planlanan yol tamamlandı. Kalan tek eksik canlı dikte turu: mikrofon ve
erişilebilirlik izinleri kullanıcı onayı gerektiriyor.

## Ölçüm disiplini

`yaz transcribe` daemon'dan önce yazıldı, bilerek. Her değişiklik (motor sürümü,
sözlük, son işleme) mikrofona o an ne söylendiğine göre değil, `fixtures/`
altındaki sabit seslerle ölçülür. Doğruluk iddiası ancak bu şekilde
karşılaştırılabilir olur.

Fixture'lar macOS `say -v Yelda` ile üretildi — sentetik. Gerçek konuşma
farklılık gösterir; özellikle İngilizce alıntı kelimelerde sentetik ses
Türkçe fonetikle okuduğu için gerçekte biraz daha iyi sonuç beklenebilir.
Hata *türü* yine de gerçek.
