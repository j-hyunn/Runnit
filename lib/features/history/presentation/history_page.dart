import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_shell.dart';
import '../../../models/models.dart';
import '../../auth/presentation/widgets/guest_login_prompt.dart';
import '../../gamification/presentation/badge_gallery_page.dart';
import '../data/history_providers.dart';
import 'run_detail_page.dart';
import 'run_history_list_page.dart';
import 'widgets/monthly_chart.dart';
import 'widgets/run_tile.dart';

/// 활동 화면 — **게스트 허용 라우트**(`RouteAccess.guestAllowedPrefixes`).
///
/// **2026-08-24 Figma "Activities" 프레임 반영**(파일 `97770fBbX9OAcPkEdZxiIP`,
/// 노드 `82:722`). 커스텀 헤더("활동" + 검색/알림 자리표시자, 홈과 같은
/// 패턴) + 언더라인 탭 전환(기록/뱃지) — Material `TabBar`의 기본 크롬
/// 대신 홈/전체 랭킹과 같은 결로 직접 그렸다.
///
/// 두 탭의 게스트 정책이 **다르다**(라우트는 하나지만 탭마다 다르게 처리):
/// - "기록": 개인 러닝 통계·목록이라 로그인 필요 — 게스트에게는 [GuestLoginGate].
/// - "뱃지": 카탈로그는 공개, 개인화(획득 여부)만 [BadgeGalleryBody] 내부에서 숨김.
///
/// "기록" 탭 구성(Figma 순서 그대로):
/// 1. 시즌 필(현재 시즌만 표시 — [FullRankingPage]와 같은 이유로 지난 시즌은
///    선택 불가 "준비 중").
/// 2. 이번 시즌 누적 거리 + 티어 진행률 바 — 홈 "이번 시즌 기록" 카드와
///    **같은 출처**(`AppUser.seasonDistanceMeters`/`tierProgress`).
/// 3. 이번 달 일별 거리 막대그래프 + 러닝 횟수/평균 페이스/시간 요약 —
///    서버에 대응 캐시가 없어 로컬 기록에서 직접 집계(`history_providers.dart`).
/// 4. "최근 기록"(최신 3건) + "전체 보기" → [RunHistoryListPage].
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _ActivityHeader(),
            _ActivityTabBar(selected: _tab, onSelect: (i) => setState(() => _tab = i)),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: const [
                  _RunHistoryTab(),
                  BadgeGalleryBody(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityHeader extends StatelessWidget {
  const _ActivityHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      // 홈 헤더(Figma `55:1179`, px-24 py-15)와 통일 — 2026-08-25.
      padding: EdgeInsets.fromLTRB(24, 15, 24, 15),
      // 24px 타이틀 텍스트의 실제 줄높이(Pretendard 기준 폰트 크기의 약
      // 1.4배)를 담을 수 있도록 34로 고정 — 24로 두면 글자가 잘렸다.
      // 네 탭 헤더 모두 같은 값을 써서 높이도 통일한다.
      child: SizedBox(
        height: 34,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '활동',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: Colors.black),
            ),
            Row(
              children: [
                _HeaderIconButton(asset: 'assets/icons/search.svg', label: '검색'),
                SizedBox(width: AppTokens.s12),
                _HeaderIconButton(asset: 'assets/icons/bell.svg', label: '알림'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 검색/알림 둘 다 아직 목적 화면이 없다 — 홈 헤더와 같은 자리표시자 처리.
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

class _ActivityTabBar extends StatelessWidget {
  const _ActivityTabBar({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  static const _labels = ['기록', '뱃지'];

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFECECEC))),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _labels.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => onSelect(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: selected == i ? const Color(0xFF00C84B) : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    _labels[i],
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.black),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RunHistoryTab extends ConsumerWidget {
  const _RunHistoryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(isAuthenticatedProvider);

    if (!signedIn) {
      return const GuestLoginGate(
        icon: Icons.bar_chart_outlined,
        title: '내 활동 통계는 로그인 후 볼 수 있어요',
        message: '카카오로 로그인하면 이번 시즌 기록과 최근 러닝 목록을 확인할 수 있어요.',
      );
    }

    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(AppTokens.s16, AppTokens.s16, AppTokens.s16, 0),
            child: _SeasonSummarySection(),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: AppTokens.s16),
            child: _RecentRunsSection(),
          ),
        ),
        SliverToBoxAdapter(
          child: ValueListenableBuilder<double>(
            valueListenable: AppShell.measuredHeight,
            builder: (context, height, _) => SizedBox(height: height),
          ),
        ),
      ],
    );
  }
}

/// Figma `85:1217`("Frame 47") — 시즌 필 + 누적 거리/티어 진행률 + 이번 달 그래프 + 요약.
class _SeasonSummarySection extends ConsumerWidget {
  const _SeasonSummarySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider).valueOrNull;
    final stats = ref.watch(monthlyActivityStatsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SeasonPill(),
        const SizedBox(height: AppTokens.s16),
        if (profile == null)
          const SizedBox(height: 260)
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                Formatters.km(profile.seasonDistanceMeters, fractionDigits: 1),
                style: const TextStyle(fontSize: 50, fontWeight: FontWeight.bold, color: Colors.black, height: 1),
              ),
              const SizedBox(width: AppTokens.s4),
              const Text(
                'km',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF616161)),
              ),
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
            profile.remainingToNextTierMeters == null
                ? '최고 티어예요 — 이번 시즌 끝까지 순위로 경쟁해요.'
                : '다음 티어까지 ${Formatters.km(profile.remainingToNextTierMeters!, fractionDigits: 1)}km',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF616161)),
          ),
          const SizedBox(height: AppTokens.s24),
          MonthlyBarChart(dailyDistanceMeters: stats.dailyDistanceMeters),
          const SizedBox(height: AppTokens.s24),
          Row(
            children: [
              Expanded(child: _SummaryStat(label: '러닝', value: '${stats.runCount}')),
              const SizedBox(width: AppTokens.s24),
              Expanded(child: _SummaryStat(label: '평균 페이스', value: Formatters.pace(stats.avgPaceSecPerKm))),
              const SizedBox(width: AppTokens.s24),
              Expanded(child: _SummaryStat(label: '시간', value: Formatters.duration(stats.totalMovingSeconds))),
            ],
          ),
        ],
      ],
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Color(0xFF616161))),
        const SizedBox(height: AppTokens.s8),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.black)),
      ],
    );
  }
}

/// Figma `85:1093`("Pill 3") — 현재는 현재 시즌만 실제 데이터가 있어(지난
/// 시즌 전체 스냅샷을 담는 백엔드가 없음, [FullRankingPage]와 동일 사유)
/// 탭하면 안내만 준다.
class _SeasonPill extends StatelessWidget {
  const _SeasonPill();

  @override
  Widget build(BuildContext context) {
    final label = Season.currentId().replaceFirst('-', ' ');

    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.rPill),
      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('지난 시즌 통계는 아직 지원하지 않아요')),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.s12, vertical: AppTokens.s8),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F3F3),
          borderRadius: BorderRadius.circular(AppTokens.rPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF9B9B9B))),
            const SizedBox(width: AppTokens.s4),
            const Icon(Icons.keyboard_arrow_down, size: 16, color: Color(0xFF9B9B9B)),
          ],
        ),
      ),
    );
  }
}

/// Figma `85:1253`("Ranking") — "최근 기록" 미리보기(최신 3건) + "전체 보기".
class _RecentRunsSection extends ConsumerWidget {
  const _RecentRunsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentRunsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '최근 기록',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black),
        ),
        const SizedBox(height: AppTokens.s8),
        if (recent.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppTokens.s24),
            child: Center(child: Text('아직 기록이 없어요. 첫 러닝을 시작해 보세요!')),
          )
        else
          for (var i = 0; i < recent.length; i++) ...[
            if (i > 0) const RunTileDivider(),
            RunHistoryTile(
              record: recent[i],
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RunDetailPage(runId: recent[i].id),
                ),
              ),
            ),
          ],
        const SizedBox(height: AppTokens.s8),
        InkWell(
          borderRadius: BorderRadius.circular(AppTokens.rPill),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const RunHistoryListPage()),
          ),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppTokens.s12),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F1F1),
              border: Border.all(color: const Color(0xFFEAEAEA)),
              borderRadius: BorderRadius.circular(AppTokens.rPill),
            ),
            child: const Text(
              '전체 보기',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.black),
            ),
          ),
        ),
      ],
    );
  }
}
