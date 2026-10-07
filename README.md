# CallRecorder (macOS 15+)

A menu-bar app that records any call you hear (Teams, Telemost, Skype, Zoom, a browser...)
plus your microphone, and saves one MP3. It also transcribes, using Apple's native Speech framework.

## Build

For the best transcription (recommended), run this once. It installs Whisper and downloads a ~550 MB
model, and all processing stays on your Mac:

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
  no setup, weaker). Live transcript with Whisper updates in ~10 s chunks and skips silence.
- Whisper's live mode uses extra CPU while recording; on Apple Silicon this is fine.
- The app is ad-hoc signed. If macOS forgets the Screen Recording permission after a rebuild,
  remove the old entry in Privacy settings and add the app again.
- Wearing headphones avoids the other side leaking into your mic track.
