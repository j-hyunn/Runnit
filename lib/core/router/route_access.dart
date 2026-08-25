import 'app_router.dart';

/// 게스트(비로그인) 접근 정책의 **단일 정의 지점**.
///
/// **2026-08-21 4탭 개편**(Figma 프레임 반영): 랭킹/뱃지가 더 이상 독립 탭이
/// 아니다 — 랭킹은 홈(티어+랭킹), 뱃지는 기록(기록+뱃지) 안의 하위 탭으로
/// 흡수됐다. 게스트 정책 자체는 바뀌지 않는다 — **화면(라우트) 단위**로
/// 공개 여부를 정하던 것을 그대로 유지하되, 대상 라우트만 옮겼다:
///
/// - 공개: **홈**(티어 카드는 로그인 유도로 대체, 랭킹은 그대로 공개),
///   **기록**(뱃지 탭은 카탈로그 공개, 기록 탭은 위젯이 로그인 유도)
/// - 로그인 필요: 러닝 트래킹, 프로필("마이")
///
/// 개인화 레이어(내 순위/내 획득 뱃지/내 기록 목록)는 여전히 **위젯이** 책임진다
/// (라우터는 화면 단위로만 막는다).
class RouteAccess {
  const RouteAccess._();

  /// 이 접두사로 시작하는 경로는 게스트에게 열려 있다(하위 라우트 포함).
  static const List<String> guestAllowedPrefixes = <String>[
    Routes.home,
    Routes.history,
  ];

  static bool allowsGuest(String location) {
    for (final prefix in guestAllowedPrefixes) {
      if (location == prefix || location.startsWith('$prefix/')) return true;
    }
    return false;
  }

  /// 게스트가 로그인 후 되돌아갈 기본 목적지(= 게스트 랜딩 화면).
  static const String guestLanding = Routes.home;

  /// 로그인 사용자의 기본 목적지.
  static const String authenticatedHome = Routes.tracking;

  /// `?from=` 값이 앱 내부 경로인지 검증한다.
  /// 외부 URL/스킴 리다이렉트(open redirect)를 막기 위해 반드시 통과시킨다.
  static bool isSafeInternalPath(String? path) {
    if (path == null || path.isEmpty) return false;
    if (!path.startsWith('/')) return false;
    if (path.startsWith('//')) return false; // protocol-relative
    if (path.startsWith(Routes.login)) return false; // 로그인으로 되돌아가는 루프 방지
    return true;
  }
}
