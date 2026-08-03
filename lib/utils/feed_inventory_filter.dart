/// SQL predicate for inventory rows that can be used as feed sources.
const String feedInventorySqlWhere = '''
(
  lower(coalesce(category, '')) in ('feed', 'feeds', 'feed_raw', 'feed_finished')
  or lower(coalesce(item_group, '')) in ('feed', 'feed_stock')
)
''';

/// Web `FeedView` formulation ingredient filter: FEED category only, no eggs, in stock.
const String formulationInventorySqlWhere = '''
(
  upper(coalesce(category, '')) = 'FEED'
  and lower(coalesce(item_name, '')) not like '%egg%'
  and coalesce(egg_category_id, '') = ''
  and coalesce(stock_level, 0) > 0
)
''';

bool isFeedInventoryCategory(String? category, {String? itemGroup}) {
  final normalizedCategory = category?.trim().toLowerCase() ?? '';
  if (const {'feed', 'feeds', 'feed_raw', 'feed_finished'}
      .contains(normalizedCategory)) {
    return true;
  }
  final normalizedGroup = itemGroup?.trim().toLowerCase() ?? '';
  return const {'feed', 'feed_stock'}.contains(normalizedGroup);
}
