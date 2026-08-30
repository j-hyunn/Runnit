import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/providers/repository_providers.dart';
import '../../../core/repositories/notification_repository.dart';
import '../../../models/models.dart';

/// 알림함·설정·미읽음 배지 Provider (PRD §5.10).
///
/// ## 재조회 신호 하나, 소비자 둘
/// `notifications` realtime INSERT는 [notificationSignalProvider] 하나로 받고,
/// 알림함 목록과 미읽음 카운트가 각자 다시 조회한다. 스트림이 밀어준 행을 목록에
/// 직접 붙이지 않는 이유는 architect §3.2 — 앱이 백그라운드였던 구간의 누락분과
/// 어긋난다.
///
/// ## ⚠️ 알림함을 `NotificationSettings.isEnabled`로 필터하지 않는다
/// 그 메서드는 마스터 스위치까지 반영하는 **설정 화면용 판정**이다. 서버는
/// 종류별 토글이 꺼진 알림을 애초에 만들지 않고, 마스터 스위치는 **푸시만**
/// 막는다(backend §2.5). 클라이언트가 한 번 더 거르면 마스터를 끈 사용자의
/// 알림함이 통째로 비어 보인다 — 인박스를 만든 이유가 사라진다.

/// 새 알림 도착 신호. 값(정수)에 의미는 없다 — **바뀌었다는 사실**만 쓴다.
final notificationSignalProvider = StreamProvider<int>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return const Stream<int>.empty();
  var tick = 0;
  return ref
      .watch(notificationRepositoryProvider)
      .watchIncoming(userId)
      // 구독 시작 직후의 최초 방출은 "변경"이 아니다. 그대로 두면 화면을 열
      // 때마다 방금 받은 목록을 한 번 더 조회한다.
      .skip(1)
      .map((_) => ++tick);
});

/// 미읽음 개수. 프로필 헤더 종 아이콘의 배지가 이것 하나만 구독한다.
/// 게스트는 항상 0(리포지토리를 건드리지 않는다).
final unreadNotificationCountProvider = FutureProvider<int>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return 0;
  // 재조회 신호. 값을 쓰지 않고 **의존만** 한다.
  ref.watch(notificationSignalProvider);
  return ref.watch(notificationRepositoryProvider).fetchUnreadCount(userId);
});

/// 알림함 한 화면치 상태.
@immutable
class NotificationInboxState {
  const NotificationInboxState({
    required this.items,
    required this.hasMore,
    this.loadingMore = false,
  });

  const NotificationInboxState.empty()
      : items = const <AppNotification>[],
        hasMore = false,
        loadingMore = false;

  final List<AppNotification> items;

  /// 커서 페이지네이션의 끝 여부. 마지막 페이지가 꽉 찼으면 더 있을 수 있다.
  final bool hasMore;
  final bool loadingMore;

  bool get isEmpty => items.isEmpty;

  NotificationInboxState copyWith({
    List<AppNotification>? items,
    bool? hasMore,
    bool? loadingMore,
  }) =>
      NotificationInboxState(
        items: items ?? this.items,
        hasMore: hasMore ?? this.hasMore,
        loadingMore: loadingMore ?? this.loadingMore,
      );
}

class NotificationInboxController extends AsyncNotifier<NotificationInboxState> {
  /// 한 페이지 크기. 첫 화면을 채우고 한 번 더 스크롤할 만큼.
  static const pageSize = 30;

  @override
  Future<NotificationInboxState> build() async {
    final userId = ref.watch(currentUserIdProvider);
    if (userId == null) return const NotificationInboxState.empty();

    // realtime은 재조회 신호로만 쓴다.
    ref.listen(notificationSignalProvider, (_, __) => ref.invalidateSelf());

    final items = await ref
        .watch(notificationRepositoryProvider)
        .fetchInbox(userId: userId, limit: pageSize);
    return NotificationInboxState(
      items: items,
      hasMore: items.length == pageSize,
    );
  }

  /// 다음 페이지. 커서는 **마지막 항목의 `createdAt`**이다.
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    final userId = ref.read(currentUserIdProvider);
    if (current == null ||
        userId == null ||
        !current.hasMore ||
        current.loadingMore ||
        current.items.isEmpty) {
      return;
    }

    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final next = await ref.read(notificationRepositoryProvider).fetchInbox(
            userId: userId,
            before: current.items.last.createdAt,
            limit: pageSize,
          );
      state = AsyncData(
        current.copyWith(
          items: [...current.items, ...next],
          hasMore: next.length == pageSize,
          loadingMore: false,
        ),
      );
    } catch (error) {
      // 다음 페이지 실패로 이미 보고 있는 목록을 에러 화면으로 바꾸지 않는다.
      // 사용자는 다시 스크롤해서 재시도할 수 있다.
      debugPrint('[notifications] 추가 페이지 조회 실패: $error');
      state = AsyncData(current.copyWith(loadingMore: false));
    }
  }

  /// 뷰포트에 실제로 보인 알림을 읽음 처리한다(목록 진입 즉시 전체 읽음 금지 —
  /// architect §3.2). 낙관적 갱신 후 실패하면 조용히 되돌린다.
  Future<void> markRead(Iterable<String> ids) async {
    final current = state.valueOrNull;
    if (current == null) return;

    final targets = ids
        .where(
          (id) => current.items
              .any((n) => n.id == id && n.readAt == null),
        )
        .toSet();
    if (targets.isEmpty) return;

    final now = DateTime.now().toUtc();
    state = AsyncData(
      current.copyWith(
        items: [
          for (final item in current.items)
            targets.contains(item.id) ? item.copyWith(readAt: now) : item,
        ],
      ),
    );

    try {
      await ref
          .read(notificationRepositoryProvider)
          .markRead(targets.toList(growable: false));
      ref.invalidate(unreadNotificationCountProvider);
    } catch (error) {
      debugPrint('[notifications] 읽음 처리 실패: $error');
      state = AsyncData(current);
    }
  }

  /// "모두 읽음" 명시 액션.
  Future<void> markAllRead() async {
    final current = state.valueOrNull;
    final userId = ref.read(currentUserIdProvider);
    if (current == null || userId == null) return;

    final now = DateTime.now().toUtc();
    state = AsyncData(
      current.copyWith(
        items: [
          for (final item in current.items)
            item.readAt == null ? item.copyWith(readAt: now) : item,
        ],
      ),
    );

    try {
      await ref.read(notificationRepositoryProvider).markAllRead(userId);
      ref.invalidate(unreadNotificationCountProvider);
    } catch (error) {
      debugPrint('[notifications] 전체 읽음 처리 실패: $error');
      state = AsyncData(current);
    }
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final notificationInboxProvider =
    AsyncNotifierProvider<NotificationInboxController, NotificationInboxState>(
  NotificationInboxController.new,
);

class NotificationSettingsController extends AsyncNotifier<NotificationSettings> {
  @override
  Future<NotificationSettings> build() async {
    final userId = ref.watch(currentUserIdProvider);
    // 게스트는 설정 화면에 들어올 수 없다(라우터 가드). 방어적 기본값.
    if (userId == null) return NotificationSettings.defaultsFor('');

    final settings =
        await ref.watch(notificationRepositoryProvider).fetchSettings(userId);
    // 행이 없으면 전 종류 on — 서버와 같은 규약이다(architect §1.3).
    return settings ?? NotificationSettings.defaultsFor(userId);
  }

  /// 종류별 토글. **낙관적 갱신 + 실패 롤백** — 스위치가 네트워크 왕복만큼
  /// 굳어 있으면 사용자는 두 번 누르고, 두 번째 요청이 첫 번째를 되돌린다.
  Future<void> setType(NotificationType type, bool enabled) =>
      _apply(
        optimistic: (s) => s.withType(type, enabled),
        commit: (repo, userId) => repo.updateSetting(
          userId: userId,
          type: type,
          enabled: enabled,
        ),
      );

  /// 마스터 스위치. 종류별 값은 건드리지 않는다 — 다시 켰을 때 원래 상태로
  /// 돌아와야 하기 때문이다(`rawFlag`).
  Future<void> setPushEnabled(bool enabled) => _apply(
        optimistic: (s) => s.copyWith(pushEnabled: enabled),
        commit: (repo, userId) => repo.updatePushEnabled(
          userId: userId,
          enabled: enabled,
        ),
      );

  Future<void> _apply({
    required NotificationSettings Function(NotificationSettings) optimistic,
    required Future<NotificationSettings> Function(
      NotificationRepository repo,
      String userId,
    ) commit,
  }) async {
    final current = state.valueOrNull;
    final userId = ref.read(currentUserIdProvider);
    if (current == null || userId == null) return;

    state = AsyncData(optimistic(current));
    try {
      final saved = await commit(
        ref.read(notificationRepositoryProvider),
        userId,
      );
      state = AsyncData(saved);
    } catch (error, stackTrace) {
      state = AsyncData(current); // 롤백 — 화면은 서버의 진실로 되돌아간다.
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

final notificationSettingsProvider = AsyncNotifierProvider<
    NotificationSettingsController, NotificationSettings>(
  NotificationSettingsController.new,
);
