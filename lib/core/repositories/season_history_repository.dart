import '../../models/models.dart';

/// 역대 시즌 기록(HI-06 / TI-06) 조회 전용 리포지토리.
///
/// **읽기 전용이다.** `season_histories` 행은 시즌 경계를 넘을 때 서버
/// (`recompute_season_tier`, 마이그레이션 22)가 쓰고, 마감 이후엔 서버도
/// 고치지 않는다(`SeasonHistory` 모델 doc 참고). 그래서 여기에는 write 경로가
/// 없다 — 클라이언트가 과거 시즌 결과를 만들거나 고칠 방법 자체를 두지 않는다.
///
/// 진행 중인 시즌은 **행이 없다.** 현재 시즌 상태는
/// `AppUser.currentTier` / `AppUser.seasonDistanceMeters`가 들고 있다.
abstract interface class SeasonHistoryRepository {
  /// [userId]의 끝난 시즌 결과를 **최신 시즌 먼저** 반환한다.
  ///
  /// `is_voided`인 행도 포함한다 — RLS(`season_histories_select_visible`)가
  /// 무효 행을 본인에게만 보여주고, 본인 화면에서는 "무효 처리됨"으로
  /// 표시해야 하기 때문이다. 행을 감추면 사용자는 시즌이 통째로 사라진
  /// 것으로 오해한다.
  Future<List<SeasonHistory>> fetchByUser(String userId);
}
