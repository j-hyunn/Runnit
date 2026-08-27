/// 공유 카드(HI-08 / HI-10)가 그리는 데이터의 **뷰모델 유니온**.
///
/// ## 왜 새 Supabase 테이블이 없는가
/// 카드 3종이 필요로 하는 값은 **전부 이미 저장돼 있다**:
///
/// | 카드 | 출처 |
/// |---|---|
/// | 티어 승급 | `profiles.current_tier` / `season_distance_meters` / `tier_season_id`, `user_badges`의 `stier_*@{season}` 인스턴스, `leaderboard_entries`(순위) |
/// | 뱃지 획득 | `badges` + `user_badges` |
/// | PB 갱신 | `badges`(조건값 `distanceKm`) + `user_badges.source_run_id` → `runs` |
///
/// 공유 **행위** 자체를 저장할 테이블(`share_events` 등)도 두지 않는다 — PRD가
/// 요구하는 수용 기준은 "카드를 만들어 공유 시트를 연다"까지이고, OS 공유 시트는
/// 사용자가 실제로 게시했는지를 앱에 돌려주지 않는다(iOS는 취소/성공만, 대상 앱은
/// 알려주지 않음). 게시 여부를 모르는 채 남는 행은 분석에도 쓸 수 없다. 공유
/// 전환율이 필요해지면 그때 분석 이벤트(`share_sheet_opened`)로 붙인다 — 도메인
/// 테이블이 아니라 텔레메트리의 문제다.
///
/// ## 단 하나의 스키마 요청 (P1, backend-engineer)
/// `user_badges.achieved_value numeric null` — 서버가 판정 시점에 확정한 값
/// (PB 초, 스트릭 주, 주간 순위 등)을 그대로 적어 두는 컬럼. PB 카드가 "5km
/// 24:31"의 **24:31을 서버 확정값으로** 받으려면 이게 필요하다. 지금은 없어도
/// P0가 성립한다 — [PersonalBestCardData.certifiedSeconds]의 폴백 규칙 참조.
library;

import '../../../models/models.dart';

/// 카드 종류. 앞의 3개는 HI-10이 지정한 트리거 지점과 1:1, 마지막 하나는
/// 성취 없이 러닝 자체를 공유하는 HI-08 경로다.
enum ShareCardKind {
  /// 티어 승급 — 브론즈→실버 등. 절대평가 승급 (PRD §5.3).
  tierPromotion,

  /// 뱃지 획득 — 티어/PB를 제외한 나머지 12개 카테고리.
  badgeEarned,

  /// PB 갱신 — 1/5/10km·하프 개인 최고 기록 (PRD HI-04).
  personalBest,

  /// 성취 없는 러닝 기록 자체 (HI-08 "기록·성취 이미지 공유 카드").
  runRecap,
}

/// 카드 하단에 공통으로 박히는 러너 신원.
///
/// [AppUser]를 그대로 넘기지 않는 이유: 카드에 필요한 건 6개 필드인데 [AppUser]는
/// 체중·생년월일까지 들고 있다. 공유 이미지를 만드는 계층에 신체 정보를 흘려보내지
/// 않는 것이 기본값으로 안전하다.
class ShareAthlete {
  const ShareAthlete({
    required this.displayName,
    required this.tier,
    required this.level,
    this.avatarUrl,
  });

  factory ShareAthlete.fromUser(AppUser user) => ShareAthlete(
        displayName: user.label,
        tier: user.currentTier,
        level: user.level,
        avatarUrl: user.avatarUrl,
      );

  final String displayName;

  /// 카드를 만든 시점의 티어. 티어 승급 카드에서는 **승급 후** 티어다.
  final Tier tier;
  final int level;
  final String? avatarUrl;
}

/// 카드에 얹는 경로 미리보기 (PRD HI-08 "경로 포함").
///
/// 좌표를 여기까지 끌고 오는 이유: 카드 위젯이 `RunRecord`를 통째로 알 필요가 없고,
/// 실내 러닝처럼 경로가 없는 경우를 `null` 하나로 표현할 수 있다.
class ShareRoute {
  const ShareRoute({required this.points, required this.distanceMeters});

  /// 위도/경도 쌍. 카드 크기(≈1080px 폭)에서는 수백 점이면 충분하므로
  /// [ShareCardBuilder]가 이미 다운샘플한 목록을 넣는다.
  final List<({double lat, double lng})> points;
  final double distanceMeters;

  bool get isDrawable => points.length >= 2;
}

/// 모든 카드의 공통 계약.
///
/// `sealed`라 UI는 `switch`로 3종을 **빠짐없이** 다뤄야 한다 — 카드가 늘면
/// 컴파일 에러로 알려준다. freezed를 쓰지 않은 것은 이 모듈의 다른 도메인
/// 뷰모델(`GamificationStats`, `BadgeProgress`)과 같은 이유다: 직렬화되지 않고
/// `copyWith`도 필요 없어서 코드 생성이 순수 비용이다.
sealed class ShareCardData {
  const ShareCardData({
    required this.athlete,
    required this.achievedAt,
    this.route,
  });

  final ShareAthlete athlete;

  /// 성취가 **확정된** 시각(UTC). 서버가 준 값을 그대로 쓴다
  /// (`UserBadge.earnedAt` / `tier_change_history.reached_at`).
  final DateTime achievedAt;

  /// 성취를 만든 러닝의 경로. 누적형 뱃지·경로 없는 러닝이면 null.
  final ShareRoute? route;

  ShareCardKind get kind;

  /// 카드의 큰 글씨 한 줄. "무엇을 달성했는가".
  String get headline;

  /// 그 아래 보조 한 줄. 없으면 null.
  String? get subhead;

  /// 공유 시트에 함께 실리는 텍스트. 이미지가 본체이고 이건 곁들임이다 —
  /// 인스타 스토리는 텍스트를 무시하지만 카카오톡·메시지는 함께 보여준다.
  String get shareText;
}

/// 티어 승급 카드.
class TierPromotionCardData extends ShareCardData {
  const TierPromotionCardData({
    required super.athlete,
    required super.achievedAt,
    required this.tier,
    required this.seasonId,
    required this.seasonDistanceMeters,
    this.rank,
    this.participantCount,
    super.route,
  });

  /// 새로 도달한 티어. [ShareAthlete.tier]와 같은 값이지만 의미가 다르다 —
  /// 이쪽은 "이 카드가 축하하는 티어"라 나중에 지난 승급을 다시 공유해도 흔들리지
  /// 않는다.
  final Tier tier;

  /// 예: `2026-Q3`.
  final String seasonId;

  /// 승급 시점의 시즌 누적 거리(m). 절대평가 기준값 (PRD §5.3).
  ///
  /// **현재 시즌 카드에서만 값이 있다.** 프로필은 "지금" 시즌의 누적 거리만
  /// 들고 있어서, 지난 시즌 승급 뱃지를 나중에 다시 공유할 때 이 값을 그대로
  /// 쓰면 다른 시즌의 숫자가 카드에 찍힌다(QA O-3, 2026-08-26). 값을 모르면
  /// null — subhead/스탯 칸에서 조용히 빠진다.
  final double? seasonDistanceMeters;

  /// 같은 티어 안에서의 주간 순위 (PRD HI-08 "순위 포함"). 집계 전이면 null.
  final int? rank;
  final int? participantCount;

  @override
  ShareCardKind get kind => ShareCardKind.tierPromotion;

  /// "상위 N%" — PRD §5.4.1에 따라 절대 순위보다 이 표기를 우선한다.
  /// [RankingEntry.topPercent]와 같은 규칙(올림, 1~100)을 쓴다.
  int? get topPercent {
    final total = participantCount;
    final r = rank;
    if (total == null || r == null || total <= 0) return null;
    return (r / total * 100).ceil().clamp(1, 100);
  }

  @override
  String get headline => '${tierLabel(tier)} 달성';

  @override
  String? get subhead {
    final meters = seasonDistanceMeters;
    if (meters == null) return '$seasonId 시즌';
    final km = (meters / 1000).toStringAsFixed(1);
    return '$seasonId 시즌 ${km}km';
  }

  @override
  String get shareText => '$seasonId 시즌 ${tierLabel(tier)} 달성! #Runnit';
}

/// 뱃지 획득 카드.
class BadgeEarnedCardData extends ShareCardData {
  const BadgeEarnedCardData({
    required super.athlete,
    required super.achievedAt,
    required this.badge,
    required this.badgeAssetPath,
    super.route,
  });

  /// 카탈로그 정의(이름·설명·등급). `UserBadge.badge` 조인 결과.
  final Badge badge;

  /// `assets/badges/{카테고리}/{등급}.svg`. 해석 규칙은 [ShareCardBuilder]가
  /// 갖는다 — 뱃지 갤러리(`badge_gallery_page.dart`)와 **같은 규칙**이어야
  /// 갤러리에서 본 메달과 공유 카드의 메달이 달라지지 않는다.
  final String badgeAssetPath;

  @override
  ShareCardKind get kind => ShareCardKind.badgeEarned;

  @override
  String get headline => badge.name;

  @override
  String? get subhead => badge.description;

  @override
  String get shareText => '뱃지 「${badge.name}」 획득! #Runnit';
}

/// PB 갱신 카드.
class PersonalBestCardData extends ShareCardData {
  const PersonalBestCardData({
    required super.athlete,
    required super.achievedAt,
    required this.targetKm,
    required this.badgeAssetPath,
    this.certifiedSeconds,
    this.runDistanceMeters,
    super.route,
  });

  /// PB 종목 거리(km). 1 / 5 / 10 / 21.0975 (하프). `Badge.condition['distanceKm']`.
  final double targetKm;

  final String badgeAssetPath;

  /// 이 PB의 **확정 기록(초)**.
  ///
  /// ## 왜 null일 수 있는가 — 정직하게 비워 두는 쪽을 택했다
  /// 서버 판정 규칙(TRD §10.2 `pb_time_lte`)은 세션 거리가 목표의 102%를 넘으면
  /// **GPS 샘플 선형 보간으로 목표 거리 통과 시각**을 쓴다. 그 보간값은 지금
  /// 어디에도 저장되지 않는다(`user_badges`에 값 컬럼이 없다).
  ///
  /// 그래서 [ShareCardBuilder]는 이렇게 채운다:
  /// - 세션 거리 ≤ 목표×102% → `run.movingSeconds`. 이 구간에서는 그게 **서버의
  ///   규칙 그 자체**라 값이 정확히 일치한다.
  /// - 초과 → **null**. 카드는 시간 없이 "5km PB 갱신"만 말한다.
  ///
  /// 클라이언트가 보간을 흉내 내지 않는 이유: 서버가 확정한 숫자를 클라이언트가
  /// 재유도하면 두 개의 정본이 생기고, 어긋나는 순간 사용자가 인스타에 올린
  /// 기록이 앱 화면과 다른 값이 된다. 이 컬럼이 생기면(`achieved_value`)
  /// 폴백은 사라지고 항상 서버 값을 쓴다.
  final int? certifiedSeconds;

  /// 그 PB가 나온 러닝의 총 거리(m). "7.2km 러닝에서 5km PB" 맥락 표시용.
  final double? runDistanceMeters;

  @override
  ShareCardKind get kind => ShareCardKind.personalBest;

  /// 하프는 21.0975km라 소수점을 그대로 쓰면 카드에서 지저분하다.
  String get distanceLabel {
    if ((targetKm - 21.0975).abs() < 0.01) return '하프';
    return targetKm == targetKm.roundToDouble()
        ? '${targetKm.toInt()}km'
        : '${targetKm}km';
  }

  /// `mm:ss` 또는 `h:mm:ss`. [certifiedSeconds]가 없으면 null.
  String? get timeLabel {
    final s = certifiedSeconds;
    return s == null ? null : formatShareClock(s);
  }

  @override
  String get headline => '$distanceLabel 개인 최고 기록';

  @override
  String? get subhead => timeLabel;

  @override
  String get shareText {
    final t = timeLabel;
    return t == null
        ? '$distanceLabel PB 갱신! #Runnit'
        : '$distanceLabel PB $t 갱신! #Runnit';
  }
}

/// 성취가 없는 **러닝 기록 자체**의 카드.
///
/// ## 왜 유니온에 하나가 더 필요했는가
/// HI-08은 "기록·성취 이미지 공유 카드"다 — 성취(뱃지·티어·PB)뿐 아니라 **기록**도
/// 공유 대상이다. 그리고 대부분의 러닝은 뱃지를 터뜨리지 않는다: 성취 카드만
/// 만들면 요약 화면의 공유 버튼은 열 번 중 아홉 번 비어 있게 된다.
///
/// [BadgeEarnedCardData]로 대신하지 않는 이유는 그릴 메달이 없어서다. 여기서는
/// **경로 그림이 주인공**이고 숫자가 그 아래 붙는다.
///
/// ⚠️ 이 카드는 서버가 확정한 성취를 주장하지 않는다 — 사용자가 방금 기록한
/// 자기 러닝의 거리·시간·경로일 뿐이다. 그래서 PRD §8.4("클라이언트 판정을
/// 확정으로 보여주지 않는다")에 걸리지 않는다. 반대로 뱃지·PB·티어 문구를 여기에
/// 얹기 시작하면 그 순간 §8.4 위반이 된다.
class RunRecapCardData extends ShareCardData {
  const RunRecapCardData({
    required super.athlete,
    required super.achievedAt,
    required this.distanceMeters,
    required this.movingSeconds,
    required this.elapsedSeconds,
    this.avgPaceSecPerKm,
    this.caloriesKcal,
    super.route,
  });

  final double distanceMeters;
  final int movingSeconds;
  final int elapsedSeconds;
  final double? avgPaceSecPerKm;
  final int? caloriesKcal;

  @override
  ShareCardKind get kind => ShareCardKind.runRecap;

  /// `5.01km`. 카드에서는 소수 둘째 자리까지 — 요약 화면과 같은 표기다.
  String get distanceLabel => '${(distanceMeters / 1000).toStringAsFixed(2)}km';

  /// 이동 시간이 0이면(정지 상태로만 기록된 이상 케이스) 전체 경과 시간으로
  /// 폴백한다 — 둘 다 0이면 그냥 `0:00`이라 레이아웃이 무너지지 않는다.
  String get timeLabel =>
      formatShareClock(movingSeconds > 0 ? movingSeconds : elapsedSeconds);

  /// `5'23"/km`. 거리가 너무 짧아 페이스가 의미 없으면 null —
  /// **카드에서 페이스 칸 자체가 빠진다**(0'00"을 자랑하게 두지 않는다).
  String? get paceLabel {
    final seconds = avgPaceSecPerKm ??
        (distanceMeters > 0 && movingSeconds > 0
            ? movingSeconds / (distanceMeters / 1000)
            : null);
    if (seconds == null || seconds <= 0 || !seconds.isFinite) return null;
    final total = seconds.round();
    return "${total ~/ 60}'${(total % 60).toString().padLeft(2, '0')}\"/km";
  }

  @override
  String get headline => '$distanceLabel 완주';

  @override
  String? get subhead {
    final pace = paceLabel;
    return pace == null ? timeLabel : '$timeLabel · $pace';
  }

  @override
  String get shareText => '$distanceLabel 러닝 완료! #Runnit';
}

/// 티어 한글 라벨. 카드/연출 문구에서 공통으로 쓴다.
String tierLabel(Tier tier) => switch (tier) {
      Tier.bronze => '브론즈',
      Tier.silver => '실버',
      Tier.gold => '골드',
      Tier.platinum => '플래티넘',
    };

/// 초 → `mm:ss` / `h:mm:ss`. 카드 3종이 같은 표기를 쓰도록 한 곳에 둔다 —
/// PB 카드의 `24:31`과 기록 카드의 `24:31`이 다른 규칙으로 그려지면 같은
/// 러닝을 두 카드로 공유했을 때 숫자가 어긋나 보인다.
String formatShareClock(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600;
  final mm = ((s % 3600) ~/ 60).toString().padLeft(2, '0');
  final ss = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
