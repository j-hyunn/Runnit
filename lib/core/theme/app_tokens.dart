import 'package:flutter/material.dart';

/// 디자인 토큰 — spacing / radius / 브랜드·등급 색.
///
/// [AppTheme]은 `ColorScheme.fromSeed` 기반의 **테마**를 담당하고,
/// 이 파일은 테마로 표현되지 않는 **상수 토큰**을 담당한다.
/// 화면 코드에 매직 넘버(패딩 17, 반지름 13...)를 흩뿌리지 않기 위한 단일 출처다.
///
/// 문서: `_workspace/20260820_ui_design_tokens.md`
class AppTokens {
  const AppTokens._();

  // ── Spacing (4pt 그리드) ────────────────────────────────
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s40 = 40;

  // ── Radius ─────────────────────────────────────────────
  static const double rSm = 8;
  static const double rMd = 12;
  static const double rLg = 16;
  static const double rPill = 999;

  /// 폰 화면 폭이 넓어도(태블릿/폴더블) 본문이 과도하게 늘어나지 않도록 제한.
  static const double contentMaxWidth = 480;

  /// 터치 타겟 최소 높이(iOS HIG 44 / Material 48 중 큰 값).
  static const double minTapTarget = 48;

  // ── 카카오 브랜드 ───────────────────────────────────────
  /// 카카오 로그인 버튼 배경. 공식 가이드 색이므로 임의로 조정하지 않는다.
  static const Color kakaoYellow = Color(0xFFFEE500);

  /// 카카오 로그인 버튼 라벨/심볼 색.
  static const Color kakaoLabel = Color(0xFF191919);

  // ── 뱃지 등급 색 ────────────────────────────────────────
  // tierBronze: 2026-08-24 Figma Home 프레임(`55:1259`) 재확인 — 실제 지정값은
  // #A47300(황동/올리브 톤)이다. 이전 값(#B08D57, 메달 청동색 느낌)은 Figma
  // 확인 없이 임의로 골랐던 값이라 화면의 실제 배지 색과 미묘하게 달랐다.
  static const Color tierBronze = Color(0xFFA47300);
  static const Color tierSilver = Color(0xFF9AA5B1);
  static const Color tierGold = Color(0xFFE0B23C);
  static const Color tierPlatinum = Color(0xFF5BC8DE);

  /// `Badge.badgeGrade`(146종 카탈로그, 6단계) 전용 — 경쟁 `Tier`엔 없는 두 등급.
  /// Figma 확인 안 된 임시값 — 실제 디자인 확정 시 교체 필요.
  static const Color tierDiamond = Color(0xFF8E7CE0);
  static const Color tierSpecial = Color(0xFFE0648E);

  // ── 레벨/경험치 진행률 색 ──────────────────────────────
  /// 홈·프로필의 XP 진행률 바 색. 시즌 티어 진행률 바(#00F35A, 네온 그린)와
  /// 시각적으로 구분되도록 앰버로 잡았다 — 두 진행 축(시즌 리셋 vs 영구 누적)이
  /// 한 카드에 나란히 있을 때 사용자가 헷갈리지 않게 한다. Figma 미확정 임시값.
  static const Color levelXp = Color(0xFFFFB020);
}
