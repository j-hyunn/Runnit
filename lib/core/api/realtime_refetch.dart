import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_error.dart';

/// "테이블이 바뀌면 다시 조회한다" 형태의 Realtime 구독 스트림.
///
/// `.stream()` 대신 채널 + 재조회를 쓰는 이유:
/// `.stream()`은 **eq 필터를 하나만** 걸 수 있는데, 리더보드는
/// period/metric/scope(+crew_id) **4중 필터 + rank 정렬 + limit**이 필요하다.
/// 또 `.stream()`이 돌려주는 것은 Realtime 페이로드를 클라이언트가 누적한
/// 결과라 서버가 계산한 `rank` 정렬/절단을 보장하지 못한다. 변경 알림만
/// Realtime으로 받고 실제 목록은 항상 REST로 다시 읽는 편이 정확하다.
///
/// [fetch]는 구독 시작 시 1회, 이후 매 변경 이벤트마다 호출된다.
Stream<T> watchTableAndRefetch<T>({
  required SupabaseClient client,
  required String table,
  required Future<T> Function() fetch,
  PostgresChangeFilter? filter,
  String? topicSuffix,
}) {
  late final StreamController<T> controller;
  RealtimeChannel? channel;
  var cancelled = false;

  Future<void> emit() async {
    try {
      final value = await fetch();
      if (!cancelled && !controller.isClosed) controller.add(value);
    } catch (error, stackTrace) {
      if (!cancelled && !controller.isClosed) {
        controller.addError(mapSupabaseError(error), stackTrace);
      }
    }
  }

  controller = StreamController<T>(
    onListen: () {
      unawaited(emit());
      // 토픽은 구독마다 고유해야 한다 — 같은 이름의 채널을 두 번 열면
      // 먼저 열린 쪽이 밀려난다.
      final topic = 'runnit:$table:${topicSuffix ?? ''}:${_seq++}';
      channel = client.channel(topic)
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          filter: filter,
          callback: (_) => unawaited(emit()),
        )
        ..subscribe();
    },
    onCancel: () async {
      cancelled = true;
      final ch = channel;
      channel = null;
      if (ch != null) await client.removeChannel(ch);
    },
  );

  return controller.stream;
}

int _seq = 0;
