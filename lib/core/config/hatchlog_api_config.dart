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

  /// Farm/commerce data requires Nest. Auth stays on Supabase.
  static HatchlogApiConfig requireConfigured() {
    final config = load();
    if (!config.isConfigured) {
      throw StateError(
        'HATCHLOG_API_URL is required for farm data sync. '
        'Set it in .env.mobile or via --dart-define=HATCHLOG_API_URL=...',
      );
    }
    debugPrint(
      'HatchLog API configured from ${config.source.name}: ${config.baseUrl}',
    );
    return config;
  }

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
      'ERROR: HATCHLOG_API_URL not set — Nest farm data transport unavailable.',
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
