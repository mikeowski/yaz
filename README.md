# yaz

Türkçe konuşan geliştiriciler için on-device dikte. Bas-konuş, bırak, metin
imlece gelir. Ses makineden çıkmaz.

[parrot](https://github.com/digimata/parrot)'un iskeleti üzerine kurulu, ama
onun bilerek reddettiği üç şeyi hedefliyor: **çok dilli varsayılan**,
**güvenilir metin yerleştirme**, **son işleme**.

**Gerekiyor:** macOS 26+, Apple Silicon.

## Durum

Erken. Şu an çalışan: motor katmanı ve ölçüm koşum takımı.

```sh
swift build -c release
./.build/release/yaz transcribe fixtures/t1.wav fixtures/t2.wav
```

```
✓ large-v3-turbo hazır — 6.8 sn

═══ t1.wav (5.57 sn) ═══
  gecikme 506 ms · RTF 0.091
  Bugün Pilot Projesini inceledim ve On Device Transcription Mimarisini çözdüm.
```

Daemon, kısayol ve metin yerleştirme henüz yok — sıradaki adımlar
[docs/architecture.md](docs/architecture.md) sonundaki durum listesinde.

## CLI

```sh
yaz transcribe <dosya...>              # ses → metin, gecikme ölçümüyle
  --engine-name whisper|parakeet       # varsayılan whisper (Türkçe destekleyen tek motor)
  --whisper-model large-v3-turbo|large-v3
  --language tr
  --repeat-count 3                     # ölçüm için tekrar
```

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

## Yığın

- **Swift 6.2** — tek SPM executable target, `.app` bundle yok
- **WhisperKit** — Whisper large-v3-turbo, CoreML/ANE (varsayılan motor)
- **FluidAudio** — Parakeet TDT, CoreML/ANE (opsiyonel, İngilizce)
- **FoundationModels** — macOS 26 on-device LLM, son işleme için (indirme yok)
- **AVAudioEngine** — mikrofon yakalama

Tasarım notları ve ölçümler: [docs/architecture.md](docs/architecture.md).
