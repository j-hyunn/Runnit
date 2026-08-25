import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';
import 'run_sample.dart';

part 'run_record.freezed.dart';
part 'run_record.g.dart';

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
}
