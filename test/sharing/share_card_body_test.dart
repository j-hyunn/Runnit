import 'dart:ui' as ui;

// Material의 `Badge` 위젯과 도메인 모델 `Badge`가 이름 충돌한다.
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/features/sharing/domain/share_card_data.dart';
import 'package:runnit/features/sharing/presentation/widgets/share_card_body.dart';
import 'package:runnit/features/sharing/presentation/widgets/share_card_surface.dart';
import 'package:runnit/models/models.dart';

/// 카드 4종의 **그림**을 검증한다. 데이터 선택 규칙은
/// `share_card_builder_test.dart`가 맡고, 여기서는 "값이 비어도 레이아웃이
/// 무너지지 않는가 / 빠져야 할 것이 실제로 빠지는가"를 본다.
///
/// 오버플로는 `FlutterError.onError`가 예외로 올려 주므로 별도 단언이 필요 없다 —
/// 픽셀이 넘치면 테스트가 실패한다.
void main() {
  const athlete = ShareAthlete(
    displayName: '지현',
    tier: Tier.gold,
    level: 12,
  );
  final achievedAt = DateTime.utc(2026, 8, 26, 15);

  Future<void> pumpCard(
    WidgetTester tester,
    ShareCardData card, {
    GlobalKey? boundaryKey,
  }) async {
    // 실기기 폭에 가까운 값. 출력은 어차피 1080px로 역산되므로 이 크기는
    // 비율 계산이 성립하는지만 확인하는 용도다. 카드는 9:16이라 320 폭이면
    // 높이 568.9 — 실제로 그려질 수 있는 화면비다.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: ShareCardSurface(
                boundaryKey: boundaryKey ?? GlobalKey(),
                child: ShareCardBody(card: card),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('티어 승급 카드', () {
    TierPromotionCardData card({int? rank, int? participantCount}) =>
        TierPromotionCardData(
          athlete: athlete,
          achievedAt: achievedAt,
          tier: Tier.gold,
          seasonId: '2026-Q3',
          seasonDistanceMeters: 128400,
          rank: rank,
          participantCount: participantCount,
        );

    testWidgets('티어·시즌·누적 거리가 보이고 브랜드 워드마크가 찍힌다', (tester) async {
      await pumpCard(tester, card());

      expect(find.text('골드 달성'), findsOneWidget);
      expect(find.text('2026-Q3'), findsOneWidget);
      expect(find.text('128.4km'), findsOneWidget);
      // 브랜드 마크는 무료 광고 1회가 목적이라 어떤 카드에서도 빠지지 않는다.
      // 세로 9:16 재설계(2026-08-26)에서 사용자 레퍼런스를 따라 워드마크
      // 하나만 상단 중앙에 남기고(러너 이름·레벨 표시는 제거) 나머지는
      // 아트 + 수치 스택으로 옮겼다.
      expect(find.text('Runnit'), findsOneWidget);
    });

    testWidgets('순위는 절대 등수가 아니라 상위 %로 그린다', (tester) async {
      await pumpCard(tester, card(rank: 12, participantCount: 100));

      // PRD §5.4.1 — 소수 정예 노출. "12위"라고 쓰지 않는다.
      expect(find.text('상위 12%'), findsOneWidget);
      expect(find.textContaining('12위'), findsNothing);
    });

    testWidgets('모집단을 모르면 순위 칸 자체가 빠진다', (tester) async {
      await pumpCard(tester, card(rank: 12));

      expect(find.text('티어 내'), findsNothing);
    });
  });

  group('PB 카드', () {
    PersonalBestCardData card({int? certifiedSeconds}) => PersonalBestCardData(
          athlete: athlete,
          achievedAt: achievedAt,
          targetKm: 5,
          badgeAssetPath: 'assets/badges/PB/gold.svg',
          certifiedSeconds: certifiedSeconds,
        );

    testWidgets('확정 기록이 있으면 시간을 보여준다', (tester) async {
      await pumpCard(tester, card(certifiedSeconds: 1471));

      expect(find.text('5km 개인 최고 기록'), findsOneWidget);
      expect(find.text('24:31'), findsAtLeastNWidgets(1));
      expect(find.text('기록'), findsOneWidget);
    });

    testWidgets('서버 확정 시간이 없으면 시간 칸만 빠지고 카드는 성립한다', (tester) async {
      // 세션 거리가 목표의 102%를 넘으면 서버 보간값을 알 수 없다 —
      // 클라이언트가 지어내지 않고 비운다.
      await pumpCard(tester, card());

      expect(find.text('5km 개인 최고 기록'), findsOneWidget);
      expect(find.text('기록'), findsNothing);
      expect(find.text('5km'), findsOneWidget); // 종목 칸은 남는다
    });
  });

  testWidgets('뱃지 카드는 이름과 설명을 그린다', (tester) async {
    await pumpCard(
      tester,
      BadgeEarnedCardData(
        athlete: athlete,
        achievedAt: achievedAt,
        badge: const Badge(
          id: 'b1',
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

    expect(find.text('새벽 러너'), findsOneWidget);
    expect(find.text('오전 6시 이전에 10번 달렸어요'), findsOneWidget);
  });

  group('기록 카드', () {
    // 2026-08-26: 사용자가 준 정확한 레퍼런스를 그대로 따른다 — 헤드라인
    // ("완주") 문구 없이 Distance/Pace/Time 세 칸을 영문 라벨로 세로로
    // 쌓는다. 콜론 표기(`4:59 /km`)도 레퍼런스 그대로다(도메인의
    // `paceLabel`은 `4'59"/km` 형식이라 공유 캡션 등 다른 곳에서 계속 쓰인다
    // — 카드 그림에서만 다르게 표기한다).
    testWidgets('Distance·Pace·Time을 영문 라벨로 그리고 경로가 있으면 경로를 그린다',
        (tester) async {
      await pumpCard(
        tester,
        RunRecapCardData(
          athlete: athlete,
          achievedAt: achievedAt,
          distanceMeters: 5012,
          movingSeconds: 1500,
          elapsedSeconds: 1560,
          caloriesKcal: 320,
          route: const ShareRoute(
            points: [
              (lat: 37.5, lng: 127.0),
              (lat: 37.51, lng: 127.01),
              (lat: 37.52, lng: 127.0),
            ],
            distanceMeters: 5012,
          ),
        ),
      );

      expect(find.text('5.01km 완주'), findsNothing);
      expect(find.text('Distance'), findsOneWidget);
      expect(find.text('5.01km'), findsOneWidget);
      expect(find.text('Pace'), findsOneWidget);
      expect(find.text('4:59 /km'), findsOneWidget);
      expect(find.text('Time'), findsOneWidget);
      expect(find.text('25:00'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('실내 러닝(경로 없음)에서도 카드가 성립한다', (tester) async {
      await pumpCard(
        tester,
        RunRecapCardData(
          athlete: athlete,
          achievedAt: achievedAt,
          distanceMeters: 3000,
          movingSeconds: 900,
          elapsedSeconds: 900,
        ),
      );

      expect(find.text('Distance'), findsOneWidget);
      expect(find.text('3.00km'), findsOneWidget);
      // 경로가 없으면 빈 사각형 대신 활동 아이콘을 놓는다.
      expect(find.byIcon(Icons.directions_run_rounded), findsOneWidget);
    });

    testWidgets('거리가 0이면 Pace 칸이 빠진다', (tester) async {
      await pumpCard(
        tester,
        RunRecapCardData(
          athlete: athlete,
          achievedAt: achievedAt,
          distanceMeters: 0,
          movingSeconds: 0,
          elapsedSeconds: 0,
        ),
      );

      expect(find.text('Pace'), findsNothing);
      expect(find.text('Time'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);
    });
  });

  testWidgets('날짜+시각은 KST로 찍힌다', (tester) async {
    // UTC 15시는 KST로 다음 날 0시 — 밤 러닝이 하루 전날로 찍히면 안 된다.
    await pumpCard(
      tester,
      RunRecapCardData(
        athlete: athlete,
        achievedAt: DateTime.utc(2026, 8, 26, 15),
        distanceMeters: 1000,
        movingSeconds: 300,
        elapsedSeconds: 300,
      ),
    );

    expect(find.text('2026.08.27  00:00'), findsOneWidget);
  });

  testWidgets('카드에 불투명 배경이 없다 — 캡처된 이미지의 알파가 살아 있다', (tester) async {
    // 오버레이 스티커의 존재 이유가 걸린 회귀 테스트다. 누군가 카드 안에
    // `ColoredBox`/`Container(color:)`를 다시 넣으면 사용자 사진이 통째로
    // 가려진 PNG가 인스타로 나간다 — 코드 리뷰가 아니라 테스트로 막는다.
    final key = GlobalKey();
    await pumpCard(
      tester,
      RunRecapCardData(
        athlete: athlete,
        achievedAt: achievedAt,
        distanceMeters: 5012,
        movingSeconds: 1500,
        elapsedSeconds: 1560,
      ),
      boundaryKey: key,
    );

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // `toImage`/`toByteData`는 엔진 스레드 작업이라 `runAsync` 밖에서는
    // 영원히 완료되지 않는다(테스트가 그대로 멈춘다).
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data;
    });

    // 좌상단 모서리. 카드 패딩 안쪽이라 어떤 카드에서도 아무것도 그려지지
    // 않는 자리다(중앙 정렬 컬럼이라 모서리는 항상 비어 있다).
    expect(bytes!.getUint8(3), 0, reason: '카드 모서리가 불투명하다 — 배경이 칠해졌다');
  });
}
