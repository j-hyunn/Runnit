import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';

part 'badge.freezed.dart';
part 'badge.g.dart';

/// 뱃지 **카탈로그** 항목 — 정의이지 획득 기록이 아니다.
/// 서버 테이블 `badges`는 사실상 읽기 전용 마스터 데이터다.
///
/// 정본은 `docs/badge-catalog.csv`(158종 / 16카테고리), 스펙은 TRD §3.6.
///
/// 판정 조건은 [conditionType](어떤 판정 함수를 쓸지) + [condition](그 함수의 입력
/// 파라미터) 조합으로 **데이터화**한다. 조건을 코드에 하드코딩하면 뱃지를 추가할
/// 때마다 앱 배포가 필요해진다.
@freezed
abstract class Badge with _$Badge {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Badge({
    /// 안정적인 슬러그(예: `dist_cum_1000km`). UUID 대신 슬러그를 쓴다 —
    /// 게이미피케이션 규칙/테스트에서 사람이 읽을 수 있어야 하기 때문.
    ///
    /// `scope == seasonal`인 **인스턴스**는 `{templateId}@{seasonId}` 형태로
    /// 발급한다(예: `stier_platinum@2026-Q3`) — 시즌마다 재발급되므로 템플릿 id를
    /// 그대로 쓰면 PK가 충돌한다.
    required String id,

    /// 표시명. CSV `display_name` (예: '천리길').
    required String name,

    /// 획득 조건 설명 — 뱃지 갤러리 상세(PRD GM-03)에 그대로 노출된다.
    required String description,

    required BadgeCategory category,
    required BadgeScope scope,
    required BadgeTriggerType triggerType,

    /// 판정 함수 **디스패치 키**. CSV `condition_type`과 1:1 (현재 40종).
    /// 상수 목록과 클라이언트 판정 가능 여부는
    /// `features/gamification/domain/badge_condition.dart` 참조.
    ///
    /// String인 이유: 새 판정 종류가 추가돼도 앱 배포 없이 카탈로그가 확장되어야 한다.
    /// 클라이언트가 모르는 값이 내려오면 진행률 없이 조건 텍스트만 표시한다.
    required String conditionType,

    /// 판정 함수 입력 파라미터. CSV `condition_value`(jsonb).
    /// 키 집합은 [conditionType]마다 다르다 — 예:
    /// `cumulative_distance_gte` → `{"distanceKm": 1000}`,
    /// `season_weekly_rank_lte` → `{"tier": "gold", "bucket": "top1"}`.
    ///
    /// 파라미터가 없는 종류(`season_first_run` 등)는 `{}`다. NULL도 `{}`와 동치로
    /// 취급하기 위해 required가 아니라 기본값을 준다.
    @Default(<String, dynamic>{}) Map<String, dynamic> condition,

    /// 뱃지 자체의 표시 등급: bronze/silver/gold/platinum/diamond/special.
    ///
    /// ⚠️ `scope == seasonal`인 시즌티어달성(`stier_*`) 4종을 제외하면
    /// **실제 시즌 티어 시스템(`Tier`)과 무관한 순수 장식용 값**이다. 섞지 말 것.
    ///
    /// enum이 아니라 String인 이유: 등급 라벨은 카탈로그 운영 중 늘어날 수 있고
    /// (예: 이벤트 전용 등급), 판정 로직이 이 값을 읽지 않는다.
    required String badgeGrade,

    /// `scope == seasonal` 템플릿이 시즌 시작 시 **실제 발급된 인스턴스**일 때만 값이
    /// 있다(예: `'2026-Q3'`). 카탈로그의 템플릿 자체와 permanent 뱃지는 null.
    String? seasonId,
  }) = _Badge;

  factory Badge.fromJson(Map<String, dynamic> json) => _$BadgeFromJson(json);
}

/// 사용자의 뱃지 **획득 기록**. 카탈로그([Badge])와 분리한다 —
/// 합치면 사용자 수 × 뱃지 수만큼 정의가 중복 저장된다.
@freezed
abstract class UserBadge with _$UserBadge {
  @JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
  const factory UserBadge({
    /// UUID. 서버 생성. `markBadgesSeen()`이 이 값으로 개별 행을 업데이트한다.
    required String id,
    required String userId,

    /// [Badge.id]. seasonal이면 템플릿이 아니라 **인스턴스** id다.
    required String badgeId,

    /// 획득 시각(UTC). 서버가 확정한다(클라이언트 시각은 신뢰 불가).
    required DateTime earnedAt,

    /// 이 뱃지를 촉발한 러닝 id. DB 컬럼 `user_badges.source_run_id`
    /// (`references runs(id) on delete set null`, 마이그레이션 02)는 처음부터
    /// 있었지만 Dart 모델에는 빠져 있었다 — 2026-08-26 공유 카드(HI-08) 설계에서
    /// 추가했다.
    ///
    /// **공유 카드가 이 값을 쓴다.** 뱃지·PB 카드에 그 러닝의 경로(§HI-08 "경로
    /// 포함")와 거리·시간을 얹으려면 "어느 러닝이 이 뱃지를 만들었는지"를 알아야
    /// 하고, 그 답을 서버는 이미 갖고 있다. 없으면 클라이언트가 `earnedAt` 근처
    /// 러닝을 시간으로 추측하게 되는데, 같은 날 두 번 뛴 사용자에게서 조용히
    /// 틀린다.
    ///
    /// null인 경우: 누적/랭킹처럼 특정 세션에서 나오지 않은 뱃지
    /// ([Badge.triggerType]이 `cumulative`), 또는 원본 러닝이 삭제된 경우.
    String? sourceRunId,

    /// 서버 재검증 통과 여부. 기본값 false — 미검증 뱃지를 낙관적으로
    /// "확정 획득"으로 표시하지 않기 위해서다.
    @Default(false) bool verified,

    /// 사용자가 획득 연출(PRD GM-02)을 이미 봤는지. 미확인 큐 처리에 쓴다.
    /// RLS상 클라이언트가 쓸 수 있는 **유일한** 컬럼이다.
    @Default(false) bool isSeen,

    /// 조인해서 함께 내려온 카탈로그 정보(선택). 별도 조회 왕복을 줄인다.
    Badge? badge,
  }) = _UserBadge;

  factory UserBadge.fromJson(Map<String, dynamic> json) =>
      _$UserBadgeFromJson(json);
}
