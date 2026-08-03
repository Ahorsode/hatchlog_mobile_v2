import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/api/hatchlog_api_client.dart';
import '../../../services/health_inventory_service.dart';
import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';
import '../../utils/active_farm_id.dart';
import '../auth/data/supabase_remote_api.dart';

class SyncEngineService {
  const SyncEngineService({
    required LocalDatabase localDatabase,
    required SupabaseRemoteApi remoteApi,
    required HatchlogApiClient hatchlogApi,
  }) : _localDatabase = localDatabase,
       _remoteApi = remoteApi,
       _hatchlogApi = hatchlogApi;

  final LocalDatabase _localDatabase;
  final SupabaseRemoteApi _remoteApi;
  final HatchlogApiClient _hatchlogApi;

  Future<void> syncWebEntitiesToLocalCache({
    required AppUser user,
    bool forceFullRefresh = false,
  }) async {
    SupabaseClient? supabase;
    try {
      supabase = Supabase.instance.client;
    } on Object {
      supabase = null;
    }
    final farmId = resolveActiveFarmId(user: user, supabase: supabase);
    if (!_hatchlogApi.isConfigured || farmId.isEmpty) {
      if (!_hatchlogApi.isConfigured) {
        debugPrint(
          'ERROR: Nest hydrate skipped — HATCHLOG_API_URL is required',
        );
      }
      return;
    }

    final scope = 'farm:$farmId';
    try {
      final cursor = forceFullRefresh
          ? null
          : await _localDatabase.readSyncCursor(scope);

      // Nest-required pull for ops + livestock/houses + commerce.
      await _hydrateNestOperationalLogs(
        farmId: farmId,
        since: cursor?.toUtc().toIso8601String(),
      );
      await _hydrateNestLivestockAndHouses(farmId: farmId);
      await _hydrateNestCommerce(farmId: farmId);
      await _hydrateNestDomainExtras(farmId: farmId);

      // Supabase snapshot only for identity leftovers (team/permissions/etc).
      if (_remoteApi.isConfigured) {
        final snapshot = await _remoteApi.fetchOperationalSnapshot(
          user: user,
          modifiedAfter: cursor,
          farmIdOverride: farmId,
        );
        final records = Map<String, List<Map<String, Object?>>>.from(
          snapshot.recordsByLocalTable,
        );
        for (final table in _nestOwnedLocalTables) {
          records.remove(table);
        }
        await _localDatabase.upsertCloudRecords(records);
        await HealthInventoryService(_localDatabase).reconcileFarmDepletion(
          farmId,
        );
        await _localDatabase.writeSyncCursor(scope, snapshot.pulledAt);
      } else {
        await _localDatabase.writeSyncCursor(scope, DateTime.now().toUtc());
      }

      debugPrint(
        'HatchLog Sync Engine: Cloud data hydration sequence complete.',
      );
    } on Object catch (error) {
      debugPrint('WARN: HatchLog Sync Engine skipped $scope: $error');
    }
  }

  static const _nestOwnedLocalTables = {
    'batches',
    'houses',
    'egg_production',
    'daily_feeding_logs',
    'mortality',
    'inventory',
    'customers',
    'suppliers',
    'sales',
    'expenses',
    'feed_formulations',
    'vaccination_schedules',
    'medication_schedules',
    'egg_categories',
    'isolation_rooms',
    'weight_records',
    'orders',
  };

  /// Nest-first read for livestock (batches) and houses.
  /// Writes into local cache so the rest of the app sees them from Drift.
  Future<void> _hydrateNestLivestockAndHouses({
    required String farmId,
  }) async {
    final livestock = await _hatchlogApi.listLivestock(farmId);
    if (livestock.isNotEmpty) {
      final rows = livestock
          .whereType<Map>()
          .map((row) => _mapNestLivestockToLocal(row, farmId))
          .whereType<Map<String, Object?>>()
          .toList();
      if (rows.isNotEmpty) {
        await _localDatabase.upsertCloudRecords({'batches': rows});
      }
    }

    final houses = await _hatchlogApi.listHouses(farmId);
    if (houses.isNotEmpty) {
      final rows = houses
          .whereType<Map>()
          .map((row) => _mapNestHouseToLocal(row, farmId))
          .whereType<Map<String, Object?>>()
          .toList();
      if (rows.isNotEmpty) {
        await _localDatabase.upsertCloudRecords({'houses': rows});
      }
    }
  }

  Future<void> _hydrateNestCommerce({required String farmId}) async {
    Future<void> upsertMapped(
      String table,
      List<dynamic> rows,
      Map<String, Object?>? Function(Map<dynamic, dynamic>) mapRow,
    ) async {
      final mapped = rows
          .whereType<Map>()
          .map(mapRow)
          .whereType<Map<String, Object?>>()
          .toList();
      if (mapped.isNotEmpty) {
        await _localDatabase.upsertCloudRecords({table: mapped});
      }
    }

    await upsertMapped(
      'inventory',
      await _hatchlogApi.listInventory(farmId),
      (raw) => _mapNestGenericToLocal(raw, farmId, snakeKeys: const {
        'itemName': 'item_name',
        'stockLevel': 'stock_level',
        'reorderLevel': 'reorder_level',
        'costPerUnit': 'cost_per_unit',
        'supplierId': 'supplier_id',
        'userId': 'user_id',
      }),
    );
    await upsertMapped(
      'customers',
      await _hatchlogApi.listCustomers(farmId),
      (raw) => _mapNestGenericToLocal(raw, farmId, snakeKeys: const {
        'balanceOwed': 'balance_owed',
        'customerType': 'customer_type',
        'contactPerson': 'contact_person',
        'supplyItems': 'supply_items',
      }),
    );
    await upsertMapped(
      'suppliers',
      await _hatchlogApi.listSuppliers(farmId),
      (raw) => _mapNestGenericToLocal(raw, farmId, snakeKeys: const {
        'balanceOwed': 'balance_owed',
        'contactPerson': 'contact_person',
        'supplyItems': 'supply_items',
      }),
    );
    await upsertMapped(
      'sales',
      await _hatchlogApi.listSales(farmId),
      (raw) => _mapNestGenericToLocal(raw, farmId, snakeKeys: const {
        'customerName': 'customer_name',
        'totalAmount': 'total_amount',
        'saleDate': 'sale_date',
        'userId': 'user_id',
        'customerId': 'customer_id',
      }),
    );
    await upsertMapped(
      'expenses',
      await _hatchlogApi.listExpenses(farmId),
      (raw) => _mapNestGenericToLocal(raw, farmId, snakeKeys: const {
        'expenseDate': 'expense_date',
        'supplierId': 'supplier_id',
        'userId': 'user_id',
        'batch_id': 'batch_id',
      }),
    );
    try {
      await upsertMapped(
        'feed_formulations',
        await _hatchlogApi.listFeedFormulations(farmId),
        (raw) => _mapNestGenericToLocal(raw, farmId, snakeKeys: const {
          'userId': 'user_id',
          'createdAt': 'created_at',
        }),
      );
    } on Object catch (error) {
      debugPrint('WARN: Nest feed formulations read skipped: $error');
    }
  }

  /// Egg categories, health schedules, isolation rooms, orders, weights.
  Future<void> _hydrateNestDomainExtras({required String farmId}) async {
    try {
      final categories = await _hatchlogApi.listEggCategories(farmId);
      final rows = categories
          .whereType<Map>()
          .map(_mapNestEggCategoryToLocal)
          .whereType<Map<String, Object?>>()
          .toList();
      if (rows.isNotEmpty) {
        await _localDatabase.upsertCloudRecords({'egg_categories': rows});
      }
    } on Object catch (error) {
      debugPrint('WARN: Nest egg categories read skipped: $error');
    }

    try {
      final schedules = await _hatchlogApi.listHealthSchedules(farmId);
      final vaccinations = (schedules['vaccinations'] as List?) ?? const [];
      final medications = (schedules['medications'] as List?) ?? const [];
      final vaxRows = vaccinations
          .whereType<Map>()
          .map((raw) => _mapNestVaccinationToLocal(raw, farmId))
          .whereType<Map<String, Object?>>()
          .toList();
      final medRows = medications
          .whereType<Map>()
          .map((raw) => _mapNestMedicationToLocal(raw, farmId))
          .whereType<Map<String, Object?>>()
          .toList();
      final byTable = <String, List<Map<String, Object?>>>{
        if (vaxRows.isNotEmpty) 'vaccination_schedules': vaxRows,
        if (medRows.isNotEmpty) 'medication_schedules': medRows,
      };
      if (byTable.isNotEmpty) {
        await _localDatabase.upsertCloudRecords(byTable);
      }
    } on Object catch (error) {
      debugPrint('WARN: Nest health schedules read skipped: $error');
    }

    try {
      final rooms = await _hatchlogApi.listIsolationRooms(farmId);
      final rows = rooms
          .whereType<Map>()
          .map(_mapNestIsolationRoomToLocal)
          .whereType<Map<String, Object?>>()
          .toList();
      if (rows.isNotEmpty) {
        await _localDatabase.upsertCloudRecords({'isolation_rooms': rows});
      }
    } on Object catch (error) {
      debugPrint('WARN: Nest isolation rooms read skipped: $error');
    }

    try {
      final orders = await _hatchlogApi.listOrders(farmId);
      final rows = orders
          .whereType<Map>()
          .map(_mapNestOrderToLocal)
          .whereType<Map<String, Object?>>()
          .toList();
      if (rows.isNotEmpty) {
        await _localDatabase.upsertCloudRecords({'orders': rows});
      }
    } on Object catch (error) {
      debugPrint('WARN: Nest orders read skipped: $error');
    }

    try {
      await _hydrateNestWeightRecords(farmId: farmId);
    } on Object catch (error) {
      debugPrint('WARN: Nest weight records read skipped: $error');
    }
  }

  Future<void> _hydrateNestWeightRecords({required String farmId}) async {
    final livestock = await _hatchlogApi.listLivestock(farmId);
    final weightRows = <Map<String, Object?>>[];
    for (final raw in livestock.whereType<Map>()) {
      final batchId = (raw['id'] ?? '').toString();
      if (batchId.isEmpty) continue;
      try {
        final details =
            await _hatchlogApi.getLivestockDetails(batchId, farmId);
        final weights = (details['weightRecords'] as List?) ??
            (details['weight_records'] as List?) ??
            const [];
        for (final wRaw in weights.whereType<Map>()) {
          final mapped = _mapNestWeightRecordToLocal(wRaw, farmId, batchId);
          if (mapped != null) weightRows.add(mapped);
        }
      } on Object catch (error) {
        debugPrint('WARN: Nest weight pull for $batchId skipped: $error');
      }
    }
    if (weightRows.isNotEmpty) {
      await _localDatabase.upsertCloudRecords({'weight_records': weightRows});
    }
  }

  Map<String, Object?>? _mapNestEggCategoryToLocal(Map<dynamic, dynamic> raw) {
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return {
      'id': id,
      'farm_id': (raw['farmId'] ?? raw['farm_id'])?.toString(),
      'name': (raw['name'] ?? '').toString(),
      'description': (raw['description'])?.toString(),
      'is_stock_internal':
          (raw['isStockInternal'] == true || raw['is_stock_internal'] == 1)
              ? 1
              : 0,
      'selling_price': raw['sellingPrice'] ?? raw['selling_price'] ?? 0,
      'unit_size': raw['unitSize'] ?? raw['unit_size'] ?? 30,
      'updated_at': (raw['updatedAt'] ?? raw['updated_at'])?.toString(),
    };
  }

  Map<String, Object?>? _mapNestVaccinationToLocal(
    Map<dynamic, dynamic> raw,
    String farmId,
  ) {
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return {
      'id': id,
      'batch_id': (raw['batchId'] ?? raw['batch_id'])?.toString(),
      'vaccine_name':
          (raw['vaccineName'] ?? raw['vaccine_name'] ?? '').toString(),
      'scheduled_date':
          (raw['scheduledDate'] ?? raw['scheduled_date'])?.toString(),
      'status': (raw['status'] ?? 'PENDING').toString(),
      'notes': raw['notes']?.toString(),
      'inventory_id': (raw['inventoryId'] ?? raw['inventory_id'])?.toString(),
      'quantity': raw['quantity'] ?? 1,
      'usage_type': (raw['usageType'] ?? raw['usage_type'])?.toString(),
      'unit': raw['unit']?.toString(),
      'farm_id': farmId,
      'is_synced': 1,
    };
  }

  Map<String, Object?>? _mapNestMedicationToLocal(
    Map<dynamic, dynamic> raw,
    String farmId,
  ) {
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return {
      'id': id,
      'batch_id': (raw['batchId'] ?? raw['batch_id'])?.toString(),
      'medication_name':
          (raw['medicationName'] ?? raw['medication_name'] ?? '').toString(),
      'scheduled_date':
          (raw['scheduledDate'] ?? raw['scheduled_date'])?.toString(),
      'status': (raw['status'] ?? 'PENDING').toString(),
      'notes': raw['notes']?.toString(),
      'inventory_id': (raw['inventoryId'] ?? raw['inventory_id'])?.toString(),
      'quantity': raw['quantity'] ?? 1,
      'usage_type': (raw['usageType'] ?? raw['usage_type'])?.toString(),
      'unit': raw['unit']?.toString(),
      'farm_id': farmId,
      'is_synced': 1,
    };
  }

  Map<String, Object?>? _mapNestIsolationRoomToLocal(Map<dynamic, dynamic> raw) {
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return {
      'id': id,
      'farm_id': (raw['farmId'] ?? raw['farm_id'])?.toString(),
      'name': (raw['name'] ?? '').toString(),
      'capacity': raw['capacity'] ?? 0,
      'user_id': (raw['userId'] ?? raw['user_id'])?.toString() ?? '',
      'updated_at': (raw['updatedAt'] ?? raw['updated_at'])?.toString(),
    };
  }

  Map<String, Object?>? _mapNestOrderToLocal(Map<dynamic, dynamic> raw) {
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return {
      'id': id,
      'farm_id': (raw['farmId'] ?? raw['farm_id'])?.toString(),
      'customer_id': (raw['customerId'] ?? raw['customer_id'])?.toString(),
      'invoice_number': raw['invoiceNumber'] ?? raw['invoice_number'],
      'subtotal_amount':
          raw['subtotalAmount'] ?? raw['subtotal_amount'] ?? 0,
      'tax_amount': raw['taxAmount'] ?? raw['tax_amount'] ?? 0,
      'total_amount': raw['totalAmount'] ?? raw['total_amount'] ?? 0,
      'cash_received': raw['cashReceived'] ?? raw['cash_received'] ?? 0,
      'currency': (raw['currency'] ?? 'USD').toString(),
      'status': (raw['status'] ?? 'PENDING').toString(),
      'discount_amount':
          raw['discountAmount'] ?? raw['discount_amount'] ?? 0,
      'payment_method':
          (raw['paymentMethod'] ?? raw['payment_method'])?.toString(),
      'payment_reference':
          (raw['paymentReference'] ?? raw['payment_reference'])?.toString(),
      'payment_account_name': (raw['paymentAccountName'] ??
              raw['payment_account_name'])
          ?.toString(),
      'order_date': (raw['orderDate'] ?? raw['order_date'])?.toString() ?? '',
      'paid_at': (raw['paidAt'] ?? raw['paid_at'])?.toString(),
      'user_id': (raw['userId'] ?? raw['user_id'])?.toString() ?? '',
      'is_deleted':
          (raw['isDeleted'] == true || raw['is_deleted'] == 1) ? 1 : 0,
      'deleted_at': (raw['deletedAt'] ?? raw['deleted_at'])?.toString(),
      'created_at': (raw['createdAt'] ?? raw['created_at'])?.toString(),
      'updated_at': (raw['updatedAt'] ?? raw['updated_at'])?.toString(),
    };
  }

  Map<String, Object?>? _mapNestWeightRecordToLocal(
    Map<dynamic, dynamic> raw,
    String farmId,
    String batchId,
  ) {
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return {
      'id': id,
      'batch_id':
          (raw['batchId'] ?? raw['batch_id'] ?? batchId)?.toString() ?? batchId,
      'average_weight':
          raw['averageWeight'] ?? raw['average_weight'] ?? 0,
      'log_date': (raw['logDate'] ?? raw['log_date'])?.toString() ?? '',
      'user_id': (raw['userId'] ?? raw['user_id'])?.toString() ?? '',
      'farm_id': farmId,
      'created_at': (raw['createdAt'] ?? raw['created_at'])?.toString(),
    };
  }

  Map<String, Object?>? _mapNestGenericToLocal(
    Map<dynamic, dynamic> raw,
    String farmId, {
    Map<String, String> snakeKeys = const {},
  }) {
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final out = <String, Object?>{
      'id': id,
      'farm_id': farmId,
      'is_synced': 1,
      'is_deleted': (raw['isDeleted'] == true || raw['is_deleted'] == 1) ? 1 : 0,
    };
    for (final entry in raw.entries) {
      final key = entry.key.toString();
      if (key == 'id' || key == 'farmId' || key == 'farm_id') continue;
      final mappedKey = snakeKeys[key] ?? _camelToSnake(key);
      out[mappedKey] = entry.value as Object?;
    }
    return out;
  }

  static String _camelToSnake(String value) {
    return value.replaceAllMapped(
      RegExp(r'[A-Z]'),
      (match) => '_${match.group(0)!.toLowerCase()}',
    );
  }

  Map<String, Object?>? _mapNestLivestockToLocal(
    Map<dynamic, dynamic> raw,
    String farmId,
  ) {
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return {
      'id': id,
      'farm_id': farmId,
      'house_id': (raw['houseId'] ?? raw['house_id'])?.toString(),
      'user_id': (raw['userId'] ?? raw['user_id'])?.toString(),
      'batch_name': (raw['batchName'] ?? raw['batch_name'] ?? raw['name'])
          ?.toString(),
      'type': (raw['type'] ?? '')?.toString(),
      'breed_type': (raw['breedType'] ?? raw['breed_type'])?.toString(),
      'status': (raw['status'] ?? '')?.toString(),
      'arrival_date':
          (raw['arrivalDate'] ?? raw['arrival_date'])?.toString(),
      'current_count': raw['currentCount'] ?? raw['current_count'] ?? 0,
      'initial_count': raw['initialCount'] ?? raw['initial_count'] ?? 0,
      'isolation_count':
          raw['isolationCount'] ?? raw['isolation_count'] ?? 0,
      'is_deleted': 0,
      'is_synced': 1,
    };
  }

  Map<String, Object?>? _mapNestHouseToLocal(
    Map<dynamic, dynamic> raw,
    String farmId,
  ) {
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return {
      'id': id,
      'farm_id': farmId,
      'user_id': (raw['userId'] ?? raw['user_id'])?.toString(),
      'name': (raw['name'] ?? '')?.toString(),
      'capacity': raw['capacity'] ?? 0,
      'is_deleted': 0,
      'is_synced': 1,
    };
  }

  Future<void> _hydrateNestOperationalLogs({
    required String farmId,
    String? since,
  }) async {
    final byTable = <String, List<Map<String, Object?>>>{
      'egg_production': <Map<String, Object?>>[],
      'daily_feeding_logs': <Map<String, Object?>>[],
      'mortality': <Map<String, Object?>>[],
    };

    // Prefer domain REST lists (full current state), then merge sync pull deltas.
    try {
      final eggs = await _hatchlogApi.listEggs(farmId);
      for (final raw in eggs.whereType<Map>()) {
        final mapped = _mapNestPayloadToLocal('egg_collection', raw);
        if (mapped != null) byTable['egg_production']!.add(mapped);
      }
    } on Object catch (error) {
      debugPrint('[Sync] Nest listEggs failed: $error');
    }

    try {
      final feeding = await _hatchlogApi.listFeeding(farmId);
      for (final raw in feeding.whereType<Map>()) {
        final mapped = _mapNestPayloadToLocal('feed_usage', raw);
        if (mapped != null) byTable['daily_feeding_logs']!.add(mapped);
      }
    } on Object catch (error) {
      debugPrint('[Sync] Nest listFeeding failed: $error');
    }

    try {
      final mortality = await _hatchlogApi.listMortality(farmId);
      for (final raw in mortality.whereType<Map>()) {
        final mapped = _mapNestPayloadToLocal('mortality', raw);
        if (mapped != null) byTable['mortality']!.add(mapped);
      }
    } on Object catch (error) {
      debugPrint('[Sync] Nest listMortality failed: $error');
    }

    try {
      final pull = await _hatchlogApi.pull(
        farmId: farmId,
        since: since,
        limit: 500,
      );
      final records = (pull['records'] as List?) ?? const [];
      for (final raw in records) {
        final row = Map<String, dynamic>.from(raw as Map);
        final entityType = row['entity_type']?.toString() ?? '';
        final payload = row['payload'];
        if (payload is! Map) {
          continue;
        }
        final mapped = _mapNestPayloadToLocal(entityType, payload);
        if (mapped == null) {
          continue;
        }
        final table = switch (entityType) {
          'egg_collection' => 'egg_production',
          'feed_usage' => 'daily_feeding_logs',
          'mortality' => 'mortality',
          _ => null,
        };
        if (table == null) {
          continue;
        }
        byTable[table]!.add(mapped);
      }
    } on Object catch (error) {
      debugPrint('[Sync] Nest pull operational logs failed: $error');
    }

    final nonEmpty = {
      for (final entry in byTable.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value,
    };
    if (nonEmpty.isEmpty) {
      return;
    }
    await _localDatabase.upsertCloudRecords(nonEmpty);
  }

  Map<String, Object?>? _mapNestPayloadToLocal(
    String entityType,
    Map<dynamic, dynamic> payload,
  ) {
    final map = <String, Object?>{};
    for (final entry in payload.entries) {
      map[entry.key.toString()] = entry.value as Object?;
    }

    // Nest/Prisma returns camelCase; local SQLite uses snake_case for many cols.
    String? pick(String camel, String snake) {
      final a = map[camel];
      final b = map[snake];
      if (a != null) return a.toString();
      if (b != null) return b.toString();
      return null;
    }

    final id = pick('id', 'id');
    if (id == null || id.isEmpty) {
      return null;
    }

    switch (entityType) {
      case 'egg_collection':
        return {
          'id': id,
          'batch_id': pick('batchId', 'batch_id'),
          'farm_id': pick('farmId', 'farm_id'),
          'user_id': pick('userId', 'user_id'),
          'eggs_collected': map['eggsCollected'] ?? map['eggs_collected'],
          'crates_collected': map['cratesCollected'] ?? map['crates_collected'],
          'eggs_remaining': map['eggsRemaining'] ?? map['eggs_remaining'],
          'unusable_count': map['unusableCount'] ?? map['unusable_count'],
          'category_id': pick('categoryId', 'category_id'),
          'quality_grade': pick('qualityGrade', 'quality_grade'),
          'is_sorted': (map['isSorted'] == true || map['is_sorted'] == 1)
              ? 1
              : 0,
          'small_count': map['smallCount'] ?? map['small_count'] ?? 0,
          'medium_count': map['mediumCount'] ?? map['medium_count'] ?? 0,
          'large_count': map['largeCount'] ?? map['large_count'] ?? 0,
          'log_date': pick('logDate', 'log_date'),
          'created_at': pick('createdAt', 'created_at'),
          'is_deleted': (map['isDeleted'] == true || map['is_deleted'] == 1)
              ? 1
              : 0,
          'is_synced': 1,
        };
      case 'feed_usage':
        return {
          'id': id,
          'batch_id': pick('batchId', 'batch_id'),
          'feed_type_id': pick('feedTypeId', 'feed_type_id'),
          'formulation_id': pick('formulationId', 'formulation_id'),
          'farm_id': pick('farmId', 'farm_id'),
          'user_id': pick('userId', 'user_id'),
          'amount_consumed': map['amountConsumed'] ?? map['amount_consumed'],
          'log_date': pick('logDate', 'log_date'),
          'is_deleted': (map['isDeleted'] == true || map['is_deleted'] == 1)
              ? 1
              : 0,
          'is_synced': 1,
        };
      case 'mortality':
        return {
          'id': id,
          'batch_id': pick('batchId', 'batch_id'),
          'farm_id': pick('farmId', 'farm_id'),
          'user_id': pick('userId', 'user_id'),
          'count': map['count'],
          'type': pick('type', 'type') ?? 'DEAD',
          'reason': pick('reason', 'reason'),
          'category': pick('category', 'category'),
          'sub_category': pick('subCategory', 'sub_category'),
          'isolation_room_id': pick('isolationRoomId', 'isolation_room_id'),
          'log_date': pick('logDate', 'log_date'),
          'created_at': pick('createdAt', 'created_at'),
          'is_deleted': (map['isDeleted'] == true || map['is_deleted'] == 1)
              ? 1
              : 0,
          'is_synced': 1,
        };
      default:
        return null;
    }
  }
}
