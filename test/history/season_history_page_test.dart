import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/auth/auth_providers.dart';
import 'package:runnit/core/error/failure.dart';
import 'package:runnit/core/providers/repository_providers.dart';
import 'package:runnit/core/repositories/season_history_repository.dart';
import 'package:runnit/core/theme/app_theme.dart';
import 'package:runnit/features/history/data/season_history_providers.dart';
import 'package:runnit/features/history/presentation/season_history_page.dart';
import 'package:runnit/models/models.dart';

/// 역대 시즌 기록 화면(HI-06)의 **상태별 화면**을 검증한다 —
/// 정상/빈 목록/무효 시즌/에러/게스트.
///
/// 서버 스냅샷을 그대로 그리는 화면이라 계산 로직이 없다. 그래서 검증 대상은
/// (a) 필드가 올바른 자리에 바인딩되는가, (b) 무효 시즌이 숨겨지지 않고
/// 구분 표시되는가, (c) 데이터가 없을 때 빈 화면 대신 안내가 나오는가다.
void main() {
  final closedAt = DateTime.utc(2026, 7, 1);

  SeasonHistory history({
    required String seasonId,
    Tier finalTier = Tier.gold,
    double distanceMeters = 123450,
    int runCount = 21,
    int movingSeconds = 3725,
    int? bestWeeklyRank,
    bool isVoided = false,
  }) =>
      SeasonHistory(
        id: 'sh-$seasonId',
        userId: 'user-1',
        seasonId: seasonId,
        finalTier: finalTier,
        distanceMeters: distanceMeters,
        runCount: runCount,
        movingSeconds: movingSeconds,
        bestWeeklyRank: bestWeeklyRank,
        closedAt: closedAt,
        isVoided: isVoided,
      );

  Future<void> pump(
    WidgetTester tester, {
    required SeasonHistoryRepository repository,
    String? userId = 'user-1',
  }) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue(userId),
          seasonHistoryRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SeasonHistoryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('시즌 결과를 최신순 카드로 보여준다', (tester) async {
    await pump(
      tester,
      repository: _FakeSeasonHistoryRepository([
        history(seasonId: '2026-Q2', bestWeeklyRank: 7),
        history(seasonId: '2026-Q1', finalTier: Tier.silver),
      ]),
    );

    expect(find.text('2026 Q2'), findsOneWidget);
    expect(find.text('2026 Q1'), findsOneWidget);

    // 거리 123450m → 123.45 km, 3725초 → 1:02:05.
    expect(find.text('123.45 km'), findsNWidgets(2));
    expect(find.text('21'), findsNWidgets(2));
    expect(find.text('1:02:05'), findsNWidgets(2));

    // 최고 주간 순위는 값이 있는 시즌에만 나온다.
    expect(find.text('7위'), findsOneWidget);
    expect(find.text('주간 최고 순위'), findsOneWidget);

    // TI-09 요약 — 무효가 아닌 시즌 중 최고 티어(Gold)와 시즌 수.
    expect(find.text('역대 최고 티어'), findsOneWidget);
    expect(find.text('완료한 시즌 2개'), findsOneWidget);
  });

  testWidgets('완료된 시즌이 없으면 안내를 보여준다', (tester) async {
    await pump(tester, repository: _FakeSeasonHistoryRepository(const []));

    expect(find.text('아직 완료된 시즌이 없어요'), findsOneWidget);
    expect(find.text('이번 시즌이 끝나면 여기에 기록돼요.'), findsOneWidget);
  });

  testWidgets('무효 시즌은 숨기지 않고 흐리게 + 라벨로 구분한다', (tester) async {
    await pump(
      tester,
      repository: _FakeSeasonHistoryRepository([
        history(seasonId: '2026-Q2', finalTier: Tier.silver),
        history(seasonId: '2026-Q1', finalTier: Tier.platinum, isVoided: true),
      ]),
    );

    // 행 자체는 남는다(§8.1 — 삭제하면 이의 제기 근거가 사라진다).
    expect(find.text('2026 Q1'), findsOneWidget);
    expect(find.text('무효 처리됨'), findsOneWidget);
    expect(
      tester.widgetList<Opacity>(find.byType(Opacity)).any((o) => o.opacity < 1),
      isTrue,
    );

    // 무효 시즌의 플래티넘은 "역대 최고 티어"에 반영되지 않는다.
    expect(find.text('완료한 시즌 1개'), findsOneWidget);
  });

  testWidgets('조회 실패는 에러 안내로 처리한다', (tester) async {
    await pump(tester, repository: _ThrowingSeasonHistoryRepository());

    expect(find.text('시즌 기록을 불러오지 못했어요'), findsOneWidget);
  });

  testWidgets('게스트는 리포지토리를 건드리지 않고 빈 상태가 된다', (tester) async {
    final repository = _FakeSeasonHistoryRepository([history(seasonId: '2026-Q2')]);
    await pump(tester, repository: repository, userId: null);

    expect(repository.calls, isEmpty);
    expect(find.text('아직 완료된 시즌이 없어요'), findsOneWidget);
  });

  test('bestEverTierProvider는 무효 시즌을 제외하고 최고 티어를 고른다', () async {
    final container = ProviderContainer(
      overrides: [
        currentUserIdProvider.overrideWithValue('user-1'),
        seasonHistoryRepositoryProvider.overrideWithValue(
          _FakeSeasonHistoryRepository([
            history(seasonId: '2026-Q2', finalTier: Tier.bronze),
            history(seasonId: '2026-Q1', finalTier: Tier.platinum, isVoided: true),
            history(seasonId: '2025-Q4', finalTier: Tier.gold),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(mySeasonHistoriesProvider.future);
    expect(container.read(bestEverTierProvider), Tier.gold);
  });
}

class _FakeSeasonHistoryRepository implements SeasonHistoryRepository {
  _FakeSeasonHistoryRepository(this.items);

  final List<SeasonHistory> items;
  final List<String> calls = [];

  @override
  Future<List<SeasonHistory>> fetchByUser(String userId) async {
    calls.add(userId);
    return items;
  }
}

class _ThrowingSeasonHistoryRepository implements SeasonHistoryRepository {
  @override
  Future<List<SeasonHistory>> fetchByUser(String userId) async =>
      throw const Failure.network(message: 'boom');
}
