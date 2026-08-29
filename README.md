# Murmur

Hold a key, talk, and your words get typed into whatever app you're in — cleaned
up, punctuated, filler words gone. An open-source take on Wispr Flow for macOS.

Everything runs on-device by default. No account, no server, no audio leaves
your Mac.

Two speech engines, switchable from the menu bar:

| | Apple `SpeechAnalyzer` | Whisper (CoreML) |
| --- | --- | --- |
| Languages | 9 | ~99 |
| Live text as you speak | yes | no |
| Speed | instant | a beat after you finish |
| First-run download | ~small, from Apple | a few hundred MB, from HuggingFace |

Apple's engine is the default. Switch to Whisper if your language isn't in
Apple's list — Russian, Arabic, Hindi and most others aren't.

## Requirements

- macOS 26 or later (uses the `SpeechAnalyzer` API added in macOS 26)
- Apple Silicon
- Xcode 26 / Swift 6.2 toolchain to build

The only dependency is [WhisperKit](https://github.com/argmaxinc/WhisperKit),
and only for the Whisper engine.

## Build and run

```bash
./build.sh --release
open Murmur.app
```

Murmur lives in the menu bar — there's no Dock icon. The settings window opens
on first run, from **Settings… (⌘,)** in the menu, or from anywhere with:

```bash
open murmur://settings
```

That last one matters on a notched MacBook: if the menu bar is full, the status
icon can be hidden behind the notch entirely, and a menu-bar-only app gets no
reopen event from `open Murmur.app`. The URL scheme is the way back in.

On first launch macOS will ask for two permissions. Both are required:

| Permission | Why |
| --- | --- |
| **Microphone** | to hear you |
| **Accessibility** | to watch for the trigger key and type into other apps |

Accessibility has to be granted by hand in **System Settings → Privacy &
Security → Accessibility**. If Murmur isn't listed, drag `Murmur.app` in.

Check that everything is wired up:

```bash
./Murmur.app/Contents/MacOS/Murmur --check
```

Run the tests (pure logic only — no mic, no models, no network):

```bash
swift test
```

Try an engine against an audio file, no microphone needed:

```bash
./Murmur.app/Contents/MacOS/Murmur --transcribe sample.wav --language ru
```

Other diagnostics, for when something doesn't work:

| Flag | Answers |
| --- | --- |
| `--dictate 5` | does the mic hear anything, and what comes back? |
| `--test-hotkey` | does the event tap see the trigger key? |
| `--watch-keys 10` | what modifier events arrive when you press a key? |
| `--focus 5` | what does Accessibility see in the focused field? |
| `--paste "text"` | does injection land? `--clipboard` forces the fallback |
| `--models` | which Whisper models are available |
| `--test-cleanup` | does the configured cleanup endpoint answer? |
| `--test-edit "make it formal"` | runs the voice-edit path on the current selection |
| `--press 5` | holds the trigger key for real, so a running Murmur dictates |

Every dictation is traced to `~/Library/Application Support/Murmur/murmur.log`:
key down, capture start, transcript length, which injection path was used. That
log is the fastest way to answer "it doesn't work".

## Using it

Hold **right ⌥**, speak, let go. The transcript is cleaned up and pasted at your
cursor. A pill at the bottom of the screen shows what's being heard as you talk.

Press **Esc** while dictating to throw it away and type nothing.

**Edit by voice.** Select text anywhere, hold the edit key (right ⌥ by default,
off until you set one) and say what to do with it — "make this formal",
"translate to English", "shorter", "turn this into bullets". The selection is
replaced with the result. Needs a cleanup model configured.

**Hold or tap.** Hold-to-talk by default; switch to tap-to-start, tap-to-stop in
settings if you dictate long passages.

Everything is configurable from the menu bar:

- **Trigger key** — right ⌥, left ⌥, right ⌘, or fn
- **Engine** — Apple or Whisper, plus which Whisper model to use
- **Language** — a specific one, your system language, or (on Whisper)
  detected per dictation, so you can switch languages mid-session
- **Cleanup** — off, on-device model, or a remote API
- **Custom vocabulary** — names and jargon the transcriber keeps mangling
- **Free memory when idle** — drops the speech model after a few minutes
  without dictating
- **Usage** — words dictated, words per minute, and a conservative estimate of
  time saved against typing at 40 wpm
- **Recent** — the last 50 dictations, in case a paste goes somewhere unhelpful.
  Stored as plain JSON in `~/Library/Application Support/Murmur`; turn
  **Save history** off to keep nothing.

## Cleanup

The raw transcript is passed through a language model that only rewrites: it
fixes punctuation and capitalisation, drops filler words, and obeys spoken
commands like "new paragraph". It's told never to answer or add content, and
output that balloons past a sane length is discarded in favour of the raw
transcript. Cleanup failing never costs you the words.

Three modes:

- **Your own endpoint** — anything OpenAI-compatible, chosen in the settings
  window. Presets for **Ollama** and **LM Studio**, both of which run on your
  own machine and need no API key, plus Groq, OpenAI and OpenRouter for hosted
  ones. There's a **Test** button, so a wrong endpoint says so instead of
  quietly leaving your text unchanged. Keys live in the login keychain, never
  in preferences.
- **Apple's on-device model** — free and offline, but needs Apple Intelligence
  turned on, and it has no Russian.
- **Off** — paste exactly what was heard.

The recommended fully-local setup:

```bash
brew install ollama
ollama pull qwen3:1.7b
```

then pick **Ollama (local)** in the settings window and press Test.

Cleanup also knows *where* the text is going. The frontmost app is classified
by bundle identifier, and a terminal is told to skip markdown, a code editor to
leave identifiers alone, a chat not to invent greetings. Apps with nothing
useful to say about style add nothing to the prompt.

## How it works

```
right ⌥ down ──▶ CGEventTap ──▶ AVAudioEngine ──▶ resample ──▶ speech backend
                                                                     │
                                                      live partial text ──▶ overlay
right ⌥ up ────▶ finalize ──▶ cleanup model ──▶ AX insert / ⌘V ──▶ your app
```

| File | Does |
| --- | --- |
| `HotkeyMonitor.swift` | the event tap: trigger key down/up, Esc to cancel |
| `AudioCapture.swift` | mic tap, buffer copy, input level for the waveform |
| `SpeechBackend.swift` | the engine protocol, and locale resolution across engines |
| `AppleBackend.swift` | `SpeechAnalyzer` streaming, model download |
| `WhisperBackend.swift` | WhisperKit batch transcription, ~99 languages |
| `AudioResampler.swift` | format conversion shared by both engines |
| `Cleanup.swift` | the rewrite pass, on-device and remote |
| `TextInjector.swift` | Accessibility insertion, pasteboard fallback |
| `Overlay.swift` | the floating pill |
| `History.swift` | the last 50 dictations, on disk, optional |
| `Settings.swift` | UserDefaults; API keys go to the keychain instead |
| `DictationController.swift` | the loop that ties it together |

Text injection tries the Accessibility API first — no clipboard churn, no ⌘V in
the target app's undo stack — but plenty of apps (Electron, terminals) lie about
their text fields, so it falls back to a pasteboard round-trip that restores
your previous clipboard afterwards.

## Caveats

- **Apple's engine covers only 9 languages** — English, German, Spanish,
  French, Italian, Japanese, Korean, Portuguese and Chinese. Everything else
  needs the Whisper engine. Run `--check` to see the list for your Mac.
- **Whisper invents things when it hears silence.** It was trained on a lot of
  subtitled video, so given room tone it produces closing credits — "Thanks for
  watching!" and the like. Murmur gates on the loudest 100 ms window of the
  recording and simply doesn't call the model below it. Real speech measures
  around 0.2; room tone around 0.002; the floor sits at 0.004.
- **Whisper has no live text.** It transcribes the whole utterance once you
  release the key, so the overlay shows a waveform rather than words.
- **Without a signing identity the build is ad-hoc signed**, and the
  Accessibility grant silently stops working after every rebuild — the checkbox
  stays ticked while the permission does nothing. See below.
- **First dictation in a new language downloads a model.** Apple's are small;
  Whisper's are a few hundred MB. Both land in
  `~/Library/Application Support/Murmur`.

## Making permissions stick

macOS ties the Accessibility grant to the app's code signature. An ad-hoc
signature changes on every build, so after each rebuild macOS quietly treats
Murmur as a different app: the checkbox in System Settings stays ticked, and the
hotkey stops working. A stable self-signed certificate fixes this for good.

1. Open **Keychain Access**
2. Open **Certificate Assistant** — on macOS 26 it is no longer in the Keychain
   Access menu, it's a separate app:
   `open "/System/Library/CoreServices/Certificate Assistant.app"`
3. **Name:** `Murmur Local Signing` — the build script looks for this exact name
4. **Identity Type:** Self Signed Root
5. **Certificate Type:** Code Signing
6. Tick **Let me override defaults**, then raise the validity period (the
   default is 365 days, after which signing fails)
7. Click through the rest and **Create**

Check it took:

```bash
security find-identity -v -p codesigning
```

Certificate Assistant makes an *untrusted* root, so it shows as
`CSSMERR_TP_NOT_TRUSTED` and `find-identity -v` lists nothing. That's fine —
`build.sh` signs by the certificate's SHA-1, which works regardless, and pins
the choice in `.signing-identity` so rebuilds keep using the same one.

What matters is the designated requirement. Ad-hoc gives you
`cdhash H"…"`, which changes with every build. The certificate gives
`identifier "com.murmur.dictation" and certificate leaf = H"…"`, which doesn't.
Check yours with `codesign -d -r- Murmur.app`.

Switching from ad-hoc to the certificate changes the signature one last time, so
grant Accessibility once more after the first signed build. It will stick after
that.

If the hotkey ever stops working right after a rebuild, that's this problem:

```bash
tccutil reset Accessibility com.murmur.dictation
```

then grant it again.

## Privacy

Audio is transcribed on-device and never written to disk. Two things are worth
knowing anyway:

- **Murmur sees your keystrokes.** Watching for the trigger key needs an event
  tap, and cancelling on Esc means that tap can't be listen-only. Murmur reads
  the key code, acts on the trigger key and Esc, and passes everything else
  through untouched — see `HotkeyMonitor.handle`. That's the whole of it, and
  it's why the app needs Accessibility permission.
- **Transcripts are kept in plain text** in `~/Library/Application Support/Murmur`
  so you can recover a bad paste. Turn **Save history** off in the menu to keep
  nothing; that also deletes what's already there.

Remote cleanup is the only feature that sends anything off the machine, it's off
by default, and it sends the transcript text — never audio.

## Licence

MIT.
