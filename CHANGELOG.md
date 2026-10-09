# Versions

Version = **1.MINOR.PATCH**, counted from the git history:

- the first commit is **1.0.0**;
- every commit that adds a user-visible capability raises MINOR (and resets nothing: PATCH keeps counting all other commits);
- every other commit (fixes, polish, wording, docs, hotkey/layout tweaks) raises PATCH;
- **build** = number of commits at release.

So 1.22.27 (build 50) = 22 feature commits + 27 fix/polish commits after the first one.
When you release: count again, update `Info.plist`, `Sources/CallRecorder/AppInfo.swift` and `windows/package.json`
(+ `windows/src/lib/appinfo.js` for the build number); a test checks that they agree.

## Feature commits (MINOR)

| # | Commit | What |
|---|--------|------|
| 1 | 5986a0e | Dock icon, launch window, menu-bar item |
| 2 | 531e317 | `update.sh` |
| 3 | 4845b45 | Local Whisper engine (files + live) |
| 4 | d2c55a7 | Streaming live transcript |
| 5 | 6530c15 | Accuracy: large-v3, beam search, VAD, vocabulary |
| 6 | 1b96259 | Transcript check pass after live recording |
| 7 | eae0713 | Speaker recognition |
| 8 | c77a63a | Summaries with local Ollama |
| 9 | b425115 | Recordings in a project folder, one folder per day |
| 10 | a12bb40 | Word-level speaker assignment |
| 11 | bac6354 | Windows version |
| 12 | 6bbd755 | Security review, Offline mode |
| 13 | 95680b2 | Output folder setting, call topic, screenshots |
| 14 | 8c51da6 | Glossary correction |
| 15 | ac27676 | Screenshot of a selected area |
| 16 | 0c1a11e | Double-click updater |
| 17 | f81f95c | One folder per call (audio, raw/fixed transcript, summary, screenshots) |
| 18 | e2f8633 | About box |
| 19 | (tabs commit) | Recorder / Settings / About tabs |
| 20 | (transparency commit) | Window transparency slider |
| 21 | (translation commit) | Live parallel translation pane |
| 22 | (voices commit) | Voice profiles: named speakers are recognised in later calls |
