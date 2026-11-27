import '../utils.dart';

/// Customer ka ek review (server `api/vendor/reviews/` ki ek row). Naam privacy ke liye "Hadi A." jaisa aata hai.
class ReviewItem {
  final int id;
  final int orderId;
  final String orderNo;
  final int stars;
  final String comment;
  final String name;

  /// ISO waqt (phone ke local waqt mein dikhta hai).
  final String createdAt;
  final String reply;
  final String repliedAt;

  const ReviewItem({
    required this.id,
    required this.orderId,
    required this.orderNo,
    required this.stars,
    required this.comment,
    required this.name,
    required this.createdAt,
    required this.reply,
    required this.repliedAt,
  });

  factory ReviewItem.fromJson(dynamic j) {
    final m = asMap(j);
    return ReviewItem(
      id: toI(m['id']),
      orderId: toI(m['order_id']),
      orderNo: s(m['order_no']),
      stars: toI(m['stars']).clamp(0, 5).toInt(),
      comment: s(m['comment']),
      name: s(m['name']).isEmpty ? 'Customer' : s(m['name']),
      createdAt: s(m['created_at']),
      reply: s(m['reply']),
      repliedAt: s(m['replied_at']),
    );
  }

  bool get hasReply => reply.trim().isNotEmpty;
}

/// 5 -> 1 star ki ek patti: kitne reviews aur kitne percent.
class StarBar {
  final int stars;
  final int count;
  final int pct;
  const StarBar(this.stars, this.count, this.pct);

  factory StarBar.fromJson(dynamic j) {
    final m = asMap(j);
    return StarBar(toI(m['stars']), toI(m['count']), toI(m['pct']));
  }
}

/// Poore reviews ka khulasa (filter se alag - hamesha sab reviews ka).
class ReviewSummary {
  /// Koi rating na ho to null.
  final double? avg;
  final int count;
  final int replied;
  final int unanswered;
  final List<StarBar> bars;

  const ReviewSummary({
    this.avg,
    this.count = 0,
    this.replied = 0,
    this.unanswered = 0,
    this.bars = const [],
  });

  factory ReviewSummary.fromJson(dynamic j) {
    final m = asMap(j);
    final a = m['avg'];
    return ReviewSummary(
      avg: a == null ? null : toD(a),
      count: toI(m['count']),
      replied: toI(m['replied']),
      unanswered: toI(m['unanswered']),
      bars: listOfMaps(m['bars']).map(StarBar.fromJson).toList(),
    );
  }
}

/// GET /api/vendor/reviews/ ka jawab (ek page).
class ReviewsPage {
  final ReviewSummary summary;
  final List<ReviewItem> reviews;
  final int page;
  final bool hasMore;
  final int maxReplyLen;

  const ReviewsPage({
    required this.summary,
    required this.reviews,
    required this.page,
    required this.hasMore,
    required this.maxReplyLen,
  });

  factory ReviewsPage.fromJson(Map<String, dynamic> m) => ReviewsPage(
        summary: ReviewSummary.fromJson(m['summary']),
        reviews: listOfMaps(m['reviews']).map(ReviewItem.fromJson).toList(),
        page: toI(m['page'], 1),
        hasMore: m['has_more'] == true,
        maxReplyLen: toI(m['max_reply_len'], 300),
      );
}

/// Jawab save / hatane ka natija.
class ReviewReplyResult {
  final String message;
  final ReviewItem review;
  final ReviewSummary summary;
  const ReviewReplyResult(this.message, this.review, this.summary);

  factory ReviewReplyResult.fromJson(Map<String, dynamic> m) => ReviewReplyResult(
        s(m['message']),
        ReviewItem.fromJson(m['review']),
        ReviewSummary.fromJson(m['summary']),
      );
}
