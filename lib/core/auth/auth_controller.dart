import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/supabase_client.dart';
import '../error/failure.dart';
import 'auth_config.dart';

/// 로그인/로그아웃 **액션**. 인증 *상태*는 `authStateProvider`가 따로 들고 있다.
///
/// 상태 의미:
/// - `AsyncData(null)`  : 대기 중(또는 브라우저 실행 완료)
/// - `AsyncLoading()`   : 브라우저를 띄우는 중 / 로그아웃 처리 중
/// - `AsyncError(Failure)` : 실패. `error`는 항상 [Failure] 타입이다.
///
/// **중요 — 로그인 완료 시점**: [signInWithKakao]가 반환되는 시점은
/// "카카오 인증 화면을 띄우는 데 성공했다"는 뜻일 뿐, 로그인 완료가 아니다.
/// 실제 세션은 딥링크(`io.runnit.app://login-callback`)로 앱에 돌아온 뒤
/// `onAuthStateChange` → `authStateProvider`로 반영된다.
/// 따라서 로그인 화면은 **`authStateProvider`(또는 `isAuthenticatedProvider`)를
/// 성공 신호로 삼아야** 하며, 화면 전환은 라우터 `redirect`가 알아서 처리한다.
/// (사용자가 브라우저를 그냥 닫으면 아무 이벤트도 오지 않으므로, 로그인 화면의
/// 스피너는 이 컨트롤러 상태에만 묶어 두고 무한 로딩을 만들지 말 것.)
class AuthController extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData(null);

  SupabaseClient get _client => ref.read(supabaseClientProvider);

  /// 카카오 소셜 로그인 시작. 이 앱의 **유일한** 로그인 수단이다.
  ///
  /// Supabase 내장 OAuth 프로바이더(`OAuthProvider.kakao`)의 웹 플로우를 쓴다.
  /// 카카오 네이티브 SDK는 도입하지 않는다.
  ///
  /// **`signInWithOAuth()` 대신 수동 2단계 플로우를 쓰는 이유**: 그 편의
  /// 메서드는 내부적으로 `url_launcher`의 `LaunchMode`(플랫폼 기본값은 iOS에서
  /// 인앱 SFSafariViewController)로 인증 페이지를 연다. 문제는
  /// SFSafariViewController는 커스텀 스킴(`io.runnit.app://...`) 리다이렉트가
  /// 와도 **자동으로 닫히지 않는다** — 앱은 딥링크를 이미 받아 세션을 복원
  /// 했는데, 화면에는 빈 브라우저 시트가 그대로 남아 사용자가 갇힌 것처럼
  /// 보였다(실기기/시뮬레이터 모두 재현). 외부 Safari로 강제 전환하면
  /// 고쳐지긴 하지만 로그인 중 앱을 완전히 떠났다가 돌아오는 경험이 된다.
  ///
  /// `flutter_web_auth_2`는 iOS/macOS에서 `ASWebAuthenticationSession`,
  /// 안드로이드에서 Chrome Custom Tabs를 쓴다 — 둘 다 앱을 벗어나지 않는
  /// 시트/탭이면서, 커스텀 스킴 리다이렉트를 감지하면 **자동으로 닫히고
  /// 결과 URL을 반환**하도록 설계된 플랫폼 표준 API다. 그래서 URL 생성
  /// (`getOAuthSignInUrl`) → 인증 시트 실행+대기(`FlutterWebAuth2.authenticate`)
  /// → 콜백 URL로 세션 교환(`getSessionFromUrl`)을 직접 잇는다.
  Future<void> signInWithKakao() async {
    state = const AsyncLoading();
    try {
      final oauth = await _client.auth.getOAuthSignInUrl(
        provider: OAuthProvider.kakao,
        redirectTo: AuthConfig.oauthRedirectUrl,
      );
      final callbackUrl = await FlutterWebAuth2.authenticate(
        url: oauth.url,
        callbackUrlScheme: AuthConfig.appScheme,
      );
      // PKCE 코드 교환까지 여기서 끝낸다 — 세션이 저장되면
      // `onAuthStateChange`가 흘러 `authStateProvider`에 반영되고, 라우터
      // `redirect`가 화면 전환을 처리한다.
      await _client.auth.getSessionFromUrl(Uri.parse(callbackUrl));
      state = const AsyncData(null);
    } on AuthException catch (e, st) {
      state = AsyncError(Failure.unauthorized(message: e.message), st);
    } catch (e, st) {
      state = AsyncError(Failure.unknown(message: '$e', cause: e), st);
    }
  }

  /// **디버그 빌드 전용** 테스트 계정 로그인. 카카오 프로바이더 자체는 정상
  /// 등록됐지만, 시뮬레이터에서는 실제 카카오 계정으로 동의 화면을 끝까지
  /// 완료할 방법이 없어(SMS 인증 등) 인증이 필요한 화면을 개발 중 확인할
  /// 수가 없다 — 그 문제를 우회하기 위한 개발자 전용 뒷문이다.
  ///
  /// `kDebugMode`가 아니면 즉시 예외를 던진다(release 빌드에 남아도 절대
  /// 호출될 수 없게 이중으로 막는다 — UI 쪽도 `kDebugMode`로 버튼 자체를 숨긴다).
  /// 대상 계정은 Supabase `auth.users`에 이메일/비밀번호로 직접 시드해 둔
  /// `dev.tester@runnit.test` 하나뿐이며, 카카오 로그인 경로와는 완전히
  /// 분리돼 있다(이 계정은 `handle_new_auth_user()` 트리거로 만들어진
  /// 평범한 `profiles` 행을 갖는다 — 프로덕션 데이터 모델과 동일하게 동작).
  Future<void> signInWithTestAccount() async {
    if (!kDebugMode) {
      throw StateError('signInWithTestAccount 는 디버그 빌드에서만 호출할 수 있습니다.');
    }
    state = const AsyncLoading();
    try {
      await _client.auth.signInWithPassword(
        email: 'dev.tester@runnit.test',
        password: 'runnit-dev-2026',
      );
      state = const AsyncData(null);
    } on AuthException catch (e, st) {
      state = AsyncError(Failure.unauthorized(message: e.message), st);
    } catch (e, st) {
      state = AsyncError(Failure.unknown(message: '$e', cause: e), st);
    }
  }

  /// 로그아웃. 성공 시 `onAuthStateChange`가 세션 null을 흘려보내고,
  /// 라우터 `redirect`가 보호 라우트에 있던 사용자를 로그인 화면으로 되돌린다.
  Future<void> signOut() async {
    state = const AsyncLoading();
    try {
      await _client.auth.signOut();
      state = const AsyncData(null);
    } on AuthException catch (e, st) {
      state = AsyncError(Failure.unauthorized(message: e.message), st);
    } catch (e, st) {
      state = AsyncError(Failure.unknown(message: '$e', cause: e), st);
    }
  }

  /// 에러 배너를 닫을 때 호출.
  void clearError() {
    if (state.hasError) state = const AsyncData(null);
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AsyncValue<void>>(AuthController.new);
