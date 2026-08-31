import '../../models/models.dart';

/// 사용자 프로필 조회/수정 계약.
///
/// 통계 캐시 필드(totalDistanceMeters, level, currentStreakDays 등)는
/// 서버 전용 쓰기 대상이며 [updateProfile]로 변경할 수 없다.
abstract interface class UserRepository {
  /// 현재 로그인 사용자. 미인증이면 null.
  Future<AppUser?> currentUser();

  Stream<AppUser?> watchCurrentUser();

  /// 임의 사용자의 프로필. 없으면 null.
  ///
  /// AC-03(타인 프로필 조회)의 진입점이기도 하다. `profiles`는 전원 공개
  /// SELECT(`profiles_select_all`)라 본인/타인을 구분하는 별도 경로가 필요 없다
  /// — 다만 **모델 전체가 아니라 공개 필드만 화면에 쓴다**는 제약은 표현 계층
  /// (`userProfileProvider`를 구독하는 화면)의 책임이다. 리포지토리에서
  /// 컬럼을 골라내지 않는 이유: `select()` 컬럼 목록을 손대면 `AppUser.fromJson`이
  /// required 필드를 잃고 깨진다(이 파일 상단 계약 참고).
  Future<AppUser?> findById(String userId);

  /// 편집 가능한 프로필 필드만 갱신한다
  /// (username, displayName, avatarUrl, bio, heightCm, weightKg,
  ///  birthDate, gender, preferredUnit, weeklyGoalKm).
  Future<AppUser> updateProfile(AppUser user);
}
