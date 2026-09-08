import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/models/models.dart';

/// 마이그레이션 65·66이 확정한 **wire 계약**을 모델 계층에 못 박는다
/// (TRD §14 #18 · #31).
///
/// 이 파일이 지키는 것은 화면 동작이 아니라 **파싱 규약**이다 — 컬럼이 nullable
/// 이라는 사실, 숫자 타입이 `numeric`이라 소수가 온다는 사실. 둘 다 서버가
/// 보내기 시작한 뒤에 런타임에서 터지는 부류라 여기서 먼저 고정한다.
void main() {
  group('#18 — user_badges.achieved_value', () {
    test('numeric 소수를 double로 받는다 (int로 받으면 PB 보간값에서 터진다)', () {
      final badge = UserBadge.fromJson(const {
        'id': 'ub1',
        'user_id': 'u1',
        'badge_id': 'pb_5km',
        'earned_at': '2026-09-08T03:00:00Z',
        'achieved_value': 1470.6,
      });

      expect(badge.achievedValue, closeTo(1470.6, 1e-9));
    });

    test('정수로 내려와도 double로 승격된다 (스트릭 주 수·등수 계열)', () {
      final badge = UserBadge.fromJson(const {
        'id': 'ub2',
        'user_id': 'u1',
        'badge_id': 'streak_4w',
        'earned_at': '2026-09-08T03:00:00Z',
        'achieved_value': 4,
      });

      expect(badge.achievedValue, 4.0);
    });

    test('null이 정상이다 — 65 이전 지급분과 값 시맨틱 없는 34종', () {
      final missing = UserBadge.fromJson(const {
        'id': 'ub3',
        'user_id': 'u1',
        'badge_id': 'first_run',
        'earned_at': '2026-09-08T03:00:00Z',
      });
      final explicitNull = UserBadge.fromJson(const {
        'id': 'ub4',
        'user_id': 'u1',
        'badge_id': 'first_run',
        'earned_at': '2026-09-08T03:00:00Z',
        'achieved_value': null,
      });

      expect(missing.achievedValue, isNull);
      expect(explicitNull.achievedValue, isNull);
    });

    test('snake_case 키로 되돌아간다', () {
      final value = UserBadge(
        id: 'ub5',
        userId: 'u1',
        badgeId: 'pb_10km',
        earnedAt: DateTime.utc(2026, 9, 8, 3),
        achievedValue: 2400.5,
      );

      expect(value.toJson()['achieved_value'], 2400.5);
      expect(value.copyWith(achievedValue: null).toJson()['achieved_value'],
          isNull);
    });
  });

  group('#31 — season_leaderboard_snapshots.rank는 nullable', () {
    Map<String, dynamic> row({Object? rank, bool isVoided = false}) => {
          'user_id': 'u1',
          'season_id': '2026-Q3',
          'tier': 'gold',
          'rank': rank,
          'participant_count': 240,
          'season_distance_meters': 123456.0,
          'run_count': 30,
          'moving_seconds': 90000,
          'reached_at': '2026-09-28T11:00:00Z',
          'computed_at': '2026-09-30T15:00:00Z',
          'is_voided': isVoided,
        };

    test('유효한 행은 순위를 그대로 갖는다', () {
      final snapshot = SeasonLeaderboardSnapshot.fromJson(row(rank: 12));

      expect(snapshot.rank, 12);
      expect(snapshot.hasRank, isTrue);
      expect(snapshot.isVoided, isFalse);
      expect(snapshot.tier, Tier.gold);
      expect(snapshot.seasonDistanceMeters, 123456.0);
      expect(snapshot.reachedAt, DateTime.utc(2026, 9, 28, 11));
      expect(snapshot.computedAt, DateTime.utc(2026, 9, 30, 15));
    });

    test('무효 행은 rank가 null로 내려오고 파싱이 던지지 않는다', () {
      // 마이그레이션 66의 CHECK: is_voided ⇔ rank is null.
      final snapshot =
          SeasonLeaderboardSnapshot.fromJson(row(rank: null, isVoided: true));

      expect(snapshot.rank, isNull);
      expect(snapshot.hasRank, isFalse);
      expect(snapshot.isVoided, isTrue);
      // participant_count는 무효 행에도 **유효 참가자 수**가 들어간다.
      expect(snapshot.participantCount, 240);
    });

    test('순위가 없으면 상위 %도 만들지 않는다 — 0%·1위로 오해되면 안 된다', () {
      final voided =
          SeasonLeaderboardSnapshot.fromJson(row(rank: null, isVoided: true));
      expect(voided.topPercent, isNull);
    });

    test('상위 %는 올림하고 1위도 0%가 되지 않는다', () {
      expect(SeasonLeaderboardSnapshot.fromJson(row(rank: 1)).topPercent, 1);
      expect(SeasonLeaderboardSnapshot.fromJson(row(rank: 240)).topPercent, 100);
    });

    test('참가자 수가 0이면 퍼센트를 만들지 않는다 (0으로 나누지 않는다)', () {
      final r = row(rank: 1)..['participant_count'] = 0;
      expect(SeasonLeaderboardSnapshot.fromJson(r).topPercent, isNull);
    });

    test('rank를 뺀 채 왕복해도 null이 유지된다', () {
      final snapshot =
          SeasonLeaderboardSnapshot.fromJson(row(rank: null, isVoided: true));
      final json = snapshot.toJson();

      expect(json['rank'], isNull);
      expect(json['is_voided'], isTrue);
      expect(json['season_distance_meters'], 123456.0);
      expect(SeasonLeaderboardSnapshot.fromJson(json), snapshot);
    });
  });
}
