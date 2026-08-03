# Marten

Marten is a cross-platform, bring-your-own-configuration network client built with Flutter. It lets you import and manage connection profiles, select an available endpoint, check reachability, and connect through the native runtime on supported platforms.

The app supports common proxy and tunnel configuration formats, including WireGuard, AmneziaWG, VLESS/Xray, Hysteria2, and configurations that use a WebRTC TURN transport. Marten does not ship with connection profiles or operate network infrastructure; you provide the configuration you are authorized to use.

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

Native builds, including `flutter run`, need the separately maintained `marten-core` runtime artifacts for the target platform. They are intentionally not included in this repository, so a fresh clone is sufficient for Flutter and Dart work but not for running or packaging a native build. The platform preparation targets in [Makefile](Makefile) show where those artifacts are expected during an authorized release build.

## Android push setup

Android push support is optional. The Firebase configuration file `android/app/google-services.json` is intentionally excluded from the repository. If it is not supplied in a local build, push registration is disabled gracefully and the rest of the app continues to work.

## Privacy

Marten processes the profiles you import on your device in order to establish the requested connection. Connection endpoints, credentials, and subscription links can be sensitive: do not include them in issues, logs, screenshots, or pull requests. The project does not bundle a profile provider or a telemetry requirement.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request, and use the repository's private vulnerability reporting flow for security-sensitive findings as described in [SECURITY.md](SECURITY.md).

## License and attribution

Marten is distributed under the [Hiddify Extended GNU General Public License v3](LICENSE.md). It is derived from hiddify-app; attribution and modification notes are in [NOTICE.md](NOTICE.md).
