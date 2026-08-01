# yaz

Türkçe konuşan geliştiriciler için on-device dikte. Bas-konuş, bırak, metin
imlece gelir. Ses makineden çıkmaz.

[parrot](https://github.com/digimata/parrot)'un iskeleti üzerine kurulu, ama
onun bilerek reddettiği üç şeyi hedefliyor: **çok dilli varsayılan**,
**güvenilir metin yerleştirme**, **son işleme**.

**Gerekiyor:** macOS 26+, Apple Silicon.



## Permissions — there are two, and a third thing that isn't one

**Accessibility** lets yaz paste text at your cursor.
**Input Monitoring** lets yaz *see* the push-to-talk key. Different list, same
Settings pane. Granting only the first produces a tap that installs cleanly
and never fires — measured here as: permission granted, tap created, zero
events, no error anywhere.

Then there is the **fn key itself**. macOS claims the globe key as soon as a
second keyboard layout exists or Dictation is on, and consumes the press
before any app sees it. Two ways out:

```
System Settings → Keyboard → "Press 🌐 key to" → Do Nothing
```

or click **"⚠︎ fn is claimed by macOS — use right option"** in the menu bar,
which switches the hotkey and saves it.

`yaz doctor` reports all three, and the app writes the same to
`~/Library/Logs/yaz.log`:

```sh
yaz doctor
yaz logs --follow
```

## Models — downloaded, not bundled

`yaz.app` is 14 MB; `whisper large-v3-turbo` is 1.6 GB. Bundling the weights
would make the app a hundred times larger and pin every user to one
checkpoint, so the first run fetches them.

It fetches them **automatically, with progress**. The menu bar shows
`downloading — 412 MB of 1.6 GB (26%)` while it works; nothing has to be run
by hand. To get it over with before you need it:

```sh
yaz models download          # fetch and compile ahead of time
yaz models list              # what is on disk
```

Weights land in `~/Documents/huggingface` (WhisperKit's choice, not ours). If
iCloud Documents sync is on, they will be uploaded — `yaz doctor` says so.

## Accessibility permission — grant it once

macOS attributes an Accessibility grant to the **code signing identity**. An
ad-hoc signature has no identity beyond the binary's own hash, so every
rebuild invalidates the permission you granted — the "I allowed it and it
still asks" symptom.

`scripts/bundle.sh` signs with a stable self-signed certificate, created once:

```sh
./scripts/signing-identity.sh    # one-time; asks for your login password
```

After that the designated requirement stays identical across rebuilds and the
grant sticks. It is not a Developer ID — Gatekeeper still treats the app as
unidentified on someone else's Mac — but it is the difference between granting
permission once and granting it every time.

## Durum

**Uçtan uca çalışıyor.** Bas-konuş → çeviri → terim düzeltme → temizlik → imlece yapıştırma. 221 test.

**Uygulama olarak (önerilen):**

```sh
./scripts/bundle.sh --dmg         # dist/yaz-0.1.0.dmg üretir
```

DMG'yi aç, `yaz.app`'i Applications'a sürükle, çalıştır. Menü barında yaşar.

Uygulama olarak kurmak izin sorununu da çözüyor: macOS erişilebilirlik iznini
*sorumlu sürece* atfeder ve terminalden çalıştırılan bir CLI'da bu terminaldir
— izin penceresi "cmux.app" ya da "Terminal" diye sorar, verdiğin izin de
zaten açık olan kabuklara işlemez. `.app` olarak yaz'ın kendi kimliği olur:
pencere "yaz" der ve izin kalıcıdır.

**CLI olarak:**

```sh
./scripts/install.sh              # derle + /usr/local/bin altına kur
./scripts/install.sh --login      # ayrıca girişte başlat
./scripts/install.sh --uninstall  # kaldır

yaz doctor --request              # erişilebilirlik iznini iste
yaz models download               # modeli önden indir (~1.6 GB)
yaz                               # daemon'ı başlat, fn'e basılı tutup konuş
```

Betik `curl | sh` için değil, bilerek: sudo istiyor ve TCC izinleri talep eden
bir daemon kuruyor. Önce oku.

`yaz doctor` her şeyi tek yerde söyler:

```
motor: whisper · dil: tr · kısayol: fn (🌐)

! mikrofon: henüz istenmedi — ilk kayıtta sorulacak
✗ erişilebilirlik: verilmemiş
    → Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik → zsh etkinleştir
✓ model: large-v3-turbo · 1,64 GB
✓ metin yerleştirme: pano (⌘V)
```

Kalite kapıları devrede: çok kısa, sessiz veya halüsinasyon çıktısı imlece
gitmeden eleniyor.

**Terim düzeltme.** Whisper Türkçe konuşmadaki İngilizce terimleri fonetik
olarak bozuyor; sözlük katmanı bunları geri getiriyor ve Türkçe eki koruyor:

```
$ yaz transcribe --vocabulary fixtures/t2.wav
  sözlük: Sılacık → Slack (0.749, skeleton)
  sözlük: Puhrıkı Esti'de → pull request'de (0.832, skeleton)
  sözlük: C.I.P. eline → CI pipeline (0.799, skeleton)
  Yarın saat 14'te toplantı var. Ahmet'e Slack üzerinden mesaj atmayı unutma.
  pull request'de merge etmem lazım. CI pipeline yeşile döndüğünde deploy ederiz.
```

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

Daemon, kısayol ve metin yerleştirme henüz yok — sıradaki adımlar
[docs/architecture.md](docs/architecture.md) sonundaki durum listesinde.

## CLI

```sh
yaz                                    # daemon (varsayılan)
  --hotkey fn|right-option|right-command|right-control|right-shift
  --inject-mode paste|type
  --language tr
  --verbose

yaz vocab test "<metin>"               # sözlük düzeltmesini dene, puanları gör
yaz vocab refine --mode llm "<metin>"  # son işlemeyi dene
yaz vocab explain "<terim>" "<duyulan>"  # fonetik anahtarları karşılaştır

yaz settings                           # ayarlar penceresi
yaz settings --history                 # geçmiş penceresi
yaz history [--search <söz>] [--json]  # geçmişi terminalden oku
yaz install --launch-at-login          # girişte başlat
yaz install --uninstall
yaz install --status
yaz preview                            # kayıt göstergesini dene (mikrofon gerekmez)
yaz doctor [--request]                 # izinler, model, ayarlar
yaz models list
yaz models download [--force]

yaz transcribe <dosya...>              # ses → metin, gecikme ölçümüyle
  --engine-name whisper|parakeet       # varsayılan whisper (Türkçe destekleyen tek motor)
  --whisper-model large-v3-turbo|large-v3
  --language tr
  --repeat-count 3                     # ölçüm için tekrar
  --max-seconds 3600                   # bundan uzun dosyaları reddet
  --strict                             # kalite kapılarını uygula
```

Desteklenmeyen motor/dil çifti model indirilmeden reddedilir:

```
$ yaz transcribe --engine-name parakeet --language tr fixtures/t1.wav
Error: parakeet motoru 'tr' dilini desteklemiyor (desteklenen: bg, hr, cs, da, nl, en, et, fi…)
```

## Geçmiş

Ne dikte ettiğin, **hangi uygulamaya** yazıldığı, ne zaman ve ne kadar
sürdüğü kaydediliyor — `~/Library/Application Support/yaz/history.jsonl`.

**Ses saklanmıyor**, yalnızca metin. Kayıtları tutmak yaz'ı kazara bir
gözetim aracına çevirirdi.

```sh
yaz history                    # son 20 kayıt
yaz history --search slack     # metinde veya uygulama adında ara
yaz history --clear
```

Menü barı → Geçmiş… ile pencereden de görülebiliyor (arama + panoya kopyala).
Kapatmak için config'de `"history": false`.

## Ayarlar

Menü barı → Ayarlar… ya da `yaz settings`. Kısayol, model, dil, yerleştirme
ve son işleme modu, sözlük düzenleyici hep orada.

Pencere aynı `~/.config/yaz/config.json` dosyasını yazıyor — dosya kaynak
olmaya devam ediyor, arayüz onu düzenlemenin bir yolu.

## Gösterge

Kayıt sırasında ekranın altında küçük bir pil beliriyor — canlı dalga formu,
sonra çeviri ve düzeltme durumları. Tıklamaları geçirir, odağı çalmaz (metin
imlecin olduğu yere yapıştırılacağı için bu şart). Menü barında da bir durum
öğesi var.

Nasıl göründüğünü mikrofon olmadan görmek için:

```sh
yaz preview
```

İkisi de config'den kapatılabilir (`"overlay": false`, `"menu_bar": false`).

## Son işleme

İki kademe. Deterministik olan varsayılan ve bedava:

```
$ yaz vocab refine --mode fillers "ıı yarın ee saat ikide mmm toplantımız var"
sonra: yarın saat ikide toplantımız var        (1 ms)
```

Dil modeli (Apple FoundationModels, macOS 26 ile hazır gelir) bağlamsal dolgu
kelimelerini ve noktalamayı da hallediyor — ama ifade başına 0.3–1.4 sn ekliyor,
o yüzden opt-in:

```
$ yaz vocab refine --mode llm "ıı yarın şey saat ikide yani toplantımız var hani o proje için ee hazırlık lazım"
sonra: Yarın saat ikide toplantımız var. O proje için hazırlık lazım.
```

Model çıktısı korumadan geçmek zorunda: özetleme, ekleme, soruyu cevaplama ve
içerik kaybı reddediliyor. Reddedilirse deterministik sonuca dönülüyor —
temizlik adımı yüzünden dikte kaybolmaz.

## Config

`~/.config/yaz/config.json` (isteğe bağlı, CLI bayrakları önceliklidir):

```json
{
  "engine": "whisper",
  "whisper_model": "large-v3-turbo",
  "language": "tr",
  "hotkey": "fn",
  "inject_mode": "paste",
  "keep_model_loaded": true,
  "refine": "fillers",
  "overlay": true,
  "menu_bar": true,
  "on_transcript": "my-hook",
  "vocabulary": [
    "Slack", "pull request", "CI pipeline", "Kubernetes",
    { "term": "PostgreSQL", "aliases": ["postgres"], "min_similarity": 0.85 }
  ]
}
```

`vocabulary` düz metin listesi ya da takma ad / eşik taşıyan nesneler alabilir.

`on_transcript` her transkriptten sonra metni tek argüman olarak alan bir
kabuk komutu çalıştırır.

## Bilinmesi gerekenler

- **Parakeet Türkçe bilmiyor.** TDT v3'ün 25 dili arasında `tr` yok — NVIDIA
  model kartı ve FluidAudio'nun `Language` enum'uyla doğrulandı. Türkçe için
  Whisper tek seçenek; Parakeet İngilizce dikte için duruyor.
- **Whisper'ın `promptTokens`'ı bu modelde bozuk.** WhisperKit + large-v3-turbo
  ile her seferinde boş çıktı. ASR'a jargon öğretmenin standart yolu kapalı,
  bu yüzden sözlük deterministik bir son işleme katmanı olacak.
- **Model `~/Documents/huggingface/` altına iniyor**, cache dizinine değil.
  iCloud Documents senkronun açıksa 1.6 GB buluta gidebilir.
- **İlk çalıştırma yavaş** — CoreML derlemesi 2–3.5 dakika. Sonraki açılışlar
  ~7 sn.
- **Metin pano ile yerleştirilir** (⌘V). Panonun eski içeriği — metin, görsel,
  dosya — kaydedilip 0.25 sn sonra geri konur. parrot'un tuş tuş yazma yöntemi
  `--inject-mode type` ile duruyor, ama Electron uygulamalarında karakter
  düşürebiliyor.
- **Erişilebilirlik izni seni başlatan uygulamaya verilir**, yaz'a değil.
  Terminal değiştirince yeniden vermen gerekir. `yaz doctor` hangi uygulamayı
  işaretlemen gerektiğini söyler — launchd altında bu yaz'ın kendisi olur,
  çünkü ikili kendi Info.plist'ini taşıyor.
- **İkili imzasız** (kurulum betiği ad-hoc imza atıyor). Her yeniden derlemede
  TCC izinleri sıfırlanabilir. Kalıcı çözüm Developer ID imzası — açık konu.

## Yığın

- **Swift 6.2** — tek SPM executable target, `.app` bundle yok
- **WhisperKit** — Whisper large-v3-turbo, CoreML/ANE (varsayılan motor)
- **FluidAudio** — Parakeet TDT, CoreML/ANE (opsiyonel, İngilizce)
- **FoundationModels** — macOS 26 on-device LLM, son işleme için (indirme yok)
- **AVAudioEngine** — mikrofon yakalama

Tasarım notları ve ölçümler: [docs/architecture.md](docs/architecture.md).
