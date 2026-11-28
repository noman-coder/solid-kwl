import '../utils.dart';
import 'home.dart';
import 'stores.dart';

/// Server ke `api/customer/products/`, `products/{id}/` aur `search/suggest/` jawab ke hisse (Phase C6).
/// Sab fields safe parse hote hain (null / ghalat type par crash nahi).

/// List / grid ka product: Home wala card + category, brand, stock, 'add' ho sakta hai ya nahi.
class ProductItem {
  final ProductCard card;
  final int categoryId;
  final String categoryName;
  final String brand;
  final int stock;
  final bool canAdd;

  const ProductItem({
    required this.card,
    required this.categoryId,
    required this.categoryName,
    required this.brand,
    required this.stock,
    required this.canAdd,
  });

  factory ProductItem.fromJson(Map<String, dynamic> j) => ProductItem(
        card: ProductCard.fromJson(j),
        categoryId: toI(j['category_id']),
        categoryName: s(j['category_name']),
        brand: s(j['brand']),
        stock: toI(j['stock']),
        canAdd: toB(j['can_add']),
      );
}

/// Search / filter sheet ki shartein (app jo bhejti hai wahi server wapas batata hai).
class ProductQuery {
  final String q;
  final String sort; // '' = server ka default
  final int? category;
  final int? store;
  final double? priceMin;
  final double? priceMax;
  final bool inStock;

  const ProductQuery({
    this.q = '',
    this.sort = '',
    this.category,
    this.store,
    this.priceMin,
    this.priceMax,
    this.inStock = false,
  });

  /// Koi filter laga hai? (search lafz aur sort filter nahi hain)
  bool get hasFilters => category != null || store != null || priceMin != null || priceMax != null || inStock;

  /// Filter sheet mein dikhne wale filters ki ginti (badge ke liye).
  int get filterCount =>
      (category != null ? 1 : 0) + (priceMin != null || priceMax != null ? 1 : 0) + (inStock ? 1 : 0);

  ProductQuery copyWith({
    String? q,
    String? sort,
    int? category,
    int? store,
    double? priceMin,
    double? priceMax,
    bool? inStock,
    bool clearCategory = false,
    bool clearStore = false,
    bool clearPrice = false,
  }) =>
      ProductQuery(
        q: q ?? this.q,
        sort: sort ?? this.sort,
        category: clearCategory ? null : (category ?? this.category),
        store: clearStore ? null : (store ?? this.store),
        priceMin: clearPrice ? null : (priceMin ?? this.priceMin),
        priceMax: clearPrice ? null : (priceMax ?? this.priceMax),
        inStock: inStock ?? this.inStock,
      );

  Map<String, String> toParams() => {
        if (q.isNotEmpty) 'q': q,
        if (sort.isNotEmpty) 'sort': sort,
        if (category != null) 'category': '$category',
        if (store != null) 'store': '$store',
        if (priceMin != null) 'price_min': _num(priceMin!),
        if (priceMax != null) 'price_max': _num(priceMax!),
        if (inStock) 'in_stock': '1',
      };

  static String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}

class ProductListData {
  final String q;
  final String searchedQ;
  final String didYouMean;
  final String sort;
  final List<SortOption> sorts;
  final List<CategoryRef> categories;
  final List<ProductItem> products;
  final int page;
  final int total;
  final bool hasMore;

  const ProductListData({
    required this.q,
    required this.searchedQ,
    required this.didYouMean,
    required this.sort,
    required this.sorts,
    required this.categories,
    required this.products,
    required this.page,
    required this.total,
    required this.hasMore,
  });

  factory ProductListData.fromJson(Map<String, dynamic> j) => ProductListData(
        q: s(j['q']),
        searchedQ: s(j['searched_q']),
        didYouMean: s(j['did_you_mean']),
        sort: s(j['sort']),
        sorts: listOfMaps(j['sorts']).map(SortOption.fromJson).toList(),
        categories: listOfMaps(j['categories']).map(CategoryRef.fromJson).toList(),
        products: listOfMaps(j['products']).map(ProductItem.fromJson).toList(),
        page: toI(j['page'], 1),
        total: toI(j['total']),
        hasMore: toB(j['has_more']),
      );
}

class ProductImage {
  final String thumb;
  final String full;
  const ProductImage({required this.thumb, required this.full});

  factory ProductImage.fromJson(Map<String, dynamic> j) {
    final full = s(j['full']);
    final thumb = s(j['thumb']);
    return ProductImage(thumb: thumb.isEmpty ? full : thumb, full: full.isEmpty ? thumb : full);
  }
}

/// Product page par store ka chhota card.
class ProductStoreBox {
  final int id;
  final String name;
  final String logo;
  final String city;
  final String statusText;
  final bool isOpen;
  final String closedMessage;
  final double? rating;
  final int ratingCount;
  final double deliveryFee;
  final bool freeDelivery;
  final double minOrder;
  final int deliveryTimeMin;
  final int deliveryTimeMax;

  const ProductStoreBox({
    required this.id,
    required this.name,
    required this.logo,
    required this.city,
    required this.statusText,
    required this.isOpen,
    required this.closedMessage,
    required this.rating,
    required this.ratingCount,
    required this.deliveryFee,
    required this.freeDelivery,
    required this.minOrder,
    required this.deliveryTimeMin,
    required this.deliveryTimeMax,
  });

  factory ProductStoreBox.fromJson(Map<String, dynamic> j) => ProductStoreBox(
        id: toI(j['id']),
        name: s(j['name']),
        logo: s(j['logo']),
        city: s(j['city']),
        statusText: s(j['status_text']),
        isOpen: j['is_open'] == null ? true : toB(j['is_open']),
        closedMessage: s(j['closed_message']),
        rating: j['rating'] == null ? null : toD(j['rating']),
        ratingCount: toI(j['rating_count']),
        deliveryFee: toD(j['delivery_fee']),
        freeDelivery: toB(j['free_delivery']),
        minOrder: toD(j['min_order']),
        deliveryTimeMin: toI(j['delivery_time_min']),
        deliveryTimeMax: toI(j['delivery_time_max']),
      );
}

class ProductDetailData {
  final ProductItem item;
  final String description;
  final List<ProductImage> images;
  final bool servesArea;
  final String areaMessage;
  final int maxQty;
  final bool lowStock;
  final String stockText;
  final bool hasOffer;
  final int? offerPercent;
  final ProductStoreBox store;
  final List<ProductItem> related;
  final String sharePath;
  final String shareText;

  const ProductDetailData({
    required this.item,
    required this.description,
    required this.images,
    required this.servesArea,
    required this.areaMessage,
    required this.maxQty,
    required this.lowStock,
    required this.stockText,
    required this.hasOffer,
    required this.offerPercent,
    required this.store,
    required this.related,
    required this.sharePath,
    required this.shareText,
  });

  factory ProductDetailData.fromJson(Map<String, dynamic> root) {
    final j = asMap(root['product']);
    return ProductDetailData(
      item: ProductItem.fromJson(j),
      description: s(j['description']),
      images: listOfMaps(j['images']).map(ProductImage.fromJson).where((i) => i.full.isNotEmpty).toList(),
      servesArea: j['serves_area'] == null ? true : toB(j['serves_area']),
      areaMessage: s(j['area_message']),
      maxQty: toI(j['max_qty']),
      lowStock: toB(j['low_stock']),
      stockText: s(j['stock_text']),
      hasOffer: toB(j['has_offer']),
      offerPercent: j['offer_percent'] == null ? null : toI(j['offer_percent']),
      store: ProductStoreBox.fromJson(asMap(j['store'])),
      related: listOfMaps(j['related']).map(ProductItem.fromJson).toList(),
      sharePath: s(j['share_path']),
      shareText: s(j['share_text']),
    );
  }
}

/// Typing ke waqt ki suggestions.
class SuggestProduct {
  final int id;
  final String name;
  final String image;
  final String unit;
  final String storeName;
  const SuggestProduct(
      {required this.id, required this.name, required this.image, required this.unit, required this.storeName});

  factory SuggestProduct.fromJson(Map<String, dynamic> j) => SuggestProduct(
        id: toI(j['id']),
        name: s(j['name']),
        image: s(j['image']),
        unit: s(j['unit']),
        storeName: s(j['store_name']),
      );
}

class SuggestStore {
  final int id;
  final String name;
  final String logo;
  final String city;
  const SuggestStore({required this.id, required this.name, required this.logo, required this.city});

  factory SuggestStore.fromJson(Map<String, dynamic> j) =>
      SuggestStore(id: toI(j['id']), name: s(j['name']), logo: s(j['logo']), city: s(j['city']));
}

class SuggestData {
  final String q;
  final String didYouMean;
  final List<SuggestProduct> products;
  final List<SuggestStore> stores;
  final List<CategoryRef> categories;

  const SuggestData({
    required this.q,
    required this.didYouMean,
    required this.products,
    required this.stores,
    required this.categories,
  });

  bool get isEmpty => products.isEmpty && stores.isEmpty && categories.isEmpty;

  factory SuggestData.fromJson(Map<String, dynamic> j) => SuggestData(
        q: s(j['q']),
        didYouMean: s(j['did_you_mean']),
        products: listOfMaps(j['products']).map(SuggestProduct.fromJson).toList(),
        stores: listOfMaps(j['stores']).map(SuggestStore.fromJson).toList(),
        categories: listOfMaps(j['categories']).map(CategoryRef.fromJson).toList(),
      );
}
