# Notchy

A minimal "Dynamic Island" for the MacBook notch, written in Swift / SwiftUI / AppKit.
The island grows out of the notch when something is happening and retracts into it when it is not.

## Modules

| Module | What it does |
| --- | --- |
| Spotify | Cover, equalizer, expanded player with seek, shuffle and transport controls (AppleScript) |
| Now Playing | Everything else that plays on the Mac, e.g. YouTube in a browser, Apple Music, podcasts |
| Timer | Countdown and stopwatch; start via the menu bar or `notchy://timer?minutes=10` |
| Calendar | Heads-up before your next event, list of today's upcoming events (EventKit) |
| Battery | Notices for plugging in, unplugging, low battery and full charge |
| Lock screen | Lock icon in the notch and a music card while the Mac is locked (experimental) |

Adding a module means implementing `NotchModule` (see `Notchy/Module/NotchModule.swift`) and registering it in
`ModuleRegistry.makeDefaultModules()`. See [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- macOS 14 or newer, Apple Silicon or Intel, a Mac with a notch (other Macs get a small pill at the top)
- Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```sh
xcodegen generate
xcodebuild -scheme Notchy -configuration Release -derivedDataPath build-release build
open build-release/Build/Products/Release/Notchy.app
```

The app is signed ad hoc and not notarized. If Gatekeeper complains, right-click the app and choose Open.
On first launch macOS asks for permission to control Spotify (Automation) and to read your calendar.

## Important notes

- **Private APIs.** System-wide Now Playing uses the third-party
  [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (vendored in `Vendor/`, pinned commit,
  reviewed in `Vendor/mediaremote-adapter/REVIEW.md`), which relies on private macOS APIs. The lock screen widgets use
  private SkyLight functions. Both can break with any macOS update. If they are unavailable, the affected features
  simply stay off. This project is not suitable for the Mac App Store.
- **Lock screen is experimental.** It could only be tested in a simulated lock; the real lock screen may behave
  differently, and macOS already shows its own now-playing widget there.
- Only developed and tested on one Mac. Expect rough edges.

## License

MIT, see [LICENSE](LICENSE). Third-party code is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
