# CallRecorder (macOS 15+)

> **Windows?** See [`windows/README.md`](windows/README.md): the same app for Windows 10/11.

A menu-bar app that records any call you hear (Teams, Skype, Zoom, a browser...)
plus your microphone, and saves one MP3. It also transcribes, using Apple's native Speech framework.

## Build

For the best transcription (recommended), run this once. It installs Whisper and downloads the models
(~1.7 GB in total), and all processing stays on your Mac:

```bash
./setup-whisper.sh
```


```bash
brew install ffmpeg        # MP3 encoding
cd CallRecorder
./build.sh                 # needs Xcode 16+ / command line tools
mv "CallRecorder.app" /Applications && open "/Applications/CallRecorder.app"
```

## Use

The window has three tabs: **Recorder** (record, screenshot, topic, transcript, summary, and a slider for the window's transparency), **Settings** (recordings folder, language, engine and the checkboxes) and **About** (version, release date, author).

**Live translation:** the "Translation ◂" button above the transcript opens a pane on the right (the window widens) with a parallel translation into the language chosen in the drop-down (15 languages). It uses the local Ollama model only, runs only while the pane is open, and nothing leaves the laptop.

The app opens a window on launch, shows a red icon in the Dock, and adds a "Rec" item to the menu bar
(it shows the elapsed time while recording). Closing the window keeps it running; the hotkeys keep working. There is no Quit button: quit with ⌘Q or from the Dock icon's menu.

| Step | How |
|------|-----|
| 1. Record to MP3 | **⇧⌥R** (Shift+Option+R) or the menu-bar button. Press again to stop. |
| 2. Transcribe an MP3 | Menu → **Transcribe file…** → pick the file. `raw_transcript.txt` etc. are saved next to it. |
| 3. Live transcript + MP3 | **⇧⌥T**. Shows "Me" / "Them" lines live; `audio.mp3` and the transcripts are saved on stop. |
| 4. Screenshot into the summary | **⇧⌥S** or the button, while recording. See "Screenshots" below. |

Files go to `/Users/mmasliukov/Private/claude/call-recorder/recordings/` (git-ignored; falls back to `~/Documents/CallRecordings/` if that folder cannot be created). Every call gets its own folder, `<yyyy-MM-dd>/<HH-mm-ss>/`:

```
recordings/2026-10-08/14-30-05/
  audio.mp3               the call (both sides + your microphone)
  raw_transcript.txt      the transcript as recognised (after the accurate check pass)
  fixed_transcript.txt    the same with glossary corrections (identical if nothing needed fixing)
  summary.md              the summary
  screenshots/            your selected areas (01_05-12.png …) and descriptions.txt
  live_transcript.txt     live recordings only: the live version, before the check pass
```

An audio file you transcribe from elsewhere gets the same files next to it, named `<name>.raw_transcript.txt`, `<name>.summary.md` and so on.

Pick the language (English, Deutsch, Русский) in the menu before recording. Recordings made with older versions stay where they were, in `CallRecordings/`.
**Save to:** → **Choose…** picks another folder for recordings (a subfolder per day is created inside it); **Default** goes back to the folder above. A folder that looks cloud-synced (iCloud, Dropbox, OneDrive…) gets a warning, because your calls would be uploaded.

## Permissions (first launch)

- **Screen & System Audio Recording**: required to capture what you hear. Approve it in
  System Settings → Privacy & Security, then relaunch the app. No video is recorded.
- **Microphone** and **Speech Recognition**: approve the prompts.

## Notes

- Everyone on the call must be fine with being recorded; check your company's and local rules.
- Two transcription engines (menu → Engine): **Whisper** (local whisper.cpp, default once set up; very good
  for English, German and Russian, plus "Auto-detect" for mixed-language calls) and **Apple** (built-in,
  no setup, weaker).
- **Live mode (⇧⌥T)** keeps the Whisper model loaded in a small local `whisper-server` and re-reads the last
  seconds of audio every second. Grey text is tentative and gets rewritten; a word becomes final only when two
  passes agree, and the last word of a pass is never final yet, so a word split across two moments is corrected
  with its second half instead of staying wrong. A pause of ~1 s ends a line. The model needs a moment to load
  when recording starts; audio is buffered meanwhile. Updates are as fast as your Mac runs the model (about
  once a second on Apple Silicon, slower on older Macs).
- **Accuracy:** "Transcribe file…" uses the most accurate model (large-v3) with beam search, volume levelling
  and silence detection; the live transcript uses the faster large-v3-turbo so it keeps up in real time. For
  best results: choose the language of the call instead of Auto-detect (auto-detect on a one-second window is
  unreliable, especially for mixed calls; the live "Auto-detect" now picks between English, German and Russian once
  per sentence instead of guessing every second), use the **Vocabulary…** button to list names and jargon Whisper
  should spell correctly (one per line), and use headphones so the other side doesn't leak into your mic.
  The most accurate result is always the file transcription, so for important calls record, then transcribe
  the MP3 afterwards.
- **Made-up text:** Whisper sometimes invents phrases on silence or breath ("Субтитры создавал …", "Thanks for
  watching", "Untertitel der Amara.org-Community") or reads its vocabulary hint back ("…, HMI, SAFe, Scrum"). Known
  phrases and hint echoes are filtered out. To block more, add a line starting with `!` to the **Vocabulary…** file,
  for example `! Subtitles by the Amara.org community`.
- **Transcript check:** after a live recording the app re-transcribes the call-audio track and your microphone
  track separately with the accurate model, which fills in words the live view missed, and replaces the transcript
  (`raw_transcript.txt`, labelled "Them"/"Me"). The live version stays as `live_transcript.txt`. It runs in the background and
  takes a few minutes for long calls; switch it off with the checkbox in the menu.
- **Speakers:** with "Recognize speakers" on, the call-audio track is analysed locally (FluidAudio) and its lines are
  labelled "Speaker 1", "Speaker 2"… instead of "Them"; your microphone stays "Me". For "Transcribe file…" every voice,
  including yours, gets a Speaker label. Use **Rename speaker…** to replace a label with a name; the saved transcripts
  is updated. Speaker models (small, a few hundred MB at most) download on first use. Voices are matched only
  within one recording; no voice profiles are stored. Limits: it works per transcript segment, so a quick
  interjection inside a long segment may be attributed to the main speaker, and several people sharing your
  microphone in one room all show as "Me" (use "Transcribe file…" on the MP3 to split them).
- **Summary:** when a call has been transcribed (a plain "Record to MP3" is transcribed automatically afterwards),
  the app writes `summary.md` (summary, key points, decisions, action items, open questions) using a local
  model served by [Ollama](https://ollama.com), so nothing leaves your Mac. One-time setup:
  `brew install ollama && brew services start ollama && ollama pull qwen2.5:7b` (`qwen2.5:14b` is better if you have
  16 GB+ RAM). Without Ollama, **Copy for Claude** puts the instructions + transcript on the clipboard to paste into a
  Claude chat. Turn it off with the "Summarize each call" checkbox.
- **Topic:** type what the call is about into the *Topic* field before (or during) the call. The summary is then organised
  around it, with off-topic items mentioned briefly, and the topic is printed at the top of `summary.md`.
- **Screenshots:** while recording, press **⇧⌥S** (or the button) when someone shares a slide or a picture. Drag a rectangle around just the relevant part (Esc cancels); only that
  area is saved in the call's `screenshots/` folder. After the call a local vision model in Ollama describes each
  image (`ollama pull qwen2.5vl:7b`; llama3.2-vision, gemma3 and llava also work), the descriptions are added to the transcript as
  `[mm:ss] [Screen] …` lines (also saved as `screenshots/descriptions.txt`) and used in the summary. Without a vision model the images are
  still saved. Images are only ever sent to Ollama on 127.0.0.1. Screenshots of slides can contain confidential data: they are kept
  with the recording, so treat that folder accordingly.
- **Silence and typing:** very short phrases such as "Thank you" or "Danke" that Whisper invents on keyboard noise are dropped when the
  audio under them is that quiet; a real, audible "thank you" is kept. Details are in `live-debug.log` ("dropped quiet filler").
- **Glossary correction:** after a call is transcribed, the local Ollama model compares the transcript with the terms in your
  **Vocabulary…** file and points out misheard ones ("safe" → "SAFe", "Luxsoft" → "Luxoft"). The model only *suggests*; the app
  checks every suggestion (the replacement must be a glossary term, the quoted phrase must really be in the transcript) and applies
  it inside that phrase only, so the text is never rewritten. `fixed_transcript.txt` gets the corrected text, `raw_transcript.txt` keeps the
  original, and the window lists what changed. Switch it off with the "Fix glossary terms" checkbox. Keep the glossary to real names
  and jargon; very common words make poor entries.
- The app is ad-hoc signed. If macOS forgets the Screen Recording permission after a rebuild,
  remove the old entry in Privacy settings and add the app again.
- Wearing headphones avoids the other side leaking into your mic track.
- **Privacy:** everything runs on your Mac; see [`SECURITY.md`](SECURITY.md) for the data flow, the review findings and how to verify (`./check-network.sh`, the **Offline mode** checkbox).

**Known voices:** after a call, use "Rename speaker" (Speaker 1 → a name). The app remembers that voice (a speaker embedding, stored only in `voices.json` in Application Support/CallRecorder, owner-only) and names that person in later calls. A match must be clear (similarity above a threshold and ahead of the next person); otherwise the speaker stays "Speaker N". Renaming a recognised name corrects/refines it. Settings → Known voices lists and forgets them. Works on the call-audio track (people on the other end), not on your own microphone ("Me").

**Summaries use names:** speakers you have named (or the app recognised) are passed to the summary model as "Named participants", so decisions and action items carry names. "Me", "Them" and "Speaker N" are never given invented names.

**Confirm speaker:** when the app recognised someone correctly, "Confirm speaker" refines their saved voice with that call (once per call). Renaming still corrects a wrong guess.

**Analyze words:** lists the 10 most frequent words (filler words left out) and 10 "unknown" words of the transcript on screen, or of a transcript file if there is none. Unknown = names, abbreviations and terms that are not in the Vocabulary list; "+ Vocabulary" / "Add all" put them into it. Lowercase ordinary words can't be judged unknown, because there is no dictionary.

**Translation controls** (pause ⏸, continue ▶, stop ⏹, restart ↻, shown while the translation pane is open): Pause lets the current line finish and waits; Stop cancels the request to Ollama and skips what was waiting (Continue then picks up from new lines); Restart clears the translation and translates everything again.

**Progress:** while a file is transcribed or a recording is checked, a bar with a percentage shows how far Whisper is (it reads whisper-cli's own progress output). Finding speakers shows a busy indicator without a percentage, because that step has no progress to report. With two tracks (call audio and microphone) the percentage covers both.
