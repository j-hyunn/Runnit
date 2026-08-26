/// Google encoded polyline (precision 5) 인코더 + 경로 다운샘플링.
///
/// `RunRecord.routePolyline`은 **지도 썸네일용**이다(계약서 §2.2). 1시간 러닝의
/// 3600개 좌표를 그대로 인코딩하면 목록 조회 payload가 커지므로,
/// Ramer–Douglas–Peucker로 시각적으로 동일한 최소 점 집합만 남긴 뒤 인코딩한다.
library;

import 'dart:math' as math;

class LatLngPoint {
  const LatLngPoint(this.latitude, this.longitude);
  final double latitude;
  final double longitude;
}

/// 경로를 [toleranceMeters] 오차 안에서 단순화한다(RDP).
/// 재귀 대신 명시 스택을 쓴다 — 장거리 러닝에서 재귀 깊이가 수천에 달할 수 있다.
List<LatLngPoint> simplifyRoute(
  List<LatLngPoint> points, {
  double toleranceMeters = 5,
}) {
  if (points.length <= 2) return List<LatLngPoint>.of(points);

  final keep = List<bool>.filled(points.length, false);
  keep[0] = true;
  keep[points.length - 1] = true;

  final stack = <List<int>>[
    [0, points.length - 1],
  ];

  while (stack.isNotEmpty) {
    final range = stack.removeLast();
    final start = range[0];
    final end = range[1];
    if (end <= start + 1) continue;

    var maxDistance = 0.0;
    var maxIndex = -1;
    for (var i = start + 1; i < end; i++) {
      final d = _perpendicularMeters(points[i], points[start], points[end]);
      if (d > maxDistance) {
        maxDistance = d;
        maxIndex = i;
      }
    }

    if (maxIndex != -1 && maxDistance > toleranceMeters) {
      keep[maxIndex] = true;
      stack.add([start, maxIndex]);
      stack.add([maxIndex, end]);
    }
  }

  final result = <LatLngPoint>[];
  for (var i = 0; i < points.length; i++) {
    if (keep[i]) result.add(points[i]);
  }
  return result;
}

/// 위경도를 등거리 평면으로 근사해 점-선분 수직거리(m)를 구한다.
/// 러닝 경로 규모(수 km)에서 근사 오차는 무시할 수준이다.
double _perpendicularMeters(LatLngPoint p, LatLngPoint a, LatLngPoint b) {
  const metersPerDegreeLat = 111320.0;
  final latScale = math.cos(a.latitude * math.pi / 180) * metersPerDegreeLat;

  final px = (p.longitude - a.longitude) * latScale;
  final py = (p.latitude - a.latitude) * metersPerDegreeLat;
  final bx = (b.longitude - a.longitude) * latScale;
  final by = (b.latitude - a.latitude) * metersPerDegreeLat;

  final lengthSquared = bx * bx + by * by;
  if (lengthSquared == 0) return math.sqrt(px * px + py * py);

  var t = (px * bx + py * by) / lengthSquared;
  t = t.clamp(0.0, 1.0);
  final dx = px - bx * t;
  final dy = py - by * t;
  return math.sqrt(dx * dx + dy * dy);
}

/// Google encoded polyline algorithm, precision 5.
String encodePolyline(List<LatLngPoint> points) {
  final buffer = StringBuffer();
  var prevLat = 0;
  var prevLon = 0;

  for (final point in points) {
    final lat = (point.latitude * 1e5).round();
    final lon = (point.longitude * 1e5).round();
    _encodeValue(buffer, lat - prevLat);
    _encodeValue(buffer, lon - prevLon);
    prevLat = lat;
    prevLon = lon;
  }
  return buffer.toString();
}

void _encodeValue(StringBuffer buffer, int value) {
  var v = value < 0 ? ~(value << 1) : value << 1;
  while (v >= 0x20) {
    buffer.writeCharCode((0x20 | (v & 0x1f)) + 63);
    v >>= 5;
  }
  buffer.writeCharCode(v + 63);
}

/// [encodePolyline]의 역변환.
///
/// 2026-08-26 공유 카드(HI-08)를 위해 추가했다. 카드는 `RunRecord.routePolyline`
/// 하나만 들고 경로를 그려야 하는 경우가 있다 — 목록/랭킹 경로로 받은 레코드는
/// `samples`가 비어 있고(payload 절감, 모델 주석 참조) 썸네일용 폴리라인만 온다.
/// 그 상황에서 샘플을 다시 조회하려고 네트워크를 타면, 공유 버튼을 누른 직후
/// 카드가 뜨기까지 왕복이 하나 더 생긴다.
///
/// 손상된 문자열이 오면 그때까지 해독한 점만 돌려준다(예외를 던지지 않는다) —
/// 경로는 카드의 장식이지 본체가 아니므로, 깨진 폴리라인 하나가 공유 자체를
/// 막아서는 안 된다.
List<LatLngPoint> decodePolyline(String encoded) {
  final points = <LatLngPoint>[];
  var index = 0;
  var lat = 0;
  var lon = 0;

  while (index < encoded.length) {
    final dLat = _decodeValue(encoded, index);
    if (dLat == null) break;
    index = dLat.nextIndex;

    final dLon = _decodeValue(encoded, index);
    if (dLon == null) break;
    index = dLon.nextIndex;

    lat += dLat.value;
    lon += dLon.value;
    points.add(LatLngPoint(lat / 1e5, lon / 1e5));
  }
  return points;
}

({int value, int nextIndex})? _decodeValue(String encoded, int start) {
  var index = start;
  var shift = 0;
  var result = 0;
  int chunk;

  do {
    if (index >= encoded.length) return null;
    chunk = encoded.codeUnitAt(index) - 63;
    if (chunk < 0) return null;
    result |= (chunk & 0x1f) << shift;
    shift += 5;
    index++;
  } while (chunk >= 0x20);

  final value = (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  return (value: value, nextIndex: index);
}
