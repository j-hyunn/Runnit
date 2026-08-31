// Material의 `Badge` 위젯과 도메인 모델 `Badge`가 이름 충돌하므로 위젯 쪽을 숨긴다.
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/models.dart';
import '../../gamification/presentation/widgets/badge_medal_art.dart';
import '../../home/presentation/widgets/ranking_widgets.dart';
import '../data/other_profile_providers.dart';
import 'widgets/profile_scaffold.dart';

/// AC-03 타인 프로필 조회 — 랭킹에서 진입한다(`/users/:userId`).
///
/// ## 노출 범위는 여기서 **끝난다**
/// PRD §5.8 AC-03: 현재 티어 · 시즌 진행률 · 획득 뱃지 · 누적 거리/횟수/레벨 ·
/// 역대 최고 티어. 그 외에는 아무것도 그리지 않는다.
///
/// ⚠️ **`profiles`는 전 컬럼 공개 SELECT라 모델에는 개인 설정까지 실려 온다** —
/// `weightKg` / `heightCm` / `birthDate` / `weeklyGoalKm` / 이메일. 서버가
/// 막아주지 않으므로 **렌더링하지 않는 것이 유일한 방어선**이다
/// (`data/other_profile_providers.dart` 파일 주석, architect 문서 §2.1).
/// 이 화면에 필드를 추가할 때 그 목록을 다시 확인할 것.
///
/// 개별 러닝 목록도 노출하지 않는다. `runs` RLS(`runs_select_own`)가 실제로
/// 막고 있어서 조회해도 0건이 오고, 그러면 화면에 "기록 없음"이라는 **거짓말**이
/// 뜬다 — 그래서 provider 자체를 만들지 않았다.
///
/// ## realtime을 붙이지 않는다
/// `user_badges`는 realtime publication에 들어 있고, 마이그레이션 55의 공개
/// SELECT 정책 때문에 **타인의 뱃지 발급 이벤트도 구독자에게 도달**한다.
/// 여기서 구독하면 남이 뱃지를 딸 때마다 이 화면이 재조회한다. 1회성 조회를
/// 유지할 것(backend 문서 §4, architect 문서 §4).
class UserProfilePage extends ConsumerStatefulWidget {
  const UserProfilePage({super.key, required this.userId});

  final String userId;

  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage> {
  /// 본인 프로필로 리다이렉트를 한 번만 예약하기 위한 래치. 빌드마다 예약하면
  /// 프레임마다 `go`가 쌓인다.
  bool _redirected = false;

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(currentUserIdProvider);

    // 본인 id로 들어온 경우 → 이 화면을 스택에서 걷어낸다. 정상 진입점(랭킹
    // 행)은 이미 본인 행을 갈라내 여기로 보내지 않으므로(2026-08-31 QA F-1),
    // 이 분기는 딥링크·잘못된 push 대비 방어 코드다. 홈 브랜치 스택에
    // 이 페이지가 남는 것을 막기 위해, 되돌아갈 곳이 있으면 pop 하고
    // 없을 때만 마이 탭으로 전환한다.
    if (myId != null && myId == widget.userId) {
      if (!_redirected) {
        _redirected = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final router = GoRouter.maybeOf(context);
          if (router == null) return; // 라우터 밖(테스트 등) — 방어 분기가 할 일 없음
          if (router.canPop()) {
            router.pop();
          } else {
            context.go(Routes.profile);
          }
        });
      }
      return const ProfileScaffold(
        title: '프로필',
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final async = ref.watch(userProfileProvider(widget.userId));

    return ProfileScaffold(
      title: '프로필',
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => _Retry(
          message: '프로필을 불러오지 못했어요',
          onRetry: () => ref.invalidate(userProfileProvider(widget.userId)),
        ),
        data: (profile) {
          if (profile == null) {
            // 탈퇴했거나 없는 사용자. 랭킹 캐시가 잠깐 뒤처지면 실제로 일어난다.
            return const _Empty(message: '찾을 수 없는 사용자예요');
          }
          return _Body(profile: profile);
        },
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.profile});

  final AppUser profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badgesAsync = ref.watch(userBadgesByIdProvider(profile.id));
    final bestTier = ref.watch(bestTierOfProvider(profile.id));

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.s16,
        0,
        AppTokens.s16,
        AppTokens.s32,
      ),
      children: [
        _IdentityCard(profile: profile, bestTier: bestTier),
        const SizedBox(height: AppTokens.s16),
        _SeasonCard(profile: profile),
        const SizedBox(height: AppTokens.s16),
        _BadgesCard(
          badgesAsync: badgesAsync,
          onRetry: () => ref.invalidate(userBadgesByIdProvider(profile.id)),
        ),
      ],
    );
  }
}

/// 아바타 + 표시이름 + 누적 요약 3분할 + 역대 최고 티어.
///
/// 3분할은 마이페이지 `_ProfileCard`와 **같은 시각 언어**지만 항목이 다르다 —
/// 거기는 티어/러닝/레벨이고, 여기는 시즌 카드가 티어를 따로 크게 보여주므로
/// 그 자리를 누적 거리로 바꿨다(AC-03 수용 기준의 "누적 거리/횟수/레벨").
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.profile, required this.bestTier});

  final AppUser profile;
  final Tier? bestTier;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProfileCircle(size: 64, imageUrl: profile.avatarUrl),
              const SizedBox(width: AppTokens.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: AppTokens.s4),
                    // 이메일 자리에 **아이디(핸들)**를 둔다. 이메일은 타인에게
                    // 절대 노출하지 않는다(§노출 범위).
                    Text(
                      '@${profile.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF616161),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.s24),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: '누적 거리',
                  value:
                      '${Formatters.km(profile.totalDistanceMeters, fractionDigits: 1)}km',
                ),
              ),
              Expanded(
                child: _Stat(label: '러닝', value: '${profile.totalRunCount}'),
              ),
              Expanded(
                child: _Stat(label: '레벨', value: 'Lv.${profile.level}'),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.s16),
          const Divider(height: 1, color: Color(0xFFEEEEEE)),
          const SizedBox(height: AppTokens.s16),
          Row(
            children: [
              const Text(
                '역대 최고 티어',
                style: TextStyle(fontSize: 14, color: Color(0xFF616161)),
              ),
              const Spacer(),
              if (bestTier == null)
                // 끝난 시즌이 아직 없거나 전부 무효인 경우 — "없음"이 아니라
                // 아직 만들어지지 않았다는 뜻이라 문구로 구분한다(TI-09).
                const Text(
                  '아직 없어요',
                  style: TextStyle(fontSize: 14, color: Color(0xFF9B9B9B)),
                )
              else
                TierPill(tier: bestTier!, iconSize: 20, fontSize: 14),
            ],
          ),
        ],
      ),
    );
  }
}

/// 현재 티어 + 시즌 진행률. 홈의 시즌 카드와 같은 규격(네온 그린 11px 바)이다.
class _SeasonCard extends StatelessWidget {
  const _SeasonCard({required this.profile});

  final AppUser profile;

  @override
  Widget build(BuildContext context) {
    final remaining = profile.remainingToNextTierMeters;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '이번 시즌',
            style: TextStyle(fontSize: 12, color: Color(0xFF616161)),
          ),
          const SizedBox(height: AppTokens.s8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                Formatters.km(profile.seasonDistanceMeters, fractionDigits: 1),
                style: const TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                  height: 1,
                ),
              ),
              const SizedBox(width: AppTokens.s4),
              const Padding(
                padding: EdgeInsets.only(bottom: 2),
                child: Text(
                  'km',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF616161),
                  ),
                ),
              ),
              const Spacer(),
              TierPill(
                tier: profile.currentTier,
                iconSize: 24,
                fontSize: 16,
                background: false,
              ),
            ],
          ),
          const SizedBox(height: AppTokens.s16),
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
                ? '최고 티어에 도달했어요'
                : '다음 티어까지 ${Formatters.km(remaining, fractionDigits: 1)}km',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Color(0xFF616161),
            ),
          ),
        ],
      ),
    );
  }
}

/// 획득 뱃지 그리드 — **획득분만**. 미획득/진행률은 그리지 않는다.
///
/// 본인 갤러리(`badgeProgressListProvider`)와 달리 카탈로그와 합치지 않는
/// 이유는 두 가지다: (1) 진행률을 계산할 근거 데이터(`GamificationStats`)를
/// 타인에 대해서는 얻을 수 없고, (2) 얻을 수 있더라도 남의 미달성을 회색
/// 아이콘으로 전시하는 화면이 된다.
class _BadgesCard extends StatelessWidget {
  const _BadgesCard({required this.badgesAsync, required this.onRetry});

  final AsyncValue<List<UserBadge>> badgesAsync;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '획득 뱃지',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const Spacer(),
              if (badgesAsync.hasValue)
                Text(
                  '${badgesAsync.requireValue.length}개',
                  style: const TextStyle(fontSize: 14, color: Color(0xFF616161)),
                ),
            ],
          ),
          const SizedBox(height: AppTokens.s12),
          badgesAsync.when(
            loading: () => const _BadgeGridSkeleton(),
            error: (_, __) => _Retry(
              message: '뱃지를 불러오지 못했어요',
              onRetry: onRetry,
            ),
            data: (badges) {
              // 카탈로그 조인이 빠진 행(`badge == null`)은 그릴 수 없다 —
              // 카테고리·등급을 모르면 어떤 아트를 쓸지 정할 수 없다.
              final drawable =
                  badges.where((b) => b.badge != null).toList(growable: false);
              if (drawable.isEmpty) {
                return const _Empty(message: '아직 획득한 뱃지가 없어요');
              }
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithMaxCrossAxisExtent(
                  // 갤러리와 같은 규격 — 화면 폭에 따라 3~5열.
                  maxCrossAxisExtent: 132,
                  mainAxisSpacing: AppTokens.s12,
                  crossAxisSpacing: AppTokens.s12,
                  childAspectRatio: 0.85,
                ),
                itemCount: drawable.length,
                itemBuilder: (context, index) {
                  final badge = drawable[index].badge!;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      BadgeMedalArt(
                        category: badge.category,
                        badgeGrade: badge.badgeGrade,
                        size: 72,
                        // 타인 화면은 획득분만 그리므로 항상 획득 상태다.
                        earned: true,
                      ),
                      const SizedBox(height: AppTokens.s8),
                      Text(
                        badge.name,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.s16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 2.5),
        ],
      ),
      child: child,
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, color: Color(0xFF616161)),
        ),
        const SizedBox(height: AppTokens.s8),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Colors.black,
            ),
          ),
        ),
      ],
    );
  }
}

class _BadgeGridSkeleton extends StatelessWidget {
  const _BadgeGridSkeleton();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 132,
        mainAxisSpacing: AppTokens.s12,
        crossAxisSpacing: AppTokens.s12,
        childAspectRatio: 0.85,
      ),
      itemCount: 6,
      itemBuilder: (_, __) => Center(
        child: Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFF3F3F3),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.s24),
      child: Center(
        child: Text(
          message,
          style: const TextStyle(fontSize: 14, color: Color(0xFF9B9B9B)),
        ),
      ),
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.s24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          const SizedBox(height: AppTokens.s12),
          OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
        ],
      ),
    );
  }
}
