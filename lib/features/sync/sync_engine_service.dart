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
    if ((!_remoteApi.isConfigured && !_hatchlogApi.isConfigured) ||
        farmId.isEmpty) {
      return;
    }

    final scope = 'farm:$farmId';
    try {
      final cursor = forceFullRefresh
          ? null
          : await _localDatabase.readSyncCursor(scope);

      // Prefer Nest pull for operational log deltas when configured; always
      // hydrate the full farm snapshot from Supabase for remaining entities.
      if (_hatchlogApi.isConfigured) {
        try {
          await _hydrateNestOperationalLogs(
            farmId: farmId,
            since: cursor?.toUtc().toIso8601String(),
          );
        } on Object catch (error) {
          debugPrint('WARN: Nest sync pull skipped: $error');
        }

        // Phase 3: prefer Nest REST for livestock/houses reads when online.
        try {
          await _hydrateNestLivestockAndHouses(farmId: farmId);
        } on Object catch (error) {
          debugPrint('WARN: Nest livestock/houses read skipped: $error');
        }
      }

      if (_remoteApi.isConfigured) {
        final snapshot = await _remoteApi.fetchOperationalSnapshot(
          user: user,
          modifiedAfter: cursor,
          farmIdOverride: farmId,
        );
        await _localDatabase.upsertCloudRecords(snapshot.recordsByLocalTable);
        await HealthInventoryService(_localDatabase).reconcileFarmDepletion(
          farmId,
        );
        await _localDatabase.writeSyncCursor(scope, snapshot.pulledAt);
      }

      debugPrint(
        'HatchLog Sync Engine: Cloud data hydration sequence complete.',
      );
    } on Object catch (error) {
      debugPrint('WARN: HatchLog Sync Engine skipped $scope: $error');
    }
  }

  /// Phase 3: Nest-first read for livestock (batches) and houses.
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
    final pull = await _hatchlogApi.pull(
      farmId: farmId,
      since: since,
      limit: 500,
    );
    final records = (pull['records'] as List?) ?? const [];
    if (records.isEmpty) {
      return;
    }

    final byTable = <String, List<Map<String, Object?>>>{
      'egg_production': <Map<String, Object?>>[],
      'daily_feeding_logs': <Map<String, Object?>>[],
      'mortality': <Map<String, Object?>>[],
    };

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

    await _localDatabase.upsertCloudRecords(byTable);
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
