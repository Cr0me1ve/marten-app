# Architecture

Marten is a Flutter application with native platform integrations for connection lifecycle, secure storage, and system tunnel support. It is designed as a client: users import the profiles they want to use, and the application manages those profiles locally.

## Main parts

- `lib/` contains the Flutter UI, state management, profile handling, and client-side configuration models.
- `lib/martencore/` provides the Dart interface to the native runtime and its generated protocol bindings.
- `android/`, `ios/`, `macos/`, `windows/`, and `linux/` contain platform runners and platform-specific integration code.
- `assets/` contains application images, fonts, and translations.
- `test/` contains Dart and Flutter tests.

The UI coordinates imports, profile selection, and connection state. When a connection is requested, the platform layer starts the native runtime and reports status back to Flutter. The runtime is provided by [marten-core](https://github.com/Cr0me1ve/marten-core), which integrates [marten-sing-box](https://github.com/Cr0me1ve/marten-sing-box) for protocol and tunnel work. Native artifacts are built separately and are not committed to this source tree.

## Profiles and local data

Profiles can originate from links, files, QR codes, or the clipboard. Marten keeps the imported data locally and uses platform-backed secure storage where available for sensitive material. The application does not include a profile catalogue or a network service.

## Platform boundaries

Flutter code is shared across platforms. Platform-specific code adapts the runtime to each operating system's networking and lifecycle APIs. This split keeps the UI and profile workflow portable while allowing the connection layer to use the facilities available on each target.

For build and generation guidance, see [development.md](development.md).
