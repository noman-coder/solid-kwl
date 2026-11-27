import 'package:flutter/material.dart';

import '../models/reviews.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/notice_card.dart';
import '../widgets/skeleton.dart';
import 'order_detail.dart';

/// Phase V14: Reviews & ratings. Customers ki rating dekhein (average, 5-1 star patti, har review) aur jawab dein.
/// Jawab server par 300 akshar tak; customer ko store page par dikhta hai. Pull-to-refresh, agla page, skeleton, empty,
/// error + retry, net band ho to purani list.
class ReviewsScreen extends StatefulWidget {
  const ReviewsScreen({super.key});

  @override
  State<ReviewsScreen> createState() => _ReviewsScreenState();
}

/// More tab / push notification se Reviews screen kholo.
Future<void> openReviewsScreen(BuildContext context) {
  final state = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: const ReviewsScreen()),
  ));
}

class _ReviewsScreenState extends State<ReviewsScreen> {
  final ScrollController _scroll = ScrollController();
  ReviewSummary _summary = const ReviewSummary();
  List<ReviewItem> _items = [];
  int _page = 1;
  bool _hasMore = false;
  int _maxLen = 300;
  bool _loaded = false; // summary pehli dafa aa chuki
  bool _loading = false;
  bool _loadingMore = false;
  bool _stale = false; // purani (phone mein save) list dikh rahi hai
  String? _error;
  String _filter = 'all'; // all | unanswered | replied
  int _stars = 0; // 0 = sab
  final Set<int> _busy = <int>{}; // jin reviews ka jawab hat raha hai (double-tap lock)
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _init();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final cached = await Api.cachedReviews();
    if (mounted && cached != null && !_loaded) {
      setState(() {
        _apply(cached);
        _stale = true;
      });
    }
    if (!mounted) return;
    await _load();
  }

  void _apply(ReviewsPage p) {
    _summary = p.summary;
    _items = p.reviews;
    _page = p.page;
    _hasMore = p.hasMore;
    _maxLen = p.maxReplyLen;
    _loaded = true;
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) _loadMore();
  }

  void _snack(String msg) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _expired() async {
    await AppScope.read(context).handleAuthExpired();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await Api.reviews(filter: _filter, stars: _stars);
      if (!mounted || seq != _seq) return;
      setState(() {
        _apply(p);
        _stale = false;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      if (e.authExpired) {
        await _expired();
        return;
      }
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = 'Kuch masla aa gaya. Dobara koshish karein.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || !_loaded || _error != null) return;
    final seq = _seq;
    setState(() => _loadingMore = true);
    try {
      final p = await Api.reviews(filter: _filter, stars: _stars, page: _page + 1);
      if (!mounted || seq != _seq) return;
      final have = _items.map((e) => e.id).toSet();
      setState(() {
        _items = [..._items, ...p.reviews.where((e) => !have.contains(e.id))];
        _page = p.page;
        _hasMore = p.hasMore;
        _summary = p.summary;
        _loadingMore = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() => _loadingMore = false);
      if (e.authExpired) {
        await _expired();
        return;
      }
      _snack(e.message);
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _setFilter(String f) {
    if (_filter == f) return;
    setState(() {
      _filter = f;
      _items = []; // list ki jagah skeleton; upar ka khulasa wahi rehta hai
      _hasMore = false;
      _stale = false;
    });
    _load();
  }

  void _setStars(int n) {
    final next = _stars == n ? 0 : n; // usi star par dobara tap = hata do
    setState(() {
      _stars = next;
      _items = [];
      _hasMore = false;
      _stale = false;
    });
    _load();
  }

  // ------------------------------------------------------------------ jawab

  /// Server ka naya review + khulasa list mein lagao. Filter ke hisaab se jo ab match nahi karta wo hat jata hai.
  void _applyReply(ReviewReplyResult r) {
    setState(() {
      _summary = r.summary;
      final i = _items.indexWhere((e) => e.id == r.review.id);
      if (i < 0) return;
      final gone = (_filter == 'unanswered' && r.review.hasReply) || (_filter == 'replied' && !r.review.hasReply);
      if (gone) {
        _items = [..._items]..removeAt(i);
      } else {
        _items = [..._items]..[i] = r.review;
      }
    });
  }

  Future<void> _openReply(ReviewItem rv) async {
    final out = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _ReplySheet(review: rv, maxLen: _maxLen),
    );
    if (!mounted || out == null) return;
    if (out is ReviewReplyResult) {
      _applyReply(out);
      _snack(out.message.isEmpty ? 'Jawab save ho gaya.' : out.message);
    } else if (out == 'expired') {
      await _expired();
    } else if (out == 'gone') {
      _snack('Yeh review ab nahi mila.');
      _load();
    }
  }

  Future<void> _removeReply(ReviewItem rv) async {
    if (_busy.contains(rv.id)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Jawab hatayein?'),
        content: const Text('Customer ko yeh jawab ab nahi dikhega. Baad mein naya jawab likh sakte hain.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nahi')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(100, 44), backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hatayein'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!_busy.add(rv.id)) return;
    setState(() {});
    try {
      final r = await Api.replyReview(rv.id, '');
      if (!mounted) return;
      _applyReply(r);
      _snack(r.message.isEmpty ? 'Jawab hata diya.' : r.message);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await _expired();
        return;
      }
      _snack(e.message);
      if (e.code == 'not_found') _load();
    } catch (_) {
      if (mounted) _snack('Kuch masla aa gaya. Dobara koshish karein.');
    } finally {
      _busy.remove(rv.id);
      if (mounted) setState(() {});
    }
  }

  void _openOrder(ReviewItem rv) {
    if (rv.orderId <= 0) return;
    openOrderById(context, AppScope.read(context), rv.orderId);
  }

  // ------------------------------------------------------------------ build

  Widget _chips() {
    final items = <List<Object>>[
      ['all', 'Sab (${_summary.count})'],
      ['unanswered', 'Jawab nahi diya (${_summary.unanswered})'],
      ['replied', 'Jawab diya (${_summary.replied})'],
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final it in items)
          ChoiceChip(
            label: Text(it[1] as String),
            selected: _filter == it[0],
            onSelected: (_) => _setFilter(it[0] as String),
          ),
        if (_stars > 0)
          InputChip(
            avatar: const Icon(Icons.star_rounded, size: 18, color: Colors.amber),
            label: Text('$_stars star'),
            onDeleted: () => _setStars(_stars),
          ),
      ],
    );
  }

  List<Widget> _listPart() {
    if (_loading && _items.isEmpty) {
      return const [SkeletonList(count: 3, height: 130)];
    }
    if (_error != null && _items.isEmpty) {
      return [
        NoticeCard(
          level: NoticeLevel.warn,
          icon: Icons.cloud_off_outlined,
          text: _error!,
          actionLabel: 'Dobara',
          onAction: _load,
        ),
      ];
    }
    if (_items.isEmpty) {
      final msg = _filter == 'unanswered'
          ? 'Sab reviews ka jawab de diya gaya hai. Shabash!'
          : _filter == 'replied'
              ? 'Abhi kisi review ka jawab nahi diya.'
              : 'Is filter mein koi review nahi.';
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: Center(child: Text(msg, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54))),
        ),
      ];
    }
    final out = <Widget>[];
    for (final rv in _items) {
      out
        ..add(_ReviewCard(
          rv: rv,
          busy: _busy.contains(rv.id),
          onReply: () => _openReply(rv),
          onRemove: () => _removeReply(rv),
          onOrder: () => _openOrder(rv),
        ))
        ..add(const SizedBox(height: 10));
    }
    if (_loadingMore) {
      out.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator()),
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (!_loaded && _loading) {
      body = const Padding(padding: EdgeInsets.all(16), child: SkeletonList(count: 4, height: 120));
    } else if (!_loaded) {
      body = EmptyState(
        icon: Icons.wifi_off_rounded,
        title: 'Load nahi ho saka',
        message: _error ?? 'Internet / VPN check karein.',
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Dobara koshish karein'),
        ),
      );
    } else if (_summary.count == 0 && _error == null) {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 80),
            EmptyState(
              icon: Icons.star_outline_rounded,
              title: 'Abhi koi review nahi',
              message: 'Jab customer deliver hue order par aap ke store ko rating dega, yahan nazar aayegi aur aap jawab de sakenge.',
            ),
          ],
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null && _items.isNotEmpty) ...[
              NoticeCard(
                level: NoticeLevel.warn,
                icon: Icons.cloud_off_outlined,
                text: 'Taza data nahi aaya. Purana data dikh raha hai.',
                actionLabel: 'Dobara',
                onAction: _load,
              ),
              const SizedBox(height: 10),
            ] else if (_stale) ...[
              NoticeCard(
                level: NoticeLevel.info,
                icon: Icons.history,
                text: 'Purani list dikh rahi hai. Taza ho rahi hai...',
              ),
              const SizedBox(height: 10),
            ],
            _SummaryCard(summary: _summary, selectedStars: _stars, onStar: _setStars),
            const SizedBox(height: 14),
            _chips(),
            const SizedBox(height: 10),
            ..._listPart(),
            const SizedBox(height: 24),
          ],
        ),
      );
    }
    return Scaffold(appBar: AppBar(title: const Text('Reviews')), body: body);
  }
}

// ---------------------------------------------------------------------- widgets

class _Stars extends StatelessWidget {
  final int filled;
  final double size;
  const _Stars(this.filled, {this.size = 18});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(i <= filled ? Icons.star_rounded : Icons.star_outline_rounded,
              size: size, color: i <= filled ? Colors.amber.shade600 : Colors.black26),
      ],
    );
  }
}

/// Upar ka card: average + 5-1 star patti (patti par tap = sirf us star ke reviews).
class _SummaryCard extends StatelessWidget {
  final ReviewSummary summary;
  final int selectedStars;
  final ValueChanged<int> onStar;
  const _SummaryCard({required this.summary, required this.selectedStars, required this.onStar});

  @override
  Widget build(BuildContext context) {
    final avg = summary.avg;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(avg == null ? '-' : avg.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w900, color: kTealDark, height: 1.05)),
                const SizedBox(height: 4),
                _Stars(avg == null ? 0 : avg.round(), size: 18),
                const SizedBox(height: 4),
                Text('${summary.count} reviews', style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
              ],
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                children: [
                  for (final b in summary.bars)
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: b.count == 0 && selectedStars != b.stars ? null : () => onStar(b.stars),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                        decoration: BoxDecoration(
                          color: selectedStars == b.stars ? kTeal.withValues(alpha: 0.10) : null,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 12,
                              child: Text('${b.stars}',
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                            ),
                            Icon(Icons.star_rounded, size: 14, color: Colors.amber.shade600),
                            const SizedBox(width: 6),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  value: (b.pct / 100).clamp(0.0, 1.0).toDouble(),
                                  minHeight: 8,
                                  color: Colors.amber.shade600,
                                  backgroundColor: const Color(0xFFEEF2F1),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 30,
                              child: Text('${b.count}',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
                            ),
                          ],
                        ),
                      ),
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

class _ReviewCard extends StatelessWidget {
  final ReviewItem rv;
  final bool busy;
  final VoidCallback onReply;
  final VoidCallback onRemove;
  final VoidCallback onOrder;

  const _ReviewCard({
    required this.rv,
    required this.busy,
    required this.onReply,
    required this.onRemove,
    required this.onOrder,
  });

  @override
  Widget build(BuildContext context) {
    final date = dateTimeText(rv.createdAt);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: kTeal.withValues(alpha: 0.12),
                  child: Text(rv.name.isEmpty ? '?' : rv.name.substring(0, 1).toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.w900, color: kTeal)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rv.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      Text([if (rv.orderNo.isNotEmpty) 'Order #${rv.orderNo}', if (date.isNotEmpty) date].join('  •  '),
                          style: const TextStyle(color: Colors.black54, fontSize: 12)),
                    ],
                  ),
                ),
                _Stars(rv.stars, size: 17),
              ],
            ),
            const SizedBox(height: 10),
            if (rv.comment.trim().isNotEmpty)
              Text(rv.comment.trim(), style: const TextStyle(fontSize: 14.5, height: 1.35))
            else
              const Text('Sirf rating di, comment nahi likha.',
                  style: TextStyle(color: Colors.black45, fontStyle: FontStyle.italic, fontSize: 13)),
            const SizedBox(height: 10),
            if (rv.hasReply)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
                decoration: BoxDecoration(
                  color: kTeal.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kTeal.withValues(alpha: 0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.reply_rounded, size: 16, color: kTeal),
                        const SizedBox(width: 6),
                        const Text('Aap ka jawab',
                            style: TextStyle(fontWeight: FontWeight.w800, color: kTealDark, fontSize: 12.5)),
                        const Spacer(),
                        if (rv.repliedAt.isNotEmpty)
                          Text(dateTimeText(rv.repliedAt), style: const TextStyle(color: Colors.black45, fontSize: 11.5)),
                        const SizedBox(width: 6),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(rv.reply.trim(), style: const TextStyle(fontSize: 14, height: 1.35)),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(onPressed: busy ? null : onReply, child: const Text('Badlein')),
                        TextButton(
                          onPressed: busy ? null : onRemove,
                          style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
                          child: busy
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Hatayein'),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: onReply,
                  icon: const Icon(Icons.reply_rounded, size: 18),
                  label: const Text('Jawab dein'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                ),
              ),
            if (rv.orderId > 0)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onOrder,
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: const Text('Order dekhein', style: TextStyle(fontSize: 12.5)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Jawab likhne ka bottom sheet. Natija: [ReviewReplyResult] (kamyab), 'expired' (dobara login) ya 'gone' (review nahi mila);
/// band karne par null. Sheet AppScope ke neeche nahi hota, is liye auth / not-found screen ko natije se bataya jata hai.
class _ReplySheet extends StatefulWidget {
  final ReviewItem review;
  final int maxLen;
  const _ReplySheet({required this.review, required this.maxLen});

  @override
  State<_ReplySheet> createState() => _ReplySheetState();
}

class _ReplySheetState extends State<_ReplySheet> {
  late final TextEditingController _c = TextEditingController(text: widget.review.reply);
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _c.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  List<String> get _quick => widget.review.stars >= 4
      ? const [
          'Shukriya! Aap ki raye hamare liye bohat qeemti hai.',
          'Bohat shukriya, dobara zaroor order karein.',
        ]
      : const [
          'Hamein afsos hai. Hum behtar karne ki poori koshish karenge.',
          'Aap ki shikayat note kar li hai, inshaAllah masla theek karenge.',
        ];

  Future<void> _save() async {
    if (_saving) return;
    final text = _c.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final r = await Api.replyReview(widget.review.id, text);
      if (mounted) Navigator.pop(context, r);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        Navigator.pop(context, 'expired');
        return;
      }
      if (e.code == 'not_found') {
        Navigator.pop(context, 'gone');
        return;
      }
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Kuch masla aa gaya. Dobara koshish karein.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _c.text.trim();
    final had = widget.review.hasReply;
    final unchanged = text == widget.review.reply.trim();
    final canSave = !_saving && !unchanged && (text.isNotEmpty || had);
    final label = text.isEmpty && had ? 'Jawab hatayein' : (had ? 'Jawab badlein' : 'Jawab bhejein');
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(had ? 'Jawab badlein' : 'Jawab dein', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _Stars(widget.review.stars, size: 15),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(widget.review.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                      ),
                    ],
                  ),
                  if (widget.review.comment.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(widget.review.comment.trim(),
                        maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _c,
              enabled: !_saving,
              autofocus: true,
              minLines: 3,
              maxLines: 5,
              maxLength: widget.maxLen,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Customer ka shukriya ya wazahat likhein...',
                border: OutlineInputBorder(),
              ),
            ),
            if (text.isEmpty && !had) ...[
              const Text('Jaldi jawab:', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
              Wrap(
                spacing: 8,
                children: [
                  for (final q in _quick)
                    ActionChip(
                      label: Text(q, style: const TextStyle(fontSize: 12)),
                      onPressed: _saving ? null : () => _c.text = q,
                    ),
                ],
              ),
              const SizedBox(height: 4),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600)),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Band karein'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: canSave ? _save : null,
                    style: text.isEmpty && had ? FilledButton.styleFrom(backgroundColor: Colors.red.shade700) : null,
                    child: _saving
                        ? const SizedBox(
                            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(label),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
