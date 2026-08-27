import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../features/sharing/presentation/widgets/achievement_celebration.dart';
import '../auth/auth_providers.dart';

/// 바텀 네비게이션 셸 — **2026-08-21 4탭 개편**(Figma 프레임 `48:872` 반영),
/// **같은 날 Home 프레임(`55:1118`) 반영 때 3번째 탭 라벨을 "기록"→"활동"으로
/// 변경**(라우트 자체는 `/history`로 동일 — 표시 라벨만 바뀜, 화면 구조는
/// `history_page.dart` 참고).
///
/// 홈 / 러닝 / 활동 / 마이 4탭. 기존 랭킹·뱃지 독립 탭은 없앴다 — 랭킹은 홈
/// (티어 카드 아래), 뱃지는 활동 화면의 하위 탭으로 흡수됐다(각 화면 참고).
///
/// 게스트 표시: 마이(프로필) 탭 아이콘에만 "로그인" 배지를 붙인다. 홈/활동은
/// 게스트도 열리므로(`RouteAccess`) 배지를 붙이지 않는다 — 탭마다 배지를
/// 붙이면 "왜 여긴 되고 저긴 안 되는지" 신호가 오히려 흐려진다.
///
/// **네비게이션 바 자체는 Material `NavigationBar`를 쓰지 않는다.** Figma
/// 디자인이 화면 폭 전체를 채우는 기본 바가 아니라, 좌우 여백을 두고 떠 있는
/// 흰색 알약(pill) 하나 — 옅은 테두리(#EEE) + 완전 라운드(1000px), 그 안의
/// 선택된 항목만 브랜드 그린 톤온톤 배경(`rgba(0,200,75,0.1)`) + 아주 옅은
/// 그림자로 도드라진다. Material `NavigationBar`의 기본 크롬(화면 폭 전체,
/// 인디케이터 필)으로는 이 톤을 재현할 수 없어 직접 그렸다. 아이콘도 Figma가
/// 내려준 lucide SVG 원본(`assets/icons/nav_*.svg`)을 그대로 쓴다(Material
/// 아이콘 대체 아님).
///
/// **2026-08-24 Figma Home 프레임(`55:1118`, 노드 `55:1404`) 재동기화**:
/// 선택된 탭은 브랜드 그린(#00C84B, 아이콘+텍스트+옅은 배경), 선택 안 된
/// 탭은 `#9B9B9B` 회색 — 이전엔 "선택 시 검정 + 흰 배경, 알약 자체는
/// #F6F6F6"였는데, Home 프레임을 다시 확인하니 그새 그린 강조 스타일로
/// 갱신돼 있었다(같은 파일의 활동 프레임 `82:722`은 아직 예전 스타일이 남아
/// 있어 두 프레임이 서로 다르다 — 더 최근에 선택/확인된 Home 쪽을 기준으로
/// 통일한다). 알약 배경도 `#F6F6F6`→흰색으로 바뀌어 `#F8F8F8` 페이지
/// 배경과의 대비가 커져, 별도 그림자를 더하지 않아도 충분히 "떠 있는"
/// 느낌이 난다.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({required this.shell, super.key});

  final StatefulNavigationShell shell;

  /// 이 바가 실제로 화면에서 차지하는 높이(알약 + 좌우/상하 여백, 기기
  /// 세이프에어리어 포함) — **상수로 어림하지 않고 실제 렌더 크기를 매
  /// 프레임 측정해서 채운다.** 폰트 메트릭·접근성 텍스트 크기·기기별
  /// 세이프에어리어가 기기마다 달라 고정값(예: "알약 61 + 세이프에어리어
  /// 34")은 실제 렌더 결과와 어긋나기 쉽다(실기기에서 여백이 계산보다 훨씬
  /// 커 보인다는 사용자 피드백으로 확인) — 그래서 측정값 하나만 신뢰한다.
  ///
  /// 각 탭의 스크롤 콘텐츠는 끝에 `ValueListenableBuilder(valueListenable:
  /// AppShell.measuredHeight, ...)`로 이 값만큼 여백을 더해야 마지막 항목이
  /// (불투명한) 알약 뒤에 가려지지 않는다. `extendBody: true`라 body는 이
  /// 바가 떠 있다는 걸 전혀 모르기 때문이다.
  static final ValueNotifier<double> measuredHeight = ValueNotifier<double>(96);

  static const _destinations = <_NavDestination>[
    _NavDestination(asset: 'assets/icons/nav_home.svg', label: '홈'),
    _NavDestination(asset: 'assets/icons/nav_running.svg', label: '러닝'),
    _NavDestination(asset: 'assets/icons/nav_activity.svg', label: '활동'),
    _NavDestination(asset: 'assets/icons/nav_profile.svg', label: '마이'),
  ];

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final _barKey = GlobalKey();

  void _measure() {
    final size = _barKey.currentContext?.findRenderObject() as RenderBox?;
    final height = size?.size.height;
    if (height != null && height != AppShell.measuredHeight.value) {
      AppShell.measuredHeight.value = height;
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(isAuthenticatedProvider);

    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());

    // 성취 축하 연출(HI-10)을 셸 수준에 매단다 — 서버 판정은 업로드 후
    // 비동기라 사용자가 이미 다른 탭으로 옮긴 뒤에 뱃지가 도착할 수 있고,
    // 오프라인 러닝은 며칠 뒤 동기화 시점에 도착한다. 요약 화면 하나에만
    // 연출을 달면 그 경우들이 조용히 사라진다.
    return AchievementCelebrationHost(
      child: Scaffold(
        body: widget.shell,
        extendBody: true,
        bottomNavigationBar: DecoratedBox(
          key: _barKey,
          // Figma "Nav bar": 콘텐츠가 스크롤되며 바 뒤로 지나갈 때 경계가
          // 갑자기 잘리지 않도록 아래(불투명)→위(투명)로 옅어지는 스크림.
          // 2026-08-24: 스크림 색을 순백에서 #F8F8F8로 바꿨다 — 화면 배경
          // 자체가 순백이 아니라 #F8F8F8(Home `55:1118`/활동 `82:722` 둘 다
          // 확인됨)이라, 순백 스크림을 쓰면 바 주변에 옅은 흰 테두리처럼
          // 배경과 어긋나 보였다.
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xFFF8F8F8), Color(0x00F8F8F8)],
            ),
          ),
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xFFEEEEEE)),
                borderRadius: BorderRadius.circular(1000),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  for (var i = 0; i < AppShell._destinations.length; i++)
                    Expanded(
                      child: _NavItem(
                        destination: AppShell._destinations[i],
                        // 마이 탭에만 게스트 배지 — 유일한 개인 정보 전용 탭.
                        showGuestBadge: i == 3 && !signedIn,
                        selected: widget.shell.currentIndex == i,
                        onTap: () => widget.shell.goBranch(
                          i,
                          initialLocation: i == widget.shell.currentIndex,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavDestination {
  const _NavDestination({required this.asset, required this.label});

  final String asset;
  final String label;
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.showGuestBadge,
    required this.onTap,
  });

  final _NavDestination destination;
  final bool selected;
  final bool showGuestBadge;
  final VoidCallback onTap;

  static const _unselectedColor = Color(0xFF9B9B9B);
  static const _selectedColor = Color(0xFF00C84B);

  @override
  Widget build(BuildContext context) {
    final color = selected ? _selectedColor : _unselectedColor;

    Widget icon = SvgPicture.asset(
      destination.asset,
      width: 24,
      height: 24,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
    if (showGuestBadge) {
      icon = Badge(label: const Text('로그인'), child: icon);
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(1000),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0x1A00C84B) : Colors.transparent,
          borderRadius: BorderRadius.circular(1000),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 5,
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(height: 4),
            Text(
              destination.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
