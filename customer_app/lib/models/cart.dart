import 'dart:math' show max;

import '../utils.dart';

/// Server ke `api/customer/cart/...` jawab ke hisse (Phase C7). Sab fields safe parse hote hain
/// (null / ghalat type par crash nahi).

/// Cart ki ek line (ek product).
class CartLine {
  final int productId;
  final String name;
  final String image;
  final String unit;
  final double price;
  final double? oldPrice;
  final int? discountPercent;
  final int quantity;
  final double lineTotal;
  final int stock;
  final int maxQty;
  final int storeId;
  final String storeName;

  /// '' (theek) | unavailable | out_of_stock | store_closed | low_stock
  final String issue;
  final String issueMessage;
  final bool priceChanged;
  final double? priceWas;

  const CartLine({
    required this.productId,
    required this.name,
    required this.image,
    required this.unit,
    required this.price,
    required this.oldPrice,
    required this.discountPercent,
    required this.quantity,
    required this.lineTotal,
    required this.stock,
    required this.maxQty,
    required this.storeId,
    required this.storeName,
    required this.issue,
    required this.issueMessage,
    required this.priceChanged,
    required this.priceWas,
  });

  bool get hasIssue => issue.isNotEmpty;

  factory CartLine.fromJson(Map<String, dynamic> j) => CartLine(
        productId: toI(j['product_id']),
        name: s(j['name']),
        image: s(j['image']),
        unit: s(j['unit']),
        price: toD(j['price']),
        oldPrice: j['old_price'] == null ? null : toD(j['old_price']),
        discountPercent: j['discount_percent'] == null ? null : toI(j['discount_percent']),
        quantity: toI(j['quantity'], 1),
        lineTotal: toD(j['line_total']),
        stock: toI(j['stock']),
        maxQty: toI(j['max_qty']),
        storeId: toI(j['store_id']),
        storeName: s(j['store_name']),
        issue: s(j['issue']),
        issueMessage: s(j['issue_message']),
        priceChanged: toB(j['price_changed']),
        priceWas: j['price_was'] == null ? null : toD(j['price_was']),
      );
}

class CartStore {
  final int id;
  final String name;
  final bool isOpen;
  final String closedMessage;
  final String deliveryTime;
  final double deliveryFee;

  const CartStore({
    required this.id,
    required this.name,
    required this.isOpen,
    required this.closedMessage,
    required this.deliveryTime,
    required this.deliveryFee,
  });

  factory CartStore.fromJson(Map<String, dynamic> j) => CartStore(
        id: toI(j['id']),
        name: s(j['name']),
        isOpen: j['is_open'] == null ? true : toB(j['is_open']),
        closedMessage: s(j['closed_message']),
        deliveryTime: s(j['delivery_time']),
        deliveryFee: toD(j['delivery_fee']),
      );
}

/// 'Rs 200 aur lagayein, delivery free' wali patti (sirf jahan server bheje).
class CartFreeDelivery {
  final double threshold;
  final double remaining;
  final int percent;
  final bool unlocked;

  const CartFreeDelivery({
    required this.threshold,
    required this.remaining,
    required this.percent,
    required this.unlocked,
  });

  factory CartFreeDelivery.fromJson(Map<String, dynamic> j) => CartFreeDelivery(
        threshold: toD(j['threshold']),
        remaining: toD(j['remaining']),
        percent: toI(j['percent']).clamp(0, 100),
        unlocked: toB(j['unlocked']),
      );
}

class CartData {
  final List<CartLine> items;
  final int count;
  final double subtotal;
  final double deliveryFee;
  final bool deliveryIsFree;
  final String deliveryTime;
  final double total;
  final CartStore? store;
  final double minOrder;
  final bool minOk;
  final double shortBy;
  final CartFreeDelivery? freeDelivery;
  final bool priceChanged;
  final bool hasIssues;
  final bool canCheckout;
  final String checkoutMessage;
  final List<String> notices;

  const CartData({
    required this.items,
    required this.count,
    required this.subtotal,
    required this.deliveryFee,
    required this.deliveryIsFree,
    required this.deliveryTime,
    required this.total,
    required this.store,
    required this.minOrder,
    required this.minOk,
    required this.shortBy,
    required this.freeDelivery,
    required this.priceChanged,
    required this.hasIssues,
    required this.canCheckout,
    required this.checkoutMessage,
    required this.notices,
  });

  static const CartData empty = CartData(
    items: [],
    count: 0,
    subtotal: 0,
    deliveryFee: 0,
    deliveryIsFree: false,
    deliveryTime: '',
    total: 0,
    store: null,
    minOrder: 0,
    minOk: true,
    shortBy: 0,
    freeDelivery: null,
    priceChanged: false,
    hasIssues: false,
    canCheckout: false,
    checkoutMessage: '',
    notices: [],
  );

  bool get isEmpty => items.isEmpty;

  CartLine? lineFor(int productId) {
    for (final l in items) {
      if (l.productId == productId) return l;
    }
    return null;
  }

  factory CartData.fromJson(Map<String, dynamic> j) {
    final storeJson = j['store'];
    final freeJson = j['free_delivery'];
    return CartData(
      items: listOfMaps(j['items']).map(CartLine.fromJson).toList(),
      count: toI(j['count']),
      subtotal: toD(j['subtotal']),
      deliveryFee: toD(j['delivery_fee']),
      deliveryIsFree: toB(j['delivery_is_free']),
      deliveryTime: s(j['delivery_time']),
      total: toD(j['total']),
      store: storeJson is Map ? CartStore.fromJson(asMap(storeJson)) : null,
      minOrder: toD(j['min_order']),
      minOk: j['min_ok'] == null ? true : toB(j['min_ok']),
      shortBy: toD(j['short_by']),
      freeDelivery: freeJson is Map ? CartFreeDelivery.fromJson(asMap(freeJson)) : null,
      priceChanged: toB(j['price_changed']),
      hasIssues: toB(j['has_issues']),
      canCheckout: toB(j['can_checkout']),
      checkoutMessage: s(j['checkout_message']),
      notices: (j['notices'] is List) ? (j['notices'] as List).map((e) => s(e)).toList() : <String>[],
    );
  }

  /// Swipe se hatane par foran (server ke jawab se pehle) line hata kar dikhane ke liye. Rakam server ke jawab par theek hoti hain.
  CartData withoutProduct(int productId) {
    final left = items.where((l) => l.productId != productId).toList();
    if (left.length == items.length) return this;
    final removed = items.firstWhere((l) => l.productId == productId);
    final newSubtotal = max(0.0, subtotal - removed.lineTotal);
    return CartData(
      items: left,
      count: max(0, count - removed.quantity),
      subtotal: left.isEmpty ? 0 : newSubtotal,
      deliveryFee: left.isEmpty ? 0 : deliveryFee,
      deliveryIsFree: deliveryIsFree,
      deliveryTime: deliveryTime,
      total: left.isEmpty ? 0 : (newSubtotal + deliveryFee),
      store: left.isEmpty ? null : store,
      minOrder: minOrder,
      minOk: left.isEmpty ? true : minOk,
      shortBy: shortBy,
      freeDelivery: left.isEmpty ? null : freeDelivery,
      priceChanged: priceChanged,
      hasIssues: hasIssues,
      canCheckout: false,
      checkoutMessage: checkoutMessage,
      notices: notices,
    );
  }
}

/// add / update / merge ke baad: taza cart + (ho to) paigham.
class CartResult {
  final CartData cart;
  final String message;
  final int merged;
  final int skipped;

  const CartResult({required this.cart, this.message = '', this.merged = 0, this.skipped = 0});

  factory CartResult.fromJson(Map<String, dynamic> j) => CartResult(
        cart: CartData.fromJson(asMap(j['cart'])),
        message: s(j['message']),
        merged: toI(j['merged']),
        skipped: j['skipped'] is List ? (j['skipped'] as List).length : 0,
      );
}
