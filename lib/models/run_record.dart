import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';
import 'run_sample.dart';

part 'run_record.freezed.dart';
part 'run_record.g.dart';

/// 서버가 샘플로 거리를 재계산하기 **직전**에 보존한 클라이언트 주장값
/// (마이그레이션 64, `runs.client_reported jsonb`).
///
/// ## 왜 스칼라 2개가 아니라 중첩 객체인가 (2026-09-07 mobile-architect 결정)
/// 서버 컬럼이 jsonb 하나이고, 클라이언트는 그것을 **통째로 되받기만** 한다
/// (`LocalRunRepository._serverOwnedKeys`). 스칼라로 펼치면 `toJson()`이
/// `client_reported_distance_meters` 같은 **`runs`에 존재하지 않는 키**를
/// 만들어 업로드 payload에 섞이고(회귀 테스트 `_runsColumns`가 정확히 이걸
/// 잡는다), 되받을 때는 jsonb → 스칼라 2개로 푸는 분해 로직을
/// `_adoptedKeys` 루프 밖에 따로 둬야 한다. 중첩으로 두면 wire 키가
/// `client_reported` 하나로 유지돼 세 집합(`_serverOwnedKeys` ·
/// `_adoptedKeys` · `_confirmationColumns`)을 **한 글자도 고치지 않아도**
/// 되고, `summaryJson` 왕복도 `RunRecord.toJson()`이 그대로 처리한다.
/// freezed 중첩 클래스는 커스텀 컨버터 없이 직렬화된다(`explicitToJson: true`).
///
/// 덤으로 [maxSpeedMps] · [recalculatedAt]도 손실 없이 따라온다 — 스칼라 2개로
/// 펼쳤다면 버려졌을 값이다.
///
/// ## 언제 채워지는가
/// 서버는 **재계산 결과가 주장값보다 작고 차이가 1m 이상일 때, 최초 확정 한 번만**
/// 채운다(마이그레이션 64 `trg_runs_guard`). 즉 이 값이 존재한다는 것 자체가
/// "거리가 깎였다"는 뜻이며, 값이 늘어나는 방향은 존재하지 않는다.
/// 재 upsert가 서버 확정값을 세탁하지 못하도록 null 검사로 보호된다.
///
/// **읽기 전용**이다 — 클라이언트는 보내지 않고 받기만 한다.
@freezed
abstract class ClientReportedRun with _$ClientReportedRun {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory ClientReportedRun({
    /// 재계산 전 클라이언트가 주장한 거리(m).
    double? distanceMeters,

    /// 재계산 전 클라이언트가 주장한 이동시간(s).
    int? movingSeconds,

    /// 재계산 전 클라이언트가 주장한 최고 순간 속도(m/s).
    double? maxSpeedMps,

    /// 서버가 재계산을 확정한 시각(UTC).
    DateTime? recalculatedAt,
  }) = _ClientReportedRun;

  factory ClientReportedRun.fromJson(Map<String, dynamic> json) =>
      _$ClientReportedRunFromJson(json);
}

/// 완결된(또는 진행 중인) 하나의 러닝 세션.
///
/// ## 단위 규약 (전 팀 공통)
/// - 거리: **미터(m)**, double
/// - 시간: **초(s)**, int
/// - 페이스: **초/킬로미터(s/km)**, double
/// - 속도: 초당 미터(m/s), double
/// - 고도: 미터(m), double
/// - 칼로리: kcal, int
/// - 모든 `DateTime`은 **UTC**
///
/// ## 시간 두 종류
/// - [elapsedSeconds]: 시작~종료 벽시계 시간 (일시정지 포함)
/// - [movingSeconds]: 실제 이동 시간 (일시정지 제외). 페이스 계산의 분모.
@freezed
abstract class RunRecord with _$RunRecord {
  const RunRecord._();

  @JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
  const factory RunRecord({
    /// UUID v4. **클라이언트에서 생성**한다 — 오프라인 기록의 업로드 멱등성 보장.
    required String id,

    /// 소유자 사용자 id (= AppUser.id = Supabase auth.users.id).
    required String userId,

    /// 세션 시작 시각(UTC).
    required DateTime startedAt,

    /// 세션 종료 시각(UTC). 진행 중이면 null.
    DateTime? endedAt,

    required ActivityType activityType,
    required RunStatus status,

    /// 총 이동 거리(m). GPS 스무딩 적용 후 값.
    required double distanceMeters,

    /// 벽시계 경과 시간(s) = endedAt - startedAt.
    required int elapsedSeconds,

    /// 순수 이동 시간(s), 일시정지 제외. 페이스 계산에 사용.
    required int movingSeconds,

    /// 평균 페이스(s/km) = movingSeconds / (distanceMeters / 1000).
    /// 거리 0이면 null.
    double? avgPaceSecPerKm,

    /// 세션 중 관측된 최고 순간 속도(m/s).
    double? maxSpeedMps,

    /// 누적 상승 고도(m). 기압계/고도 데이터 없으면 null.
    double? elevationGainMeters,

    /// 누적 하강 고도(m).
    double? elevationLossMeters,

    /// 평균/최대 심박수(bpm). 웨어러블 연동 시에만.
    int? avgHeartRateBpm,
    int? maxHeartRateBpm,

    /// 소모 칼로리(kcal). 추정값.
    int? caloriesKcal,

    /// 평균 케이던스(spm).
    int? avgCadenceSpm,

    /// 원시 샘플 목록. 시간 오름차순 정렬 보장.
    /// 목록/랭킹 조회 시에는 빈 리스트로 내려오고, 상세 조회에서만 채워진다
    /// (payload 절감 — 1시간 러닝 = 약 3600 샘플).
    @Default(<RunSample>[]) List<RunSample> samples,

    /// 지도 썸네일용 다운샘플 경로. Google encoded polyline (precision 5) 문자열.
    /// 실내 러닝은 null.
    String? routePolyline,

    /// 사용자 메모/제목.
    String? title,
    String? note,

    /// 서버 동기화 상태. 기기 로컬에서만 의미를 가지며 서버로 전송하지 않는다.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(SyncStatus.local)
    SyncStatus syncStatus,

    /// 이 세션에 기여한 소스들. 폰+워치 동시 기록 시 둘 다 포함.
    @Default(<RunSampleSource>[]) List<RunSampleSource> sources,

    /// 이 세션에 기여한 **기기 벤더** 목록. [sources]와 직교하는 축이다
    /// (`enums.dart`의 [DeviceVendor] 주석 참조 — "언제/어떻게" vs "어느 기기").
    ///
    /// | 상황 | 값 |
    /// |---|---|
    /// | 폰 단독 러닝 (P0 기본) | `[phone]` |
    /// | 폰 GPS + Apple Watch 심박 | `[phone, watchApple]` |
    /// | 워치 워크아웃 통째 임포트 (P1, WR-01~03) | `[watchApple]` / `[watchGarmin]` |
    /// | 수동 입력·기기 정보 없음 | `[]` — 빈 배열은 `[phone]`과 **다른 뜻**이다 |
    ///
    /// ## 왜 스칼라가 아니라 배열인가
    /// 한 세션에 폰(좌표)과 워치(심박)가 **동시에** 기여하는 것이 P1의 기본
    /// 경로다. 스칼라 `deviceVendor` 하나로는 그 세션을 폰 기록이라 부를지
    /// 워치 기록이라 부를지 손실 없이 표현할 수 없다.
    ///
    /// ## 뱃지 판정에서의 사용 (device_source_count_gte / _diversity_gte)
    /// - "애플워치로 누적 50회": `deviceVendors`가 `watchApple`을 **포함**하는 러닝 수
    /// - "올라운더"(device_both_used): `phone`을 포함한 러닝과 `watchApple`/`watchGarmin`을
    ///   포함한 러닝이 각각 1건 이상. **같은 러닝이 둘 다 충족해도 인정된다** —
    ///   매칭 규칙은 배열 겹침 하나뿐이고 "폰 단독"이라는 두 번째 시맨틱은 없다
    ///   (TRD §3.1.2 / 2026-08-26 기기 벤더 중재)
    ///
    /// 값 문자열은 뱃지 카탈로그 토큰과 1:1로 같다 — 매핑 테이블이 없다.
    @Default(<DeviceVendor>[]) List<DeviceVendor> deviceVendors,

    /// 서버가 산정한 이 러닝의 XP. 클라이언트 계산값은 신뢰하지 않는다
    /// (서버 재검증 후 확정 — `compute_run_xp()`). DB 컬럼은 `runs.awarded_xp`.
    int? awardedXp,

    /// 서버 재검증 이상치 플래그 (PRD §8.4). DB 컬럼 `runs.is_flagged`.
    ///
    /// **읽기 전용**이다 — `_serverOwnedKeys`가 업로드 payload에서 제거하고,
    /// 서버 `trg_runs_guard`가 한 번 더 되돌린다.
    ///
    /// ## 왜 `@Default(false)`가 아니라 nullable인가
    /// 세 가지 상태를 구분해야 하기 때문이다:
    /// - `null` = **아직 모른다** (로컬 저장만 됐거나 서버 응답을 못 받음)
    /// - `false` = 서버가 정상으로 확정
    /// - `true` = 서버가 이상치로 플래그
    ///
    /// 기본값을 `false`로 두면 "아직 검증 전"이 "정상 확정"으로 둔갑해,
    /// 나중에 플래그될 기록을 축하하고 공유까지 시켜 버린다. 공유 카드는 앱 밖으로
    /// 나가면 회수할 수 없으므로(`gamification/domain/achievement_moment.dart`의
    /// 게이트 판정), 이 구분이 곧 안전장치다.
    ///
    /// 2026-08-26 추가 — gamification-designer의 공유 트리거 타이밍 설계 요청.
    bool? isFlagged,

    /// 플래그 사유. DB 컬럼 `runs.flag_reason`. [isFlagged]와 같은 규칙으로
    /// 서버 전용이다. 사용자에게 그대로 노출할 문구는 아니다(내부 코드에 가깝다).
    String? flagReason,

    /// 서버 재계산 **직전**의 클라이언트 주장 거리·이동시간
    /// (마이그레이션 64, DB 컬럼 `runs.client_reported jsonb`).
    ///
    /// [isFlagged]와 **같은 방침**이다 — `_serverOwnedKeys`가 업로드 payload에서
    /// 제거하고, 업로드 응답에서만 채택한다. 다만 로컬 저장에는 남아야 한다:
    /// 이 필드가 없던 동안 값은 `summaryJson`에만 얹혀 있어서, 다음 전체 로컬
    /// 재기록(`toRow()` → `toJson()`)에서 **조용히 사라졌다**(TRD §14 #27 잔여 ②).
    ///
    /// null의 뜻은 "거리 조정이 없었다"이다 — 서버가 값을 깎았을 때만 채우므로
    /// (§ [ClientReportedRun] 주석), `isFlagged`와 달리 "아직 모른다"와
    /// "조정 없음"을 구분할 필요가 없다. 조정 여부 판정은 [distanceWasAdjusted].
    ClientReportedRun? clientReported,

    /// 레코드 생성/수정 시각(UTC). 서버가 채운다.
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _RunRecord;

  factory RunRecord.fromJson(Map<String, dynamic> json) =>
      _$RunRecordFromJson(json);

  /// 표시용 파생값 — 저장하지 않는다.
  double get distanceKm => distanceMeters / 1000.0;

  /// 평균 속도(m/s). 이동 시간이 0이면 0.
  double get avgSpeedMps => movingSeconds == 0 ? 0 : distanceMeters / movingSeconds;

  bool get isActive =>
      status == RunStatus.recording || status == RunStatus.paused;

  /// 서버가 확정한 거리와 기기가 기록한 거리가 **눈에 띄게** 다른가.
  ///
  /// 상세 화면이 "기기 기록 10.0km → 확정 9.7km"를 병기할지 결정하는 단일
  /// 술어다(flutter-ui 계약). 이 값이 true일 때만 [clientReportedDistanceMeters]가
  /// non-null임이 보장된다.
  ///
  /// ## 임계 10m는 **표시용**이며 서버의 `v_flag_shrink_ratio`(0.8)와 무관하다
  /// 두 수는 서로 다른 질문에 답한다:
  /// - 서버 0.8 — "부정을 의심할 만큼 깎였는가" → `is_flagged`
  /// - 여기 10m — "사용자에게 두 숫자를 나란히 보여줄 가치가 있는가"
  ///
  /// 서버는 1m 이상 차이면 [clientReported]를 남기는데, 5.00km가 4.998km로
  /// 확정된 것까지 병기하면 배너가 상시 노출돼 **정말 깎인 기록의 신호를 덮는다.**
  /// 반대로 서버 임계(20%)를 그대로 쓰면 플래그 없이 3% 깎인 기록 —
  /// 사용자가 실제로 "왜 거리가 다르지?"라고 묻는 대다수 —이 설명 없이 남는다.
  ///
  /// 축소 방향만 본다: 서버는 재계산값이 주장값 이하일 때만 채택하므로
  /// (`least(recalc, claimed)`) 확정 거리가 더 큰 경우는 존재하지 않고,
  /// 혹시 생기더라도 "기기보다 더 뛴 것으로 확정"을 병기할 이유는 없다.
  bool get distanceWasAdjusted {
    final claimed = clientReported?.distanceMeters;
    if (claimed == null) return false;
    return claimed - distanceMeters > distanceAdjustmentDisplayThresholdMeters;
  }

  /// [distanceWasAdjusted]가 true일 때 병기할 **기기 기록 거리**(m).
  /// 조정이 없었으면 null — 호출부가 null 검사 하나로 분기하게 하려는 것이다.
  double? get clientReportedDistanceMeters =>
      distanceWasAdjusted ? clientReported!.distanceMeters : null;

  /// 확정 거리보다 얼마나 컸는가(m). 조정이 없었으면 null.
  double? get distanceAdjustmentMeters {
    final claimed = clientReportedDistanceMeters;
    return claimed == null ? null : claimed - distanceMeters;
  }

  /// 병기 임계(m). [distanceWasAdjusted] 주석 참조.
  static const double distanceAdjustmentDisplayThresholdMeters = 10.0;
}
