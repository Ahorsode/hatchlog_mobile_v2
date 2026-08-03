import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/core/api/hatchlog_api_client.dart';
import 'package:hatchlog_m/core/config/hatchlog_api_config.dart';

void main() {
  group('Nest CRUD contract — mutation routing', () {
    late HatchlogApiClient client;

    setUp(() {
      client = HatchlogApiClient(
        config: const HatchlogApiConfig(
          baseUrl: 'http://localhost:3001',
          source: HatchlogApiConfigSource.compileTimeNative,
        ),
      );
    });

    test('worker log + settings outbox types are Nest mutation types', () {
      expect(
        HatchlogApiClient.nestMutationInputTypes,
        containsAll([
          'worker_log_update',
          'worker_log_delete',
          'farm_settings_update',
          'sales_settings_update',
        ]),
      );
      expect(client.supportsMutationInputType('worker_log_update'), isTrue);
      expect(client.supportsMutationInputType('farm_settings_update'), isTrue);
      expect(client.supportsMutationInputType('role_promotion'), isFalse);
    });

    test('ops sync entities remain Nest-supported', () {
      expect(
        HatchlogApiClient.nestSupportedEntityTypes,
        containsAll(['egg_collection', 'feed_usage', 'mortality']),
      );
    });

    test('commerce outbox types remain Nest-supported', () {
      expect(
        HatchlogApiClient.nestCommerceInputTypes,
        containsAll([
          'sales_invoice',
          'farm_gate_sale',
          'expense_allocation',
          'inventory_item',
          'inventory_reorder_update',
        ]),
      );
    });

    test('client exposes Nest delete/update helpers used by sync', () {
      expect(client.deleteMortality, isA<Function>());
      expect(client.updateMortality, isA<Function>());
      expect(client.updateFeeding, isA<Function>());
      expect(client.deleteInventory, isA<Function>());
      expect(client.deleteSale, isA<Function>());
      expect(client.deleteExpense, isA<Function>());
      expect(client.deleteCustomer, isA<Function>());
      expect(client.deleteFeedFormulation, isA<Function>());
      expect(client.updateFarmSettings, isA<Function>());
      expect(client.updateSalesSettings, isA<Function>());
      expect(client.listEggCategories, isA<Function>());
      expect(client.listOrders, isA<Function>());
    });
  });

  group('Nest CRUD contract — config hard-require', () {
    test('empty config is not configured', () {
      const missing = HatchlogApiConfig(
        baseUrl: '',
        source: HatchlogApiConfigSource.missing,
      );
      expect(missing.isConfigured, isFalse);
    });

    test('configured config reports isConfigured true', () {
      const config = HatchlogApiConfig(
        baseUrl: 'http://10.0.2.2:3001',
        source: HatchlogApiConfigSource.packedAsset,
      );
      expect(config.isConfigured, isTrue);
    });
  });
}
