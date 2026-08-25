/// 단위 규약과 변환 유틸 — **프로젝트 전체의 단위 기준점**.
///
/// 저장/전송되는 모든 값은 SI 단위다:
/// - 거리: 미터(m)
/// - 시간: 초(s)
/// - 속도: 초당 미터(m/s)
/// - 페이스: 초/킬로미터(s/km)
/// - 고도: 미터(m)
/// - 심박수: bpm, 케이던스: spm
/// - 칼로리: kcal
/// - 시각: UTC DateTime (직렬화 시 ISO-8601)
///
/// km/mile, "5'30\"/km" 같은 표현은 **표시 계층에서만** 만든다.
library;

class Units {
  const Units._();

  static const double metersPerKilometer = 1000.0;
  static const double metersPerMile = 1609.344;
  static const int secondsPerMinute = 60;

  /// m/s → s/km. 속도가 0 이하이면 null(무한대 페이스).
  static double? paceSecPerKmFromSpeed(double speedMps) =>
      speedMps <= 0 ? null : metersPerKilometer / speedMps;

  /// 거리(m) + 이동시간(s) → 평균 페이스(s/km). 거리 0이면 null.
  static double? avgPaceSecPerKm({
    required double distanceMeters,
    required int movingSeconds,
  }) {
    if (distanceMeters <= 0) return null;
    return movingSeconds / (distanceMeters / metersPerKilometer);
  }

  static double metersToKm(double meters) => meters / metersPerKilometer;
  static double metersToMiles(double meters) => meters / metersPerMile;
}
