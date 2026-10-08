# CallRecorder (macOS 15+)

> **Windows?** See [`windows/README.md`](windows/README.md): the same app for Windows 10/11.

A menu-bar app that records any call you hear (Teams, Telemost, Skype, Zoom, a browser...)
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

The app opens a window on launch, shows a red icon in the Dock, and adds a "Rec" item to the menu bar
(it shows the elapsed time while recording). Closing the window keeps it running; the hotkeys keep working.

| Step | How |
|------|-----|
| 1. Record to MP3 | **⌃⌥R** (Control+Option+R) or the menu-bar button. Press again to stop. |
| 2. Transcribe an MP3 | Menu → **Transcribe file…** → pick the file. A `.txt` is saved next to it. |
| 3. Live transcript + MP3 | **⌃⌥T**. Shows "Me" / "Them" lines live; `.txt` and `.mp3` saved on stop. |
| 4. Screenshot into the summary | **⌃⌥S** or the button, while recording. See "Screenshots" below. |

Files go to `/Users/mmasliukov/Private/claude/call-recorder/CallRecordings/<yyyy-MM-dd>/` (one subfolder per day; git-ignored; falls back to `~/Documents/CallRecordings/` if that folder cannot be created). Pick the language (English, Deutsch, Русский) in the menu before recording.
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
- **Live mode (⌃⌥T)** keeps the Whisper model loaded in a small local `whisper-server` and re-reads the last
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
  (`<name>.txt`, labelled "Them"/"Me"). The live version stays as `<name>.live.txt`. It runs in the background and
  takes a few minutes for long calls; switch it off with the checkbox in the menu.
- **Speakers:** with "Recognize speakers" on, the call-audio track is analysed locally (FluidAudio) and its lines are
  labelled "Speaker 1", "Speaker 2"… instead of "Them"; your microphone stays "Me". For "Transcribe file…" every voice,
  including yours, gets a Speaker label. Use **Rename speaker…** to replace a label with a name; the saved `.txt`
  is updated. Speaker models (small, a few hundred MB at most) download on first use. Voices are matched only
  within one recording; no voice profiles are stored. Limits: it works per transcript segment, so a quick
  interjection inside a long segment may be attributed to the main speaker, and several people sharing your
  microphone in one room all show as "Me" (use "Transcribe file…" on the MP3 to split them).
- **Summary:** when a call has been transcribed (a plain "Record to MP3" is transcribed automatically afterwards),
  the app writes `<name>.summary.md` (summary, key points, decisions, action items, open questions) using a local
  model served by [Ollama](https://ollama.com), so nothing leaves your Mac. One-time setup:
  `brew install ollama && brew services start ollama && ollama pull qwen2.5:7b` (`qwen2.5:14b` is better if you have
  16 GB+ RAM). Without Ollama, **Copy for Claude** puts the instructions + transcript on the clipboard to paste into a
  Claude chat. Turn it off with the "Summarize each call" checkbox.
- **Topic:** type what the call is about into the *Topic* field before (or during) the call. The summary is then organised
  around it, with off-topic items mentioned briefly, and the topic is printed at the top of `<name>.summary.md`.
- **Screenshots:** while recording, press **⌃⌥S** (or the button) when someone shares a slide or a picture. The screen under your
  mouse is saved in `<name>_screens/` next to the recording. After the call a local vision model in Ollama describes each
  image (`ollama pull qwen2.5vl:7b`; llama3.2-vision, gemma3 and llava also work), the descriptions are added to the transcript as
  `[mm:ss] [Screen] …` lines (also saved as `<name>.screens.txt`) and used in the summary. Without a vision model the images are
  still saved. Images are only ever sent to Ollama on 127.0.0.1. Screenshots of slides can contain confidential data: they are kept
  with the recording, so treat that folder accordingly.
- **Silence and typing:** very short phrases such as "Thank you" or "Danke" that Whisper invents on keyboard noise are dropped when the
  audio under them is that quiet; a real, audible "thank you" is kept. Details are in `live-debug.log` ("dropped quiet filler").
- The app is ad-hoc signed. If macOS forgets the Screen Recording permission after a rebuild,
  remove the old entry in Privacy settings and add the app again.
- Wearing headphones avoids the other side leaking into your mic track.
- **Privacy:** everything runs on your Mac; see [`SECURITY.md`](SECURITY.md) for the data flow, the review findings and how to verify (`./check-network.sh`, the **Offline mode** checkbox).
