import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS profile migration preserves canonical bytes and survives cache removal', () async {
    final root = Directory.current.path;
    final source = '$root/ios/Shared/FilePath.swift';
    final temporary = await Directory.systemTemp.createTemp('marten-ios-profile-migration-');
    addTearDown(() => temporary.delete(recursive: true));

    final harness = File('${temporary.path}/main.swift');
    final executable = '${temporary.path}/migration-test';
    await harness.writeAsString(r'''
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func requireBytes(_ path: URL, _ expected: Data, _ message: String) throws {
    if try Data(contentsOf: path) != expected { fatalError(message) }
}

let shared = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let manager = FileManager.default
let legacy = shared.appendingPathComponent("Library/Caches/Working/configs", isDirectory: true)
let durable = shared.appendingPathComponent("Library/Application Support/Marten", isDirectory: true)
let durableConfigs = durable.appendingPathComponent("configs", isDirectory: true)
try manager.createDirectory(at: legacy, withIntermediateDirectories: true)

let movedID = "11111111-1111-4111-8111-111111111111"
let conflictID = "22222222-2222-4222-8222-222222222222"
let movedBytes = Data([0, 255, 17, 42, 128, 9])
let staleBytes = Data([3, 3, 3])
let currentBytes = Data([8, 0, 8, 0, 8])
try movedBytes.write(to: legacy.appendingPathComponent("\(movedID).json"))
try staleBytes.write(to: legacy.appendingPathComponent("\(conflictID).json"))
let temporaryBytes = Data("scratch plaintext".utf8)
let temporaryFile = legacy.appendingPathComponent("\(movedID).tmp.json")
try temporaryBytes.write(to: temporaryFile)

try manager.createDirectory(at: durableConfigs, withIntermediateDirectories: true)
try currentBytes.write(to: durableConfigs.appendingPathComponent("\(conflictID).json"))

let returnedRoot = try FilePath.prepareProfileStorage(in: shared)
require(returnedRoot.standardizedFileURL == durable.standardizedFileURL, "returned durable root differs")
try requireBytes(durableConfigs.appendingPathComponent("\(movedID).json"), movedBytes,
                 "migration changed encrypted bytes")
try requireBytes(durableConfigs.appendingPathComponent("\(conflictID).json"), currentBytes,
                 "migration overwrote the existing durable profile")
try requireBytes(legacy.appendingPathComponent("\(conflictID).json"), staleBytes,
                 "existing destination should leave the legacy source intact")
try requireBytes(temporaryFile, temporaryBytes, "temporary profile file should be skipped")
require(!manager.fileExists(atPath: durableConfigs.appendingPathComponent("\(movedID).tmp.json").path),
        "temporary profile file should not enter durable storage")

// A second startup is idempotent and keeps the newer durable generation.
_ = try FilePath.prepareProfileStorage(in: shared)
try requireBytes(durableConfigs.appendingPathComponent("\(movedID).json"), movedBytes,
                 "repeated migration changed the moved profile")
try requireBytes(durableConfigs.appendingPathComponent("\(conflictID).json"), currentBytes,
                 "repeated migration replaced the durable generation")

// iOS may purge Caches after migration; the durable profile set remains readable.
try manager.removeItem(at: shared.appendingPathComponent("Library/Caches", isDirectory: true))
try requireBytes(durableConfigs.appendingPathComponent("\(movedID).json"), movedBytes,
                 "profile was lost when the old cache was removed")
try requireBytes(durableConfigs.appendingPathComponent("\(conflictID).json"), currentBytes,
                 "existing durable profile was lost when the old cache was removed")
''');

    final compile = await Process.run('swiftc', [source, harness.path, '-o', executable]);
    expect(compile.exitCode, 0, reason: '${compile.stderr}\n${compile.stdout}');

    final sharedDirectory = await Directory.systemTemp.createTemp('marten-ios-shared-container-');
    addTearDown(() => sharedDirectory.delete(recursive: true));
    final result = await Process.run(executable, [sharedDirectory.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n${result.stdout}');
  }, skip: !Platform.isMacOS);
}
