# Security and privacy review

Scope: the Mac app (`Sources/`), the Windows app (`windows/`), their setup scripts and dependencies.
Reviewed on 2026-10-08 by reading all of the code and running the Windows app's tests; the Mac app could not be
compiled or run in that review. This is a code review, not a penetration test.

## Where your audio and text can go

| Data | Where it lives | Leaves the computer? |
|------|----------------|----------------------|
| Call audio and microphone | temporary files (deleted after the MP3 and the check pass), then the MP3 in `CallRecordings/<date>/` | No |
| Transcripts, summaries | `CallRecordings/<date>/*.txt`, `*.summary.md`; `live-debug.log` contains recognised text too | No |
| Speech recognition | `whisper-cli` / `whisper-server` (whisper.cpp), started by the app; server listens on 127.0.0.1 only | No |
| Speaker recognition | Mac: FluidAudio (Core ML). Windows: sherpa-onnx. Both on the CPU/GPU/Neural Engine, in-process | No |
| Summaries | Ollama on 127.0.0.1:11434. An address that is not local is refused (Windows code; the Mac code has a fixed local address) | No |
| Vocabulary list | `vocabulary.txt`; its words are also passed to Whisper on the command line | No |
| Clipboard ("Copy for Claude" / "Copy summary") | only when you press the button | Only if *you* paste it somewhere |

Everything the app does while running is local. The only network traffic is **downloading things once**:

| What | From | When | Contains your data? |
|------|------|------|---------------------|
| Whisper models, VAD model | huggingface.co | `setup-whisper.sh` / `setup-whisper.ps1` | No |
| whisper.cpp, ffmpeg, Ollama, npm and Swift packages | Homebrew, GitHub, winget, npm | setup / update | No |
| Mac speaker models | Hugging Face, fetched by FluidAudio | first speaker recognition | No |
| Windows speaker models (~30 MB) | github.com/k2-fsa/sherpa-onnx releases | first speaker recognition; SHA-256 checked | No |
| Code updates | github.com/maxkerro/call-recorder | `git pull` in `update.sh` / `update.ps1` | No |

A download request reveals that you use these tools (and your IP address) to the server, nothing else.
**Offline mode** (checkbox in both apps) refuses all downloads made by the app itself.

## Findings and what was done

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | Windows: `OLLAMA_HOST` could have pointed the summary at a remote server | Medium | Fixed: non-local addresses are refused and covered by a test |
| 2 | Windows: recordings in `Documents` are usually synced to OneDrive | High on default Windows | Fixed: default is `%USERPROFILE%\CallRecordings`; the window warns if the folder name looks cloud-synced |
| 3 | Windows: speaker models were downloaded without verification, then unpacked | Medium | Fixed: SHA-256 pinned, a mismatch is deleted before use |
| 4 | Windows: Electron/Chromium could make background requests | Low | Fixed: Chromium background networking disabled; every request that is not local file/127.0.0.1 is blocked and logged; navigation and pop-ups denied; sandboxed renderer; IPC accepted only from the app's own page; microphone/screen permission only for the app's own page |
| 5 | `whisper-server.log` may contain recognised text and stayed in the temp folder | Low | Fixed on both: deleted when the server stops |
| 6 | Raw audio left in the temp folder after a crash | Low | Windows: stale session folders removed at start-up. Mac: files are in the per-user temp folder; delete `Call_*.caf` there after a crash |
| 7 | Mac: recording folders were readable by other local users | Low | Fixed: owner-only (0700) |
| 8 | Dependencies could change underneath you (`^` / `from:` ranges) | Medium | Windows: exact versions + `package-lock.json`, `npm ci`. Mac: FluidAudio minimum raised to 0.17.4 (has Offline mode). Commit `Package.resolved` after your next successful build to pin it exactly |
| 9 | No Offline mode | Info | Added to both apps (Mac: FluidAudio's `ModelHub.offlineMode`) |

## What remains your decision

- **Third-party code is trusted, not audited here:** whisper.cpp, ffmpeg, Ollama, FluidAudio, sherpa-onnx, Electron.
  None is known to send data out while processing; verify instead of trusting (below). Use the Ollama *service*
  (`brew services`) or the Windows installer with updates disabled, and never sign in to Ollama's cloud features.
- **Recordings are not encrypted by the app.** Use FileVault (Mac) or BitLocker (Windows), and keep the folder out
  of Time Machine, File History, OneDrive, iCloud and Dropbox if the recordings must not leave the laptop.
- **Clipboard:** Windows clipboard history with "sync across devices" and macOS Universal Clipboard can pass what you
  copied to your other devices. Paste into a Claude chat only what you are willing to share with Anthropic.
- **`live-debug.log`** contains recognised text. It is git-ignored; delete it when you are done debugging.
- **The repository is public.** `.gitignore` excludes `CallRecordings/` and `live-debug.log`; run `git status` before
  every commit and never use `git add -f` on them.
- **Unsigned builds:** the Mac app is ad-hoc signed and the Windows build is unsigned, so nothing protects the app
  file from being replaced by another program running as you. Build from source yourself; enable 2FA on GitHub.
- **Local processes:** `whisper-server` listens on a random port on 127.0.0.1 without a password. Any program
  running as you could ask it to transcribe audio it already holds, but cannot read your recordings through it
  (it could read the files directly anyway).
- **Recording people:** in Germany recording a conversation without everyone's consent can be a criminal offence
  (§ 201 StGB), and voice recordings are personal data under GDPR. This is not legal advice.

## Verify it yourself

1. **Look:** while recording run `./check-network.sh` (Mac) or `windows\check-network.ps1` (Windows). Expected:
   only 127.0.0.1 connections.
2. **Unplug:** switch Wi-Fi off, switch Offline mode on, record, transcribe, summarize. Everything must still work
   (after the first-run downloads).
3. **Block:** on Windows run `windows\block-outbound.ps1` (as Administrator) after the first-run downloads: the
   firewall then cuts the internet for CallRecorder and whisper.cpp. On the Mac use LuLu or Little Snitch and
   deny outgoing connections for `CallRecorder`, `whisper-server`, `whisper-cli`.
4. **Inspect:** `grep -rn "http" Sources windows/src` lists every URL in the code; the only non-local ones are the model
   download addresses above (a test in `windows/test/privacy.test.js` enforces this for the Windows code).

This Claude session works in a separate cloud workspace on the source code only. It never has access to your
recordings, transcripts or logs unless you paste them into the chat.
