// Material의 `Badge` 위젯과 도메인 모델 `Badge`가 이름 충돌한다.
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/auth/auth_providers.dart';
import 'package:runnit/core/theme/app_theme.dart';
import 'package:runnit/features/history/data/history_providers.dart';
import 'package:runnit/features/sharing/data/share_providers.dart';
import 'package:runnit/features/tracking/presentation/widgets/summary_achievements.dart';
import 'package:runnit/models/models.dart';

/// 요약 화면 성취 블록(HI-10)의 **게이트 분기**를 검증한다.
///
/// 핵심 규칙 세 가지:
/// 1. 서버 확정 전(`pending`)에는 잠정 문구만 — 성취 축하도 공유도 없다.
/// 2. 서버가 플래그한 기록(`flagged`)은 블록 자체가 사라진다(회수 연출 없음).
/// 3. 큐에 도착한 성취는 **그 자체로 서버 확정**이라 공유 버튼이 붙는다.
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

  const badge = Badge(
    id: 'b_dawn',
    name: '새벽 러너',
    description: '오전 6시 이전에 10번 달렸어요',
    category: BadgeCategory.timeOfDayWeekday,
    scope: BadgeScope.permanent,
    triggerType: BadgeTriggerType.session,
    conditionType: 'x',
    badgeGrade: 'silver',
  );

  final earned = UserBadge(
    id: 'ub1',
    userId: 'u1',
    badgeId: badge.id,
    earnedAt: DateTime.utc(2026, 8, 26, 9, 30),
    verified: true,
    badge: badge,
  );

  /// [stored]는 로컬 DB가 들고 있는 **서버 확정본**(`storedRunProvider`의 출처).
  /// null이면 아직 업로드 결과가 도착하지 않은 상태다.
  Future<void> pumpBlock(
    WidgetTester tester, {
    RunRecord? stored,
    List<UserBadge> queue = const [],
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
          pendingAchievementsProvider.overrideWith((ref) => Stream.value(queue)),
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

  testWidgets('업로드 전에는 잠정 문구만 나오고 성취 축하는 없다', (tester) async {
    await pumpBlock(tester);

    expect(find.textContaining('아직 서버에 올리는 중'), findsOneWidget);
    expect(find.text('공유하기'), findsNothing);
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

  testWidgets('큐에 도착한 성취는 축하 + 공유 버튼을 받는다', (tester) async {
    await pumpBlock(
      tester,
      stored: record(syncStatus: SyncStatus.synced, isFlagged: false),
      queue: [earned],
    );

    expect(find.text('새 뱃지 획득'), findsOneWidget);
    expect(find.text('새벽 러너'), findsOneWidget);
    expect(find.text('공유하기'), findsOneWidget);
    expect(find.text('확인'), findsOneWidget);
  });

  testWidgets('여러 건이 동시에 와도 한 번에 하나만 연출하고 남은 수를 알린다', (tester) async {
    await pumpBlock(
      tester,
      stored: record(syncStatus: SyncStatus.synced, isFlagged: false),
      queue: [
        earned,
        earned.copyWith(id: 'ub2', badgeId: 'b2'),
      ],
    );

    expect(find.text('새벽 러너'), findsOneWidget);
    expect(find.text('외 1개 더 있어요'), findsOneWidget);
    expect(find.text('다음'), findsOneWidget);
  });

  testWidgets('밀려 있던 성취는 한 장으로 접어 보여준다', (tester) async {
    // 연출을 처음 켜는 순간 기존 사용자에게 쏟아지는 뱃지(TRD §14 #19).
    await pumpBlock(
      tester,
      stored: record(syncStatus: SyncStatus.synced, isFlagged: false),
      queue: [
        for (var i = 0; i < 8; i++)
          earned.copyWith(id: 'ub$i', badgeId: 'b$i'),
      ],
    );

    expect(find.text('그동안 받은 뱃지 8개'), findsOneWidget);
    // 여덟 번 넘기게 만들지 않는다.
    expect(find.text('다음'), findsNothing);
    expect(find.text('공유하기'), findsNothing);
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
