# Marten

Marten is a cross-platform, bring-your-own-configuration network client built with Flutter. It lets you import and manage connection profiles, select an available endpoint, check reachability, and connect through the native runtime on supported platforms.

The app source is published at [Cr0me1ve/marten-app](https://github.com/Cr0me1ve/marten-app).

[![Android](https://github.com/Cr0me1ve/marten-app/actions/workflows/android.yml/badge.svg)](https://github.com/Cr0me1ve/marten-app/actions/workflows/android.yml)

The app supports common proxy and tunnel configuration formats, including WireGuard, AmneziaWG, VLESS/Xray, Hysteria2, and configurations that use a WebRTC TURN transport. Marten does not ship with connection profiles or operate network infrastructure; you provide the configuration you are authorized to use.

Marten is developed alongside [marten-core](https://github.com/Cr0me1ve/marten-core) and [marten-sing-box](https://github.com/Cr0me1ve/marten-sing-box). Those repositories provide the native runtime and networking engine used by the app.

## Features

- Import profiles from links, files, QR codes, or the clipboard.
- Keep several subscriptions and choose profiles from a single client.
- Test endpoint latency and refresh subscriptions.
- Run on Android, iOS, macOS, Windows, and Linux, with platform-specific capabilities where available.
- Store sensitive local profile data using the platform security facilities where supported.

## Getting started

Install the Flutter SDK version declared in [pubspec.yaml](pubspec.yaml), then fetch dependencies, generate source, and run the usual Dart checks:

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart run slang
flutter analyze
flutter test
```

With the native runtime artifacts for a target platform supplied separately, run the app with:

```sh
flutter run
```

More detail for contributors is in [docs/development.md](docs/development.md). For a high-level view of the client, see [docs/architecture.md](docs/architecture.md).

## Native runtime artifacts

Native builds, including `flutter run`, need separately built artifacts from [marten-core](https://github.com/Cr0me1ve/marten-core) and its [marten-sing-box](https://github.com/Cr0me1ve/marten-sing-box) dependency. Native artifacts are intentionally not committed here, so a fresh clone is sufficient for Flutter and Dart work but not for running or packaging a native build. The platform preparation targets in [Makefile](Makefile) show where those artifacts are expected during a release build.

The public Android workflow downloads a stripped, SHA256-pinned `marten-core.aar` from this repository's dependency release, verifies its embedded revisions, runs the Flutter and Android test suites, and builds an arm64 APK on a GitHub-hosted runner. A `vX.Y.Z` tag publishes the verified APK, checksum, signing-certificate report, and provenance metadata to [GitHub Releases](https://github.com/Cr0me1ve/marten-app/releases). Repository pushes and tags use the stable signing identity stored in GitHub Secrets, and the workflow rejects an unexpected certificate digest. The native core itself is built separately; the public app workflow only packages the pinned artifact.

## Optional Firebase setup

Firebase configuration files are intentionally excluded from the repository. Android push support and privacy-safe Crashlytics reporting are optional; without local Firebase configuration, both integrations are disabled gracefully and the rest of the app continues to work. Crash reporting is also disabled by default at runtime and requires explicit user opt-in.

## Subscription refresh API

`https://api.app.marten.pw` is a public registry for providers who already have an HTTPS subscription URL and want Marten installations to refresh it after a silent push. The registry does not download or proxy the subscription payload. It creates an install link, stores the source URL encrypted, and keeps an owner credential separate from the link shared with subscribers.

Create a channel:

```sh
curl --fail-with-body https://api.app.marten.pw/v1/subscriptions \
  --header 'Content-Type: application/json' \
  --data '{"name":"My subscription","url":"https://provider.example/subscription/token"}'
```

The `url` must use HTTPS. A successful `201` response has this shape:

```json
{
  "subscription": {
    "id": "sub_...",
    "name": "My subscription",
    "status": "active",
    "devices": 0
  },
  "install_url": "https://api.app.marten.pw/install/sub_...",
  "deep_link": "marten://import?...",
  "push_endpoint": "https://api.app.marten.pw/v1/subscriptions/sub_.../devices/push-token",
  "trigger_endpoint": "https://api.app.marten.pw/v1/subscriptions/sub_.../push",
  "owner_token": "mtn_owner_..."
}
```

Save `owner_token` immediately. It is returned only after creation or rotation, is not included in the install link, and must not be given to subscribers. Share `install_url` or `deep_link`; Marten continues to download the original subscription directly from its provider and uses the registry only for push registration.

Request a data-only silent refresh:

```sh
curl --fail-with-body --request POST \
  https://api.app.marten.pw/v1/subscriptions/sub_ID/push \
  --header 'Authorization: Bearer mtn_owner_SECRET'
```

The `202` response contains a push job ID. Its aggregate status can be read with the same owner credential:

```sh
curl --fail-with-body \
  https://api.app.marten.pw/v1/subscriptions/sub_ID/push-jobs/job_ID \
  --header 'Authorization: Bearer mtn_owner_SECRET'
```

Read or replace channel metadata:

```sh
curl --fail-with-body https://api.app.marten.pw/v1/subscriptions/sub_ID \
  --header 'Authorization: Bearer mtn_owner_SECRET'

curl --fail-with-body --request PATCH https://api.app.marten.pw/v1/subscriptions/sub_ID \
  --header 'Authorization: Bearer mtn_owner_SECRET' \
  --header 'Content-Type: application/json' \
  --data '{"name":"Renamed subscription","url":"https://provider.example/subscription/new-token"}'
```

Rotate the owner credential or delete the channel:

```sh
curl --fail-with-body --request POST \
  https://api.app.marten.pw/v1/subscriptions/sub_ID/owner-token/rotate \
  --header 'Authorization: Bearer mtn_owner_OLD_SECRET'

curl --fail-with-body --request DELETE \
  https://api.app.marten.pw/v1/subscriptions/sub_ID \
  --header 'Authorization: Bearer mtn_owner_SECRET'
```

The service accepts one owner-triggered refresh per channel every 30 seconds and at most 100 per UTC day. Creation is limited to five requests per source IP per hour; device registration is limited to ten requests per source IP and thirty per channel per minute. A limited request returns `429`, `Retry-After`, and a JSON `scope`. Missing or invalid owner credentials return `401`, while unknown or deleted channels return `404`.

Marten registers and unregisters its FCM token automatically. The registration endpoint is intentionally device-facing: callers must send `X-Device-ID`, `X-Client-Secret`, and an opaque per-profile `push_binding_id`. Push messages contain only a refresh type, binding ID, reason, and timestamp; subscription URLs, configurations, and credentials are never placed in a push payload.

## Privacy

Marten processes the profiles you import on your device in order to establish the requested connection. Connection endpoints, credentials, and subscription links can be sensitive: do not include them in issues, logs, screenshots, or pull requests. The project does not bundle a profile provider, Firebase Analytics, tracking, or a telemetry requirement.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request, and use the repository's private vulnerability reporting flow for security-sensitive findings as described in [SECURITY.md](SECURITY.md).

## License and attribution

Marten is distributed under the [Hiddify Extended GNU General Public License v3](LICENSE.md). It is derived from hiddify-app; attribution and modification notes are in [NOTICE.md](NOTICE.md).
