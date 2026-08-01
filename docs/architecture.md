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

## Durum

- **M1 — tamam.** Motor katmanı, `Transcriber` protokolü, Whisper + Parakeet
  conformance'ları, `yaz transcribe` ölçüm koşum takımı, sabit Türkçe fixture'lar.
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
