import 'package:flutter/material.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../models/models.dart';

/// 알림 종류의 화면 표현 — 아이콘·강조색·설정 화면 라벨, 그리고 상대 시각.
///
/// ## 문구는 여기서 만들지 않는다
/// 알림함에 보이는 제목/본문은 **서버가 완성해 내려준 값**(`title`/`body`)을
/// 그대로 쓴다. 이 파일이 제공하는 라벨은 **설정 화면의 토글 이름**과
/// **알림함 아이콘**뿐이다 — 클라이언트가 티어·랭킹을 계산해 문구를 만들면
/// 트레이 문구(서버)와 알림함 문구(클라이언트)가 갈라진다(architect §1.2).
///
/// ## 아이콘은 Material 임시값이다
/// `assets/icons/`에는 알림 종류별 lucide 원본이 아직 없다. Figma에서 종류별
/// 아이콘이 확정되면 `profile_page.dart`와 같은 방식으로 SVG로 교체한다.
class NotificationDisplay {
  const NotificationDisplay._();

  static IconData iconOf(NotificationType type) => switch (type) {
        NotificationType.tierPromotion => Icons.military_tech_outlined,
        NotificationType.tierProximity => Icons.trending_up,
        NotificationType.seasonEnding => Icons.hourglass_bottom,
        NotificationType.rankChange => Icons.swap_vert,
        NotificationType.weekendPush => Icons.bolt_outlined,
        NotificationType.badgeLevel => Icons.workspace_premium_outlined,
        NotificationType.points => Icons.toll_outlined,
      };

  /// 아이콘 강조색. 성취 계열은 티어/레벨 색을 그대로 빌려 온다 — 같은 사건이
  /// 홈·프로필에서 쓰는 색과 달라지면 무엇에 대한 알림인지 한눈에 안 잡힌다.
  static Color colorOf(NotificationType type) => switch (type) {
        NotificationType.tierPromotion => AppTokens.tierGold,
        NotificationType.tierProximity => AppTokens.tierSilver,
        NotificationType.seasonEnding => AppTokens.tierPlatinum,
        NotificationType.rankChange => AppTokens.tierBronze,
        NotificationType.weekendPush => AppTokens.levelXp,
        NotificationType.badgeLevel => AppTokens.levelXp,
        NotificationType.points => AppTokens.tierSpecial,
      };

  /// 설정 화면 토글의 이름. PRD §5.10 표의 요구사항 하나와 1:1이다.
  static String labelOf(NotificationType type) => switch (type) {
        NotificationType.tierPromotion => '티어 승급',
        NotificationType.tierProximity => '다음 티어 근접',
        NotificationType.seasonEnding => '시즌 종료 알림',
        NotificationType.rankChange => '주간 순위 변동',
        NotificationType.weekendPush => '주말 막판 알림',
        NotificationType.badgeLevel => '뱃지·레벨업',
        NotificationType.points => '포인트', // Phase 4 — 화면에 노출되지 않는다
      };

  /// 토글 아래 한 줄 설명. **무엇이 있을 때 오는 알림인지**만 말한다.
  ///
  /// 순위 관련 문구는 PRD §5.4.1의 "격차 우선" 표기를 따른다 — "10위까지"처럼
  /// 절대 순위를 목표로 제시하면 브론즈 3,000명 중 2,847위 사용자에게는
  /// 도달 불가능한 목표로 읽힌다.
  static String descriptionOf(NotificationType type) => switch (type) {
        NotificationType.tierPromotion => '시즌 누적 거리로 다음 티어에 올라섰을 때',
        NotificationType.tierProximity => '다음 티어까지 조금 남았을 때',
        NotificationType.seasonEnding => '시즌이 끝나기 14일 · 3일 전',
        NotificationType.rankChange => '같은 티어 안에서 순위가 바뀌었을 때',
        NotificationType.weekendPush => '주말에 앞사람과의 격차를 알려줄 때',
        NotificationType.badgeLevel => '새 뱃지를 얻거나 레벨이 올랐을 때',
        NotificationType.points => '포인트 적립·소멸 예정',
      };

  /// 알림함의 시각 표기. 오늘 안의 알림은 "방금/분/시간", 그 이후는 날짜다 —
  /// "3일 전"보다 "8월 25일"이 기억을 잇기 쉽다.
  static String relativeTime(DateTime createdAt, {DateTime? now}) {
    final local = createdAt.toLocal();
    final base = (now ?? DateTime.now()).toLocal();
    final diff = base.difference(local);

    if (diff.inMinutes < 1) return '방금 전';
    if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
    if (diff.inHours < 24 && base.day == local.day) {
      return '${diff.inHours}시간 전';
    }
    final yesterday = base.subtract(const Duration(days: 1));
    if (local.year == yesterday.year &&
        local.month == yesterday.month &&
        local.day == yesterday.day) {
      return '어제';
    }
    if (local.year == base.year) return '${local.month}월 ${local.day}일';
    return '${local.year}. ${local.month}. ${local.day}';
  }

  /// 미읽음 배지 문구. 세 자리부터는 개수 자체가 정보가 아니다.
  static String unreadBadgeLabel(int count) => count > 99 ? '99+' : '$count';
}
