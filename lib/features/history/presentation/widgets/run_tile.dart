import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../models/models.dart';
import '../../../tracking/presentation/tracking_format.dart';

/// Figma 노드 `85:1266`("List 1") — 활동 탭 "최근 기록"/전체 기록 목록이
/// 공유하는 행. 왼쪽 활동유형+날짜, 가운데 거리/페이스/시간 3항목(초록
/// SemiBold 값 + 회색 라벨), 오른쪽 chevron.
///
/// [onTap]을 넘기면 chevron이 활성화된다 — 활동 탭 목록·전체 기록 목록은
/// [RunDetailPage](HI-02)로 이동시킨다. 넘기지 않으면 비활성 행이 된다.
class RunHistoryTile extends StatelessWidget {
  const RunHistoryTile({super.key, required this.record, this.onTap});

  final RunRecord record;
  final VoidCallback? onTap;

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  static String _dateLabel(DateTime utc) {
    final local = utc.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final w = _weekdays[local.weekday - 1];
    return '$y.$m.$d ($w)';
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.rMd),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTokens.s12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    RunFormat.activityLabel(record.activityType),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.black),
                  ),
                  const SizedBox(height: AppTokens.s4),
                  Text(
                    _dateLabel(record.startedAt),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Color(0xFF616161)),
                  ),
                ],
              ),
            ),
            _Stat(value: Formatters.km(record.distanceMeters, fractionDigits: 1), unit: 'km'),
            const SizedBox(width: AppTokens.s24),
            _Stat(value: RunFormat.paceOf(record), unit: '페이스'),
            const SizedBox(width: AppTokens.s24),
            _Stat(value: Formatters.duration(record.movingSeconds), unit: '시간'),
            const SizedBox(width: AppTokens.s8),
            SvgPicture.asset(
              'assets/icons/chevron_right.svg',
              width: 20,
              height: 20,
              colorFilter: const ColorFilter.mode(Color(0xFF9B9B9B), BlendMode.srcIn),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.unit});

  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF00C84B)),
        ),
        Text(
          unit,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Color(0xFFA5A5A5)),
        ),
      ],
    );
  }
}

/// Figma "Vector 5/6" — 목록 행 사이 얇은 구분선.
class RunTileDivider extends StatelessWidget {
  const RunTileDivider({super.key});

  @override
  Widget build(BuildContext context) => const Divider(height: 1, thickness: 1, color: Color(0xFFEAEAEA));
}
