import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/models.dart';
import '../../../core/widgets/app_shell.dart';
import '../../auth/presentation/widgets/guest_login_prompt.dart';
import '../../ranking/data/ranking_providers.dart';
import 'full_ranking_page.dart';
import 'widgets/ranking_widgets.dart';

/// 홈 화면 — **게스트 허용 라우트**(`RouteAccess.guestAllowedPrefixes`).
///
/// **2026-08-21 Figma "Home" 프레임 반영**(파일 `97770fBbX9OAcPkEdZxiIP`,
/// 노드 `55:1118`), **같은 날 사용자 피드백으로 4가지 조정**:
/// 1. "이번 시즌 기록" 카드의 티어 표시는 뱃지(톤온톤 배경 필)가 아니라
///    아이콘+텍스트만 — `TierPill(background: false)`.
/// 2. "오늘의 Top 러너"는 5명까지만(`dailyTopRunnersProvider`의 `limit`을
///    서버 조회 단계에서 5로 낮췄다).
/// 3. "러너 랭킹"의 내 티어/전체 각각 10명 미리보기 + "전체 보기"는 더 이상
///    인앱 펼치기가 아니라 [FullRankingPage]로 이동해서 전체 목록을 보여주고
///    내 순위 행을 강조 표시한다.
/// 4. "전체" 랭킹에도 각 유저의 실제 티어 배지를 보여준다 — 이걸 위해
///    `leaderboard_entries`에 `owner_tier`(행 소유자의 진짜 개인 티어) 컬럼을
///    추가했다(마이그레이션 24, `RankingEntry.ownerTier`). 기존 `tier`는
///    보드의 조회 조건이라 "전체" 보드에서는 항상 null이었던 것과 다르다.
///
/// **2026-08-23**: "이번 주 기록" 카드를 "이번 시즌 기록"으로 바꿨다 —
/// 이제 `myRankProvider(null)`(주간 랭킹 점수)가 아니라
/// `AppUser.seasonDistanceMeters`(시즌 누적 거리, 바로 아래 티어 진행률 바가
/// 쓰는 값과 동일한 출처)를 큰 숫자로 보여준다. 두 값 다 "서버가 확정한 값을
/// 그대로 표시"라는 원칙은 같지만, 카드 안에서 위(거리)와 아래(티어 진행률)가
/// 서로 다른 기간(주간 vs 시즌)을 가리키던 이전 상태가 헷갈려서 시즌으로 통일했다.
///
/// 구성(위→아래):
/// 1. 커스텀 헤더 — 로고 + 검색/알림 아이콘(둘 다 아직 목적지가 없어 자리만
///    잡아둔 자리표시자 — 탭하면 "준비 중" 안내만 뜬다).
/// 2. "이번 시즌 기록" 카드 — 시즌 누적 거리(`AppUser.seasonDistanceMeters`) + 현재
///    티어(아이콘+텍스트) + 시즌 티어 진행률 바(Figma가 지정한 브랜드 그린 고정색).
/// 3. "오늘의 Top 러너" — 일간(daily) 글로벌 리더보드 상위 5명, 가로 스크롤 카드.
/// 4. "러너 랭킹" — "내 티어"/"전체" 필 토글(하나만 보이는 리스트, 각 10명
///    미리보기) + "전체 보기"(별도 화면으로 이동).
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      // Figma `55:1118`("Home") 루트 배경은 순백이 아니라 #F8F8F8 — 흰 카드
      // (My card/Top runner 카드)들이 이 옅은 회색 위에서 살짝 떠 보이도록
      // 하는 의도적 배경색이다(활동 탭 `82:722`도 동일한 배경을 쓴다).
      backgroundColor: const Color(0xFFF8F8F8),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _HomeHeader(),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        AppTokens.s16,
                        AppTokens.s16,
                        AppTokens.s16,
                        AppTokens.s24,
                      ),
                      child: _WeeklyTierCard(),
                    ),
                  ),
                  const SliverToBoxAdapter(child: _TopRunnersSection()),
                  const SliverToBoxAdapter(child: SizedBox(height: AppTokens.s24)),
                  const _RunnerRankingSection(),
                  // `AppShell`이 플로팅 알약 네비바라 body 위를 덮는다
                  // (`extendBody: true`) — 마지막 랭킹 행이 그 뒤에 가려지지
                  // 않도록 바의 실측 높이만큼 여백을 더 확보한다(고정값을
                  // 어림하면 기기별 폰트 메트릭/세이프에어리어 차이로 어긋난다).
                  SliverToBoxAdapter(
                    child: ValueListenableBuilder<double>(
                      valueListenable: AppShell.measuredHeight,
                      builder: (context, height, _) => SizedBox(height: height),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Figma 노드 `55:1179`("Header") — 로고 + 검색/알림. 시스템 상단바가 아니라
/// 화면 폭 전체를 쓰는 커스텀 헤더라 `AppBar` 대신 직접 그렸다.
class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Figma `55:1179`: px-24 py-15. 다른 세 탭(러닝/활동/마이) 헤더도
      // 2026-08-25에 이 값(24)으로 맞췄다 — 홈이 기준.
      padding: const EdgeInsets.fromLTRB(24, 15, 24, 15),
      // 러닝/활동/마이 헤더의 24px 타이틀 텍스트는 폰트 줄높이가 폰트
      // 크기보다 커서(Pretendard 기준 약 1.4배) 24로 고정하면 글자가
      // 위아래로 잘렸다 — 네 헤더 모두 34로 맞춰 타이틀이 잘리지 않으면서
      // 높이도 똑같게 한다.
      child: SizedBox(
        height: 34,
        child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          SvgPicture.asset('assets/icons/logo.svg', height: 22),
          const Row(
            children: [
              _HeaderIconButton(
                asset: 'assets/icons/search.svg',
                label: '검색',
              ),
              SizedBox(width: AppTokens.s12),
              _HeaderIconButton(
                asset: 'assets/icons/bell.svg',
                label: '알림',
              ),
            ],
          ),
        ],
        ),
      ),
    );
  }
}

/// 검색/알림 둘 다 아직 목적 화면이 없다(검색: 범위 밖, 알림: PRD NT-* 후속).
/// 탭 자체를 죽이지 않고 "준비 중"임을 알리는 최소한의 피드백만 준다.
class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({required this.asset, required this.label});

  final String asset;
  final String label;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.rPill),
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label 기능은 준비 중이에요')),
        );
      },
      child: SvgPicture.asset(asset, width: 24, height: 24),
    );
  }
}

/// Figma 노드 `55:1238`("My card") — 시즌 누적 거리 + 현재 티어 + 시즌
/// 티어 진행률. 티어는 뱃지가 아니라 아이콘+텍스트만(`TierPill(background:
/// false)`) — 진행률 바 색은 Figma 지정값(브랜드 그린)으로 고정이며 티어별
/// 색과는 무관하다.
class _WeeklyTierCard extends ConsumerWidget {
  const _WeeklyTierCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(isAuthenticatedProvider);
    final text = Theme.of(context).textTheme;

    if (!signedIn) {
      return const GuestLoginPromptCard(
        icon: Icons.military_tech_outlined,
        title: '내 기록과 티어가 궁금하다면',
        message: '로그인하면 이번 시즌 누적 거리와 내 티어, 다음 등급까지 남은 거리를 볼 수 있어요.',
        actionLabel: '로그인하고 내 기록 보기',
      );
    }

    final profile = ref.watch(currentProfileProvider).valueOrNull;

    if (profile == null) {
      return Container(
        height: 168,
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(20),
        ),
      );
    }

    final tier = profile.currentTier;
    final remaining = profile.remainingToNextTierMeters;
    final seasonKm = Formatters.km(profile.seasonDistanceMeters, fractionDigits: 1);

    return Container(
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
          const Text(
            '이번 시즌 기록',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Color(0xFF616161)),
          ),
          const SizedBox(height: AppTokens.s8),
          Row(
            // Figma `55:1405`("Container"): gap-16, Distance 박스는 w-230 고정.
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                width: 230,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      seasonKm,
                      style: const TextStyle(
                        fontSize: 50,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                        height: 1,
                      ),
                    ),
                    const SizedBox(width: AppTokens.s4),
                    const Text(
                      'km',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF616161),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              TierPill(tier: tier, iconSize: 24, fontSize: 16, background: false),
            ],
          ),
          const SizedBox(height: AppTokens.s24),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppTokens.rPill),
            child: LinearProgressIndicator(
              value: profile.tierProgress,
              minHeight: 11,
              backgroundColor: const Color(0xFF00F35A).withValues(alpha: 0.1),
              color: const Color(0xFF00F35A),
            ),
          ),
          const SizedBox(height: AppTokens.s8),
          Text(
            remaining == null
                ? '최고 티어예요 — 이번 시즌 끝까지 순위로 경쟁해요.'
                : '다음 티어까지 ${Formatters.km(remaining, fractionDigits: 1)}km',
            style: text.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: const Color(0xFF616161),
            ),
          ),
        ],
      ),
    );
  }
}

/// Figma 노드 `55:1321`("Top runner") — 일간 리더보드 상위 5명 가로 스크롤.
class _TopRunnersSection extends ConsumerWidget {
  const _TopRunnersSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dailyTopRunnersProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Figma `55:1321`("Top runner"): 컨테이너 여백 16 + 섹션 자체 px-8 = 24.
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppTokens.s24),
          child: Text(
            '오늘의 Top 러너',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black),
          ),
        ),
        const SizedBox(height: AppTokens.s16),
        SizedBox(
          height: 200,
          child: async.when(
            loading: () => const _TopRunnersSkeleton(),
            error: (_, __) => const Center(child: Text('오늘의 랭킹을 불러오지 못했어요')),
            data: (entries) {
              if (entries.isEmpty) {
                return const Center(child: Text('아직 오늘 달린 사람이 없어요.'));
              }
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppTokens.s24),
                itemCount: entries.length,
                separatorBuilder: (_, __) => const SizedBox(width: AppTokens.s12),
                itemBuilder: (context, index) => _TopRunnerCard(entry: entries[index]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TopRunnerCard extends StatelessWidget {
  const _TopRunnerCard({required this.entry});

  final RankingEntry entry;

  @override
  Widget build(BuildContext context) {
    final name = entry.displayName ?? entry.username;

    return Container(
      width: 141,
      padding: const EdgeInsets.all(AppTokens.s12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFF5F5F5)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Top ${entry.rank}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.black),
          ),
          const SizedBox(height: AppTokens.s12),
          const ProfileCircle(size: 40),
          const SizedBox(height: AppTokens.s8),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.black),
          ),
          if (entry.ownerTier != null) ...[
            const SizedBox(height: AppTokens.s8),
            TierPill(tier: entry.ownerTier!),
          ],
          const SizedBox(height: AppTokens.s12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                Formatters.km(entry.score, fractionDigits: 1),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: Colors.black),
              ),
              const Text(
                ' km',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF616161)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopRunnersSkeleton extends StatelessWidget {
  const _TopRunnersSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.s24),
      itemCount: 3,
      separatorBuilder: (_, __) => const SizedBox(width: AppTokens.s12),
      itemBuilder: (_, __) => Container(
        width: 141,
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }
}

/// Figma 노드 `55:1221`("Ranking") — "내 티어"/"전체" 필 토글(각 10명 미리보기)
/// + "전체 보기"(→ [FullRankingPage]).
class _RunnerRankingSection extends ConsumerStatefulWidget {
  const _RunnerRankingSection();

  @override
  ConsumerState<_RunnerRankingSection> createState() => _RunnerRankingSectionState();
}

class _RunnerRankingSectionState extends ConsumerState<_RunnerRankingSection> {
  bool _myTierSelected = true;

  static const _previewCount = 10;

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(isAuthenticatedProvider);

    // 게스트는 "내 티어"가 성립하지 않는다 — 필 자체를 보여주지 않고 전체만.
    final showPills = signedIn;
    final myTierAsync = signedIn ? ref.watch(myTierProvider) : null;
    final effectiveTier = signedIn && _myTierSelected ? myTierAsync?.valueOrNull : null;
    final tierStillLoading =
        signedIn && _myTierSelected && (myTierAsync?.isLoading ?? false);

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          // Figma `55:1221`("Ranking"): 컨테이너 여백 16 + 섹션 자체 px-8 = 24.
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.s24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '러너 랭킹',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black),
                ),
                InkWell(
                  onTap: tierStillLoading
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => FullRankingPage(initialTier: effectiveTier),
                            ),
                          ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '전체 보기',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF616161),
                        ),
                      ),
                      SvgPicture.asset(
                        'assets/icons/chevron_right.svg',
                        width: 16,
                        height: 16,
                        colorFilter: const ColorFilter.mode(Color(0xFF616161), BlendMode.srcIn),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (showPills)
          SliverToBoxAdapter(
            // Figma `55:1220`("Pill Buttons"): gap-9. `55:1221`("Ranking")
            // 자체가 flex-col gap-16이라 이 필 줄과 아래 목록 사이도 16.
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
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
            ),
          ),
        if (tierStillLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(AppTokens.s16),
              child: RunnerListSkeleton(),
            ),
          )
        else
          _RunnerList(tier: effectiveTier, previewCount: _previewCount),
      ],
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

class _RunnerList extends ConsumerWidget {
  const _RunnerList({required this.tier, required this.previewCount});

  final Tier? tier;
  final int previewCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(leaderboardProvider(tier));

    return async.when(
      loading: () => const SliverToBoxAdapter(
        child: Padding(padding: EdgeInsets.all(AppTokens.s16), child: RunnerListSkeleton()),
      ),
      error: (_, __) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.s16),
          child: Column(
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
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(AppTokens.s24),
              child: Center(child: Text('아직 이번 주 기록이 없어요.')),
            ),
          );
        }
        final visible = previewCount.clamp(0, entries.length);
        // Figma `55:1358`("Lists"): flex-col gap-8 사이에 각 행이 자체
        // py-8까지 갖고 있어 행간 총 간격은 8(gap) — `SliverList`엔 항목 사이
        // 구분자가 없어 `Column`으로 감싸 `SizedBox(height: 8)`을 직접 끼운다
        // (미리보기가 최대 10개라 가상 스크롤이 필요 없다).
        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.s24),
          sliver: SliverToBoxAdapter(
            child: Column(
              children: [
                for (var i = 0; i < visible; i++) ...[
                  if (i > 0) const SizedBox(height: AppTokens.s8),
                  RunnerListTile(entry: entries[i]),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
