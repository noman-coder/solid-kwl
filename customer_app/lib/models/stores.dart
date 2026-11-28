import '../utils.dart';
import 'home.dart';

/// Server ke `api/customer/stores/` aur `stores/{id}/` jawab ke hisse (Phase C5). Sab fields safe parse hote hain.

class SortOption {
  final String key;
  final String label;
  const SortOption({required this.key, required this.label});

  factory SortOption.fromJson(Map<String, dynamic> j) => SortOption(key: s(j['key']), label: s(j['label']));
}

class CategoryRef {
  final int id;
  final String name;
  const CategoryRef({required this.id, required this.name});

  factory CategoryRef.fromJson(Map<String, dynamic> j) => CategoryRef(id: toI(j['id']), name: s(j['name']));
}

/// Stores list ke filters (app jo bhejti hai wahi server wapas batata hai).
class StoreQuery {
  final String q;
  final String sort; // '' = server ka default
  final bool open;
  final bool free;
  final bool top;
  final bool isNew;
  final int? type;
  final int? category;

  const StoreQuery({
    this.q = '',
    this.sort = '',
    this.open = false,
    this.free = false,
    this.top = false,
    this.isNew = false,
    this.type,
    this.category,
  });

  /// Koi filter / search laga hai? (khali list par 'filters hatayein' dikhane ke liye; sort filter nahi hai)
  bool get hasFilters => q.isNotEmpty || open || free || top || isNew || type != null || category != null;

  StoreQuery copyWith({
    String? q,
    String? sort,
    bool? open,
    bool? free,
    bool? top,
    bool? isNew,
    int? type,
    int? category,
    bool clearType = false,
    bool clearCategory = false,
  }) =>
      StoreQuery(
        q: q ?? this.q,
        sort: sort ?? this.sort,
        open: open ?? this.open,
        free: free ?? this.free,
        top: top ?? this.top,
        isNew: isNew ?? this.isNew,
        type: clearType ? null : (type ?? this.type),
        category: clearCategory ? null : (category ?? this.category),
      );

  /// Home ke banner / store type se aaye hue params (q, free, open, sort, category, type) se.
  factory StoreQuery.fromParams(Map<String, String> p) => StoreQuery(
        q: p['q'] ?? '',
        sort: p['sort'] ?? '',
        open: p['open'] == '1',
        free: p['free'] == '1',
        top: p['top'] == '1',
        isNew: p['new'] == '1',
        type: p['type'] == null ? null : int.tryParse(p['type']!),
        category: p['category'] == null ? null : int.tryParse(p['category']!),
      );

  Map<String, String> toParams() => {
        if (q.isNotEmpty) 'q': q,
        if (sort.isNotEmpty) 'sort': sort,
        if (open) 'open': '1',
        if (free) 'free': '1',
        if (top) 'top': '1',
        if (isNew) 'new': '1',
        if (type != null) 'type': '$type',
        if (category != null) 'category': '$category',
      };
}

class StoreListData {
  final String area;
  final bool hasLocation;
  final String sort;
  final List<SortOption> sorts;
  final List<StoreType> storeTypes;
  final List<CategoryRef> categories;
  final List<StoreCard> stores;
  final int page;
  final int total;
  final bool hasMore;
  final int outsideCount;

  const StoreListData({
    required this.area,
    required this.hasLocation,
    required this.sort,
    required this.sorts,
    required this.storeTypes,
    required this.categories,
    required this.stores,
    required this.page,
    required this.total,
    required this.hasMore,
    required this.outsideCount,
  });

  factory StoreListData.fromJson(Map<String, dynamic> j) => StoreListData(
        area: s(j['area']),
        hasLocation: toB(j['has_location']),
        sort: s(j['sort']),
        sorts: listOfMaps(j['sorts']).map(SortOption.fromJson).toList(),
        storeTypes: listOfMaps(j['store_types']).map(StoreType.fromJson).toList(),
        categories: listOfMaps(j['categories']).map(CategoryRef.fromJson).toList(),
        stores: listOfMaps(j['stores']).map(StoreCard.fromJson).toList(),
        page: toI(j['page'], 1),
        total: toI(j['total']),
        hasMore: toB(j['has_more']),
        outsideCount: toI(j['outside_count']),
      );
}

/// Store detail ke upar ki info (cover, timing, fee, rating, coupons...).
class StoreInfo {
  final StoreCard card; // naam, logo, cover, status, rating, fee, time... (list wale card jaisa)
  final String description;
  final String hoursText;
  final bool servesArea;
  final String areaMessage;
  final bool isFavorite;
  final List<CouponItem> coupons;
  final List<RatingBarItem> ratingBars;
  final String sharePath;
  final String shareText;

  const StoreInfo({
    required this.card,
    required this.description,
    required this.hoursText,
    required this.servesArea,
    required this.areaMessage,
    required this.isFavorite,
    required this.coupons,
    required this.ratingBars,
    required this.sharePath,
    required this.shareText,
  });

  factory StoreInfo.fromJson(Map<String, dynamic> j) => StoreInfo(
        card: StoreCard.fromJson(j),
        description: s(j['description']),
        hoursText: s(j['hours_text']),
        servesArea: j['serves_area'] == null ? true : toB(j['serves_area']),
        areaMessage: s(j['area_message']),
        isFavorite: toB(j['is_favorite']),
        coupons: listOfMaps(j['coupons']).map(CouponItem.fromJson).toList(),
        ratingBars: listOfMaps(j['rating_bars']).map(RatingBarItem.fromJson).toList(),
        sharePath: s(j['share_path']),
        shareText: s(j['share_text']),
      );
}

class RatingBarItem {
  final int stars;
  final int count;
  final int pct;
  const RatingBarItem({required this.stars, required this.count, required this.pct});

  factory RatingBarItem.fromJson(Map<String, dynamic> j) =>
      RatingBarItem(stars: toI(j['stars']), count: toI(j['count']), pct: toI(j['pct']));
}

/// Store ke menu ka ek tab (category) - id 0 = bina category wale.
class StoreMenuItem {
  final int id;
  final String name;
  final int count;
  const StoreMenuItem({required this.id, required this.name, required this.count});

  factory StoreMenuItem.fromJson(Map<String, dynamic> j) =>
      StoreMenuItem(id: toI(j['id']), name: s(j['name']), count: toI(j['count']));
}

/// Store ke andar ka product (Home ke ProductCard par category / description / stock / 'add' ho sakta hai ya nahi).
class StoreProduct {
  final ProductCard card;
  final int categoryId;
  final String categoryName;
  final String description;
  final int stock;
  final bool canAdd;

  const StoreProduct({
    required this.card,
    required this.categoryId,
    required this.categoryName,
    required this.description,
    required this.stock,
    required this.canAdd,
  });

  factory StoreProduct.fromJson(Map<String, dynamic> j) => StoreProduct(
        card: ProductCard.fromJson(j),
        categoryId: toI(j['category_id']),
        categoryName: s(j['category_name']),
        description: s(j['description']),
        stock: toI(j['stock']),
        canAdd: toB(j['can_add']),
      );
}

class StoreDetailData {
  final StoreInfo store;
  final DeliveryBanner delivery;
  final List<StoreMenuItem> menu;
  final int menuTotal;
  final List<StoreProduct> products;
  final int page;
  final int total;
  final bool hasMore;

  const StoreDetailData({
    required this.store,
    required this.delivery,
    required this.menu,
    required this.menuTotal,
    required this.products,
    required this.page,
    required this.total,
    required this.hasMore,
  });

  factory StoreDetailData.fromJson(Map<String, dynamic> j) => StoreDetailData(
        store: StoreInfo.fromJson(asMap(j['store'])),
        delivery: DeliveryBanner.fromJson(asMap(j['delivery'])),
        menu: listOfMaps(j['menu']).map(StoreMenuItem.fromJson).toList(),
        menuTotal: toI(j['menu_total']),
        products: listOfMaps(j['products']).map(StoreProduct.fromJson).toList(),
        page: toI(j['page'], 1),
        total: toI(j['total']),
        hasMore: toB(j['has_more']),
      );
}
