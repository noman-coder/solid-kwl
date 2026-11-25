import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/products.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../services/photo.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/notice_card.dart';
import '../widgets/skeleton.dart';

/// Phase V9: naya product / purana product edit - step-wise form (Basic -> Rate & Stock -> Photo -> Review).
/// Phase V9-B: photo camera / gallery se, crop, upload se pehle compress, progress bar + retry.
/// Product ki sirf ek main photo hoti hai. Photo na ho to product save hota hai magar photo lagne tak shop par nahi aata.
///
/// Naye product ka adhoora form khud phone mein bachta hai (draft) - net chala jaye ya app band ho to data nahi jata.
/// Submit dobara dabane / retry par server dobara product nahi banata (request key).
Future<bool> openProductForm(BuildContext context, {VendorProduct? product, bool startAtPhotos = false}) {
  return pushProductForm(Navigator.of(context), AppScope.read(context),
      product: product, startAtPhotos: startAtPhotos);
}

/// Jab BuildContext pehle hi band ho chuka ho (bottom sheet se) tab navigator + state ke saath kholo.
Future<bool> pushProductForm(NavigatorState nav, AppState st,
    {VendorProduct? product, bool startAtPhotos = false}) async {
  final r = await nav.push<bool>(MaterialPageRoute<bool>(
    fullscreenDialog: true,
    builder: (_) => AppScope(state: st, child: ProductFormScreen(product: product, startAtPhotos: startAtPhotos)),
  ));
  return r == true;
}

const String _kDraftKey = 'vendor_product_draft_v1';

String _newRequestKey() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = math.Random.secure();
  return List.generate(20, (_) => chars[r.nextInt(chars.length)]).join();
}

String _plainNum(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

class ProductFormScreen extends StatefulWidget {
  /// Edit ke liye product (list se). Null ho to naya product.
  final VendorProduct? product;

  /// Edit mein seedha Photos step se shuru (products card ka "Photo lagayein").
  final bool startAtPhotos;
  const ProductFormScreen({super.key, this.product, this.startAtPhotos = false});

  @override
  State<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends State<ProductFormScreen> {
  static const List<String> _stepLabels = ['Basic', 'Rate / Stock', 'Photo', 'Review'];
  static const int _lastStep = 3;
  static const int _photoStepIndex = 2;

  final TextEditingController _name = TextEditingController();
  final TextEditingController _desc = TextEditingController();
  final TextEditingController _price = TextEditingController();
  final TextEditingController _discount = TextEditingController();
  final TextEditingController _purchase = TextEditingController(); // Phase V11: kharid rate (profit ke liye, optional)
  final TextEditingController _stock = TextEditingController();
  final ScrollController _scroll = ScrollController();

  ProductFormData? _data;
  String? _loadError;
  bool _loading = true;

  int _step = 0;
  int? _category;
  int? _brand;
  int? _unit;

  String? _nameErr;
  String? _catErr;
  String? _priceErr;
  String? _discErr;
  String? _purchaseErr;
  String? _stockErr;
  String? _submitErr;
  bool _saving = false;
  bool _done = false;
  bool _draftRestored = false;
  String _requestKey = _newRequestKey();
  Timer? _draftTimer;

  // Phase V9-B: photo (compress ho chuki file), upload ka haal
  File? _photo;
  int _photoBytes = 0;
  bool _photoBusy = false;
  String? _photoErr;
  bool _photoErrSettings = false;
  double _upload = 0; // 0.0 - 1.0 (bheje gaye bytes)
  bool _failedOnce = false;

  bool get _editing => widget.product != null;
  bool get _hasOldPhoto => _data?.product?.hasImage ?? false;
  FormLimits get _lim => _data?.limits ?? const FormLimits();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (!_editing && !_done && _data != null) _writeDraft(); // controllers dispose hone se pehle
    _name.dispose();
    _desc.dispose();
    _price.dispose();
    _discount.dispose();
    _purchase.dispose();
    _stock.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ load

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final d = await Api.productFormData(productId: widget.product?.id);
      if (!mounted) return;
      _data = d;
      final v = d.product;
      if (v != null) {
        _name.text = v.name;
        _desc.text = v.description;
        _category = v.category;
        _brand = v.brand;
        _unit = v.unit;
        _price.text = v.price > 0 ? _plainNum(v.price) : '';
        _discount.text = v.discount > 0 ? _plainNum(v.discount) : '';
        final pr = v.purchaseRate;
        _purchase.text = pr != null && pr > 0 ? _plainNum(pr) : '';
        if (widget.startAtPhotos) _step = _photoStepIndex;
      } else {
        await _restoreDraft(d);
      }
      if (!mounted) return;
      setState(() => _loading = false);
      if (d.product == null) _recoverLostPhoto();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (await AppScope.read(context).handleApiError(e)) {
        if (mounted) Navigator.of(context).pop(false);
        return;
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.message;
      });
    }
  }

  // ------------------------------------------------------------ draft (sirf naya product)

  bool get _hasContent =>
      _name.text.trim().isNotEmpty ||
      _desc.text.trim().isNotEmpty ||
      _price.text.trim().isNotEmpty ||
      _purchase.text.trim().isNotEmpty ||
      _stock.text.trim().isNotEmpty ||
      _photo != null ||
      _category != null;

  void _scheduleDraft() {
    if (_editing) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 600), _writeDraft);
  }

  void _writeDraft() {
    if (_editing || _done) return;
    final map = <String, dynamic>{
      'name': _name.text,
      'description': _desc.text,
      'price': _price.text,
      'discount': _discount.text,
      'purchase_rate': _purchase.text,
      'stock': _stock.text,
      'category': _category,
      'brand': _brand,
      'unit': _unit,
      'step': _step,
      'key': _requestKey,
      'photo': _photo?.path ?? '',
    };
    final has = _hasContent;
    SharedPreferences.getInstance().then((p) {
      if (has) {
        p.setString(_kDraftKey, jsonEncode(map));
      } else {
        p.remove(_kDraftKey);
      }
    }).catchError((_) {});
  }

  Future<void> _clearDraft() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kDraftKey);
    } catch (_) {}
  }

  Future<void> _restoreDraft(ProductFormData d) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kDraftKey);
      if (raw == null || raw.isEmpty) return;
      final m = asMap(jsonDecode(raw));
      bool exists(List<NamedItem> l, int? id) => id != null && l.any((e) => e.id == id);
      final cat = m['category'] == null ? null : toI(m['category']);
      final brand = m['brand'] == null ? null : toI(m['brand']);
      final unit = m['unit'] == null ? null : toI(m['unit']);
      _name.text = s(m['name']);
      _desc.text = s(m['description']);
      _price.text = s(m['price']);
      _discount.text = s(m['discount']);
      _purchase.text = s(m['purchase_rate']);
      _stock.text = s(m['stock']);
      _category = exists(d.categories, cat) ? cat : null;
      _brand = exists(d.brands, brand) ? brand : null;
      _unit = exists(d.units, unit) ? unit : null;
      _step = toI(m['step']).clamp(0, _lastStep).toInt();
      // Phase V9-B: draft ki compressed photo (file abhi maujood ho to)
      final pp = s(m['photo']);
      if (pp.isNotEmpty && PhotoService.isOurs(pp)) {
        final f = File(pp);
        if (await f.exists()) {
          final n = await f.length();
          if (n > 0) {
            _photo = f;
            _photoBytes = n;
          }
        }
      }
      final key = s(m['key']);
      if (RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(key)) _requestKey = key;
      _draftRestored = _hasContent;
    } catch (_) {
      // kharab draft: chupchap nazar-andaz
    }
  }

  Future<void> _discardDraft() async {
    await _clearDraft();
    await PhotoService.deleteIfOurs(_photo?.path);
    if (!mounted) return;
    setState(() {
      _photo = null;
      _photoBytes = 0;
      _photoErr = null;
      _failedOnce = false;
      _name.clear();
      _desc.clear();
      _price.clear();
      _discount.clear();
      _purchase.clear();
      _stock.clear();
      _category = null;
      _brand = null;
      _unit = null;
      _step = 0;
      _draftRestored = false;
      _requestKey = _newRequestKey();
      _nameErr = _catErr = _priceErr = _discErr = _purchaseErr = _stockErr = _submitErr = null;
    });
  }

  // ------------------------------------------------------------ helpers

  String _nameOf(List<NamedItem> l, int? id) {
    if (id == null) return '';
    for (final e in l) {
      if (e.id == id) return e.name;
    }
    return '';
  }

  double? _num(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  /// Customer ko jo rate dikhega (discount ke baad).
  double? get _customerPrice {
    final p = _num(_price);
    final d = _num(_discount) ?? 0;
    if (p == null || p <= 0 || d < 0 || d > _lim.maxDiscount) return null;
    return p - p * d / 100;
  }

  /// Vendor ko har unit par milne wali raqam (commission ke baad) - server ke `vendor_share` jaisa (kam az kam 0.01).
  double? get _vendorShare {
    final c = _customerPrice;
    final pct = _data?.commissionPercent ?? 0;
    if (c == null) return null;
    final v = (c * (100 - pct) / 100);
    return v < 0.01 ? 0.01 : v;
  }

  void _changed() {
    if (!mounted) return;
    setState(() => _submitErr = null);
    _scheduleDraft();
  }

  // ------------------------------------------------------------ validation (server ke usool)

  bool _validateBasic() {
    String? n;
    String? c;
    final name = _name.text.trim();
    if (name.length < _lim.nameMin) n = 'Naam kam az kam ${_lim.nameMin} harf ka likhein.';
    if (_category == null) c = 'Category chunein.';
    setState(() {
      _nameErr = n;
      _catErr = c;
    });
    return n == null && c == null;
  }

  bool _validatePrice() {
    String? p;
    String? d;
    String? st;
    final price = _num(_price);
    if (price == null || price <= 0 || price > _lim.maxPrice) p = 'Sahi rate likhein (0 se zyada).';
    final disc = _discount.text.trim().isEmpty ? 0.0 : _num(_discount);
    if (disc == null || disc < 0 || disc > _lim.maxDiscount) {
      d = 'Discount 0 se ${_plainNum(_lim.maxDiscount)} ke darmiyan hona chahiye.';
    }
    String? pu;
    if (_purchase.text.trim().isNotEmpty) {
      final pr = _num(_purchase);
      if (pr == null || pr <= 0 || pr > _lim.maxPrice) pu = 'Kharid rate sahi likhein (0 se zyada) ya khali chhor dein.';
    }
    final stock = _stock.text.trim().isEmpty ? 0.0 : _num(_stock);
    if (stock == null || stock < 0 || stock > _lim.maxStock) {
      st = 'Stock sahi number hona chahiye.';
    } else if (!_editing && stock <= 0) {
      st = 'Stock 0 se zyada likhein.';
    }
    setState(() {
      _priceErr = p;
      _discErr = d;
      _purchaseErr = pu;
      _stockErr = st;
    });
    return p == null && d == null && pu == null && st == null;
  }

  void _toTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _next() {
    FocusScope.of(context).unfocus();
    if (_step == 0 && !_validateBasic()) return;
    if (_step == 1 && !_validatePrice()) return;
    if (_step == _photoStepIndex && _photoBusy) {
      _snack('Photo tayyar ho rahi hai, thora intezar karein.');
      return;
    }
    if (_step < _lastStep) {
      setState(() => _step++);
      _toTop();
      _scheduleDraft();
    } else {
      _submit();
    }
  }

  void _back() {
    FocusScope.of(context).unfocus();
    if (_step > 0) {
      setState(() => _step--);
      _toTop();
    }
  }

  void _goStep(int i) {
    if (i >= _step || _saving || _photoBusy) return;
    setState(() => _step = i);
    _toTop();
  }

  // ------------------------------------------------------------ submit

  Future<void> _submit() async {
    if (_saving) return;
    // Aakhri baar dono steps check (user peeche ja kar kuch badal sakta hai).
    if (!_validateBasic()) {
      setState(() => _step = 0);
      return;
    }
    if (!_validatePrice()) {
      setState(() => _step = 1);
      return;
    }
    if (_photoBusy) {
      _snack('Photo tayyar ho rahi hai, thora intezar karein.');
      return;
    }
    final st = AppScope.read(context);
    if (!_editing) _writeDraft(); // upload ke dauran app band ho / net toote to data + photo bacha rahe
    setState(() {
      _saving = true;
      _submitErr = null;
      _upload = 0;
    });
    final stock = _stock.text.trim().isEmpty ? 0.0 : (_num(_stock) ?? 0.0);
    final disc = _discount.text.trim().isEmpty ? 0.0 : (_num(_discount) ?? 0.0);
    final fields = <String, dynamic>{
      'name': _name.text.trim(),
      'description': _desc.text.trim(),
      'category': _category,
      'brand': _brand ?? '',
      'unit': _unit ?? '',
      'price': _num(_price),
      'discount_percentage': disc,
      // Phase V11: khali bhejne par (edit mein) kharid rate hat jata hai; naye product mein khali = nahi dena
      'purchase_rate': _purchase.text.trim(),
      'stock': stock,
    };
    final photoFile = _photo;
    final r = await st.saveProduct(
      id: widget.product?.id,
      fields: fields,
      requestKey: _requestKey, // naya aur edit dono: retry par dohra asar nahi
      photo: photoFile,
      onProgress: (v) {
        if (mounted) setState(() => _upload = v);
      },
    );
    if (!mounted) return;
    if (r.result != null) {
      _done = true;
      _draftTimer?.cancel();
      await _clearDraft();
      await PhotoService.deleteIfOurs(photoFile?.path); // kamyab: temp photo saaf
      HapticFeedback.mediumImpact();
      // Message server ka hi (live / admin approval / photo badli / photo upload na hui)
      final msg = r.result!.message;
      if (msg.isNotEmpty) st.toast(msg);
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    if (r.error == null) {
      // session khatam / approval hat gayi: AppState sambhal chuka
      if (mounted) Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _saving = false;
      _failedOnce = true;
      _submitErr = r.error;
    });
    _scheduleDraft(); // net ka masla ho to bhi data (aur photo) bacha rahe; retry par wohi request key
  }

  // ------------------------------------------------------------ photo (Phase V9-B)

  void _snack(String msg) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _choosePhoto(ImageSource source) async {
    if (_photoBusy || _saving) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _photoErr = null;
      _photoErrSettings = false;
    });
    try {
      final picked = await PhotoService.pick(source);
      if (picked == null || !mounted) return; // user ne cancel kiya
      await _processPhoto(picked);
    } on PhotoException catch (e) {
      if (!mounted) return;
      setState(() {
        _photoErr = e.message;
        _photoErrSettings = e.openSettings;
      });
    }
  }

  /// Crop -> compress -> form mein lagao. Purani compressed file hata di jati hai.
  Future<void> _processPhoto(String path) async {
    if (!mounted) return;
    setState(() => _photoBusy = true);
    try {
      final cropped = await PhotoService.crop(path);
      if (cropped == null) return; // crop cancel: kuch nahi badla
      final res = await PhotoService.compress(cropped, maxMb: _lim.maxImageMb);
      if (!mounted) {
        await PhotoService.deleteIfOurs(res.file.path);
        return;
      }
      final old = _photo?.path;
      setState(() {
        _photo = res.file;
        _photoBytes = res.bytes;
        _photoErr = null;
        _submitErr = null;
        _failedOnce = false;
      });
      if (old != null && old != res.file.path) PhotoService.deleteIfOurs(old);
      _scheduleDraft();
    } on PhotoException catch (e) {
      if (mounted) {
        setState(() {
          _photoErr = e.message;
          _photoErrSettings = false;
        });
      }
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<void> _recropPhoto() async {
    final f = _photo;
    if (f == null || _photoBusy || _saving) return;
    await _processPhoto(f.path);
  }

  Future<void> _removePhoto() async {
    final f = _photo;
    if (f == null || _photoBusy || _saving) return;
    setState(() {
      _photo = null;
      _photoBytes = 0;
      _photoErr = null;
    });
    await PhotoService.deleteIfOurs(f.path);
    _scheduleDraft();
  }

  /// Camera kholte waqt app ko system ne band kar diya ho to wo photo wapas lagao (sirf naya product).
  Future<void> _recoverLostPhoto() async {
    final path = await PhotoService.recoverLost();
    if (path == null || !mounted || _photo != null || _photoBusy) return;
    setState(() => _step = _photoStepIndex);
    await _processPhoto(path);
  }

  // ------------------------------------------------------------ pickers

  Future<void> _pickCategory() async {
    final d = _data!;
    final res = await _showPicker(
      title: 'Category chunein',
      kind: 'category',
      items: d.categories,
      selected: _category,
      allowNone: false,
    );
    if (res == null || !mounted) return;
    setState(() {
      _category = res.item?.id;
      _catErr = null;
    });
    _scheduleDraft();
  }

  Future<void> _pickBrand() async {
    final res = await _showPicker(
      title: 'Brand chunein (zaroori nahi)',
      kind: 'brand',
      items: _data!.brands,
      selected: _brand,
      allowNone: true,
    );
    if (res == null || !mounted) return;
    setState(() => _brand = res.item?.id);
    _scheduleDraft();
  }

  Future<void> _pickUnit() async {
    final res = await _showPicker(
      title: 'Unit chunein (kg, dozen...)',
      kind: 'unit',
      items: _data!.units,
      selected: _unit,
      allowNone: true,
    );
    if (res == null || !mounted) return;
    setState(() => _unit = res.item?.id);
    _scheduleDraft();
  }

  Future<_PickResult?> _showPicker({
    required String title,
    required String kind,
    required List<NamedItem> items,
    required int? selected,
    required bool allowNone,
  }) {
    final st = AppScope.read(context);
    return showModalBottomSheet<_PickResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (_) => AppScope(
        state: st,
        child: _PickerSheet(
          title: title,
          kind: kind,
          items: items,
          selected: selected,
          allowNone: allowNone,
          limits: _lim,
        ),
      ),
    );
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final title = _editing ? 'Product edit' : 'Naya product';
    final locked = (_saving && !_done) || _photoBusy;
    // Upload / photo tayyar hone ke dauran peeche jana rok do (adhoora kaam background mein na chhute).
    return PopScope(
      canPop: !locked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && locked) {
          _snack(_saving ? 'Upload chal raha hai, thora intezar karein.' : 'Photo tayyar ho rahi hai, thora intezar karein.');
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Band karein',
            onPressed: locked ? null : () => Navigator.of(context).pop(false),
          ),
        ),
        body: _body(),
        bottomNavigationBar: (_loading || _data == null || !(_data!.canAdd || _editing)) ? null : _bottomBar(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [SkeletonList(count: 4, height: 72)],
      );
    }
    if (_loadError != null || _data == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          NoticeCard(
            level: NoticeLevel.error,
            icon: Icons.cloud_off,
            text: _loadError ?? 'Form load nahi ho saka.',
            actionLabel: 'Dobara',
            onAction: _load,
          ),
        ],
      );
    }
    if (!_data!.canAdd && !_editing) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          NoticeCard(
            level: NoticeLevel.warn,
            text: 'Shop mein warehouse set nahi hai, naya product abhi nahi ban sakta. Admin se rabta karein.',
          ),
        ],
      );
    }
    return Column(
      children: [
        _StepBar(step: _step, labels: _stepLabels, onTap: _goStep),
        const Divider(height: 1),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusScope.of(context).unfocus(),
            child: ListView(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                if (_draftRestored && !_editing && _step == 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: NoticeCard(
                      level: NoticeLevel.info,
                      icon: Icons.history,
                      text: 'Pichla adhoora product wapas aa gaya.',
                      actionLabel: 'Naya shuru',
                      onAction: _discardDraft,
                    ),
                  ),
                if (_step == 0) ..._basicStep(),
                if (_step == 1) ..._priceStep(),
                if (_step == _photoStepIndex) ..._photoStep(),
                if (_step == _lastStep) ..._reviewStep(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _bottomBar() {
    final last = _step == _lastStep;
    final busy = _saving || _photoBusy;
    return Container(
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: kBorder))),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            if (_step > 0) ...[
              Expanded(
                child: OutlinedButton(onPressed: busy ? null : _back, child: const Text('Peeche')),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: busy ? null : _next,
                child: _saving
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                    : Text(last
                        ? (_failedOnce ? 'Dobara koshish karein' : (_editing ? 'Update karein' : 'Product bhejein'))
                        : (_step == _photoStepIndex && _photo == null && !_hasOldPhoto ? 'Photo ke baghair aage' : 'Aage')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ step 1: basic

  List<Widget> _basicStep() {
    final d = _data!;
    final v = d.product;
    return [
      if (v != null && v.approvalStatus == 'rejected' && v.rejectionReason.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: NoticeCard(
            level: NoticeLevel.warn,
            text: 'Admin ne reject kiya: ${v.rejectionReason}. Theek karke dobara bhejein.',
          ),
        ),
      TextField(
        controller: _name,
        maxLength: _lim.nameMax,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) {
          if (_nameErr != null) _nameErr = null;
          _changed();
        },
        decoration: InputDecoration(labelText: 'Product ka naam *', hintText: 'jaise: Basmati Chawal 5kg', errorText: _nameErr),
      ),
      const SizedBox(height: 8),
      _PickTile(
        label: 'Category *',
        value: _nameOf(d.categories, _category),
        placeholder: 'Category chunein',
        icon: Icons.category_outlined,
        errorText: _catErr,
        onTap: _pickCategory,
      ),
      const SizedBox(height: 12),
      _PickTile(
        label: 'Brand',
        value: _nameOf(d.brands, _brand),
        placeholder: 'Zaroori nahi',
        icon: Icons.sell_outlined,
        onTap: _pickBrand,
      ),
      const SizedBox(height: 12),
      _PickTile(
        label: 'Unit',
        value: _nameOf(d.units, _unit),
        placeholder: 'Zaroori nahi (kg, dozen...)',
        icon: Icons.straighten,
        onTap: _pickUnit,
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _desc,
        maxLines: 4,
        minLines: 3,
        maxLength: _lim.descriptionMax,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => _changed(),
        decoration: const InputDecoration(labelText: 'Tafseel (zaroori nahi)', alignLabelWithHint: true),
      ),
      if (v != null && v.barcode.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Barcode: ${v.barcode}', style: const TextStyle(color: Colors.black54, fontSize: 13)),
        ),
    ];
  }

  // ------------------------------------------------------------ step 2: rate / stock

  List<Widget> _priceStep() {
    final nf = FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'));
    const kb = TextInputType.numberWithOptions(decimal: true);
    final customer = _customerPrice;
    final share = _vendorShare;
    final pct = _data!.commissionPercent;
    final v = _data!.product;
    return [
      TextField(
        controller: _price,
        keyboardType: kb,
        inputFormatters: [nf],
        onChanged: (_) {
          if (_priceErr != null) _priceErr = null;
          _changed();
        },
        decoration: InputDecoration(
            labelText: 'Rate (discount se pehle) *', prefixText: 'Rs ', errorText: _priceErr),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _discount,
        keyboardType: kb,
        inputFormatters: [nf],
        onChanged: (_) {
          if (_discErr != null) _discErr = null;
          _changed();
        },
        decoration: InputDecoration(
            labelText: 'Discount (0 - ${_plainNum(_lim.maxDiscount)})', hintText: '0', suffixText: '%', errorText: _discErr),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _purchase,
        keyboardType: kb,
        inputFormatters: [nf],
        onChanged: (_) {
          if (_purchaseErr != null) _purchaseErr = null;
          _changed();
        },
        decoration: InputDecoration(
          labelText: 'Kharid rate (optional)',
          prefixText: 'Rs ',
          helperText: 'Profit hisaab ke liye. Customer ko nahi dikhta.',
          helperMaxLines: 2,
          errorText: _purchaseErr,
        ),
      ),
      if (customer != null)
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kTeal.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Customer ko rate: ${rs(double.parse(customer.toStringAsFixed(2)))}',
                  style: const TextStyle(fontWeight: FontWeight.w800, color: kTealDark)),
              if (share != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Aap ko milega: ${rs(double.parse(share.toStringAsFixed(2)))} har unit par'
                  '${pct > 0 ? ' (shop ka commission ${_plainNum(pct)}% ke baad)' : ''}',
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                ),
              ],
            ],
          ),
        ),
      const SizedBox(height: 20),
      if (_editing && v != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('Abhi stock: ${numText(v.currentStock)}', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      TextField(
        controller: _stock,
        keyboardType: kb,
        inputFormatters: [nf],
        onChanged: (_) {
          if (_stockErr != null) _stockErr = null;
          _changed();
        },
        decoration: InputDecoration(
          labelText: _editing ? 'Naya stock jama karein' : 'Stock (kitna maal hai) *',
          hintText: _editing ? '0' : null,
          errorText: _stockErr,
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          _editing
              ? 'Ye stock mein jama hoga (purana stock kam nahi hota). Khali chhorein to stock waisa hi rahega.'
              : 'Ye shuruati stock hai; baad mein Products tab se barha sakte hain.',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ),
    ];
  }

  // ------------------------------------------------------------ step 3: photo (Phase V9-B)

  List<Widget> _photoStep() {
    final v = _data!.product;
    final oldUrl = (v != null && v.hasImage) ? v.image : null;
    final disabled = _photoBusy || _saving;
    final hasAny = _photo != null || oldUrl != null;
    return [
      const Text('Product ki photo', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
      const SizedBox(height: 4),
      const Text(
        'Saaf, roshni wali photo lagayein, product beech mein. Photo bhejne se pehle khud chhoti ho jati hai (data bachta hai).',
        style: TextStyle(fontSize: 12.5, color: Colors.black54),
      ),
      const SizedBox(height: 12),
      _PhotoPreview(file: _photo, networkUrl: oldUrl, busy: _photoBusy),
      const SizedBox(height: 8),
      if (_photo != null)
        Text('Nayi photo tayyar - ${fileSizeText(_photoBytes)}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700, color: kTealDark))
      else if (oldUrl != null)
        const Text('Ye maujooda photo hai. Nayi na chunein to yahi rahegi.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.black54, fontSize: 13)),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: disabled ? null : () => _choosePhoto(ImageSource.camera),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Camera'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: disabled ? null : () => _choosePhoto(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Gallery'),
            ),
          ),
        ],
      ),
      if (_photo != null)
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton.icon(
              onPressed: disabled ? null : _recropPhoto,
              icon: const Icon(Icons.crop),
              label: const Text('Dobara crop'),
            ),
            TextButton.icon(
              onPressed: disabled ? null : _removePhoto,
              icon: const Icon(Icons.delete_outline),
              label: Text(oldUrl != null ? 'Nayi photo hatayein' : 'Photo hatayein'),
            ),
          ],
        ),
      if (_photoErr != null) ...[
        const SizedBox(height: 8),
        NoticeCard(
          level: NoticeLevel.error,
          text: _photoErr!,
          actionLabel: _photoErrSettings ? 'Settings' : null,
          onAction: _photoErrSettings ? () => openAppSettings() : null,
        ),
      ],
      if (!hasAny) ...[
        const SizedBox(height: 12),
        const NoticeCard(
          level: NoticeLevel.warn,
          icon: Icons.photo_camera_outlined,
          text: 'Photo ke baghair product save to ho jayega, lekin shop par tab tak nazar nahi aayega jab tak photo na lage. Baad mein Products se "Photo lagayein" dabakar laga sakte hain.',
        ),
      ],
      if (oldUrl != null && !_data!.autoApprove) ...[
        const SizedBox(height: 12),
        const NoticeCard(
          level: NoticeLevel.info,
          text: 'Photo badalne par product dobara admin review mein ja sakta hai.',
        ),
      ],
    ];
  }

  // ------------------------------------------------------------ step 4: review

  List<Widget> _reviewStep() {
    final d = _data!;
    final customer = _customerPrice;
    final share = _vendorShare;
    final disc = _num(_discount) ?? 0;
    final stock = _num(_stock) ?? 0;
    final v = d.product;
    final newPhoto = _photo != null;
    final hadPhoto = v?.hasImage ?? false;
    final noPhoto = !newPhoto && !hadPhoto;
    final unit = _nameOf(d.units, _unit);

    // Is submit ke baad kya hoga (asli natija server ka message batayega)
    String after;
    if (_editing) {
      if (d.autoApprove) {
        after = 'Tabdeeli foran lagu ho jayegi.';
      } else if (newPhoto && hadPhoto) {
        after = 'Photo badalne par product dobara admin review mein jayega, aur review tak shop par nazar nahi aayega.';
      } else if (newPhoto) {
        after = 'Photo lagne ke baad product admin approval par shop par aayega.';
      } else {
        after = 'Naam, tafseel, category ya brand badalne par product dobara admin review mein jayega; sirf rate / stock badalne par nahi.';
      }
    } else if (noPhoto) {
      after = 'Product save ho jayega, lekin photo lagne tak shop par nazar nahi aayega.';
    } else {
      after = d.autoApprove ? 'Product foran shop par list ho jayega.' : 'Admin approval ke baad shop par nazar aayega.';
    }

    return [
      _ReviewCard(
        title: 'Basic',
        onEdit: () => _goStep(0),
        rows: [
          ('Naam', _name.text.trim()),
          ('Category', _nameOf(d.categories, _category)),
          ('Brand', _nameOf(d.brands, _brand).isEmpty ? '-' : _nameOf(d.brands, _brand)),
          ('Unit', unit.isEmpty ? '-' : unit),
          if (_desc.text.trim().isNotEmpty) ('Tafseel', _desc.text.trim()),
        ],
      ),
      const SizedBox(height: 12),
      _ReviewCard(
        title: 'Rate / Stock',
        onEdit: () => _goStep(1),
        rows: [
          ('Rate', _num(_price) == null ? '-' : rs(_num(_price)!)),
          ('Discount', disc > 0 ? '${_plainNum(disc)}%' : 'Nahi'),
          if (_num(_purchase) != null) ('Kharid rate', rs(_num(_purchase)!)),
          if (customer != null) ('Customer ko rate', rs(double.parse(customer.toStringAsFixed(2)))),
          if (share != null) ('Aap ko milega', rs(double.parse(share.toStringAsFixed(2)))),
          (_editing ? 'Naya stock' : 'Stock', '${numText(stock)}${unit.isEmpty ? '' : ' $unit'}'),
        ],
      ),
      const SizedBox(height: 12),
      _PhotoReviewCard(
        file: _photo,
        bytes: _photoBytes,
        oldUrl: hadPhoto ? v?.image : null,
        onEdit: () => _goStep(_photoStepIndex),
      ),
      const SizedBox(height: 12),
      NoticeCard(
        level: noPhoto ? NoticeLevel.warn : NoticeLevel.info,
        icon: noPhoto ? Icons.photo_camera_outlined : Icons.info_outline,
        text: noPhoto ? 'Photo abhi nahi lagi. $after' : after,
        actionLabel: noPhoto && !_saving ? 'Photo lagayein' : null,
        onAction: noPhoto && !_saving ? () => _goStep(_photoStepIndex) : null,
      ),
      if (_saving) ...[
        const SizedBox(height: 12),
        _UploadCard(hasPhoto: _photo != null, progress: _upload),
      ],
      if (_submitErr != null && !_saving) ...[
        const SizedBox(height: 12),
        NoticeCard(
          level: NoticeLevel.error,
          text: _photo != null
              ? '$_submitErr\nForm ka baqi data aur photo bachi hui hai - "Dobara koshish karein" dabayein.'
              : _submitErr!,
          actionLabel: _photo != null ? 'Photo badlein' : null,
          onAction: _photo != null ? () => _goStep(_photoStepIndex) : null,
        ),
      ],
    ];
  }
}

// ---------------------------------------------------------------- pieces

class _StepBar extends StatelessWidget {
  final int step;
  final List<String> labels;
  final void Function(int) onTap;
  const _StepBar({required this.step, required this.labels, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0)
              Expanded(
                child: Container(height: 2, color: i <= step ? kTeal : kBorder),
              ),
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => onTap(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor: i <= step ? kTeal : Colors.grey.shade300,
                      child: i < step
                          ? const Icon(Icons.check, size: 14, color: Colors.white)
                          : Text('${i + 1}',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: i == step ? Colors.white : Colors.black54)),
                    ),
                    // 4 step chhoti screen par na samayein: naam sirf maujooda step ka
                    if (i == step) ...[
                      const SizedBox(width: 6),
                      Text(labels[i],
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: kTealDark)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PickTile extends StatelessWidget {
  final String label;
  final String value;
  final String placeholder;
  final IconData icon;
  final String? errorText;
  final VoidCallback onTap;
  const _PickTile({
    required this.label,
    required this.value,
    required this.placeholder,
    required this.icon,
    required this.onTap,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          errorText: errorText,
          prefixIcon: Icon(icon),
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: Text(
          value.isEmpty ? placeholder : value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 16,
            color: value.isEmpty ? Colors.black45 : Colors.black87,
            fontWeight: value.isEmpty ? FontWeight.w400 : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final String title;
  final VoidCallback onEdit;
  final List<(String, String)> rows;
  const _ReviewCard({required this.title, required this.onEdit, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15))),
                TextButton(onPressed: onEdit, child: const Text('Badlein')),
              ],
            ),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 6, right: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 110, child: Text(r.$1, style: const TextStyle(color: Colors.black54))),
                    Expanded(child: Text(r.$2, style: const TextStyle(fontWeight: FontWeight.w700))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Photo ka bara preview (nayi photo file, ya purani photo ka link, ya khali).
class _PhotoPreview extends StatelessWidget {
  final File? file;
  final String? networkUrl;
  final bool busy;
  const _PhotoPreview({required this.file, required this.networkUrl, required this.busy});

  @override
  Widget build(BuildContext context) {
    Widget empty() => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_a_photo_outlined, size: 44, color: Colors.black38),
              SizedBox(height: 8),
              Text('Abhi photo nahi lagi', style: TextStyle(color: Colors.black54)),
            ],
          ),
        );
    Widget child;
    if (file != null) {
      child = Image.file(file!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => empty());
    } else if (networkUrl != null) {
      child = Image.network(Api.absUrl(networkUrl!), fit: BoxFit.cover, errorBuilder: (_, __, ___) => empty());
    } else {
      child = empty();
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(color: kBg, child: child),
                if (busy)
                  Container(
                    color: Colors.black45,
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 10),
                          Text('Photo tayyar ho rahi hai...',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Review mein photo ka chhota card.
class _PhotoReviewCard extends StatelessWidget {
  final File? file;
  final int bytes;
  final String? oldUrl;
  final VoidCallback onEdit;
  const _PhotoReviewCard({required this.file, required this.bytes, required this.oldUrl, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final has = file != null || oldUrl != null;
    final label = file != null
        ? (oldUrl != null ? 'Nayi photo (purani badlegi) - ${fileSizeText(bytes)}' : 'Nayi photo - ${fileSizeText(bytes)}')
        : (oldUrl != null ? 'Maujooda photo (waisi hi rahegi)' : 'Nahi lagi');
    Widget thumb;
    if (file != null) {
      thumb = Image.file(file!, width: 64, height: 64, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox());
    } else if (oldUrl != null) {
      thumb = Image.network(Api.absUrl(oldUrl!),
          width: 64, height: 64, fit: BoxFit.cover, cacheWidth: 200, errorBuilder: (_, __, ___) => const SizedBox());
    } else {
      thumb = const Icon(Icons.photo_camera_outlined, color: Colors.black38);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Photo', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15))),
                TextButton(onPressed: onEdit, child: Text(has ? 'Badlein' : 'Lagayein')),
              ],
            ),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 64,
                    height: 64,
                    color: kBg,
                    alignment: Alignment.center,
                    child: thumb,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Bhejte waqt ka progress: photo ho to upload %, phir "server par save".
class _UploadCard extends StatelessWidget {
  final bool hasPhoto;
  final double progress;
  const _UploadCard({required this.hasPhoto, required this.progress});

  @override
  Widget build(BuildContext context) {
    final uploading = hasPhoto && progress < 1;
    final text = !hasPhoto
        ? 'Product save ho raha hai...'
        : uploading
            ? 'Photo upload ho rahi hai ${(progress * 100).round()}%'
            : 'Server par save ho raha hai...';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: uploading ? progress : null, minHeight: 8),
            ),
            const SizedBox(height: 8),
            const Text('Screen band na karein, thora intezar karein.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
      ),
    );
  }
}

/// Picker ka nateeja: item null = "koi nahi" (clear). Sheet band karne (dismiss) par null wapas (kuch nahi badla).
class _PickResult {
  final NamedItem? item;
  const _PickResult(this.item);
}

/// Search wali list (category / brand / unit). Naam na mile to "naya banayein" ka option.
class _PickerSheet extends StatefulWidget {
  final String title;
  final String kind;
  final List<NamedItem> items;
  final int? selected;
  final bool allowNone;
  final FormLimits limits;
  const _PickerSheet({
    required this.title,
    required this.kind,
    required this.items,
    required this.selected,
    required this.allowNone,
    required this.limits,
  });

  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  final TextEditingController _q = TextEditingController();
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  String get _query => _q.text.trim();

  List<NamedItem> get _filtered {
    final q = _query.toLowerCase();
    if (q.isEmpty) return widget.items;
    return widget.items.where((e) => e.name.toLowerCase().contains(q)).toList();
  }

  bool get _canCreate {
    final q = _query;
    if (q.length < widget.limits.masterNameMin || q.length > widget.limits.masterNameMax) return false;
    return !widget.items.any((e) => e.name.toLowerCase() == q.toLowerCase());
  }

  Future<void> _create() async {
    if (_creating) return;
    final name = _query.split(RegExp(r'\s+')).join(' ');
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final item = await Api.createMaster(widget.kind, name);
      if (!mounted) return;
      if (!widget.items.any((e) => e.id == item.id)) {
        widget.items.add(item);
        widget.items.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      }
      Navigator.of(context).pop(_PickResult(item));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (await AppScope.read(context).handleApiError(e)) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = e.message;
      });
    }
  }

  String get _kindLabel => switch (widget.kind) {
        'category' => 'category',
        'brand' => 'brand',
        _ => 'unit',
      };

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final inset = mq.viewInsets.bottom;
    final maxH = math.max(260.0, mq.size.height - inset - 120);
    final height = math.min(mq.size.height * 0.8, maxH);
    final list = _filtered;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(widget.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _q,
                onChanged: (_) => setState(() => _error = null),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Dhoondein ya naya naam likhein',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _q.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                                _q.clear();
                                _error = null;
                              })),
                  isDense: true,
                  filled: true,
                  fillColor: kBg,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(_error!, style: TextStyle(color: Colors.red.shade800, fontWeight: FontWeight.w600)),
              ),
            Expanded(
              child: ListView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  if (_canCreate)
                    ListTile(
                      leading: _creating
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : const Icon(Icons.add_circle_outline, color: kTeal),
                      title: Text('"$_query" naya $_kindLabel banayein',
                          style: const TextStyle(fontWeight: FontWeight.w800, color: kTealDark)),
                      onTap: _creating ? null : _create,
                    ),
                  if (widget.allowNone && _query.isEmpty)
                    ListTile(
                      leading: const Icon(Icons.block, color: Colors.black45),
                      title: const Text('Koi nahi'),
                      trailing: widget.selected == null ? const Icon(Icons.check, color: kTeal) : null,
                      onTap: () => Navigator.of(context).pop(const _PickResult(null)),
                    ),
                  for (final it in list)
                    ListTile(
                      title: Text(it.name),
                      trailing: it.id == widget.selected ? const Icon(Icons.check, color: kTeal) : null,
                      onTap: () => Navigator.of(context).pop(_PickResult(it)),
                    ),
                  if (list.isEmpty && !_canCreate)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('Kuch nahi mila.', style: TextStyle(color: Colors.black54))),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
