import '../../../models/models.dart';

/// 러닝 수치의 **표시 포맷 단일 출처**.
///
/// 모델의 단위 규약(거리 m / 시간 s / 페이스 s·km⁻¹)을 화면 단위로 바꾸는 일을
/// 한 곳에 모은다. 각 위젯이 제각각 `toStringAsFixed`를 부르면 화면마다 소수 자리가
/// 어긋난다.
class RunFormat {
  const RunFormat._();

  /// 값이 아직 없을 때의 자리표시자. 0으로 표시하면 "0km를 뛰었다"로 읽힌다.
  static const String emptyPace = "--'--\"";

  /// 거리(m) → `12.34` (km, 소수 2자리).
  static String distanceKm(double meters) =>
      (meters / 1000.0).toStringAsFixed(2);

  /// 시간(s) → `mm:ss`, 1시간 이상이면 `h:mm:ss`.
  static String duration(int seconds) {
    final total = seconds < 0 ? 0 : seconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// 페이스(s/km) → `5'42"`. 값이 없거나 비정상이면 [emptyPace].
  ///
  /// 상한을 두는 이유: 출발 직후 몇 미터만 이동한 순간에는 페이스가 수십 분/km로
  /// 튀어 화면이 요동친다. 99분을 넘으면 아직 의미 없는 값으로 보고 감춘다.
  static String pace(double? secPerKm) {
    if (secPerKm == null ||
        !secPerKm.isFinite ||
        secPerKm <= 0 ||
        secPerKm > 99 * 60) {
      return emptyPace;
    }
    final total = secPerKm.round();
    final m = total ~/ 60;
    final s = total % 60;
    return "$m'${s.toString().padLeft(2, '0')}\"";
  }

  /// 진행 중 기록의 페이스. `avgPaceSecPerKm`이 비어 있으면 거리·이동시간으로 보완한다
  /// (트래킹 엔진은 거리 0인 초기 스냅샷에서 null을 준다).
  static String paceOf(RunRecord record) {
    final stored = record.avgPaceSecPerKm;
    if (stored != null) return pace(stored);
    if (record.distanceMeters <= 0 || record.movingSeconds <= 0) {
      return emptyPace;
    }
    return pace(record.movingSeconds / (record.distanceMeters / 1000.0));
  }

  /// 활동 유형의 한국어 라벨.
  static String activityLabel(ActivityType type) => switch (type) {
        ActivityType.outdoorRun => '야외 러닝',
        ActivityType.indoorRun => '실내 러닝',
        ActivityType.trailRun => '트레일',
        ActivityType.walk => '걷기',
      };

  /// 실내 러닝은 GPS 좌표가 없다 — 지도를 띄우지 않는다.
  static bool hasRoute(ActivityType type) => type != ActivityType.indoorRun;
}
