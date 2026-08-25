import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';

part 'app_user.freezed.dart';
part 'app_user.g.dart';

/// 앱 사용자 프로필. Dart 기본 `User`/Supabase `User`와의 이름 충돌을 피하려
/// 클래스명을 `AppUser`로 둔다. DB 테이블은 `profiles`.
///
/// [id]는 Supabase `auth.users.id`(UUID)와 동일 값을 사용한다.
///
/// ## 통계 캐시 필드
/// [totalDistanceMeters] 등 누적 통계는 **서버가 러닝 업로드 트리거로 갱신하는
/// 비정규화 캐시**다. 클라이언트가 직접 쓰지 않는다(읽기 전용).
/// 매 조회 시 runs 테이블 집계를 하면 프로필/랭킹 화면이 느려지므로 캐시를 둔다.
@freezed
abstract class AppUser with _$AppUser {
  const AppUser._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory AppUser({
    /// = Supabase auth.users.id (UUID).
    required String id,

    /// 고유 표시 핸들. 랭킹/크루에서 노출.
    required String username,

    /// 표시 이름. 미설정 시 null → UI는 username으로 폴백.
    String? displayName,

    String? avatarUrl,
    String? bio,

    /// 소속 러닝크루 id. 미소속이면 null.
    String? crewId,

    /// 신장(cm) / 체중(kg) — 칼로리 추정에 사용. 미입력 가능.
    double? heightCm,
    double? weightKg,

    /// 생년월일(UTC 자정). 연령대 랭킹/칼로리 추정용. 미입력 가능.
    DateTime? birthDate,

    Gender? gender,

    /// 표시 단위 설정. 저장은 항상 SI, 이 값은 표시 계층 전용.
    @Default(DistanceUnit.metric) DistanceUnit preferredUnit,

    // ── 서버 관리 통계 캐시 (클라이언트 읽기 전용) ──────────────
    /// 누적 러닝 거리(m).
    @Default(0) double totalDistanceMeters,

    /// 누적 이동 시간(s).
    @Default(0) int totalMovingSeconds,

    /// 누적 러닝 횟수.
    @Default(0) int totalRunCount,

    /// 누적 게이미피케이션 포인트. 레벨 산출의 입력.
    @Default(0) int totalPoints,

    /// 현재 레벨. totalPoints에서 서버가 파생.
    @Default(1) int level,

    /// 현재 연속 러닝 일수 / 역대 최장 연속 일수.
    @Default(0) int currentStreakDays,
    @Default(0) int longestStreakDays,

    /// 마지막 러닝 종료 시각(UTC). 스트릭 판정 기준.
    DateTime? lastRunAt,

    // ── 티어 시스템 (PRD §5.3 / §8.1) · 서버 관리, 클라이언트 읽기 전용 ──
    /// 현재 시즌 경쟁 티어. 시즌 시작 시 전원 [Tier.bronze]로 리셋된다(TI-02).
    /// 시즌 중 강등 없음(TI-08) — 단, 기록 삭제로 누적 거리가 기준선 아래로
    /// 내려가면 하향 조정된다(§8.1).
    @Default(Tier.bronze) Tier currentTier,

    /// **티어 판정 기준 거리(m)** — 현재 시즌 누적.
    ///
    /// ⚠️ [totalDistanceMeters]와 집계 대상이 다르다. 이 값에는
    /// **검증 통과(`is_flagged = false`) + 실외 활동** 기록만 합산한다.
    /// 트레드밀(`ActivityType.indoorRun`)·수동 입력 기록은 §8.3에 따라
    /// 누적 통계·히스토리에는 반영되지만 이 필드에는 들어가지 않는다.
    @Default(0) double seasonDistanceMeters,

    /// [currentTier]/[seasonDistanceMeters]가 속한 시즌 id (예: `2026-Q3`).
    ///
    /// **시즌 리셋의 트리거 기준점이다.** 서버는 러닝 저장/조회 시
    /// 이 값이 `Season.currentId()`와 다르면 (1) 직전 시즌 결과를
    /// `season_histories`에 확정 기록하고 (2) 티어·시즌 거리를 리셋한 뒤
    /// 이 값을 현재 시즌으로 갱신한다. 배치 잡에만 의존하지 않고 이 비교를
    /// 두는 이유: 배치가 실패하거나 지연돼도 다음 접근 시 스스로 복구된다.
    ///
    /// null이면 "아직 어떤 시즌에도 참여하지 않음"(신규 가입 직후).
    String? tierSeasonId,

    required DateTime createdAt,
    DateTime? updatedAt,
  }) = _AppUser;

  factory AppUser.fromJson(Map<String, dynamic> json) =>
      _$AppUserFromJson(json);

  String get label => displayName?.trim().isNotEmpty == true
      ? displayName!
      : username;

  /// 다음 승급 목표. 플래티넘이면 null.
  Tier? get nextTier => currentTier.next;

  /// TI-05 진행률 바 — 다음 티어까지 남은 거리(m). 플래티넘이면 null.
  ///
  /// 서버가 확정한 [currentTier]를 기준으로 계산한다(거리에서 티어를 다시
  /// 유도하지 않는다). 서버 갱신이 한 박자 늦더라도 화면에 표시된 티어와
  /// 진행률 바가 서로 모순되지 않게 하기 위함이다.
  double? get remainingToNextTierMeters {
    final next = nextTier;
    if (next == null) return null;
    final left = next.thresholdMeters - seasonDistanceMeters;
    return left > 0 ? left : 0;
  }

  /// 현재 티어 구간 내 진행률 0.0~1.0. 플래티넘이면 1.0.
  double get tierProgress {
    final next = nextTier;
    if (next == null) return 1;
    final floor = currentTier.thresholdMeters;
    final span = next.thresholdMeters - floor;
    if (span <= 0) return 1;
    return ((seasonDistanceMeters - floor) / span).clamp(0.0, 1.0);
  }
}
