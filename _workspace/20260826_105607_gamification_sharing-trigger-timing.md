# 공유 카드(HI-08 · HI-10) 성취 확정 시점 판정

작성: gamification-designer / 2026-08-26
근거: PRD §5.2(HI-08·HI-10) §8.1 §8.4 / TRD §10.2 §11 / 마이그레이션 05·13·22·27·31·33·34·39

원칙 한 줄: **공유 카드는 앱 밖으로 나가면 회수할 수 없다. 서버가 확정한 사실만 공유 대상이다.**

---

## 0. 먼저 확인한 사실 (코드 근거)

| 사실 | 근거 |
|---|---|
| `runs` INSERT의 **BEFORE 트리거**가 `validate_run()`을 돌려 `is_flagged`를 그 자리에서 확정한다 | `05_server_guards.sql` `trg_runs_guard` |
| `recompute_season_tier`(티어 갱신)와 `evaluate_badges`(뱃지 지급)는 같은 INSERT의 **AFTER ROW 트리거**다 → **같은 트랜잭션, 동기** | `13`, `22-2` `trg_runs_recompute_stats` / `runs_01`·`runs_03` 트리거 |
| 따라서 뱃지 판정 시점에 `is_flagged`는 **이미 최종값**이고, 모든 판정 쿼리가 `status='completed' AND is_flagged=false`로 거른다 | `27`, `32`, `41` 전 조건 분기 |
| `evaluate_badges`는 지급 시 항상 `verified=true, revoked=false`로 INSERT | `27:567`, `31:112`, `39:637` |
| **`revoked=true`를 세우는 코드 경로가 저장소 전체에 없다.** `39` 주석: "INSERT 전용 — PRD §8.1에 따라 회수 경로를 만들지 말 것" | grep 결과 0건 |
| pg_cron이 도는 것은 리더보드(5분)·챌린지 상태(10분)뿐. 티어·뱃지는 배치 대상이 아니다 | `15_pg_cron_schedule.sql` |
| `tier_change_history`는 **엄격한 상승**일 때만 `reached_at`을 남긴다. 본인 SELECT 가능(RLS) | `33`, `34` |
| `profiles`는 `supabase_realtime` publication에 **없다** → 티어 변화의 realtime 푸시는 오지 않는다 | `supabase_user_repository.dart:52` 주석, `03`/`07`은 `leaderboard_entries`·`user_badges`만 추가 |
| `user_badges`는 publication에 **있고**, `watchUnseenBadges()` 스트림이 이미 구현돼 있다 | `07_rls.sql:153`, `supabase_gamification_repository.dart:60` |

---

## 1. 뱃지 획득 — 언제 축하해도 되는가

### 결론: **지급된 순간이 곧 확정이다. 잠정 상태가 아니다.**

`verified`는 "나중에 검증할 예정"이라는 뜻이 아니다. 뱃지는 이미 `is_flagged=false`로 확정된 기록만
근거로 서버 함수가 판정하므로, 행이 생겼다는 것 자체가 검증 통과를 의미한다.
자동으로 `revoked`가 서는 경로는 **존재하지 않는다**. 회수는 PRD §8.1의 "부정 기록 판정" —
즉 §8.4 "플래그 후 수동 검토"를 거친 **운영자 수동 조치**뿐이다.

### 트리거 규칙 (그대로 구현 가능)

```
이미 있는 gamificationRepository.watchUnseenBadges(userId) 스트림을 구독한다.
새 UserBadge가 들어오면 → 축하 연출 + 공유 버튼(HI-10) 노출 → markBadgesSeen()
```

- 러닝 업로드와 같은 트랜잭션에서 INSERT되므로, **온라인이면 요약 화면 연출이 끝나기 전에 도착한다.**
  HI-10의 "요약 화면 연출 종료 직후 노출"은 이 경로로 충족된다.
- **오프라인 러닝은 뱃지 이벤트가 아예 발생하지 않는다.** 동기화 후에 온다.
  요약 화면에서 뱃지 축하를 로컬 판정으로 미리 그리면 안 된다 — 그 경로가 §8.4 위반이다.
- 공유 카드의 획득 일시는 로컬 시각이 아니라 서버 행의 `earned_at`을 쓴다.

### 즉시 반영할 작은 보강 1건 (flutter-ui-designer / mobile-architect)

`watchUnseenBadges()`의 fetch 쿼리에 두 조건을 추가한다:

```dart
.eq('is_seen', false)
.eq('verified', true)     // 추가
.eq('revoked', false)     // 추가
```

지금은 서버가 항상 `verified=true, revoked=false`로만 넣어서 결과가 같지만,
운영자가 수동 회수한 뱃지가 아직 `is_seen=false`인 상태면 **회수된 뱃지를 축하하고
공유까지 시키게 된다.** 두 줄로 그 경우가 조용히 큐에서 빠진다.
(RLS상 본인 행은 전체 SELECT 가능하므로 두 컬럼 다 필터에 쓸 수 있다.
`UserBadge` 모델에 `revoked`를 추가할 필요는 없다 — 필터는 쿼리 레벨이면 충분하다.)

---

## 2. PB 갱신 — 언제 확정인가

### 먼저 지적할 구조적 사실: **`personal_bests` 테이블이 없다.**

저장소 전체에 PB를 담는 테이블·컬럼이 없다. PB는 오직 **뱃지**로만 존재한다
(`pb_first_achieved` 6종, `pb_time_lte` N종). 그리고 `evaluate_badges`는 이미 보유한
뱃지를 건너뛰므로, 이 뱃지들은 **일생에 한 번**만 발생한다.

즉 PRD HI-04가 말하는 "1/5/10km·하프 PB **자동 갱신**"(= 내 5km 기록을 25분→24분으로 경신)은
**서버에 확정 객체가 없다.** 서버가 확인해 줄 대상 자체가 없으므로 "서버 확인 후 보여준다"는
선택지가 성립하지 않는다.

### 결론: 공유 가능한 PB 순간 = **PB 뱃지 이벤트**로 한정한다 (MVP)

| 대상 | 트리거 | 공유 버튼 |
|---|---|---|
| **PB 뱃지** (`pb_first_*`, `pb_*_sub*`) | §1과 완전히 동일 — `watchUnseenBadges` 스트림 | ✅ 노출 |
| **HI-04 의미의 PB 경신** (로컬 히스토리 비교) | 요약 화면에 잠정 표시 가능 | ❌ **금지** |

로컬 판정 PB에 공유 버튼을 붙이는 것은 §8.4 정면 위반이다. 클라이언트 계산값을 신뢰하지 않는 것이
§8.4의 유일한 원칙인데, 공유 카드는 그 계산값을 앱 밖으로 내보내는 행위다.
GPS 조작으로 5km를 12분에 뛴 기록은 서버에서 플래그되어 뱃지를 못 받지만,
로컬 판정 공유 카드는 그 사실과 무관하게 이미 인스타에 올라가 있다.

### 요약 화면 트리거 규칙

```
1. 러닝 저장 직후 로컬 PB 비교값을 계산해도 된다.
   → 문구는 잠정형("이번 러닝이 5km 최고 기록이에요"), 공유 버튼 없음.
2. 업로드 성공(_push == true) + 뱃지 이벤트 도착까지 짧게 대기(권장 3초 상한).
   → 이 창 안에 PB 뱃지가 오면 확정 연출로 승격 + 공유 버튼 노출.
3. 오프라인/업로드 실패면 pending 상태 유지.
   "동기화되면 확정돼요" — 공유 버튼 없음. 나중에 동기화되면 §1 경로로 알림이 뜬다.
4. 서버가 플래그한 기록이면 성취 블록을 조용히 생략한다.
   회수 애니메이션을 넣지 않는다 (TRD §11: 설명 없이 박탈하지 않음).
```

`is_flagged`는 업로드 응답 시점에 이미 최종값이므로, **"나중에 걸릴 가능성"은
자동 경로에는 없다.** 남는 위험은 §8.4의 "경로 비현실성 → 플래그 후 수동 검토"뿐이고,
이건 사람이 개입하는 사후 조치라 클라이언트가 기다릴 대상이 아니다.

### 막힌 지점 — mobile-architect 확인 필요 (2건)

1. **`RunRecord`에 `isFlagged` / `flagReason` 필드가 없다.** 서버 컬럼은 있는데 모델에 없다.
2. **`local_run_repository.dart:79`의 `upsert()`에 `.select()`가 없다.** 서버가 확정한
   `is_flagged`를 클라이언트가 읽어올 방법이 아예 없다.

이 둘 때문에 위 규칙 4번(플래그 시 성취 블록 생략)이 현재 코드로는 구현 불가다.
지금 상태로는 "업로드는 성공했는데 뱃지가 안 온" 경우와 "플래그된" 경우를 구분할 수 없어,
사용자는 이유 없이 아무 일도 안 일어나는 화면을 본다.

**요청**: `RunRecord`에 읽기 전용 `isFlagged`(+ `flagReason`) 추가,
`_push`를 `.upsert(payload).select().single()`로 바꿔 서버 확정값을 로컬에 반영.
서버 가드가 이 컬럼의 클라이언트 입력을 무시하므로(`trg_runs_guard`) 업로드 방향 위험은 없다.

---

## 3. 티어 승급 — 언제 확정인가

### 결론: **동기다. 배치가 아니다.**

`recompute_season_tier`는 `runs_01_recompute_stats` AFTER ROW 트리거 안에서 돌고,
그 안에서 `profiles.current_tier`를 갱신하고 `tier_change_history`에 상승 행을 넣는다.
전부 러닝 INSERT와 같은 트랜잭션이다 — PRD §8.1 "판정 시점: 기록 저장 즉시, 배치 대기 없음"이
문자 그대로 구현돼 있다. 배치(`reset_stale_seasons`)와 `sync_my_season()` RPC는 **시즌 롤오버**
지연 복구용이지 승급 판정 경로가 아니다.

### 트리거 규칙

```
1. 업로드 직전 profile 스냅샷 보관: (currentTier, tierSeasonId)
2. _push 성공 직후 userRepository.currentUser() 재조회 (realtime 불필요 — profiles는
   publication에 없어서 어차피 푸시가 안 온다)
3. isTierPromotion(prev, prevSeasonId, curr, currSeasonId) == true 이면
   → 승급 축하 + 공유 버튼(HI-10)
```

- **realtime 구독을 새로 만들지 말 것.** `profiles`를 publication에 넣는 것은 스키마 변경이고,
  값이 업로드 트랜잭션에서 이미 확정되므로 재조회 한 번이면 충분하다.
- **시즌 id를 반드시 함께 비교한다.** 분기 경계에서 전원이 브론즈로 리셋되므로(§8.1),
  시즌이 다른 두 티어를 비교하면 롤오버를 "강등"으로 오인하거나 그 반대가 된다.
  → `isTierPromotion()`이 이 가드를 포함한다.
- **앱이 죽어도 놓치지 않으려면**: 마지막으로 축하한 `(seasonId, tier)`를 로컬에 저장하고
  앱 시작 시 현재 프로필과 비교한다. 카드에 넣을 정확한 승급 시각이 필요하면
  `tier_change_history`에서 `(user_id, season_id, tier)`로 `reached_at`을 읽는다(본인 SELECT 허용).
- **강등은 축하 대상이 아니다.** 시즌 중 강등은 기록 삭제 시에만 발생하고(§8.1),
  `isTierPromotion`이 엄격한 상승만 통과시키므로 자동으로 걸러진다.

---

## 4. 부정행위 방지 원칙과 충돌하는 트리거 방식 — 금지 목록

| 하면 안 되는 것 | 이유 |
|---|---|
| 로컬 뱃지 판정 결과로 공유 카드를 띄운다 | §8.4. 서버가 플래그한 기록도 카드가 나간다 |
| 로컬 PB 비교 결과에 공유 버튼을 붙인다 | 위와 동일. 현재 서버에 대응 확정 객체조차 없다 |
| 클라이언트가 `TierX.fromSeasonDistanceMeters()`로 계산한 티어로 승급 축하를 띄운다 | `enums.dart:220` 주석이 명시적으로 금지 — 표시용 예측 전용 |
| 업로드 전(오프라인 상태)에 "확정" 문구로 성취를 보여준다 | 동기화 후 뒤집히면 사용자가 이미 공유한 뒤다 |
| 뱃지 회수(`revoked`) 시 취소 애니메이션을 재생한다 | TRD §11 — 설명 없이 박탈하지 않는다. 조용히 목록에서 제외 |

---

## 5. 남긴 코드

`lib/features/gamification/domain/achievement_moment.dart` (신규, 순수 함수 3개)

| 함수 | 용도 |
|---|---|
| `AchievementGate achievementGate({runSynced, runFlagged})` | 요약 화면 성취 블록 상태 — `confirmed` / `pending` / `flagged` |
| `bool isTierPromotion({previousTier, previousSeasonId, currentTier, currentSeasonId})` | 시즌 가드 포함 엄격 상승 판정 |
| `bool isBadgeShareable({verified, revoked})` | 서버 행 값 기준 공유 허용 판정 |

전부 입력→출력만 의존. backend-engineer가 서버에서 같은 판단을 해야 할 일이 생기면 그대로 이식 가능.

---

## 6. 다른 에이전트에게 넘기는 것

**mobile-architect**
- `RunRecord`에 읽기 전용 `isFlagged` / `flagReason` 추가
- `local_run_repository.dart:79` `_push`의 `upsert()` → `.select().single()`로 서버 확정값 회수
- 업로드 전 프로필 스냅샷 보관 → 업로드 성공 후 재조회 → `isTierPromotion()` 비교 배선
- 마지막 축하한 `(seasonId, tier)` 로컬 영속화 (앱 재시작 시 놓침 방지)

**flutter-ui-designer**
- 뱃지·PB 공유 카드는 `watchUnseenBadges()` 스트림 이벤트로만 트리거
- 요약 화면 성취 블록은 `AchievementGate` 3상태로 분기. `pending`에는 공유 버튼을 렌더하지 않는다
- `watchUnseenBadges` 쿼리에 `.eq('verified', true).eq('revoked', false)` 추가
- 티어 승급 축하는 realtime이 아니라 업로드 후 프로필 재조회 결과로 트리거

**backend-engineer** (판단 필요, 이번 라운드 범위 밖)
- HI-04의 "PB 자동 갱신"을 뱃지 외의 형태로도 남길 것인지 —
  현재 서버에 PB 확정 객체가 없어 반복 경신은 공유 대상이 될 수 없다.
  필요하다면 `personal_bests(user_id, distance_km, best_seconds, run_id, achieved_at)` 같은
  서버 확정 테이블이 선행돼야 한다
- `profiles`를 `supabase_realtime` publication에 넣을지 — **지금은 불필요하다는 것이 이 문서의 결론.**
  넣지 않아도 승급 트리거가 정확하게 동작한다
