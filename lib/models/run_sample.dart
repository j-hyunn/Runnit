import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';

part 'run_sample.freezed.dart';
part 'run_sample.g.dart';

/// 러닝 중 수집된 단일 시점의 측정값.
///
/// **폰 GPS와 워치 센서를 하나의 모델로 통합한다.** 소스는 [source]로만 구분하며,
/// PhoneRunSample/WatchRunSample 같은 분리 모델을 만들지 않는다.
/// (분리 시 게이미피케이션·백엔드·UI 세 곳에서 소스 분기가 중복된다.)
///
/// ## 단위 규약
/// - 좌표: WGS84 도(degree), double
/// - 시각: UTC `DateTime` (직렬화 시 ISO-8601 문자열)
/// - 고도/정확도: 미터(m)
/// - 속도: 초당 미터(m/s)
/// - 심박수: 분당 박동수(bpm), 정수
@freezed
abstract class RunSample with _$RunSample {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory RunSample({
    /// WGS84 위도(deg). 실내 러닝(트레드밀) 샘플에서는 null.
    double? latitude,

    /// WGS84 경도(deg). 실내 러닝 샘플에서는 null.
    double? longitude,

    /// 샘플 측정 시각. **항상 UTC**로 저장한다.
    required DateTime timestamp,

    /// 해수면 기준 고도(m). 기압계/GPS 미지원 시 null.
    double? altitudeMeters,

    /// 수평 위치 정확도 반경(m). 값이 클수록 부정확 — 스무딩 필터의 입력.
    double? accuracyMeters,

    /// 순간 속도(m/s). 기기 미제공 시 null이며 소비 측에서 좌표 미분으로 대체한다.
    double? speedMps,

    /// 진행 방향(deg, 0=북, 시계방향). 미지원 시 null.
    double? headingDegrees,

    /// 순간 심박수(bpm). 웨어러블 연동 시에만 존재.
    int? heartRateBpm,

    /// 순간 케이던스(spm, steps per minute). 미지원 시 null.
    int? cadenceSpm,

    /// 세션 시작 시점부터의 누적 거리(m). 트래킹 엔진이 채운다.
    /// null이면 소비 측에서 좌표로 재계산해야 한다.
    double? cumulativeDistanceMeters,

    /// 이 샘플의 출처 장치.
    required RunSampleSource source,
  }) = _RunSample;

  factory RunSample.fromJson(Map<String, dynamic> json) =>
      _$RunSampleFromJson(json);
}
