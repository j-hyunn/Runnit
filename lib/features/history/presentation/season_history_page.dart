import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_shell.dart';
import '../../../models/models.dart';
import '../../home/presentation/widgets/ranking_widgets.dart';
import '../data/season_history_providers.dart';
import 'widgets/history_header.dart';

/// 역대 시즌 기록 화면 (PRD HI-06 / TI-06, 명예 요소 TI-09).
///
/// ## 이 화면이 존재하는 이유
/// 티어는 시즌마다 리셋된다(TI-02). 리셋 자체가 상실감을 만들기 때문에
/// "2026 Q3 플래티넘"이라는 사실이 **영구히 남는 곳**이 필요하다 —
/// 영구 루프(§4.3)에서 뱃지·레벨과 같은 역할을 시즌 결과가 맡는다.
///
/// ## 표시 규칙
/// - **끝난 시즌만** 있다. 진행 중인 시즌은 `season_histories`에 행이 없고,
///   현재 상태는 홈의 티어 카드가 보여준다 — 여기에 "진행 중" 카드를 끼워
///   넣으면 확정값과 잠정값이 한 목록에 섞인다.
/// - 무효 처리된 시즌(`isVoided`, §8.1)은 **숨기지 않고 흐리게** 보여준다.
///   숨기면 사용자는 시즌이 통째로 증발한 것으로 오해한다. 이 행은 RLS상
///   본인에게만 보인다.
/// - 최신 시즌이 위. 정렬은 리포지토리(`season_id desc`)가 확정한 순서를
///   그대로 쓴다.
///
/// 타인 프로필의 역대 시즌은 범위 밖이다(AC-03과 함께 다뤄야 한다) —
/// 이 화면은 로그인한 본인 것만 조회한다.
class SeasonHistoryPage extends ConsumerWidget {
  const SeasonHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final histories = ref.watch(mySeasonHistoriesProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const HistoryHeader(title: '역대 시즌'),
            Expanded(
              child: histories.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => const _SeasonHistoryMessage(
                  title: '시즌 기록을 불러오지 못했어요',
                  body: '잠시 후 다시 시도해 주세요.',
                ),
                data: (items) => items.isEmpty
                    ? const _SeasonHistoryMessage(
                        title: '아직 완료된 시즌이 없어요',
                        body: '이번 시즌이 끝나면 여기에 기록돼요.',
                      )
                    : _SeasonHistoryList(items: items),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeasonHistoryList extends ConsumerWidget {
  const _SeasonHistoryList({required this.items});

  final List<SeasonHistory> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // TI-09 — 확정된 최고 티어. 무효 시즌과 진행 중 시즌은 빠진다.
    final bestTier = ref.watch(bestEverTierProvider);

    return ValueListenableBuilder<double>(
      valueListenable: AppShell.measuredHeight,
      builder: (context, navHeight, _) => ListView.separated(
        padding: EdgeInsets.only(
          left: AppTokens.s16,
          right: AppTokens.s16,
          bottom: navHeight + AppTokens.s16,
        ),
        itemCount: items.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: AppTokens.s12),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _BestTierSummary(
              seasonCount: items.where((h) => !h.isVoided).length,
              bestTier: bestTier,
            );
          }
          return _SeasonHistoryCard(history: items[index - 1]);
        },
      ),
    );
  }
}

/// 목록 맨 위 요약 — "역대 최고 티어"(TI-09)와 완주한 시즌 수.
///
/// 카드가 아니라 배경 위 텍스트로 둔다. 아래 시즌 카드들과 같은 흰 카드로
/// 만들면 "가장 최근 시즌"으로 오독되기 쉽다.
class _BestTierSummary extends StatelessWidget {
  const _BestTierSummary({required this.seasonCount, required this.bestTier});

  final int seasonCount;
  final Tier? bestTier;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppTokens.s4, AppTokens.s8, AppTokens.s4, AppTokens.s12),
      child: Row(
        children: [
          const Text(
            '역대 최고 티어',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Color(0xFF616161)),
          ),
          const SizedBox(width: AppTokens.s8),
          if (bestTier == null)
            const Text(
              '-',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black),
            )
          else
            TierPill(tier: bestTier!, fontSize: 13),
          const Spacer(),
          Text(
            '완료한 시즌 $seasonCount개',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Color(0xFF9B9B9B)),
          ),
        ],
      ),
    );
  }
}

/// 시즌 1개 = 카드 1장. 프로필·활동 탭과 같은 흰 카드(반지름 20 + 옅은 그림자).
class _SeasonHistoryCard extends StatelessWidget {
  const _SeasonHistoryCard({required this.history});

  final SeasonHistory history;

  @override
  Widget build(BuildContext context) {
    final voided = history.isVoided;

    final card = Container(
      padding: const EdgeInsets.all(AppTokens.s16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 2.5),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  // `2026-Q3` → `2026 Q3`. 모델이 파생시켜 준 라벨을 쓴다.
                  history.seasonLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black),
                ),
              ),
              TierPill(tier: history.finalTier),
            ],
          ),
          if (voided) ...[
            const SizedBox(height: AppTokens.s8),
            const _VoidedLabel(),
          ],
          const SizedBox(height: AppTokens.s16),
          Row(
            children: [
              Expanded(
                child: _SeasonStat(label: '거리', value: '${Formatters.km(history.distanceMeters)} km'),
              ),
              Expanded(
                child: _SeasonStat(label: '러닝', value: '${history.runCount}'),
              ),
              Expanded(
                child: _SeasonStat(label: '시간', value: Formatters.duration(history.movingSeconds)),
              ),
            ],
          ),
          // 미참여 시즌(주간 랭킹에 한 번도 안 올라간 경우)은 null이다 —
          // "순위 없음" 행을 만들면 실패한 것처럼 보이므로 아예 감춘다.
          if (history.bestWeeklyRank != null) ...[
            const SizedBox(height: AppTokens.s16),
            Row(
              children: [
                const Text(
                  '주간 최고 순위',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Color(0xFF616161)),
                ),
                const Spacer(),
                Text(
                  '${history.bestWeeklyRank}위',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.black),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    if (!voided) return card;

    // 무효 시즌: 흐리게 + 라벨. 삭제하지 않는 이유는 이의 제기 대응 근거를
    // 남기기 위함이다(§8.1) — 사용자에게도 "없던 일"이 아니라 "무효"로 보인다.
    return Semantics(
      label: '${history.seasonLabel} 시즌 — 무효 처리됨',
      child: Opacity(opacity: 0.45, child: card),
    );
  }
}

class _VoidedLabel extends StatelessWidget {
  const _VoidedLabel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.s8, vertical: AppTokens.s4),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F3F3),
        borderRadius: BorderRadius.circular(AppTokens.rPill),
      ),
      child: const Text(
        '무효 처리됨',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF9B9B9B)),
      ),
    );
  }
}

/// 프로필/활동 탭의 3분할 통계와 같은 형태(라벨 위, 값 아래).
class _SeasonStat extends StatelessWidget {
  const _SeasonStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Color(0xFF616161))),
        const SizedBox(height: AppTokens.s8),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.black),
        ),
      ],
    );
  }
}

/// 빈 목록·에러 공용 안내. 두 상태의 레이아웃이 같아서 위젯을 나누지 않는다.
class _SeasonHistoryMessage extends StatelessWidget {
  const _SeasonHistoryMessage({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.black),
            ),
            const SizedBox(height: AppTokens.s8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Color(0xFF9B9B9B)),
            ),
          ],
        ),
      ),
    );
  }
}
