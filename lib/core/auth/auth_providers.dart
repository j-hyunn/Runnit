import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../models/models.dart';
import '../api/supabase_client.dart';
import '../error/failure.dart';
import '../providers/repository_providers.dart';
import 'auth_controller.dart';
import 'auth_state.dart';

/// 앱 전역 인증 상태의 **단일 진실 원천**.
///
/// - 초기값은 `auth.currentSession`에서 **동기적으로** 읽는다.
///   `main()`이 `initializeSupabase()`(= `Supabase.initialize`, 내부에서 로컬
///   저장소의 세션 복구를 await)를 마친 뒤 `runApp`하므로 첫 프레임에 이미
///   정확한 값이 나온다. 라우터 `redirect`가 동기 함수라 이 점이 중요하다.
/// - 이후 갱신은 `onAuthStateChange`(로그인/로그아웃/토큰 갱신/OAuth 딥링크 복귀)로 받는다.
class AuthNotifier extends Notifier<AppAuthState> {
  StreamSubscription<sb.AuthState>? _sub;

  @override
  AppAuthState build() {
    final client = ref.watch(supabaseClientProvider);

    _sub = client.auth.onAuthStateChange.listen(
      (event) => state = AppAuthState.fromSession(event.session),
      onError: (Object error, StackTrace stackTrace) {
        state = const AppAuthState.guest();
        // 딥링크 복귀 시 카카오 인증이 실패하면(사용자가 동의 취소, redirect
        // URL 불일치 등) supabase_flutter 는 이 스트림에 AuthException 을
        // *에러 이벤트*로 흘려보낸다 — signInWithOAuth() 자체는 이미
        // "브라우저 실행 성공"으로 정상 반환된 뒤라 authControllerProvider 는
        // 이 실패를 모른다. 여기서 명시적으로 넘겨주지 않으면 로그인 화면은
        // 스피너도 에러도 없이 그냥 조용히 게스트로 남는다.
        final message =
            error is sb.AuthException ? error.message : error.toString();
        ref.read(authControllerProvider.notifier).state =
            AsyncError(Failure.unauthorized(message: message), stackTrace);
      },
    );
    ref.onDispose(() => _sub?.cancel());

    return AppAuthState.fromSession(client.auth.currentSession);
  }
}

/// `ref.watch(authStateProvider)` → [AppAuthState] (동기 접근 가능).
final authStateProvider = NotifierProvider<AuthNotifier, AppAuthState>(
  AuthNotifier.new,
);

/// 위젯이 로그인 여부만 필요할 때. 토큰 자동 갱신으로 인한 불필요한 리빌드를 막는다.
///
/// 예) 뱃지 카탈로그는 게스트도 보지만, "내가 획득함" 오버레이는
/// 이 값이 true일 때만 그린다.
final isAuthenticatedProvider = Provider<bool>(
  (ref) => ref.watch(authStateProvider.select((s) => s.isAuthenticated)),
);

/// 현재 로그인 사용자 id(`auth.users.id`). 게스트면 null.
final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(authStateProvider.select((s) => s.userId)),
);

/// 로그인 사용자의 프로필(`profiles` 행).
///
/// [authStateProvider]와 **분리**해 둔다. 인증 상태가 프로필 조회에 의존하면
/// 순환이 생기고, 프로필 fetch 실패가 로그인 판정을 무너뜨린다.
/// 게스트일 때는 리포지토리를 아예 건드리지 않고 즉시 null을 돌려준다.
final currentProfileProvider = FutureProvider<AppUser?>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  return ref.watch(userRepositoryProvider).currentUser();
});
