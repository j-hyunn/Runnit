/// 공유 카드 위젯 → PNG 바이트. **클라이언트 렌더링 확정**(ARCHITECTURE §12 #3,
/// TRD §14 #3 — 2026-08-26 해소).
///
/// ## 왜 서버 렌더링이 아닌가
/// 1. **디자인 시스템이 Flutter에만 있다.** 티어 색(`AppTokens`), Pretendard
///    가변 폰트, 뱃지 SVG 146종이 전부 앱 자산이다. 서버에서 같은 그림을 그리려면
///    HTML/Canvas 스택에 그 전부를 **두 번째로** 구현해야 하고, 두 구현이 어긋나는
///    날 사용자는 앱에서 본 것과 다른 카드를 인스타에 올린다.
/// 2. **비용과 지연이 0.** 마케팅 예산 0원(BRD)이라 공유는 유일한 성장 레버인데,
///    그 레버에 서버 왕복과 이미지 저장 비용을 얹을 이유가 없다.
/// 3. **성취 직후에 동작해야 한다(HI-10).** 러닝 종료 지점은 신호가 나쁜 곳일 수
///    있다 — 오프라인 우선 원칙(§9)을 공유에도 그대로 적용한다. 캡처는 네트워크
///    없이 끝난다.
/// 4. **경로 좌표가 기기 밖으로 나가지 않는다.** 이미지 한 장 만들자고 집 근처
///    GPS 트랙을 서버로 올릴 필요가 없다.
///
/// 서버 렌더링이 필요해지는 유일한 시나리오는 **링크 공유의 OG 이미지**(웹에서
/// URL 미리보기)인데, PRD가 요구하는 것은 스토리에 올릴 **이미지 파일**이다.
/// 그 요구가 생기면 그때 별도로 붙인다 — 지금의 클라이언트 경로를 대체하는 게
/// 아니라 추가된다.
///
/// ## 왜 `screenshot` 패키지를 쓰지 않는가
/// 그 패키지는 아래 `toImage()` 호출을 감싼 얇은 래퍼다. 우리는 기기 화면 해상도와
/// 무관하게 **항상 1080×1920**을 내보내야 해서 `pixelRatio`를 직접 계산하는데,
/// 래퍼는 그 계산에 필요한 경계 크기를 감춘다.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 인스타그램 스토리 규격(PRD HI-08 "9:16"). 1080×1920은 스토리 권장 해상도이자
/// 대부분의 기기에서 업스케일 없이 선명한 최소 크기다.
const int shareCardPixelWidth = 1080;
const int shareCardPixelHeight = 1920;
const double shareCardAspectRatio = 9 / 16;

/// 캡처 실패. 호출부는 이걸 잡아 "공유할 이미지를 만들지 못했어요"로 바꾼다 —
/// 캡처 실패가 요약 화면 전체를 무너뜨리면 안 된다.
class ShareCardRenderException implements Exception {
  const ShareCardRenderException(this.message);
  final String message;
  @override
  String toString() => 'ShareCardRenderException: $message';
}

/// [boundaryKey]가 가리키는 [RepaintBoundary]를 PNG로 굽는다.
///
/// ## 호출 계약 (flutter-ui-designer)
/// - 카드 위젯은 **화면에 실제로 올라가 있어야** 한다. `Offstage`는 페인트를
///   건너뛰므로 캡처가 빈 이미지가 되거나 예외가 된다. HI-10 흐름은 "공유 버튼 →
///   카드 미리보기 시트 → 공유"라 카드는 어차피 눈에 보인다 — 그 시트의 카드를
///   그대로 캡처한다.
/// - 카드는 `AspectRatio(aspectRatio: shareCardAspectRatio)`로 9:16을 유지한다.
///   논리 폭이 얼마든 출력은 [targetWidth]로 고정되므로, 작은 기기에서 카드가
///   작게 보여도 결과 이미지 해상도는 같다.
/// - 첫 프레임에 곧바로 부르지 않는다. 위젯이 아직 레이아웃되지 않았거나
///   (`debugNeedsPaint`) 폰트/SVG가 로드 중이면 흐릿하거나 빈 그림이 나온다.
///   [captureCard]는 프레임 하나를 기다린 뒤 캡처한다.
Future<Uint8List> captureCard(
  GlobalKey boundaryKey, {
  int targetWidth = shareCardPixelWidth,
}) async {
  // 레이아웃/폰트가 정착한 다음 프레임에서 굽는다.
  await WidgetsBinding.instance.endOfFrame;

  final object = boundaryKey.currentContext?.findRenderObject();
  if (object is! RenderRepaintBoundary) {
    throw const ShareCardRenderException(
      '카드가 아직 화면에 없습니다 (RepaintBoundary를 찾지 못함)',
    );
  }

  final logicalWidth = object.size.width;
  if (logicalWidth <= 0) {
    throw const ShareCardRenderException('카드 크기가 0입니다');
  }

  // 기기 DPI가 아니라 **원하는 출력 폭**에서 배율을 역산한다.
  // 이래야 갤럭시든 SE든 결과가 정확히 같은 1080×1920이 된다.
  final pixelRatio = targetWidth / logicalWidth;

  final image = await object.toImage(pixelRatio: pixelRatio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw const ShareCardRenderException('PNG 인코딩에 실패했습니다');
    }
    return data.buffer.asUint8List();
  } finally {
    // 1080×1920 RGBA는 약 8MB다. GC를 기다리면 연속 공유 시 메모리가 튄다.
    image.dispose();
  }
}
