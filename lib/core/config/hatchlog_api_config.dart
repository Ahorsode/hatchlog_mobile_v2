import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class HatchlogApiConfig {
  const HatchlogApiConfig({
    required this.baseUrl,
    required this.source,
  });

  static const _definedUrl = String.fromEnvironment('HATCHLOG_API_URL');

  final String baseUrl;
  final HatchlogApiConfigSource source;

  bool get isConfigured => baseUrl.isNotEmpty;

  static HatchlogApiConfig load() {
    final fromEnv = (dotenv.env['HATCHLOG_API_URL'] ?? '').trim();
    if (fromEnv.isNotEmpty) {
      return HatchlogApiConfig(
        baseUrl: _stripTrailingSlash(fromEnv),
        source: HatchlogApiConfigSource.packedAsset,
      );
    }

    final defined = _definedUrl.trim();
    if (defined.isNotEmpty) {
      return HatchlogApiConfig(
        baseUrl: _stripTrailingSlash(defined),
        source: HatchlogApiConfigSource.compileTimeNative,
      );
    }

    debugPrint(
      'WARN: HATCHLOG_API_URL not set — Nest sync transport disabled.',
    );
    return const HatchlogApiConfig(
      baseUrl: '',
      source: HatchlogApiConfigSource.missing,
    );
  }

  static String _stripTrailingSlash(String value) {
    if (value.endsWith('/')) {
      return value.substring(0, value.length - 1);
    }
    return value;
  }
}

enum HatchlogApiConfigSource { packedAsset, compileTimeNative, missing }
