import '../utils.dart';

/// Server ka offer `state`: live | scheduled | paused | ended
String offerStateText(String state) {
  switch (state) {
    case 'live':
      return 'Chalu';
    case 'scheduled':
      return 'Jald shuru';
    case 'paused':
      return 'Band';
    case 'ended':
      return 'Khatam';
    default:
      return state;
  }
}

class OfferProduct {
  final int id;
  final String name;
  final String? image;
  final String category;

  const OfferProduct({required this.id, required this.name, required this.image, required this.category});

  factory OfferProduct.fromJson(dynamic j) {
    final m = asMap(j);
    final img = s(m['image']);
    return OfferProduct(
      id: toI(m['id']),
      name: s(m['name']),
      image: img.isEmpty ? null : img,
      category: s(m['category']),
    );
  }
}

class Offer {
  final int id;
  final OfferProduct product;
  final double discountPercent;
  final double basePrice;
  final double regularPrice;
  final double offerPrice;
  final double productDiscount;

  /// false: product ka apna discount offer se bara / barabar hai (offer ka asar nahi).
  final bool effective;

  /// "YYYY-MM-DD"; [endsOn] aakhri din (shamil).
  final String startsOn;
  final String endsOn;
  final bool isActive;
  final String state;
  final int? daysLeft;
  final double maxPercent;
  final String shareText;

  const Offer({
    required this.id,
    required this.product,
    required this.discountPercent,
    required this.basePrice,
    required this.regularPrice,
    required this.offerPrice,
    required this.productDiscount,
    required this.effective,
    required this.startsOn,
    required this.endsOn,
    required this.isActive,
    required this.state,
    required this.daysLeft,
    required this.maxPercent,
    required this.shareText,
  });

  factory Offer.fromJson(dynamic j) {
    final m = asMap(j);
    final dl = m['days_left'];
    return Offer(
      id: toI(m['id']),
      product: OfferProduct.fromJson(m['product']),
      discountPercent: toD(m['discount_percent']),
      basePrice: toD(m['base_price']),
      regularPrice: toD(m['regular_price']),
      offerPrice: toD(m['offer_price']),
      productDiscount: toD(m['product_discount']),
      effective: m['effective'] != false,
      startsOn: s(m['starts_on']),
      endsOn: s(m['ends_on']),
      isActive: m['is_active'] != false,
      state: s(m['state']),
      daysLeft: dl == null ? null : toI(dl),
      maxPercent: toD(m['max_percent']),
      shareText: s(m['share_text']),
    );
  }

  bool get isLive => state == 'live';
  bool get isEnded => state == 'ended';
}

class OfferSummary {
  final int total;
  final int max;
  final int live;
  final int scheduled;
  final int paused;
  final int ended;

  const OfferSummary({this.total = 0, this.max = 100, this.live = 0, this.scheduled = 0, this.paused = 0, this.ended = 0});

  factory OfferSummary.fromJson(dynamic j) {
    final m = asMap(j);
    return OfferSummary(
      total: toI(m['total']),
      max: toI(m['max'], 100),
      live: toI(m['live']),
      scheduled: toI(m['scheduled']),
      paused: toI(m['paused']),
      ended: toI(m['ended']),
    );
  }
}

/// GET /api/vendor/offers/ ka jawab (aur har badlav ke baad ki taza list).
class OffersPage {
  final OfferSummary summary;
  final List<Offer> offers;
  final double minPercent;
  final double maxPercent;
  final int maxDays;

  const OffersPage(this.summary, this.offers, {this.minPercent = 1, this.maxPercent = 70, this.maxDays = 90});

  factory OffersPage.fromJson(Map<String, dynamic> m) {
    final lim = asMap(m['limits']);
    return OffersPage(
      OfferSummary.fromJson(m['summary']),
      listOfMaps(m['offers']).map(Offer.fromJson).toList(),
      minPercent: toD(lim['min_percent'], 1),
      maxPercent: toD(lim['max_percent'], 70),
      maxDays: toI(lim['max_days'], 90),
    );
  }
}

/// Create / edit / toggle / delete ka natija.
class OfferActionResult {
  final String message;
  final Offer? offer;
  final bool deleted;
  final bool duplicate;
  final OffersPage page;

  const OfferActionResult({required this.message, required this.offer, required this.deleted, required this.duplicate, required this.page});

  factory OfferActionResult.fromJson(Map<String, dynamic> m) => OfferActionResult(
        message: s(m['message']),
        offer: m['offer'] is Map ? Offer.fromJson(m['offer']) : null,
        deleted: m['deleted'] == true,
        duplicate: m['duplicate'] == true,
        page: OffersPage.fromJson(m),
      );
}

/// Offer banate waqt product chunne ki list (sirf approved + chalu products).
class OfferPick {
  final int id;
  final String name;
  final String? image;
  final String category;
  final double basePrice;
  final double regularPrice;
  final double productDiscount;
  final double maxPercent;
  final bool hasOffer;

  const OfferPick({
    required this.id,
    required this.name,
    required this.image,
    required this.category,
    required this.basePrice,
    required this.regularPrice,
    required this.productDiscount,
    required this.maxPercent,
    required this.hasOffer,
  });

  factory OfferPick.fromJson(dynamic j) {
    final m = asMap(j);
    final img = s(m['image']);
    return OfferPick(
      id: toI(m['id']),
      name: s(m['name']),
      image: img.isEmpty ? null : img,
      category: s(m['category']),
      basePrice: toD(m['base_price']),
      regularPrice: toD(m['regular_price']),
      productDiscount: toD(m['product_discount']),
      maxPercent: toD(m['max_percent']),
      hasOffer: m['has_offer'] == true,
    );
  }
}
