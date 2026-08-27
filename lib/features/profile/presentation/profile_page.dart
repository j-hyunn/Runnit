import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_shell.dart';
import '../../../models/models.dart';
import '../../home/presentation/widgets/ranking_widgets.dart';
import '../../tracking/presentation/wearable_connect_page.dart';

/// 마이페이지 — **로그인 필수 라우트**(라우터 가드가 게스트를 `/login`으로 보낸다).
///
/// **2026-08-25 사용자가 캡처해 준 Figma 스크린샷 반영**(MCP 호출 한도 초과로
/// `get_design_context` 대신 이미지로 전달받음 — 정확한 hex/spacing 값은 없어
/// 앱 전역에서 이미 쓰는 토큰(배경 `#F8F8F8`, 카드 흰색+라운드 20+옅은 그림자,
/// 구분선 `#EAEAEA`)을 그대로 맞춰 재현했다. 알림/고객센터/공지사항/FAQ/문의/약관
/// 항목은 아직 목적 화면이 없어 검색·알림 아이콘과 같은 "준비 중" 자리표시자로
/// 처리한다. 알림 설정 아이콘 등 일부는 Figma가 요구하는 정확한 lucide 아이콘
/// 대신 Material 아이콘으로 임시 대체했다 — Figma 접근이 복구되면 실제 벡터로
/// 교체 필요.
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider).valueOrNull;
    final email = ref.watch(authStateProvider).email;
    final signingOut = ref.watch(authControllerProvider).isLoading;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _ProfileHeader(),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppTokens.s16,
                        0,
                        AppTokens.s16,
                        AppTokens.s16,
                      ),
                      child: _ProfileCard(profile: profile, email: email),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppTokens.s16),
                      child: _MenuCard(
                        items: [
                          _MenuItemData(
                            icon: Icons.watch_outlined,
                            label: '웨어러블 연동',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const WearableConnectPage(),
                              ),
                            ),
                          ),
                          const _MenuItemData(
                            asset: 'assets/icons/bell.svg',
                            label: '알림 설정',
                          ),
                          const _MenuItemData(
                            asset: 'assets/icons/headset.svg',
                            label: '고객 센터',
                          ),
                          const _MenuItemData(
                            asset: 'assets/icons/megaphone.svg',
                            label: '공지사항',
                          ),
                          const _MenuItemData(
                            asset: 'assets/icons/message-circle-question-mark.svg',
                            label: 'FAQ',
                          ),
                          const _MenuItemData(
                            asset: 'assets/icons/message-square-check.svg',
                            label: '문의하기',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: AppTokens.s16)),
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: AppTokens.s16),
                      child: _MenuCard(
                        items: [
                          _MenuItemData(
                            asset: 'assets/icons/file-text.svg',
                            label: '이용 약관',
                          ),
                          _MenuItemData(
                            asset: 'assets/icons/user-shield.svg',
                            label: '개인정보 처리방침',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: AppTokens.s16)),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppTokens.s16),
                      child: _MenuCard(
                        items: [
                          _MenuItemData(
                            asset: 'assets/icons/log-out.svg',
                            label: '로그아웃',
                            loading: signingOut,
                            onTap: signingOut
                                ? null
                                : () => ref
                                    .read(authControllerProvider.notifier)
                                    .signOut(),
                          ),
                        ],
                      ),
                    ),
                  ),
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

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      // 홈 헤더(Figma `55:1179`, px-24 py-15)와 통일 — 2026-08-25.
      padding: EdgeInsets.fromLTRB(24, 15, 24, 15),
      // 34로 고정 — 다른 헤더와 같은 이유(`_ActivityHeader` 참고, 24로 두면
      // 24px 타이틀 텍스트 줄높이가 넘쳐서 잘렸다).
      child: SizedBox(
        height: 34,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '마이페이지',
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

/// Figma "My profile" 카드 — 아바타 + 이름/이메일 + 설정 아이콘, 아래 티어/러닝/포인트 3분할.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile, required this.email});

  final AppUser? profile;
  final String? email;

  @override
  Widget build(BuildContext context) {
    final tier = profile?.currentTier;
    final label = profile?.label ?? 'My profile';
    final runCount = profile?.totalRunCount ?? 0;
    final points = profile?.totalXp ?? 0;

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const ProfileCircle(size: 64),
              const SizedBox(width: AppTokens.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black),
                    ),
                    if (email != null) ...[
                      const SizedBox(height: AppTokens.s4),
                      Text(
                        email!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Color(0xFF616161)),
                      ),
                    ],
                  ],
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(AppTokens.rPill),
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('설정 화면은 준비 중이에요')),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppTokens.s4),
                  child: SvgPicture.asset(
                    'assets/icons/settings.svg',
                    width: 24,
                    height: 24,
                    colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.s24),
          Row(
            children: [
              Expanded(
                child: _ProfileStat(
                  label: '티어',
                  value: tier == null ? '-' : TierPill.labelFor(tier),
                  valueColor: tier == null ? Colors.black : TierPill.colorFor(tier),
                ),
              ),
              Expanded(
                child: _ProfileStat(label: '러닝', value: '$runCount'),
              ),
              Expanded(
                child: _ProfileStat(label: '포인트', value: points > 0 ? '$points' : '-'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: Color(0xFF616161))),
        const SizedBox(height: AppTokens.s8),
        Text(
          value,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: valueColor ?? Colors.black),
        ),
      ],
    );
  }
}

class _MenuItemData {
  const _MenuItemData({
    this.asset,
    this.icon,
    required this.label,
    this.onTap,
    this.loading = false,
  }) : assert(asset != null || icon != null, 'asset 또는 icon 중 하나는 있어야 한다');

  /// lucide SVG 원본(`assets/icons/*.svg`) 경로.
  final String? asset;

  /// [asset]에 맞는 lucide 아이콘이 없을 때만 쓰는 Material 아이콘 대체.
  final IconData? icon;

  final String label;
  final VoidCallback? onTap;
  final bool loading;
}

/// Figma의 흰 카드 안 메뉴 목록 — 아이콘 + 라벨 + chevron, 행 사이 구분선.
class _MenuCard extends StatelessWidget {
  const _MenuCard({required this.items});

  final List<_MenuItemData> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 2.5),
        ],
      ),
      child: Column(
        children: [
          for (final item in items) _MenuRow(item: item),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.item});

  final _MenuItemData item;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: item.onTap ??
          () => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${item.label} 기능은 준비 중이에요')),
              ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.s16, vertical: AppTokens.s16),
        child: Row(
          children: [
            if (item.asset != null)
              SvgPicture.asset(
                item.asset!,
                width: 24,
                height: 24,
                colorFilter: const ColorFilter.mode(Color(0xFF616161), BlendMode.srcIn),
              )
            else
              Icon(item.icon, size: 24, color: const Color(0xFF616161)),
            const SizedBox(width: AppTokens.s12),
            Expanded(
              child: Text(
                item.label,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.black),
              ),
            ),
            if (item.loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
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
