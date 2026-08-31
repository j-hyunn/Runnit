/// `RunRecord` + `List<RunSample>` → GPX 1.1 XML 직렬화 (HI-09, P1).
///
/// **클라이언트 전용이다** — 서버 렌더링을 요구하지 않는다(TRD §12). 위치 이력은
/// 사용자 자산이므로(PRD §6) 표준 GPX로 내보내 다른 러닝 앱·지도 서비스로 옮길 수
/// 있게 한다.
///
/// 외부 패키지(`xml`)를 끌어오지 않고 `StringBuffer`로 직접 쓴다 — GPX는 스키마가
/// 얕고(중첩 3단계), 우리가 쓰는 요소가 10개도 안 된다. 이스케이프만 정확히
/// 처리하면 충분하다.
///
/// ## 실내 러닝 / 좌표 없는 샘플
/// `latitude`·`longitude`가 null인 샘플(트레드밀)은 `<trkpt>`로 만들 수 없으므로
/// 건너뛴다. 좌표 있는 샘플이 2개 미만이면 그릴 트랙이 없다 — 그 경우
/// [hasExportableRoute]가 false를 돌려주고, 호출부는 내보내기 진입점 자체를
/// 노출하지 않는다.
library;

import '../../../models/models.dart';

/// GPX 트랙으로 만들 수 있는 좌표 샘플이 2개 이상인가.
bool hasExportableRoute(RunRecord record) {
  var count = 0;
  for (final s in record.samples) {
    if (s.latitude != null && s.longitude != null) {
      count++;
      if (count >= 2) return true;
    }
  }
  return false;
}

/// [record]를 GPX 1.1 문서 문자열로 직렬화한다.
///
/// 좌표 없는 샘플은 조용히 제외된다. 좌표 샘플이 하나도 없으면 `<trkseg>`가 빈
/// 채로 나온다 — 그런 레코드는 애초에 [hasExportableRoute]로 걸러야 한다.
String encodeRunAsGpx(RunRecord record) {
  final b = StringBuffer();
  b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  b.write('<gpx version="1.1" creator="Runnit" '
      'xmlns="http://www.topografix.com/GPX/1/1" '
      'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
      'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 '
      'http://www.topografix.com/GPX/1/1/gpx.xsd '
      'http://www.garmin.com/xmlschemas/TrackPointExtension/v1 '
      'http://www.garmin.com/xmlschemas/TrackPointExtensionv1.xsd">\n');

  final name = _trackName(record);
  b.writeln('  <metadata>');
  b.writeln('    <name>${_esc(name)}</name>');
  b.writeln('    <time>${_iso8601(record.startedAt)}</time>');
  b.writeln('  </metadata>');

  b.writeln('  <trk>');
  b.writeln('    <name>${_esc(name)}</name>');
  b.writeln('    <type>${_gpxType(record.activityType)}</type>');
  b.writeln('    <trkseg>');

  for (final s in record.samples) {
    final lat = s.latitude;
    final lon = s.longitude;
    if (lat == null || lon == null) continue;

    b.write('      <trkpt lat="${_coord(lat)}" lon="${_coord(lon)}">');
    b.write('\n');
    if (s.altitudeMeters != null) {
      b.writeln('        <ele>${s.altitudeMeters!.toStringAsFixed(1)}</ele>');
    }
    b.writeln('        <time>${_iso8601(s.timestamp)}</time>');
    if (s.heartRateBpm != null || s.cadenceSpm != null) {
      b.writeln('        <extensions>');
      b.writeln('          <gpxtpx:TrackPointExtension>');
      if (s.heartRateBpm != null) {
        b.writeln('            <gpxtpx:hr>${s.heartRateBpm}</gpxtpx:hr>');
      }
      if (s.cadenceSpm != null) {
        b.writeln('            <gpxtpx:cad>${s.cadenceSpm}</gpxtpx:cad>');
      }
      b.writeln('          </gpxtpx:TrackPointExtension>');
      b.writeln('        </extensions>');
    }
    b.writeln('      </trkpt>');
  }

  b.writeln('    </trkseg>');
  b.writeln('  </trk>');
  b.write('</gpx>\n');
  return b.toString();
}

String _trackName(RunRecord record) {
  final title = record.title?.trim();
  if (title != null && title.isNotEmpty) return title;
  return 'Runnit ${_dateLabel(record.startedAt)}';
}

/// GPX `<type>`는 자유 문자열이지만 소비 앱들이 관습적으로 쓰는 값에 맞춘다.
String _gpxType(ActivityType type) => switch (type) {
      ActivityType.walk => 'walking',
      _ => 'running',
    };

/// 위경도는 7자리(약 1cm 해상도)면 GPS 원본을 손실 없이 담는다.
String _coord(double value) => value.toStringAsFixed(7);

String _dateLabel(DateTime dt) {
  final u = dt.toUtc();
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${p2(u.month)}-${p2(u.day)}';
}

/// GPX 시각은 UTC ISO-8601(소수 초 없이). `DateTime.toIso8601String()`은
/// `.000`을 붙이고 로컬이면 오프셋을 붙이므로 직접 조립한다.
String _iso8601(DateTime dt) {
  final u = dt.toUtc();
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${p2(u.month)}-${p2(u.day)}'
      'T${p2(u.hour)}:${p2(u.minute)}:${p2(u.second)}Z';
}

String _esc(String s) {
  final b = StringBuffer();
  for (final rune in s.runes) {
    switch (rune) {
      case 0x26: // &
        b.write('&amp;');
      case 0x3C: // <
        b.write('&lt;');
      case 0x3E: // >
        b.write('&gt;');
      case 0x22: // "
        b.write('&quot;');
      case 0x27: // '
        b.write('&apos;');
      default:
        b.writeCharCode(rune);
    }
  }
  return b.toString();
}
