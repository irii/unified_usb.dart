import 'dart:io';

import 'package:ffigen/ffigen.dart';
import 'package:logging/logging.dart';

void main(List<String> args) {
  final logger = Logger('generate_bindings');

  final libusbInclude = findLibusbIncludeDir(args, logger);

  final yamlFile = File('ffigen.yaml');

  if (!yamlFile.existsSync()) {
    logger.severe('ffigen.yaml not found.');
    exit(1);
  }

  final config = YamlConfig.fromFile(
    yamlFile,
    logger,
  );

  final adapter = config.configAdapter();

  final headerFile = Uri.file('$libusbInclude/libusb.h');
  adapter.headers.entryPoints.add(headerFile);

  adapter.generate();

  logger.info(
    'Generated bindings using libusb include: $libusbInclude',
  );
}

String findLibusbIncludeDir(List<String> args, Logger logger) {
  for (final arg in args) {
    if (arg.startsWith('--libusb-include=')) {
      final path = arg.substring('--libusb-include='.length);
      return validateDirectory(path, 'libusb include directory', logger);
    }
  }

  final envPath = Platform.environment['LIBUSB_INCLUDE'];

  if (envPath != null && envPath.isNotEmpty) {
    return validateDirectory(
      envPath,
      'LIBUSB_INCLUDE',
      logger,
    );
  }

  fail(
    logger,
    'Could not find libusb include directory.\n\n'
    'Provide it using either:\n'
    '  --libusb-include=/path/to/include\n'
    'or:\n'
    '  LIBUSB_INCLUDE=/path/to/include',
  );
}

String validateDirectory(
  String path,
  String source,
  Logger logger,
) {
  final directory = Directory(path);

  if (!directory.existsSync()) {
    fail(
      logger,
      '$source does not exist: $path',
    );
  }

  final header = File(
    '${directory.path}${Platform.pathSeparator}libusb.h',
  );

  if (!header.existsSync()) {
    fail(
      logger,
      'libusb.h not found in $source: ${directory.path}',
    );
  }

  return directory.absolute.path;
}

Never fail(Logger logger, String message) {
  logger.severe(message);
  exit(1);
}
