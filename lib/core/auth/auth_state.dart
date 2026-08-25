import 'package:supabase_flutter/supabase_flutter.dart' show Session;

/// 인증 상태 3분기.
///
/// - [unknown]: 세션 복원 전. 라우터는 이 상태에서 **리다이렉트하지 않는다**
///   (미인증으로 오판해 로그인 화면을 깜빡이는 것을 막기 위해).
///   `main()`이 `initializeSupabase()`를 await 하므로 실전에서는 거의 스쳐 지나간다.
/// - [unauthenticated]: 세션 없음 = 게스트. 앱 사용 자체는 가능하고,
///   공개 라우트(랭킹/뱃지 카탈로그)만 열람할 수 있다.
/// - [authenticated]: 카카오 로그인 완료. 유효 세션 보유.
enum AuthStatus { unknown, unauthenticated, authenticated }

/// 라우터/UI가 소비하는 인증 스냅샷.
///
/// 클래스명이 `AppAuthState`인 이유: `supabase_flutter`가 이미 `AuthState`
/// (= `AuthChangeEvent` + `Session` 이벤트 객체)를 export 한다. 같은 이름을 쓰면
/// 두 패키지를 함께 import 하는 화면에서 ambiguous import 컴파일 에러가 난다.
/// `AppUser`(vs Supabase `User`)와 같은 규칙이다.
///
/// 여기에는 **auth 세션만** 담는다. 프로필([AppUser])은 담지 않는다 —
/// 프로필 조회는 `userRepositoryProvider`에 의존하고, 그 리포지토리는 다시
/// `supabaseClientProvider`에 의존하므로, 인증 상태에 프로필을 섞으면
/// "로그인 판정 → 프로필 조회 → 로그인 판정" 순환이 생긴다.
/// 프로필은 `currentProfileProvider`(auth_providers.dart)로 분리한다.
class AppAuthState {
  const AppAuthState({required this.status, this.session});

  const AppAuthState.unknown()
      : status = AuthStatus.unknown,
        session = null;

  const AppAuthState.guest()
      : status = AuthStatus.unauthenticated,
        session = null;

  factory AppAuthState.fromSession(Session? session) => session == null
      ? const AppAuthState.guest()
      : AppAuthState(status: AuthStatus.authenticated, session: session);

  final AuthStatus status;
  final Session? session;

  bool get isAuthenticated => status == AuthStatus.authenticated;

  /// 게스트 = 세션이 없다고 **확정된** 상태. [AuthStatus.unknown]은 게스트가 아니다.
  bool get isGuest => status == AuthStatus.unauthenticated;

  bool get isResolved => status != AuthStatus.unknown;

  /// = `auth.users.id` = `profiles.id` = 모든 모델의 `userId`.
  String? get userId => session?.user.id;

  /// 카카오 계정이 email scope 동의를 안 했으면 null일 수 있다.
  String? get email => session?.user.email;

  @override
  bool operator ==(Object other) =>
      other is AppAuthState &&
      other.status == status &&
      other.session?.accessToken == session?.accessToken;

  @override
  int get hashCode => Object.hash(status, session?.accessToken);

  @override
  String toString() => 'AppAuthState($status, userId: $userId)';
}
