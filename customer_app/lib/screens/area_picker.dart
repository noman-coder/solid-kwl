import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../models/home.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// "Deliver to" area chunne ka bottom sheet: GPS se, list se (shehar / area), ya "Sab areas".
/// Chunte hi AppState.setArea chalta hai aur Home / stores dobara load hote hain.
Future<void> showAreaPicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => const _AreaSheet(),
  );
}

class _AreaSheet extends StatefulWidget {
  const _AreaSheet();

  @override
  State<_AreaSheet> createState() => _AreaSheetState();
}

class _AreaSheetState extends State<_AreaSheet> {
  final TextEditingController _search = TextEditingController();
  List<AreaGroup>? _groups;
  String? _error;
  String? _gpsMessage;
  bool _gpsBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _groups = null;
    });
    try {
      final g = await Api.areas();
      if (!mounted) return;
      setState(() => _groups = g);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Areas ki list nahi aa saki. Dobara koshish karein.');
    }
  }

  Future<void> _choose(String area) async {
    final state = AppScope.read(context);
    final nav = Navigator.of(context);
    await state.setArea(area);
    if (nav.mounted) nav.pop();
  }

  Future<void> _useGps() async {
    if (_gpsBusy) return;
    final state = AppScope.read(context);
    final nav = Navigator.of(context);
    setState(() {
      _gpsBusy = true;
      _gpsMessage = null;
    });
    String? msg;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        msg = 'Phone ki location (GPS) band hai. Usay on karke dobara koshish karein.';
      } else {
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) {
          msg = 'Location ki ijazat nahi mili. List se apna area chun sakte hain.';
        } else if (perm == LocationPermission.deniedForever) {
          msg = 'Location ki ijazat band hai. Phone ki Settings > App > Permissions mein on karein, ya list se area chunein.';
        } else {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 15)),
          );
          await Api.saveLocationLocal(pos.latitude, pos.longitude);
          final r = await Api.sendLocation(pos.latitude, pos.longitude);
          if (r.suggestedArea.isNotEmpty) {
            await state.setArea(r.suggestedArea);
            state.say('Area: ${r.suggestedArea}');
            if (nav.mounted) nav.pop();
            return;
          }
          state.locationChanged(); // faasle ab bhi dikhein
          msg = r.message.isNotEmpty ? r.message : 'Aap ke nazdeek koi store nahi mila. List se area chunein.';
        }
      }
    } on TimeoutException {
      msg = 'Location milne mein der lag gayi. Khuli jagah par dobara koshish karein.';
    } on ApiException catch (e) {
      msg = e.message;
    } catch (_) {
      msg = 'Location nahi mil saki. List se apna area chunein.';
    }
    if (!mounted) return;
    setState(() {
      _gpsBusy = false;
      _gpsMessage = msg;
    });
  }

  Future<void> _removeLocation() async {
    final state = AppScope.read(context);
    await Api.clearLocation();
    state.locationChanged();
    if (!mounted) return;
    setState(() => _gpsMessage = 'Aap ki location hata di gayi.');
  }

  @override
  Widget build(BuildContext context) {
    final current = Api.areaChosen ? Api.area : null;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              const Text('Delivery kahan chahiye?',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: kInk)),
              const SizedBox(height: 4),
              const Text('Apna area chunein, hum us area ke stores dikhayenge.', style: TextStyle(color: kMuted)),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _gpsBusy ? null : _useGps,
                icon: _gpsBusy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                    : const Icon(Icons.my_location_rounded),
                label: Text(_gpsBusy ? 'Location dhoond rahe hain...' : 'Meri location istemal karein'),
              ),
              if (_gpsMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_gpsMessage!, style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
                ),
              if (Api.lat != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: _removeLocation, child: const Text('Meri location hata dein')),
                ),
              const SizedBox(height: 10),
              TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Shehar ya area dhoondhein',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => setState(_search.clear),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(backgroundColor: kGreenSoft, child: Icon(Icons.public_rounded, color: kGreen)),
                title: const Text('Sab areas', style: TextStyle(fontWeight: FontWeight.w800)),
                subtitle: const Text('Koi filter nahi'),
                trailing: current == '' ? const Icon(Icons.check_circle_rounded, color: kGreen) : null,
                onTap: () => _choose(''),
              ),
              ..._body(current),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _body(String? current) {
    if (_error != null) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            children: [
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: kMuted)),
              const SizedBox(height: 10),
              OutlinedButton(onPressed: _load, child: const Text('Dobara koshish karein')),
            ],
          ),
        ),
      ];
    }
    final groups = _groups;
    if (groups == null) {
      return const [Padding(padding: EdgeInsets.only(top: 12), child: SkeletonList(count: 4, height: 56))];
    }
    final q = _search.text.trim().toLowerCase();
    final out = <Widget>[];
    for (final g in groups) {
      final cityMatch = q.isEmpty || g.city.toLowerCase().contains(q);
      final areas = g.areas.where((a) => cityMatch || a.name.toLowerCase().contains(q)).toList();
      if (!cityMatch && areas.isEmpty) continue;
      out.add(const Divider(height: 24));
      out.add(_AreaTile(
        icon: Icons.location_city_rounded,
        title: g.city,
        subtitle: 'Poora shehar',
        selected: current != null && current.toLowerCase() == g.city.toLowerCase(),
        onTap: () => _choose(g.city),
      ));
      for (final a in areas) {
        out.add(_AreaTile(
          icon: Icons.place_outlined,
          title: a.name,
          subtitle: g.city,
          selected: current != null && current.toLowerCase() == a.label.toLowerCase(),
          onTap: () => _choose(a.label),
        ));
      }
    }
    if (out.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Text('Is naam ka koi area nahi mila.', textAlign: TextAlign.center, style: TextStyle(color: kMuted)),
        ),
      ];
    }
    return out;
  }
}

class _AreaTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _AreaTile(
      {required this.icon, required this.title, required this.subtitle, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(icon, color: kOrange),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle),
      trailing: selected ? const Icon(Icons.check_circle_rounded, color: kGreen) : null,
      onTap: onTap,
    );
  }
}
