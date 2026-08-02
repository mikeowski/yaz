# Third-party notices

yaz is MIT licensed (see [LICENSE](LICENSE)). It links the libraries below and
downloads the model weights below at runtime. Licences were read from each
dependency's own `LICENSE` file in the resolved checkout, not assumed.

## Swift packages

| Package | Licence | Source |
|---|---|---|
| WhisperKit | MIT — © 2024 argmax, inc. | https://github.com/argmaxinc/WhisperKit |
| FluidAudio | Apache-2.0 | https://github.com/FluidInference/FluidAudio |
| swift-argument-parser | Apache-2.0 | https://github.com/apple/swift-argument-parser |
| swift-collections | Apache-2.0 | https://github.com/apple/swift-collections |
| swift-crypto | Apache-2.0 | https://github.com/apple/swift-crypto |
| swift-asn1 | Apache-2.0 | https://github.com/apple/swift-asn1 |
| swift-transformers | Apache-2.0 | https://github.com/huggingface/swift-transformers |
| swift-jinja | Apache-2.0 | https://github.com/huggingface/swift-jinja |
| yyjson | MIT | https://github.com/ibireme/yyjson |

Apache-2.0 requires that the licence and any `NOTICE` accompany redistribution.
If you ship a binary of yaz, ship this file with it. FluidAudio carries its own
`ThirdPartyLicenses` directory covering what *it* vendors; that applies
transitively.

## Models

Model weights are **not** part of this repository and are **not** bundled in
the app. They are downloaded on first use into `~/Documents/huggingface`, and
they carry their own licences, which are not MIT and are not ours to grant:

| Model | Published by | Where to check the licence |
|---|---|---|
| `openai_whisper-large-v3-v20240930_turbo` (Core ML) | Argmax, converted from OpenAI Whisper | https://huggingface.co/argmaxinc/whisperkit-coreml |
| `parakeet-tdt-0.6b-v3` (Core ML) | NVIDIA, converted by FluidInference | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |

If you plan to redistribute yaz, or use it commercially, read those model cards
yourself. They are stated here as pointers, not as a legal opinion, and they
can change independently of this repository.

## Apple frameworks

`FoundationModels`, `AVFoundation`, `AppKit`, `SwiftUI`, `Accelerate`, `IOKit`
and `CoreGraphics` are system frameworks covered by the Apple SDK licence
agreement. Nothing from them is redistributed here.
