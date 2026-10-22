import 'dart:io';

import 'package:marten/core/model/directories.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class ProfilePathResolver {
  const ProfilePathResolver(this._workingDir, {Directory? tempWorkingDir}) : _tempWorkingDir = tempWorkingDir;

  factory ProfilePathResolver.forDirectories(Directories dirs, {required bool isIOS}) {
    return ProfilePathResolver(
      isIOS ? Directory(p.join(dirs.baseDir.path, 'Library', 'Application Support', 'Marten')) : dirs.workingDir,
      tempWorkingDir: isIOS ? dirs.workingDir : null,
    );
  }

  final Directory _workingDir;
  final Directory? _tempWorkingDir;

  Directory get directory => Directory(p.join(_workingDir.path, "configs"));

  File file(String fileName) {
    return File(p.join(directory.path, "$fileName.json"));
  }

  File backupFile(String fileName) => File('${file(fileName).path}.last-good');

  File tempFile(String fileName) =>
      File(p.join((_tempWorkingDir ?? _workingDir).path, 'configs', '$fileName.${const Uuid().v4()}.tmp.json'));
}
