import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/features/sharing/domain/share_card_builder.dart';
import 'package:runnit/features/sharing/domain/share_card_data.dart';
import 'package:runnit/features/tracking/domain/polyline_codec.dart';
import 'package:runnit/models/models.dart';

/// 공유 카드 조합 규칙(HI-08). 여기서 검증하는 것은 **디자인이 아니라 데이터
/// 선택 규칙**이다 — 어떤 뱃지가 어떤 카드가 되는가, PB 시간을 언제 신뢰하는가,
/// 경로를 어디서 얻는가.

final _user = AppUser(
  id: 'u1',
  username: 'runner',
  displayName: '지현',
  currentTier: Tier.gold,
  level: 12,
  seasonDistanceMeters: 123456,
  tierSeasonId: '2026-Q3',
  createdAt: DateTime.utc(2026, 1, 1),
);

Badge _badge({
  required String id,
  required BadgeCategory category,
  BadgeScope scope = BadgeScope.permanent,
  Map<String, dynamic> condition = const {},
  String grade = 'gold',
  String? seasonId,
  String conditionType = 'x',
}) =>
    Badge(
      id: id,
      name: '테스트뱃지',
      description: '설명',
      category: category,
      scope: scope,
      triggerType: BadgeTriggerType.session,
      conditionType: conditionType,
      condition: condition,
      badgeGrade: grade,
      seasonId: seasonId,
    );

UserBadge _earned(Badge badge, {String? sourceRunId, double? achievedValue}) =>
    UserBadge(
      id: 'ub1',
      userId: 'u1',
      badgeId: badge.id,
      earnedAt: DateTime.utc(2026, 8, 26, 3),
      verified: true,
      sourceRunId: sourceRunId,
      achievedValue: achievedValue,
      badge: badge,
    );

/// PB 뱃지 한 벌 — 카탈로그와 획득 기록을 함께 만든다.
({Badge badge, UserBadge userBadge}) _pb({
  double distanceKm = 5,
  String conditionType = 'pb_time_lte',
  double? achievedValue,
}) {
  final badge = _badge(
    id: 'pb_${distanceKm}km',
    category: BadgeCategory.personalBest,
    condition: {'distanceKm': distanceKm},
    conditionType: conditionType,
  );
  return (
    badge: badge,
    userBadge: _earned(badge, sourceRunId: 'r1', achievedValue: achievedValue),
  );
}

RunRecord _run({
  required double distanceMeters,
  int movingSeconds = 1500,
  List<RunSample> samples = const [],
  String? polyline,
}) =>
    RunRecord(
      id: 'r1',
      userId: 'u1',
      startedAt: DateTime.utc(2026, 8, 26, 2),
      endedAt: DateTime.utc(2026, 8, 26, 3),
      activityType: ActivityType.outdoorRun,
      status: RunStatus.completed,
      distanceMeters: distanceMeters,
      elapsedSeconds: movingSeconds,
      movingSeconds: movingSeconds,
      samples: samples,
      routePolyline: polyline,
    );

RunSample _sample(double lat, double lng) => RunSample(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.utc(2026, 8, 26, 2),
      source: RunSampleSource.phone,
    );

void main() {
  group('카드 종류 분기', () {
    test('season_tier 뱃지는 티어 승급 카드가 된다', () {
      final badge = _badge(
        id: 'stier_gold@2026-Q3',
        category: BadgeCategory.seasonTier,
        scope: BadgeScope.seasonal,
        condition: {'tier': 'gold'},
        seasonId: '2026-Q3',
      );

      final card = ShareCardBuilder.fromUserBadge(
        userBadge: _earned(badge),
        user: _user,
      );

      expect(card, isA<TierPromotionCardData>());
      final tierCard = card! as TierPromotionCardData;
      expect(tierCard.tier, Tier.gold);
      expect(tierCard.seasonId, '2026-Q3');
      expect(tierCard.kind, ShareCardKind.tierPromotion);
    });

    test('seasonId가 비어도 뱃지 id의 @ 뒤에서 복구한다', () {
      final badge = _badge(
        id: 'stier_platinum@2026-Q4',
        category: BadgeCategory.seasonTier,
        scope: BadgeScope.seasonal,
        condition: {'tier': 'platinum'},
      );

      final card = ShareCardBuilder.fromUserBadge(
        userBadge: _earned(badge),
        user: _user,
      )! as TierPromotionCardData;

      expect(card.seasonId, '2026-Q4');
      // 지난/다음 시즌 카드에는 이번 주 순위를 얹지 않는다.
      expect(card.rank, isNull);
    });

    test('personal_best 뱃지는 PB 카드가 된다', () {
      final pb = _pb(achievedValue: 1471);

      final card = ShareCardBuilder.fromUserBadge(
        userBadge: pb.userBadge,
        user: _user,
        sourceRun: _run(distanceMeters: 5020, movingSeconds: 1500),
      )! as PersonalBestCardData;

      expect(card.targetKm, 5);
      expect(card.distanceLabel, '5km');
      // 시간은 러닝이 아니라 서버 확정값(achieved_value)에서 온다.
      expect(card.timeLabel, '24:31');
      expect(card.runDistanceMeters, 5020);
    });

    test('distanceKm이 없는 PB 뱃지는 카드로 만들지 않는다', () {
      final badge = _badge(id: 'pb_x', category: BadgeCategory.personalBest);
      final card = ShareCardBuilder.fromUserBadge(
        userBadge: _earned(badge),
        user: _user,
      );
      expect(card, isNull);
    });

    test('나머지 카테고리는 뱃지 카드가 되고 아트 경로가 붙는다', () {
      final badge = _badge(
        id: 'dist_cum_1000km',
        category: BadgeCategory.cumulativeDistance,
        grade: 'diamond',
      );

      final card = ShareCardBuilder.fromUserBadge(
        userBadge: _earned(badge),
        user: _user,
      )! as BadgeEarnedCardData;

      expect(card.badgeAssetPath, 'assets/badges/distance/diamond.svg');
    });

    test('카탈로그 조인이 없으면 카드를 만들 수 없다', () {
      final orphan = UserBadge(
        id: 'ub9',
        userId: 'u1',
        badgeId: 'unknown',
        earnedAt: DateTime.utc(2026, 8, 26),
      );
      expect(
        ShareCardBuilder.fromUserBadge(userBadge: orphan, user: _user),
        isNull,
      );
    });
  });

  group('PB 확정 시간 — achieved_value 단일 출처 (TRD §14 #18, 마이그레이션 65)', () {
    test('서버 확정값을 반올림해 그대로 쓴다', () {
      final pb = _pb(achievedValue: 1470.6);
      expect(
        ShareCardBuilder.certifiedPbSeconds(
          badge: pb.badge,
          userBadge: pb.userBadge,
        ),
        1471,
      );
    });

    test('pb_first_achieved도 초 단위라 같은 경로를 쓴다', () {
      final pb = _pb(conditionType: 'pb_first_achieved', achievedValue: 1800);
      expect(
        ShareCardBuilder.certifiedPbSeconds(
          badge: pb.badge,
          userBadge: pb.userBadge,
        ),
        1800,
      );
    });

    test('65 이전 지급분(achieved_value == null)은 비운다 — moving_seconds 폴백 없음', () {
      final pb = _pb();
      expect(
        ShareCardBuilder.certifiedPbSeconds(
          badge: pb.badge,
          userBadge: pb.userBadge,
        ),
        isNull,
      );

      // 회귀 가드: 예전 규칙(세션 거리 ≤ 목표×102%)이라면 1500이 나왔다.
      final card = ShareCardBuilder.fromUserBadge(
        userBadge: pb.userBadge,
        user: _user,
        sourceRun: _run(distanceMeters: 5020, movingSeconds: 1500),
      )! as PersonalBestCardData;
      expect(card.certifiedSeconds, isNull);
      expect(card.timeLabel, isNull);
      expect(card.shareText, '5km PB 갱신! #Runnit');
    });

    test('102%를 넘는 러닝이어도 서버 확정값이 있으면 그 값을 쓴다', () {
      // 예전 규칙은 이 구간을 통째로 null로 만들었다(GPS 보간값이 저장되지
      // 않았기 때문). 이제 서버가 보간 결과를 적어 두므로 카드에 시간이 나온다.
      final pb = _pb(achievedValue: 1471.2);
      final card = ShareCardBuilder.fromUserBadge(
        userBadge: pb.userBadge,
        user: _user,
        sourceRun: _run(distanceMeters: 7200, movingSeconds: 2400),
      )! as PersonalBestCardData;

      expect(card.timeLabel, '24:31');
    });

    test('단위가 초가 아닌 조건 타입은 읽지 않는다 — 등수를 시간으로 찍지 않기 위해', () {
      final pb = _pb(conditionType: 'season_weekly_rank_lte', achievedValue: 3);
      expect(
        ShareCardBuilder.certifiedPbSeconds(
          badge: pb.badge,
          userBadge: pb.userBadge,
        ),
        isNull,
      );
    });

    test('0 이하·비유한 값은 0:00을 자랑하지 않도록 비운다', () {
      for (final v in <double>[0, -12, double.nan, double.infinity]) {
        final pb = _pb(achievedValue: v);
        expect(
          ShareCardBuilder.certifiedPbSeconds(
            badge: pb.badge,
            userBadge: pb.userBadge,
          ),
          isNull,
          reason: 'achievedValue=$v',
        );
      }
    });

    test('시간을 모르면 카드 문구에서 시간이 통째로 빠진다', () {
      final card = PersonalBestCardData(
        athlete: ShareAthlete.fromUser(_user),
        achievedAt: DateTime.utc(2026, 8, 26),
        targetKm: 21.0975,
        badgeAssetPath: 'assets/badges/PB/gold.svg',
      );
      expect(card.distanceLabel, '하프');
      expect(card.timeLabel, isNull);
      expect(card.shareText, contains('하프 PB 갱신'));
    });
  });

  group('경로 추출', () {
    test('samples가 있으면 그대로 쓴다', () {
      final route = ShareCardBuilder.routeOf(_run(
        distanceMeters: 3000,
        samples: [
          _sample(37.5665, 126.9780),
          _sample(37.5670, 126.9790),
          _sample(37.5680, 126.9800),
        ],
      ));

      expect(route, isNotNull);
      expect(route!.isDrawable, isTrue);
      expect(route.points.first.lat, closeTo(37.5665, 1e-5));
    });

    test('samples가 비면 routePolyline을 해독해 쓴다', () {
      final encoded = encodePolyline(const [
        LatLngPoint(37.5665, 126.9780),
        LatLngPoint(37.5680, 126.9800),
      ]);

      final route = ShareCardBuilder.routeOf(
        _run(distanceMeters: 3000, polyline: encoded),
      );

      expect(route, isNotNull);
      expect(route!.points.length, 2);
      expect(route.points.last.lng, closeTo(126.9800, 1e-4));
    });

    test('좌표도 폴리라인도 없으면 경로 없는 카드가 된다', () {
      expect(ShareCardBuilder.routeOf(_run(distanceMeters: 3000)), isNull);
      expect(ShareCardBuilder.routeOf(null), isNull);
    });

    test('점이 많아도 상한 안으로 줄이고 양 끝은 남긴다', () {
      final samples = [
        for (var i = 0; i < 3000; i++)
          _sample(37.5 + i * 0.0002, 127.0 + (i % 7) * 0.0003),
      ];

      final route = ShareCardBuilder.routeOf(
        _run(distanceMeters: 30000, samples: samples),
      )!;

      expect(route.points.length,
          lessThanOrEqualTo(ShareCardBuilder.maxRoutePoints));
      expect(route.points.first.lat, closeTo(37.5, 1e-6));
      expect(route.points.last.lat, closeTo(37.5 + 2999 * 0.0002, 1e-6));
    });
  });

  group('폴리라인 왕복', () {
    test('encode → decode가 precision 5 안에서 보존된다', () {
      const original = [
        LatLngPoint(37.56650, 126.97800),
        LatLngPoint(37.56712, 126.97934),
        LatLngPoint(37.56488, 126.98120),
      ];

      final decoded = decodePolyline(encodePolyline(original));

      expect(decoded.length, original.length);
      for (var i = 0; i < original.length; i++) {
        expect(decoded[i].latitude, closeTo(original[i].latitude, 1e-5));
        expect(decoded[i].longitude, closeTo(original[i].longitude, 1e-5));
      }
    });

    test('손상된 문자열은 던지지 않고 해독한 만큼만 돌려준다', () {
      final truncated = encodePolyline(const [
        LatLngPoint(37.5665, 126.9780),
        LatLngPoint(37.5680, 126.9800),
      ]);
      // 마지막 한 글자를 잘라 뒷 좌표를 불완전하게 만든다.
      final broken = truncated.substring(0, truncated.length - 1);

      expect(() => decodePolyline(broken), returnsNormally);
      expect(decodePolyline(''), isEmpty);
    });
  });

  group('티어 카드 표기', () {
    test('상위 N%는 올림하고 1위도 0%가 되지 않는다', () {
      final card = TierPromotionCardData(
        athlete: ShareAthlete.fromUser(_user),
        achievedAt: DateTime.utc(2026, 8, 26),
        tier: Tier.gold,
        seasonId: '2026-Q3',
        seasonDistanceMeters: 123456,
        rank: 1,
        participantCount: 240,
      );
      expect(card.topPercent, 1);
      expect(card.headline, '골드 달성');
      expect(card.subhead, contains('123.5km'));
    });

    test('참가자 수를 모르면 퍼센트를 만들지 않는다', () {
      final card = TierPromotionCardData(
        athlete: ShareAthlete.fromUser(_user),
        achievedAt: DateTime.utc(2026, 8, 26),
        tier: Tier.silver,
        seasonId: '2026-Q3',
        seasonDistanceMeters: 30000,
        rank: 5,
      );
      expect(card.topPercent, isNull);
    });
  });
}
