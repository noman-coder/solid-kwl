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
  final bool needsPhoto; // Phase V9-B: photo nahi lagi (card par "Photo lagayein")

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
    this.needsPhoto = false,
  });

  factory VendorProduct.fromJson(Map<String, dynamic> m) {
    return VendorProduct(
      id: toI(m['id']),
      name: s(m['name']),
      image: pickImage(m), // list ke liye chhoti (thumb) tasveer
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
      needsPhoto: m.containsKey('needs_photo') ? m['needs_photo'] == true : s(m['image']).isEmpty,
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

// ---------------------------------------------------------------- Phase V9-A: product add / edit form

/// Category / Brand / Unit ki ek entry (dropdown / search sheet ke liye).
class NamedItem {
  final int id;
  final String name;
  const NamedItem(this.id, this.name);

  factory NamedItem.fromJson(Map<String, dynamic> m) => NamedItem(toI(m['id']), s(m['name']));
}

/// Form ke server-side hadood (form-data se aate hain, app mein hard-code nahi).
class FormLimits {
  final int nameMin;
  final int nameMax;
  final int descriptionMax;
  final double maxPrice;
  final double maxDiscount;
  final double maxStock;
  final int maxImageMb;
  final int masterNameMin;
  final int masterNameMax;
  const FormLimits({
    this.nameMin = 3,
    this.nameMax = 100,
    this.descriptionMax = 2000,
    this.maxPrice = 99999999.99,
    this.maxDiscount = 90,
    this.maxStock = 1000000,
    this.maxImageMb = 5,
    this.masterNameMin = 2,
    this.masterNameMax = 100,
  });

  factory FormLimits.fromJson(dynamic j) {
    final m = asMap(j);
    const d = FormLimits();
    return FormLimits(
      nameMin: toI(m['name_min'], d.nameMin),
      nameMax: toI(m['name_max'], d.nameMax),
      descriptionMax: toI(m['description_max'], d.descriptionMax),
      maxPrice: toD(m['max_price'], d.maxPrice),
      maxDiscount: toD(m['max_discount'], d.maxDiscount),
      maxStock: toD(m['max_stock'], d.maxStock),
      maxImageMb: toI(m['max_image_mb'], d.maxImageMb),
      masterNameMin: toI(m['master_name_min'], d.masterNameMin),
      masterNameMax: toI(m['master_name_max'], d.masterNameMax),
    );
  }
}

/// Edit form ke liye product ki maujooda values.
class ProductFormValues {
  final int id;
  final String name;
  final String description;
  final int? category;
  final int? brand;
  final int? unit;
  final double price; // discount se pehle ka rate
  final double discount;
  final double? purchaseRate; // Phase V11: vendor ka kharid rate (khali = null)
  final double currentStock;
  final String barcode;
  final String? image;
  final bool hasImage;
  final String approvalStatus;
  final String rejectionReason;

  const ProductFormValues({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.brand,
    required this.unit,
    required this.price,
    required this.discount,
    this.purchaseRate,
    required this.currentStock,
    required this.barcode,
    required this.image,
    required this.hasImage,
    required this.approvalStatus,
    required this.rejectionReason,
  });

  factory ProductFormValues.fromJson(Map<String, dynamic> m) {
    int? idOrNull(dynamic v) => v == null ? null : toI(v);
    final img = s(m['image']);
    return ProductFormValues(
      id: toI(m['id']),
      name: s(m['name']),
      description: s(m['description']),
      category: idOrNull(m['category']),
      brand: idOrNull(m['brand']),
      unit: idOrNull(m['unit']),
      price: toD(m['price']),
      discount: toD(m['discount_percentage']),
      purchaseRate: m['purchase_rate'] == null ? null : toD(m['purchase_rate']),
      currentStock: toD(m['current_stock']),
      barcode: s(m['barcode']),
      image: img.isEmpty ? null : img,
      hasImage: m['has_image'] == true,
      approvalStatus: s(m['approval_status']),
      rejectionReason: s(m['rejection_reason']),
    );
  }
}

/// GET /api/vendor/products/form-data/ ka jawab.
class ProductFormData {
  final List<NamedItem> categories;
  final List<NamedItem> brands;
  final List<NamedItem> units;
  final double commissionPercent;
  final bool autoApprove;
  final bool canAdd;
  final FormLimits limits;
  final ProductFormValues? product;

  const ProductFormData({
    required this.categories,
    required this.brands,
    required this.units,
    required this.commissionPercent,
    required this.autoApprove,
    required this.canAdd,
    required this.limits,
    required this.product,
  });

  factory ProductFormData.fromJson(Map<String, dynamic> m) => ProductFormData(
        categories: listOfMaps(m['categories']).map(NamedItem.fromJson).toList(),
        brands: listOfMaps(m['brands']).map(NamedItem.fromJson).toList(),
        units: listOfMaps(m['units']).map(NamedItem.fromJson).toList(),
        commissionPercent: toD(m['commission_percent']),
        autoApprove: m['auto_approve'] == true,
        canAdd: m['can_add'] != false,
        limits: FormLimits.fromJson(m['limits']),
        product: m['product'] is Map ? ProductFormValues.fromJson(asMap(m['product'])) : null,
      );
}

/// Product add / edit ke baad ka jawab.
class ProductSaveResult {
  final String message;
  final VendorProduct? product;
  final Map<String, int> counts;
  final bool live; // shop par nazar aa raha hai (add par)
  final bool needsPhoto; // photo abhi nahi lagi
  final bool resubmitted; // edit ke baad dobara admin review mein gaya
  final bool duplicate; // double tap / retry: pehle hi save ho chuka tha
  final bool photoFailed; // product save hua magar photo server par na lag saki

  const ProductSaveResult({
    required this.message,
    required this.product,
    required this.counts,
    required this.live,
    required this.needsPhoto,
    required this.resubmitted,
    required this.duplicate,
    this.photoFailed = false,
  });

  factory ProductSaveResult.fromJson(Map<String, dynamic> m) => ProductSaveResult(
        message: s(m['message']),
        product: m['product'] is Map ? VendorProduct.fromJson(asMap(m['product'])) : null,
        counts: countsFrom(m['counts']),
        live: m['live'] == true,
        needsPhoto: m['needs_photo'] == true,
        resubmitted: m['resubmitted'] == true,
        duplicate: m['duplicate'] == true,
        photoFailed: m['photo_failed'] == true,
      );
}
