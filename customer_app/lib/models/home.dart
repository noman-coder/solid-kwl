import '../utils.dart';

/// Server ke `api/customer/home/` jawab ke hisse (Phase C4). Sab fields safe parse hote hain (null / ghalat type par crash nahi).

/// Banner dabane par kya ho: store / stores (filter) / url / none.
class BannerAction {
  final String type;
  final int storeId;
  final String url;
  final bool relative;
  final Map<String, String> params;

  const BannerAction({this.type = 'none', this.storeId = 0, this.url = '', this.relative = false, this.params = const {}});

  factory BannerAction.fromJson(Map<String, dynamic> j) {
    final p = asMap(j['params']).map((k, v) => MapEntry(k, s(v)));
    return BannerAction(
      type: s(j['type']).isEmpty ? 'none' : s(j['type']),
      storeId: toI(j['store_id']),
      url: s(j['url']),
      relative: toB(j['relative']),
      params: p,
    );
  }
}

class BannerItem {
  final int id;
  final String title;
  final String image;
  final BannerAction action;

  const BannerItem({required this.id, required this.title, required this.image, required this.action});

  factory BannerItem.fromJson(Map<String, dynamic> j) => BannerItem(
        id: toI(j['id']),
        title: s(j['title']),
        image: s(j['image']),
        action: BannerAction.fromJson(asMap(j['action'])),
      );
}

class StoreType {
  final int id;
  final String name;
  final String icon;
  final int count;

  const StoreType({required this.id, required this.name, required this.icon, required this.count});

  factory StoreType.fromJson(Map<String, dynamic> j) =>
      StoreType(id: toI(j['id']), name: s(j['name']), icon: s(j['icon']), count: toI(j['count']));
}

/// Category / master category ka tile (kind: 'master' ya 'category').
class CategoryTile {
  final int id;
  final String name;
  final String icon;
  final int tone;
  final String kind;

  const CategoryTile(
      {required this.id, required this.name, required this.icon, required this.tone, required this.kind});

  bool get isMaster => kind == 'master';

  factory CategoryTile.fromJson(Map<String, dynamic> j) => CategoryTile(
        id: toI(j['id']),
        name: s(j['name']),
        icon: s(j['icon']),
        tone: toI(j['tone'], 1),
        kind: s(j['kind']),
      );
}

class StoreCard {
  final int id;
  final String name;
  final String logo;
  final String cover;
  final String type;
  final String city;
  final String status; // open / busy / closed
  final String statusText;
  final bool isOpen;
  final String closedMessage;
  final double? rating;
  final int ratingCount;
  final double deliveryFee;
  final bool freeDelivery;
  final double minOrder;
  final int timeMin;
  final int timeMax;
  final String distanceText;
  final bool verified;

  const StoreCard({
    required this.id,
    required this.name,
    required this.logo,
    required this.cover,
    required this.type,
    required this.city,
    required this.status,
    required this.statusText,
    required this.isOpen,
    required this.closedMessage,
    required this.rating,
    required this.ratingCount,
    required this.deliveryFee,
    required this.freeDelivery,
    required this.minOrder,
    required this.timeMin,
    required this.timeMax,
    required this.distanceText,
    required this.verified,
  });

  String get timeText => timeMax > 0 ? '$timeMin-$timeMax min' : '';

  factory StoreCard.fromJson(Map<String, dynamic> j) => StoreCard(
        id: toI(j['id']),
        name: s(j['name']),
        logo: s(j['logo']),
        cover: s(j['cover']),
        type: s(j['type']),
        city: s(j['city']),
        status: s(j['status']),
        statusText: s(j['status_text']),
        isOpen: j['is_open'] == null ? true : toB(j['is_open']),
        closedMessage: s(j['closed_message']),
        rating: j['rating'] == null ? null : toD(j['rating']),
        ratingCount: toI(j['rating_count']),
        deliveryFee: toD(j['delivery_fee']),
        freeDelivery: toB(j['free_delivery']),
        minOrder: toD(j['min_order']),
        timeMin: toI(j['delivery_time_min']),
        timeMax: toI(j['delivery_time_max']),
        distanceText: s(j['distance_text']),
        verified: toB(j['verified']),
      );
}

class ProductCard {
  final int id;
  final String name;
  final String image;
  final String unit;
  final double price;
  final double? oldPrice;
  final int? discountPercent;
  final bool inStock;
  final int storeId;
  final String storeName;
  final bool storeOpen;
  final String closedMessage;
  final DateTime? offerEndsAt;

  const ProductCard({
    required this.id,
    required this.name,
    required this.image,
    required this.unit,
    required this.price,
    required this.oldPrice,
    required this.discountPercent,
    required this.inStock,
    required this.storeId,
    required this.storeName,
    required this.storeOpen,
    required this.closedMessage,
    required this.offerEndsAt,
  });

  factory ProductCard.fromJson(Map<String, dynamic> j) => ProductCard(
        id: toI(j['id']),
        name: s(j['name']),
        image: s(j['image']),
        unit: s(j['unit']),
        price: toD(j['price']),
        oldPrice: j['old_price'] == null ? null : toD(j['old_price']),
        discountPercent: j['discount_percent'] == null ? null : toI(j['discount_percent']),
        inStock: j['in_stock'] == null ? true : toB(j['in_stock']),
        storeId: toI(j['store_id']),
        storeName: s(j['store_name']),
        storeOpen: j['store_open'] == null ? true : toB(j['store_open']),
        closedMessage: s(j['closed_message']),
        offerEndsAt: DateTime.tryParse(s(j['offer_ends_at'])),
      );
}

class CouponItem {
  final String code;
  final String title;
  final String label;
  final double minOrder;
  final String validUntil;
  final bool firstOrderOnly;
  final String storeName;

  const CouponItem({
    required this.code,
    required this.title,
    required this.label,
    required this.minOrder,
    required this.validUntil,
    required this.firstOrderOnly,
    required this.storeName,
  });

  factory CouponItem.fromJson(Map<String, dynamic> j) => CouponItem(
        code: s(j['code']),
        title: s(j['title']),
        label: s(j['label']),
        minOrder: toD(j['min_order']),
        validUntil: s(j['valid_until']),
        firstOrderOnly: toB(j['first_order_only']),
        storeName: s(j['store_name']),
      );
}

class DeliveryBanner {
  final bool freeEnabled;
  final double freeThreshold;
  final String standardTime;

  const DeliveryBanner({this.freeEnabled = false, this.freeThreshold = 0, this.standardTime = ''});

  factory DeliveryBanner.fromJson(Map<String, dynamic> j) => DeliveryBanner(
        freeEnabled: toB(j['free_enabled']),
        freeThreshold: toD(j['free_threshold']),
        standardTime: s(j['standard_time']),
      );
}

class HomeData {
  final String area;
  final String areaSource; // chosen / address / ''
  final bool hasLocation;
  final List<BannerItem> banners;
  final List<StoreType> storeTypes;
  final List<CategoryTile> categories;
  final int? selectedMaster;
  final String selectedMasterName;
  final List<StoreCard> stores;
  final int storesOutsideCount;
  final List<ProductCard> offers;
  final List<ProductCard> recentlyViewed;
  final List<CouponItem> coupons;
  final DeliveryBanner delivery;

  const HomeData({
    required this.area,
    required this.areaSource,
    required this.hasLocation,
    required this.banners,
    required this.storeTypes,
    required this.categories,
    required this.selectedMaster,
    required this.selectedMasterName,
    required this.stores,
    required this.storesOutsideCount,
    required this.offers,
    required this.recentlyViewed,
    required this.coupons,
    required this.delivery,
  });

  bool get isEmpty =>
      stores.isEmpty && banners.isEmpty && offers.isEmpty && categories.isEmpty && recentlyViewed.isEmpty;

  factory HomeData.fromJson(Map<String, dynamic> j) => HomeData(
        area: s(j['area']),
        areaSource: s(j['area_source']),
        hasLocation: toB(j['has_location']),
        banners: listOfMaps(j['banners']).map(BannerItem.fromJson).toList(),
        storeTypes: listOfMaps(j['store_types']).map(StoreType.fromJson).toList(),
        categories: listOfMaps(j['categories']).map(CategoryTile.fromJson).toList(),
        selectedMaster: j['selected_master'] == null ? null : toI(j['selected_master']),
        selectedMasterName: s(j['selected_master_name']),
        stores: listOfMaps(j['stores']).map(StoreCard.fromJson).toList(),
        storesOutsideCount: toI(j['stores_outside_count']),
        offers: listOfMaps(j['offers']).map(ProductCard.fromJson).toList(),
        recentlyViewed: listOfMaps(j['recently_viewed']).map(ProductCard.fromJson).toList(),
        coupons: listOfMaps(j['coupons']).map(CouponItem.fromJson).toList(),
        delivery: DeliveryBanner.fromJson(asMap(j['delivery'])),
      );
}

/// `api/customer/areas/`: shehar aur us ke areas.
class AreaItem {
  final String name;
  final String label;
  const AreaItem({required this.name, required this.label});
}

class AreaGroup {
  final String city;
  final List<AreaItem> areas;
  const AreaGroup({required this.city, required this.areas});

  factory AreaGroup.fromJson(Map<String, dynamic> j) => AreaGroup(
        city: s(j['city']),
        areas: listOfMaps(j['areas']).map((a) => AreaItem(name: s(a['name']), label: s(a['label']))).toList(),
      );
}

/// GPS bhejne ka jawab: nazdeeki store ke hisab se area ka mashwara.
class LocationResult {
  final bool saved;
  final String suggestedArea;
  final String nearestStore;
  final String nearestDistance;
  final String message;

  const LocationResult({
    required this.saved,
    required this.suggestedArea,
    required this.nearestStore,
    required this.nearestDistance,
    required this.message,
  });

  factory LocationResult.fromJson(Map<String, dynamic> j) {
    final n = asMap(j['nearest_store']);
    return LocationResult(
      saved: toB(j['saved']),
      suggestedArea: s(j['suggested_area']),
      nearestStore: s(n['name']),
      nearestDistance: s(n['distance_text']),
      message: s(j['message']),
    );
  }
}
