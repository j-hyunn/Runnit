/// 레벨 곡선 — **서버 `compute_level()`의 클라이언트 재현본**.
///
/// ## 이 파일의 위치
/// 정본은 서버다. `AppUser.level` / `AppUser.totalXp`는 서버가 확정해 내려주는
/// 값이고, 클라이언트는 그것을 표시할 뿐이다. 이 파일은 **"다음 레벨까지 320XP"**
/// 같은 UI 문구를 서버 왕복 없이 만들기 위한 것이지, 레벨을 결정하기 위한 것이 아니다.
///
/// 화면에 레벨 숫자를 그릴 때는 [levelForXp]가 아니라 **`AppUser.level`을 쓸 것.**
/// 두 값이 어긋나면 서버 값이 옳다.
///
/// ## XP는 포인트가 아니다
/// PRD §5.6의 "포인트"는 **Phase 4의 상품 교환 화폐**(거리 비연동 적립)다.
/// 레벨을 올리는 재화는 **XP**이고 이름을 분리했다(2026-08-26 확정).
/// `totalPoints`라는 이름은 Phase 4에 반납했다 — 이 파일에 되살리지 말 것.
///
/// ## 서버와의 대응 (필수 유지)
/// ```sql
/// public.xp_level_thresholds()  -- 아래 [thresholds]와 글자 그대로 같은 60개 정수
/// public.compute_level(xp) = max{L : thresholds[L] <= xp}
/// ```
/// 정본: `_workspace/20260826_000340_gamification_badge-backlog-decisions.md` §1.2,
/// `docs/TRD.md` §3.8.3.
///
/// ## 왜 배열인가 — 닫힌 식을 쓰지 않는 이유
/// 유도식은 `XP_required(L) = ceil(50 × (L−1)^2.2)`지만, **그 식을 런타임에
/// 계산하지 않는다.** 지수 역함수의 부동소수 오차가 "레벨업까지 1pt 남음"을
/// 고착시키는 버그를 실제로 일으킨 전례가 있다
/// (`_workspace/20260819_210450_badge_rules.md` §4.3 — 구 곡선의 L=33에서
/// `pow(32, 1.6)`이 정답보다 3e-16 커지고 `ceil()`이 그 오차를 정수 1로 증폭했다).
///
/// 상한이 60인 이상 60개 정수를 양쪽에 그대로 심는 것이 가장 단순하고 **정확히
/// 동일**하다. 보정 루프도, 역함수도 필요 없다.
library;

/// 모든 계산이 입력에만 의존하는 순수 함수 모음.
class LevelCurve {
  const LevelCurve._();

  /// 레벨 L에 진입하는 데 필요한 누적 XP. **인덱스 = 레벨 − 1** (0-based 배열).
  ///
  /// 서버 `public.xp_level_thresholds()`와 한 값이라도 달라지면 사용자가 보는
  /// 진행률과 실제 레벨업 시점이 어긋난다.
  static const List<int> thresholds = <int>[
    0, 50, 230, 561, 1056, 1725, 2576, 3616, 4851, 6285, //          L1..L10
    7925, 9774, 11836, 14114, 16614, 19337, 22287, 25466, 28879, 32526, // L11..L20
    36412, 40538, 44906, 49519, 54380, 59490, 64851, 70465, 76334, 82461, // L21..L30
    88846, 95492, 102401, 109573, 117011, 124716, 132690, 140934, 149450, 158239, // L31..L40
    167303, 176643, 186260, 196156, 206332, 216790, 227530, 238554, 249863, 261458, // L41..L50
    273341, 285513, 297974, 310726, 323770, 337108, 350739, 364666, 378889, 393410, // L51..L60
  ];

  /// 최대 레벨. 카탈로그의 `lvl_60` 표시명이 이미 "만렙"(diamond)이다.
  /// 구 곡선의 상한 100은 폐기됐다 — 60 위에 아무 보상도 없는 40레벨을 남기면
  /// 레벨 숫자만 인플레이션된다.
  static int get maxLevel => thresholds.length;

  /// 누적 XP → 레벨. 서버 `compute_level`과 **정수 비교만으로** 일치한다.
  ///
  /// 서버 값(`AppUser.level`)이 있으면 그쪽을 쓴다. 이 함수는 서버 값이 아직
  /// 도착하지 않았을 때의 낙관적 추정이거나, 아래 진행률 계산의 내부 보조용이다.
  static int levelForXp(int totalXp) {
    if (totalXp <= 0) return 1;
    // 이진 탐색: thresholds[i] <= totalXp 인 마지막 i.
    var lo = 0;
    var hi = thresholds.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (thresholds[mid] <= totalXp) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo + 1;
  }

  /// 레벨 [level]에 도달하는 데 필요한 누적 XP. `xpRequiredFor(1) == 0`.
  ///
  /// [levelForXp]의 **정확한 역함수**다 — 배열을 직접 읽으므로 보정 루프가 없다.
  /// 모든 L에 대해 `levelForXp(xpRequiredFor(L)) == L`이고
  /// `levelForXp(xpRequiredFor(L) - 1) == L - 1`이 성립한다.
  static int xpRequiredFor(int level) {
    if (level <= 1) return 0;
    final capped = level > maxLevel ? maxLevel : level;
    return thresholds[capped - 1];
  }

  /// 현재 레벨 구간의 시작 XP(= 이 레벨에 진입할 때의 누적 XP).
  static int currentLevelFloor(int level) => xpRequiredFor(level);

  /// 다음 레벨에 필요한 누적 XP. 만렙이면 null.
  static int? nextLevelThreshold(int level) =>
      level >= maxLevel ? null : xpRequiredFor(level + 1);

  /// 다음 레벨까지 남은 XP. 만렙이면 null.
  ///
  /// [level]은 서버가 내려준 `AppUser.level`을 넘기는 것을 권장한다.
  /// 생략하면 [totalXp]로부터 추정한다.
  static int? xpToNextLevel(int totalXp, {int? level}) {
    final lv = level ?? levelForXp(totalXp);
    final next = nextLevelThreshold(lv);
    if (next == null) return null;
    final remaining = next - totalXp;
    return remaining < 0 ? 0 : remaining;
  }

  /// 현재 레벨 구간 안에서의 진행률 0.0~1.0. 만렙이면 1.0.
  ///
  /// 프로그레스 바 채우기용. 레벨 전체가 아니라 **현재 구간만**의 비율이다.
  static double levelProgress(int totalXp, {int? level}) {
    final lv = level ?? levelForXp(totalXp);
    if (lv >= maxLevel) return 1.0;
    final floor = currentLevelFloor(lv);
    final next = xpRequiredFor(lv + 1);
    final span = next - floor;
    if (span <= 0) return 1.0;
    final gained = totalXp - floor;
    return (gained / span).clamp(0.0, 1.0);
  }

  /// 만렙 여부.
  static bool isMaxLevel(int level) => level >= maxLevel;
}
