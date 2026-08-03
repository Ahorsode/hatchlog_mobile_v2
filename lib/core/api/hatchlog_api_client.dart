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

  /// Outbox types routed to Nest domain REST (not sync protocol).
  static const nestCommerceInputTypes = {
    'sales_invoice',
    'farm_gate_sale',
    'expense_allocation',
    'inventory_item',
    'inventory_reorder_update',
  };

  /// Worker log mutations + farm/sales settings routed to Nest domain REST.
  static const nestMutationInputTypes = {
    'worker_log_update',
    'worker_log_delete',
    'farm_settings_update',
    'sales_settings_update',
  };

  bool get isConfigured => _config.isConfigured;

  bool supportsEntityType(String entityType) =>
      nestSupportedEntityTypes.contains(entityType);

  bool supportsCommerceInputType(String entityType) =>
      nestCommerceInputTypes.contains(entityType);

  bool supportsMutationInputType(String entityType) =>
      nestMutationInputTypes.contains(entityType);

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

  Future<Map<String, dynamic>> updateFeeding(
    String id,
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'PATCH',
        path: '/api/v1/feeding/$id',
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

  Future<Map<String, dynamic>> updateMortality(
    String id,
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'PATCH',
        path: '/api/v1/mortality/$id',
        body: body,
      );

  Future<Map<String, dynamic>> deleteMortality(String id) =>
      _requestJsonUnwrap(method: 'DELETE', path: '/api/v1/mortality/$id');

  // --- Commerce / finance / health (Nest domain REST) ---

  Future<List<dynamic>> listInventory(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/inventory',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createInventory(Map<String, dynamic> body) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/inventory',
        body: body,
      );

  Future<Map<String, dynamic>> updateInventory(
    String id,
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'PATCH',
        path: '/api/v1/inventory/$id',
        body: body,
      );

  Future<Map<String, dynamic>> deleteInventory(
    String id,
    String farmId, {
    String? reason,
  }) =>
      _requestJsonUnwrap(
        method: 'DELETE',
        path: '/api/v1/inventory/$id',
        query: {'farm_id': farmId},
        body: {if (reason != null && reason.isNotEmpty) 'reason': reason},
      );

  Future<List<dynamic>> listCustomers(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/customers',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createCustomer(Map<String, dynamic> body) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/customers',
        body: body,
      );

  Future<Map<String, dynamic>> updateCustomer(
    String id,
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'PATCH',
        path: '/api/v1/customers/$id',
        body: body,
      );

  Future<Map<String, dynamic>> deleteCustomer(String id, String farmId) =>
      _requestJsonUnwrap(
        method: 'DELETE',
        path: '/api/v1/customers/$id',
        query: {'farm_id': farmId},
      );

  Future<List<dynamic>> listSuppliers(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/suppliers',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createSupplier(Map<String, dynamic> body) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/suppliers',
        body: body,
      );

  Future<Map<String, dynamic>> updateSupplier(
    String id,
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'PATCH',
        path: '/api/v1/suppliers/$id',
        body: body,
      );

  Future<List<dynamic>> listSales(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/sales',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createSale(Map<String, dynamic> body) =>
      _requestJsonUnwrap(method: 'POST', path: '/api/v1/sales', body: body);

  Future<Map<String, dynamic>> deleteSale(
    String id,
    String farmId, {
    String? reason,
  }) =>
      _requestJsonUnwrap(
        method: 'DELETE',
        path: '/api/v1/sales/$id',
        query: {'farm_id': farmId},
        body: {if (reason != null && reason.isNotEmpty) 'reason': reason},
      );

  Future<List<dynamic>> listExpenses(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/expenses',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createExpense(Map<String, dynamic> body) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/expenses',
        body: body,
      );

  Future<Map<String, dynamic>> deleteExpense(
    String id, {
    required String farmId,
    required String reason,
  }) =>
      _requestJsonUnwrap(
        method: 'DELETE',
        path: '/api/v1/expenses/$id',
        body: {'farm_id': farmId, 'reason': reason},
      );

  Future<List<dynamic>> listOrders(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/orders',
        query: {'farm_id': farmId},
      );

  Future<List<dynamic>> listIsolationRooms(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/isolation-rooms',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createIsolationRoom(
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/isolation-rooms',
        body: body,
      );

  Future<Map<String, dynamic>> listHealthSchedules(String farmId) =>
      _requestJsonUnwrap(
        method: 'GET',
        path: '/api/v1/health-schedules',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createHealthSchedules(
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/health-schedules',
        body: body,
      );

  Future<List<dynamic>> listHealthInventory(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/health-inventory',
        query: {'farm_id': farmId},
      );

  Future<List<dynamic>> listFeedFormulations(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/feeding/feed-formulations',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createFeedFormulation(
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/feeding/feed-formulations',
        body: body,
      );

  Future<Map<String, dynamic>> deleteFeedFormulation(
    String id,
    String farmId,
  ) =>
      _requestJsonUnwrap(
        method: 'DELETE',
        path: '/api/v1/feed-formulations/$id',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> getFarmSettings(String farmId) =>
      _requestJsonUnwrap(
        method: 'GET',
        path: '/api/v1/farms/$farmId/settings',
      );

  Future<Map<String, dynamic>> updateFarm(
    String farmId,
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'PATCH',
        path: '/api/v1/farms/$farmId',
        body: body,
      );

  Future<Map<String, dynamic>> updateFarmSettings(
    String farmId,
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'PATCH',
        path: '/api/v1/farms/$farmId/settings',
        body: body,
      );

  Future<Map<String, dynamic>> getSalesSettings(String farmId) =>
      _requestJsonUnwrap(
        method: 'GET',
        path: '/api/v1/farms/$farmId/sales-settings',
      );

  Future<Map<String, dynamic>> updateSalesSettings(
    String farmId,
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'PATCH',
        path: '/api/v1/farms/$farmId/sales-settings',
        body: body,
      );

  Future<List<dynamic>> listEggCategories(String farmId) => _requestList(
        method: 'GET',
        path: '/api/v1/egg-categories',
        query: {'farm_id': farmId},
      );

  Future<Map<String, dynamic>> createEggCategory(Map<String, dynamic> body) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/egg-categories',
        body: body,
      );

  Future<Map<String, dynamic>> transferToIsolation(
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/isolation/transfer',
        body: body,
      );

  Future<Map<String, dynamic>> returnFromIsolation(
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/isolation/return',
        body: body,
      );

  Future<Map<String, dynamic>> logIsolationMortality(
    Map<String, dynamic> body,
  ) =>
      _requestJsonUnwrap(
        method: 'POST',
        path: '/api/v1/isolation/mortality',
        body: body,
      );

  /// Push a single queued worker input via Nest when supported.
  Future<void> pushQueuedInput(PendingSyncInput input) async {
    if (supportsCommerceInputType(input.inputType)) {
      await pushCommerceQueuedInput(input);
      return;
    }
    if (supportsMutationInputType(input.inputType)) {
      await pushMutationQueuedInput(input);
      return;
    }
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

  /// Map worker-log / settings outbox payloads onto Nest domain REST.
  Future<void> pushMutationQueuedInput(PendingSyncInput input) async {
    switch (input.inputType) {
      case 'worker_log_update':
        await _pushNestWorkerLogUpdate(input);
      case 'worker_log_delete':
        await _pushNestWorkerLogDelete(input);
      case 'farm_settings_update':
        await _pushNestFarmSettingsUpdate(input);
      case 'sales_settings_update':
        await _pushNestSalesSettingsUpdate(input);
      default:
        throw StateError(
          'Mutation type not supported by Nest: ${input.inputType}',
        );
    }
  }

  Future<void> _pushNestWorkerLogUpdate(PendingSyncInput input) async {
    final payload = input.payload;
    final recordType = (payload['record_type'] ?? '').toString().trim();
    final recordId = (payload['record_id'] ?? input.resolvedServerRecordId)
        .toString()
        .trim();
    if (recordId.isEmpty) {
      throw StateError('Missing record_id on worker_log_update');
    }

    switch (recordType) {
      case 'egg_collection':
        final crates = _asDouble(payload['crates']);
        final singleEggs = _asInt(payload['single_eggs']);
        final eggsPerCrate = _asInt(payload['eggs_per_crate'], fallback: 30);
        final payloadEggs = _asInt(payload['eggs_collected']);
        final eggsCollected = payloadEggs > 0
            ? payloadEggs
            : (crates * eggsPerCrate).round() + singleEggs;
        final logDate = _optionalString(payload['log_date']);
        await updateEgg(recordId, {
          'eggsCollected': eggsCollected,
          'unusableCount': _asInt(payload['unusable_count']),
          if (_optionalString(payload['quality_grade']).isNotEmpty)
            'qualityGrade': payload['quality_grade'],
          'isSorted': payload['is_sorted'] == true || payload['is_sorted'] == 1,
          'smallCount': _asInt(payload['small_count']),
          'mediumCount': _asInt(payload['medium_count']),
          'largeCount': _asInt(payload['large_count']),
          if (logDate.isNotEmpty) 'logDate': logDate,
        });
      case 'feed_usage':
        final logDate = _optionalString(payload['log_date']);
        final feedTypeId = _optionalString(payload['feed_type_id']);
        final formulationId = _optionalString(payload['formulation_id']);
        await updateFeeding(recordId, {
          'amountConsumed':
              _asDouble(payload['amount_consumed'] ?? payload['bags']),
          if (logDate.isNotEmpty) 'logDate': logDate,
          'feedTypeId': feedTypeId.isEmpty ? null : feedTypeId,
          'formulationId': formulationId.isEmpty ? null : formulationId,
        });
      case 'mortality':
        final logDate = _optionalString(payload['log_date']);
        final reason = _optionalString(payload['reason']);
        final category = _optionalString(payload['category']);
        final subCategory = _optionalString(payload['sub_category']);
        await updateMortality(recordId, {
          'count': _asInt(payload['count']),
          if (reason.isNotEmpty) 'reason': reason,
          if (category.isNotEmpty) 'category': category,
          if (subCategory.isNotEmpty) 'subCategory': subCategory,
          if (logDate.isNotEmpty) 'logDate': logDate,
        });
      default:
        throw StateError('Unsupported worker log update type: $recordType');
    }
  }

  Future<void> _pushNestWorkerLogDelete(PendingSyncInput input) async {
    final payload = input.payload;
    final table = (payload['table'] ?? '').toString().trim();
    final recordId = (payload['record_id'] ?? input.resolvedServerRecordId)
        .toString()
        .trim();
    if (recordId.isEmpty) {
      throw StateError('Missing record_id on worker_log_delete');
    }
    switch (table) {
      case 'egg_production':
        await deleteEgg(recordId);
      case 'daily_feeding_logs':
        await deleteFeeding(recordId);
      case 'mortality':
        await deleteMortality(recordId);
      default:
        throw StateError('Unsupported worker log delete table: $table');
    }
  }

  Future<void> _pushNestFarmSettingsUpdate(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = (payload['farm_id'] ?? '').toString().trim();
    if (farmId.isEmpty) {
      throw StateError('Missing farm_id on farm_settings_update');
    }

    await updateFarm(farmId, {
      'name': payload['name']?.toString() ?? '',
      'location': payload['location']?.toString(),
      'capacity': _asInt(payload['capacity']),
    });

    await updateFarmSettings(farmId, {
      'currency': payload['currency']?.toString(),
      'eggsPerCrate': _asInt(payload['eggs_per_crate'], fallback: 30),
      'eggRecordReminderTime':
          _nullIfEmpty(_optionalString(payload['egg_record_reminder_time'])),
      'feedRecordReminderTime':
          _nullIfEmpty(_optionalString(payload['feed_record_reminder_time'])),
      'defaultEggUnit': _optionalString(payload['default_egg_unit']).isEmpty
          ? 'crate'
          : payload['default_egg_unit'],
      'allowEggUnitChange': payload['allow_egg_unit_change'] == true,
      'defaultEggSortMode':
          _optionalString(payload['default_egg_sort_mode']).isEmpty
              ? 'unsorted'
              : payload['default_egg_sort_mode'],
      'allowEggSortModeChange': payload['allow_egg_sort_mode_change'] == true,
      if (payload['growth_target_standard'] != null)
        'growthTargetStandard': _asInt(payload['growth_target_standard']),
    });
  }

  Future<void> _pushNestSalesSettingsUpdate(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = (payload['farm_id'] ?? '').toString().trim();
    if (farmId.isEmpty) {
      throw StateError('Missing farm_id on sales_settings_update');
    }
    final discountType =
        _optionalString(payload['default_discount_type']);
    await updateSalesSettings(farmId, {
      'allowBatchOverride': payload['allow_batch_override'] == true,
      'allowWorkerDiscounts': payload['allow_worker_discounts'] == true,
      'defaultDiscountType':
          discountType == 'flat' || discountType == 'percent'
              ? discountType
              : 'item',
    });
  }

  static String _optionalString(Object? value) =>
      value?.toString().trim() ?? '';

  static String? _nullIfEmpty(String value) =>
      value.isEmpty ? null : value;

  static int _asInt(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static double _asDouble(Object? value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// Map commerce outbox payloads onto Nest domain REST.
  Future<void> pushCommerceQueuedInput(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = (payload['farm_id'] ?? '').toString().trim();
    if (farmId.isEmpty) {
      throw StateError('Missing farm_id on pending sync input');
    }

    switch (input.inputType) {
      case 'inventory_item':
        await createInventory({
          'farm_id': farmId,
          'itemName': payload['item_name']?.toString() ?? 'Item',
          'stockLevel': payload['stock_level'] ?? 0,
          'unit': (payload['unit']?.toString().isNotEmpty == true)
              ? payload['unit']
              : 'bags',
          'category': (payload['category']?.toString().isNotEmpty == true)
              ? payload['category']
              : 'other',
        });
      case 'inventory_reorder_update':
        final inventoryId = payload['inventory_id']?.toString() ?? '';
        if (inventoryId.isEmpty) {
          throw StateError('Missing inventory_id');
        }
        await updateInventory(inventoryId, {
          'farm_id': farmId,
          'reorderLevel': payload['reorder_level'],
        });
      case 'expense_allocation':
        final allocations = (payload['allocations'] as List?) ?? const [];
        if (allocations.isEmpty) {
          await createExpense({
            'farm_id': farmId,
            'amount': payload['amount'] ?? 0,
            'category': (payload['category'] ?? 'OTHER').toString().toUpperCase(),
            'description': payload['description']?.toString(),
            'expenseDate': payload['expense_date']?.toString(),
          });
        } else {
          for (final allocation in allocations) {
            final item = Map<String, dynamic>.from(allocation as Map);
            await createExpense({
              'farm_id': farmId,
              'amount': item['amount'] ?? 0,
              'category':
                  (payload['category'] ?? 'OTHER').toString().toUpperCase(),
              'description': payload['description']?.toString(),
              'expenseDate': payload['expense_date']?.toString(),
              'batch_id': item['batch_id']?.toString(),
            });
          }
        }
      case 'sales_invoice':
      case 'farm_gate_sale':
        await _pushNestSale(input);
      default:
        throw StateError(
          'Commerce type not supported by Nest: ${input.inputType}',
        );
    }
  }

  Future<void> _pushNestSale(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = (payload['farm_id'] ?? '').toString().trim();
    final itemsRaw = payload['items'];
    List<Map<String, dynamic>> items;

    if (itemsRaw is List && itemsRaw.isNotEmpty) {
      items = itemsRaw.map((raw) {
        final item = Map<String, dynamic>.from(raw as Map);
        final qty = (item['quantity'] as num?)?.toInt() ?? 1;
        final unitPrice = (item['unit_price'] as num?)?.toDouble() ??
            (item['unitPrice'] as num?)?.toDouble() ??
            0.0;
        final total = (item['total_price'] as num?)?.toDouble() ??
            (item['totalPrice'] as num?)?.toDouble() ??
            (qty * unitPrice);
        return {
          'description':
              (item['description'] ?? item['item'] ?? 'Sale item').toString(),
          'quantity': qty < 1 ? 1 : qty,
          'unitPrice': unitPrice,
          'totalPrice': total,
        };
      }).toList();
    } else if (input.inputType == 'farm_gate_sale') {
      final qty = (payload['quantity_crates'] as num?)?.toInt() ??
          (payload['quantity'] as num?)?.toInt() ??
          1;
      final total = (payload['amount_received'] as num?)?.toDouble() ?? 0.0;
      final unit = payload['unit']?.toString() ?? '';
      items = [
        {
          'description':
              unit.isEmpty ? 'Farm-gate sale' : 'Farm-gate sale ($unit)',
          'quantity': qty < 1 ? 1 : qty,
          'unitPrice': qty <= 0 ? total : total / qty,
          'totalPrice': total,
        },
      ];
    } else {
      final qty = (payload['quantity'] as num?)?.toInt() ?? 1;
      final total = (payload['total'] as num?)?.toDouble() ?? 0.0;
      final itemName = payload['item']?.toString() ?? 'Sale item';
      items = [
        {
          'description': itemName.isEmpty ? 'Sale item' : itemName,
          'quantity': qty < 1 ? 1 : qty,
          'unitPrice': qty <= 0 ? total : total / qty,
          'totalPrice': total,
        },
      ];
    }

    final totalAmount = items.fold<double>(
      0,
      (sum, item) => sum + ((item['totalPrice'] as num?)?.toDouble() ?? 0),
    );

    await createSale({
      'farm_id': farmId,
      'customerName': input.inputType == 'farm_gate_sale'
          ? 'Farm Gate Customer'
          : (payload['customer_name']?.toString() ?? 'Customer'),
      'totalAmount': totalAmount,
      'items': items,
    });
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
