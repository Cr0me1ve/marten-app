import 'dart:io';

import 'package:marten/martencore/core_interface/core_interface.dart';
import 'package:marten/martencore/core_interface/core_interface_desktop.dart';
import 'package:marten/martencore/core_interface/core_interface_mobile.dart';

CoreInterface getCoreInterface() {
  if (Platform.isAndroid || Platform.isIOS) {
    return CoreInterfaceMobile();
  }
  return CoreInterfaceDesktop();
}
