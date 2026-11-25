import '../utils.dart';

/// Products tab ke chips (server ke `status` / `stock` filters se). key: all | approved | pending | rejected | low | out
const List<String> kProductFilters = ['all', 'approved', 'pending', 'rejected', 'low', 'out'];
const Map<String, String> kProductFilterLabels = {
  'all': 'Sab',
  'approved': 'Approved',
  'pending': 'Pending',
  'rejected': 'Rejected',
  'low': 'Kam stock',
  'out': 'Khatam',
};

/// Vendor ka ek product (list card + quick edit).
class VendorProduct {
  final int id;
  final String name;
  final String? image;
  final String category;
  final String unit;
  final String barcode;
  final double price; // customer ko dikhne wala rate (discount ke baad)
  final double originalPrice; // discount se pehle (quick edit isi ko badalta hai)
  final double discountPercent;
  final double stock;
  final double lowThreshold;
  final String stockState; // ok | low | out
  final String approvalStatus; // approved | pending | rejected
  final String rejectionReason;
  final bool isActive;
  final bool visible; // customer ko nazar aa raha hai
  final bool canToggle;

  const VendorProduct({
    required this.id,
    required this.name,
    required this.image,
    required this.category,
    required this.unit,
    required this.barcode,
    required this.price,
    required this.originalPrice,
    required this.discountPercent,
    required this.stock,
    required this.lowThreshold,
    required this.stockState,
    required this.approvalStatus,
    required this.rejectionReason,
    required this.isActive,
    required this.visible,
    required this.canToggle,
  });

  factory VendorProduct.fromJson(Map<String, dynamic> m) {
    final img = s(m['image']);
    return VendorProduct(
      id: toI(m['id']),
      name: s(m['name']),
      image: img.isEmpty ? null : img,
      category: s(m['category']),
      unit: s(m['unit']),
      barcode: s(m['barcode']),
      price: toD(m['price']),
      originalPrice: toD(m['original_price']),
      discountPercent: toD(m['discount_percent']),
      stock: toD(m['stock']),
      lowThreshold: toD(m['low_threshold']),
      stockState: s(m['stock_state']).isEmpty ? 'ok' : s(m['stock_state']),
      approvalStatus: s(m['approval_status']).isEmpty ? 'approved' : s(m['approval_status']),
      rejectionReason: s(m['rejection_reason']),
      isActive: m['is_active'] != false,
      visible: m['visible'] == true,
      canToggle: m['can_toggle'] == true,
    );
  }

  bool get isApproved => approvalStatus == 'approved';
  bool get isPending => approvalStatus == 'pending';
  bool get isRejected => approvalStatus == 'rejected';
  bool get hasDiscount => discountPercent > 0;
}

/// Products API ka ek page.
class ProductsPage {
  final int page;
  final bool hasMore;
  final Map<String, int> counts; // all / approved / pending / rejected / low / out
  final List<VendorProduct> products;
  const ProductsPage(this.page, this.hasMore, this.counts, this.products);

  factory ProductsPage.fromJson(Map<String, dynamic> m) => ProductsPage(
        toI(m['page'], 1),
        m['has_more'] == true,
        countsFrom(m['counts']),
        listOfMaps(m['products']).map(VendorProduct.fromJson).toList(),
      );
}

Map<String, int> countsFrom(dynamic j) {
  final m = asMap(j);
  return {for (final k in kProductFilters) k: toI(m[k])};
}

/// toggle / quick-update ke baad ka jawab.
class ProductChange {
  final String message;
  final VendorProduct? product;
  final Map<String, int> counts;
  const ProductChange(this.message, this.product, this.counts);

  factory ProductChange.fromJson(Map<String, dynamic> m) => ProductChange(
        s(m['message']),
        m['product'] is Map ? VendorProduct.fromJson(asMap(m['product'])) : null,
        countsFrom(m['counts']),
      );
}
