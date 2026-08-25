import 'package:flutter/material.dart';

import '../../../../core/theme/app_tokens.dart';

/// 카카오 로그인 버튼.
///
/// 카카오 공식 가이드에 맞춰 배경 `#FEE500` / 라벨 `#191919`를 고정한다.
/// (테마 색을 쓰지 않는 유일한 버튼이다 — 소셜 로그인 버튼은 프로바이더의
///  브랜드 색을 유지해야 사용자가 식별할 수 있다.)
///
/// 로고 이미지 에셋이 없으므로 말풍선 심볼은 [Icons.chat_bubble] 로 대체한다.
class KakaoLoginButton extends StatelessWidget {
  const KakaoLoginButton({
    required this.onPressed,
    this.isLoading = false,
    this.label = '카카오 로그인',
    super.key,
  });

  final VoidCallback? onPressed;

  /// true면 스피너를 보여주고 입력을 막는다.
  /// **주의**: 이 로딩은 "브라우저를 띄우는 중"까지만이다. 로그인 완료 대기가 아니다.
  final bool isLoading;

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        onPressed: isLoading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppTokens.kakaoYellow,
          foregroundColor: AppTokens.kakaoLabel,
          disabledBackgroundColor: AppTokens.kakaoYellow.withValues(alpha: 0.6),
          disabledForegroundColor: AppTokens.kakaoLabel.withValues(alpha: 0.6),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.rMd),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        child: isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppTokens.kakaoLabel),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.chat_bubble, size: 19),
                  const SizedBox(width: AppTokens.s8),
                  Flexible(
                    child: Text(label, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
      ),
    );
  }
}
