import '../utils.dart';
import 'vendor.dart';

/// Admin ki list ka ek area (label jaise "Jahanian (Khanewal)") aur vendor ne chuna ya nahi.
class AreaOption {
  final String label;
  final bool selected;
  const AreaOption(this.label, this.selected);
}

/// Ek shehar ke areas.
class AreaGroup {
  final String city;
  final List<AreaOption> areas;
  const AreaGroup(this.city, this.areas);
}

class StoreCategoryOption {
  final int id;
  final String name;
  const StoreCategoryOption(this.id, this.name);
}

/// Store ki verified location (blue tick).
class StoreLocation {
  final bool verified;
  final bool hasLocation;
  final double? latitude;
  final double? longitude;
  final double? accuracyM;
  final String verifiedAt;
  final int maxAccuracyM;

  const StoreLocation({
    this.verified = false,
    this.hasLocation = false,
    this.latitude,
    this.longitude,
    this.accuracyM,
    this.verifiedAt = '',
    this.maxAccuracyM = 500,
  });

  factory StoreLocation.fromJson(dynamic j) {
    final m = asMap(j);
    return StoreLocation(
      verified: m['verified'] == true,
      hasLocation: m['has_location'] == true,
      latitude: m['latitude'] == null ? null : toD(m['latitude']),
      longitude: m['longitude'] == null ? null : toD(m['longitude']),
      accuracyM: m['accuracy_m'] == null ? null : toD(m['accuracy_m']),
      verifiedAt: s(m['verified_at']),
      maxAccuracyM: toI(m['max_accuracy_m'], 500),
    );
  }
}

/// Server ki `api/vendor/store/` ki settings (ek store).
class StoreSettings {
  final String name;
  final String city;
  final String description;
  final StoreCategoryOption? category;

  /// open | busy | closed
  final String status;

  /// "HH:MM" (khali = hamesha khula)
  final String opensAt;
  final String closesAt;
  final double minOrder;
  final double deliveryFee;
  final int timeMin;
  final int timeMax;

  /// Chune hue saare areas (list wale + apne likhe).
  final List<String> areas;
  final List<AreaGroup> areaGroups;

  /// Apne likhe areas (admin ki list mein nahi), comma se.
  final String areasExtra;
  final String? logo;
  final String? cover;
  final StoreLocation location;

  const StoreSettings({
    required this.name,
    required this.city,
    required this.description,
    required this.category,
    required this.status,
    required this.opensAt,
    required this.closesAt,
    required this.minOrder,
    required this.deliveryFee,
    required this.timeMin,
    required this.timeMax,
    required this.areas,
    required this.areaGroups,
    required this.areasExtra,
    required this.logo,
    required this.cover,
    required this.location,
  });

  factory StoreSettings.fromJson(dynamic j) {
    final m = asMap(j);
    final cat = m['category'] is Map ? asMap(m['category']) : null;
    return StoreSettings(
      name: s(m['name']),
      city: s(m['city']),
      description: s(m['description']),
      category: cat == null ? null : StoreCategoryOption(toI(cat['id']), s(cat['name'])),
      status: s(m['status']).isEmpty ? 'open' : s(m['status']),
      opensAt: s(m['opens_at']),
      closesAt: s(m['closes_at']),
      minOrder: toD(m['min_order_amount']),
      deliveryFee: toD(m['delivery_fee']),
      timeMin: toI(m['delivery_time_min'], 30),
      timeMax: toI(m['delivery_time_max'], 45),
      areas: m['areas'] is List ? (m['areas'] as List).map((e) => s(e)).where((e) => e.isNotEmpty).toList() : <String>[],
      areaGroups: listOfMaps(m['area_groups'])
          .map((g) => AreaGroup(
                s(g['city']),
                listOfMaps(g['areas']).map((a) => AreaOption(s(a['label']), a['selected'] == true)).toList(),
              ))
          .toList(),
      areasExtra: s(m['areas_extra']),
      logo: m['logo'] == null || s(m['logo']).isEmpty ? null : s(m['logo']),
      cover: m['cover'] == null || s(m['cover']).isEmpty ? null : s(m['cover']),
      location: StoreLocation.fromJson(m['location']),
    );
  }

  bool get hasHours => opensAt.isNotEmpty && closesAt.isNotEmpty;
}

/// Server ki hadein (validation ke liye).
class StoreLimits {
  final int descriptionMax;
  final int maxAreas;
  final int minutesMin;
  final int minutesMax;
  final double moneyMax;
  final int imageMaxMb;

  const StoreLimits({
    this.descriptionMax = 1000,
    this.maxAreas = 50,
    this.minutesMin = 5,
    this.minutesMax = 600,
    this.moneyMax = 99999.99,
    this.imageMaxMb = 5,
  });

  factory StoreLimits.fromJson(dynamic j) {
    final m = asMap(j);
    return StoreLimits(
      descriptionMax: toI(m['description_max'], 1000),
      maxAreas: toI(m['max_areas'], 50),
      minutesMin: toI(m['minutes_min'], 5),
      minutesMax: toI(m['minutes_max'], 600),
      moneyMax: toD(m['money_max'], 99999.99),
      imageMaxMb: toI(m['image_max_mb'], 5),
    );
  }
}

/// `GET /api/vendor/store/` ka poora jawab.
class StorePage {
  final StoreSettings settings;
  final List<StoreCategoryOption> categories;
  final StoreLimits limits;

  /// Switch + timing ke hisab se customer ko store abhi khula dikhta hai?
  final bool isOpen;
  final bool withinHours;

  const StorePage({
    required this.settings,
    required this.categories,
    required this.limits,
    required this.isOpen,
    required this.withinHours,
  });

  factory StorePage.fromJson(Map<String, dynamic> d) {
    final store = asMap(d['store']);
    return StorePage(
      settings: StoreSettings.fromJson(d['settings']),
      categories: listOfMaps(d['categories']).map((c) => StoreCategoryOption(toI(c['id']), s(c['name']))).toList(),
      limits: StoreLimits.fromJson(d['limits']),
      isOpen: store['is_open'] == true,
      withinHours: store['within_hours'] != false,
    );
  }
}

/// Kisi section / location save ka jawab.
class StoreSaveResult {
  final String message;
  final StoreSettings settings;
  final Vendor? vendor;
  final bool isOpen;
  final bool withinHours;

  const StoreSaveResult({
    required this.message,
    required this.settings,
    required this.vendor,
    required this.isOpen,
    required this.withinHours,
  });

  factory StoreSaveResult.fromJson(Map<String, dynamic> d) {
    final store = asMap(d['store']);
    return StoreSaveResult(
      message: s(d['message']),
      settings: StoreSettings.fromJson(d['settings']),
      vendor: d['vendor'] is Map ? Vendor.fromJson(asMap(d['vendor'])) : null,
      isOpen: store['is_open'] == true,
      withinHours: store['within_hours'] != false,
    );
  }
}
