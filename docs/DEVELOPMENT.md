# Development notes

Technical details for people working on the code. The user guide is the [README](../README.md).

## Features and how they map to the original

These features work, but still need testing and refinement.

| Feature | iOS implementation |
| --- | --- |
| Word-by-word highlighting | Port of `LyricsAnimator.ts`: NotSung/Active/Sung states, syllable gradients, cubic splines for scale/y-offset/glow, and [spr](https://github.com/Fraktality/spr) springs |
| Per-letter animation | Syllables longer than one second are split into letters with a proximity effect, following `Emphasize.ts` |
| Line blur | Blur increases with distance from the active line (`BlurMultiplier = 1.25`) |
| Duets and backing vocals | Right-aligned `OppositeAligned` lines; each backing-vocal group is its own smaller row under the main line (`bg-line`), so two can follow each other |
| Instrumental breaks | Three animated dots during gaps of at least three seconds |
| Line-synced and static lyrics | `Line` and `Static` lyric types |
| Dynamic background | Port of the extension's Kawarp: the blurred cover warped like liquid by drifting noise, cross-fading from song to song and slowing down on pause. A Metal shader drawn at the original's 300×150 and stretched, so it stays light on battery |
| Big artwork | The quote button at the bottom left swaps the lyrics for the cover, as big as fits, over a flowing nebula in the cover's colours, with the line being sung under it (word by word, like the lyrics). Songs whose lyrics are hidden can show it too, or the nebula alone |
| Skip songs without sync | Optionally skips songs that have no Spicy Lyrics sync (or no word-by-word sync). The next songs in the queue are looked up while the current one plays, so an unsynced song is skipped the moment it starts, together with any unsynced songs right after it; songs you pick or go back to are kept |
| Lyrics ahead of time | The lyrics of the next songs in the queue are fetched while the current one plays, so they show the moment the song changes |
| Lyrics sources | Spicy Lyrics API with [LRCLIB](https://lrclib.net) as a fallback |
| Seeking | Tap a lyric line to seek to it; requires Spotify Premium |
| Track picker | Tap the track header (or the list button) to jump ahead in the queue, replay something from your history, or search; swipe the header sideways to skip. Requires Spotify Premium |
| Own TTML files | Like the extension's Lyrics Manager: pick a `.ttml` file or paste TTML, apply it just once or save it to a library that wins over online sources (*••• → Свой текст (TTML)*) |
| Apple Music style player | Controls fade away while a song plays; landscape and iPad put artwork and controls beside the lyrics |
| Gestures | Swipe the lyrics sideways to change tracks, pinch to resize, long-press a line to seek / copy / share (iOS 18+) |
| iPad | Side-by-side layout in landscape (upright iPad uses the portrait layout: side by side the lyrics column was too narrow), larger lyrics, pointer hover, keyboard shortcuts (space, ⌘← / ⌘→) |
| Floating lyrics (Picture in Picture) | The current line, word by word, in a PiP window over any app; wide, square, portrait or tall; opens out of the lyrics and closes back onto them; starts from *•••* or when leaving the app; play/pause and ±15 s from the window |
| Romanization and translation | On-device: Japanese (with kanji readings), Chinese pinyin, Korean, Cyrillic, Greek; translation under or instead of each line, by Apple Translation on the device (iOS 18+), Google, Yandex or DeepL (your own key) |
| Interface language | English and Russian; follows the phone's language (English otherwise), or pick one in *Settings → Interface* |
| Display modes | Spicy Lyrics' Simple Lyrics Mode, centred lyrics, SF Pro / Rounded / New York |

## Spotify Connection

The app connects through the official **Spotify Web API**:

- OAuth sign-in using Authorization Code + PKCE, without a client secret.
- Requests to `/me/player` every 2 seconds while playing (sooner near the end of a track and
  right after a button press). Between requests, playback position is estimated locally; small
  differences are blended in gradually so words never jump backwards. Some devices (Spotify's own
  phone app) only refresh the position on play, pause and seek: when two reports in a row show a
  playing position that did not move (`frozenReports`), the local clock keeps running and only a
  changed `timestamp` (a seek) moves it. While App Remote is connected it keeps the clock instead and
  the Web API only fills in details (cover, names) and checks that App Remote has not gone stale.
- Transient connection failures (TLS handshake errors, dropped VPN connections) are retried
  on a fresh connection.
- Play/pause, next/previous, and seeking through the Web API; these controls require
  **Spotify Premium**.

### Who can sign in

Spotify keeps every developer app in **Development Mode** unless the developer is an
organization with 250,000+ monthly users, and a Development Mode app accepts at most
**5 allowlisted accounts**; the app owner also needs Premium. The same applies to the iOS SDK.
So the app ships **without a Client ID of its own**: everyone signs in with **their own Client
ID**, and the app walks them through it on first launch (*Settings → Spotify* to change it):

1. You need **Spotify Premium** (Spotify requires it from the owner of a developer app).
2. Open the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), sign in with
   your Spotify account and accept the terms.
3. **Create app**: any name and description, website empty, redirect URI
   `spicylyrics-ios://callback` (press **Add**), tick **Web API**, accept, **Save**.
4. **Settings → User Management → Add new user** with your Spotify account's email
   (up to five people can share your Client ID this way).
5. **Basic Information → Client ID**: copy it (not the client secret) and paste it into the app.

If an account that isn't in your app's User Management list signs in, Spotify answers 403; the
app then explains how to add it. A quota 429 (`QUOTA_EXCEEDED`) is reported too.

## Lyrics Source: Spicy Lyrics Key

- **With a key (recommended):** obtain a client key (`sl_pk_…`) from
  [Spicy Lyrics Developers](https://developers.spicylyrics.org) and enter it under
  *Settings → Lyrics Sources*. The app uses `GET /v1/lyrics/{trackId}`, as the Android app does.
- **Without a key:** the app sends a `POST /query` request using your Spotify token,
  following the Spicetify extension. SLObjPack responses are decoded on the device.
  The server may reject tokens from third-party apps. If that happens, the app prompts
  you to add a key and falls back to LRCLIB for line-synced lyrics.

## Built-in Key

The Spicy Lyrics client key (`sl_pk_…`) can be built into the app, so users skip that setup and
cannot change it. A Spotify Client ID is never built in (see the README).

- **Locally:** copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` (git-ignored)
  and fill it in.
- **GitHub Actions:** add the repository secret `SPICY_LYRICS_KEY`.

`scripts/generate-bundled-keys.sh` turns it into a git-ignored Swift file with the value
XOR-masked, so it is not readable in `Info.plist` or the binary's strings. This only deters
casual inspection: it is a public client key that the app sends over the network anyway.
Never put a Spicy Lyrics secret key (`sl_sk_…`) there.

## Building

Requires a Mac with Xcode 16+ targeting iOS 17+, **or** GitHub Actions.
Build and installation paths are experimental at this stage.

### On a Mac

```bash
brew install xcodegen
xcodegen generate
open SpicyLyrics.xcodeproj
```

Select your development team in Xcode under **Signing & Capabilities**. If the bundle
identifier is unavailable, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.
Then build and run the app on your iPhone.

### Without a Mac: GitHub Actions and Sideloading

The workflow in `.github/workflows/ios-build.yml` builds an **unsigned** IPA on a macOS
runner. What it publishes depends on how it runs:

| Trigger | Channel | Result |
| --- | --- | --- |
| Pull request | `pr` | Compile check; IPA only as a run artifact |
| Push or merge to `main` | `alpha` | Pre-release `vX.Y.Z-alpha.N` under *Releases* (the last 10 are kept) |
| *Actions → Build iOS app → Run workflow* on `main` | `release` | Stable release `vX.Y.Z` under *Releases* |

Versioning:

- Stable versions are git tags `vX.Y.Z`. A manual run raises the latest one by the chosen
  part (`patch` by default, or `minor` / `major`), or uses the exact version you type in.
- Alphas carry the version of the next patch release plus the run number, e.g. `v0.1.1-alpha.57`.
- `MARKETING_VERSION` in `project.yml` is the floor: with no tags yet the first release uses it,
  and raising it (say to `1.0.0`) moves every following build to that line.
- The build number (`CFBundleVersion`) is the workflow run number, so it always grows.
- The app shows its version and channel under *Settings → About*.

To install, download the IPA from the release (or the run's artifacts) and sign it with
[Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io) using your Apple ID.
With a free account, the installation has to be refreshed every seven days.

## Project Structure

```text
SpicyLyrics/
  App/          Entry point and lifecycle; polling while the app is open
  Spotify/      OAuth PKCE, Web API, App Remote, player model, and playback clock
  Lyrics/       Models, parsers (Spicy JSON, LRC, TTML), SLObjPack, service, disk cache,
                translation and romanization
  Rendering/    Springs, splines, animator, lyric line rendering, and scrolling
  Background/   Kawarp background and visualizer (Metal)
  PiP/          Floating lyrics window (frames drawn with Core Graphics)
  Support/      Settings, sync log, error reports, update check, fonts, audio route
  Resources/    Localizations (en, ru)
  UI/           Onboarding, now playing screen, playback controls, and settings
cloudflare/     Report server (Worker, D1, R2): see cloudflare/README.md
scripts/        AltStore source generator and tests, build-time key script
.github/        Build and release workflow, report bot (workflow and prompt)
```
