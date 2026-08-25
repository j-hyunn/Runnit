import 'package:flutter/material.dart';

/// Figma 노드 `85:1138`("Frame 44") — 이번 달 일별 거리 막대 그래프.
///
/// Figma 목업은 막대 높이가 실제 데이터와 무관한 데코용 임의값이라(격자선의
/// "0" 기준선과 막대 밑변이 정확히 맞지 않는다) 그 값을 그대로 베끼지 않고,
/// 실데이터로 **비례가 맞는** 막대를 새로 그린다 — 격자 4단(최댓값 기준
/// 5의 배수로 반올림)/일자 눈금(1·8·15·22·말일)/막대 색(초록, 기록 없는
/// 날은 투명)이라는 시각 언어만 Figma에서 가져왔다.
class MonthlyBarChart extends StatelessWidget {
  const MonthlyBarChart({super.key, required this.dailyDistanceMeters});

  /// index 0 = 1일 ... 마지막 index = 이번 달 마지막 날.
  final List<double> dailyDistanceMeters;

  static const _labelStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Color(0xFF616161));

  @override
  Widget build(BuildContext context) {
    final maxKm = dailyDistanceMeters.fold<double>(
      0,
      (acc, meters) => (meters / 1000) > acc ? meters / 1000 : acc,
    );
    final topRaw = (maxKm / 5).ceil() * 5;
    final topValue = topRaw < 5 ? 5.0 : topRaw.toDouble();
    final gridLabels = [topValue, topValue * 2 / 3, topValue / 3, 0.0];
    final ticks = _dayTicks(dailyDistanceMeters.length);

    return SizedBox(
      height: 130,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 101,
            child: Stack(
              children: [
                Column(
                  children: [
                    for (var i = 0; i < gridLabels.length; i++) ...[
                      if (i > 0) const SizedBox(height: 15),
                      _GridRow(label: gridLabels[i].round().toString()),
                    ],
                  ],
                ),
                Positioned(
                  left: 32,
                  right: 0,
                  bottom: 8,
                  height: 85,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final meters in dailyDistanceMeters)
                        _Bar(km: meters / 1000, topValue: topValue),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 15),
          SizedBox(
            height: 14,
            child: Row(
              children: [
                const SizedBox(width: 32),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final day in ticks) Text('$day', style: _labelStyle),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static List<int> _dayTicks(int daysInMonth) {
    final ticks = {1, 8, 15, 22, daysInMonth};
    return ticks.toList()..sort();
  }
}

class _GridRow extends StatelessWidget {
  const _GridRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 14,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(label, style: MonthlyBarChart._labelStyle),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Divider(height: 1, thickness: 1, color: Color(0xFFEEEEEE))),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.km, required this.topValue});

  final double km;
  final double topValue;

  static const _maxHeight = 85.0;

  @override
  Widget build(BuildContext context) {
    final ratio = topValue <= 0 ? 0.0 : (km / topValue).clamp(0.0, 1.0);
    return Container(
      width: 6,
      height: ratio * _maxHeight,
      decoration: BoxDecoration(
        color: km > 0 ? const Color(0xFF00C84B) : Colors.transparent,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
