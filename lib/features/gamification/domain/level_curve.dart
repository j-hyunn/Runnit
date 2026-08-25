
/// 레벨 곡선 — **서버 `compute_level()`의 클라이언트 재현본**.
///
/// ## 이 파일의 위치
/// 정본은 서버다. `AppUser.level` / `AppUser.totalPoints`는 서버가 확정해 내려주는
/// 값이고, 클라이언트는 그것을 표시할 뿐이다. 이 파일은 **"다음 레벨까지 320pt"**
/// 같은 UI 문구를 서버 왕복 없이 만들기 위한 것이지, 레벨을 결정하기 위한 것이 아니다.
///
/// 화면에 레벨 숫자를 그릴 때는 [levelForPoints]가 아니라 **`AppUser.level`을 쓸 것.**
/// 두 값이 어긋나면 서버 값이 옳다.
///
/// ## 서버와의 대응 (필수 유지)
/// ```sql
/// compute_level(p) = least(1 + floor(power(greatest(p,0)::numeric / 500.0, 1.0/1.6)), 100)
/// ```
/// 확정 근거: `_workspace/20260819_210450_badge_rules.md` §4.
/// 서버 산식이 바뀌면 이 파일도 **반드시 함께** 바꾼다. 갈라지면 사용자가 보는
/// 진행률과 실제 레벨업 시점이 어긋난다.
library;

import 'dart:math' as math;

/// 모든 계산이 입력에만 의존하는 순수 함수 모음.
class LevelCurve {
  const LevelCurve._();

  /// 레벨 2에 필요한 누적 포인트. 곡선의 스케일 계수.
  static const int basePoints = 500;

  /// 체증 지수. 클수록 후반 레벨업이 느려진다.
  static const double exponent = 1.6;

  /// 최대 레벨. 서버 `compute_level`의 `least(..., 100)`과 동일.
  static const int maxLevel = 100;

  /// 누적 포인트 → 레벨.
  ///
  /// 서버 값(`AppUser.level`)이 있으면 그쪽을 쓴다. 이 함수는 서버 값이 아직
  /// 도착하지 않았을 때의 낙관적 추정이거나, 아래 진행률 계산의 내부 보조용이다.
  static int levelForPoints(int totalPoints) {
    if (totalPoints <= 0) return 1;
    final level = 1 + (math.pow(totalPoints / basePoints, 1 / exponent)).floor();
    return level > maxLevel ? maxLevel : level;
  }

  /// 레벨 [level]에 도달하는 데 필요한 누적 포인트.
  ///
  /// [levelForPoints]의 **정확한 역함수**다: 모든 L에 대해
  /// `levelForPoints(pointsRequiredFor(L)) == L`이고
  /// `levelForPoints(pointsRequiredFor(L) - 1) == L - 1`이 성립한다.
  /// `pointsRequiredFor(1) == 0`.
  ///
  /// ## 왜 닫힌 식(`ceil(500 * (L-1)^1.6)`)을 그대로 쓰지 않는가
  /// 지수 `1.6`은 이진 부동소수로 정확히 표현되지 않는다. 그래서 예컨대 L=33에서
  /// `pow(32, 1.6)`이 수학적 정답 256보다 약 3e-16 크게 나오고, `ceil()`이 그 오차를
  /// 정수 1로 증폭해 128001을 돌려준다. 그런데 [levelForPoints]는 128000에서 이미
  /// 33을 반환한다 — "레벨업까지 1pt 남았다"고 표시된 뒤 포인트가 늘어도 숫자가
  /// 그대로인 버그가 된다. 아래 보정 루프가 두 함수를 정확히 맞물리게 한다
  /// (오차가 1 미만이므로 실제로는 0~1회만 돈다).
  static int pointsRequiredFor(int level) {
    if (level <= 1) return 0;
    final capped = level > maxLevel ? maxLevel : level;
    var points = (basePoints * math.pow(capped - 1, exponent)).ceil();
    // 과대 추정 보정: 한 단계 아래 포인트로도 이미 목표 레벨이면 내린다.
    while (points > 0 && levelForPoints(points - 1) >= capped) {
      points -= 1;
    }
    // 과소 추정 보정: 목표 레벨에 못 미치면 올린다.
    while (levelForPoints(points) < capped) {
      points += 1;
    }
    return points;
  }

  /// 현재 레벨 구간의 시작 포인트(= 이 레벨에 진입할 때의 누적 포인트).
  static int currentLevelFloor(int level) => pointsRequiredFor(level);

  /// 다음 레벨에 필요한 누적 포인트. 만렙이면 null.
  static int? nextLevelThreshold(int level) =>
      level >= maxLevel ? null : pointsRequiredFor(level + 1);

  /// 다음 레벨까지 남은 포인트. 만렙이면 null.
  ///
  /// [level]은 서버가 내려준 `AppUser.level`을 넘기는 것을 권장한다.
  /// 생략하면 [totalPoints]로부터 추정한다.
  static int? pointsToNextLevel(int totalPoints, {int? level}) {
    final lv = level ?? levelForPoints(totalPoints);
    final next = nextLevelThreshold(lv);
    if (next == null) return null;
    final remaining = next - totalPoints;
    return remaining < 0 ? 0 : remaining;
  }

  /// 현재 레벨 구간 안에서의 진행률 0.0~1.0. 만렙이면 1.0.
  ///
  /// 프로그레스 바 채우기용. 레벨 전체가 아니라 **현재 구간만**의 비율이다.
  static double levelProgress(int totalPoints, {int? level}) {
    final lv = level ?? levelForPoints(totalPoints);
    if (lv >= maxLevel) return 1.0;
    final floor = currentLevelFloor(lv);
    final next = pointsRequiredFor(lv + 1);
    final span = next - floor;
    if (span <= 0) return 1.0;
    final gained = totalPoints - floor;
    return (gained / span).clamp(0.0, 1.0);
  }

  /// 만렙 여부.
  static bool isMaxLevel(int level) => level >= maxLevel;
}
