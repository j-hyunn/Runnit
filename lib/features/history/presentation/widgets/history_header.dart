import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme/app_tokens.dart';

/// 활동(히스토리) 계열 **전체화면 페이지**가 공유하는 상단 헤더 —
/// 뒤로가기 chevron + 제목.
///
/// 이 화면들은 Figma에 전용 프레임이 없다(활동 프레임엔 미리보기 3건과 버튼만
/// 있다). 그래서 앱 전역에서 이미 쓰는 헤더 패턴([FullRankingPage] 참고)을
/// 여기 한 벌만 두고 [RunHistoryListPage]·[RunDetailPage]가 같이 쓴다 —
/// 전에는 각 화면이 chevron 뒤집기 코드를 따로 갖고 있었다.
///
/// `AppBar`를 쓰지 않는 이유는 이 계열 화면이 모두 흰 배경 + 20/600 제목이라,
/// Material의 기본 elevation·surfaceTint를 매번 지우는 편이 더 번거롭기 때문이다.
class HistoryHeader extends StatelessWidget {
  const HistoryHeader({super.key, required this.title, this.onBack});

  final String title;

  /// null이면 `Navigator.pop`. 헤더가 화면 밖 사정을 몰라도 되게 기본값을 둔다.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: '뒤로',
            child: InkWell(
              onTap: onBack ?? () => Navigator.of(context).maybePop(),
              borderRadius: BorderRadius.circular(AppTokens.rPill),
              child: Transform.flip(
                flipX: true,
                child: SvgPicture.asset(
                  'assets/icons/chevron_right.svg',
                  width: 24,
                  height: 24,
                  colorFilter:
                      const ColorFilter.mode(Colors.black, BlendMode.srcIn),
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
        ],
      ),
    );
  }
}
