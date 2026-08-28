import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';

part 'app_notification.freezed.dart';
part 'app_notification.g.dart';

/// 사용자가 받은 알림 1건 (PRD §5.10). DB 테이블은 `notifications`.
///
/// 이름이 `Notification`이 아닌 이유: Flutter 프레임워크에 동명의 위젯 클래스가
/// 있어 `import` 충돌이 난다.
///
/// ## 이 모델은 "발송 로그"이자 "알림함"이다
/// 테이블을 둘로 나누지 않는다. 서버가 푸시를 발행할 때 이 행을 만들고, 앱은
/// 같은 행을 목록으로 읽는다. 나누면 "푸시는 갔는데 알림함에 없다"는 상태가
/// 생기고, 그 시점에 어느 쪽이 진실인지 판단할 근거가 사라진다.
/// 푸시 전송 실패(토큰 만료 등)와 무관하게 행은 남으므로, 알림 권한을 끈
/// 사용자도 앱에 들어오면 놓친 알림을 볼 수 있다.
///
/// ## 클라이언트가 쓸 수 있는 컬럼은 [readAt] 하나뿐이다
/// `user_badges.is_seen`과 같은 규약이다(TRD §4.1). 나머지는 서버 전용이며
/// RLS·가드 트리거가 되돌린다 — 문구를 클라이언트가 고칠 수 있으면 알림함이
/// 발송 근거로서의 가치를 잃는다.
///
/// ## 문구는 서버가 완성해서 내려준다
/// [title]/[body]에 이미 사용자 이름·거리·티어가 박혀 있다. 클라이언트가
/// [payload]로 문구를 조립하지 않는다 — 푸시 알림 트레이에 뜨는 문구(서버 조립)와
/// 알림함 문구(클라이언트 조립)가 갈라지면 같은 사건이 두 가지로 보인다.
/// [payload]는 **딥링크와 부가 표시**에만 쓴다.
@freezed
abstract class AppNotification with _$AppNotification {
  const AppNotification._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory AppNotification({
    /// 서버 생성 UUID.
    required String id,

    required String userId,

    required NotificationType type,

    /// 서버가 완성한 알림 제목/본문. 푸시 트레이에 뜬 문구와 동일하다.
    required String title,
    required String body,

    /// 딥링크·부가 표시용 구조화 데이터(jsonb).
    ///
    /// 규약 키 (서버가 채우고 클라이언트는 읽기만):
    /// | 키 | 타입 | 쓰는 종류 |
    /// |---|---|---|
    /// | `route` | string | 전 종류 — 탭했을 때 이동할 앱 경로(`/home` 등) |
    /// | `tier` | string | tierPromotion / tierProximity |
    /// | `remaining_m` | number | tierProximity / weekendPush |
    /// | `season_id` | string | seasonEnding (`2026-Q3`) |
    /// | `days_left` | number | seasonEnding (14 / 3) |
    /// | `direction` | string | rankChange (`up` / `down`) |
    /// | `rank` | number | rankChange / weekendPush |
    /// | `user_badge_id` | string | tierPromotion / badgeLevel — **참조용일 뿐,
    ///   이 값으로 축하 연출을 띄우지 않는다**(ARCHITECTURE §7.4.1) |
    ///
    /// 모르는 키는 무시한다. 서버가 키를 추가해도 구버전 앱이 깨지지 않아야 한다.
    @Default(<String, dynamic>{}) Map<String, dynamic> payload,

    /// 서버가 이 알림을 발행한 시각(UTC). 목록 정렬 기준(최신 우선).
    required DateTime createdAt,

    /// 사용자가 읽은 시각. null이면 미읽음 — 미읽음 배지 카운트의 기준이다.
    /// **클라이언트가 쓰는 유일한 컬럼.**
    DateTime? readAt,
  }) = _AppNotification;

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      _$AppNotificationFromJson(json);

  bool get isRead => readAt != null;

  /// 탭했을 때 이동할 라우트. 없거나 형식이 어긋나면 null —
  /// 호출부는 null이면 알림함에 머문다(빈 화면으로 튀지 않는다).
  String? get route {
    final value = payload['route'];
    return (value is String && value.startsWith('/')) ? value : null;
  }

  /// 정수형 payload 값 조회. jsonb 숫자는 `int`/`double` 어느 쪽으로도 올 수 있어
  /// 호출부마다 캐스팅을 반복하지 않도록 여기서 흡수한다.
  int? intPayload(String key) {
    final value = payload[key];
    if (value is int) return value;
    if (value is num) return value.round();
    return null;
  }

  String? stringPayload(String key) {
    final value = payload[key];
    return value is String ? value : null;
  }
}
