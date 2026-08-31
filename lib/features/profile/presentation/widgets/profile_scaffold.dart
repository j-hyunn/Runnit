import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme/app_tokens.dart';

/// 프로필 계열 하위 화면(AC-02 편집 / AC-03 타인 프로필)의 공통 껍데기.
///
/// 앱에 이미 있는 헤더 패턴(`full_ranking_page.dart` / `history_header.dart`)을
/// 그대로 따른다 — 좌측 chevron(뒤로) + 20/w600 타이틀, `fromLTRB(16,15,16,15)`.
/// 배경은 마이페이지와 같은 `#F8F8F8`이라 흰 카드가 떠 보인다.
///
/// **`AppShell`의 바텀 여백을 넣지 않는다.** 이 두 화면은 탭 위에 push되는
/// 전체 화면이고, 셸의 플로팅 알약 네비바는 push된 라우트 위에 겹치지 않는다.
class ProfileScaffold extends StatelessWidget {
  const ProfileScaffold({
    super.key,
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
              child: Row(
                children: [
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(AppTokens.rPill),
                    child: Transform.flip(
                      flipX: true,
                      // chevron_left 에셋이 따로 없어 chevron_right를 좌우
                      // 반전해 재사용한다(전체 랭킹 화면과 같은 방식).
                      child: SvgPicture.asset(
                        'assets/icons/chevron_right.svg',
                        width: 24,
                        height: 24,
                        colorFilter: const ColorFilter.mode(
                          Colors.black,
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
