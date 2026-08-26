import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/features/sharing/domain/achievement_backlog.dart';
import 'package:runnit/models/models.dart';

/// 연출을 처음 켜는 순간 밀려 있던 `is_seen = false` 뱃지가 한꺼번에 쏟아지는
/// 문제(TRD §14 #19)를 어떻게 가르는지 검증한다.
void main() {
  UserBadge badge(String id, DateTime earnedAt) => UserBadge(
        id: id,
        userId: 'u1',
        badgeId: 'b_$id',
        earnedAt: earnedAt,
        verified: true,
      );

  final now = DateTime.utc(2026, 8, 26, 12);

  test('빈 큐와 1건은 밀린 성취가 아니다', () {
    expect(isAchievementBacklog(const []), isFalse);
    expect(isAchievementBacklog([badge('a', now)]), isFalse);
  });

  test('한 러닝이 터뜨린 여러 뱃지는 개별 축하 대상이다', () {
    // 같은 트랜잭션에서 발급되므로 earnedAt이 사실상 동일하다.
    final queue = [
      for (var i = 0; i < kBurstBadgeLimit; i++)
        badge('a$i', now.add(Duration(milliseconds: i))),
    ];
    expect(isAchievementBacklog(queue), isFalse);
  });

  test('한 번에 감당하기 힘든 개수면 접는다', () {
    final queue = [
      for (var i = 0; i < kBurstBadgeLimit + 1; i++) badge('a$i', now),
    ];
    expect(isAchievementBacklog(queue), isTrue);
  });

  test('개수가 적어도 서로 다른 날의 성취면 접는다', () {
    // 며칠 전 받은 뱃지를 지금 하나씩 터뜨리는 것은 축하가 아니라 알림 정리다.
    final queue = [
      badge('old', now.subtract(const Duration(days: 3))),
      badge('new', now),
    ];
    expect(isAchievementBacklog(queue), isTrue);
  });

  test('큐 정렬 순서에 의존하지 않는다', () {
    final ascending = [
      badge('old', now.subtract(const Duration(days: 3))),
      badge('new', now),
    ];
    final descending = ascending.reversed.toList();
    expect(
      isAchievementBacklog(descending),
      isAchievementBacklog(ascending),
    );
  });
}
