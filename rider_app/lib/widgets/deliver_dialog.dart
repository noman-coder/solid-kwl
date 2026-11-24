import 'package:flutter/material.dart';

import '../models/order.dart';
import '../utils.dart';

/// "Deliver kar diya?" ka confirm dialog. COD ho to cash yaad dilata hai.
Future<bool> confirmDeliver(BuildContext context, RiderOrder o) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Order #${o.orderNo} deliver?'),
      content: Text(o.isCod
          ? 'Customer se COD ${rs(o.total)} cash lena na bhulein.'
          : 'Online payment ho chuki hai - cash nahi lena.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Nahi')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Haan, deliver')),
      ],
    ),
  );
  return ok == true;
}
