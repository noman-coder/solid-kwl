import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/home.dart';
import '../services/app_state.dart';
import '../theme.dart';

/// Product ko cart mein daalo - Search, Store page aur Product page sab yahi use karte hain.
/// Guest ke liye phone mein, login customer ke liye server par. Doosre store ka maal ho to poochta hai
/// (\"Purana cart khali karein?\"). Kamyab hone par `true`.
/// `stock`: guest ke liye hadd (0 = maloom nahi; login ke liye server khud stock dekhta hai).
Future<bool> addProductToCart(
  BuildContext context, {
  required ProductCard card,
  int qty = 1,
  int stock = 0,
}) async {
  final state = AppScope.read(context);
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  HapticFeedback.lightImpact();

  var out = await state.cart.add(
    productId: card.id,
    storeId: card.storeId,
    storeName: card.storeName,
    qty: qty,
    maxQty: stock,
  );

  if (out.conflict) {
    if (!context.mounted) return false;
    final replace = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Purana cart khali karein?'),
        content: Text(
          'Aap ke cart mein "${out.currentStore}" ka maal hai. Ek waqt mein ek hi store se order hota hai. '
          '"${out.newStore.isEmpty ? card.storeName : out.newStore}" ka maal lene ke liye purana cart khali hoga.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Nahi')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Khali karke add karein')),
        ],
      ),
    );
    if (replace != true) return false;
    out = await state.cart.add(
      productId: card.id,
      storeId: card.storeId,
      storeName: card.storeName,
      qty: qty,
      maxQty: stock,
      replace: true,
    );
  }

  messenger.hideCurrentSnackBar();
  if (!out.ok) {
    messenger.showSnackBar(SnackBar(content: Text(out.message)));
    return false;
  }
  messenger.showSnackBar(SnackBar(
    content: Text('${card.name} cart mein add ho gaya.', maxLines: 2, overflow: TextOverflow.ellipsis),
    action: SnackBarAction(
      label: 'Cart dekhein',
      textColor: kOrangeSoft,
      onPressed: () {
        navigator.popUntil((r) => r.isFirst);
        state.goTab(2);
      },
    ),
  ));
  return true;
}
