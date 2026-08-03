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

  // ---------------------------------------------------------------------------
  // Domain REST endpoints (Phase 3) — match Nest /api/v1/* contracts
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> getMe() =>
      _requestJsonUnwrap(method: 'GET', path: '/api/v1/me');

  Future<List<dynamic>> listFarms() =>
      _requestList(method: 'GET', path: '/api/v1/farms');

  Future<List<dynamic>> listLivestock(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/livestock',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createLivestock(Map<String, dynamic> body) =>
      _requestJsonUnwrap(method: 'POST', path: '/api/v1/livestock', body: body);

  Future<Map<String, dynamic>> updateLivestock(
    String id,
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'PATCH',
        path: '/api/v1/livestock/$id',
        body: body,
      );

  Future<Map<String, dynamic>> deleteLivestock(String id, String reason) =>
      _requestJsonUnwrap(
        method: 'DELETE',
        path: '/api/v1/livestock/$id',
        body: {'reason': reason},
      );

  Future<Map<String, dynamic>> getLivestockDetails(
    String id,
    String farmId,
  ) =>
      _requestJsonUnwrap(
        method: 'GET',
        path: '/api/v1/livestock/$id/details',
        query: {'farm_id': farmId},
      );

  Future<List<dynamic>> listHouses(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/houses',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createHouse(Map<String, dynamic> body) =>
      _requestJsonUnwrap(method: 'POST', path: '/api/v1/houses', body: body);

  Future<Map<String, dynamic>> updateHouse(
    String id,
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'PATCH',
        path: '/api/v1/houses/$id',
        body: body,
      );

  Future<Map<String, dynamic>> deleteHouse(String id) =>
      _requestJsonUnwrap(method: 'DELETE', path: '/api/v1/houses/$id');

  Future<List<dynamic>> listEggs(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/eggs',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createEgg(Map<String, dynamic> body) =>
      _requestJsonUnwrap(method: 'POST', path: '/api/v1/eggs', body: body);

  Future<Map<String, dynamic>> updateEgg(
    String id,
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'PATCH',
        path: '/api/v1/eggs/$id',
        body: body,
      );

  Future<Map<String, dynamic>> deleteEgg(String id) =>
      _requestJsonUnwrap(method: 'DELETE', path: '/api/v1/eggs/$id');

  Future<List<dynamic>> listFeeding(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/feeding',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createFeeding(Map<String, dynamic> body) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/feeding',
        body: body,
      );

  Future<Map<String, dynamic>> deleteFeeding(String id) =>
      _requestJsonUnwrap(method: 'DELETE', path: '/api/v1/feeding/$id');

  Future<List<dynamic>> listMortality(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/mortality',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createMortality(Map<String, dynamic> body) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/mortality',
        body: body,
      );

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

  Future<List<dynamic>> _requestList({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final raw = await _requestJson(
      method: method,
      path: path,
      body: body,
      query: query,
    );
    if (raw['success'] == false) {
      throw StateError(
        (raw['error'] is Map ? raw['error']['message'] : null)?.toString() ??
            'HatchLog API request failed',
      );
    }
    final data = raw.containsKey('data') ? raw['data'] : raw;
    if (data is List) return data;
    if (data is Map && data['items'] is List) return data['items'] as List;
    return const [];
  }

  /// Like [_requestJson] but unwraps the Nest `{ success, data }` envelope
  /// when present, returning `data` directly.
  Future<Map<String, dynamic>> _requestJsonUnwrap({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final raw = await _requestJson(
      method: method,
      path: path,
      body: body,
      query: query,
    );
    return _unwrapEnvelope(raw);
  }

  static Map<String, dynamic> _unwrapEnvelope(Map<String, dynamic> raw) {
    if (raw['success'] == false) {
      throw StateError(
        (raw['error'] is Map ? raw['error']['message'] : null)?.toString() ??
            'HatchLog API request failed',
      );
    }
    if (raw.containsKey('success') && raw.containsKey('data')) {
      final data = raw['data'];
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return raw;
    }
    return raw;
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
      case 'PATCH':
        response = await _http.patch(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        );
      case 'DELETE':
        response = await _http.delete(
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
