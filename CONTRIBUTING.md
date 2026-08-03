# Contributing to Marten

Thanks for taking the time to contribute. Small, focused pull requests are easiest to review.

## Before you start

- Discuss substantial changes in an issue first.
- Keep changes scoped and explain their user-visible effect.
- Do not commit profiles, subscription links, credentials, signing keys, Firebase configuration, or other secrets. Use redacted examples in tests and documentation.
- Do not add generated build output or locally supplied native runtime artifacts to the repository.

## Development workflow

Set up the Flutter SDK version declared in [pubspec.yaml](pubspec.yaml), then run:

```sh
flutter pub get
flutter analyze
flutter test
```

When a change affects generated Dart code, refresh it before committing:

```sh
dart run build_runner build --delete-conflicting-outputs
dart run slang
```

See [docs/development.md](docs/development.md) for notes on generation and native artifacts.

## Pull requests

Describe the problem, the approach, and how you tested it. Update user-facing documentation when behavior changes. Please keep formatting and naming consistent with the surrounding code, and make sure `flutter analyze` and the relevant tests pass.

For a security issue, do not open a public issue or pull request. Follow [SECURITY.md](SECURITY.md) instead.
