// Material의 `Badge` 위젯과 도메인 모델 `Badge`가 이름 충돌한다.
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/theme/app_theme.dart';
import 'package:runnit/features/sharing/data/share_providers.dart';
import 'package:runnit/features/sharing/domain/share_card_data.dart';
import 'package:runnit/features/sharing/presentation/widgets/achievement_celebration.dart';
import 'package:runnit/models/models.dart';

/// [AchievementCelebrationView]의 카드 종류별 공유 버튼 노출을 검증한다.
///
/// 2026-08-27(사용자 요청): 일반 뱃지([BadgeEarnedCardData])와 티어 승급
/// ([TierPromotionCardData])은 공유하지 않는다 — 둘 다 이 풀페이지 축하
/// 애니메이션 하나로 끝난다. **PB만** 공유 버튼을 받는다. 이 분기는 예전에
/// `SummaryAchievements`(요약 화면 인라인)에서도 간접적으로 검증됐지만,
/// 그 위젯이 게이트 문구만 그리도록 단순화되면서 이 파일로 옮겨왔다.
void main() {
  const athlete = ShareAthlete(displayName: '지현', tier: Tier.gold, level: 12);
  final achievedAt = DateTime.utc(2026, 8, 26, 9, 30);

  final earned = UserBadge(
    id: 'ub1',
    userId: 'u1',
    badgeId: 'b_dawn',
    earnedAt: achievedAt,
    verified: true,
  );

  Future<void> pumpView(
    WidgetTester tester,
    ShareCardData card, {
    int remaining = 0,
  }) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shareCardForAchievementProvider(earned).overrideWith((ref) async => card),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: AchievementCelebrationView(
              userBadge: earned,
              remaining: remaining,
              onDismiss: () {},
            ),
          ),
        ),
      ),
    );
    // 카드 Provider가 비동기(FutureProvider)라 한 프레임 더 필요하다.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('일반 뱃지는 축하하되 공유 버튼을 주지 않는다', (tester) async {
    await pumpView(
      tester,
      BadgeEarnedCardData(
        athlete: athlete,
        achievedAt: achievedAt,
        badge: const Badge(
          id: 'b_dawn',
          name: '새벽 러너',
          description: '오전 6시 이전에 10번 달렸어요',
          category: BadgeCategory.timeOfDayWeekday,
          scope: BadgeScope.permanent,
          triggerType: BadgeTriggerType.session,
          conditionType: 'x',
          badgeGrade: 'silver',
        ),
        badgeAssetPath: 'assets/badges/date/silver.svg',
      ),
    );

    expect(find.text('새 뱃지 획득'), findsOneWidget);
    expect(find.text('새벽 러너'), findsOneWidget);
    expect(find.text('공유하기'), findsNothing);
    expect(find.text('확인'), findsOneWidget);
  });

  testWidgets('티어 승급 카드는 축하하되 공유 버튼을 주지 않는다', (tester) async {
    await pumpView(
      tester,
      TierPromotionCardData(
        athlete: athlete,
        achievedAt: achievedAt,
        tier: Tier.gold,
        seasonId: '2026-Q3',
        seasonDistanceMeters: 128400,
      ),
    );

    expect(find.text('티어 승급'), findsOneWidget);
    expect(find.text('골드 달성'), findsOneWidget);
    expect(find.text('공유하기'), findsNothing);
    expect(find.text('확인'), findsOneWidget);
  });

  testWidgets('PB 카드는 공유 버튼을 받는다', (tester) async {
    await pumpView(
      tester,
      PersonalBestCardData(
        athlete: athlete,
        achievedAt: achievedAt,
        targetKm: 5,
        badgeAssetPath: 'assets/badges/PB/gold.svg',
        certifiedSeconds: 1471,
      ),
    );

    expect(find.text('개인 최고 기록'), findsOneWidget);
    expect(find.text('공유하기'), findsOneWidget);
  });

  testWidgets('남은 성취가 있으면 확인 대신 다음이 뜬다', (tester) async {
    await pumpView(
      tester,
      BadgeEarnedCardData(
        athlete: athlete,
        achievedAt: achievedAt,
        badge: const Badge(
          id: 'b_dawn',
          name: '새벽 러너',
          description: '오전 6시 이전에 10번 달렸어요',
          category: BadgeCategory.timeOfDayWeekday,
          scope: BadgeScope.permanent,
          triggerType: BadgeTriggerType.session,
          conditionType: 'x',
          badgeGrade: 'silver',
        ),
        badgeAssetPath: 'assets/badges/date/silver.svg',
      ),
      remaining: 2,
    );

    expect(find.text('외 2개 더 있어요'), findsOneWidget);
    expect(find.text('다음'), findsOneWidget);
    expect(find.text('확인'), findsNothing);
  });
}
