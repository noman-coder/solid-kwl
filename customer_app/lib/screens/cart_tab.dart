import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/cart.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/content_width.dart';
import '../widgets/empty_state.dart';
import '../widgets/net_image.dart';
import '../widgets/notice_card.dart';
import '../widgets/skeleton.dart';
import 'login.dart';
import 'product_detail.dart';

/// Phase C7: Cart tab. Login customer ka server cart, guest ka phone wala cart - dono ek jaisa.
/// Item card (qty stepper, swipe se hatao), subtotal, delivery fee, minimum order warning, free-delivery bar,
/// "qeemat badal gayi" alert aur neeche checkout patti (checkout khud Phase C8 mein judega).
class CartTab extends StatefulWidget {
  const CartTab({super.key});

  @override
  State<CartTab> createState() => _CartTabState();
}

class _CartTabState extends State<CartTab> {
  static const int _cartIndex = 2;
  bool _wasActive = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final active = state.tab == _cartIndex;
    // Cart tab par aate hi taza qeemat / stock (peeche se, skeleton ke baghair)
    if (active && !_wasActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) AppScope.read(context).cart.refresh(silent: true);
      });
    }
    _wasActive = active;
  }

  void _toast(String msg) => AppScope.read(context).say(msg);

  Future<void> _setQty(CartLine l, int qty) async {
    if (qty <= 0) {
      HapticFeedback.mediumImpact();
      return _remove(l);                       // 1 se kam = hatao ("Wapas" ka mauqa milta hai)
    }
    final cart = AppScope.read(context).cart;
    HapticFeedback.selectionClick();
    final err = await cart.setQty(l.productId, qty);
    if (err != null && mounted) _toast(err);
  }

  Future<void> _remove(CartLine l) async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final err = await state.cart.remove(l.productId);
    if (!mounted) return;
    if (err != null) {
      _toast(err);
      return;
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text('${l.name} hata diya.', maxLines: 1, overflow: TextOverflow.ellipsis),
      action: SnackBarAction(
        label: 'Wapas',
        textColor: kOrangeSoft,
        onPressed: () async {
          final out = await state.cart.add(
            productId: l.productId,
            storeId: l.storeId,
            storeName: l.storeName,
            qty: l.quantity,
            maxQty: l.maxQty,
          );
          if (!out.ok) state.say(out.message);
        },
      ),
    ));
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cart khali karein?'),
        content: const Text('Cart ke saare items hat jayenge.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Nahi')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Khali karein')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final err = await AppScope.read(context).cart.clear();
    if (err != null && mounted) _toast(err);
  }

  Future<void> _checkout(CartData d) async {
    final state = AppScope.read(context);
    if (!state.loggedIn) {
      final ok = await ensureLoggedIn(context);
      if (!ok || !mounted) return;               // login ke baad guest cart khud server cart mein jud jata hai
    }
    final fresh = state.cart.data ?? d;
    if (!fresh.canCheckout) {
      _toast(fresh.checkoutMessage.isNotEmpty ? fresh.checkoutMessage : 'Cart theek karke dobara try karein.');
      return;
    }
    // Checkout (address, delivery, payment, order) Phase C8 mein judega.
    _toast('Checkout ka hissa agle phase (C8) mein aa raha hai. Aap ka cart mehfooz hai.');
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final cart = state.cart;
    final data = cart.data;

    if (data == null) {
      if (cart.error != null && !cart.loading) {
        return EmptyState(
          icon: cart.error!.isNetwork ? Icons.wifi_off_rounded : Icons.shopping_cart_outlined,
          title: 'Cart nahi khul saka',
          message: cart.error!.message,
          action: FilledButton(onPressed: () => cart.refresh(), child: const Text('Dobara koshish karein')),
        );
      }
      return const _CartSkeleton();
    }

    if (data.isEmpty) {
      return RefreshIndicator(
        color: kOrange,
        onRefresh: () => cart.refresh(silent: true),
        child: EmptyState(
          icon: Icons.shopping_cart_outlined,
          title: 'Cart khali hai',
          message: 'Apni pasand ke products cart mein dalein aur order karein.',
          action: FilledButton(onPressed: () => state.openStores(), child: const Text('Stores dekhein')),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            color: kOrange,
            onRefresh: () => cart.refresh(silent: true),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
              children: [
                ContentWidth(
                  maxWidth: 720,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (cart.error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: NoticeCard(
                            level: NoticeLevel.warn,
                            text: cart.error!.isNetwork
                                ? 'Net nahi hai. Purana cart dikh raha hai.'
                                : 'Cart taza nahi ho saka. Purana dikh raha hai.',
                            actionLabel: 'Dobara',
                            onAction: () => cart.refresh(silent: true),
                          ),
                        ),
                      _StoreHeader(data: data),
                      if (data.priceChanged)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: NoticeCard(
                            level: NoticeLevel.warn,
                            text: 'Kuch items ki qeemat badal gayi hai. Naya total neeche hai.',
                            actionLabel: 'Theek hai',
                            onAction: cart.acknowledgePrices,
                          ),
                        ),
                      if (data.store != null && !data.store!.isOpen)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: NoticeCard(
                            level: NoticeLevel.error,
                            text: data.store!.closedMessage.isNotEmpty
                                ? data.store!.closedMessage
                                : 'Store abhi band hai.',
                          ),
                        ),
                      const SizedBox(height: 10),
                      for (final l in data.items)
                        _CartLineCard(
                          key: ValueKey('cart_${l.productId}'),
                          line: l,
                          busy: cart.busy.contains(l.productId),
                          onDismissed: () => _remove(l),
                          onMinus: () => _setQty(l, l.quantity - 1),
                          onPlus: () {
                            final limit = l.maxQty > 0 ? l.maxQty : 1000;
                            if (l.quantity >= limit) {
                              _toast(l.maxQty > 0 ? 'Itna hi stock hai (${l.maxQty}).' : 'Ab aur nahi barh sakta.');
                            } else {
                              _setQty(l, l.quantity + 1);
                            }
                          },
                          onOpen: () => openProduct(context, l.productId),
                        ),
                      if (data.freeDelivery != null) _FreeDeliveryBar(info: data.freeDelivery!),
                      if (!data.minOk && data.minOrder > 0) _MinOrderCard(data: data),
                      const SizedBox(height: 4),
                      _BillCard(data: data),
                      Align(
                        alignment: Alignment.center,
                        child: TextButton.icon(
                          onPressed: _confirmClear,
                          icon: const Icon(Icons.delete_outline_rounded, size: 20),
                          label: const Text('Cart khali karein'),
                          style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        _CheckoutBar(data: data, onCheckout: () => _checkout(data)),
      ],
    );
  }
}

// ---------------------------------------------------------------- upar ki patti: store ka naam + delivery waqt

class _StoreHeader extends StatelessWidget {
  final CartData data;
  const _StoreHeader({required this.data});

  @override
  Widget build(BuildContext context) {
    final st = data.store;
    final name = st?.name ?? (data.items.isNotEmpty ? data.items.first.storeName : '');
    if (name.isEmpty) return const SizedBox.shrink();
    final time = st != null && st.deliveryTime.isNotEmpty ? st.deliveryTime : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
        boxShadow: kSoftShadow,
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 20,
            backgroundColor: kOrangeSoft,
            child: Icon(Icons.storefront_rounded, color: kOrange),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: kInk)),
                if (time.isNotEmpty)
                  Text('Delivery: $time', style: const TextStyle(fontSize: 12.5, color: kMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- ek item ka card

class _CartLineCard extends StatelessWidget {
  final CartLine line;
  final bool busy;
  final VoidCallback onDismissed;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback onOpen;

  const _CartLineCard({
    super.key,
    required this.line,
    required this.busy,
    required this.onDismissed,
    required this.onMinus,
    required this.onPlus,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final l = line;
    final dim = l.issue == 'unavailable' || l.issue == 'out_of_stock';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Dismissible(
        key: ValueKey('dismiss_${l.productId}'),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => onDismissed(),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 22),
          decoration: BoxDecoration(color: Colors.red.shade600, borderRadius: BorderRadius.circular(16)),
          child: const Icon(Icons.delete_outline_rounded, color: Colors.white, size: 28),
        ),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: l.hasIssue ? Colors.red.shade200 : kBorder),
            boxShadow: kSoftShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: l.issue == 'unavailable' ? null : onOpen,
                    borderRadius: BorderRadius.circular(12),
                    child: Opacity(
                      opacity: dim ? 0.5 : 1,
                      child: NetImage(path: l.image, width: 72, height: 72, radius: 12),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w800, height: 1.2, color: dim ? kMuted : kInk)),
                        if (l.unit.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(l.unit, style: const TextStyle(fontSize: 12.5, color: kMuted)),
                          ),
                        const SizedBox(height: 4),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.end,
                          spacing: 6,
                          children: [
                            Text(rs(l.price),
                                style: const TextStyle(
                                    fontSize: 14.5, fontWeight: FontWeight.w900, color: kOrangeDark)),
                            if (l.oldPrice != null)
                              Text(rs(l.oldPrice),
                                  style: const TextStyle(
                                      fontSize: 12, color: kMuted, decoration: TextDecoration.lineThrough)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (l.priceChanged && l.priceWas != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _Chip(
                    icon: Icons.price_change_outlined,
                    text: 'Qeemat badli: ${rs(l.priceWas)} se ${rs(l.price)}',
                    color: Colors.amber.shade900,
                    bg: Colors.amber.shade50,
                  ),
                ),
              if (l.hasIssue)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _Chip(
                    icon: Icons.error_outline_rounded,
                    text: l.issueMessage.isNotEmpty ? l.issueMessage : 'Yeh item abhi order nahi ho sakta.',
                    color: Colors.red.shade800,
                    bg: Colors.red.shade50,
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (l.issue == 'unavailable')
                    TextButton.icon(
                      onPressed: onDismissed,
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      label: const Text('Hata dein'),
                      style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
                    )
                  else
                    _Stepper(
                      quantity: l.quantity,
                      busy: busy,
                      onMinus: onMinus,
                      onPlus: onPlus,
                    ),
                  const Spacer(),
                  Text(rs(l.lineTotal),
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w900, color: dim ? kMuted : kInk)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  final Color bg;
  const _Chip({required this.icon, required this.text, required this.color, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
          ),
        ],
      ),
    );
  }
}

/// - [qty] + : quantity 1 ho to minus ki jagah kuda-daan (item hat jata hai, 'Wapas' ka mauqa milta hai).
class _Stepper extends StatelessWidget {
  final int quantity;
  final bool busy;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _Stepper({required this.quantity, required this.busy, required this.onMinus, required this.onPlus});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kOrangeSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: quantity <= 1 ? 'Hata dein' : 'Kam karein',
            visualDensity: VisualDensity.compact,
            onPressed: busy ? null : onMinus,
            icon: Icon(quantity <= 1 ? Icons.delete_outline_rounded : Icons.remove_rounded),
          ),
          SizedBox(
            width: 30,
            child: busy
                ? const Center(
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                : Text('$quantity',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: kInk)),
          ),
          IconButton(
            tooltip: 'Zyada karein',
            visualDensity: VisualDensity.compact,
            onPressed: busy ? null : onPlus,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- free delivery / minimum order / bill

class _FreeDeliveryBar extends StatelessWidget {
  final CartFreeDelivery info;
  const _FreeDeliveryBar({required this.info});

  @override
  Widget build(BuildContext context) {
    final unlocked = info.unlocked;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: unlocked ? kGreenSoft : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: unlocked ? kGreen.withValues(alpha: 0.4) : kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.local_shipping_outlined, size: 20, color: unlocked ? kGreen : kOrange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  unlocked
                      ? 'Mubarak ho! Delivery free hai.'
                      : '${rs(info.remaining)} aur lagayein, delivery free',
                  style: TextStyle(fontWeight: FontWeight.w800, color: unlocked ? kGreen : kInk),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: info.percent / 100),
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOut,
              builder: (_, v, __) => LinearProgressIndicator(
                value: v,
                minHeight: 8,
                backgroundColor: kOrangeSoft,
                color: unlocked ? kGreen : kOrange,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MinOrderCard extends StatelessWidget {
  final CartData data;
  const _MinOrderCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: NoticeCard(
        level: NoticeLevel.warn,
        icon: Icons.shopping_basket_outlined,
        text: 'Minimum order ${rs(data.minOrder)} hai. Aur ${rs(data.shortBy)} ka maal add karein.',
      ),
    );
  }
}

class _BillCard extends StatelessWidget {
  final CartData data;
  const _BillCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
        boxShadow: kSoftShadow,
      ),
      child: Column(
        children: [
          _BillRow(label: 'Items (${data.count})', value: rs(data.subtotal)),
          const SizedBox(height: 8),
          _BillRow(
            label: 'Delivery',
            value: data.deliveryIsFree ? 'Free' : rs(data.deliveryFee),
            valueColor: data.deliveryIsFree ? kGreen : null,
          ),
          const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(height: 1, color: kBorder)),
          _BillRow(label: 'Total', value: rs(data.total), bold: true),
        ],
      ),
    );
  }
}

class _BillRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final Color? valueColor;
  const _BillRow({required this.label, required this.value, this.bold = false, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: bold ? 17 : 14.5,
      fontWeight: bold ? FontWeight.w900 : FontWeight.w600,
      color: bold ? kInk : kMuted,
    );
    return Row(
      children: [
        Expanded(child: Text(label, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)),
        Text(value, style: style.copyWith(color: valueColor ?? (bold ? kOrangeDark : kInk))),
      ],
    );
  }
}

// ---------------------------------------------------------------- neeche ki checkout patti

class _CheckoutBar extends StatelessWidget {
  final CartData data;
  final VoidCallback onCheckout;
  const _CheckoutBar({required this.data, required this.onCheckout});

  @override
  Widget build(BuildContext context) {
    final blocked = !data.canCheckout && data.checkoutMessage.isNotEmpty;
    return Material(
      color: Colors.white,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: ContentWidth(
          maxWidth: 720,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (blocked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(data.checkoutMessage,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.red.shade700)),
                  ),
                Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Total', style: TextStyle(fontSize: 12, color: kMuted)),
                        Text(rs(data.total),
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: kInk)),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: FilledButton(
                        onPressed: data.canCheckout ? onCheckout : null,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        child: const Text('Checkout karein', maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- loading

class _CartSkeleton extends StatelessWidget {
  const _CartSkeleton();

  @override
  Widget build(BuildContext context) {
    return SkeletonScope(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(14),
        children: [
          const SkeletonBox(height: 62, radius: 16),
          const SizedBox(height: 12),
          for (var i = 0; i < 3; i++) ...[
            const SkeletonBox(height: 116, radius: 16),
            const SizedBox(height: 10),
          ],
          const SkeletonBox(height: 110, radius: 16),
        ],
      ),
    );
  }
}
