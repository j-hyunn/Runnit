import 'package:flutter/material.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../../../tracking/presentation/tracking_format.dart';
import '../../domain/lap_splits.dart';

/// HI-02 페이스 그래프 — 1km 구간별 페이스 막대.
///
/// **빠른 구간일수록 막대가 길다.** 페이스(s/km)는 값이 작을수록 빠르므로
/// 축을 뒤집는다. 러닝 앱 관례이며, 뒤집지 않으면 잘 뛴 구간이 가장 낮은
/// 막대로 나와 성취가 거꾸로 읽힌다.
///
/// ## fl_chart를 쓰지 않은 이유
/// pubspec의 fl_chart는 "페이스/고도/심박 **추이**"용이다. 이 그래프는
/// 추이(연속 시계열)가 아니라 랩 3~10개짜리 **범주형 막대**다.
/// - 축을 뒤집고 눈금을 `4'52"` 같은 페이스 문자열로 바꾸는 순간
///   fl_chart가 대신 해 주는 축·격자 로직을 대부분 `getTitlesWidget`으로
///   덮어쓰게 된다 — 남는 건 툴팁뿐인데, 값은 바로 옆 랩 테이블에 이미 있다.
/// - 같은 탭의 [MonthlyBarChart]가 이미 손그림 막대다. 여기만 fl_chart를
///   쓰면 한 화면 안에서 막대 굵기·모서리·라벨 톤이 서로 다르게 보인다.
///
/// fl_chart는 P1의 고도·심박 **연속** 추이 차트에서 값을 한다. 그때 도입한다.
class PaceChart extends StatelessWidget {
  const PaceChart({super.key, required this.splits});

  final List<LapSplit> splits;

  /// 완전 구간이 이 개수 미만이면 그래프를 그리지 않는다 — 막대 하나짜리
  /// 그래프는 비교 대상이 없어 아무것도 말해 주지 않는다(랩 테이블로 충분).
  static const int minBarsToRender = 2;

  static const double _barMaxHeight = 120;
  static const double _minBarWidth = 12;
  static const double _barGap = 6;

  static const Color _accent = Color(0xFF00C84B);
  static const Color _bar = Color(0xFF9BE3B6);
  static const Color _muted = Color(0xFFD6D6D6);
  static const TextStyle _labelStyle =
      TextStyle(fontSize: 12, color: Color(0xFF616161));

  /// 호출부가 섹션 제목을 그리기 전에 물어볼 수 있게 공개한다 — 제목만
  /// 남고 본문이 비는 빈 섹션을 막는다.
  static bool canRender(List<LapSplit> splits) =>
      splits.where((s) => !s.isPartial && s.paceSecPerKm > 0).length >=
      minBarsToRender;

  @override
  Widget build(BuildContext context) {
    final full =
        splits.where((s) => !s.isPartial && s.paceSecPerKm > 0).toList();
    if (full.length < minBarsToRender) return const SizedBox.shrink();

    final paces = full.map((s) => s.paceSecPerKm);
    final fastest = paces.reduce((a, b) => a < b ? a : b);
    final slowest = paces.reduce((a, b) => a > b ? a : b);
    // 전 구간이 1초 이내로 균일하면 정규화 분모가 0에 가까워져 막대 높이가
    // 노이즈에 요동친다. 그럴 땐 "차이 없음"을 뜻하는 균일 높이로 그린다.
    final flat = (slowest - fastest) < 1.0;
    final span = flat ? 1.0 : slowest - fastest;

    // 자투리 구간은 페이스가 튀어 스케일을 왜곡하므로 위 계산에서 제외했고,
    // 막대는 실제 페이스대로(범위 밖이면 잘라서) 옅게 그린다.
    final bars = [
      for (final s in splits)
        if (s.paceSecPerKm > 0)
          _BarSpec(
            label: '${s.index}',
            ratio: flat && !s.isPartial
                ? 0.65
                : (0.30 + 0.70 * (1 - (s.paceSecPerKm - fastest) / span))
                    .clamp(0.10, 1.0),
            faded: s.isPartial,
            isFastest: !s.isPartial && s.paceSecPerKm == fastest,
            semantics: s.isPartial
                ? '자투리 구간 ${Formatters.km(s.distanceMeters, fractionDigits: 2)}킬로미터, 페이스 ${RunFormat.pace(s.paceSecPerKm)}'
                : '${s.index}킬로미터 구간, 페이스 ${RunFormat.pace(s.paceSecPerKm)}',
          ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Legend(fastest: fastest, slowest: slowest, flat: flat),
        const SizedBox(height: AppTokens.s12),
        LayoutBuilder(
          builder: (context, constraints) {
            final n = bars.length;
            final available = constraints.maxWidth - _barGap * (n - 1);
            final ideal = n == 0 ? _minBarWidth : available / n;
            final width = ideal < _minBarWidth ? _minBarWidth : ideal;
            final row = Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < n; i++) ...[
                  if (i > 0) const SizedBox(width: _barGap),
                  SizedBox(width: width, child: _PaceBar(spec: bars[i])),
                ],
              ],
            );
            // 마라톤(42랩)처럼 막대가 많으면 폭을 줄이는 대신 가로로 스크롤
            // 시킨다. 3px짜리 막대는 높이 차이를 읽을 수 없다.
            return SizedBox(
              height: _barMaxHeight + 22,
              child: ideal < _minBarWidth
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal, child: row)
                  : row,
            );
          },
        ),
      ],
    );
  }
}

class _BarSpec {
  const _BarSpec({
    required this.label,
    required this.ratio,
    required this.faded,
    required this.isFastest,
    required this.semantics,
  });

  final String label;
  final double ratio;
  final bool faded;
  final bool isFastest;
  final String semantics;
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.fastest,
    required this.slowest,
    required this.flat,
  });

  final double fastest;
  final double slowest;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    if (flat) {
      return Text(
        '전 구간 페이스가 고르게 ${RunFormat.pace(fastest)}',
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: PaceChart._accent,
        ),
      );
    }
    return Row(
      children: [
        Text(
          '가장 빠른 구간 ${RunFormat.pace(fastest)}',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: PaceChart._accent,
          ),
        ),
        const SizedBox(width: AppTokens.s12),
        Text(
          '가장 느린 ${RunFormat.pace(slowest)}',
          style: PaceChart._labelStyle,
        ),
      ],
    );
  }
}

class _PaceBar extends StatelessWidget {
  const _PaceBar({required this.spec});

  final _BarSpec spec;

  @override
  Widget build(BuildContext context) {
    final color = spec.faded
        ? PaceChart._muted
        : spec.isFastest
            ? PaceChart._accent
            : PaceChart._bar;
    return Semantics(
      label: spec.semantics,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            height: spec.ratio.clamp(0.0, 1.0) * PaceChart._barMaxHeight,
            decoration: BoxDecoration(
              color: color,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(3)),
            ),
          ),
          const SizedBox(height: AppTokens.s4),
          Text(
            spec.label,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: PaceChart._labelStyle.copyWith(
              fontWeight: spec.isFastest ? FontWeight.w600 : FontWeight.w400,
              color: spec.isFastest
                  ? PaceChart._accent
                  : PaceChart._labelStyle.color,
            ),
          ),
        ],
      ),
    );
  }
}
