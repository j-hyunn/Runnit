/// 뱃지 아트 경로 해석 — `assets/badges/{카테고리}/{등급}.svg`.
///
/// ## 왜 domain에 있는가
/// 이 규칙은 원래 `presentation/badge_gallery_page.dart`의 private 함수 두 개였다.
/// 2026-08-26 공유 카드(HI-08)가 **같은 메달을 카드에도 그려야** 하면서 두 번째
/// 소비자가 생겼다 — 갤러리에서 본 메달과 인스타에 올라간 메달이 다르면 그건
/// 버그이므로, 규칙을 한 곳에만 둔다.
///
/// `badge_gallery_page.dart`의 private 사본은 2026-08-26 UI 라운드에서
/// 제거되고 이 함수로 위임하도록 정리됐다.
library;

import '../../../models/enums.dart';

/// [BadgeCategory] → `assets/badges/` 하위 폴더명.
/// 2026-08-26 기준 남은 14종(permanent 11 + 시즌 3) 전부 아트가 있다.
String badgeCategoryAssetFolder(BadgeCategory category) => switch (category) {
      BadgeCategory.cumulativeDistance => 'distance',
      BadgeCategory.cumulativeCount => 'count',
      BadgeCategory.longestStreak => 'strict',
      BadgeCategory.personalBest => 'PB',
      BadgeCategory.singleSessionDistance => 'session',
      BadgeCategory.timeOfDayWeekday => 'date',
      BadgeCategory.routeExploration => 'route',
      BadgeCategory.specialDay => 'special',
      BadgeCategory.paceSpeed => 'speed',
      BadgeCategory.deviceIntegration => 'wearable',
      BadgeCategory.level => 'level',
      BadgeCategory.seasonTier => 'tier',
      BadgeCategory.seasonWeeklyRank => 'ranking',
      BadgeCategory.seasonEvent => 'event',
    };

/// 파일명은 `Badge.badgeGrade`와 동일한 6종(bronze/silver/gold/platinum/diamond/
/// special)이라 그대로 쓴다. `badgeGrade`는 String이라(카탈로그 운영 중 등급이 늘
/// 수 있음) 모르는 값이 오면 bronze로 폴백해 **존재하지 않는 파일을 참조하지
/// 않게** 한다 — 공유 카드에서 이게 터지면 캡처 자체가 실패한다.
String badgeGradeAssetName(String badgeGrade) => const {
      'bronze', 'silver', 'gold', 'platinum', 'diamond', 'special',
    }.contains(badgeGrade)
        ? badgeGrade
        : 'bronze';

/// 뱃지 메달 SVG의 전체 asset 경로.
String badgeAssetPath({
  required BadgeCategory category,
  required String badgeGrade,
}) =>
    'assets/badges/${badgeCategoryAssetFolder(category)}'
    '/${badgeGradeAssetName(badgeGrade)}.svg';
