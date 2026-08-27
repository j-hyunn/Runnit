import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/api/realtime_refetch.dart';
import '../../../core/api/supabase_error.dart';
import '../../../core/api/wire_enums.dart';
import '../../../core/repositories/gamification_repository.dart';
import '../../../models/models.dart';

/// [GamificationRepository]의 Supabase 구현.
///
/// **획득 판정은 전부 서버다.** 이 클래스에는 뱃지를 부여하는 경로가 없다 —
/// `user_badges`는 RLS상 INSERT 정책 자체가 없고(서버 재검증 전용),
/// 클라이언트가 쓸 수 있는 컬럼은 `is_seen` 하나뿐이다(가드 트리거, §3.1).
///
/// 인증/게스트:
/// - `badges` 카탈로그는 anon에게도 열려 있다(마이그레이션 17) → 게스트도 호출 가능.
/// - 나머지(`user_badges`, `challenges`, `challenge_participations`)는
///   authenticated 전용이라 게스트가 부르면 빈 결과 또는 권한 오류가 난다.
///   호출부가 로그인 여부로 분기한다.
///
/// 클라이언트는 항상 같은 [SupabaseClient]를 쓴다. anon 키 상태인지 로그인
/// 세션인지는 SDK가 Authorization 헤더로 알아서 처리한다.
class SupabaseGamificationRepository implements GamificationRepository {
  const SupabaseGamificationRepository(this._client);

  final SupabaseClient _client;

  static const _badges = 'badges';
  static const _userBadges = 'user_badges';
  static const _challenges = 'challenges';
  static const _participations = 'challenge_participations';

  @override
  Future<List<Badge>> fetchBadgeCatalog() {
    return guardSupabase(() async {
      // `is_active`/`sort_order` 컬럼은 v2에서 삭제됐다(scope+seasonId가 시즌성을,
      // 클라이언트 파생 정렬(`badgeGradeOrder`)이 정렬을 대체 — 설계 문서
      // `_workspace/20260825_architect_badge-model-v2.md` §2.4/§2.6). 지난 시즌
      // 템플릿 필터링은 `BadgeProgressCalculator.forCatalog`가 담당한다.
      final rows = await _client.from(_badges).select().order('id');
      return rows.map(Badge.fromJson).toList(growable: false);
    });
  }

  @override
  Future<List<UserBadge>> fetchUserBadges(String userId) {
    return guardSupabase(() async {
      // 임베드 별칭 `badge:`는 허용된다 — 금지된 것은 *컬럼* 별칭이다(§2.5).
      // `badge`는 UserBadge.badge 필드명과 정확히 일치한다.
      // revoked=true 는 `watchUnseenBadges`와 같은 이유로 제외한다 — 운영자가 수동
      // 회수한 뱃지를 갤러리 상세의 공유 버튼(§HI-08)이 다시 "확정 성취"로
      // 내보내면 안 된다(QA F-1, 2026-08-26).
      final rows = await _client
          .from(_userBadges)
          .select('*, badge:badges(*)')
          .eq('user_id', userId)
          .eq('revoked', false)
          .order('earned_at', ascending: false);
      return rows.map(UserBadge.fromJson).toList(growable: false);
    });
  }

  @override
  Stream<List<UserBadge>> watchUnseenBadges(String userId) {
    // user_badges는 supabase_realtime publication에 포함돼 있다(07_rls.sql).
    // 서버가 러닝 업로드 직후 뱃지를 INSERT하면 곧바로 푸시가 온다.
    return watchTableAndRefetch<List<UserBadge>>(
      client: _client,
      table: _userBadges,
      topicSuffix: 'unseen-$userId',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: userId,
      ),
      fetch: () => guardSupabase(() async {
        final rows = await _client
            .from(_userBadges)
            .select('*, badge:badges(*)')
            .eq('user_id', userId)
            .eq('is_seen', false)
            // 이 큐는 축하 연출 + **공유 카드**의 입력이다(HI-10). 지금은 서버가
            // 항상 verified=true / revoked=false로만 넣어서 결과가 같지만,
            // 운영자가 수동 회수한 뱃지가 아직 is_seen=false로 남아 있으면
            // 그 뱃지를 축하하고 인스타에 올리게 된다 — 앱 밖으로 나간 카드는
            // 회수할 수 없으므로 두 줄로 그 경우를 큐에서 빼 둔다.
            // (gamification 문서 20260826_105607 §1)
            .eq('verified', true)
            .eq('revoked', false)
            .order('earned_at', ascending: true);
        return rows.map(UserBadge.fromJson).toList(growable: false);
      }),
    );
  }

  @override
  Future<void> markBadgesSeen(List<String> userBadgeIds) {
    if (userBadgeIds.isEmpty) return Future.value();
    return guardSupabase(() async {
      // `is_seen`은 클라이언트가 쓸 수 있는 유일한 컬럼이다.
      // 다른 키를 함께 보내면 가드 트리거가 조용히 되돌린다.
      await _client
          .from(_userBadges)
          .update(<String, dynamic>{'is_seen': true})
          .inFilter('id', userBadgeIds);
    });
  }

  @override
  Future<List<Challenge>> fetchChallenges({
    ChallengeStatus? status,
    String? crewId,
  }) {
    return guardSupabase(() async {
      var query = _client.from(_challenges).select();
      if (status != null) query = query.eq('status', status.wire);
      // crewId를 주지 않으면 RLS가 허용하는 전부(공개 + 내 크루)를 그대로 돌려준다.
      if (crewId != null) query = query.eq('crew_id', crewId);

      final rows = await query.order('start_at', ascending: false);
      return rows.map(Challenge.fromJson).toList(growable: false);
    });
  }

  @override
  Future<List<ChallengeParticipation>> fetchMyParticipations(String userId) {
    return guardSupabase(() async {
      final rows = await _client
          .from(_participations)
          .select('*, challenge:challenges(*)')
          .eq('user_id', userId)
          .order('joined_at', ascending: false);
      return rows.map(ChallengeParticipation.fromJson).toList(growable: false);
    });
  }

  @override
  Future<void> joinChallenge({
    required String challengeId,
    required String userId,
  }) {
    return guardSupabase(() async {
      // 진척도/완료시각/순위는 보내지 않는다 — challenge_participations_guard가
      // 서버 전용으로 되돌리고, participant_count는 트리거가 증가시킨다.
      await _client.from(_participations).insert(<String, dynamic>{
        'challenge_id': challengeId,
        'user_id': userId,
      });
    });
  }
}
