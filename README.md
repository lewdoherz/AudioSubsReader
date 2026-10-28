# AudioSubs Reader

An independent Windows/Android application. The previous `audiosubs` project is not modified or required at runtime.

The ebook is the displayed source of truth. Local speech recognition supplies word timestamps; conservative matching locates those words in the ebook without replacing its original spelling, punctuation or semantic formatting. The reader displays a continuous reflowable book, not subtitle rows.

Downloads: [GitHub Releases](https://github.com/lewdoherz/AudioSubsReader/releases). Windows packages are portable ZIPs; Android packages are player-only APKs. Speech models and prepared books are not included.

## Workflow

1. **Windows:** choose **Prepare on this PC**, a DRM-free EPUB, and its audiobook files. Files are naturally sorted when added; use **Move earlier** to correct their order.
2. Download a speech model explicitly, or enter an existing local CTranslate2/faster-whisper model directory. Start with **tiny**, **CPU**, **int8**. Select the spoken language or `auto`.
3. Press **Create reading book** and choose an output folder. Preparation writes a new `.abook` file, with a numbered name if necessary; original inputs and existing packages are not overwritten.
4. Press **Import and read**. The package contains the ebook text, illustrations, original audio, and timing, so it can be copied to another computer or Android device.
5. **Android:** transfer the `.abook`, press **Open reading book**, and select it with the document picker. Android imports and plays prepared books only; it contains no Python, transcription worker, speech models, translation, or secondary subtitle controls.

Playback includes play/pause, seeking, speed, track selection, ebook chapter navigation, automatic track advancement, and per-device resume positions. **Word**, **Phrase**, and **Sentence** choose the visual highlight range. Phrase/sentence ranges expand around a genuinely timed word; they are not separately measured speech boundaries.

Following keeps the active word visible, including inside paragraphs longer than the screen. Manual scrolling pauses following without changing the audio position; **Resume following** returns to the narration. Unaligned intervals show no stale highlight. **Alignment details** reports matched recognized words and preparation warnings.

## Appearance and playback time

Open **Appearance** from the library or reader toolbar. Changes apply immediately and are saved on this device:

- **System**, **Light**, or **Dark** theme.
- System font, PT Serif, PT Sans, or IBM Plex Mono, with a **14–40** font-size range. Bundled fonts include bold and italic variants; ebook emphasis remains intact.
- Background, underline, or text-color highlighting; palette colors or a custom `#RRGGBB` color. Highlight text is contrast-adjusted when necessary for readability.
- Word, phrase, or sentence highlight range.
- Whole-book or current-file timeline.

**Whole book** is the default clock: **Played** is the current position across all audio files, **Remaining** is time to the end, and **Total** is the complete audiobook duration. Seeking and ±15-second jumps cross file boundaries while retaining play/pause state and playback speed. After the last file finishes, the clock stays at the end until you replay or seek. The track indicator still identifies the current audio file. Choose **Current file** in the reader's timeline menu or Appearance to restore a file-local clock.

These are audiobook positions and recorded durations, not accumulated listening statistics or speed-adjusted estimates. If any track duration is unknown, the whole-book total is explicitly unavailable rather than an incorrect partial sum.

## Build and run

Prerequisites: Flutter/Dart compatible with `pubspec.yaml`; Visual Studio C++ desktop tools for Windows; Python **3.12 x64** for preparation development/packaging; Android SDK/JDK for Android builds. The LGPL FFmpeg/PyAV builder downloads checksum-pinned MSYS2/build inputs into this project's ignored build cache; a stock GPL-enabled PyAV wheel is not substituted.

```powershell
flutter pub get
powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1
flutter run -d windows
```

The setup script creates this project's own `worker/.venv`. To choose a Python installation:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/setup_worker.ps1 -Python C:\path\to\python.exe
```

Package the standalone Windows preparation worker and build the application:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1
```

Run `build/windows/x64/runner/Release/audiosubs_reader.exe`. Keep the **entire Release directory**, including `preparation_runtime`, DLLs and Flutter data. A packaged build does not require installed Python or the old app. Models are downloaded separately. Use `-SkipWorker` only when the packaged worker is already current. The first Windows launch presents the bundled third-party component terms; acknowledgement is stored locally and requested again if those terms change.

Build the player-only Android APK:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build_android.ps1
```

Output: `build/app/outputs/flutter-apk/app-release.apk` for ARM64 and x86_64. The generated local Android release configuration uses the development signing key, not a production/store key. Application ID `com.audiosubs.audiosubs_reader` is separate from the old player.

### CUDA on Windows

An NVIDIA driver alone does not supply the libraries required by the [faster-whisper GPU backend](https://github.com/SYSTRAN/faster-whisper#gpu): **CUDA 12 cuBLAS and CUDA 12-compatible cuDNN 9**. A missing `cublas64_12.dll` is a runtime-library problem, not a damaged speech model.

To build with a private GPU runtime:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1 -Cuda
```

`-Cuda` installs pinned NVIDIA wheels from `worker/requirements-cuda.txt` into this project's environment. Packaging includes their DLLs and licence metadata under `preparation_runtime/_internal/`. CPU-only environments do not install these large optional packages; once installed, subsequent packaging includes them automatically. For development without packaging, use `scripts/setup_worker.ps1 -Cuda`.

The worker registers its private DLL directories and preloads cuBLAS/cuDNN before starting GPU inference. Search-path changes apply only to the worker process; no global PATH changes or unrelated Python installation are needed. Compatible system libraries on PATH or under `CUDA_PATH/bin` / `CUDNN_PATH/bin` remain supported. CPU inference does not initialize the CUDA loader.

Use **Device: cuda**, **Precision: float16** with a compatible NVIDIA GPU/driver. Missing or unloadable GPU libraries produce a setup error rather than silently switching to CPU. NVIDIA's component licences apply; review their redistribution terms before publishing GPU-enabled bundles.

### Redistributing Windows builds

`build_windows.ps1` collects native/Python/Flutter dependency notices and matching LGPL FFmpeg/PyAV build inputs before compiling. Runtime notices and component terms are under `preparation_runtime/_internal/THIRD-PARTY-LICENSES/`.

Publish `dist/<version>/AudioSubsReader-<version>-ffmpeg-lgpl-source.zip` at the release URL recorded in that directory's manifest, alongside the Windows binary ZIP. It contains matching FFmpeg/PyAV source, patches, checksums, build configuration and rebuilding instructions. Shared FFmpeg libraries remain replaceable; no application-wide restriction overrides LGPL replacement/relinking rights. The collector's `unresolved_terms` identifies publisher review obligations; collecting notices is not legal approval or an application licence assignment.

Windows executables are not Authenticode-signed. Android release builds currently use a development signing key, not a store-production key; neither package is a store release.

## Preparation CLI

```powershell
worker\.venv\Scripts\python.exe worker\prepare.py --download-model tiny --model-directory C:\models
worker\.venv\Scripts\python.exe worker\prepare.py --request request.json
```

The download above creates `C:\models\tiny`. A request contains:

```json
{
  "ebook": "C:/books/title.epub",
  "audio": ["C:/books/01.mp3", "C:/books/02.mp3"],
  "output": "C:/books/title.abook",
  "model": "C:/models/tiny",
  "language": "en",
  "device": "cpu",
  "computeType": "int8"
}
```

The worker emits UTF-8 JSONL progress, an explicit error with nonzero exit status, or a final `done` event. Inference uses local model files only. CUDA requires the private runtime described above or compatible system CUDA/cuDNN libraries, plus an NVIDIA driver; unsupported settings fail rather than silently changing devices.

For existing word-level timing, optional `transcript` names a UTF-8 JSON file containing one array per audio track, in the same order. Each word is `{"word":"Example","start":0.1,"end":0.6}`, with seconds relative to its track. This bypasses speech recognition, not ebook alignment.

## Format and storage

`.abook` is a ZIP with schema-versioned `book.json`, relative `audio/` paths and `images/`. The manifest holds semantic blocks/inline runs, track durations, and word cues with track-local millisecond timestamps and block-local UTF-16 character offsets. No absolute Windows media paths travel to Android.

Imports stream audio to app-owned storage off the UI isolate, validate referenced assets and cue ranges, and reject unsafe paths, symbolic links, duplicate paths and incomplete packages. A provider-only Android URI is streamed into a temporary local package first. Reimporting the same book ID preserves the existing local copy and progress. Keep enough storage for the package, expanded audio, and temporary import copy.

Reading positions are stored beside each imported book, independently on each device; they are not synchronized between devices. Uninstalling/clearing Android app data removes its imported library and progress. Keep the original `.abook` elsewhere.

## Boundaries

- **DRM-free, reflowable EPUB** is the preparation format. Headings, paragraphs, bold/italic/underline, list items, quotations, line breaks and supported illustrations are retained. Safe SVG images are rasterized to PNG. Publisher stylesheets/fonts, exact page layout, complex tables and fixed-layout fidelity are not reproduced. Convert other ebook formats to DRM-free EPUB first; DRM removal is not provided.
- Audio selection accepts MP3, M4B, M4A, WAV, FLAC, OGG and AAC. Preparation uses PyAV; playback uses native platform decoders, so recognition of an extension does not guarantee that a particular encoding will play. Native failures are displayed.
- Alignment is conservative text matching against recognized speech, not a forced aligner. Ambiguous/repeated passages, narration additions, abridgements, different editions and recognition errors can leave gaps. Coverage measures the fraction of recognized words matched, not transcription accuracy or the fraction of the ebook narrated.
- Audio decoding uses bounded **90-second chunks** rather than loading an entire audiobook waveform into memory. Chunk boundaries may lose words. The model and whole-book text/timing index still require memory.
- EPUB limits: 20,000 entries, 128 MiB per expanded entry and 512 MiB total expanded content. Reader packages allow 100,000 entries, a 64 MiB manifest and 64 GiB expanded content.
- Android playback pauses when the app enters the background. Background media service, lock-screen controls and durable background preparation are not implemented. Windows can continue playing while unfocused.
- Windows debug runs currently emit a native-thread event-channel diagnostic from `audioplayers_windows` 4.4.1. It is not suppressed; treat it as an upstream stability risk.
- Packaged Windows builds include collected third-party notices and publish corresponding LGPL source beside the binaries. Their component-specific redistribution terms still apply; this repository does not assign an application licence.

## Checks

```powershell
flutter analyze lib test
flutter test test
worker\.venv\Scripts\python.exe -m unittest discover -s worker/tests
```

Runtime verification used real two-track narrated WAV audio and an EPUB with inline emphasis and a multi-screen paragraph. Source and standalone packaged workers produced portable books with 54 recognized words anchored to ebook text. Windows and an Android x86_64 emulator exercised native playback, visible-word following, manual-scroll/resume-follow, sentence highlighting, speed changes, automatic track advancement, and persisted resume. Physical ARM64 hardware was not exercised.

The v0.2.0 native runs additionally exercised live dark mode, serif font/size changes, custom highlight-color validation and underlining, visible-word following after those changes, whole-book clocks, paused cross-file seeking/skipping, switching to a file-local clock, and persisted appearance/playback speed. The displayed reader and Appearance dialog/sheet were visually checked on both platforms.

Native completion/replay checks on both platforms verified that the completed book clock remains at its final endpoint despite late decoder position resets, and that replay and subsequent cross-file seeking receive position updates normally.

Windows preparation was also exercised through native EPUB, multi-audio and output-folder dialogs, invoking its bundled worker and importing the result. An Android release APK was separately exercised with the real document provider and observed playing highlighted text after automatic track advancement. Disposable fixtures and UI-driving scripts are not shipped. Permanent tests cover package safety, alignment ambiguities/omissions, Unicode ranges, formatting, contrast, atomic preference persistence, highlight boundaries and whole-book timeline boundaries.

CUDA was verified on the RTX 5080 with driver 617.42, the local large-v3 model, and float16 inference. Earlier source/packaged/deployed runs used only Windows system directories on PATH with CUDA_PATH/CUDNN_PATH unset, demonstrating private-runtime loading. The final LGPL-runtime packaged worker also transcribed the two-track fixture and anchored all 54 recognized words. This short smoke did not transcribe the user's full audiobook.
