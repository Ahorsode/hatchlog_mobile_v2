import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/utils/feed_inventory_filter.dart';

void main() {
  test('isFeedInventoryCategory matches feed categories and groups', () {
    expect(isFeedInventoryCategory('FEED'), isTrue);
    expect(isFeedInventoryCategory('feed_raw'), isTrue);
    expect(isFeedInventoryCategory('MEDICATION', itemGroup: 'FEED_STOCK'), isTrue);
    expect(isFeedInventoryCategory('MEDICATION', itemGroup: 'MEDICATION_STOCK'), isFalse);
  });

  test('feedInventorySqlWhere is a non-empty SQL fragment', () {
    expect(feedInventorySqlWhere.trim(), isNotEmpty);
    expect(feedInventorySqlWhere, contains('feed_stock'));
  });

  test('formulationInventorySqlWhere matches web FEED-only filter', () {
    expect(formulationInventorySqlWhere, contains("= 'FEED'"));
    expect(formulationInventorySqlWhere, contains('egg_category_id'));
  });
}
