import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/profile/data/profile_path_resolver.dart';

void main() {
  test('iOS canonical profiles use durable storage while parser scratch stays in cache', () async {
    final root = await Directory.systemTemp.createTemp('marten-profile-paths-');
    addTearDown(() => root.delete(recursive: true));
    final base = Directory('${root.path}/shared');
    final working = Directory('${root.path}/shared/Library/Caches/Working');
    final directories = (baseDir: base, workingDir: working, tempDir: working);

    final paths = ProfilePathResolver.forDirectories(directories, isIOS: true);

    expect(paths.directory.path, '${base.path}/Library/Application Support/Marten/configs');
    expect(paths.file('profile-id').path, '${base.path}/Library/Application Support/Marten/configs/profile-id.json');
    final firstScratch = paths.tempFile('profile-id').path;
    final secondScratch = paths.tempFile('profile-id').path;
    expect(firstScratch, startsWith('${working.path}/configs/profile-id.'));
    expect(firstScratch, endsWith('.tmp.json'));
    expect(secondScratch, startsWith('${working.path}/configs/profile-id.'));
    expect(secondScratch, endsWith('.tmp.json'));
    expect(firstScratch, isNot(secondScratch), reason: 'concurrent imports need independent scratch files');
  });

  test('non-iOS profile and scratch paths remain under the working directory', () async {
    final root = await Directory.systemTemp.createTemp('marten-profile-paths-');
    addTearDown(() => root.delete(recursive: true));
    final base = Directory('${root.path}/base');
    final working = Directory('${root.path}/working');
    final directories = (baseDir: base, workingDir: working, tempDir: working);

    final paths = ProfilePathResolver.forDirectories(directories, isIOS: false);

    expect(paths.directory.path, '${working.path}/configs');
    final firstScratch = paths.tempFile('profile-id').path;
    final secondScratch = paths.tempFile('profile-id').path;
    expect(firstScratch, startsWith('${working.path}/configs/profile-id.'));
    expect(firstScratch, endsWith('.tmp.json'));
    expect(secondScratch, startsWith('${working.path}/configs/profile-id.'));
    expect(secondScratch, endsWith('.tmp.json'));
    expect(firstScratch, isNot(secondScratch), reason: 'concurrent imports need independent scratch files');
  });
}
