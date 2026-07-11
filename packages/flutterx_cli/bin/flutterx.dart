import 'dart:io';

import 'package:flutterx_cli/flutterx_cli.dart';

Future<void> main(List<String> args) async {
  final cli = await buildCli();
  exitCode = await cli.run(args);
}
