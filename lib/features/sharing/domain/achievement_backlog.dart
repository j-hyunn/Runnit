/// 밀려 있던 성취를 **한 번에 접어서** 보여줄지 판정한다 (TRD §14 #19).
///
/// ## 왜 필요한가
/// `user_badges.is_seen`은 컬럼만 있었을 뿐 **어떤 화면도 구독한 적이 없어서**
/// 지금까지 전부 `false`로 쌓여 왔다. 축하 연출을 켜는 순간 기존 사용자에게는
/// 그동안 받은 뱃지가 한꺼번에 큐로 쏟아진다 — 다이얼로그를 20번 닫게 만드는
/// 것은 축하가 아니라 벌이다.
///
/// ## 왜 로컬 플래그("이미 처리했음")를 두지 않는가
/// 접어서 보여준 뒤 `markAchievementsSeen`을 부르면 **서버 행이 `is_seen=true`가
/// 되어 큐에서 영구히 빠진다.** 즉 "한 번만"이라는 상태를 이미 서버가 들고 있다.
/// SharedPreferences에 같은 사실을 한 번 더 적으면, 두 값이 어긋나는 날
/// (재설치·기기 변경) 사용자는 축하를 통째로 잃거나 두 번 본다.
library;

import '../../../models/models.dart';

/// 한 번의 러닝이 현실적으로 터뜨릴 수 있는 뱃지 수의 상한.
///
/// 10km 달성 러닝 하나가 누적거리·단일세션·시간대·PB를 동시에 만족시키는 일은
/// 실제로 있지만, 그래도 한 자릿수 초반이다. 이보다 많으면 "이번 러닝의 성과"가
/// 아니라 "밀려 있던 것"이라고 보는 편이 맞다.
const int kBurstBadgeLimit = 5;

/// 같은 세션의 성취로 볼 수 있는 획득 시각 간격의 상한.
///
/// 서버는 러닝 업로드와 **같은 트랜잭션**에서 뱃지를 발급하므로 한 러닝에서 나온
/// 뱃지들의 `earnedAt`은 사실상 동일하다. 하루 이상 벌어져 있다면 서로 다른 날의
/// 성취가 큐에 함께 남아 있다는 뜻이다.
const Duration kBurstBadgeSpan = Duration(hours: 24);

/// 큐를 "밀린 성취"로 보고 요약 화면으로 접어야 하는가.
///
/// 두 신호 중 하나라도 걸리면 접는다:
/// 1. 개수가 [kBurstBadgeLimit]를 넘는다.
/// 2. 가장 오래된 것과 가장 최근 것의 획득 시각이 [kBurstBadgeSpan] 넘게 벌어져
///    있다 — 개수가 적어도 **서로 다른 날의 성취**라면 한 건씩 축하 연출을
///    재생하는 것이 어색하다("3일 전에 받은 뱃지"를 지금 터뜨리는 셈).
///
/// 개수만으로 판정하지 않는 이유가 2번이다. 반대로 시간 간격만 보면, 한 러닝이
/// 뱃지 12개를 터뜨린 경우(시즌 첫 러닝 등)를 놓친다.
bool isAchievementBacklog(List<UserBadge> queue) {
  if (queue.length <= 1) return false;
  if (queue.length > kBurstBadgeLimit) return true;

  var oldest = queue.first.earnedAt;
  var newest = queue.first.earnedAt;
  for (final badge in queue) {
    if (badge.earnedAt.isBefore(oldest)) oldest = badge.earnedAt;
    if (badge.earnedAt.isAfter(newest)) newest = badge.earnedAt;
  }
  return newest.difference(oldest) > kBurstBadgeSpan;
}
