import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import '../data/history_providers.dart';
import 'run_detail_page.dart';
import 'widgets/history_header.dart';
import 'widgets/run_tile.dart';

/// 활동 탭 "전체 보기" 이동 화면 — 이 화면 자체는 Figma에 선택된 프레임이
/// 없어(활동 프레임엔 미리보기 3건 + 버튼만 있음) 앱 전역에서 이미 쓰는
/// 헤더/목록 패턴([FullRankingPage] 참고)을 그대로 따른다. 헤더는
/// [RunDetailPage]와 공유하는 [HistoryHeader]다.
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
            const HistoryHeader(title: '전체 기록'),
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
                    itemBuilder: (context, index) => RunHistoryTile(
                      record: records[index],
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => RunDetailPage(runId: records[index].id),
                        ),
                      ),
                    ),
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
