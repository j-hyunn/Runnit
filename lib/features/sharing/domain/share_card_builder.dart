/// 기존 모델 → [ShareCardData] 조합. **순수 함수만** 둔다(I/O 없음).
///
/// 이 계층이 존재하는 이유: 카드가 필요로 하는 값은 `AppUser` / `Badge` /
/// `UserBadge` / `RunRecord` / `RankingEntry` 네다섯 곳에 흩어져 있고, 어느 것을
/// 어떻게 합칠지는 **UI 배치와 무관한 규칙**이다(어떤 뱃지가 PB 카드가 되는가,
/// PB 시간을 신뢰할 수 있는가, 경로를 몇 점으로 줄이는가). 위젯 안에 섞으면
/// 테스트할 수 없고 카드 디자인을 바꿀 때마다 규칙이 함께 흔들린다.
library;

import '../../../models/models.dart';
import '../../gamification/domain/badge_assets.dart';
import '../../tracking/domain/polyline_codec.dart';
import 'share_card_data.dart';

abstract final class ShareCardBuilder {
  /// 카드에 그릴 경로 점의 상한. 1080px 폭 카드에서 이보다 촘촘해도 눈에 보이는
  /// 차이가 없고, 점이 많을수록 캡처 시 래스터화가 느려진다.
  static const int maxRoutePoints = 240;

  /// 서버 PB 판정(TRD §10.2 `pb_time_lte`)이 `moving_seconds`를 그대로 쓰는
  /// 상한 비율. 이 안쪽이면 클라이언트가 보는 값 = 서버가 판정한 값이다.
  static const double pbDirectTimeRatio = 1.02;

  // ───────────────────────── 진입점 ─────────────────────────

  /// 획득한 뱃지 1건을 카드로 변환한다. 세 종류의 분기가 **여기 한 곳**에만 있다.
  ///
  /// [userBadge]의 카탈로그 정보([UserBadge.badge])가 비어 있으면 카드를 만들 수
  /// 없다(이름·등급·카테고리가 전부 거기 있다) → null. 호출부는 조인해서 받은
  /// 뱃지만 넘긴다(`fetchUserBadges`/`watchUnseenBadges`는 이미 조인한다).
  ///
  /// [sourceRun]은 [UserBadge.sourceRunId]로 찾아 둔 러닝. 없으면 경로 없이
  /// 카드가 만들어진다 — 누적형 뱃지는 애초에 원본 세션이 없다.
  static ShareCardData? fromUserBadge({
    required UserBadge userBadge,
    required AppUser user,
    RunRecord? sourceRun,
    RankingEntry? myRank,
  }) {
    final badge = userBadge.badge;
    if (badge == null) return null;

    final athlete = ShareAthlete.fromUser(user);
    final route = routeOf(sourceRun);

    return switch (badge.category) {
      BadgeCategory.seasonTier => _tierCard(
          badge: badge,
          userBadge: userBadge,
          user: user,
          athlete: athlete,
          route: route,
          myRank: myRank,
        ),
      BadgeCategory.personalBest => _pbCard(
          badge: badge,
          userBadge: userBadge,
          athlete: athlete,
          route: route,
          sourceRun: sourceRun,
        ),
      _ => BadgeEarnedCardData(
          athlete: athlete,
          achievedAt: userBadge.earnedAt,
          badge: badge,
          badgeAssetPath: badgeAssetPath(
            category: badge.category,
            badgeGrade: badge.badgeGrade,
          ),
          route: route,
        ),
    };
  }

  /// 뱃지 없이 **현재 티어를 그대로** 카드로 만든다.
  ///
  /// 승급 순간의 큐(`stier_*` 뱃지)와 별개로, 프로필/홈에서 "지금 내 티어를
  /// 자랑한다"는 경로가 필요하다(HI-08은 성취 직후에 한정되지 않는다). 승급
  /// 시각은 알 수 없으므로 [achievedAt]에 호출부가 아는 시각(없으면 now)을 준다.
  static TierPromotionCardData fromProfile({
    required AppUser user,
    RankingEntry? myRank,
    DateTime? achievedAt,
  }) {
    return TierPromotionCardData(
      athlete: ShareAthlete.fromUser(user),
      achievedAt: achievedAt ?? DateTime.now().toUtc(),
      tier: user.currentTier,
      seasonId: user.tierSeasonId ?? Season.currentId(),
      seasonDistanceMeters: user.seasonDistanceMeters,
      rank: myRank?.rank,
      participantCount: myRank?.participantCount,
    );
  }

  /// 러닝 1건을 그대로 카드로 만든다 — 성취가 없어도 요약 화면에서 공유할 수
  /// 있어야 하기 때문(HI-08의 "기록 공유").
  ///
  /// 2026-08-26 UI 작업에서 [RunRecapCardData]로 유니온에 편입했다. 대부분의
  /// 러닝은 뱃지를 터뜨리지 않으므로, 이 경로가 없으면 요약 화면의 공유 버튼은
  /// 대개 아무것도 만들지 못한다.
  static RunRecapCardData fromRun({
    required RunRecord run,
    required AppUser user,
  }) {
    return RunRecapCardData(
      athlete: ShareAthlete.fromUser(user),
      // 러닝의 "확정 시각"은 시작 시각이다. 종료 시각은 모델에 없고, 카드에
      // 찍히는 날짜로는 "언제 뛴 러닝인가"가 자연스럽다.
      achievedAt: run.startedAt,
      distanceMeters: run.distanceMeters,
      movingSeconds: run.movingSeconds,
      elapsedSeconds: run.elapsedSeconds,
      avgPaceSecPerKm: run.avgPaceSecPerKm,
      caloriesKcal: run.caloriesKcal,
      route: routeOf(run),
    );
  }

  // ───────────────────────── 내부 조합 ─────────────────────────

  static TierPromotionCardData _tierCard({
    required Badge badge,
    required UserBadge userBadge,
    required AppUser user,
    required ShareAthlete athlete,
    required ShareRoute? route,
    required RankingEntry? myRank,
  }) {
    // `stier_*` 뱃지의 condition은 `{"tier": "silver"}` 형태다(마이그레이션 26).
    // 프로필의 현재 티어를 쓰지 않는 이유: 지난 시즌 승급 뱃지를 나중에 다시
    // 공유하면 프로필 티어는 이미 다른 값이다.
    final tier = _tierFromCondition(badge.condition) ?? user.currentTier;

    // seasonal 인스턴스는 `seasonId`가 채워져 있다. 없으면 뱃지 id의 `@` 뒤를
    // 본다(`stier_platinum@2026-Q3`) — 그것도 없으면 프로필 시즌으로 폴백.
    final seasonId = badge.seasonId ??
        _seasonIdFromBadgeId(badge.id) ??
        user.tierSeasonId ??
        Season.currentId();

    // 시즌 누적 거리도 순위와 같은 이유로 **현재 시즌 카드에만** 붙인다 — 프로필은
    // "지금" 시즌 값만 들고 있어서, 지난 시즌 승급을 다시 공유할 때 그대로 쓰면
    // 다른 시즌의 숫자가 한 장에 섞인다(QA O-3).
    final isCurrentSeason = seasonId == user.tierSeasonId;

    return TierPromotionCardData(
      athlete: athlete,
      achievedAt: userBadge.earnedAt,
      tier: tier,
      seasonId: seasonId,
      seasonDistanceMeters: isCurrentSeason ? user.seasonDistanceMeters : null,
      rank: isCurrentSeason ? myRank?.rank : null,
      participantCount: isCurrentSeason ? myRank?.participantCount : null,
      route: route,
    );
  }

  static PersonalBestCardData? _pbCard({
    required Badge badge,
    required UserBadge userBadge,
    required ShareAthlete athlete,
    required ShareRoute? route,
    required RunRecord? sourceRun,
  }) {
    final targetKm = _numOf(badge.condition['distanceKm']);
    // 목표 거리를 모르면 "무엇의 PB인지"를 말할 수 없다 — 카드로 만들지 않는다.
    if (targetKm == null || targetKm <= 0) return null;

    return PersonalBestCardData(
      athlete: athlete,
      achievedAt: userBadge.earnedAt,
      targetKm: targetKm,
      badgeAssetPath: badgeAssetPath(
        category: badge.category,
        badgeGrade: badge.badgeGrade,
      ),
      certifiedSeconds: certifiedPbSeconds(run: sourceRun, targetKm: targetKm),
      runDistanceMeters: sourceRun?.distanceMeters,
      route: route,
    );
  }

  /// PB 카드에 적을 수 있는 **확정 기록(초)**. 규칙과 근거는
  /// [PersonalBestCardData.certifiedSeconds] 문서 참조.
  ///
  /// 요약하면: 세션 거리가 목표의 102% 이하일 때만 `movingSeconds`가 서버 판정과
  /// 일치하므로 그 구간에서만 값을 낸다. 초과 구간은 서버가 GPS 보간으로 만든
  /// 값을 쓰는데 그 값이 저장되지 않아 클라이언트가 알 방법이 없다 → null.
  static int? certifiedPbSeconds({
    required RunRecord? run,
    required double targetKm,
  }) {
    if (run == null) return null;
    final targetMeters = targetKm * 1000;
    if (run.distanceMeters > targetMeters * pbDirectTimeRatio) return null;
    return run.movingSeconds > 0 ? run.movingSeconds : null;
  }

  /// 러닝에서 카드용 경로를 뽑는다.
  ///
  /// 우선순위:
  /// 1. `samples`의 좌표 — 상세 조회/방금 끝낸 러닝은 이걸 갖고 있다.
  /// 2. `routePolyline` 해독 — 목록 경로로 받은 레코드는 샘플이 비어 있다.
  ///
  /// 어느 쪽이든 [maxRoutePoints] 이하로 줄인다. 실내 러닝은 좌표가 없어 null.
  static ShareRoute? routeOf(RunRecord? run) {
    if (run == null) return null;

    var points = <LatLngPoint>[
      for (final s in run.samples)
        if (s.latitude != null && s.longitude != null)
          LatLngPoint(s.latitude!, s.longitude!),
    ];

    if (points.length < 2) {
      final encoded = run.routePolyline;
      if (encoded == null || encoded.isEmpty) return null;
      points = decodePolyline(encoded);
    }
    if (points.length < 2) return null;

    final reduced = _downsample(points);
    return ShareRoute(
      points: [
        for (final p in reduced) (lat: p.latitude, lng: p.longitude),
      ],
      distanceMeters: run.distanceMeters,
    );
  }

  /// RDP로 먼저 줄이고, 그래도 많으면 균등 간격으로 솎는다.
  ///
  /// RDP만 쓰지 않는 이유: 허용오차를 키워 점 수를 맞추려면 이분 탐색이 필요한데,
  /// 카드 썸네일에서는 균등 솎기로 생기는 모양 왜곡이 눈에 띄지 않는다.
  /// **시작점과 끝점은 반드시 남긴다** — 루프 코스인지 편도인지가 그림에서 사라지면
  /// 경로를 넣은 의미가 없다.
  static List<LatLngPoint> _downsample(List<LatLngPoint> points) {
    final simplified = simplifyRoute(points, toleranceMeters: 8);
    if (simplified.length <= maxRoutePoints) return simplified;

    final step = simplified.length / (maxRoutePoints - 1);
    final out = <LatLngPoint>[];
    for (var i = 0; i < maxRoutePoints - 1; i++) {
      out.add(simplified[(i * step).floor()]);
    }
    out.add(simplified.last);
    return out;
  }

  // ───────────────────────── 파싱 헬퍼 ─────────────────────────

  static Tier? _tierFromCondition(Map<String, dynamic> condition) {
    final raw = condition['tier'];
    if (raw is! String) return null;
    for (final t in Tier.values) {
      if (t.name == raw) return t;
    }
    return null;
  }

  /// `stier_platinum@2026-Q3` → `2026-Q3`. 형식이 맞을 때만 돌려준다.
  static String? _seasonIdFromBadgeId(String badgeId) {
    final at = badgeId.indexOf('@');
    if (at < 0) return null;
    final candidate = badgeId.substring(at + 1);
    return RegExp(r'^\d{4}-Q[1-4]$').hasMatch(candidate) ? candidate : null;
  }

  /// jsonb에서 온 숫자는 int일 수도 double일 수도 있다(하프 = 21.0975).
  static double? _numOf(Object? value) => switch (value) {
        final num n => n.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };
}
