/// 공유 카드 4종의 **실제 그림**. [ShareCardSurface]의 `child`로 들어간다.
///
/// ## 2026-08-26 재설계 — 세로 9:16 투명 오버레이 스티커
/// 사용자가 준 정확한 레퍼런스 이미지(396×704 = 9:16, 투명 배경 + 흰색 콘텐츠)를
/// 그대로 따른다: 위에서 아래로 **워드마크 → 촬영 시각 → 경로/엠블럼 → 수치
/// 스택** 한 줄기 중앙 정렬 컬럼이다. 좌우로 나눠 쓰던 가로 밴드 레이아웃은
/// 폐기했다 — 카드는 다시 세로다.
///
/// 1. **배경이 없다.** 어떤 위젯도 불투명 배경을 칠하지 않는다(칠하는 순간
///    알파가 사라져 스티커가 아니라 사진을 덮는 판때기가 된다).
/// 2. **그림자/halo가 없다.** 레퍼런스 이미지가 순수한 흰 선·글자였고,
///    사용자가 명시적으로 그림자를 걷어내라고 했다(2026-08-26). 밝은 사진
///    위 대비를 카드가 대신 책임지지 않는다.
/// 3. **세로가 빡빡한 축이다.** 카드 **높이**(`s`)를 기준 단위로 삼는다 —
///    9:16에서 요소가 조금만 커져도 세로 예산을 넘기기 쉽다.
///
/// ## 이 파일이 지키는 계약 (아키텍처 문서 §5.1)
/// 1. `MediaQuery`·`Theme`·다크모드를 **읽지 않는다.** 카드는 1080×1920으로
///    구워지는 고정 규격 인쇄물이다.
/// 2. 폰트를 앰비언트 테마에 맡기지 않는다. 수치·라벨·워드마크는
///    `Orbitron`(사용자 지정 디스플레이 서체), 한글은 `Pretendard Variable`로
///    폴백한다 — Orbitron에는 한글 글리프가 없어 폴백을 명시하지 않으면 기기
///    기본 글꼴이 튀어나온다.
/// 3. 네트워크 이미지(`athlete.avatarUrl`)를 그리지 않는다. 캡처는 프레임
///    하나만 기다리는데 네트워크 이미지는 그 안에 도착한다는 보장이 없다.
///
/// ## 레퍼런스와의 의도적 차이
/// - 레퍼런스는 러닝 기록 카드([RunRecapCardData]) 한 장이었고, 그 카드는
///   러너 신원(이름/티어)을 아예 보여주지 않는다 — 그대로 따랐다.
/// - 성취 카드(티어/뱃지/PB) 3종은 레퍼런스에 없었다. 같은 시각 언어(워드마크
///   → 시각 → 아트 → 수치 스택)를 쓰되, "무엇을 달성했는가"를 말해야 하므로
///   아트 아래에 헤드라인/서브헤드를 추가했다.
///
/// ## 경로(route)를 어디에 그리는가
/// **기록 카드에서만** 그린다. 성취 카드에 경로를 얹으면 임의의 사진 위에서
/// "안 보이거나(밝은 사진) 지저분한 낙서로 보이거나" 둘 중 하나가 된다.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../models/enums.dart';
import '../../domain/share_card_data.dart';

// ════════════════════════ 타이포 · 가독성 토큰 ════════════════════════

/// 수치·라벨·워드마크용 디스플레이 서체(사용자 지정). 가변 폰트라 굵기는
/// `TextStyle.fontWeight`가 축으로 매핑된다.
const String shareCardDisplayFont = 'Orbitron';

/// Orbitron에는 한글 글리프가 없다. 폴백을 명시하지 않으면 한글만 기기 기본
/// 글꼴로 찍혀 카드가 두 얼굴이 된다.
const List<String> shareCardFontFallback = ['Pretendard Variable'];

/// 카드 안 모든 텍스트가 이 함수를 통과한다 — 서체·폴백을 한 곳에서
/// 보장하기 위해서다(사용자 지정 Orbitron + 한글 폴백).
///
/// 2026-08-26: 그림자/halo를 걷어냈다(사용자 요청) — 레퍼런스 이미지 자체가
/// 그림자 없는 순수한 흰 선·글자였다. 밝은 사진 위 대비는 이 카드의 관심사가
/// 아니다 — 사용자가 어떤 사진에 얹을지 미리 알 수 없고, 대비를 강제로
/// 만들면 레퍼런스와 다른 그림이 된다.
TextStyle shareCardTextStyle({
  required double size,
  required FontWeight weight,
  Color color = Colors.white,
  double height = 1.0,
  double letterSpacing = 0,
}) =>
    TextStyle(
      fontFamily: shareCardDisplayFont,
      fontFamilyFallback: shareCardFontFallback,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
      decoration: TextDecoration.none,
    );

// ════════════════════════ 카드 본문 ════════════════════════

/// 카드 본문. 4종 분기가 **여기 한 곳**에만 있다.
///
/// 세로 컬럼 하나: 워드마크 → 시각 → (여백) → 아트 → (여백) →
/// [성취 카드만] 헤드라인/서브헤드 → 수치 스택. 카드 종류에 따라 아트·글자
/// 크기 예산이 달라 [isRecap] 분기로 두 세트의 치수를 쓴다 — 기록 카드는
/// 러너 신원·헤드라인이 없어 여유가 더 크고, 성취 카드는 헤드라인이 들어가는
/// 만큼 아트/수치를 보수적으로 잡는다. 둘 다 `Spacer`로 남는 세로 공간을
/// 흡수하므로, 실제 합이 예산보다 작아도(경로 없음, 뱃지처럼 수치 0개 등)
/// 레이아웃이 어색하게 뜨지 않는다.
class ShareCardBody extends StatelessWidget {
  const ShareCardBody({required this.card, super.key});

  final ShareCardData card;

  @override
  Widget build(BuildContext context) {
    final accent = shareCardAccent(card);
    final stats = _statsOf(card);
    final isRecap = card is RunRecapCardData;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 9:16에서 빡빡한 축은 세로다 — 카드 높이를 기준 단위로 잡아야
        // 미리보기든 1080×1920 출력이든 같은 비율이 나온다.
        final s = constraints.maxHeight;

        final heroWidth = s * (isRecap ? 0.34 : 0.30);
        final heroHeight = s * (isRecap ? 0.20 : 0.24);
        final statLabelSize = s * (isRecap ? 0.024 : 0.019);
        final statValueSize = s * (isRecap ? 0.074 : 0.052);

        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: s * 0.06,
            vertical: s * 0.058,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                'Runnit',
                textAlign: TextAlign.center,
                maxLines: 1,
                style: shareCardTextStyle(
                  size: s * 0.082,
                  weight: FontWeight.w500,
                  letterSpacing: s * 0.002,
                ),
              ),
              SizedBox(height: s * 0.016),
              Text(
                formatShareDateTime(card.achievedAt),
                textAlign: TextAlign.center,
                maxLines: 1,
                style: shareCardTextStyle(
                  size: s * 0.026,
                  weight: FontWeight.w400,
                  color: Colors.white.withValues(alpha: 0.75),
                  letterSpacing: s * 0.001,
                ),
              ),
              const Spacer(flex: 2),
              SizedBox(
                width: heroWidth,
                height: heroHeight,
                child: _HeroArt(card: card, accent: accent),
              ),
              const Spacer(flex: 1),
              // 헤드라인은 성취 카드(티어/뱃지/PB)에만 있다 — 기록 카드는
              // "무엇을 달성했는가"를 주장하지 않고 수치가 바로 그 답이다.
              if (!isRecap) ...[
                Text(
                  card.headline,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: shareCardTextStyle(
                    size: s * 0.038,
                    weight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
                if (card.subhead != null) ...[
                  SizedBox(height: s * 0.01),
                  Text(
                    card.subhead!,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: shareCardTextStyle(
                      size: s * 0.022,
                      weight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.82),
                    ),
                  ),
                ],
                SizedBox(height: s * 0.028),
              ],
              if (stats.isNotEmpty)
                _StatStack(
                  stats: stats,
                  s: s,
                  labelSize: statLabelSize,
                  valueSize: statValueSize,
                ),
            ],
          ),
        );
      },
    );
  }

  static List<_Stat> _statsOf(ShareCardData card) => switch (card) {
        final TierPromotionCardData c => _tierStats(c),
        BadgeEarnedCardData() => const <_Stat>[],
        final PersonalBestCardData c => _pbStats(c),
        final RunRecapCardData c => _recapStats(c),
      };

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

  /// 기록 카드: Distance · (있으면) Pace · Time — **레퍼런스 그대로 영문
  /// 라벨**이다. 다른 3종의 라벨이 한글인 것과 다르지만, 사용자가 지정한
  /// 정확한 레퍼런스가 이 카드에 한정돼 있어 그대로 옮겼다.
  static List<_Stat> _recapStats(RunRecapCardData card) {
    final pace = _paceColonLabel(card);
    return [
      _Stat(label: 'Distance', value: card.distanceLabel),
      if (pace != null) _Stat(label: 'Pace', value: '$pace /km'),
      _Stat(label: 'Time', value: card.timeLabel),
    ];
  }

  /// `4:10` 형식(콜론). 도메인의 [RunRecapCardData.paceLabel]은 `4'10"` 형식
  /// (다른 카드·공유 캡션과의 표기 통일이 목적)이라, 레퍼런스가 요구하는
  /// 콜론 표기는 이 위젯 계층에서 별도로 만든다. **null 판정 로직은 도메인과
  /// 동일하게 유지**해야 "거리 0이면 페이스 칸이 빠진다" 같은 계약이
  /// 어긋나지 않는다.
  static String? _paceColonLabel(RunRecapCardData card) {
    final seconds = card.avgPaceSecPerKm ??
        (card.distanceMeters > 0 && card.movingSeconds > 0
            ? card.movingSeconds / (card.distanceMeters / 1000)
            : null);
    if (seconds == null || seconds <= 0 || !seconds.isFinite) return null;
    final total = seconds.round();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }
}

class _Stat {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;
}

/// 수치 블록을 **세로로** 쌓는다 — 레퍼런스가 Distance/Pace/Time을 한 줄에
/// 나열하지 않고 각각 자기 줄을 갖는 것과 같다. 가로 밴드 시절의 좌우 나열
/// (`_StatRow`)은 폐기했다.
class _StatStack extends StatelessWidget {
  const _StatStack({
    required this.stats,
    required this.s,
    required this.labelSize,
    required this.valueSize,
  });

  final List<_Stat> stats;
  final double s;
  final double labelSize;
  final double valueSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0) SizedBox(height: s * 0.03),
          _StatBlock(stat: stats[i], labelSize: labelSize, valueSize: valueSize),
        ],
      ],
    );
  }
}

class _StatBlock extends StatelessWidget {
  const _StatBlock({
    required this.stat,
    required this.labelSize,
    required this.valueSize,
  });

  final _Stat stat;
  final double labelSize;
  final double valueSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          stat.label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: shareCardTextStyle(
            size: labelSize,
            weight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.75),
            letterSpacing: labelSize * 0.03,
          ),
        ),
        SizedBox(height: labelSize * 0.28),
        Text(
          stat.value,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: shareCardTextStyle(size: valueSize, weight: FontWeight.w700),
        ),
      ],
    );
  }
}

// ════════════════════════ 아트 ════════════════════════

/// 성취 카드(티어/뱃지/PB)의 아트 또는 기록 카드의 경로를 고른다.
class _HeroArt extends StatelessWidget {
  const _HeroArt({required this.card, required this.accent});

  final ShareCardData card;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    // sealed union이라 4종이 빠짐없이 다뤄진다 — 카드가 늘면 컴파일 에러가 난다.
    return switch (card) {
      final TierPromotionCardData c => ShareCardEmblem(
          assetPath: tierEmblemAssetPath(c.tier),
          size: double.infinity,
          accent: accent,
          scrim: true,
        ),
      final BadgeEarnedCardData c => ShareCardEmblem(
          assetPath: c.badgeAssetPath,
          size: double.infinity,
          accent: accent,
          scrim: true,
        ),
      final PersonalBestCardData c => ShareCardEmblem(
          assetPath: c.badgeAssetPath,
          size: double.infinity,
          accent: accent,
          scrim: true,
        ),
      // 기록 카드에는 메달이 없다 — 경로 그림이 그 자리를 대신한다.
      final RunRecapCardData c => _RouteHero(route: c.route, accent: accent),
    };
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
    this.scrim = false,
    super.key,
  });

  final String assetPath;

  /// `double.infinity`를 주면 부모가 준 상자를 채운다(공유 카드가 그렇게 쓴다).
  final double size;
  final Color accent;

  /// 임의의 사진 위에 얹히는 공유 카드용. 메달 뒤에 **어두운** 원을 깔아
  /// 밝은 사진 위에서도 메달의 실루엣이 살아 있게 한다. 앱 안 축하 연출은
  /// 이미 어두운 배경 위라 필요 없다(기본값 false).
  final bool scrim;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final d = math.min(constraints.maxWidth, constraints.maxHeight);

          return Stack(
            alignment: Alignment.center,
            children: [
              if (scrim)
                Container(
                  width: d,
                  height: d,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [Color(0x73000000), Color(0x00000000)],
                      stops: [0.55, 1],
                    ),
                  ),
                ),
              // 메달 뒤 광채 — 메달이 바탕에서 떠 보이게 한다.
              Container(
                width: d,
                height: d,
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
              SvgPicture.asset(assetPath, width: d * 0.78),
            ],
          );
        },
      ),
    );
  }
}

/// 기록 카드의 주인공 — 경로 그림.
///
/// 경로가 없으면(실내 러닝·좌표 없는 기록) 그림 대신 활동 아이콘을 놓는다.
/// **빈 사각형을 남기지 않는다** — 아트 칸이 비면 카드 가운데가 뜯겨 보인다.
///
/// 레퍼런스의 선은 **순백**이고 시작/끝 점 마커가 없는 단순한 선이다 —
/// 이전(가로 밴드) 디자인의 티어색 선 + 시작/끝 원 마커를 걷어냈다.
class _RouteHero extends StatelessWidget {
  const _RouteHero({required this.route, required this.accent});

  final ShareRoute? route;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final drawable = route;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final minSide = math.min(w, h);

        if (drawable == null || !drawable.isDrawable) {
          return Center(
            child: Icon(
              Icons.directions_run_rounded,
              size: minSide * 0.85,
              color: Colors.white,
            ),
          );
        }

        return CustomPaint(
          size: Size(w, h),
          painter: ShareRoutePainter(
            route: drawable,
            color: Colors.white,
            strokeWidth: minSide * 0.045,
            showEndpoints: false,
          ),
        );
      },
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
    this.haloColor,
  });

  final ShareRoute route;
  final Color color;
  final double strokeWidth;

  /// 시작/끝 점을 찍을지.
  final bool showEndpoints;

  /// 경로 아래에 먼저 깔리는 굵은 어두운 획. 투명 배경 카드에서 임의의
  /// 사진 위 대비를 만드는 유일한 수단이라 **공유 카드에서는 반드시 준다.**
  /// null이면 halo 없이 선만 그린다.
  final Color? haloColor;

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

    // halo가 선보다 굵으므로 여백도 halo 기준으로 잡는다 — 아니면 경로가
    // 상자 밖으로 삐져나간다.
    final inset = strokeWidth * (haloColor == null ? 1.6 : 2.4);
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

    final halo = haloColor;
    if (halo != null) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = halo
          ..strokeWidth = strokeWidth * 2.1
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, strokeWidth * 0.5),
      );
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
      oldDelegate.showEndpoints != showEndpoints ||
      oldDelegate.haloColor != haloColor;
}

// ════════════════════════ 공용 헬퍼 ════════════════════════

/// 카드 성격에 맞는 강조색. 티어 카드는 그 티어 색, 뱃지/PB는 등급 색,
/// 기록 카드는 러너의 현재 티어 색을 쓴다(그 사람의 카드라는 신호). 카드
/// 본문에서는 더 이상 브랜드 라인·러너 이름 색으로 쓰이지 않지만, 메달 뒤
/// 광채(`ShareCardEmblem`)와 축하 연출(`achievement_celebration.dart`)이
/// 여전히 이 값을 쓴다.
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

/// 카드에 찍히는 날짜+시각. 서버 시각은 UTC로 오므로 **KST로 옮겨** 표기한다
/// — 밤 러닝이 하루 전날로 찍히는 일을 막는다(PRD의 주간 경계도 KST 기준).
/// 레퍼런스가 `2026.08.26  19:34`처럼 시각까지 보여줘서, 날짜만 찍던 이전
/// `formatShareDate`를 대체한다.
String formatShareDateTime(DateTime utc) {
  final kst = utc.toUtc().add(const Duration(hours: 9));
  final mo = kst.month.toString().padLeft(2, '0');
  final d = kst.day.toString().padLeft(2, '0');
  final h = kst.hour.toString().padLeft(2, '0');
  final mi = kst.minute.toString().padLeft(2, '0');
  return '${kst.year}.$mo.$d  $h:$mi';
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
