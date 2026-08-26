/// 공유 카드 4종의 **실제 그림**. [ShareCardSurface]의 `child`로 들어간다.
///
/// ## 이 파일이 지키는 계약 (아키텍처 문서 §5.1)
/// 1. `MediaQuery`·`Theme`·다크모드를 **읽지 않는다.** 카드는 1080×1920으로
///    구워지는 고정 규격 인쇄물이고, 스토리에 올라간 뒤에는 보는 사람의 테마와
///    무관하다. 모든 치수는 [LayoutBuilder]가 준 카드 폭(`w`) 대비 비율이다.
/// 2. 폰트도 앰비언트 테마에 맡기지 않고 `Pretendard Variable`을 명시한다 —
///    카드를 띄우는 화면의 `DefaultTextStyle`이 무엇이든 결과가 같아야 한다.
/// 3. 네트워크 이미지(`athlete.avatarUrl`)를 그리지 않는다. 캡처는 프레임 하나만
///    기다리는데 네트워크 이미지는 그 안에 도착한다는 보장이 없어, 아바타가 빈
///    사각형으로 구워질 수 있다. 대신 이니셜 원을 그린다.
///
/// ## 레이아웃 원칙
/// 세로 9:16은 **위/가운데/아래 3단**으로 읽힌다: 브랜드 → 성취 → 러너.
/// 가운데 성취 영역만 카드 종류에 따라 달라지고, 위아래는 4종이 공유한다.
/// 가운데 영역의 요소(메달·헤드라인·부제·수치 타일)는 **전부 없을 수 있으므로**
/// 각각 null 검사 후 리스트에 넣는다 — 빈 자리가 생겨도 [Spacer]가 흡수한다.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../models/enums.dart';
import '../../domain/share_card_data.dart';

/// 카드 본문. 4종 분기가 **여기 한 곳**에만 있다.
class ShareCardBody extends StatelessWidget {
  const ShareCardBody({required this.card, super.key});

  final ShareCardData card;

  @override
  Widget build(BuildContext context) {
    final accent = shareCardAccent(card);

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;

        return DefaultTextStyle(
          style: TextStyle(
            fontFamily: 'Pretendard Variable',
            color: Colors.white,
            fontSize: w * 0.045,
            height: 1.25,
            // 카드는 어떤 화면 위에 있어도 같은 글씨여야 한다.
            decoration: TextDecoration.none,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _Backdrop(accent: accent),
              // 성취 카드에서 경로는 **배경 워터마크**다. 주인공은 메달과 문구고,
              // 경로는 "어디를 뛰어서 얻었는지"를 흐리게 덧붙인다.
              if (card.kind != ShareCardKind.runRecap && card.route != null)
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.16,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: w * 0.1),
                      child: CustomPaint(
                        painter: ShareRoutePainter(
                          route: card.route!,
                          color: Colors.white,
                          strokeWidth: w * 0.012,
                          showEndpoints: false,
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  w * 0.085,
                  w * 0.09,
                  w * 0.085,
                  w * 0.085,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _BrandRow(w: w, accent: accent, achievedAt: card.achievedAt),
                    const Spacer(),
                    _CardCenter(card: card, w: w, accent: accent),
                    const Spacer(),
                    _AthleteFooter(card: card, w: w, accent: accent),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ════════════════════════ 공통 3단 ════════════════════════

/// 카드 바탕. 위쪽에서 강조색이 번지고 아래로 갈수록 잠긴다 — 아래 절반에
/// 흰 글씨(러너 정보)가 앉으므로 그쪽 대비를 확보해야 한다.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(accent.withValues(alpha: 0.30), _cardBase),
            Color.alphaBlend(accent.withValues(alpha: 0.10), _cardBase),
            _cardBase,
          ],
          stops: const [0, 0.45, 1],
        ),
      ),
    );
  }
}

class _BrandRow extends StatelessWidget {
  const _BrandRow({
    required this.w,
    required this.accent,
    required this.achievedAt,
  });

  final double w;
  final Color accent;
  final DateTime achievedAt;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'RUNNIT',
          style: TextStyle(
            color: accent,
            fontSize: w * 0.048,
            fontWeight: FontWeight.w800,
            letterSpacing: w * 0.012,
          ),
        ),
        Text(
          formatShareDate(achievedAt),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: w * 0.038,
            fontWeight: FontWeight.w500,
            letterSpacing: w * 0.002,
          ),
        ),
      ],
    );
  }
}

/// 하단 러너 신원 — **브랜드 마크와 함께 4종 공통**이다. 무료 광고 1회가
/// 이 카드의 목적이므로(BRD §5.2) 이름과 브랜드는 어떤 카드에서도 빠지지 않는다.
class _AthleteFooter extends StatelessWidget {
  const _AthleteFooter({
    required this.card,
    required this.w,
    required this.accent,
  });

  final ShareCardData card;
  final double w;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final athlete = card.athlete;
    final initial = _initialOf(athlete.displayName);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: w * 0.003, color: Colors.white.withValues(alpha: 0.16)),
        SizedBox(height: w * 0.05),
        Row(
          children: [
            Container(
              width: w * 0.12,
              height: w * 0.12,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.22),
                border: Border.all(
                  color: accent.withValues(alpha: 0.6),
                  width: w * 0.004,
                ),
              ),
              child: Text(
                initial,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: w * 0.055,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SizedBox(width: w * 0.035),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    athlete.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: w * 0.046,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: w * 0.008),
                  Text(
                    'Lv.${athlete.level} · ${tierLabel(athlete.tier)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: w * 0.036,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: w * 0.03),
            _BrandMark(w: w, accent: accent),
          ],
        ),
      ],
    );
  }

  static String _initialOf(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? 'R' : trimmed.characters.first.toUpperCase();
  }
}

/// 오른쪽 아래 브랜드 마크. 캡처된 이미지가 어디로 퍼지든 출처가 남아야 한다.
class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.w, required this.accent});

  final double w;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: w * 0.035, vertical: w * 0.018),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(w * 0.1),
        border: Border.all(color: accent.withValues(alpha: 0.45), width: w * 0.003),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: w * 0.022,
            height: w * 0.022,
            decoration: BoxDecoration(shape: BoxShape.circle, color: accent),
          ),
          SizedBox(width: w * 0.018),
          Text(
            'Runnit',
            style: TextStyle(
              color: Colors.white,
              fontSize: w * 0.034,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════ 가운데 — 카드별 ════════════════════════

class _CardCenter extends StatelessWidget {
  const _CardCenter({
    required this.card,
    required this.w,
    required this.accent,
  });

  final ShareCardData card;
  final double w;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    // sealed union이라 4종이 빠짐없이 다뤄진다 — 카드가 늘면 컴파일 에러가 난다.
    final (Widget emblem, List<_Stat> stats) = switch (card) {
      final TierPromotionCardData c => (
          ShareCardEmblem(
            assetPath: tierEmblemAssetPath(c.tier),
            size: w * 0.42,
            accent: accent,
          ),
          _tierStats(c),
        ),
      final BadgeEarnedCardData c => (
          ShareCardEmblem(
            assetPath: c.badgeAssetPath,
            size: w * 0.42,
            accent: accent,
          ),
          const <_Stat>[],
        ),
      final PersonalBestCardData c => (
          ShareCardEmblem(
            assetPath: c.badgeAssetPath,
            size: w * 0.42,
            accent: accent,
          ),
          _pbStats(c),
        ),
      // 기록 카드에는 메달이 없다 — 경로 그림이 그 자리를 대신한다.
      final RunRecapCardData c => (
          _RouteHero(route: c.route, w: w, accent: accent),
          _recapStats(c),
        ),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        emblem,
        SizedBox(height: w * 0.06),
        Text(
          card.headline,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: w * 0.105,
            height: 1.15,
            fontWeight: FontWeight.w800,
            letterSpacing: -w * 0.002,
          ),
        ),
        if (card.subhead != null) ...[
          SizedBox(height: w * 0.028),
          Text(
            card.subhead!,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: w * 0.046,
              height: 1.35,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        // 타일이 하나도 없으면 행 자체를 그리지 않는다 — 빈 구분선만 남는
        // 카드(예: 시간 없는 PB, 경로 없는 실내 러닝)를 만들지 않기 위해서다.
        if (stats.isNotEmpty) ...[
          SizedBox(height: w * 0.07),
          _StatRow(stats: stats, w: w, accent: accent),
        ],
      ],
    );
  }

  /// 티어 카드: 시즌 · 시즌 누적 거리 · (있으면) 상위 %.
  ///
  /// **`rank`가 아니라 `topPercent`를 쓴다** — PRD §5.4.1의 "소수 정예 노출"
  /// 원칙. 참가자 수를 모르면 `topPercent`가 null이고 그 칸은 통째로 빠진다.
  static List<_Stat> _tierStats(TierPromotionCardData card) {
    final top = card.topPercent;
    final seasonDistance = card.seasonDistanceMeters;
    return [
      _Stat(label: '시즌', value: card.seasonId),
      // 지난 시즌 승급을 다시 공유하면 null이다 — 다른 시즌의 거리를 보여주지
      // 않고 칸을 통째로 뺀다(QA O-3).
      if (seasonDistance != null)
        _Stat(
          label: '시즌 누적',
          value: '${(seasonDistance / 1000).toStringAsFixed(1)}km',
        ),
      if (top != null) _Stat(label: '티어 내', value: '상위 $top%'),
    ];
  }

  /// PB 카드: 기록 · (있으면) 그 PB가 나온 러닝 거리.
  ///
  /// ⚠️ `timeLabel`은 **null일 수 있다**(서버 보간값이 저장되지 않는 구간 —
  /// `PersonalBestCardData.certifiedSeconds` 문서). 그때는 시간 칸이 빠지고
  /// 거리 칸만 남는다. 절대 클라이언트가 시간을 지어내지 않는다.
  static List<_Stat> _pbStats(PersonalBestCardData card) {
    final time = card.timeLabel;
    final runDistance = card.runDistanceMeters;
    return [
      _Stat(label: '종목', value: card.distanceLabel),
      if (time != null) _Stat(label: '기록', value: time),
      if (runDistance != null)
        _Stat(
          label: '이 러닝',
          value: '${(runDistance / 1000).toStringAsFixed(2)}km',
        ),
    ];
  }

  /// 기록 카드: 시간 · 페이스 · (있으면) 칼로리.
  static List<_Stat> _recapStats(RunRecapCardData card) {
    final pace = card.paceLabel;
    final kcal = card.caloriesKcal;
    return [
      _Stat(label: '시간', value: card.timeLabel),
      if (pace != null) _Stat(label: '페이스', value: pace),
      if (kcal != null) _Stat(label: '칼로리', value: '$kcal'),
    ];
  }
}

/// 메달/엠블럼 SVG 한 장 + 뒤에 깔리는 광채.
///
/// 카드와 **축하 연출**(`achievement_celebration.dart`)이 같은 위젯을 쓴다 —
/// 화면에서 본 메달과 공유된 이미지의 메달이 달라지면 그건 버그다.
///
/// SVG는 비동기로 로드되므로 **캡처 전에 미리 데워 둬야 한다**
/// ([precacheShareCardArt]). 로드 전에 캡처하면 메달 없는 카드가 구워진다.
class ShareCardEmblem extends StatelessWidget {
  const ShareCardEmblem({
    required this.assetPath,
    required this.size,
    required this.accent,
    super.key,
  });

  final String assetPath;
  final double size;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 메달 뒤 광채 — 어두운 배경에서 메달이 떠 보이게 한다.
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  accent.withValues(alpha: 0.38),
                  accent.withValues(alpha: 0),
                ],
              ),
            ),
          ),
          SvgPicture.asset(assetPath, width: size * 0.78),
        ],
      ),
    );
  }
}

/// 기록 카드의 주인공 — 경로 그림.
///
/// 경로가 없으면(실내 러닝·좌표 없는 기록) 그림 대신 활동 아이콘을 놓는다.
/// **빈 사각형을 남기지 않는다** — 카드 가운데가 비면 완성도가 무너져 보인다.
class _RouteHero extends StatelessWidget {
  const _RouteHero({required this.route, required this.w, required this.accent});

  final ShareRoute? route;
  final double w;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final size = w * 0.6;
    final drawable = route;

    if (drawable == null || !drawable.isDrawable) {
      return SizedBox(
        width: size,
        height: size * 0.6,
        child: Center(
          child: Icon(
            Icons.directions_run_rounded,
            size: w * 0.28,
            color: accent.withValues(alpha: 0.85),
          ),
        ),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: ShareRoutePainter(
          route: drawable,
          color: accent,
          strokeWidth: w * 0.016,
        ),
      ),
    );
  }
}

// ════════════════════════ 수치 타일 ════════════════════════

class _Stat {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.stats, required this.w, required this.accent});

  final List<_Stat> stats;
  final double w;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0)
            Container(
              width: w * 0.003,
              height: w * 0.09,
              margin: EdgeInsets.symmetric(horizontal: w * 0.045),
              color: Colors.white.withValues(alpha: 0.18),
            ),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  stats[i].value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: w * 0.058,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: w * 0.012),
                Text(
                  stats[i].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent.withValues(alpha: 0.9),
                    fontSize: w * 0.032,
                    fontWeight: FontWeight.w600,
                    letterSpacing: w * 0.002,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ════════════════════════ 경로 페인터 ════════════════════════

/// 위경도 목록을 주어진 상자에 **비율을 유지한 채** 그린다.
///
/// 경도 1도의 실제 거리는 위도에 따라 줄어들므로(`cos(lat)`), 보정 없이 그리면
/// 고위도에서 경로가 가로로 늘어난 채 찍힌다 — 사용자가 아는 자기 코스 모양과
/// 달라 보인다. 카드 한 장짜리 그림이므로 정식 투영 대신 평균 위도 기준
/// 등장방형(equirectangular) 근사로 충분하다.
class ShareRoutePainter extends CustomPainter {
  const ShareRoutePainter({
    required this.route,
    required this.color,
    required this.strokeWidth,
    this.showEndpoints = true,
  });

  final ShareRoute route;
  final Color color;
  final double strokeWidth;

  /// 시작/끝 점을 찍을지. 배경 워터마크로 쓸 때는 끈다.
  final bool showEndpoints;

  @override
  void paint(Canvas canvas, Size size) {
    final points = route.points;
    if (points.length < 2 || size.isEmpty) return;

    var minLat = points.first.lat, maxLat = points.first.lat;
    var minLng = points.first.lng, maxLng = points.first.lng;
    for (final p in points) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLng = math.min(minLng, p.lng);
      maxLng = math.max(maxLng, p.lng);
    }

    final latScale = math.cos((minLat + maxLat) / 2 * math.pi / 180).abs();
    // 완전 직선 코스(트랙 왕복 등)는 한 축의 폭이 0이라 그대로 나누면 NaN이 된다.
    final spanX = math.max((maxLng - minLng) * latScale, 1e-9);
    final spanY = math.max(maxLat - minLat, 1e-9);

    final inset = strokeWidth * 1.6;
    final boxW = math.max(size.width - inset * 2, 1.0);
    final boxH = math.max(size.height - inset * 2, 1.0);
    final scale = math.min(boxW / spanX, boxH / spanY);

    final drawnW = spanX * scale;
    final drawnH = spanY * scale;
    final dx = inset + (boxW - drawnW) / 2;
    final dy = inset + (boxH - drawnH) / 2;

    Offset project(double lat, double lng) => Offset(
          dx + (lng - minLng) * latScale * scale,
          // 위도는 위로 갈수록 커지고 캔버스 y는 아래로 갈수록 커진다 — 뒤집는다.
          dy + drawnH - (lat - minLat) * scale,
        );

    final start = project(points.first.lat, points.first.lng);
    final path = Path()..moveTo(start.dx, start.dy);
    for (final p in points.skip(1)) {
      final o = project(p.lat, p.lng);
      path.lineTo(o.dx, o.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = color
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    if (!showEndpoints) return;
    // 시작(속 빈 원)과 끝(채운 원)을 구분해 찍는다 — 루프 코스인지 편도인지가
    // 그림만으로 읽힌다.
    final end = project(points.last.lat, points.last.lng);
    canvas.drawCircle(
      end,
      strokeWidth * 1.5,
      Paint()..color = color,
    );
    canvas.drawCircle(
      start,
      strokeWidth * 1.3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 0.8
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(ShareRoutePainter oldDelegate) =>
      oldDelegate.route != route ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.showEndpoints != showEndpoints;
}

// ════════════════════════ 공용 헬퍼 ════════════════════════

/// 카드 바탕색. 스토리 배경이 비쳐 글자가 안 보이는 사고를 막기 위해
/// [ShareCardSurface]가 깔아 두는 색과 같은 계열의 완전 불투명 색이다.
const Color _cardBase = Color(0xFF101216);

/// 카드 성격에 맞는 강조색. 티어 카드는 그 티어 색, 뱃지/PB는 등급 색,
/// 기록 카드는 러너의 현재 티어 색을 쓴다(그 사람의 카드라는 신호).
Color shareCardAccent(ShareCardData card) => switch (card) {
      TierPromotionCardData(:final tier) => tierAccentColor(tier),
      BadgeEarnedCardData(:final badge) => badgeGradeAccentColor(badge.badgeGrade),
      PersonalBestCardData() => AppTokens.tierGold,
      RunRecapCardData(:final athlete) => tierAccentColor(athlete.tier),
    };

Color tierAccentColor(Tier tier) => switch (tier) {
      Tier.bronze => AppTokens.tierBronze,
      Tier.silver => AppTokens.tierSilver,
      Tier.gold => AppTokens.tierGold,
      Tier.platinum => AppTokens.tierPlatinum,
    };

/// `Badge.badgeGrade`는 String이라(카탈로그 운영 중 등급이 늘 수 있음) 모르는
/// 값이 오면 실버로 폴백한다 — 카드에서 색이 빠지는 것보다 낫다.
Color badgeGradeAccentColor(String grade) => switch (grade) {
      'bronze' => AppTokens.tierBronze,
      'silver' => AppTokens.tierSilver,
      'gold' => AppTokens.tierGold,
      'platinum' => AppTokens.tierPlatinum,
      'diamond' => AppTokens.tierDiamond,
      'special' => AppTokens.tierSpecial,
      _ => AppTokens.tierSilver,
    };

/// 티어 엠블럼 SVG. 뱃지 갤러리의 시즌 티어 뱃지와 **같은 파일**을 쓴다
/// (`assets/badges/tier/{등급}.svg`) — 두 화면의 그림이 갈라지지 않게.
String tierEmblemAssetPath(Tier tier) => 'assets/badges/tier/${tier.name}.svg';

/// 카드에 찍히는 날짜. 서버 시각은 UTC로 오므로 **KST로 옮겨** 표기한다 —
/// 밤 러닝이 하루 전날로 찍히는 일을 막는다(PRD의 주간 경계도 KST 기준).
String formatShareDate(DateTime utc) {
  final kst = utc.toUtc().add(const Duration(hours: 9));
  final m = kst.month.toString().padLeft(2, '0');
  final d = kst.day.toString().padLeft(2, '0');
  return '${kst.year}.$m.$d';
}

/// 이 카드가 그리는 메달/엠블럼 자산. 기록 카드는 메달이 없어 null
/// (경로 그림은 [CustomPainter]라 로드할 자산이 없다).
String? shareCardEmblemAsset(ShareCardData card) => switch (card) {
      TierPromotionCardData(:final tier) => tierEmblemAssetPath(tier),
      BadgeEarnedCardData(:final badgeAssetPath) => badgeAssetPath,
      PersonalBestCardData(:final badgeAssetPath) => badgeAssetPath,
      RunRecapCardData() => null,
    };

/// 카드가 쓰는 SVG를 **캡처 전에** 디코드해 둔다.
///
/// [SvgPicture]는 비동기로 로드되는데 캡처는 프레임 하나만 기다린다. 데우지
/// 않고 구우면 메달 자리가 빈 카드가 인스타로 나간다 — 되돌릴 수 없는 종류의
/// 사고다. 실패해도 던지지 않는다(메달 없는 카드가 공유 실패보다는 낫다).
Future<void> precacheShareCardArt(ShareCardData card) async {
  final path = shareCardEmblemAsset(card);
  if (path == null) return;
  try {
    await SvgAssetLoader(path).loadBytes(null);
  } catch (_) {
    // 자산이 없거나 파싱에 실패해도 카드는 나머지를 그린다.
  }
}
