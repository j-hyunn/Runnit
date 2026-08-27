/// OS 공유 시트 연결. 캡처([captureCard])와 분리해 둔다 — 캡처는 순수 렌더링,
/// 이쪽은 파일 I/O + 플랫폼 채널이라 테스트에서 갈아 끼우는 단위가 다르다.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/share_card_data.dart';
import 'share_card_renderer.dart';

/// 공유 시도의 결과. `ShareResultStatus`를 그대로 노출하지 않는 이유:
/// **OS는 사용자가 실제로 게시했는지 알려주지 않는다.** iOS는 취소 여부만,
/// 안드로이드는 그마저도 신뢰할 수 없다. 화면이 "공유 완료!"라고 단언하면
/// 거짓말이 되므로, 성공/실패 대신 "시트를 열었다 / 열지 못했다"만 구분한다.
enum ShareOutcome {
  /// 공유 시트가 떴다. 게시 여부는 알 수 없다.
  presented,

  /// 사용자가 시트를 그냥 닫았다(알 수 있는 플랫폼에서만).
  dismissed,

  /// 캡처 또는 공유 자체가 실패했다.
  failed,
}

abstract interface class ShareService {
  /// 카드 위젯을 굽고 OS 공유 시트를 연다.
  ///
  /// [boundaryKey]는 카드 위젯을 감싼 [RepaintBoundary]의 키.
  /// [origin]은 iPad 팝오버 앵커 — 없으면 iPad에서 시트가 뜨지 않는다.
  Future<ShareOutcome> shareCard({
    required GlobalKey boundaryKey,
    required ShareCardData card,
    Rect? origin,
  });
}

class ShareServiceImpl implements ShareService {
  const ShareServiceImpl();

  @override
  Future<ShareOutcome> shareCard({
    required GlobalKey boundaryKey,
    required ShareCardData card,
    Rect? origin,
  }) async {
    try {
      final bytes = await captureCard(boundaryKey);
      final file = await _writeTempPng(bytes, card.kind);

      final result = await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: card.shareText,
        sharePositionOrigin: origin,
      );

      return switch (result.status) {
        ShareResultStatus.dismissed => ShareOutcome.dismissed,
        _ => ShareOutcome.presented,
      };
    } catch (_) {
      // 공유는 부가 기능이다 — 실패해도 성취 화면 자체는 살아 있어야 한다.
      return ShareOutcome.failed;
    }
  }

  /// 캐시 디렉터리에 쓴다(문서 디렉터리가 아니라).
  ///
  /// 공유용 PNG는 OS가 대상 앱에 넘긴 뒤로는 쓸모가 없다. 캐시에 두면 저장 공간이
  /// 빠듯할 때 OS가 알아서 지우고, iOS에서는 iCloud 백업 대상에서도 빠진다.
  /// 파일명에 타임스탬프를 넣어 연속 공유 시 이전 파일을 덮지 않게 한다 —
  /// 일부 안드로이드 기기에서 같은 경로를 재사용하면 대상 앱이 캐시된 옛 이미지를
  /// 집는다.
  Future<File> _writeTempPng(Uint8List bytes, ShareCardKind kind) async {
    final dir = await getTemporaryDirectory();
    final shareDir = Directory(p.join(dir.path, 'share_cards'));
    if (!shareDir.existsSync()) {
      await shareDir.create(recursive: true);
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file = File(p.join(shareDir.path, 'runnit_${kind.name}_$stamp.png'));
    return file.writeAsBytes(bytes, flush: true);
  }
}
