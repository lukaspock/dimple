# Notchy – Architecture (contract between work packages)

Project root: this repository (Xcode project `Notchy.xcodeproj` generated from `project.yml`, target `Notchy`, sources in `Notchy/`)
Swift 5.9 language mode, macOS 14 deployment target, LSUIElement, code/comments/names in English.

## Folder layout (inside Notchy/Notchy/)
- App/            NotchyApp (AppDelegate-based), MenuBarController (status item: "Beenden", "Beim Login starten" via SMAppService)
- Notch/          NotchPanel, NotchWindowController, NotchGeometry, NotchShape, NotchRootView, NotchViewModel
- Module/         NotchModule.swift (FIXED CONTRACT, do not change signatures), ModuleRegistry.swift
- Modules/Spotify/ SpotifyModule, SpotifyService (AppleScript), SpotifyCompactViews, SpotifyExpandedView, EqualizerView, ArtworkColor
- Resources: Info.plist, Notchy.entitlements, Assets.xcassets

## Contract
`Module/NotchModule.swift` defines the protocol. Core (Notch/, ModuleRegistry) only talks to modules through it.
Adding a module later = new folder in Modules/ + one line in `ModuleRegistry.makeDefaultModules()`.

States: hidden / compact / expanded (`NotchDisplayState`). Core owns hover logic (expand on hover with spring,
collapse ~0.5 s after hover ends) and geometry. Modules only render content and report `isActive`.

## Design language
Very minimalistic, pure black (#000) surface, SF system font, white / white-opacity text, no borders, no gradients on chrome.
Animations: only soft springs (response ~0.35, dampingFraction ~0.8) and short easeOut fades. No bouncing gimmicks.
Compact: small side wings next to the notch, cover left (rounded, ~ 20pt), equalizer right.
Expanded: ~ 380x170pt content area under/around the notch, generous spacing, thin 3pt progress bar, SF Symbols (backward.fill, play.fill, pause.fill, forward.fill).

## Spotify
No MediaRemote. AppleScript via NSAppleScript on ONE serial background queue (NSAppleScript is not thread-safe).
Only talk to Spotify if `NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")` is non-empty
(otherwise AppleScript would launch it). Observe DistributedNotificationCenter "com.spotify.client.PlaybackStateChanged" for instant updates,
plus a light timer (~1 s while expanded/playing, to interpolate progress locally) .
Artwork: `artwork url of current track` -> URLSession download, cached by URL. Accent color derived from the cover (average/dominant, boosted saturation/brightness).
