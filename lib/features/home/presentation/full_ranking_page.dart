import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../models/models.dart';
import '../../ranking/data/ranking_providers.dart';
import 'widgets/ranking_widgets.dart';

/// "전체 보기" 눌렀을 때 이동하는 전체 랭킹 화면 — **2026-08-23 Figma
/// 프레임 반영**(파일 `97770fBbX9OAcPkEdZxiIP`, 노드 `65:84`).
///
/// 홈 화면의 "러너 랭킹" 미리보기(상위 10명)와 달리 여기는 리포지토리가
/// 주는 만큼(최대 50명) 전부 보여주고, 내 순위 행을 강조 표시한다
/// (`RunnerListTile(highlighted: true)`).
///
/// Figma는 이 화면 안에도 홈과 같은 "내 티어"/"전체" 필 토글을 다시 두고,
/// 타이틀은 어느 쪽을 보든 항상 고정 "러너 랭킹"이다 — 그래서 홈에서 넘어올
/// 때 탭했던 필로 시작하되, 이 화면 안에서도 자유롭게 전환할 수 있게 했다
/// (홈의 미리보기와 별개의 로컬 상태).
///
/// **시즌 선택 필**(`시즌 n ⌄`)도 Figma에 있지만, 지금은 **현재 시즌만
/// 실제로 조회 가능하다** — `leaderboard_entries`는 항상 "현재 기간" 행만
/// 캐시하고(`refresh_leaderboard`가 매 갱신마다 이전 기간 행을 지운다),
/// 다른 유저 전체의 과거 시즌 랭킹을 담아두는 테이블이 없다(`season_histories`는
/// 로그인한 사용자 "본인"의 시즌별 최종 결과만 기록하지, 그 시즌의 전체
/// 리더보드 스냅샷이 아니다). 그래서 필을 누르면 지난 시즌 목록을 보여주되
/// 전부 "준비 중"으로 비활성화해 둔다 — 실제 과거 시즌 전체 랭킹을 보여주려면
/// 시즌 종료 시 리더보드를 스냅샷하는 백엔드 작업이 별도로 필요하다(범위 밖).
class FullRankingPage extends ConsumerStatefulWidget {
  const FullRankingPage({super.key, this.initialTier});

  /// 홈에서 넘어올 때 활성이었던 필(null=전체, 특정 [Tier]=그 티어) — 이
  /// 화면의 시작 상태로만 쓰이고, 이후엔 이 화면 안의 필로 독립적으로 전환한다.
  final Tier? initialTier;

  @override
  ConsumerState<FullRankingPage> createState() => _FullRankingPageState();
}

class _FullRankingPageState extends ConsumerState<FullRankingPage> {
  late bool _myTierSelected = widget.initialTier != null;

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(isAuthenticatedProvider);
    final myUserId = ref.watch(currentUserIdProvider);

    final showPills = signedIn;
    final myTierAsync = signedIn ? ref.watch(myTierProvider) : null;
    final effectiveTier = signedIn && _myTierSelected ? myTierAsync?.valueOrNull : null;
    final tierStillLoading =
        signedIn && _myTierSelected && (myTierAsync?.isLoading ?? false);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(onBack: () => Navigator.of(context).pop()),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppTokens.s24, AppTokens.s16, AppTokens.s24, 0),
              child: Row(
                children: [
                  if (showPills)
                    Expanded(
                      child: Row(
                        children: [
                          _FilterPill(
                            label: '내 티어',
                            selected: _myTierSelected,
                            onTap: () => setState(() => _myTierSelected = true),
                          ),
                          const SizedBox(width: 9),
                          _FilterPill(
                            label: '전체',
                            selected: !_myTierSelected,
                            onTap: () => setState(() => _myTierSelected = false),
                          ),
                        ],
                      ),
                    )
                  else
                    const Spacer(),
                  const SizedBox(width: 9),
                  const _SeasonPill(),
                ],
              ),
            ),
            const SizedBox(height: AppTokens.s16),
            Expanded(
              child: tierStillLoading
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: AppTokens.s24),
                      child: RunnerListSkeleton(itemCount: 10),
                    )
                  : _RankingListView(tier: effectiveTier, myUserId: myUserId),
            ),
          ],
        ),
      ),
    );
  }
}

/// Figma 노드 `65:284` — 뒤로가기 + 고정 타이틀("러너 랭킹").
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
              // chevron_right를 좌우 반전해 chevron_left로 재사용(별도 에셋 없음).
              colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
              matchTextDirection: false,
            ).let((child) => Transform.flip(flipX: true, child: child)),
          ),
          const SizedBox(width: 16),
          const Text(
            '러너 랭킹',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black),
          ),
        ],
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.rPill),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.s12, vertical: AppTokens.s8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF00C84B) : const Color(0xFFF3F3F3),
          borderRadius: BorderRadius.circular(AppTokens.rPill),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: selected ? Colors.white : const Color(0xFF9B9B9B),
          ),
        ),
      ),
    );
  }
}

/// Figma 노드 `65:291`("Pill 3") — "시즌 n" + chevron-down. 탭하면 Figma
/// 노드 `71:714`("Dimmed")처럼 아래에서 올라오는 바텀시트로 시즌 목록을
/// 보여준다. 지금은 현재 시즌만 실제 데이터가 있어(클래스 최상단 doc 참고)
/// 지난 시즌은 목록엔 있지만 전부 "준비 중"으로 비활성 처리한다.
class _SeasonPill extends StatelessWidget {
  const _SeasonPill();

  static String seasonLabel(String seasonId) => seasonId.replaceFirst('-', ' ');

  @override
  Widget build(BuildContext context) {
    final currentSeason = Season.currentId();

    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.rPill),
      onTap: () => _showSeasonSheet(context, currentSeason),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.s12, vertical: AppTokens.s8),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F3F3),
          borderRadius: BorderRadius.circular(AppTokens.rPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              seasonLabel(currentSeason),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF9B9B9B)),
            ),
            const SizedBox(width: AppTokens.s4),
            const Icon(Icons.keyboard_arrow_down, size: 16, color: Color(0xFF9B9B9B)),
          ],
        ),
      ),
    );
  }

  static void _showSeasonSheet(BuildContext context, String currentSeason) {
    final previousSeasons = [
      Season.previousId(currentSeason),
      Season.previousId(Season.previousId(currentSeason)),
    ];

    showModalBottomSheet<void>(
      context: context,
      // `AppShell`의 플로팅 알약 네비바는 셸의 바깥쪽 Scaffold에 붙어 있어서,
      // 이 화면(중첩 탭 Navigator) 기준으로 시트를 띄우면 그 알약 밑에
      // 깔린다 — 루트 Navigator를 써서 알약보다 위(전체 화면)에 뜨게 한다.
      useRootNavigator: true,
      // Figma "Dimmed": rgba(0,0,0,0.6).
      barrierColor: const Color(0x99000000),
      backgroundColor: Colors.white,
      // 화면 가장자리에서 띄우지 않는다(엣지-투-엣지) — 위쪽 모서리만 둥글게.
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(AppTokens.s16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SeasonRow(
              label: seasonLabel(currentSeason),
              selected: true,
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
            for (final season in previousSeasons)
              _SeasonRow(
                label: seasonLabel(season),
                selected: false,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('지난 시즌 랭킹은 아직 지원하지 않아요')),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Figma 노드 `71:703`(선택, 초록 톤 배경+체크)/`71:704`(미선택, 배경 없음).
class _SeasonRow extends StatelessWidget {
  const _SeasonRow({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.rMd),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppTokens.s12),
        decoration: BoxDecoration(
          color: selected ? const Color(0x1A00C84B) : null,
          borderRadius: BorderRadius.circular(AppTokens.rMd),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  color: selected ? Colors.black : const Color(0xFF9B9B9B),
                ),
              ),
            ),
            if (selected)
              const Icon(Icons.check, size: 24, color: Color(0xFF00C84B))
            else
              const Text(
                '준비 중',
                style: TextStyle(fontSize: 12, color: Color(0xFF9B9B9B)),
              ),
          ],
        ),
      ),
    );
  }
}

class _RankingListView extends ConsumerWidget {
  const _RankingListView({required this.tier, required this.myUserId});

  final Tier? tier;
  final String? myUserId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(leaderboardProvider(tier));

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(horizontal: AppTokens.s24),
        child: RunnerListSkeleton(itemCount: 10),
      ),
      error: (_, __) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('랭킹을 불러오지 못했어요'),
            const SizedBox(height: AppTokens.s8),
            OutlinedButton(
              onPressed: () => ref.invalidate(leaderboardProvider(tier)),
              child: const Text('다시 시도'),
            ),
          ],
        ),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return const Center(child: Text('아직 이번 주 기록이 없어요.'));
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.s24, vertical: AppTokens.s8),
          itemCount: entries.length,
          separatorBuilder: (_, __) => const SizedBox(height: AppTokens.s4),
          itemBuilder: (context, index) {
            final entry = entries[index];
            return RunnerListTile(
              entry: entry,
              highlighted: myUserId != null && entry.userId == myUserId,
            );
          },
        );
      },
    );
  }
}

extension _WidgetLet on Widget {
  Widget let(Widget Function(Widget) f) => f(this);
}
