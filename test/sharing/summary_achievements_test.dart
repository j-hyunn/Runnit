// Material의 `Badge` 위젯과 도메인 모델 `Badge`가 이름 충돌한다.
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/auth/auth_providers.dart';
import 'package:runnit/core/theme/app_theme.dart';
import 'package:runnit/features/history/data/history_providers.dart';
import 'package:runnit/features/tracking/presentation/widgets/summary_achievements.dart';
import 'package:runnit/models/models.dart';

/// 요약 화면 성취 블록(HI-10)의 **게이트 분기**를 검증한다.
///
/// 2026-08-27부터 성취(뱃지/티어/PB) 축하는 이 위젯이 아니라 전역
/// `AchievementCelebrationHost`의 풀페이지가 담당한다(사용자 요청) — 이
/// 위젯은 게이트 상태 문구만 그린다. 핵심 규칙 두 가지:
/// 1. 서버 확정 전(`pending`)에는 잠정 문구만.
/// 2. 서버가 플래그한 기록(`flagged`)은 블록 자체가 사라진다(회수 연출 없음).
void main() {
  const runId = 'run-1';

  final user = AppUser(
    id: 'u1',
    username: 'runner',
    displayName: '지현',
    currentTier: Tier.gold,
    level: 12,
    seasonDistanceMeters: 128400,
    tierSeasonId: '2026-Q3',
    createdAt: DateTime.utc(2026),
  );

  RunRecord record({
    SyncStatus syncStatus = SyncStatus.local,
    bool? isFlagged,
  }) =>
      RunRecord(
        id: runId,
        userId: 'u1',
        startedAt: DateTime.utc(2026, 8, 26, 9),
        activityType: ActivityType.outdoorRun,
        status: RunStatus.completed,
        distanceMeters: 5012,
        elapsedSeconds: 1560,
        movingSeconds: 1500,
        syncStatus: syncStatus,
        isFlagged: isFlagged,
      );

  /// [stored]는 로컬 DB가 들고 있는 **서버 확정본**(`storedRunProvider`의 출처).
  /// null이면 아직 업로드 결과가 도착하지 않은 상태다.
  Future<void> pumpBlock(
    WidgetTester tester, {
    RunRecord? stored,
    bool signedIn = true,
  }) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentProfileProvider
              .overrideWith((ref) async => signedIn ? user : null),
          myRunsProvider.overrideWith(
            (ref) => Stream.value(stored == null ? const [] : [stored]),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                SummaryAchievements(record: record()),
                RunShareButton(record: record()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('업로드 전에는 잠정 문구만 나온다', (tester) async {
    await pumpBlock(tester);

    expect(find.textContaining('아직 서버에 올리는 중'), findsOneWidget);
  });

  testWidgets('서버 확인이 끝나면 확정 문구로 바뀐다', (tester) async {
    await pumpBlock(
      tester,
      stored: record(syncStatus: SyncStatus.synced, isFlagged: false),
    );

    expect(find.textContaining('기록이 확인됐어요'), findsOneWidget);
    expect(find.textContaining('아직 서버에 올리는 중'), findsNothing);
  });

  testWidgets('업로드는 됐지만 판정값을 모르면 확정으로 넘어가지 않는다', (tester) async {
    // `isFlagged == null` = "아직 모른다". 이것을 정상 확정으로 취급하면
    // 나중에 플래그될 기록을 축하하고 공유까지 시키게 된다.
    await pumpBlock(tester, stored: record(syncStatus: SyncStatus.synced));

    expect(find.textContaining('아직 서버에 올리는 중'), findsOneWidget);
  });

  testWidgets('서버가 플래그한 기록은 성취 블록과 공유 버튼이 모두 사라진다', (tester) async {
    await pumpBlock(
      tester,
      stored: record(syncStatus: SyncStatus.synced, isFlagged: true),
    );

    expect(find.textContaining('기록이 확인됐어요'), findsNothing);
    expect(find.textContaining('아직 서버에 올리는 중'), findsNothing);
    // 회수 애니메이션도, 사유 안내도 없다 — 조용히 생략한다(TRD §11).
    expect(find.text('이 러닝 공유하기'), findsNothing);
  });

  testWidgets('러닝 자체는 성취가 없어도 공유할 수 있다', (tester) async {
    await pumpBlock(tester);

    expect(find.text('이 러닝 공유하기'), findsOneWidget);
  });

  testWidgets('프로필을 모르면 러닝 공유 버튼을 그리지 않는다', (tester) async {
    // 카드 하단의 러너 정보(이름·레벨·티어)를 채울 수 없다.
    await pumpBlock(tester, signedIn: false);

    expect(find.text('이 러닝 공유하기'), findsNothing);
  });
}
