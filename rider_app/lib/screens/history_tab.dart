import 'package:flutter/material.dart';

import '../models/history.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading.dart';
import '../widgets/notice_card.dart';
import 'order_detail.dart';

/// History: delivered / cancelled orders, status + date filter, pagination.
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});
  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  final _scroll = ScrollController();
  final List<HistoryItem> _items = [];
  HistorySummary _summary = const HistorySummary();
  int _page = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String _status = ''; // '' = sab, delivered, cancelled
  DateTimeRange? _range;
  int _ver = -1;
  int _gen = 0; // purani request ka jawab ignore karne ke liye

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.pixels > _scroll.position.maxScrollExtent - 300 &&
          _hasMore &&
          !_loadingMore &&
          !_loading) {
        _fetch(reset: false);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = AppScope.of(context).historyVersion;
    if (_ver != v) {
      _ver = v;
      Future.microtask(() => _fetch(reset: true));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _fetch({required bool reset}) async {
    if (!mounted) return;
    final gen = reset ? ++_gen : _gen;
    final page = reset ? 1 : _page + 1;
    setState(() {
      if (reset) {
        _loading = true;
      } else {
        _loadingMore = true;
      }
      _error = null;
    });
    try {
      final d = await Api.history(
        page: page,
        status: _status,
        from: _range == null ? null : isoDate(_range!.start),
        to: _range == null ? null : isoDate(_range!.end),
      );
      if (!mounted || gen != _gen) return;
      final p = HistoryPage.fromJson(d);
      setState(() {
        if (reset) _items.clear();
        _items.addAll(p.items);
        _page = p.page;
        _hasMore = p.hasMore;
        _summary = p.summary;
      });
    } on ApiException catch (e) {
      if (!mounted || gen != _gen) return;
      if (e.authExpired) {
        await AppScope.of(context).onLogout();
        return;
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted && gen == _gen) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDateRange: _range,
      helpText: 'Tareekh chunein',
    );
    if (r != null) {
      setState(() => _range = r);
      _fetch(reset: true);
    }
  }

  void _setStatus(String s) {
    if (_status == s) return;
    setState(() => _status = s);
    _fetch(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    return RefreshIndicator(
      onRefresh: () => _fetch(reset: true),
      child: ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ChoiceChip(label: const Text('Sab'), selected: _status == '', onSelected: (_) => _setStatus('')),
              ChoiceChip(
                  label: const Text('Delivered'),
                  selected: _status == 'delivered',
                  onSelected: (_) => _setStatus('delivered')),
              ChoiceChip(
                  label: const Text('Cancelled'),
                  selected: _status == 'cancelled',
                  onSelected: (_) => _setStatus('cancelled')),
              ActionChip(
                avatar: const Icon(Icons.date_range, size: 18),
                label: Text(_range == null
                    ? 'Tareekh'
                    : '${fmtDate(_range!.start)} - ${fmtDate(_range!.end)}'),
                onPressed: _pickRange,
              ),
              if (_range != null)
                IconButton(
                  tooltip: 'Tareekh hatayein',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() => _range = null);
                    _fetch(reset: true);
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_error != null) ...[
            NoticeCard(
                level: NoticeLevel.error,
                icon: Icons.wifi_off,
                text: _error!,
                actionLabel: 'Dobara',
                onAction: () => _fetch(reset: true)),
            const SizedBox(height: 10),
          ],
          if (_loading)
            const SizedBox(height: 260, child: Loading())
          else ...[
            _summaryCard(),
            const SizedBox(height: 10),
            if (_items.isEmpty && _error == null)
              const SizedBox(
                height: 300,
                child: EmptyState(
                  icon: Icons.history,
                  title: 'Koi order nahi mila',
                  message: 'Is filter mein koi delivered / cancelled order nahi.',
                ),
              ),
            for (final h in _items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _HistoryTile(
                  item: h,
                  onTap: () => openOrderDetail(context, st, id: h.id),
                ),
              ),
            if (_loadingMore)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            if (_hasMore && !_loadingMore)
              Center(
                child: TextButton(onPressed: () => _fetch(reset: false), child: const Text('Aur dikhayein')),
              ),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _summaryCard() => Card(
        color: kGreen.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _Sum('Deliveries', numText(_summary.deliveries)),
              _Sum('Kamai', rs(_summary.earned)),
              _Sum('Cash liya', rs(_summary.cash)),
            ],
          ),
        ),
      );
}

class _Sum extends StatelessWidget {
  final String label;
  final String value;
  const _Sum(this.label, this.value);
  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ],
      );
}

class _HistoryTile extends StatelessWidget {
  final HistoryItem item;
  final VoidCallback onTap;
  const _HistoryTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ok = item.delivered;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: (ok ? kGreen : Colors.red).withValues(alpha: 0.12),
                child: Icon(ok ? Icons.check : Icons.close, color: ok ? kGreen : Colors.red),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('#${item.orderNo}  •  ${item.storeName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text(
                        '${item.customerName.isEmpty ? 'Customer' : item.customerName}  •  ${item.isCod ? 'COD' : 'Paid'} ${rs(item.total)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5)),
                    Text(fmtDateTime(item.when),
                        style: const TextStyle(fontSize: 11.5, color: Colors.black54)),
                  ],
                ),
              ),
              Text(ok ? '+${rs(item.fee)}' : 'Cancelled',
                  style: TextStyle(fontWeight: FontWeight.w800, color: ok ? kGreen : Colors.red)),
            ],
          ),
        ),
      ),
    );
  }
}
