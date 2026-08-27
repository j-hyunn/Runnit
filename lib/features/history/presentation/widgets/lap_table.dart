import 'package:flutter/material.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../../../tracking/presentation/tracking_format.dart';
import '../../domain/lap_splits.dart';

/// HI-02 랩 테이블 — 1km 구간별 페이스·시간·(있으면) 심박 또는 상승 고도.
///
/// 가장 빠른 완전 구간을 앱 강조색(초록)으로 표시한다 — 러닝 앱 관례이자,
/// 표를 위에서 아래로 훑지 않아도 "어디가 잘 나왔는지"가 먼저 보이게 하는
/// 유일한 장치다. 자투리 구간은 1km를 못 채워 페이스가 과대·과소로 튀므로
/// 최속 후보에서 빼고 회색으로 낮춘다.
///
/// 4번째 열은 데이터가 있을 때만 붙는다. 폰 가로폭에서 5열은 각 셀이
/// 줄바꿈되기 시작해, 심박(웨어러블)과 고도(기압계) 중 하나만 고른다 —
/// 심박이 러너에게 더 자주 의미가 있으므로 우선한다.
class LapTable extends StatelessWidget {
  const LapTable({super.key, required this.splits});

  final List<LapSplit> splits;

  static const _headerColor = Color(0xFF616161);
  static const _mutedColor = Color(0xFF9B9B9B);
  static const _accentColor = Color(0xFF00C84B);
  static const _dividerColor = Color(0xFFEAEAEA);

  @override
  Widget build(BuildContext context) {
    if (splits.isEmpty) return const SizedBox.shrink();

    final extra = _ExtraColumn.pick(splits);
    final fastestIndex = _fastestFullLapIndex(splits);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _LapRow(
          cells: [
            const _LapCell('구간', flex: 2, color: _headerColor, bold: true),
            const _LapCell('페이스', color: _headerColor, bold: true),
            const _LapCell('시간', color: _headerColor, bold: true),
            if (extra != null)
              _LapCell(extra.header, color: _headerColor, bold: true),
          ],
        ),
        const Divider(height: 1, thickness: 1, color: _dividerColor),
        for (final split in splits)
          _LapRow(
            highlighted: split.index == fastestIndex,
            cells: [
              _LapCell(
                split.isPartial
                    ? '${split.index} · ${Formatters.km(split.distanceMeters, fractionDigits: 2)}km'
                    : '${split.index}km',
                flex: 2,
                color: split.isPartial ? _mutedColor : Colors.black,
              ),
              _LapCell(
                RunFormat.pace(split.paceSecPerKm),
                color: split.index == fastestIndex
                    ? _accentColor
                    : split.isPartial
                        ? _mutedColor
                        : Colors.black,
                bold: split.index == fastestIndex,
              ),
              _LapCell(
                Formatters.duration(split.durationSeconds),
                color: split.isPartial ? _mutedColor : Colors.black,
              ),
              if (extra != null)
                _LapCell(
                  extra.valueOf(split),
                  color: split.isPartial ? _mutedColor : Colors.black,
                ),
            ],
          ),
      ],
    );
  }

  /// 가장 빠른 **완전** 구간의 번호. 완전 구간이 없으면 null(강조 없음).
  /// 동률이면 먼저 나온 구간을 고른다 — 두 줄을 같이 강조하면 "최고 기록"이
  /// 두 개인 것처럼 읽힌다.
  static int? _fastestFullLapIndex(List<LapSplit> splits) {
    int? bestIndex;
    double? bestPace;
    for (final s in splits) {
      if (s.isPartial || s.paceSecPerKm <= 0) continue;
      if (bestPace == null || s.paceSecPerKm < bestPace) {
        bestPace = s.paceSecPerKm;
        bestIndex = s.index;
      }
    }
    return bestIndex;
  }
}

/// 4번째 열에 무엇을 보여줄지의 결정. 데이터가 전혀 없으면 열 자체를 뺀다.
class _ExtraColumn {
  const _ExtraColumn(this.header, this.valueOf);

  final String header;
  final String Function(LapSplit) valueOf;

  static _ExtraColumn? pick(List<LapSplit> splits) {
    if (splits.any((s) => s.avgHeartRateBpm != null)) {
      return _ExtraColumn(
        '심박',
        (s) => s.avgHeartRateBpm == null ? '–' : '${s.avgHeartRateBpm}',
      );
    }
    if (splits.any((s) => s.elevationGainMeters != null)) {
      return _ExtraColumn(
        '고도',
        (s) => s.elevationGainMeters == null
            ? '–'
            : '+${s.elevationGainMeters!.round()}m',
      );
    }
    return null;
  }
}

class _LapRow extends StatelessWidget {
  const _LapRow({required this.cells, this.highlighted = false});

  final List<Widget> cells;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        // 색맹 사용자에게 초록 텍스트만으로는 최속 구간이 구분되지 않는다.
        // 옅은 배경을 함께 깔아 색상 외 단서를 하나 더 준다.
        color: highlighted ? const Color(0x1400C84B) : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTokens.rSm),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.s8,
          vertical: AppTokens.s12,
        ),
        child: Row(children: cells),
      ),
    );
  }
}

class _LapCell extends StatelessWidget {
  const _LapCell(
    this.text, {
    this.flex = 1,
    this.color = Colors.black,
    this.bold = false,
  });

  final String text;
  final int flex;
  final Color color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
          color: color,
        ),
      ),
    );
  }
}
