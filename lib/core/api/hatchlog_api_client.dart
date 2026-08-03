import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/hatchlog_api_config.dart';
import '../storage/local_database.dart';

/// NestJS HatchLog API client (Option A).
/// Auth: Supabase access token as Bearer.
class HatchlogApiClient {
  HatchlogApiClient({
    required HatchlogApiConfig config,
    http.Client? httpClient,
  }) : _config = config,
       _http = httpClient ?? http.Client();

  final HatchlogApiConfig _config;
  final http.Client _http;

  static const nestSupportedEntityTypes = {
    'egg_collection',
    'feed_usage',
    'mortality',
  };

  bool get isConfigured => _config.isConfigured;

  bool supportsEntityType(String entityType) =>
      nestSupportedEntityTypes.contains(entityType);

  Future<Map<String, dynamic>> health() async {
    final response = await _http.get(Uri.parse('${_config.baseUrl}/health'));
    return _decodeMap(response);
  }

  Future<Map<String, dynamic>> push({
    required String farmId,
    required List<Map<String, dynamic>> mutations,
  }) async {
    return _requestJson(
      method: 'POST',
      path: '/api/v1/sync/push',
      body: {
        'sync_protocol_version': 1,
        'farm_id': farmId,
        'mutations': mutations,
      },
    );
  }

  Future<Map<String, dynamic>> pull({
    required String farmId,
    String? since,
    int limit = 200,
  }) async {
    final query = <String, String>{
      'farm_id': farmId,
      'limit': '$limit',
      if (since != null && since.isNotEmpty) 'since': since,
    };
    return _requestJson(
      method: 'GET',
      path: '/api/v1/sync/pull',
      query: query,
    );
  }

  Future<Map<String, dynamic>> status({required String farmId}) async {
    return _requestJson(
      method: 'GET',
      path: '/api/v1/sync/status',
      query: {'farm_id': farmId},
    );
  }

  /// Push a single queued worker input via Nest when supported.
  Future<void> pushQueuedInput(PendingSyncInput input) async {
    if (!supportsEntityType(input.inputType)) {
      throw StateError('Entity not supported by Nest API: ${input.inputType}');
    }
    final farmId = (input.payload['farm_id'] ?? '').toString().trim();
    if (farmId.isEmpty) {
      throw StateError('Missing farm_id on pending sync input');
    }

    final result = await push(
      farmId: farmId,
      mutations: [
        {
          'client_id': input.resolvedServerRecordId,
          'entity_type': input.inputType,
          'op': 'upsert',
          'payload': input.payload,
          'client_updated_at': input.createdAt.toUtc().toIso8601String(),
        },
      ],
    );

    final results = (result['results'] as List?) ?? const [];
    if (results.isEmpty) {
      throw StateError('Nest sync push returned no results');
    }
    final first = Map<String, dynamic>.from(results.first as Map);
    final status = first['status']?.toString();
    if (status != 'accepted') {
      throw StateError(
        'Nest sync rejected ${input.inputType}: '
        '${first['error_code'] ?? status} ${first['message'] ?? ''}',
      );
    }
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    if (!_config.isConfigured) {
      throw StateError('HATCHLOG_API_URL is not configured');
    }

    final token = await _requireAccessToken();
    final uri = Uri.parse(
      '${_config.baseUrl}$path',
    ).replace(queryParameters: query);

    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
    };

    late http.Response response;
    switch (method) {
      case 'GET':
        response = await _http.get(uri, headers: headers);
      case 'POST':
        response = await _http.post(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        );
      default:
        throw UnsupportedError('HTTP method not supported: $method');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      debugPrint(
        '[HatchlogApi] $method $path failed '
        '(${response.statusCode}): ${response.body}',
      );
      throw StateError(
        'HatchLog API $method $path failed with ${response.statusCode}',
      );
    }

    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }
    return _decodeMap(response);
  }

  Future<String> _requireAccessToken() async {
    var session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      final refreshed = await Supabase.instance.client.auth.refreshSession();
      session = refreshed.session;
    }
    final token = session?.accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('No Supabase access token available for HatchLog API');
    }
    return token;
  }

  Map<String, dynamic> _decodeMap(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw StateError('Expected JSON object from HatchLog API');
  }
}
