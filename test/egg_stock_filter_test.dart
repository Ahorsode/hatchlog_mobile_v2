import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/utils/inventory_sale_utils.dart';

void main() {
  test('matchesEggStockFilter reads camelCase egg production rows', () {
    final row = <String, Object?>{
      'eggsCollected': 120,
      'eggsRemaining': 40,
      'unusableCount': 10,
    };

    expect(matchesEggStockFilter(row, 'active'), isTrue);
    expect(matchesEggStockFilter(row, 'sold_out'), isFalse);
  });
}
