/// OS 공유 시트의 iPad 팝오버 앵커(`sharePositionOrigin`) 계산.
///
/// iPad에서 `Share.share*`는 팝오버로 뜨고, 앵커 사각형이 없으면 시트를 아예
/// 띄우지 못하거나 화면 중앙에 임의로 붙는다. 앵커는 **사용자가 실제로 누른
/// 위젯**이어야 팝오버 꼬리가 그 버튼을 가리킨다.
///
/// ## 흔한 실수 (QA A-6)
/// 페이지 `build`의 `context`로 `context.findRenderObject()`를 부르면 그건
/// **페이지 전체의 RenderBox**다 — 앵커가 화면 전체 사각형이 되어 팝오버가
/// 버튼과 무관한 곳에서 뜬다. 따라서 이 파일의 함수는 **액션 위젯에 붙인
/// [GlobalKey]** 를 받는다. 호출부는 그 키를 반드시 버튼 위젯에 달아야 한다.
library;

import 'package:flutter/widgets.dart';

/// [key]가 가리키는 위젯의 전역 좌표 사각형. 계산할 수 없으면 null.
///
/// null이면 호출부는 그대로 넘기면 된다 — iPhone/Android는 앵커를 쓰지 않고,
/// iPad에서도 OS가 기본 위치로 떨어뜨린다(어색할 뿐 실패는 아니다).
Rect? shareOriginOfKey(GlobalKey key) {
  final render = key.currentContext?.findRenderObject();
  if (render is! RenderBox || !render.attached || !render.hasSize) return null;
  return render.localToGlobal(Offset.zero) & render.size;
}
