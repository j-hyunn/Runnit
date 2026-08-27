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
import '../../../sharing/domain/share_card_builder.dart';
import '../../../sharing/presentation/share_card_sheet.dart';
import '../tracking_ui_providers.dart';

/// 요약 화면의 게이트 문구 — HI-10의 수용 기준("요약 화면 연출 종료 직후 노출")은
/// [AchievementCelebrationHost](`achievement_celebration.dart`)의 **풀페이지**가
/// 담당한다.
///
/// ## 2026-08-27: 인라인 축하를 걷어냈다 (사용자 요청)
/// 이전에는 성취(뱃지/티어/PB)를 이 화면 안에 `Container`로 직접 그렸다. 지금은
/// 요약 화면 위에 **풀페이지로 덮이는** 전역 축하([AchievementCelebrationHost])
/// 하나로 통일한다 — 그 큐 소비·밀린 성취 접기·1건씩 순차 연출은 전부 그쪽
/// 책임이고, 여기서 두 번째로 소비하면 같은 뱃지가 두 화면에서 각자 판단하게
/// 된다. 이 위젯은 이제 **게이트 상태 문구만** 그린다.
///
/// ## 세 상태를 어떻게 가르는가 ([AchievementGate])
/// | 게이트 | 화면 |
/// |---|---|
/// | `confirmed` | 서버 확인 완료. 잠시 뒤 전역 풀페이지가 뜰 수 있다 |
/// | `pending` | 아직 업로드/검증 전. 잠정 문구만 |
/// | `flagged` | 서버가 이상치로 판정. **블록 자체를 조용히 생략**한다 |
///
/// `flagged`에 회수 애니메이션을 넣지 않는 이유는 TRD §11 — 설명 없이 박탈하지
/// 않는다. 축하한 적이 없으니 되돌릴 것도 없고, "당신의 기록이 거부됐습니다"를
/// 러닝 직후에 통보하는 것은 이 화면이 할 일이 아니다.
class SummaryAchievements extends ConsumerWidget {
  const SummaryAchievements({required this.record, super.key});

  final RunRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    return Text(
      switch (gate) {
        // "포인트"는 MVP 범위 밖이라(PRD §5.6 Phase 4) 문구에서 뺐다. 뱃지·티어는
        // 전역 풀페이지가 알아서 덮으므로 "기록 화면에 반영돼요"도 사실이 아니다.
        AchievementGate.confirmed => '기록이 확인됐어요. 새 뱃지나 티어 변화가 있으면 곧 알려드려요.',
        AchievementGate.pending => '아직 서버에 올리는 중이에요. 연결되면 뱃지와 티어가 확정돼요.',
        AchievementGate.flagged => '',
      },
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
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
