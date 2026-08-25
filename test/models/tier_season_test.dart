import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/models/models.dart';

void main() {
  group('Tier 판정 (PRD §5.3.2)', () {
    test('기준선에서 정확히 승급한다', () {
      expect(TierX.fromSeasonDistanceMeters(0), Tier.bronze);
      expect(TierX.fromSeasonDistanceMeters(24999), Tier.bronze);
      expect(TierX.fromSeasonDistanceMeters(25000), Tier.silver);
      expect(TierX.fromSeasonDistanceMeters(99999), Tier.silver);
      expect(TierX.fromSeasonDistanceMeters(100000), Tier.gold);
      expect(TierX.fromSeasonDistanceMeters(250000), Tier.platinum);
      expect(TierX.fromSeasonDistanceMeters(999999), Tier.platinum);
    });

    test('플래티넘은 다음 티어가 없다', () {
      expect(Tier.platinum.next, isNull);
      expect(TierX.remainingToNextMeters(250000), isNull);
    });

    test('다음 티어까지 남은 거리', () {
      expect(TierX.remainingToNextMeters(0), 25000);
      expect(TierX.remainingToNextMeters(30000), 70000);
    });
  });

  group('AppUser 티어 진행률 (TI-05)', () {
    AppUser user({required Tier tier, required double meters}) => AppUser(
          id: 'u',
          username: 'runner',
          currentTier: tier,
          seasonDistanceMeters: meters,
          createdAt: DateTime.utc(2026),
        );

    test('서버가 준 currentTier를 기준으로 계산한다', () {
      final u = user(tier: Tier.silver, meters: 62500);
      expect(u.nextTier, Tier.gold);
      expect(u.remainingToNextTierMeters, 37500);
      expect(u.tierProgress, closeTo(0.5, 1e-9));
    });

    test('플래티넘은 진행률 1.0', () {
      final u = user(tier: Tier.platinum, meters: 300000);
      expect(u.tierProgress, 1.0);
      expect(u.remainingToNextTierMeters, isNull);
    });

    test('기본값은 브론즈 · 시즌 거리 0', () {
      final u = AppUser(
        id: 'u',
        username: 'runner',
        createdAt: DateTime.utc(2026),
      );
      expect(u.currentTier, Tier.bronze);
      expect(u.seasonDistanceMeters, 0);
      expect(u.tierSeasonId, isNull);
    });
  });

  group('시즌 경계 (PRD §8.5)', () {
    test('분기 id는 KST 기준으로 정해진다', () {
      // 2026-07-01 00:00 KST == 2026-06-30 15:00 UTC → 이미 Q3 다.
      expect(Season.idAt(DateTime.utc(2026, 6, 30, 15)), '2026-Q3');
      expect(Season.idAt(DateTime.utc(2026, 6, 30, 14, 59)), '2026-Q2');
      expect(Season.idAt(DateTime.utc(2026, 8, 21)), '2026-Q3');
    });

    test('시작/종료는 UTC로 반환되며 반열림 구간이다', () {
      expect(Season.startOf('2026-Q3'), DateTime.utc(2026, 6, 30, 15));
      expect(Season.endOf('2026-Q3'), DateTime.utc(2026, 9, 30, 15));
      expect(Season.endOf('2026-Q3'), Season.startOf('2026-Q4'));
    });

    test('연말 경계를 넘는다', () {
      expect(Season.nextId('2026-Q4'), '2027-Q1');
      expect(Season.previousId('2027-Q1'), '2026-Q4');
      expect(Season.startOf('2027-Q1'), DateTime.utc(2026, 12, 31, 15));
    });

    test('러닝은 시작 시각으로 귀속된다', () {
      // 시즌 마지막 날 23:30 KST 에 시작해 다음 시즌으로 넘어간 러닝.
      final startedAt = DateTime.utc(2026, 9, 30, 14, 30);
      expect(Season.idForRun(startedAt), '2026-Q3');
    });

    test('잘못된 형식은 거부한다', () {
      expect(() => Season.startOf('2026-Q5'), throwsFormatException);
      expect(() => Season.startOf('2026Q3'), throwsFormatException);
    });
  });

  group('주간 경계 (RK-01)', () {
    test('KST 월요일 00:00 에 시작한다', () {
      // 2026-08-21 은 금요일. 그 주 월요일은 2026-08-17 00:00 KST.
      final friday = DateTime.utc(2026, 8, 21, 3);
      expect(RankingWeek.startOf(friday), DateTime.utc(2026, 8, 16, 15));
      expect(RankingWeek.endOf(friday), DateTime.utc(2026, 8, 23, 15));
    });

    test('일요일 23:59 KST 는 아직 같은 주다', () {
      final sundayLate = DateTime.utc(2026, 8, 23, 14, 59);
      expect(RankingWeek.startOf(sundayLate), DateTime.utc(2026, 8, 16, 15));
    });

    test('월요일 00:00 KST 는 새 주다', () {
      final monday = DateTime.utc(2026, 8, 23, 15);
      expect(RankingWeek.startOf(monday), DateTime.utc(2026, 8, 23, 15));
    });
  });

  group('RankingEntry 티어 차원 (RK-02 / RK-04)', () {
    RankingEntry entry({Tier? tier, int? participants}) => RankingEntry(
          userId: 'u',
          username: 'runner',
          rank: 34,
          metric: RankingMetric.distance,
          score: 42000,
          period: RankingPeriod.weekly,
          scope: RankingScope.global,
          tier: tier,
          participantCount: participants,
          periodStart: DateTime.utc(2026, 8, 16, 15),
          periodEnd: DateTime.utc(2026, 8, 23, 15),
        );

    test('tier는 scope와 직교하며 nullable 이다', () {
      expect(entry().tier, isNull);
      expect(entry(tier: Tier.silver).scope, RankingScope.global);
      expect(entry(tier: Tier.silver).tier, Tier.silver);
    });

    test('상위 % 는 올림하며 참가자 수가 없으면 null', () {
      expect(entry(participants: 100).topPercent, 34);
      expect(entry(participants: 45).topPercent, 76);
      expect(entry().topPercent, isNull);
    });

    test('직렬화 키는 snake_case 이고 tier 라벨은 소문자다', () {
      final json = entry(tier: Tier.platinum, participants: 10).toJson();
      expect(json['tier'], 'platinum');
      expect(json['participant_count'], 10);
      expect(json['period_start'], isNotNull);
      expect(RankingEntry.fromJson(json).tier, Tier.platinum);
    });
  });

  group('SeasonHistory (HI-06)', () {
    test('시즌 경계는 seasonId에서 파생된다', () {
      final h = SeasonHistory(
        id: 'h1',
        userId: 'u',
        seasonId: '2026-Q3',
        finalTier: Tier.gold,
        distanceMeters: 132000,
        runCount: 24,
        movingSeconds: 46000,
        closedAt: DateTime.utc(2026, 9, 30, 15),
      );
      expect(h.startAt, DateTime.utc(2026, 6, 30, 15));
      expect(h.endAt, DateTime.utc(2026, 9, 30, 15));
      expect(h.seasonLabel, '2026 Q3');
      expect(h.isVoided, isFalse);

      final json = h.toJson();
      expect(json['season_id'], '2026-Q3');
      expect(json['final_tier'], 'gold');
      expect(json['distance_meters'], 132000);
      expect(json.containsKey('start_at'), isFalse);
    });
  });
}
