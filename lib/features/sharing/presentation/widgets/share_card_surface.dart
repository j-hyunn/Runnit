/// 공유 카드의 **9:16 프레임 + 캡처 계약**. 안쪽 그림은 flutter-ui-designer 담당.
///
/// ## 이 파일이 확정하는 것 (바꾸면 캡처가 깨진다)
/// 1. 카드는 항상 `AspectRatio(9/16)`이고 [RepaintBoundary]로 감싸여 있다.
/// 2. 그 경계의 [GlobalKey]를 밖에서 주입받는다 — 캡처하는 쪽이 키를 소유해야
///    "지금 화면에 있는 그 카드"를 정확히 굽는다.
/// 3. 카드 안에서는 `MediaQuery` 크기나 `Theme`의 화면 의존 값을 읽지 않는다.
///    카드는 1080×1920으로 구워지는 **고정 규격 인쇄물**이고, 기기마다 다르게
///    보이면 안 된다. 크기는 전부 카드 폭 대비 비율로 잡는다.
/// 4. 다크 모드를 따라가지 않는다. 인스타 스토리에 올라간 카드는 보는 사람의
///    테마와 무관하며, 브랜드 카드가 기기 설정에 따라 두 얼굴을 갖는 건 손해다.
///
/// ## 안쪽 그림
/// 2026-08-26 UI 작업에서 `widgets/share_card_body.dart`의 [ShareCardBody]가
/// 자리표시자(`DefaultShareCardBody`)를 대체했다. 자리표시자는 **삭제**했다 —
/// 남겨 두면 두 벌의 카드 디자인이 갈라지고, 어느 쪽이 실제로 공유되는지
/// 코드를 읽어야 알 수 있게 된다(뱃지 아트 경로가 두 벌이던 것과 같은 문제).
library;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_tokens.dart';
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppTokens.rLg),
          // 캡처된 PNG에 투명 영역이 남지 않도록 배경을 명시한다 —
          // 스토리 배경이 비쳐 글자가 안 보이는 사고를 막는다.
          child: ColoredBox(
            color: const Color(0xFF101216),
            // 카드는 1080×1920으로 구워지는 고정 규격 "인쇄물"이라, 보는
            // 사람의 시스템 글꼴 배율과 무관해야 한다(캡처 계약 ④, QA O-1).
            // 이게 없으면 `Text`가 `MediaQuery.textScalerOf`를 암묵적으로
            // 읽어 시스템 글꼴을 키운 사용자만 다른 글씨 크기가 찍힌 카드를
            // 얻는다.
            child: MediaQuery.withNoTextScaling(child: child),
          ),
        ),
      ),
    );
  }
}
