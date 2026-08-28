import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/api/realtime_refetch.dart';
import '../../../core/api/supabase_error.dart';
import '../../../core/api/wire_enums.dart';
import '../../../core/repositories/notification_repository.dart';
import '../../../models/models.dart';

/// [NotificationRepository]의 Supabase 구현 (마이그레이션 44~48).
///
/// **쓰기는 셋뿐이다** — 읽음 표시 / 설정 토글 / 토큰 등록·해제. 알림 행을 만드는
/// 경로는 이 클래스에 없다(발행은 전부 서버 트리거·pg_cron — ARCHITECTURE §7.5.1).
class SupabaseNotificationRepository implements NotificationRepository {
  const SupabaseNotificationRepository(this._client);

  final SupabaseClient _client;

  static const _inbox = 'notifications';
  static const _settings = 'notification_settings';
  static const _tokens = 'push_tokens';

  @override
  Future<List<AppNotification>> fetchInbox({
    required String userId,
    DateTime? before,
    int limit = 30,
  }) {
    return guardSupabase(() async {
      // 커서 페이지네이션. offset을 쓰면 조회 중 새 알림이 도착했을 때
      // 경계가 밀려 같은 항목이 두 번 보인다(architect §3.2).
      var query = _client.from(_inbox).select().eq('user_id', userId);
      if (before != null) {
        query = query.lt('created_at', before.toUtc().toIso8601String());
      }
      final rows =
          await query.order('created_at', ascending: false).limit(limit);
      return rows.map(AppNotification.fromJson).toList(growable: false);
    });
  }

  @override
  Future<int> fetchUnreadCount(String userId) {
    return guardSupabase(() async {
      // HEAD + count. 행을 내려받지 않는다 — 배지 하나 때문에 전체 payload를
      // 받으면 알림이 쌓일수록 비용이 선형으로 는다.
      // `(user_id) where read_at is null` 부분 인덱스가 이 쿼리를 받친다.
      return _client
          .from(_inbox)
          .count(CountOption.exact)
          .eq('user_id', userId)
          .isFilter('read_at', null);
    });
  }

  @override
  Stream<void> watchIncoming(String userId) {
    // 재조회 **신호**로만 쓴다. 스트림이 밀어준 행을 목록에 직접 붙이면 앱이
    // 백그라운드였던 구간의 누락분과 어긋난다(architect §3.2).
    return watchTableAndRefetch<void>(
      client: _client,
      table: _inbox,
      topicSuffix: 'inbox-$userId',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: userId,
      ),
      fetch: () async {},
    );
  }

  @override
  Future<void> markRead(List<String> notificationIds) {
    if (notificationIds.isEmpty) return Future<void>.value();
    return guardSupabase(() async {
      // RPC가 `read_at = now()`를 서버 시각으로 채우고, 이미 읽은 행은
      // 건드리지 않는다(읽은 시각이 뒤로 밀리면 안 된다).
      await _client.rpc<void>(
        'mark_notifications_read',
        params: {'p_ids': notificationIds},
      );
    });
  }

  @override
  Future<void> markAllRead(String userId) {
    return guardSupabase(() async {
      // p_ids = null 이 "전체 읽음"이다. 주체는 RPC 안에서 `auth.uid()`로
      // 확정하므로 userId를 넘기지 않는다.
      await _client.rpc<void>(
        'mark_notifications_read',
        params: const {'p_ids': null},
      );
    });
  }

  @override
  Future<NotificationSettings?> fetchSettings(String userId) {
    return guardSupabase(() async {
      final row = await _client
          .from(_settings)
          .select()
          .eq('user_id', userId)
          .maybeSingle();
      // 행이 없으면 null — 호출부가 `defaultsFor`(전 종류 on)로 폴백한다.
      return row == null ? null : NotificationSettings.fromJson(row);
    });
  }

  @override
  Future<NotificationSettings> updateSetting({
    required String userId,
    required NotificationType type,
    required bool enabled,
  }) {
    return _upsertColumn(userId, NotificationSettings.columnOf(type), enabled);
  }

  @override
  Future<NotificationSettings> updatePushEnabled({
    required String userId,
    required bool enabled,
  }) {
    return _upsertColumn(userId, 'push_enabled', enabled);
  }

  /// 컬럼 **하나만** 담은 upsert.
  ///
  /// 행 전체를 덮어쓰지 않는 이유: 폰·태블릿이 같은 화면을 열고 있으면 나중
  /// 요청이 방금 바뀐 다른 값을 되돌린다(lost update). PostgREST의
  /// `ON CONFLICT DO UPDATE`는 **payload에 있는 컬럼만** 갱신하므로, 보내지
  /// 않은 토글은 서버 값 그대로 남는다. 행이 없으면 나머지는 컬럼 기본값
  /// (전부 true)으로 insert된다.
  Future<NotificationSettings> _upsertColumn(
    String userId,
    String column,
    bool value,
  ) {
    return guardSupabase(() async {
      final row = await _client
          .from(_settings)
          .upsert({'user_id': userId, column: value}, onConflict: 'user_id')
          .select()
          .single();
      return NotificationSettings.fromJson(row);
    });
  }

  @override
  Future<void> upsertToken(PushDeviceToken token) {
    return guardSupabase(() async {
      // 단순 upsert가 아니라 RPC인 이유(backend §6.1): 같은 기기를 다른 계정이
      // 쓰면 토큰은 그대로인 채 `user_id`만 바뀌는데, RLS update의 USING이 이전
      // 소유자 행에 매칭되지 않아 실패한다. 그대로 두면 기기를 넘겨받은
      // 사용자에게 이전 사용자의 알림이 간다.
      await _client.rpc<void>(
        'register_push_token',
        params: {
          'p_token': token.token,
          'p_platform': token.platform.wire,
          'p_device_id': token.deviceId,
          'p_app_version': token.appVersion,
        },
      );
    });
  }

  @override
  Future<void> deleteToken(String token) {
    return guardSupabase(() async {
      await _client.from(_tokens).delete().eq('token', token);
    });
  }
}
