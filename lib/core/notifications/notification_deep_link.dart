import '../../models/models.dart';
import '../router/app_router.dart';
import '../router/route_access.dart';

/// 알림 payload → 앱 라우트 해석.
///
/// ## 서버가 준 경로를 그대로 믿지 않는다
/// `payload['route']`는 서버가 채우지만, **앱 버전마다 존재하는 라우트가 다르다.**
/// 서버가 `/points`(Phase 4) 같은 경로를 실어 보내면 구버전 앱은
/// `GoException: no routes for location`으로 죽는다. 그래서 화이트리스트를
/// 통과하지 못한 경로는 버리고 **종류별 기본 목적지**로 떨어뜨린다.
///
/// ## ⚠️ 접두사 매칭을 쓰지 않는다 (2026-08-28 QA C-3)
/// 처음에는 `/profile` 같은 **접두사**로 검사했다. 그 결과 서버가 보내던
/// `/profile/badges`가 `/profile/`로 시작한다는 이유로 화이트리스트를 통과한 뒤
/// go_router에서 `no routes for location`으로 크래시했다 — **화이트리스트가 막으려던
/// 바로 그 실패를 화이트리스트가 통과시켰다.** 접두사는 "이 아래 어딘가에 라우트가
/// 있을 것"이라는 추측일 뿐, 라우터에 그 경로가 등록돼 있다는 근거가 아니다.
///
/// 그래서 지금은 **라우터에 실제로 등록된 경로만 정확히 일치(exact match)**시키고,
/// 파라미터가 있는 라우트(러닝 상세)는 패턴 하나로 따로 검사한다. 라우트를 새로
/// 추가할 때 [_exactRoutes]에 같이 넣지 않으면 딥링크가 폴백될 뿐 **크래시하지는
/// 않는다** — 실패 방향이 안전한 쪽이다.
///
/// ## 종류별 목적지 (서버 발행값의 정본)
/// | 종류 | 목적지 화면 | route |
/// |---|---|---|
/// | NT-01 tierPromotion | 홈(티어 카드) | `/home` |
/// | NT-02 tierProximity | 홈(티어 카드) | `/home` |
/// | NT-03 seasonEnding | 홈(티어 카드) | `/home` |
/// | NT-04 rankChange | 홈(주간 랭킹) | `/home` |
/// | NT-05 weekendPush | 홈(주간 랭킹) | `/home` |
/// | NT-06 badgeLevel | 활동(뱃지 탭) | `/history?tab=badges` |
/// | 러닝 1건을 가리킬 때 | 기록 상세 | `/history/run/{runId}` |
/// | NT-07 points(Phase 4) · 미상 | 알림함 | `/notifications` |
///
/// 랭킹과 티어가 같은 `/home`인 이유: 2026-08-21 4탭 개편에서 랭킹 독립 탭이
/// 홈으로, 뱃지 독립 탭이 활동으로 흡수됐다(`app_router.dart`). `/ranking`,
/// `/profile/badges` 같은 경로는 **이 앱에 존재한 적이 없다.** 서버는
/// 마이그레이션 49·50에서 이 표대로 정정됐고(원격 실측 20건 일치), 과거 행도
/// 50-6에서 백필됐다.
///
/// ⚠️ **딥링크는 이동만 한다.** payload에 `user_badge_id`가 있어도 그것으로
/// 축하 연출을 띄우지 않는다 — 성취 축하의 소비 지점은
/// `AchievementCelebrationHost` 하나뿐이다(ARCHITECTURE §7.4.1 · §7.5.2).
/// 도착한 화면에서 `user_badges.is_seen`이 아직 false면 그 호스트가 알아서 뜬다.
class NotificationDeepLink {
  const NotificationDeepLink._();

  /// 라우터에 등록된 **정확한** 경로 목록. 접두사가 아니라 완전 일치다.
  static const Set<String> _exactRoutes = <String>{
    Routes.home,
    Routes.tracking,
    Routes.history,
    Routes.profile,
    Routes.notifications,
    Routes.notificationSettings,
  };

  /// 유일한 파라미터 라우트 — `/history/run/{runId}`.
  /// runId에 `/`가 들어갈 수 없으므로 세그먼트 하나로 제한한다.
  static final RegExp _runDetailPattern =
      RegExp(r'^/history/run/[^/]+$');

  // ── 과거 행 변환표를 두지 않는다 (2026-08-28) ─────────────────────────
  //
  // QA C-3 직후에는 이미 DB에 쌓인 옛 route(`/ranking`, `/profile/badges`,
  // `/runs/{id}`)를 클라이언트가 변환하는 표를 뒀었다. **서버가 마이그레이션 50-6
  // 에서 그 행들을 직접 백필해 잘못된 route가 0건이 되면서 걷어냈다.**
  //
  // 남겨 둘 이유가 없어서가 아니라, 남기면 **route 매핑의 정의가 두 곳**이 되기
  // 때문이다 — 정의가 두 곳으로 갈라진 것이 C-3의 원인이었다. 서버가 남긴 잘못된
  // 값은 서버가 치우고, 클라이언트는 "라우터에 등록됐는가" 하나만 판단한다.
  //
  // 서버가 다시 미지 경로를 보내더라도 [_fallbackFor]가 안전하게 받는다 —
  // 크래시가 아니라 종류별 목적지로 착지한다. 그 성질은
  // `test/notifications/notification_deep_link_router_test.dart`가 지킨다.

  /// [AppNotification] 한 건의 목적지.
  static String resolve(AppNotification notification) =>
      resolveRaw(notification.route, notification.type);

  /// FCM data payload처럼 모델이 아직 없는 경로에서 쓰는 형태.
  ///
  /// **어떤 입력에도 라우터에 존재하는 경로만 돌려준다.** 미지 경로·외부 URL·
  /// null은 전부 종류별 안전 폴백으로 떨어진다.
  static String resolveRaw(String? route, NotificationType? type) {
    final normalized = _normalize(route);
    if (normalized != null) return normalized;
    return _fallbackFor(type);
  }

  /// 라우터에 존재하는 경로로 정규화한다. 불가능하면 null.
  static String? _normalize(String? route) {
    if (!RouteAccess.isSafeInternalPath(route)) return null;

    // 쿼리·프래그먼트는 경로 판정에서 제외한다(`/home?tab=rank`처럼 서버가 힌트를
    // 붙여도 라우트 자체는 `/home`이다). 파싱에 실패하면 경로가 아니다.
    final Uri uri;
    try {
      uri = Uri.parse(route!);
    } catch (_) {
      return null;
    }
    final path = uri.path;

    if (_exactRoutes.contains(path)) return route;
    if (_runDetailPattern.hasMatch(path)) return route;
    return null;
  }

  static String _fallbackFor(NotificationType? type) => switch (type) {
        // 티어·랭킹은 홈 화면 하나에 같이 있다(2026-08-21 4탭 개편).
        NotificationType.tierPromotion ||
        NotificationType.tierProximity ||
        NotificationType.seasonEnding ||
        NotificationType.rankChange ||
        NotificationType.weekendPush =>
          Routes.home,
        // 뱃지·레벨은 활동 화면의 뱃지 하위 탭.
        NotificationType.badgeLevel => Routes.badgeGallery,
        // NT-07(Phase 4)과 종류를 모르는 경우 — 최소한 원문은 알림함에 있다.
        NotificationType.points || null => Routes.notifications,
      };
}
