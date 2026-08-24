# Sanshuai Player

A native iPhone and iPad player for personal music collections. It connects only to local files and music servers that users own, control, or are authorized to access. It does not provide, host, aggregate, or distribute music content.

<p align="center">
  <img src="MusicPlayer/Resources/Assets.xcassets/AppIcon.appiconset/HimhuuMusic-ArchivePlayer-AppIcon-v4.png" width="144" alt="Sanshuai Player app icon">
</p>

## Features

- OpenSubsonic / Subsonic support for Navidrome, Airsonic, Gonic, and other compatible servers
- Jellyfin libraries, search, favorites, playlists, lyrics, and playback progress sync
- Local and SMB imports through the system file picker, including metadata, artwork, and lyrics extraction
- Multiple music sources with independent credentials, connection testing, editing, and switching
- Native AVPlayer queues, background audio, Lock Screen, headset, and CarPlay controls
- Original Metal visual effects driven by real-time PCM audio analysis
- Privacy-first credential storage in Keychain, with no advertising or analytics SDKs

## Requirements

- macOS with Xcode 26 or later
- iOS / iPadOS 17.0+
- Swift 6
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the project from `project.yml`

## Build

```sh
git clone https://github.com/xiaosongji/SanshuaiPlayer.git
cd SanshuaiPlayer

# Optional: regenerate the Xcode project
brew install xcodegen
xcodegen generate

# Unsigned build verification
xcodebuild -project MusicPlayer.xcodeproj \
  -scheme MusicPlayer \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

You can also open `MusicPlayer.xcodeproj` directly and run it on any installed simulator. Before installing on a physical device, configure your own Bundle ID, Development Team, and signing settings in Xcode.

> `CODE_SIGNING_ALLOWED=NO` is intended only for build verification. An unsigned simulator build may return Keychain error `-34018` because it lacks the required entitlement. Use a normally signed build when testing credential persistence.

## Test

```sh
xcodebuild -project MusicPlayer.xcodeproj \
  -scheme MusicPlayer \
  -destination 'platform=iOS Simulator,name=<your simulator name>' \
  test
```

Live service contract tests use the following environment variables and are skipped when they are not configured:

- `MUSICPLAYER_NAVIDROME_*`
- `MUSICPLAYER_SECONDARY_SUBSONIC_*`
- `MUSICPLAYER_JELLYFIN_*`

Never commit real server addresses, usernames, passwords, certificates, tokens, or unredacted test logs.

## Architecture

```text
SwiftUI Views
  ├─ MusicSourceStore
  ├─ UnifiedLibraryStore
  └─ UnifiedPlaybackController
             │
      MusicSourceProvider
       ├─ OpenSubsonicProvider
       ├─ JellyfinProvider
       ├─ ExistingNASProvider
       ├─ LocalMusicProvider
       └─ MockMusicSourceProvider
```

SwiftUI views depend only on unified domain models, while protocol-specific DTOs and behavior stay behind provider boundaries. See the [architecture](docs/architecture.md), [acceptance matrix](docs/acceptance.md), and [known issues](docs/known-issues.md) for more detail.

## Optional NAS Service

The `server/` directory contains an OwnMusic example service and reusable Navidrome / Caddy deployment templates. The iOS app does not require this service: it can connect directly to an existing OpenSubsonic or Jellyfin instance, or work exclusively with local and SMB imports.

- [General deployment guidance](docs/deployment.md)
- [fnOS / Navidrome example](docs/navidrome-fnos.md)
- [OwnMusic API](docs/backend-api.md)

All examples use placeholder domains and environment variables. Never expose a NAS administration interface directly to the internet.

## Privacy and External Services

The project contains no advertising or analytics SDKs. Requests go to a user-configured music server only when the user connects to it. If lyrics or artwork are missing, the app can send the track title, artist, album, and duration required for matching to LRCLIB or a Chinese lyrics and artwork aggregation service.

See the [privacy notes](docs/privacy.md) and [third-party notices](THIRD_PARTY_NOTICES.md) for details.

## Contributing and Security

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before getting started. Report security concerns privately according to [SECURITY.md](SECURITY.md), and never include real credentials or server details in a public issue.

## License

Source code is available under the [MIT License](LICENSE). See [ASSET_LICENSES.md](ASSET_LICENSES.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the terms that apply to visual assets, third-party projects, and brand identifiers. The MIT License does not grant rights to any Himhuu trademark.

## Official Links

- [Product](https://himhuu.com/apps/sanshuai-player)
- [Privacy Policy](https://himhuu.com/apps/sanshuai-player/privacy)
- [Terms of Use](https://himhuu.com/apps/sanshuai-player/terms)
- [Support](https://himhuu.com/apps/sanshuai-player/support)
