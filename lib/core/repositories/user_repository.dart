import '../../models/models.dart';

/// 사용자 프로필 조회/수정 계약.
///
/// 통계 캐시 필드(totalDistanceMeters, level, currentStreakDays 등)는
/// 서버 전용 쓰기 대상이며 [updateProfile]로 변경할 수 없다.
abstract interface class UserRepository {
  /// 현재 로그인 사용자. 미인증이면 null.
  Future<AppUser?> currentUser();

  Stream<AppUser?> watchCurrentUser();

  Future<AppUser?> findById(String userId);

  /// 편집 가능한 프로필 필드만 갱신한다
  /// (username, displayName, avatarUrl, bio, heightCm, weightKg,
  ///  birthDate, gender, preferredUnit).
  Future<AppUser> updateProfile(AppUser user);
}
