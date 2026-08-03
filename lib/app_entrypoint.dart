import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marten/bootstrap.dart';
import 'package:marten/core/model/environment.dart';

Future<void> runMarten(Environment environment) {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent),
  );

  return lazyBootstrap(widgetsBinding, environment);
}
