/// 카카오 OAuth 딥링크 설정.
///
/// Supabase의 OAuth 웹 플로우(`signInWithOAuth`)는 브라우저(ASWebAuthenticationSession /
/// Custom Tabs)를 띄운 뒤, 인증이 끝나면 **앱 커스텀 스킴 딥링크**로 돌아온다.
/// `supabase_flutter`가 그 딥링크를 가로채 세션을 복원하고
/// `onAuthStateChange`로 흘려보낸다(`detectSessionInUri` 기본 true).
///
/// 카카오 네이티브 SDK(`kakao_flutter_sdk`)는 쓰지 않는다 — 범위 밖이다.
class AuthConfig {
  const AuthConfig._();

  /// 앱 커스텀 URL 스킴. iOS `Info.plist`(CFBundleURLSchemes)와
  /// Android `AndroidManifest.xml`(intent-filter data android:scheme)에
  /// **동일하게** 등록되어야 한다.
  static const String appScheme = 'io.runnit.app';

  /// OAuth 콜백 호스트. Supabase 대시보드
  /// Authentication → URL Configuration → Redirect URLs 에도 등록해야 한다.
  static const String oauthCallbackHost = 'login-callback';

  /// `signInWithOAuth(redirectTo:)`에 넘기는 값.
  /// 예: `io.runnit.app://login-callback`
  ///
  /// 빌드별로 바꿔야 하면 `--dart-define=OAUTH_REDIRECT_URL=...`로 덮어쓴다.
  static const String oauthRedirectUrl = String.fromEnvironment(
    'OAUTH_REDIRECT_URL',
    defaultValue: '$appScheme://$oauthCallbackHost',
  );
}
