
/// 뱃지 진행률 표시에 필요한 사용자 통계 **스냅샷**.
///
/// ## 왜 이게 필요한가
/// `AppUser`(= `profiles`)에는 누적 통계 4종과 스트릭만 캐시돼 있다. 뱃지 지표 12종 중
/// 나머지(단일 러닝 최장 거리, 최고 페이스, 고도, 시간대별 횟수)의 현재값은 서버가
/// 내려주지 않으므로, 클라이언트가 로컬 러닝 기록에서 직접 집계해야 진행률 바를 그릴 수 있다.
///
/// ## 이 값은 정본이 아니다
/// 로컬 기록만 스캔하므로 다른 기기에서 뛴 러닝이 빠질 수 있고, 서버의 `is_flagged`
/// 판정도 알 수 없다(모델에 해당 필드가 없다 — 규칙서 §7 A1 참조). 따라서 여기서 나온
/// 값으로 계산한 진행률은 **실제보다 낮거나 높을 수 있는 추정치**다.
/// 뱃지 획득 여부는 오직 서버가 내려준 `UserBadge` 목록이 결정한다.
///
/// 캐시 통계(`totalDistanceMeters` 등)는 서버 값을 그대로 쓰므로 로컬 집계보다 정확하다 —
/// [fromUserAndRuns]가 그 둘을 섞는 이유다.
library;

import '../../../models/models.dart';

/// 서버 시각(UTC) → KST 변환에 쓰는 고정 오프셋. 한국은 서머타임이 없다.
const Duration _kstOffset = Duration(hours: 9);

/// 뱃지 진행률 계산의 입력. 모든 필드는 SI 단위(규약: `core/utils/units.dart`).
class GamificationStats {
  const GamificationStats({
    this.totalRunCount = 0,
    this.totalDistanceMeters = 0,
    this.totalMovingSeconds = 0,
    this.longestStreakDays = 0,
    this.maxSingleRunDistanceMeters = 0,
    this.bestPaceSecPerKmOver5k,
    this.bestPaceSecPerKmOver10k,
    this.maxSingleRunElevationGainMeters = 0,
    this.totalElevationGainMeters = 0,
    this.earlyRunCount = 0,
    this.nightRunCount = 0,
    this.completedChallengeCount = 0,
  });

  /// 서버 캐시 출처 (정확).
  final int totalRunCount;
  final double totalDistanceMeters;
  final int totalMovingSeconds;
  final int longestStreakDays;

  /// 로컬 집계 출처 (추정).
  final double maxSingleRunDistanceMeters;

  /// 5km 이상 러닝 중 **가장 빠른**(가장 작은) 평균 페이스(s/km). 해당 러닝이 없으면 null.
  final double? bestPaceSecPerKmOver5k;

  /// 10km 이상 러닝 중 가장 빠른 평균 페이스(s/km). 해당 러닝이 없으면 null.
  final double? bestPaceSecPerKmOver10k;

  final double maxSingleRunElevationGainMeters;
  final double totalElevationGainMeters;
  final int earlyRunCount;
  final int nightRunCount;
  final int completedChallengeCount;

  static const GamificationStats empty = GamificationStats();

  /// 서버 캐시([user])와 로컬 러닝 기록([runs])을 합쳐 스냅샷을 만든다. 순수 함수.
  ///
  /// 누적 4종과 스트릭은 [user]의 서버 캐시를 신뢰하고, 나머지는 [runs]에서 집계한다.
  /// [runs]는 로컬 DB의 전체 기록을 넘기는 것을 전제로 한다 — 일부만 넘기면
  /// `maxSingleRunDistanceMeters` 등이 과소 집계된다.
  ///
  /// [completedChallengeCount]는 `ChallengeParticipation.completedAt != null` 개수를
  /// 호출부가 세어서 넘긴다(러닝 기록에서는 알 수 없다).
  factory GamificationStats.fromUserAndRuns({
    required AppUser user,
    required Iterable<RunRecord> runs,
    int completedChallengeCount = 0,
  }) {
    final local = GamificationStats.fromRuns(runs);
    return GamificationStats(
      // 서버 캐시 우선 — 다른 기기 기록까지 반영돼 있다.
      totalRunCount: user.totalRunCount,
      totalDistanceMeters: user.totalDistanceMeters,
      totalMovingSeconds: user.totalMovingSeconds,
      longestStreakDays: user.longestStreakDays,
      // 서버가 캐시하지 않는 값 — 로컬 집계로 대체(추정치).
      maxSingleRunDistanceMeters: local.maxSingleRunDistanceMeters,
      bestPaceSecPerKmOver5k: local.bestPaceSecPerKmOver5k,
      bestPaceSecPerKmOver10k: local.bestPaceSecPerKmOver10k,
      maxSingleRunElevationGainMeters: local.maxSingleRunElevationGainMeters,
      totalElevationGainMeters: local.totalElevationGainMeters,
      earlyRunCount: local.earlyRunCount,
      nightRunCount: local.nightRunCount,
      completedChallengeCount: completedChallengeCount,
    );
  }

  /// 러닝 기록만으로 집계. 서버 캐시 필드도 로컬 값으로 채운다(로그인 전/오프라인 폴백).
  ///
  /// 순수 함수 — 입력에만 의존하고 부수효과가 없다. 서버가 동일 집계를 SQL로
  /// 재구현할 때 참조 구현으로 쓸 수 있다(규칙서 §1.1 "값의 출처" 표와 1:1 대응).
  factory GamificationStats.fromRuns(Iterable<RunRecord> runs) {
    var runCount = 0;
    var totalDistance = 0.0;
    var totalMoving = 0;
    var maxDistance = 0.0;
    double? bestPace5k;
    double? bestPace10k;
    var maxElevation = 0.0;
    var totalElevation = 0.0;
    var early = 0;
    var night = 0;

    for (final run in runs) {
      // 서버 판정 기준과 동일하게 completed만 센다.
      // is_flagged는 클라이언트가 알 수 없어 걸러내지 못한다 → 과대 추정 가능.
      if (run.status != RunStatus.completed) continue;

      runCount += 1;
      totalDistance += run.distanceMeters;
      totalMoving += run.movingSeconds;

      if (run.distanceMeters > maxDistance) maxDistance = run.distanceMeters;

      final gain = run.elevationGainMeters ?? 0;
      if (gain > maxElevation) maxElevation = gain;
      totalElevation += gain;

      // 페이스는 저장값(avgPaceSecPerKm)이 아니라 거리/시간에서 재계산한다.
      // 서버가 upsert 시 같은 식으로 덮어쓰므로(backend §6) 동일 결과가 된다.
      if (run.movingSeconds > 0 && run.distanceMeters > 0) {
        final pace = run.movingSeconds / (run.distanceMeters / 1000.0);
        if (run.distanceMeters >= 5000) {
          if (bestPace5k == null || pace < bestPace5k) bestPace5k = pace;
        }
        if (run.distanceMeters >= 10000) {
          if (bestPace10k == null || pace < bestPace10k) bestPace10k = pace;
        }
      }

      final kstHour = run.startedAt.toUtc().add(_kstOffset).hour;
      if (kstHour >= 5 && kstHour < 7) early += 1;
      if (kstHour >= 21 || kstHour < 4) night += 1;
    }

    return GamificationStats(
      totalRunCount: runCount,
      totalDistanceMeters: totalDistance,
      totalMovingSeconds: totalMoving,
      longestStreakDays: computeLongestStreakDays(runs),
      maxSingleRunDistanceMeters: maxDistance,
      bestPaceSecPerKmOver5k: bestPace5k,
      bestPaceSecPerKmOver10k: bestPace10k,
      maxSingleRunElevationGainMeters: maxElevation,
      totalElevationGainMeters: totalElevation,
      earlyRunCount: early,
      nightRunCount: night,
    );
  }

  /// 역대 최장 연속 러닝 일수. 서버의 gaps-and-islands 쿼리와 동일한 규약을 따른다:
  /// **KST 일자 기준, `startedAt` 귀속, 하루 여러 번은 1일.**
  ///
  /// 순수 함수. 규칙서 §2.3의 SQL과 1:1 대응한다.
  static int computeLongestStreakDays(Iterable<RunRecord> runs) {
    final days = <int>{};
    for (final run in runs) {
      if (run.status != RunStatus.completed) continue;
      final kst = run.startedAt.toUtc().add(_kstOffset);
      // UTC 자정 기준 일련번호로 정규화 — 타임존 재적용 없이 날짜만 비교한다.
      days.add(DateTime.utc(kst.year, kst.month, kst.day)
              .millisecondsSinceEpoch ~/
          Duration.millisecondsPerDay);
    }
    if (days.isEmpty) return 0;

    final sorted = days.toList()..sort();
    var longest = 1;
    var current = 1;
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i] == sorted[i - 1] + 1) {
        current += 1;
        if (current > longest) longest = current;
      } else {
        current = 1;
      }
    }
    return longest;
  }
}
