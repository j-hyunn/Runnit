import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/api/supabase_error.dart';
import '../../../core/repositories/season_history_repository.dart';
import '../../../models/models.dart';

/// [SeasonHistoryRepository]의 Supabase(`public.season_histories`) 구현.
///
/// 계약(마이그레이션 21):
/// - 컬럼명이 `SeasonHistory` 필드의 snake_case 변환과 1:1이라 행을 그대로
///   `fromJson`에 넘긴다. **컬럼 별칭(`as`)을 쓰지 않는다** — 별칭을 쓰는 순간
///   `fromJson`이 키를 못 찾는다(`SupabaseUserRepository`와 같은 규칙).
/// - `start_at`/`end_at`은 **컬럼이 아니다.** `seasonId`에서 파생되는 Dart
///   getter이므로 select에 넣으면 안 된다.
/// - 정렬은 `season_id desc`. id 형식이 `2026-Q3`라 문자열 정렬이 곧 시간 역순이다
///   (`Season` doc의 형식 선택 근거). `closed_at` 정렬은 백필/복구 실행 순서에
///   흔들릴 수 있어 쓰지 않는다.
///
/// RLS(`season_histories_select_visible`): authenticated에게
/// `is_voided = false OR user_id = auth.uid()`를 허용하고 anon은 차단한다.
/// 이 클래스는 **본인 행만** 조회한다(타인 프로필의 역대 시즌은 범위 밖) —
/// 따라서 무효 행도 함께 내려오고, 화면이 이를 구분해 표시한다.
class SupabaseSeasonHistoryRepository implements SeasonHistoryRepository {
  const SupabaseSeasonHistoryRepository(this._client);

  final SupabaseClient _client;

  static const _table = 'season_histories';

  @override
  Future<List<SeasonHistory>> fetchByUser(String userId) {
    return guardSupabase(() async {
      final rows = await _client
          .from(_table)
          .select()
          .eq('user_id', userId)
          .order('season_id', ascending: false);
      return rows.map(SeasonHistory.fromJson).toList(growable: false);
    });
  }
}
