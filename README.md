# CallRecorder (macOS 15+)

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
| 3. Live transcript + MP3 | **⌃⌥L**. Shows "Me" / "Them" lines live; `.txt` and `.mp3` saved on stop. |

Files go to `~/Documents/CallRecordings/`. Pick the language (English, Deutsch, Русский) in the menu before recording.

## Permissions (first launch)

- **Screen & System Audio Recording**: required to capture what you hear. Approve it in
  System Settings → Privacy & Security, then relaunch the app. No video is recorded.
- **Microphone** and **Speech Recognition**: approve the prompts.

## Notes

- Everyone on the call must be fine with being recorded; check your company's and local rules.
- Two transcription engines (menu → Engine): **Whisper** (local whisper.cpp, default once set up; very good
  for English, German and Russian, plus "Auto-detect" for mixed-language calls) and **Apple** (built-in,
  no setup, weaker).
- **Live mode (⌃⌥L)** keeps the Whisper model loaded in a small local `whisper-server` and re-reads the last
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
- **Transcript check:** after a live recording the app re-transcribes the call-audio track and your microphone
  track separately with the accurate model, which fills in words the live view missed, and replaces the transcript
  (`<name>.txt`, labelled "Them"/"Me"). The live version stays as `<name>.live.txt`. It runs in the background and
  takes a few minutes for long calls; switch it off with the checkbox in the menu.
- The app is ad-hoc signed. If macOS forgets the Screen Recording permission after a rebuild,
  remove the old entry in Privacy settings and add the app again.
- Wearing headphones avoids the other side leaking into your mic track.
