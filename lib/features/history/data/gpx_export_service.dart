/// GPX 파일 생성 + OS 공유 시트 연결 (HI-09).
///
/// 직렬화(`domain/gpx_encoder.dart`)와 분리한다 — 인코더는 순수 함수라 단위
/// 테스트하고, 이쪽은 파일 I/O + 플랫폼 채널이라 통합 지점에서만 확인한다
/// (`sharing/data/share_service.dart`와 같은 구조).
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../models/models.dart';
import '../domain/gpx_encoder.dart';

/// GPX 내보내기 시도의 결과. 공유 카드([ShareOutcome])와 같은 이유로 "게시 성공"을
/// 단언하지 않는다 — OS는 사용자가 실제로 파일을 저장/전송했는지 알려주지 않는다.
enum GpxExportOutcome {
  /// 공유 시트가 떴다. 이후는 알 수 없다.
  presented,

  /// 사용자가 시트를 그냥 닫았다(알 수 있는 플랫폼에서만).
  dismissed,

  /// 내보낼 경로 좌표가 없다(실내 러닝 등) — 진입점에서 걸러야 정상.
  noRoute,

  /// 직렬화·파일 쓰기·공유 중 실패.
  failed,
}

final gpxExportServiceProvider = Provider<GpxExportService>(
  (ref) => const GpxExportService(),
);

class GpxExportService {
  const GpxExportService();

  /// [record]를 GPX로 직렬화해 임시 파일로 쓰고 OS 공유 시트를 연다.
  ///
  /// [origin]은 iPad 팝오버 앵커 — 없으면 iPad에서 시트가 뜨지 않는다.
  Future<GpxExportOutcome> exportAndShare(
    RunRecord record, {
    Rect? origin,
  }) async {
    if (!hasExportableRoute(record)) return GpxExportOutcome.noRoute;

    try {
      final xml = encodeRunAsGpx(record);
      final file = await _writeTempGpx(xml, record);

      final result = await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/gpx+xml')],
        sharePositionOrigin: origin,
      );

      return switch (result.status) {
        ShareResultStatus.dismissed => GpxExportOutcome.dismissed,
        _ => GpxExportOutcome.presented,
      };
    } catch (_) {
      return GpxExportOutcome.failed;
    }
  }

  /// 캐시 디렉터리에 쓴다 — 공유 후에는 쓸모없는 파일이라 OS가 공간이 빠듯할 때
  /// 알아서 지운다(`share_service.dart`와 같은 판단).
  Future<File> _writeTempGpx(String xml, RunRecord record) async {
    final dir = await getTemporaryDirectory();
    final exportDir = Directory(p.join(dir.path, 'gpx_exports'));
    if (!exportDir.existsSync()) {
      await exportDir.create(recursive: true);
    }
    final file = File(p.join(exportDir.path, _fileName(record)));
    return file.writeAsString(xml, flush: true);
  }

  /// `runnit_YYYYMMDD_HHMM.gpx` — 시작 시각(로컬) 기준. 같은 분에 두 번
  /// 내보내면 덮어쓰지만, 공유용 임시 파일이라 문제되지 않는다.
  static String _fileName(RunRecord record) {
    final t = record.startedAt.toLocal();
    String p2(int n) => n.toString().padLeft(2, '0');
    return 'runnit_${t.year}${p2(t.month)}${p2(t.day)}_'
        '${p2(t.hour)}${p2(t.minute)}.gpx';
  }
}
