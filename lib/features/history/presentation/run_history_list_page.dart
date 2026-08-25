import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_tokens.dart';
import '../data/history_providers.dart';
import 'widgets/run_tile.dart';

/// 활동 탭 "전체 보기" 이동 화면 — 이 화면 자체는 Figma에 선택된 프레임이
/// 없어(활동 프레임엔 미리보기 3건 + 버튼만 있음) 앱 전역에서 이미 쓰는
/// 헤더/목록 패턴([FullRankingPage] 참고)을 그대로 따른다.
class RunHistoryListPage extends ConsumerWidget {
  const RunHistoryListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(myRunsProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(onBack: () => Navigator.of(context).pop()),
            Expanded(
              child: runs.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => const Center(child: Text('기록을 불러오지 못했어요')),
                data: (records) {
                  if (records.isEmpty) {
                    return const Center(child: Text('아직 기록이 없어요.'));
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: AppTokens.s24),
                    itemCount: records.length,
                    separatorBuilder: (_, __) => const RunTileDivider(),
                    itemBuilder: (context, index) => RunHistoryTile(record: records[index]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      child: Row(
        children: [
          InkWell(
            onTap: onBack,
            borderRadius: BorderRadius.circular(AppTokens.rPill),
            child: SvgPicture.asset(
              'assets/icons/chevron_right.svg',
              width: 24,
              height: 24,
              colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
            ).let((child) => Transform.flip(flipX: true, child: child)),
          ),
          const SizedBox(width: 16),
          const Text(
            '전체 기록',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black),
          ),
        ],
      ),
    );
  }
}

extension _WidgetLet on Widget {
  Widget let(Widget Function(Widget) f) => f(this);
}
