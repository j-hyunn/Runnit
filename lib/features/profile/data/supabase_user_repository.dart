import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/api/supabase_error.dart';
import '../../../core/api/wire_enums.dart';
import '../../../core/repositories/user_repository.dart';
import '../../../models/models.dart';

/// [UserRepository]의 Supabase(`public.profiles`) 구현.
///
/// 계약(`_workspace/20260819_132600_backend_schema.md` §2.1):
/// - 컬럼명은 Dart 필드의 snake_case 변환과 1:1이라 `AppUser.fromJson`에
///   행을 그대로 넘긴다. **`select()`에 컬럼 별칭(`as`)을 쓰지 않는다** —
///   별칭을 쓰는 순간 `fromJson`이 키를 못 찾는다.
/// - 통계 캐시(`total_*`, `level`, `*_streak_days`, `crew_id` …)는 서버 전용이다.
///   `profiles_guard` 트리거가 되돌리긴 하지만, 애초에 요청에 싣지 않는다.
///
/// RLS: `profiles`는 authenticated 전용이다(anon GRANT 회수, 마이그레이션 17).
/// 게스트 상태에서는 이 리포지토리를 호출하지 않는다 —
/// `currentProfileProvider`가 `currentUserIdProvider == null`이면 즉시 null을 준다.
class SupabaseUserRepository implements UserRepository {
  const SupabaseUserRepository(this._client);

  final SupabaseClient _client;

  static const _table = 'profiles';

  @override
  Future<AppUser?> currentUser() {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return Future.value(null);
    return findById(userId);
  }

  @override
  Future<AppUser?> findById(String userId) {
    return guardSupabase(() async {
      // maybeSingle: 가입 트리거(`on_auth_user_created`)와 첫 조회가 경합해
      // 행이 아직 없을 수 있다. 그 경우는 에러가 아니라 null이다.
      final row = await _client
          .from(_table)
          .select()
          .eq('id', userId)
          .maybeSingle();
      return row == null ? null : AppUser.fromJson(row);
    });
  }

  @override
  Stream<AppUser?> watchCurrentUser() {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return Stream<AppUser?>.value(null);

    // NOTE: `profiles`는 아직 `supabase_realtime` publication에 없다
    // (03/07 마이그레이션이 넣은 것은 leaderboard_entries / user_badges뿐).
    // 따라서 이 스트림은 **최초 스냅샷은 정상**이지만 이후 UPDATE 푸시는 오지 않는다.
    // 라이브 갱신이 필요해지면 publication에 profiles를 추가하는 마이그레이션이
    // 선행돼야 한다(스키마 변경이므로 별도 승인 대상).
    return _client
        .from(_table)
        .stream(primaryKey: ['id'])
        .eq('id', userId)
        .map((rows) => rows.isEmpty ? null : AppUser.fromJson(rows.first))
        .handleError((Object error, StackTrace stackTrace) {
          Error.throwWithStackTrace(mapSupabaseError(error), stackTrace);
        });
  }

  @override
  Future<AppUser> updateProfile(AppUser user) {
    return guardSupabase(() async {
      final row = await _client
          .from(_table)
          .update(_editablePatch(user))
          .eq('id', user.id)
          .select()
          .single();
      return AppUser.fromJson(row);
    });
  }

  /// 인터페이스가 허용한 편집 가능 필드만 추린다.
  /// `user.toJson()`을 통째로 보내면 서버 전용 통계까지 실려간다.
  static Map<String, dynamic> _editablePatch(AppUser user) => <String, dynamic>{
        'username': user.username,
        'display_name': user.displayName,
        'avatar_url': user.avatarUrl,
        'bio': user.bio,
        'height_cm': user.heightCm,
        'weight_kg': user.weightKg,
        // timestamptz 컬럼이다(§2.1). UTC ISO-8601로 보낸다.
        'birth_date': user.birthDate?.toUtc().toIso8601String(),
        'gender': user.gender?.wire,
        'preferred_unit': user.preferredUnit.wire,
      };
}
