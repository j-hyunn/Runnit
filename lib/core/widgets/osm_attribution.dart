import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// OpenStreetMap 타일 출처 표기.
///
/// `tile.openstreetmap.org`를 쓰는 모든 지도에 **반드시** 얹어야 한다(OSMF의
/// 타일 이용 정책 — 선택 아님). 트래킹 지도([RunMapView])와 기록 상세 지도
/// ([RunRouteMap])가 같은 걸 쓰도록 여기로 올렸다.
///
/// 자체 반투명 배경을 갖고 있어 타일 위에서도, 트래킹 화면의 일시정지 딤
/// 오버레이 위에서도 읽힌다 — 스택에서 딤보다 **뒤에** 두지 말 것.
class OsmAttribution extends StatelessWidget {
  const OsmAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppTokens.s4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0xE6FFFFFF),
          borderRadius: BorderRadius.all(Radius.circular(AppTokens.rSm)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            '© OpenStreetMap contributors',
            style: TextStyle(
              fontSize: 10,
              height: 1.2,
              color: Color(0xFF4A4A4A),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
