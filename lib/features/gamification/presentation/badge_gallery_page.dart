// Material의 `Badge` 위젯과 도메인 모델 `Badge`가 이름 충돌하므로 위젯 쪽을 숨긴다.
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_shell.dart';
import '../../../models/models.dart';
import '../../auth/presentation/widgets/guest_login_prompt.dart';
import '../../sharing/data/share_providers.dart';
import '../../sharing/domain/share_card_data.dart';
import '../../sharing/presentation/share_card_sheet.dart';
import '../data/gamification_providers.dart';
import '../domain/badge_assets.dart';
import '../domain/badge_progress.dart';

/// 뱃지 갤러리 **본문** — 게스트도 볼 수 있지만 개인화 레이어는 비공개다.
///
/// - 게스트: 전체 카탈로그를 **중립적으로**(획득 여부/진행률 없이) 보여준다.
///   "내가 못 얻은 것"처럼 보이는 잠금 표현 대신 회색 톤 + 자물쇠로 통일하고,
///   상단에 로그인 유도 카드를 둔다.
/// - 로그인: 획득한 뱃지를 등급 색 + 체크로 강조하고 획득 개수 요약을 보여준다.
///
/// 데이터 소스는 `../data/gamification_providers.dart` — Supabase `badges` /
/// `user_badges` 테이블.
///
/// **Scaffold/AppBar를 포함하지 않는다** — 2026-08-21 4탭 개편으로 독립 라우트가
/// 아니라 기록 화면("HistoryPage")의 "뱃지" 하위 탭 안에 임베드되는 형태로 바뀌었다.
/// 호출부(부모 화면)가 AppBar/TabBar를 소유한다.
class BadgeGalleryBody extends ConsumerWidget {
  const BadgeGalleryBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(isAuthenticatedProvider);
    final progressList = ref.watch(badgeProgressListProvider);

    return progressList.when(
      loading: () => const _GallerySkeleton(),
      error: (e, _) => _GalleryError(
        onRetry: () => ref.invalidate(badgeCatalogProvider),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const Center(child: Text('아직 공개된 뱃지가 없어요'));
        }
        return _GalleryBody(progressList: list, signedIn: signedIn);
      },
    );
  }
}

class _GalleryBody extends ConsumerWidget {
  const _GalleryBody({required this.progressList, required this.signedIn});

  final List<BadgeProgress> progressList;
  final bool signedIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loadingEarned = signedIn && ref.watch(userBadgesProvider).isLoading;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.s16,
            AppTokens.s16,
            AppTokens.s16,
            AppTokens.s8,
          ),
          sliver: SliverToBoxAdapter(
            child: signedIn
                ? _EarnedSummary(
                    progressList: progressList,
                    loading: loadingEarned,
                  )
                : const GuestLoginPromptCard(
                    icon: Icons.military_tech_outlined,
                    title: '로그인하고 내 뱃지 확인하기',
                    message: '카카오로 로그인하면 내가 획득한 뱃지와 다음 목표까지의 진행률이 표시돼요.',
                    actionLabel: '로그인하고 내 뱃지 보기',
                  ),
          ),
        ),
        // 카테고리별 섹션으로 나눠 그린다 — `badgeProgressListProvider`가 이미
        // 카테고리순으로 정렬해 넘겨주므로 연속 구간을 그대로 묶으면 된다.
        // "어떤 종류의 뱃지인지" 한눈에 구분되도록 섹션 헤더에 카테고리 라벨을 단다.
        for (final group in _groupByCategory(progressList)) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.s16,
              AppTokens.s16,
              AppTokens.s16,
              AppTokens.s4,
            ),
            sliver: SliverToBoxAdapter(
              child: _CategorySectionHeader(category: group.first.badge.category),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.s16,
              0,
              AppTokens.s16,
              AppTokens.s8,
            ),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                // 화면 폭에 따라 3~5열로 자동 조정된다(작은 폰 ~ 큰 폰/폴더블).
                maxCrossAxisExtent: 132,
                mainAxisSpacing: AppTokens.s12,
                crossAxisSpacing: AppTokens.s12,
                childAspectRatio: 0.85,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final progress = group[index];
                  return _BadgeTile(
                    progress: progress,
                    showEarnedState: signedIn,
                    onTap: () => _showDetail(context, progress, signedIn),
                  );
                },
                childCount: group.length,
              ),
            ),
          ),
        ],
        // AppShell이 플로팅 알약 네비바(`extendBody: true`)라 마지막 줄이
        // 그 뒤에 가려지지 않도록 바의 실측 높이만큼 여백을 더한다.
        SliverToBoxAdapter(
          child: ValueListenableBuilder<double>(
            valueListenable: AppShell.measuredHeight,
            builder: (context, height, _) => SizedBox(height: height),
          ),
        ),
      ],
    );
  }

  // 다른 바텀시트(러닝 설정 `tracking_page.dart`, 시즌 선택
  // `full_ranking_page.dart`)와 같은 크롬으로 통일 — 흰 배경, 위쪽만 20px
  // 라운드, 어두운 스크림(`0x99000000`), `useRootNavigator: true`,
  // `EdgeInsets.all(AppTokens.s16)` 패딩, 20/w600 타이틀.
  //
  // 다른 두 시트는 콘텐츠가 많아 홈 인디케이터 안전영역과 자연히 떨어지지만,
  // 이 시트는 짧아서 그 여백 없이 그리면 마지막 줄(진행률 바 등)이
  // 홈 인디케이터에 바짝 붙어 "너무 낮아" 보인다 — `SafeArea(top: false)` +
  // 여유 여백으로 보정한다.
  void _showDetail(
    BuildContext context,
    BadgeProgress progress,
    bool signedIn,
  ) {
    final badge = progress.badge;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      barrierColor: const Color(0x99000000),
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.s16,
              AppTokens.s24,
              AppTokens.s16,
              AppTokens.s24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _BadgeMedal(
                      progress: progress,
                      showEarnedState: signedIn,
                      size: 64,
                      // 상세 시트는 미획득이어도 뱃지 원래 색을 그대로 보여준다 —
                      // 목록(그리드)에서만 투명도로 미획득을 표시한다.
                      forceFullColor: true,
                    ),
                    const SizedBox(width: AppTokens.s16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            badge.name,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              color: Colors.black,
                            ),
                          ),
                          Text(
                            '${_categoryLabel(badge.category)} · ${_gradeLabel(badge.badgeGrade)}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppTokens.s20),
                Text(
                  badge.description,
                  style: const TextStyle(fontSize: 15, height: 1.4, color: Colors.black),
                ),
                const SizedBox(height: AppTokens.s20),
                if (!signedIn)
                  const GuestLoginPromptCard(
                    icon: Icons.lock_outline,
                    title: '내 획득 여부는 로그인 후 확인',
                    message: '로그인하면 이 뱃지를 얻었는지, 얼마나 남았는지 볼 수 있어요.',
                  )
                else if (_isEarnedForDisplay(progress, signedIn)) ...[
                  Row(
                    children: [
                      Icon(Icons.check_circle, size: 18, color: scheme.primary),
                      const SizedBox(width: AppTokens.s8),
                      Text(
                        progress.earnedAt == null
                            ? '획득 완료'
                            : '${_formatDate(progress.earnedAt!)} 획득',
                        style: const TextStyle(fontSize: 14, color: Colors.black),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppTokens.s16),
                  // HI-08: 성취 직후를 놓쳤어도 나중에 자랑할 수 있어야 한다.
                  _BadgeShareButton(badgeId: badge.id),
                ]
                else ...[
                  Text(
                    progress.meetsThresholdLocally
                        ? '조건을 채운 것 같아요 — 서버 반영을 기다리는 중이에요.'
                        : '아직 획득하지 않았어요.',
                    style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
                  ),
                  if (progress.currentValue != null) ...[
                    const SizedBox(height: AppTokens.s12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppTokens.rPill),
                      child: LinearProgressIndicator(
                        value: progress.ratio,
                        minHeight: 8,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 획득한 뱃지의 공유 버튼(HI-08, 트리거 지점 #3).
///
/// 카드를 만들려면 카탈로그 정의가 아니라 **획득 행**([UserBadge])이 필요하다 —
/// 획득 시각·원본 러닝(경로)이 거기 있다. [BadgeProgress]는 카탈로그 + 진행률
/// 뷰모델이라 그 정보를 갖고 있지 않아서 여기서 한 번 찾는다.
///
/// 카드를 만들 수 없으면(획득 행 미로딩, 카탈로그 조인 누락) 버튼을 그리지
/// 않는다 — 눌러도 아무 일이 없는 버튼보다 없는 편이 낫다.
///
/// **일반 뱃지([BadgeEarnedCardData])·티어 승급([TierPromotionCardData])은
/// 공유하지 않는다**(2026-08-27, 사용자 요청) — 둘 다 풀페이지 축하
/// 애니메이션으로 끝나고 별도 공유 카드로 이어지지 않는다. PB만 남긴다.
class _BadgeShareButton extends ConsumerWidget {
  const _BadgeShareButton({required this.badgeId});

  final String badgeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final earned = ref.watch(userBadgesProvider).valueOrNull;
    if (earned == null) return const SizedBox.shrink();

    UserBadge? mine;
    for (final userBadge in earned) {
      if (userBadge.badgeId == badgeId) {
        mine = userBadge;
        break;
      }
    }
    if (mine == null) return const SizedBox.shrink();

    final card = ref.watch(shareCardForAchievementProvider(mine)).valueOrNull;
    if (card == null) return const SizedBox.shrink();
    if (card is BadgeEarnedCardData || card is TierPromotionCardData) {
      return const SizedBox.shrink();
    }

    return FilledButton.tonalIcon(
      onPressed: () => showShareCardSheet(context, card),
      icon: const Icon(Icons.ios_share),
      label: const Text('공유하기'),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(AppTokens.minTapTarget),
      ),
    );
  }
}

String _formatDate(DateTime dt) {
  final local = dt.toLocal();
  return '${local.year}.${local.month.toString().padLeft(2, '0')}.${local.day.toString().padLeft(2, '0')}';
}

/// 카테고리순으로 정렬된 리스트를 연속 구간별로 묶는다. 순수 함수.
List<List<BadgeProgress>> _groupByCategory(List<BadgeProgress> sorted) {
  final groups = <List<BadgeProgress>>[];
  for (final progress in sorted) {
    if (groups.isNotEmpty &&
        groups.last.first.badge.category == progress.badge.category) {
      groups.last.add(progress);
    } else {
      groups.add([progress]);
    }
  }
  return groups;
}

/// 섹션 헤더 — 카테고리 라벨 + 아이콘으로 "어떤 종류의 뱃지"인지 구분한다.
class _CategorySectionHeader extends StatelessWidget {
  const _CategorySectionHeader({required this.category});

  final BadgeCategory category;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(_categoryIcon(category), size: 16, color: const Color(0xFF9B9B9B)),
        const SizedBox(width: AppTokens.s4),
        Text(
          _categoryLabel(category),
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Color(0xFF9B9B9B),
          ),
        ),
      ],
    );
  }
}

/// 획득 요약 — **영구 뱃지**(한 번 얻으면 유지)와 **시즌 뱃지**(시즌 종료 시
/// 초기화)를 나눠서 각각 획득 개수를 보여준다. 두 축은 리셋 주기가 달라
/// 하나로 합산하면 "이번 시즌에 뭘 얼마나 모았는지"가 묻힌다(PRD §5.5, §8.5).
///
/// 시즌 뱃지는 **이번 시즌 인스턴스**(`badge.seasonId == Season.currentId()`)만
/// 센다 — 지난 시즌에 획득한 뱃지는 역대 기록(HI-06)의 몫이지 이번 시즌
/// 진행 현황이 아니다.
class _EarnedSummary extends StatelessWidget {
  const _EarnedSummary({
    required this.progressList,
    required this.loading,
  });

  final List<BadgeProgress> progressList;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final currentSeasonId = Season.currentId();

    final permanent = progressList
        .where((p) => p.badge.scope == BadgeScope.permanent)
        .toList();
    final seasonal = progressList
        .where((p) =>
            p.badge.scope == BadgeScope.seasonal &&
            p.badge.seasonId == currentSeasonId)
        .toList();

    return Container(
      padding: const EdgeInsets.all(AppTokens.s16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppTokens.rLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('내 뱃지',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppTokens.s16),
          _SummaryRow(
            label: '영구 뱃지',
            caption: '한 번 얻으면 계속 유지돼요',
            earned: permanent.where((p) => p.isEarned).length,
            total: permanent.length,
            color: scheme.primary,
            loading: loading,
          ),
          const SizedBox(height: AppTokens.s16),
          _SummaryRow(
            label: '시즌 뱃지',
            caption: seasonal.isEmpty
                ? '이번 시즌 뱃지가 아직 없어요'
                : '시즌이 끝나면 초기화돼요',
            earned: seasonal.where((p) => p.isEarned).length,
            total: seasonal.length,
            color: AppTokens.tierSpecial,
            loading: loading,
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.caption,
    required this.earned,
    required this.total,
    required this.color,
    required this.loading,
  });

  final String label;
  final String caption;
  final int earned;
  final int total;
  final Color color;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final ratio = total == 0 ? 0.0 : earned / total;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            if (loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text('$earned / $total',
                  style:
                      text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: AppTokens.s8),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppTokens.rPill),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: loading ? 0 : ratio),
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => LinearProgressIndicator(
              value: value,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
              color: color,
            ),
          ),
        ),
        const SizedBox(height: AppTokens.s4),
        Text(
          caption,
          style: text.bodySmall?.copyWith(color: const Color(0xFF9B9B9B)),
        ),
      ],
    );
  }
}

/// 실제 획득 여부 — 게스트에게는 항상 false(개인화 정보 비공개).
bool _isEarnedForDisplay(BadgeProgress progress, bool showEarnedState) =>
    showEarnedState && progress.isEarned;

class _BadgeTile extends StatelessWidget {
  const _BadgeTile({
    required this.progress,
    required this.showEarnedState,
    required this.onTap,
  });

  final BadgeProgress progress;

  /// false면(게스트) 획득/미획득 구분 없이 전부 중립 표현으로 그린다.
  final bool showEarnedState;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final isEarned = _isEarnedForDisplay(progress, showEarnedState);
    // 진행률 바는 로그인 + 미획득 + 추정치가 있을 때만(게스트/획득 완료엔 안 그린다).
    final showRatioBar = showEarnedState &&
        !isEarned &&
        progress.currentValue != null &&
        progress.ratio > 0;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.rLg),
      // 그리드 셀은 `childAspectRatio`로 콘텐츠보다 넉넉하게 잡혀 있다 —
      // `Column`이 `mainAxisSize.min`이라 안 그러면 셀 위쪽에 붙어 보인다.
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BadgeMedal(
              progress: progress,
              showEarnedState: showEarnedState,
              size: 72,
            ),
            const SizedBox(height: AppTokens.s8),
            Text(
              progress.badge.name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(
                fontWeight: isEarned ? FontWeight.w700 : FontWeight.w500,
                color: isEarned ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
            ),
            if (showRatioBar) ...[
              const SizedBox(height: AppTokens.s4),
              SizedBox(
                width: 48,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppTokens.rPill),
                  child: LinearProgressIndicator(
                    value: progress.ratio,
                    minHeight: 4,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 뱃지 메달 — 카테고리별 실제 아트(`assets/badges/{카테고리}/{등급}.svg`,
/// 등급별 색이 이미 입혀져 있다)를 그린다. 2026-08-26 기준 모든 카테고리에
/// 아트가 있어 Material 아이콘 폴백은 더 이상 필요 없다.
class _BadgeMedal extends StatelessWidget {
  const _BadgeMedal({
    required this.progress,
    required this.showEarnedState,
    required this.size,
    this.forceFullColor = false,
  });

  final BadgeProgress progress;
  final bool showEarnedState;
  final double size;

  /// true면 미획득이어도 투명도를 낮추지 않는다 — 상세 시트 전용
  /// (목록 그리드는 계속 투명도로 미획득을 표시한다).
  final bool forceFullColor;

  @override
  Widget build(BuildContext context) {
    final badge = progress.badge;
    final scheme = Theme.of(context).colorScheme;
    final active = _isEarnedForDisplay(progress, showEarnedState);
    final dimmed = !active && !forceFullColor;

    // 미획득 상태는 흑백이 아니라 **투명도만** 낮춘다 — 등급 색이 회색으로
    // 뭉개지지 않고 옅게라도 보여야 갤러리에서 등급을 가늠할 수 있다.
    final medal = SizedBox(
      width: size,
      height: size,
      child: Center(
        child: _BadgeArtwork(
          // 경로 규칙 정본은 `domain/badge_assets.dart` — 공유 카드와 공유한다.
          assetPath: badgeAssetPath(
            category: badge.category,
            badgeGrade: badge.badgeGrade,
          ),
          // 원본 뷰박스가 40×44(세로로 긴 방패) — 폭을 size에 맞추고 비율은 그대로 둔다.
          width: size,
          dimmed: dimmed,
        ),
      ),
    );

    if (!active) return medal;

    // 획득 뱃지는 살짝 튀어오르는 등장 연출 + 체크 배지로 성취를 강조한다.
    // 잠금 아이콘은 더 이상 그리지 않는다 — 미획득 상태는 위에서 투명도만으로 표현한다.
    return Stack(
      alignment: Alignment.center,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.85, end: 1),
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutBack,
          builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
          child: medal,
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surface),
            child: Icon(Icons.check_circle, size: size * 0.24, color: _checkColor(badge.badgeGrade)),
          ),
        ),
      ],
    );
  }
}

/// 등급별로 이미 채색된 뱃지 SVG 한 장. 미획득 상태는 흑백(그레이스케일)으로
/// 죽여서 "잠겨 있다"는 걸 전달한다 — 등급 색은 여전히 톤으로 짐작 가능해서
/// 완전 회색 원(예전 폴백 렌더링)보다 정보량이 많다.
class _BadgeArtwork extends StatelessWidget {
  const _BadgeArtwork({
    required this.assetPath,
    required this.width,
    required this.dimmed,
  });

  final String assetPath;
  final double width;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final svg = SvgPicture.asset(assetPath, width: width);
    if (!dimmed) return svg;
    return Opacity(opacity: 0.35, child: svg);
  }
}

// 아트 경로 규칙(`_categoryAssetFolder` / `_gradeAssetName`)은 2026-08-26
// `../domain/badge_assets.dart`로 옮겼다. 공유 카드(HI-08)가 **같은 메달**을
// 그려야 하는 두 번째 소비자가 되면서, 규칙이 두 벌 있으면 갤러리에서 본 메달과
// 인스타에 올라간 메달이 갈라질 수 있게 됐기 때문이다. 이 파일은 그 함수를
// 그대로 호출한다.

/// 획득 체크 배지 색상. 사용자 요청으로 platinum↔diamond만 서로 맞바꿔
/// 쓴다(2026-08-25) — 나머지 등급은 [_gradeColor]와 동일.
Color _checkColor(String badgeGrade) => switch (badgeGrade) {
      'platinum' => AppTokens.tierDiamond,
      'diamond' => AppTokens.tierPlatinum,
      _ => _gradeColor(badgeGrade),
    };

/// `Badge.badgeGrade`는 String(카탈로그 운영 중 등급이 늘 수 있음 — `badge.dart`
/// doc 참고)이라 모르는 값이 오면 outline 색으로 안전하게 폴백한다.
Color _gradeColor(String badgeGrade) => switch (badgeGrade) {
      'bronze' => AppTokens.tierBronze,
      'silver' => AppTokens.tierSilver,
      'gold' => AppTokens.tierGold,
      'platinum' => AppTokens.tierPlatinum,
      'diamond' => AppTokens.tierDiamond,
      'special' => AppTokens.tierSpecial,
      _ => const Color(0xFF9B9B9B),
    };

String _gradeLabel(String badgeGrade) => switch (badgeGrade) {
      'bronze' => '브론즈',
      'silver' => '실버',
      'gold' => '골드',
      'platinum' => '플래티넘',
      'diamond' => '다이아몬드',
      'special' => '스페셜',
      _ => badgeGrade,
    };

/// `docs/badge-catalog.csv`의 `category` 열(한글 라벨, 16종)과 1:1 대응 —
/// CSV가 정본이므로 이 표기를 그대로 따른다.
String _categoryLabel(BadgeCategory category) => switch (category) {
      BadgeCategory.cumulativeDistance => '누적거리',
      BadgeCategory.cumulativeCount => '누적횟수',
      BadgeCategory.longestStreak => '최장스트릭',
      BadgeCategory.personalBest => 'PB갱신',
      BadgeCategory.singleSessionDistance => '단일세션거리',
      BadgeCategory.timeOfDayWeekday => '시간대요일',
      BadgeCategory.routeExploration => '경로탐험',
      BadgeCategory.specialDay => '특별한날',
      BadgeCategory.paceSpeed => '페이스속도',
      BadgeCategory.deviceIntegration => '기기연동',
      BadgeCategory.level => '레벨',
      BadgeCategory.seasonTier => '시즌티어달성',
      BadgeCategory.seasonWeeklyRank => '시즌주간랭킹',
      BadgeCategory.seasonEvent => '시즌한정이벤트',
    };

IconData _categoryIcon(BadgeCategory category) => switch (category) {
      BadgeCategory.cumulativeDistance => Icons.route,
      BadgeCategory.cumulativeCount => Icons.repeat,
      BadgeCategory.longestStreak => Icons.local_fire_department,
      BadgeCategory.personalBest => Icons.emoji_events,
      BadgeCategory.singleSessionDistance => Icons.directions_run,
      BadgeCategory.timeOfDayWeekday => Icons.schedule,
      BadgeCategory.routeExploration => Icons.explore,
      BadgeCategory.specialDay => Icons.cake,
      BadgeCategory.paceSpeed => Icons.speed,
      BadgeCategory.deviceIntegration => Icons.watch,
      BadgeCategory.level => Icons.military_tech,
      BadgeCategory.seasonTier => Icons.workspace_premium,
      BadgeCategory.seasonWeeklyRank => Icons.leaderboard,
      BadgeCategory.seasonEvent => Icons.celebration,
    };

class _GallerySkeleton extends StatelessWidget {
  const _GallerySkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GridView.builder(
      padding: const EdgeInsets.all(AppTokens.s16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 132,
        mainAxisSpacing: AppTokens.s12,
        crossAxisSpacing: AppTokens.s12,
        childAspectRatio: 0.95,
      ),
      itemCount: 9,
      itemBuilder: (_, __) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: AppTokens.s8),
          Container(
            width: 56,
            height: 10,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(AppTokens.rSm),
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryError extends StatelessWidget {
  const _GalleryError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off,
              size: 40, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: AppTokens.s12),
          const Text('뱃지를 불러오지 못했어요'),
          const SizedBox(height: AppTokens.s12),
          OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
        ],
      ),
    );
  }
}
