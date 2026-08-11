# Development

## Prerequisites

Install the Flutter SDK version specified in [../pubspec.yaml](../pubspec.yaml). Platform builds also need the normal tooling for their target, such as Android Studio for Android or Xcode for iOS and macOS.

Fetch packages from the repository root:

```sh
flutter pub get
```

After supplying the separately maintained native runtime artifacts for the target platform, run the application on a connected device or selected desktop target:

```sh
flutter run
```

## Quality checks

Run static analysis and the Dart/Flutter test suite before submitting a change:

```sh
flutter analyze
flutter test
```

## Code generation

The project uses build_runner for generated models and related source, and Slang for translations. Regenerate affected outputs with:

```sh
dart run build_runner build --delete-conflicting-outputs
dart run slang
```

Some generated protocol bindings reflect interfaces provided by the native runtime. Regenerating those bindings requires the separately maintained runtime sources and protocol tooling; see the corresponding targets in [../Makefile](../Makefile). Do not replace checked-in generated files with output from a different runtime revision.

## Native artifacts and release builds

This repository deliberately excludes `marten-core` and release runtime artifacts such as Android AARs and iOS frameworks. They must be obtained or built through the authorized release process before packaging a native release. The preparation targets in the [Makefile](../Makefile) identify the required integration points.

Firebase configuration files are also intentionally absent. They are only needed for optional Android push support and opt-in Crashlytics reporting; builds without them should keep both integrations disabled while preserving normal app behavior.

## Keeping a working tree safe

Never commit credentials, imported profiles, subscription URLs, signing material, Firebase configuration files, or local runtime artifacts. Check `git status` before committing and keep generated changes limited to the generators you ran.
