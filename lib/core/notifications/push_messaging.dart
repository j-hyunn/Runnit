import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/wire_enums.dart';
import '../../models/models.dart';
import '../router/app_router.dart';
import 'firebase_bootstrap.dart';
import 'notification_deep_link.dart';

/// FCM 백그라운드 격리 진입점.
///
/// **아무것도 하지 않는 것이 정상이다.** 서버(`push-dispatch`)는 `notification`
/// 블록을 실은 메시지를 보내므로 앱이 백그라운드/종료 상태일 때의 트레이 표시는
/// OS가 처리한다. 여기서 Supabase에 붙어 알림함을 갱신하려는 유혹이 있지만,
/// 이 격리는 별도 엔진이라 Riverpod 컨테이너도 세션도 없다 — 재구현한 절반짜리
/// 클라이언트가 생길 뿐이다. 알림함은 앱이 열릴 때 어차피 다시 읽는다.
///
/// 그럼에도 핸들러를 **등록은 해야 한다.** 등록하지 않으면 일부 Android 기기에서
/// data-only 메시지가 조용히 버려진다.
@pragma('vm:entry-point')
Future<void> runnitFirebaseBackgroundHandler(RemoteMessage message) async {}

/// 포그라운드에서 받은 푸시 1건 — 인앱 배너가 그릴 최소 정보.
///
/// 서버가 완성한 문구를 **그대로** 나른다. 클라이언트가 payload로 문구를
/// 조립하지 않는다(트레이 문구와 갈라지면 같은 사건이 두 가지로 보인다).
@immutable
class PushBanner {
  const PushBanner({
    required this.title,
    required this.body,
    required this.route,
    this.type,
  });

  final String title;
  final String body;

  /// 배너를 탭했을 때 이동할 경로. 이미 해석·검증을 마친 값이다.
  final String route;
  final NotificationType? type;
}

/// FCM 수신·딥링크 경계.
///
/// ## 이 클래스가 하지 않는 것
/// - 알림을 만들지 않는다(발행은 전부 서버 — ARCHITECTURE §7.5.1)
/// - 성취 축하를 띄우지 않는다(소비 지점은 `AchievementCelebrationHost` 하나)
/// - 토큰을 등록하지 않는다(인증 수명주기에 붙는 `push_token_sync.dart`의 몫)
///
/// ## 포그라운드 중복 방지 (architect §4.2)
/// | 종류 | 인앱 배너 |
/// |---|---|
/// | `isAchievement`(NT-01·NT-06) | **띄우지 않는다** — 몇 초 뒤 축하 풀페이지가 뜬다 |
/// | 그 외(NT-02·03·04·05) | 띄운다 — 대응하는 인앱 연출이 없다 |
///
/// 배너 표시 여부와 무관하게 **모든 종류가 알림함에 남는다.**
class PushMessagingService {
  PushMessagingService(this._ref);

  final Ref _ref;
  final StreamController<PushBanner> _banners =
      StreamController<PushBanner>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];
  var _started = false;

  /// 인앱 배너로 그릴 메시지 스트림. 구독자가 없으면 그냥 흘려보낸다.
  Stream<PushBanner> get banners => _banners.stream;

  /// 앱 시작 시 1회. Firebase가 없으면 조용히 아무것도 하지 않는다.
  Future<void> start() async {
    if (_started || !isFirebaseAvailable) return;
    _started = true;

    final messaging = FirebaseMessaging.instance;

    try {
      // iOS: 포그라운드 배너를 OS가 그리지 않게 한다. 우리가 직접 그리고,
      // 성취 계열은 아예 생략해야 하기 때문이다(위 표). Android는 원래
      // 포그라운드 트레이 표시를 하지 않는다.
      await messaging.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: true,
        sound: false,
      );
    } catch (error) {
      debugPrint('[push] 포그라운드 표시 옵션 설정 실패: $error');
    }

    _subs.add(FirebaseMessaging.onMessage.listen(_onForeground));
    _subs.add(FirebaseMessaging.onMessageOpenedApp.listen(_onOpened));

    // 종료 상태에서 알림 탭으로 실행된 경우. 라우터가 준비된 뒤에 이동해야
    // 하므로 첫 프레임 뒤로 미룬다.
    try {
      final initial = await messaging.getInitialMessage();
      if (initial != null) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _onOpened(initial));
      }
    } catch (error) {
      debugPrint('[push] 초기 메시지 조회 실패: $error');
    }
  }

  void _onForeground(RemoteMessage message) {
    final type = notificationTypeFromWire(_dataString(message, 'type'));

    // 성취 계열은 배너를 띄우지 않는다 — 같은 사건을 배너와 풀페이지가
    // 두 번 알리게 된다(ARCHITECTURE §7.5.2).
    if (type?.isAchievement ?? false) return;

    final title =
        message.notification?.title ?? _dataString(message, 'title') ?? '';
    final body =
        message.notification?.body ?? _dataString(message, 'body') ?? '';
    if (title.isEmpty && body.isEmpty) return;

    _banners.add(
      PushBanner(
        title: title,
        body: body,
        route: _routeOf(message, type),
        type: type,
      ),
    );
  }

  void _onOpened(RemoteMessage message) {
    final type = notificationTypeFromWire(_dataString(message, 'type'));
    navigateTo(_routeOf(message, type));
  }

  /// 딥링크 이동. **이동만 한다** — payload에 `user_badge_id`가 있어도
  /// 축하 연출을 여기서 띄우지 않는다(ARCHITECTURE §7.4.1).
  void navigateTo(String route) {
    try {
      _ref.read(appRouterProvider).go(route);
    } catch (error) {
      debugPrint('[push] 딥링크 이동 실패($route): $error');
    }
  }

  String _routeOf(RemoteMessage message, NotificationType? type) =>
      NotificationDeepLink.resolveRaw(_dataString(message, 'route'), type);

  /// FCM `data`의 값은 **규격상 항상 문자열**이지만, 캐스팅(`as String?`)으로
  /// 꺼내면 규격을 벗어난 값 하나가 리스너 안에서 예외를 던져 **그 메시지가
  /// 통째로 사라진다**(스택 트레이스도 앱 로그에만 남는다). 타입을 확인해서
  /// 꺼내면 최악의 경우도 "그 필드만 없는 것"이 되고, 종류·경로는 폴백이 받는다.
  ///
  /// 서버가 `data.type`을 아예 싣지 않는 경우(QA C-2)도 여기서 null이 되어
  /// `notificationTypeFromWire`가 null을 돌려주고, 딥링크는 알림함으로 폴백한다 —
  /// 크래시하지 않는다. 다만 그때는 성취 계열 판정이 불가능해 배너 억제가
  /// 동작하지 않으므로, **`type`은 서버가 반드시 실어야 하는 값**이다.
  static String? _dataString(RemoteMessage message, String key) {
    final value = message.data[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    unawaited(_banners.close());
  }
}

/// 앱 수명 동안 하나. `app.dart`가 `ref.watch`로 붙잡아 살려 둔다 —
/// 화면이 소유하면 알림 화면에 한 번도 안 들어간 사용자는 딥링크도 배너도
/// 받지 못한다.
final pushMessagingProvider = Provider<PushMessagingService>((ref) {
  final service = PushMessagingService(ref);
  ref.onDispose(service.dispose);
  unawaited(service.start());
  return service;
});

/// 인앱 배너 스트림. `NotificationBannerHost`가 구독한다.
final pushBannerProvider = StreamProvider<PushBanner>((ref) {
  return ref.watch(pushMessagingProvider).banners;
});
