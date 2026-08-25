import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/providers/repository_providers.dart';
import '../../../models/models.dart';

/// 활동 탭이 쓰는 provider들. **로컬 우선 저장소를 그대로 구독**한다
/// (`RunSyncCoordinator`가 백그라운드에서 서버와 맞춰준다) — 별도의
/// "활동 탭 전용 원격 조회"를 두지 않는다.
///
/// 통계(이번 달 요약/그래프)는 서버 캐시가 없어 **클라이언트에서 직접
/// 집계**한다. `AppUser.seasonDistanceMeters`(시즌 누적, 서버 확정값)와
/// 달리 "이번 달" 단위 통계는 서버에 대응하는 캐시 필드가 없기 때문이다 —
/// 대신 로컬 DB가 사용자의 전체 기록을 갖고 있으므로 여기서 계산해도
/// 정합성 문제가 없다(서버 확정값을 흉내 내는 게 아니라 원본 기록을 그대로 합산).

/// 로그인 사용자의 러닝 기록(최신순). 활동 탭의 통계·그래프·전체 목록이
/// 모두 이 하나의 스트림에서 파생된다 — 화면마다 다른 쿼리를 두지 않는다.
final myRunsProvider = StreamProvider<List<RunRecord>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return const Stream.empty();
  // 그래프(이번 달 일별 집계)가 최대 31일치를 봐야 하고, 활동이 잦은
  // 사용자도 한 달에 200건을 넘기지 않는다는 가정으로 넉넉히 잡는다.
  return ref.watch(runRepositoryProvider).watchByUser(userId, limit: 200);
});

/// "최근 기록" 미리보기 — 최신 3건.
final recentRunsProvider = Provider<List<RunRecord>>((ref) {
  final runs = ref.watch(myRunsProvider).valueOrNull ?? const <RunRecord>[];
  return runs.take(3).toList(growable: false);
});

/// 이번 달(로컬 달력 기준) 일별 거리 합계 + 요약 통계.
class MonthlyActivityStats {
  const MonthlyActivityStats({
    required this.dailyDistanceMeters,
    required this.runCount,
    required this.totalMovingSeconds,
    required this.totalDistanceMeters,
  });

  /// index 0 = 1일, ... 마지막 index = 이번 달 마지막 날.
  final List<double> dailyDistanceMeters;
  final int runCount;
  final int totalMovingSeconds;
  final double totalDistanceMeters;

  /// 이동 거리 가중 평균 페이스(s/km). 기록이 없으면 null.
  double? get avgPaceSecPerKm =>
      totalDistanceMeters <= 0 ? null : totalMovingSeconds / (totalDistanceMeters / 1000.0);
}

final monthlyActivityStatsProvider = Provider<MonthlyActivityStats>((ref) {
  final runs = ref.watch(myRunsProvider).valueOrNull ?? const <RunRecord>[];
  final now = DateTime.now();
  final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
  final daily = List<double>.filled(daysInMonth, 0);

  var runCount = 0;
  var totalMovingSeconds = 0;
  var totalDistanceMeters = 0.0;

  for (final run in runs) {
    final local = run.startedAt.toLocal();
    if (local.year != now.year || local.month != now.month) continue;
    daily[local.day - 1] += run.distanceMeters;
    runCount++;
    totalMovingSeconds += run.movingSeconds;
    totalDistanceMeters += run.distanceMeters;
  }

  return MonthlyActivityStats(
    dailyDistanceMeters: daily,
    runCount: runCount,
    totalMovingSeconds: totalMovingSeconds,
    totalDistanceMeters: totalDistanceMeters,
  );
});
