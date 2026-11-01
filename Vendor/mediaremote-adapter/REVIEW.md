# Security review: mediaremote-adapter @ 0e82bf1

Reviewed 2026-11-01, full read of `bin/mediaremote-adapter.pl`, `CMakeLists.txt`, `Makefile`, `scripts/*.sh`,
and every file in `src/adapter`, `src/private`, `src/utility`, `include` (the `src/test` client was skimmed only;
it is built by CMake but NOT shipped in the app).

**Verdict: no findings. Safe to bundle.**

## What it executes
- `bin/mediaremote-adapter.pl` (run as `/usr/bin/perl script framework <fn> ...`): validates args, `dl_load_file`s the
  framework, then calls one exported C symbol (`adapter_stream_env`, `adapter_get_env`, `adapter_send_env`, ...).
  Parameters are passed to the framework through `MEDIAREMOTEADAPTER_*` environment variables. Function names are
  whitelisted; options are regex-validated. No `system`, backticks, `eval` of input, or network use.
- Framework (ObjC, ARC): dlopen-style loads Apple's private
  `/System/Library/PrivateFrameworks/MediaRemote.framework` via `CFBundle` and resolves 11 `MRMediaRemote*` functions
  (get now-playing info/PID/client/isPlaying, send command, set elapsed time/shuffle/repeat/speed, register for notifications).
- The only subprocess spawn is `NSTask` in `src/adapter/test.m`, used by the `test` function with a caller-supplied
  `MEDIAREMOTEADAPTER_TEST_CLIENT_PATH`. Notchy never calls `test` with a client path and does not ship the test client.

## What it reads
- Now Playing metadata (title, artist, album, duration, elapsed, artwork bytes, bundle ids, PID) via MediaRemote and
  `NSRunningApplication` (PID to bundle id). Environment variables prefixed `MEDIAREMOTEADAPTER_` and `ADAPTER_TEST_MODE`.
- No file reads of user data.

## Network / filesystem
- No sockets, `NSURLSession`, `curl`, `http` calls. Grep for `NSURLSession|NSURLConnection|socket|CFStream|curl|system(|popen|exec|posix_spawn|fopen|writeToFile|NSFileManager`
  across non-test sources: only `NSTask` in `test.m` (above). The one `https://apple.com` string is a fixture in a debug self-test of the JSON serializer.
- Writes only to stdout/stderr (JSON lines / error text). Nothing is written to disk.
- Outputs raw artwork as base64 in JSON (can be several hundred KB per line); consumer must buffer lines.

## Other notes
- No obfuscated code, no binary blobs in the repo. Build is plain CMake, with an ad-hoc `codesign` post-build step.
- It works because `/usr/bin/perl` is an Apple platform binary, which MediaRemote (macOS 15.4+) still entitles. It relies on a private API, so a future macOS update can break it; Notchy treats it as optional (`isAvailable`).
- Control commands (`send`, `seek`, `shuffle`, `repeat`, `speed`) act on the *system* now-playing app.
