# CallRecorder for Windows

Same app as the Mac version, built with Electron so it runs on Windows 10/11 (64-bit). It records everything you hear
(Teams, Telemost, Skype, Zoom, a browser…) plus your microphone, and does everything locally:

| Step | How |
|------|-----|
| 1. Record to MP3 | **Ctrl+Alt+R** or the button. Press again to stop. The MP3 is then transcribed automatically. |
| 2. Transcribe an MP3 | **Transcribe file…**. A `.txt` is saved next to the file. |
| 3. Live transcript + MP3 | **Ctrl+Alt+T**. Live "Them" / "Me" lines; the accurate re-check runs after you stop. |
| 4. Screenshot into the summary | **Ctrl+Alt+S** or the button, while recording. |

Also, like on the Mac: speaker recognition (**Speaker 1, 2…** for the call audio, "Me" for your microphone; word-level
matching; **Rename speaker** replaces a label with a name), language picker (English, Deutsch, Русский, auto-detect),
vocabulary list, filtering of made-up phrases ("Субтитры создавал DimaTorzok", "Thanks for watching", the vocabulary
echo "HMI, SAFe, Scrum"), a summary of every call (`<name>.summary.md`) and a transcript check that fixes missing words
(the live version stays as `<name>.live.txt`). The window keeps running in the system tray when closed, so the hotkeys
keep working.

Files go to `%USERPROFILE%\CallRecordings\<yyyy-MM-dd>\` (one folder per day; deliberately not in Documents, which Windows often syncs to OneDrive). Set the environment variable
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
- **Hotkeys:** if another app already owns Ctrl+Alt+R / Ctrl+Alt+T the app says so; the buttons still work.
  (On a German keyboard Ctrl+Alt is "AltGr"; these two combinations are unused there.)
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
- **Topic:** type what the call is about; the summary is organised around it and the topic is printed at the top of `<name>.summary.md`.
- **Screenshots:** during a recording press **Ctrl+Alt+S**. The screen under the mouse is saved in `<name>_screens\`; after
  the call a local Ollama vision model (`ollama pull qwen2.5vl:7b`) describes each image and the text joins the transcript as
  `[mm:ss] [Screen] …` lines for the summary. Images go to 127.0.0.1 only.
- "Thank you"/"Danke"/"Спасибо" that Whisper invents on keyboard noise are dropped when the audio under them is that quiet.
