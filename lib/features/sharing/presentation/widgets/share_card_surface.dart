/// 공유 카드의 **9:16 투명 프레임 + 캡처 계약**. 안쪽 그림은 `share_card_body.dart`.
///
/// ## 이 파일이 확정하는 것 (바꾸면 캡처가 깨진다)
/// 1. 카드는 항상 `AspectRatio(shareCardAspectRatio)`(9:16)이고 [RepaintBoundary]로
///    감싸여 있다.
/// 2. 그 경계의 [GlobalKey]를 밖에서 주입받는다 — 캡처하는 쪽이 키를 소유해야
///    "지금 화면에 있는 그 카드"를 정확히 굽는다.
/// 3. 카드 안에서는 `MediaQuery` 크기나 `Theme`의 화면 의존 값을 읽지 않는다.
///    카드는 1080×1920으로 구워지는 **고정 규격 인쇄물**이고, 기기마다 다르게
///    보이면 안 된다. 크기는 전부 카드 **높이** 대비 비율로 잡는다.
/// 4. 다크 모드를 따라가지 않는다. 스티커가 얹히는 곳은 사용자의 사진이지
///    보는 사람의 테마가 아니다.
/// 5. **배경을 칠하지 않는다.** ← 2026-08-26 변경의 핵심.
///
/// ## 왜 배경(그리고 둥근 모서리)이 사라졌는가
/// 이전에는 `ClipRRect` + `ColoredBox(0xFF101216)`로 불투명 카드를 만들었다.
/// 지금 카드는 사용자가 **자기 사진 위에 얹는 오버레이 스티커**다(렌더러 문서
/// 참조). 배경색을 칠하면 사진이 가려져 스티커의 존재 이유가 사라지고, 둥근
/// 모서리는 "여기 판때기가 하나 붙어 있다"는 프레임 신호를 남긴다 — 사진 위에
/// 자연스럽게 앉으려면 글자와 선만 남아야 한다.
///
/// 글자와 경로 선에 그림자/halo도 달지 않는다(2026-08-26, 사용자 요청) —
/// 레퍼런스 이미지가 순수한 흰 선·글자였다. 밝은 사진 위 대비는 이 카드가
/// 책임지지 않는다.
library;

import 'package:flutter/material.dart';

import '../../data/share_card_renderer.dart';

/// 캡처 대상 프레임. 카드 위젯은 **반드시** 이걸 통해 화면에 올라간다.
class ShareCardSurface extends StatelessWidget {
  const ShareCardSurface({
    required this.boundaryKey,
    required this.child,
    super.key,
  });

  /// `captureCard(boundaryKey)`에 넘길 키. 시트/페이지가 소유한다.
  final GlobalKey boundaryKey;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: shareCardAspectRatio,
      child: RepaintBoundary(
        key: boundaryKey,
        // ⚠️ 여기에 ColoredBox/DecoratedBox/Container(color:)를 넣지 않는다.
        // 하나라도 들어가면 캡처된 PNG의 알파가 사라지고 스티커가 아니라
        // 사진을 덮는 판때기가 된다.
        //
        // 카드는 1080×1920으로 구워지는 고정 규격 "인쇄물"이라, 보는 사람의
        // 시스템 글꼴 배율과 무관해야 한다(캡처 계약 ③, QA O-1). 이게 없으면
        // `Text`가 `MediaQuery.textScalerOf`를 암묵적으로 읽어 시스템 글꼴을
        // 키운 사용자만 다른 글씨 크기가 찍힌 카드를 얻는다.
        child: MediaQuery.withNoTextScaling(child: child),
      ),
    );
  }
}
