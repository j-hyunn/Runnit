import '../../models/models.dart';

/// 알림함·알림 설정·푸시 토큰 조회/갱신 계약 (PRD §5.10 NT-01~08).
///
/// **알림을 만드는 메서드는 없다.** 발송 조건 판정(티어 승급·순위 추월·시즌 D-3)은
/// 전부 서버(트리거·pg_cron)의 몫이고, 클라이언트가 알림 행을 만들 수 있으면
/// 티어·랭킹 판정을 클라이언트가 흉내내는 경로가 열린다(ARCHITECTURE §7.3).
/// 여기 있는 쓰기는 셋뿐이다 — **읽음 표시 / 설정 토글 / 토큰 등록·해제**.
abstract interface class NotificationRepository {
  /// 알림함 한 페이지. 최신순([AppNotification.createdAt] desc).
  ///
  /// [before]는 커서 — 마지막 항목의 `createdAt`을 넘겨 다음 페이지를 받는다.
  /// offset 페이지네이션을 쓰지 않는 이유: 조회 중 새 알림이 도착하면 offset이
  /// 밀려 같은 항목이 두 번 보인다.
  Future<List<AppNotification>> fetchInbox({
    required String userId,
    DateTime? before,
    int limit = 30,
  });

  /// 미읽음 개수. 목록을 다 받아 세지 않는다 — 탭 배지 하나 때문에 전체 payload를
  /// 내려받게 되고, 오래된 알림이 쌓일수록 비용이 선형으로 는다.
  /// (`head: true` + `count: exact`)
  Future<int> fetchUnreadCount(String userId);

  /// 새 알림 도착 스트림(`notifications` INSERT realtime).
  /// 미읽음 배지와 알림함 목록을 **재조회시키는 신호**로만 쓴다 — 스트림이 밀어준
  /// 행을 그대로 목록에 붙이면 앱이 백그라운드였던 구간의 누락분과 어긋난다.
  Stream<void> watchIncoming(String userId);

  /// 읽음 처리. 서버가 `read_at = now()`를 채운다(클라이언트 시각 불신).
  /// 이미 읽은 행은 갱신하지 않는다 — 읽은 시각이 뒤로 밀리면 안 된다.
  Future<void> markRead(List<String> notificationIds);

  /// 알림함 전체 읽음.
  Future<void> markAllRead(String userId);

  /// 설정 조회. 행이 없으면 null — 호출부는
  /// [NotificationSettings.defaultsFor]로 폴백한다(전 종류 on).
  Future<NotificationSettings?> fetchSettings(String userId);

  /// 종류 하나만 갱신한다. 행 전체를 덮어쓰지 않는 이유는
  /// [NotificationSettings.columnOf] 주석 참조(다중 기기 lost update).
  /// 행이 없으면 기본값(전 on) 위에 이 값을 얹어 insert한다.
  Future<NotificationSettings> updateSetting({
    required String userId,
    required NotificationType type,
    required bool enabled,
  });

  /// 마스터 스위치.
  Future<NotificationSettings> updatePushEnabled({
    required String userId,
    required bool enabled,
  });

  /// FCM 토큰 등록/갱신(upsert, PK = token).
  Future<void> upsertToken(PushDeviceToken token);

  /// 토큰 해제(로그아웃·권한 철회). 실패해도 호출부는 진행한다.
  Future<void> deleteToken(String token);
}
