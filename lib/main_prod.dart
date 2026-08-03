import 'package:marten/app_entrypoint.dart';
import 'package:marten/core/model/environment.dart';

Future<void> main() => runMarten(Environment.prod);
