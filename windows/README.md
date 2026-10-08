# CallRecorder for Windows

Same app as the Mac version, built with Electron so it runs on Windows 10/11 (64-bit). It records everything you hear
(Teams, Skype, Zoom, a browser…) plus your microphone, and does everything locally:

| Step | How |
|------|-----|
| 1. Record to MP3 | **Shift+Alt+R** or the button. Press again to stop. The MP3 is then transcribed automatically. |
| 2. Transcribe an MP3 | **Transcribe file…**. The transcript files are saved next to it. |
| 3. Live transcript + MP3 | **Shift+Alt+T**. Live "Them" / "Me" lines; the accurate re-check runs after you stop. |
| 4. Screenshot into the summary | **Shift+Alt+S** or the button, while recording. |

Also, like on the Mac: speaker recognition (**Speaker 1, 2…** for the call audio, "Me" for your microphone; word-level
matching; **Rename speaker** replaces a label with a name), language picker (English, Deutsch, Русский, auto-detect),
vocabulary list, filtering of made-up phrases ("Субтитры создавал DimaTorzok", "Thanks for watching", the vocabulary
echo "HMI, SAFe, Scrum"), a summary of every call (`summary.md`) and a transcript check that fixes missing words
(the live version stays as `live_transcript.txt`). The window keeps running in the system tray when closed, so the hotkeys
keep working.

Files go to `%USERPROFILE%\CallRecordings\<yyyy-MM-dd>\<HH-mm-ss>\` (one folder per call: `audio.mp3`, `raw_transcript.txt`, `fixed_transcript.txt`, `summary.md`, `screenshots\`, and for live recordings `live_transcript.txt`; one day folder per day; deliberately not in Documents, which Windows often syncs to OneDrive). Set the environment variable
`CALLREC_DIR` to use another folder. Settings, models and tools live in `%APPDATA%\CallRecorder`.

## Install (once)

1. Install [Node.js LTS](https://nodejs.org) and [Git](https://git-scm.com) (`winget install OpenJS.NodeJS.LTS Git.Git`).
2. In PowerShell, in the `windows` folder of this repository:

   ```powershell
   npm ci
   powershell -ExecutionPolicy Bypass -File .\setup-whisper.ps1    # ffmpeg, whisper.cpp and the models (~1.7 GB)
   npm start
   ```

3. For call summaries install [Ollama](https://ollama.com/download), then `ollama pull qwen2.5:7b`
   (`qwen2.5:14b` is better with 16 GB+ RAM). Without it, **Copy for Claude** puts the instructions and transcript on
   the clipboard for pasting into a Claude chat.

Update later with `powershell -ExecutionPolicy Bypass -File .\update.ps1` (git pull, npm install, start).
To get a normal installer: `npm run dist` (creates `dist\CallRecorder Setup x.y.z.exe`).

If `setup-whisper.ps1` cannot find a whisper.cpp Windows build, download one from
<https://github.com/ggml-org/whisper.cpp/releases> (`whisper-bin-x64.zip`) and run
`.\setup-whisper.ps1 -FromZip C:\path\to\whisper-bin-x64.zip`. With an NVIDIA GPU, `-Cuda` is much faster.

## Permissions and notes

- **Microphone:** Windows Settings → Privacy & security → Microphone → allow desktop apps.
- **Call audio** is captured from your default output device ("loopback"), so it works with speakers and headphones
  and needs no extra permission. It includes every sound your PC plays, not only the call. The window shows how many
  seconds of call audio and microphone were captured, so a silent track is easy to spot.
- **Hotkeys:** if another app already owns Shift+Alt+R / Shift+Alt+T the app says so; the buttons still work.
  (On Windows, Alt+Shift is also the default shortcut for switching keyboard layout, which matters with English, Russian and German layouts installed. If the layout flips when you press a hotkey, turn that shortcut off in Settings → Time & language → Typing → Advanced keyboard settings → Input language hot keys.)
- **Speaker recognition** downloads two small models from GitHub the first time (about 30 MB) and runs on the CPU.
  Speakers are matched only within one recording; no voice profiles are stored.
- There is no Apple-speech fallback on Windows: Whisper is the only engine.
- Everyone on the call must be fine with being recorded; check your company's and local rules.

## Development

```powershell
npm test       # unit and end-to-end tests with a fake Whisper, fake Ollama and real ffmpeg
```

`live-debug.log` (git-ignored, in this folder when run from source) explains what live transcription is doing.

## Privacy

Nothing you record leaves the PC: recognition, speaker detection and summaries all run locally, and the app talks only to
127.0.0.1. See [`SECURITY.md`](../SECURITY.md) for the data-flow table, the audit findings and how to verify it
(`check-network.ps1`, `block-outbound.ps1`, the **Offline mode** checkbox).

## Folder, topic, screenshots

- **Save to:** → **Choose…** sets another recordings folder (a subfolder per day is created inside); **Default** restores
  `%USERPROFILE%\CallRecordings`. Cloud-synced-looking folders are flagged.
- **Topic:** type what the call is about; the summary is organised around it and the topic is printed at the top of `summary.md`.
- **Screenshots:** during a recording press **Shift+Alt+S**. The screen freezes: drag a rectangle around just the relevant part (Esc or right-click cancels). Only that area is saved in the call's `screenshots\` folder; after
  the call a local Ollama vision model (`ollama pull qwen2.5vl:7b`) describes each image and the text joins the transcript as
  `[mm:ss] [Screen] …` lines for the summary. Images go to 127.0.0.1 only.
- "Thank you"/"Danke"/"Спасибо" that Whisper invents on keyboard noise are dropped when the audio under them is that quiet.

- **Glossary correction:** after a call is transcribed, the local Ollama model compares the transcript with the terms in your
  **Vocabulary…** file and points out misheard ones ("safe" → "SAFe", "Luxsoft" → "Luxoft"). The model only *suggests*; the app
  checks every suggestion (the replacement must be a glossary term, the quoted phrase must really be in the transcript) and applies
  it inside that phrase only, so the text is never rewritten. `fixed_transcript.txt` gets the corrected text, `raw_transcript.txt` keeps the
  original, and the window lists what changed. Switch it off with the "Fix glossary terms" checkbox. Keep the glossary to real names
  and jargon; very common words make poor entries.

There is no Quit button: closing the window keeps the app in the system tray; quit from the tray icon's menu (right-click → Quit).
