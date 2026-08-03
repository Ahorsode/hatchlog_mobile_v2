import 'dart:math';

import '../core/api/hatchlog_api_client.dart';
import '../core/storage/local_database.dart';
import '../utils/feed_inventory_filter.dart';

class FeedFormulationIngredientInput {
  const FeedFormulationIngredientInput({
    required this.inventoryId,
    required this.bags,
  });

  final String inventoryId;
  final double bags;
}

class FeedFormulationService {
  FeedFormulationService(
    this._localDatabase, {
    HatchlogApiClient? hatchlogApi,
  }) : _hatchlogApi = hatchlogApi;

  final LocalDatabase _localDatabase;
  final HatchlogApiClient? _hatchlogApi;

  String _newId() {
    final random = Random.secure();
    final suffix = List<int>.generate(
      8,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return 'form_${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }

  Future<List<Map<String, Object?>>> loadFeedInventory(String farmId) async {
    return _localDatabase.rawLocalQuery(
      '''
      select id, item_name, stock_level, unit
      from inventory
      where farm_id = ?
        and is_deleted = 0
        and $formulationInventorySqlWhere
      order by item_name asc
      ''',
      [farmId],
    );
  }

  Future<String> createFormulation({
    required String farmId,
    required String name,
    required String type,
    String? targetLivestock,
    required List<FeedFormulationIngredientInput> ingredients,
    HatchlogApiClient? hatchlogApi,
  }) async {
    if (name.trim().isEmpty) {
      throw ArgumentError('Formulation name is required');
    }
    if (ingredients.isEmpty) {
      throw ArgumentError('Add at least one ingredient');
    }

    final formulationId = _newId();
    final now = DateTime.now().toIso8601String();
    final totalBags = ingredients.fold<double>(
      0,
      (sum, row) => sum + row.bags,
    );

    for (final ingredient in ingredients) {
      if (ingredient.bags <= 0) {
        throw ArgumentError('Each ingredient must use at least one bag');
      }
      final rows = await _localDatabase.queryLocalRecords(
        'inventory',
        where: 'id = ? and is_deleted = 0',
        whereArgs: [ingredient.inventoryId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Ingredient inventory item not found');
      }
      final stock = _asDouble(rows.first['stock_level']);
      final itemName = rows.first['item_name']?.toString() ?? 'Ingredient';
      if (stock < ingredient.bags) {
        throw StateError(
          'Insufficient stock for $itemName (${stock.toStringAsFixed(1)} available)',
        );
      }
    }

    await _localDatabase.insertLocalRecord('feed_formulations', {
      'id': formulationId,
      'farm_id': farmId,
      'name': name.trim(),
      'notes': null,
      'type': type,
      'target_livestock': targetLivestock,
      'stock_level': totalBags,
      'updated_at': now,
    });

    final ingredientRows = <Map<String, Object?>>[];
    for (final ingredient in ingredients) {
      final rows = await _localDatabase.queryLocalRecords(
        'inventory',
        where: 'id = ?',
        whereArgs: [ingredient.inventoryId],
        limit: 1,
      );
      final item = rows.first;
      final unit = item['unit']?.toString().trim().isNotEmpty ?? false
          ? item['unit']!.toString()
          : 'bag';
      final ingredientId = _newId();
      ingredientRows.add({
        'id': ingredientId,
        'formulation_id': formulationId,
        'inventory_id': ingredient.inventoryId,
        'quantity': ingredient.bags,
        'unit': unit,
      });
      await _localDatabase.insertLocalRecord(
        'feed_formulation_ingredients',
        ingredientRows.last,
      );

      final stock = _asDouble(item['stock_level']);
      await _localDatabase.updateLocalRecord(
        'inventory',
        {
          'stock_level': (stock - ingredient.bags).clamp(0, 999999),
          'is_synced': 0,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [ingredient.inventoryId],
      );
    }

    final api = hatchlogApi ?? _hatchlogApi;
    if (api != null && api.isConfigured) {
      await api.createFeedFormulation({
        'farm_id': farmId,
        'name': name.trim(),
        'type': type,
        if (targetLivestock != null && targetLivestock.trim().isNotEmpty)
          'targetLivestock': targetLivestock,
        'ingredients': [
          for (final ingredient in ingredients)
            {
              'inventoryId': ingredient.inventoryId,
              'quantity': ingredient.bags,
            },
        ],
      });
    }

    return formulationId;
  }

  double _asDouble(Object? value) {
    if (value == null) {
      return 0;
    }
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString()) ?? 0;
  }
}
