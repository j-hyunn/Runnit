/// 러닝 요약 화면의 **성취 블록과 공유 버튼**(HI-08 / HI-10).
///
/// `tracking_page.dart`에서 떼어낸 이유는 두 가지다: 그 파일이 이미 1700줄이고,
/// 이 두 위젯은 게이트 분기(확정/대기/플래그)를 담고 있어 **화면 전체를 띄우지
/// 않고 단위로 검증**할 수 있어야 한다(`test/sharing/summary_achievements_test.dart`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_providers.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../../models/models.dart';
import '../../../gamification/domain/achievement_moment.dart';
import '../../../sharing/data/share_providers.dart';
import '../../../sharing/domain/achievement_backlog.dart';
import '../../../sharing/domain/share_card_builder.dart';
import '../../../sharing/presentation/share_card_sheet.dart';
import '../../../sharing/presentation/widgets/achievement_celebration.dart';
import '../tracking_ui_providers.dart';

/// 요약 화면의 성취 블록 — HI-10의 수용 기준("요약 화면 연출 종료 직후 노출").
///
/// ## 세 상태를 어떻게 가르는가 ([AchievementGate])
/// | 게이트 | 화면 |
/// |---|---|
/// | `confirmed` | 서버 확인 완료. 도착한 성취를 축하하고 **공유 버튼**을 준다 |
/// | `pending` | 아직 업로드/검증 전. 잠정 문구만, **공유 버튼 없음** |
/// | `flagged` | 서버가 이상치로 판정. **블록 자체를 조용히 생략**한다 |
///
/// `flagged`에 회수 애니메이션을 넣지 않는 이유는 TRD §11 — 설명 없이 박탈하지
/// 않는다. 축하한 적이 없으니 되돌릴 것도 없고, "당신의 기록이 거부됐습니다"를
/// 러닝 직후에 통보하는 것은 이 화면이 할 일이 아니다.
///
/// ## 큐에 뜬 성취는 게이트와 별개로 이미 확정이다
/// `evaluate_badges()`는 `is_flagged = false`인 기록만 근거로 판정하고 `verified
/// = true`로 지급한다. 그래서 큐에 온 뱃지는 **이 러닝의 게이트가 아직 pending
/// 이어도**(예: 다른 날 오프라인 러닝이 방금 동기화됨) 그 자체로 공유 가능하다.
/// 게이트가 지배하는 것은 "이번 러닝"에 대한 문구다.
class SummaryAchievements extends ConsumerStatefulWidget {
  const SummaryAchievements({required this.record, super.key});

  final RunRecord record;

  @override
  ConsumerState<SummaryAchievements> createState() =>
      _SummaryAchievementsState();
}

class _SummaryAchievementsState extends ConsumerState<SummaryAchievements> {
  /// 이 화면에서 이미 확인한 성취.
  ///
  /// `markAchievementsSeen`은 네트워크 실패 시 조용히 넘어가므로(축하 화면을
  /// 닫는 동작이 오류로 막히는 쪽이 더 나쁘다), 이 집합이 없으면 오프라인에서
  /// "확인"을 눌러도 같은 카드가 그대로 남아 **버튼이 고장 난 것처럼 보인다**.
  final Set<String> _dismissed = <String>{};

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // 업로드 결과는 `stop()`이 돌려준 스냅샷이 아니라 로컬 DB의 최신 행에 있다
    // (`storedRunProvider` 문서 참조). 아직 스트림이 도착하지 않았으면 손에 쥔
    // 레코드로 판정한다 — 그 경우 값은 보수적으로 `pending`이 된다.
    final stored = ref.watch(storedRunProvider(record.id)) ?? record;
    final gate = achievementGate(
      runSynced: stored.syncStatus == SyncStatus.synced,
      runFlagged: stored.isFlagged,
    );

    if (gate == AchievementGate.flagged) return const SizedBox.shrink();

    final queue = [
      for (final badge
          in ref.watch(pendingAchievementsProvider).valueOrNull ??
              const <UserBadge>[])
        if (!_dismissed.contains(badge.id)) badge,
    ];
    final next = queue.isEmpty ? null : queue.first;

    // 밀려 있던 성취가 이 화면에서 터지는 경우(연출을 처음 켠 직후, 또는 며칠치
    // 오프라인 러닝이 한꺼번에 동기화된 직후)에도 한 장으로 접는다 —
    // 요약 화면에서 뱃지를 스무 번 넘기게 만들지 않는다.
    if (isAchievementBacklog(queue)) {
      return _BacklogSummary(
        queue: queue,
        onDismiss: () => _dismiss([for (final badge in queue) badge.id]),
      );
    }

    if (next != null) {
      return Container(
        padding: const EdgeInsets.all(AppTokens.s20),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(AppTokens.rLg),
        ),
        child: AchievementCelebrationView(
          userBadge: next,
          // 한 번에 하나. 확인을 누르면 seen 처리되어 큐가 한 칸 밀리고
          // 다음 성취가 같은 자리에 나타난다 — 다이얼로그를 쌓지 않는다.
          remaining: queue.length - 1,
          onDismiss: () => _dismiss([next.id]),
        ),
      );
    }

    return Text(
      switch (gate) {
        // "포인트"는 MVP 범위 밖이라(PRD §5.6 Phase 4) 문구에서 뺐다. 뱃지·티어는
        // 이제 이 화면에서 바로 축하하므로 "기록 화면에 반영돼요"도 사실이 아니다.
        AchievementGate.confirmed => '기록이 확인됐어요. 새 뱃지나 티어 변화가 있으면 여기에 바로 표시돼요.',
        AchievementGate.pending => '아직 서버에 올리는 중이에요. 연결되면 뱃지와 티어가 확정돼요.',
        AchievementGate.flagged => '',
      },
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  void _dismiss(List<String> userBadgeIds) {
    setState(() => _dismissed.addAll(userBadgeIds));
    markAchievementsSeenFrom(ref, userBadgeIds);
  }
}

/// 밀린 성취를 요약 화면에서 한 장으로 접어 보여준다 (TRD §14 #19).
///
/// 개별 축하를 재생하지 않는 이유: 이건 방금 일어난 일이 아니다. 대신 개수를
/// 알리고 갤러리로 안내한 뒤, 확인을 누르면 **일괄** `is_seen` 처리한다.
class _BacklogSummary extends StatelessWidget {
  const _BacklogSummary({required this.queue, required this.onDismiss});

  final List<UserBadge> queue;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(AppTokens.s20),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppTokens.rLg),
      ),
      child: Column(
        children: [
          const Icon(Icons.military_tech_rounded, size: 40),
          const SizedBox(height: AppTokens.s12),
          Text(
            '그동안 받은 뱃지 ${queue.length}개',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppTokens.s4),
          Text(
            '활동 탭의 뱃지 갤러리에서 하나씩 확인하고 공유할 수 있어요.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppTokens.s12),
          TextButton(onPressed: onDismiss, child: const Text('확인')),
        ],
      ),
    );
  }
}

/// 러닝 기록 자체의 공유 버튼(HI-08).
///
/// 성취 카드와 달리 **서버 확정을 기다리지 않는다** — 이 카드는 뱃지·티어·PB를
/// 주장하지 않고 방금 사용자가 기록한 거리·시간·경로만 그리기 때문이다
/// (PRD §8.4가 막는 것은 클라이언트 판정을 "확정 성취"로 내보내는 행위다).
/// 다만 서버가 이상치로 플래그한 기록은 공유 대상에서 뺀다.
///
/// 게스트/프로필 미로딩 상태에서는 버튼을 그리지 않는다 — 카드 하단의 러너
/// 정보(이름·레벨·티어)를 채울 수 없다.
class RunShareButton extends ConsumerWidget {
  const RunShareButton({required this.record, super.key});

  final RunRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentProfileProvider).valueOrNull;
    if (user == null) return const SizedBox.shrink();

    final stored = ref.watch(storedRunProvider(record.id)) ?? record;
    if (stored.isFlagged == true) return const SizedBox.shrink();

    return OutlinedButton.icon(
      onPressed: () => showShareCardSheet(
        context,
        // 경로 좌표는 **손에 쥔 원본 레코드**에서 뽑는다. 목록 스트림에서 온
        // `stored`는 payload 절감 규약상 `samples`가 비어 있다.
        ShareCardBuilder.fromRun(run: record, user: user),
      ),
      icon: const Icon(Icons.ios_share),
      label: const Text('이 러닝 공유하기'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(AppTokens.minTapTarget),
      ),
    );
  }
}
