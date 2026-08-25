import 'units.dart';

/// 표시 전용 포맷터. 저장값(SI)을 사람이 읽는 문자열로만 바꾼다.
/// 여기서 계산 로직을 만들지 말 것 — 계산은 domain 계층 책임.
class Formatters {
  const Formatters._();

  /// 3421.7m -> "3.42"
  static String km(double meters, {int fractionDigits = 2}) =>
      Units.metersToKm(meters).toStringAsFixed(fractionDigits);

  /// 330.0 s/km -> "5'30\"".
  static String pace(double? secPerKm) {
    if (secPerKm == null || secPerKm.isNaN || secPerKm.isInfinite) return '--\'--"';
    final total = secPerKm.round();
    final m = total ~/ 60;
    final s = total % 60;
    return "$m'${s.toString().padLeft(2, '0')}\"";
  }

  /// 3725초 -> "1:02:05", 305초 -> "5:05"
  static String duration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
    return '$m:$ss';
  }
}
