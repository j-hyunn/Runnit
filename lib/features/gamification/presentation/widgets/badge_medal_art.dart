// Material의 `Badge` 위젯과 도메인 모델 `Badge`가 이름 충돌하므로 위젯 쪽을 숨긴다.
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../models/models.dart';
import '../../domain/badge_assets.dart';

/// 뱃지 메달 **한 장**을 그리는 최소 단위 위젯.
///
/// ## 왜 갤러리에서 뽑아냈나
/// 원래 이 렌더링은 `badge_gallery_page.dart`의 private `_BadgeMedal`이었고,
/// 입력이 `BadgeProgress`(카탈로그 + 진행률 + 획득 여부)였다. AC-03 타인 프로필이
/// 두 번째 소비자가 되면서 그 입력을 쓸 수 없게 됐다 — 타인의 진행률은 만들
/// 근거 데이터(`GamificationStats`)가 없고, 애초에 **획득한 뱃지만** 보여준다.
///
/// 그래서 렌더링에 실제로 필요한 최소 입력([Badge]의 카테고리·등급 + 획득 여부)만
/// 받는 공개 위젯으로 내리고, 갤러리의 `_BadgeMedal`은 `BadgeProgress`를 이 값들로
/// 풀어 이 위젯에 넘긴다. 아트 경로 규칙이 `domain/badge_assets.dart` 한 곳에
/// 모여 있는 것과 같은 이유다 — 갤러리에서 본 메달과 타인 프로필의 메달이
/// 갈라지면 그건 버그다.
class BadgeMedalArt extends StatelessWidget {
  const BadgeMedalArt({
    super.key,
    required this.category,
    required this.badgeGrade,
    required this.size,
    this.earned = false,
    this.dimmed = false,
  });

  final BadgeCategory category;

  /// [Badge.badgeGrade] — String이다(카탈로그 운영 중 등급이 늘 수 있음).
  final String badgeGrade;

  final double size;

  /// true면 등장 애니메이션 + 획득 체크 배지를 얹는다.
  final bool earned;

  /// true면 투명도를 낮춰 "아직 아님"을 표현한다. 흑백으로 죽이지 않는 이유는
  /// 등급 색이 옅게라도 보여야 갤러리에서 등급을 가늠할 수 있기 때문이다.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final art = SvgPicture.asset(
      badgeAssetPath(category: category, badgeGrade: badgeGrade),
      // 원본 뷰박스가 40×44(세로로 긴 방패) — 폭을 size에 맞추고 비율은 그대로 둔다.
      width: size,
    );

    final medal = SizedBox(
      width: size,
      height: size,
      child: Center(child: dimmed ? Opacity(opacity: 0.35, child: art) : art),
    );

    if (!earned) return medal;

    // 획득 뱃지는 살짝 튀어오르는 등장 연출 + 체크 배지로 성취를 강조한다.
    return Stack(
      alignment: Alignment.center,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.85, end: 1),
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutBack,
          builder: (_, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: medal,
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration:
                BoxDecoration(shape: BoxShape.circle, color: scheme.surface),
            child: Icon(
              Icons.check_circle,
              size: size * 0.24,
              color: badgeCheckColor(badgeGrade),
            ),
          ),
        ),
      ],
    );
  }
}

/// 획득 체크 배지 색상. 사용자 요청으로 platinum↔diamond만 서로 맞바꿔
/// 쓴다(2026-08-25) — 나머지 등급은 [badgeGradeColor]와 동일.
Color badgeCheckColor(String badgeGrade) => switch (badgeGrade) {
      'platinum' => AppTokens.tierDiamond,
      'diamond' => AppTokens.tierPlatinum,
      _ => badgeGradeColor(badgeGrade),
    };

/// `Badge.badgeGrade`는 String(카탈로그 운영 중 등급이 늘 수 있음 — `badge.dart`
/// doc 참고)이라 모르는 값이 오면 outline 색으로 안전하게 폴백한다.
Color badgeGradeColor(String badgeGrade) => switch (badgeGrade) {
      'bronze' => AppTokens.tierBronze,
      'silver' => AppTokens.tierSilver,
      'gold' => AppTokens.tierGold,
      'platinum' => AppTokens.tierPlatinum,
      'diamond' => AppTokens.tierDiamond,
      'special' => AppTokens.tierSpecial,
      _ => const Color(0xFF9B9B9B),
    };

String badgeGradeLabel(String badgeGrade) => switch (badgeGrade) {
      'bronze' => '브론즈',
      'silver' => '실버',
      'gold' => '골드',
      'platinum' => '플래티넘',
      'diamond' => '다이아몬드',
      'special' => '스페셜',
      _ => badgeGrade,
    };
