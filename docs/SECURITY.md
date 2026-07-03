# Security notes — LocalVideo

## Camera credentials

Cameras may require a username/password (`cameras.json` `username`/`password`, or embedded
in `url`). How they're handled:

### Credentials are never placed in a process argv (fixed 2026-07)

**Before:** each camera was demuxed by an `ffmpeg` **subprocess** invoked with the full
`rtsp://user:pass@host/...` URL as a command-line argument. That exposed the password to
**any local process** via `ps`, `pgrep -f`, or Activity Monitor — argv is world-readable to
the same user and trivially greppable.

**Investigation:** ffmpeg's RTSP demuxer has **no** `-user`/`-password`/`-headers`/auth
option (verified on ffmpeg 8.1 / libavformat 62) — credentials can only travel in the URL
userinfo. And the ffmpeg **CLI** can only receive that URL via **argv**: it does not expand
`${ENV}` in `-i`, does not read the input URL from stdin (`-i pipe:` expects media bytes),
and has no response-file/`@argfile` mechanism. So with the ffmpeg subprocess there was no
way to keep credentials off the command line.

**Fix:** the ffmpeg subprocess was replaced with an **in-process libavformat demuxer**
(`Sources/CRTSPDemux/`, driven by `RTSPSource.swift`). The credentialed URL is now passed
directly to `avformat_open_input()` inside the app; it lives **only in the app's memory** and
is never handed to any child process, so it cannot appear in argv / `ps` / Activity Monitor.
The demuxed Annex-B H.264 is byte-identical to what the old `ffmpeg -f h264 -` pipe produced,
so decode/render latency is unchanged (in fact steady-state CPU dropped slightly — no
subprocess pipe-copy overhead).

### Remaining exposure (by design, given the threat model)

- **On disk:** `cameras.json` stores credentials in **plaintext**. It is git-ignored and
  never committed. This is a LAN-only, single-user, personal app on a trusted Mac; disk
  encryption (FileVault) is the expected protection. Not moved to Keychain (yet).
- **In memory:** the URL/credentials exist in the app's address space while running
  (unavoidable — libavformat needs them to authenticate). Readable only by the same user
  with a debugger, i.e. no worse than any app holding a secret.

### Rules for contributors

- Never log, print, or commit real credentials (stderr from the engine is not surfaced;
  `cameras.json` is git-ignored). Mask passwords in any UI/mockup/output (`user:****@host`).
- `Config.save` writes `username`/`password` separately and atomically — never write
  `resolvedURL` (the credential-embedded form) to disk or logs.
