# 알림 트리거 게이미피케이션 규칙 (NT-01~06)

- 작성: gamification-designer / 2026-08-28
- 근거: PRD §5.10 · §5.3.2 · §5.4(RK-04·05·06) · §5.4.1 · §5.5(GM-04) · §8.2 · §8.5 · §8.6,
  TRD §3.8 · §4.3 · §10.2, `_workspace/20260828_164428_architect_notifications.md` §9(남은 결정 1~4)
- 대상: backend-engineer (SQL 이식) / flutter-ui-designer (문구·payload 표시)
- 범위: **판정 규칙만.** 스키마·모듈 구조는 architect 문서가 정본이다.

---

## 0. 이 문서를 지배하는 두 문장

**① 도달 불가능한 목표는 동기를 죽인다.** 모든 임계치는 "지금부터 한 번의 러닝, 늦어도
한 주 안에 뒤집을 수 있는 범위"로 잡았다. 범위를 벗어나면 **아예 보내지 않는다.**
"250km까지 92km 남았어요"는 격려가 아니라 포기 통보다.

**② 알림 한 건의 예산은 유한하다.** 사용자가 알림을 끄는 순간 이 앱의 이중 경쟁
루프(PRD §4.2)는 존재하지 않게 된다. 그래서 아래 모든 규칙에는 **상한이 있고, 상한은
count 쿼리가 아니라 `dedupe_key` unique 제약으로 강제한다.** 애플리케이션 레벨 체크는
pg_cron 재실행 경합에서 새어 나간다.

**주간 총 알림 예산 (전 종류 합산 목표): 평균 4~6건 / 최대 9건.**

| 종류 | 주당 최대 | 성격 |
|---|---|---|
| NT-01 티어 승급 | 시즌당 3 (구조적 상한) | 사건 |
| NT-02 티어 근접 | 시즌당 3 (구조적 상한) | 사건 |
| NT-03 시즌 D-day | 시즌당 2 | 배치 |
| NT-04 순위 변동 | **4** (하락 3 + 상승 2, 합계 4 cap) | 배치 |
| NT-05 주말 유도 | **2** (토 1 + 일 1) | 배치 |
| NT-06 뱃지·레벨 | 러닝당 1 + 주간뱃지 1 | 사건 |

---

## 1. NT-02 — 다음 티어 근접

### 1.1 임계치: 절대 5km가 아니라 **구간별 고정 테이블**

아키텍트 제안(전 구간 5km)을 채택하지 않는다. 근거:

| 구간 | 구간 폭 | 5km의 의미 | 문제 |
|---|---|---|---|
| 브론즈→실버 | 25km | 구간의 20% | 적절 |
| 실버→골드 | 75km | 구간의 6.7% | 밴드가 너무 좁다 |
| 골드→플래티넘 | 150km | 구간의 3.3% | **거의 아무도 밴드를 통과하지 못한다** |

트리거는 "러닝 저장 후 잔여 거리가 임계치 이하로 내려간 순간"이다. 밴드가 좁으면 한 번의
러닝이 밴드를 **건너뛰어** 통과하고(예: 잔여 12km → 러닝 8km → 잔여 4km는 밴드 진입이지만,
잔여 12km → 러닝 14km면 승급이라 NT-01이 대신 발화), 밴드 폭이 주 평균 러닝 거리보다 좁을수록
"근접 알림을 한 번도 못 받고 승급하는" 사용자 비율이 올라간다. 플래티넘 페이스 러너의 주
평균은 19km(PRD §5.3.2)이므로 5km 밴드는 사실상 무의미하다.

**확정 임계치 — 상수 테이블(계산식 아님):**

| 다음 티어 | 임계치 `NT02_THRESHOLD_M` | 구간 대비 | 근거 |
|---|---|---|---|
| 실버 (25km) | **5,000m** | 20% | 1회 러닝 |
| 골드 (100km) | **10,000m** | 13% | 1~2회 러닝 |
| 플래티넘 (250km) | **15,000m** | 10% | 한 주 분량 |
| — (플래티넘 도달자) | 발송 안 함 | — | 다음 티어 없음 |

레벨 임계값(TRD §3.8.3)과 같은 원칙이다 — **비율 계산식을 런타임에 돌리지 않고 정수
테이블을 심는다.** 부동소수 경계에서 "잔여 5,000.0001m"가 밴드 밖으로 새는 사고를 원천 차단.

```sql
-- 서버 상수. immutable 함수로 두면 조건 판정에서 그대로 쓸 수 있다.
create or replace function public.tier_proximity_threshold_m(p_next public.tier)
returns integer language sql immutable as $$
  select case p_next
    when 'silver'   then 5000
    when 'gold'     then 10000
    when 'platinum' then 15000
    else null end;
$$;
```

### 1.2 발화 조건 (러닝 저장 AFTER 트리거, NT-01과 같은 트랜잭션)

전부 참일 때만 1건 발행한다.

| # | 조건 | 근거 |
|---|---|---|
| 1 | `next_tier is not null` (현재 플래티넘 아님) | 다음 목표가 없다 |
| 2 | `remaining_m > 0` | **0 이하면 승급이므로 NT-01이 대신 나간다.** 같은 러닝에서 두 건이 겹치면 안 된다 |
| 3 | `remaining_m <= tier_proximity_threshold_m(next_tier)` | §1.1 |
| 4 | 이 러닝이 `is_flagged = false` 이고 티어 반영 대상(PRD §8.3 — 실내·수동 제외) | 반영 안 되는 기록으로 "곧 승급"이라 알리면 거짓말이 된다 |
| 5 | 시즌 종료까지 **24시간 초과** 남음 | 남은 시간에 도달 불가능한 목표는 안 보낸다(§0-①). D-3은 NT-03이 담당 |
| 6 | `notification_settings.tier_proximity`가 on (행 없으면 on) | NT-08 |

### 1.3 발송 빈도 상한 — **시즌·티어당 정확히 1회, 재발송 없음**

```
dedupe_key = tier_proximity:{season_id}:{next_tier}
예) tier_proximity:2026-Q3:gold
```

한 시즌 최대 3건(실버·골드·플래티넘). unique 제약이 곧 상한이다.

**재발송 조건: 없다.** 근거:
- 시즌 누적 거리는 **단조 증가**한다(TI-08, 강등 없음). 즉 잔여 거리는 단조 감소하므로
  정상 경로에서 사용자는 각 밴드에 **단 한 번만** 진입한다. 재발송 규칙 자체가 필요 없다.
- 예외는 §8.4 부정 기록 무효화로 누적 거리가 줄어드는 경우다. 이때 잔여 거리가 밴드 밖으로
  나갔다가 다시 들어오면 알림이 두 번 간다 — **`dedupe_key`가 이것을 막는다.** 무효화를
  당한 사용자에게 "다시 5km 남았어요"를 보내는 것은 최악의 UX다.

⚠️ **주중 승급(§8.6)으로 티어가 오르면 다음 밴드의 키가 달라지므로 자연히 다시 발화한다.**
브론즈→실버 승급 직후 잔여 골드 75km는 밴드 밖이라 발화하지 않고, 나중에 10km 이하로
내려올 때 `...:gold` 키로 1회 나간다. 의도된 동작이다.

### 1.4 문구

```
title: "{next_tier_ko}까지 {remaining_km}km"
body : "이번 시즌 {season_distance_km}km를 달렸어요. 한 번만 더 나가면 {next_tier_ko}예요."
route: /home
payload: { tier: "{next_tier}", remaining_m: {remaining_m}, season_id: "{season_id}" }
```

- `remaining_km` = `round(remaining_m / 100.0) / 10.0` — **소수점 1자리.** "4.7km"가 "5km"보다
  구체적이고, 구체적인 숫자가 행동을 부른다.
- `next_tier_ko` = 실버 / 골드 / 플래티넘.
- 이모지·아이콘은 클라이언트 표시 레이어(`notification_display.dart`)가 붙인다. 서버 문구에
  넣지 않는다 — 푸시 트레이와 알림함의 렌더링 폭이 달라 깨진다.

---

## 2. NT-03 — 시즌 종료 D-14 / D-3

### 2.1 대상 필터: 전원 아님. **D-day별로 다른 필터 + 3가지 문구 변형**

D-14와 D-3은 목적이 다르다. D-14는 **광범위한 재참여**, D-3은 **막판 승급 유도**다.
같은 필터를 쓰면 D-3에 "92km 남았어요"가 나가서 §0-①을 정면으로 위반한다.

**승급 가능권 판정 — 남은 일수 × 페르소나 주간 거리로 역산:**

| D-day | 남은 기간 | 페르소나 실현 거리(주 15~30km) | `NT03_REACHABLE_M` |
|---|---|---|---|
| D-14 | 2주 | 30~60km | **40,000m** |
| D-3 | 3일 (러닝 1~2회) | 5~15km | **10,000m** |

중간값을 택했다. 상단값(60km/15km)을 쓰면 "가능하다"는 문구가 다수에게 거짓이 되고,
하단값을 쓰면 실제로 승급 가능한 사용자를 놓친다.

**활동 상태 정의 (공통):**
```
활동중(active)  := 최근 14일 내 completed·비플래그 러닝 ≥ 1건
휴면(dormant)   := 활동중 아님 AND 이번 시즌 러닝 ≥ 1건
미참여          := 이번 시즌 러닝 0건 → 두 D-day 모두 발송 안 함
```
미참여자를 제외하는 이유: 시즌 서사에 한 번도 들어온 적 없는 사용자에게 "시즌 D-3"은
의미를 모르는 알림이고, 첫 알림이 이해 불가능하면 그대로 꺼진다.

**발송 매트릭스:**

| D-day | 대상 | 변형 | 발송 |
|---|---|---|---|
| **D-14** | 활동중 + 휴면 (= 시즌 러닝 ≥1건 전원) | 승급권(`remaining_m ≤ 40km`) → **A** / 그 외 → **B** / 플래티넘 → **C** | ✅ |
| **D-3** | 승급권(`remaining_m ≤ 10km`) — 활동중·휴면 무관 | **A** | ✅ |
| **D-3** | 승급권 아님 AND **활동중** | **B** | ✅ |
| **D-3** | 승급권 아님 AND **휴면** | — | ❌ **보내지 않는다** |
| **D-3** | 플래티넘 도달자 | **C** | ✅ |

🔵 D-3에서 휴면·비승급권을 제외한 유일한 이유: 이들에게 D-3은 **아무 행동도 유발하지
못하는 순수 소음**이다. D-14에서 이미 한 번 불렀고 반응하지 않았다. 두 번째 알림이
데려오지 못할 사용자에게 두 번째 알림을 보내는 비용은 "알림 끄기"다.

### 2.2 문구 3변형

**A — 승급 가능권 (막판 승급 유도)**
```
title: "시즌 종료 D-{days_left} · {next_tier_ko}까지 {remaining_km}km"
body : "{days_left}일 안에 {remaining_km}km면 이번 시즌을 {next_tier_ko}로 마감해요."
route: /home
```

**B — 승급권 밖 (시즌 마무리 서사)**
```
title: "시즌 종료 D-{days_left}"
body : "{season_label} 시즌을 {season_distance_km}km · {current_tier_ko}로 달려왔어요.
        남은 {days_left}일 기록이 이번 시즌 뱃지에 남습니다."
route: /profile
```
승급 잔여 거리를 **넣지 않는다.** "92km 남았다"는 정보는 이 사용자에게 실패 통지다.
대신 이미 쌓은 것(누적 거리·현재 티어·영구히 남는 뱃지 GM-07)을 보여준다.

**C — 플래티넘 도달자 (다음 티어 없음)**
```
title: "시즌 종료 D-{days_left} · {season_label} 플래티넘 확정"
body : "{season_distance_km}km. 남은 {days_left}일은 주간 랭킹에서 마무리해요."
route: /ranking
```
PRD §5.3.2가 인정한 한계("상위 러너는 시즌 후반 목표가 사라진다")를 주간 랭킹으로
넘겨주는 지점이다.

### 2.3 상한 / dedupe

```
dedupe_key = season_ending:{season_id}:d{days_left}
예) season_ending:2026-Q3:d14 · season_ending:2026-Q3:d3
```
시즌당 최대 2건. 변형(A/B/C)은 키에 넣지 않는다 — 같은 D-day에 변형만 다른 두 건이 가는
사고를 키가 막아야 한다.

**발송 시각: 매일 09:00 KST** 배치에서 `season_end - now()` 를 KST 날짜 기준으로 계산.
아침이 하루 러닝 계획을 세우는 시각이다. D-3은 금요일에 걸리는 경우가 많아 주말 러닝
계획과 맞물린다.

**공통 payload:**
```json
{ "season_id": "2026-Q3", "days_left": 14, "tier": "gold",
  "remaining_m": 8200, "season_distance_m": 91800, "variant": "A" }
```
`variant`는 클라이언트가 아이콘/톤을 고르는 용도다. 문구 조립에는 쓰지 않는다.

---

## 3. NT-04 — 순위 추월 / 추월당함

### 3.1 ⚠️ 먼저: `rank_delta`를 알림 기준으로 쓰면 안 된다

`leaderboard_entries.rank_delta`는 마이그레이션 03/11/16/24에서
`rank_delta = le.rank - excluded.rank`, 즉 **직전 5분 배치 대비 변동**이다.
이걸 알림 트리거로 쓰면:

- 5분마다 ±1~2계단 진동하는 사용자에게 하루 수십 건이 나간다
- 3계단 내려갔다 3계단 올라온 사용자에게 "추월당함" + "추월함" 두 건이 나가고,
  **순 변동은 0인데 알림은 2건**이다

**기준선은 "5분 전 순위"가 아니라 "마지막으로 사용자에게 알려준 순위"여야 한다.**

**backend 요청 — `leaderboard_entries`에 2컬럼 추가:**
```sql
alter table public.leaderboard_entries
  add column notified_rank integer,      -- 이 사용자에게 마지막으로 통지한 rank
  add column notified_at   timestamptz;  -- 통지 시각 (심야 억제·간격 판정용)
```
`rank_delta`는 UI의 "↑3" 표시용으로 그대로 둔다. 역할이 다르다.

### 3.2 발화 조건

**평가 시점: 랭킹 확정 배치 직후가 아니라, 별도 NT-04 패스를 매시 정각 체이닝.**
5분 배치마다 평가하면 아래 상한을 하루 이른 시각에 다 소진한다. 매시 1회면 상한 4건이
주 전체에 자연스럽게 분산된다.

**공통 게이트 (전부 참):**

| # | 조건 | 근거 |
|---|---|---|
| G1 | `period='weekly'` AND `metric='distance'` AND `scope='global'` | 티어 내 개인 순위만 (크루 P2 제외) |
| G2 | 현재 시각이 **KST 08:00~22:00** | 방해 금지. 배치 계열은 심야 발송 금지 |
| G3 | **주 시작 후 24시간 경과** (월 00:00 기준) | 주 초에는 표본이 1~2건이라 순위가 무의미하게 요동친다 |
| G4 | `participant_count >= 10` | 참가자가 한 자리면 "3계단 하락"이 곧 꼴찌다. 소규모 티어는 NT-05가 담당 |
| G5 | `notified_rank is not null` | 첫 진입은 비교 대상이 없다. 첫 배치에서 `notified_rank`만 채우고 알림은 안 보낸다 |
| G6 | `notified_at < now() - interval '6 hours'` | 같은 사용자에게 6시간 안에 두 번 보내지 않는다 |
| G7 | `notification_settings.rank_change` on | NT-08 |

**순위권 필터 — 상위 30위 또는 상위 30%:**
```
in_band(rank, pc) := rank <= greatest(30, ceil(pc * 0.3))
eligible          := in_band(rank, pc) OR in_band(notified_rank, pc)
```
`notified_rank`도 보는 이유: **밴드 안에 있다가 밖으로 밀려난 순간**이 가장 강한 복귀
동기다. 그 한 건을 놓치면 안 된다.

🔵 하위권을 제외한 근거는 PRD §5.4.1이다. 브론즈 3,000명 중 2,847위 사용자에게
"2,847→2,851위"는 순수 소음이고, 그가 실제로 반응하는 신호는 순위가 아니라
**"앞사람까지 0.8km"** 다 — 그건 NT-05가 담당한다. 두 알림의 역할 분담이 이것이다.

| 알림 | 심리 | 대상 |
|---|---|---|
| NT-04 순위 변동 | **방어** (잃을 것이 있는 사람) | 상위 30위/30% |
| NT-05 주말 격차 | **추격** (한 칸 올릴 수 있는 사람) | 격차 5km 이내 전원 |

**방향별 임계 — 비대칭이다:**

| 방향 | 조건 | 임계 | 근거 |
|---|---|---|---|
| **down (추월당함)** | `rank > notified_rank` | **하락 폭 ≥ 3계단** | RK-05가 지목한 "재방문 유도의 핵심". 손실 회피가 획득보다 강하다 |
| **up (추월함)** | `rank < notified_rank` | **상승 폭 ≥ 5계단** OR **마일스톤 진입**(`rank <= 10 && notified_rank > 10`, `rank <= 3 && notified_rank > 3`, `rank = 1 && notified_rank > 1`) | 상승은 대개 방금 러닝을 끝낸 사용자가 앱 안에서 이미 확인한다. 재방문 가치가 낮으므로 문턱을 높인다 |

**둘 다 보낸다.** 하락만 보내면 알림이 나쁜 소식 전용 채널이 되어 꺼진다. 다만 예산 배분은
하락에 더 준다(아래).

### 3.3 상한 — **키에 순번을 넣어 unique 제약으로 강제**

```
dedupe_key = rank_change:{week_id}:{direction}:{n}
예) rank_change:2026-W35:down:2
```

| 방향 | 주당 최대 n |
|---|---|
| down | **3** |
| up | **2** |
| **합계** | **4** (아래 참조) |

발행 절차 (경합 안전):
```
n := (해당 주·해당 방향의 기존 rank_change 알림 수) + 1
if n > cap(direction) then skip
if (해당 주 rank_change 총 건수) >= 4 then skip
insert ... on conflict (user_id, dedupe_key) do nothing
-- 삽입 성공 여부와 무관하게 notified_rank/notified_at 은 갱신한다
```

⚠️ **`notified_rank` 갱신은 알림 발송 여부와 분리한다.** 상한에 걸려 발송을 건너뛴 뒤에도
기준선을 갱신하지 않으면, 다음 주기에 같은 변동이 계속 조건을 만족해 매시 재시도하고
`notified_at` 간격 게이트(G6)만 남게 된다. 건너뛴 경우에도 갱신해야 조용해진다.

아키텍트 제안(`rank_change:2026-W35:down`, 순번 없음)은 주당 방향별 1건 상한이다. 3건으로
늘린 이유: 하락 알림 1건은 "이미 밀렸다"는 통지로 끝나지만, 주중에 2~3번 오면 **경쟁이
진행 중이라는 감각**을 만든다. 주 4건은 예산(§0) 안에 들어간다.

### 3.4 문구

```
down:
title: "{overtaker_display_name}님에게 추월당했어요"
body : "{tier_ko} {rank}위 · 앞사람까지 {gap_km}km"

up:
title: "{rank}위로 올라섰어요"        // rank=1 이면 "{tier_ko} 1위예요"
body : "{tier_ko} {rank}위(상위 {top_pct}%) · 뒷사람과 {gap_behind_km}km 차"

route: /ranking
payload: { direction, rank, previous_rank, gap_m, participant_count, tier, week_id }
```

- `overtaker_display_name`은 **바로 위(rank+... 아님, 나를 지나쳐 앞선 사람 중 가장 가까운 1명)**
  의 `display_name`. 없거나 비공개면 `"누군가"`로 대체하고, 문구는
  `"순위가 {previous_rank}위 → {rank}위로 내려갔어요"`로 바꾼다.
  ⚠️ PRD AC-05(기록 공개 범위)를 존중해야 한다 — 비공개 사용자의 이름을 알림으로 노출하면
  설정을 우회하는 것이 된다.
- `top_pct` = `ceil(rank / participant_count * 100)` — RK-04 표기와 동일 산식.
- **down 문구에도 격차(`gap_km`)를 반드시 넣는다.** 순위만 알리면 "졌다"로 끝나고,
  격차를 붙여야 "0.8km면 되찾는다"가 된다.

---

## 4. NT-05 — 주말 막판 유도

### 4.1 발송 요일·시각: **토 10:00 KST + 일 18:00 KST (주 2회)**

| 후보 | 채택 | 근거 |
|---|---|---|
| 금 저녁 | ❌ | 주말 러닝 기회가 아직 2일 남아 긴급성이 없다. 3회 발송은 예산 초과 |
| **토 10:00** | ✅ | 주말 첫 러닝 기회 직전. 오전에 나갈 사람에게 이유를 준다 |
| **일 18:00** | ✅ | 주간 마감(일 23:59, PRD §8.5)까지 러닝 1회가 물리적으로 가능한 **마지막 현실 시점**. 20시 이후면 "이제 와서 뭘"이 된다 |
| 일 22:00 | ❌ | 방해 금지 시간이고 행동 불가능 |

### 4.2 문구 기준: **격차 우선 — "10위까지"는 쓰지 않는다**

PRD §5.4.1이 확정한 표기 원칙(RK-04)을 그대로 따른다. PRD 표의 예시 문구
`"10위까지 2.1km"`는 **원칙과 충돌하는 예시**다 — 브론즈 3,000명 중 2,847위 사용자에게
"10위까지"는 2,837계단이라는 도달 불가능한 목표이고, §0-①에 정면으로 위반한다.

**확정 표기: 1차 지표 = 바로 위 사용자와의 격차. 절대 순위·상위 %는 병기.**
```
"앞사람까지 0.8km · 128위(상위 34%)"
```
RK-04가 확정한 포맷과 글자 그대로 같다. 랭킹 화면과 알림의 표기가 다르면 사용자는 둘 중
어느 쪽이 진짜인지 판단할 근거를 잃는다.

⚠️ backend 인계: PRD §5.10 NT-05 행의 예시 문구 `"10위까지 2.1km"`는 **구현하지 않는다.**
§5.4.1(확정 트레이드오프)이 §5.10의 예시보다 나중에 확정된 상위 원칙이다. PRD 본문 수정이
필요하면 오케스트레이터가 사용자 확인을 받아야 한다.

### 4.3 대상 필터 — 3변형

**공통 게이트:** `notification_settings.weekend_push` on / `period='weekly'` /
활동 상태 = 최근 28일 내 러닝 ≥ 1건 (완전 신규·완전 이탈자 제외).

| 변형 | 조건 | 발송 |
|---|---|---|
| **A · 추격** | 이번 주 거리 > 0 AND `rank > 1` AND **`gap_ahead_m <= 5,000`** | 토 + 일 |
| **B · 미러닝** | 이번 주 거리 = 0 | **일요일만** |
| **C · 방어** | `rank = 1` AND **`gap_behind_m <= 5,000`** | **일요일만** |
| — | 위 어디에도 해당 없음 (격차 5km 초과) | **발송 안 함** |

**격차 상한 5,000m의 근거:** 페르소나 1회 러닝 거리가 5~10km(PRD §5.3.2)다. 5km를 넘는
격차는 주말 하루로 뒤집을 수 없고, 그런 사용자에게 "앞사람까지 8.4km"는 추격 신호가
아니라 포기 신호다. **§0-①의 직접 적용이다.**

**B를 일요일만 보내는 이유:** 이번 주 한 번도 안 뛴 사용자에게 토·일 두 번 보내면 잔소리다.
마지막 기회 1회로 족하다.
**C를 일요일만 보내는 이유:** 1위 방어 심리는 마감 임박에서만 작동한다. 토요일 오전의
"2위와 1.2km 차"는 여유로 읽힌다.

### 4.4 문구

```
A · 추격
title: "앞사람까지 {gap_ahead_km}km"
body : "{tier_ko} {rank}위(상위 {top_pct}%) · 오늘 {gap_ahead_km}km면 한 칸 올라가요."

B · 미러닝
title: "이번 주 기록이 아직 없어요"
body : "{tier_ko} 랭킹 마감까지 오늘 하루. 5km면 상위 {projected_top_pct}%예요."

C · 방어
title: "{tier_ko} 1위, 마감까지 {gap_behind_km}km 차"
body : "2위 {chaser_display_name}님이 {gap_behind_km}km 뒤에 있어요."

route: /ranking
payload: { rank, participant_count, remaining_m, gap_m, tier, week_id, variant }
```

- B의 `projected_top_pct` = "이번 주 5km를 뛰었을 때의 예상 순위 백분위". 계산은
  `count(*) filter (where score < 5000) / participant_count`. **미러닝자에게 현재 순위
  (= 사실상 꼴찌)를 보여주면 안 된다** — 보여줄 것은 현재 위치가 아니라 도달 가능한 위치다.
- C의 `chaser_display_name`은 NT-04와 같은 공개 범위 규칙(AC-05)을 적용한다.

### 4.5 dedupe

```
dedupe_key = weekend_push:{week_id}:{sat|sun}
예) weekend_push:2026-W35:sun
```
주당 최대 2건. 변형은 키에 넣지 않는다(§2.3과 같은 이유).

---

## 5. NT-06 — 뱃지 획득 / 레벨업

### 5.1 결정: **(b) 별도 경로.** `user_badges`에 레벨업 합성 행을 만들지 않는다

아키텍트 §9-#3의 (a)안(뱃지 큐에 합성 행 삽입)을 **채택하지 않는다.** 근거 3가지:

**① XP 순환이 생긴다 (치명적).**
`XP_badge`(TRD §3.8.2)는 `user_badges` 행마다 `badge_grade`별 XP를 준다. 레벨업 합성 행이
`user_badges`에 들어가면 **레벨업 → XP 획득 → 레벨업**의 순환이 생긴다. TRD가
`category='level'` 뱃지 9종의 XP를 굳이 0으로 못박은 것이 바로 이 함정을 피하기
위해서였다. 합성 행은 카탈로그 FK가 없어 `badge_grade`도 없으므로 집계 쿼리
(`XP_badge`, 뱃지 개수, 갤러리 GM-03)마다 예외 분기를 심어야 한다. 순환 차단을 위해
새 예외를 3곳에 뿌리는 것보다, 애초에 넣지 않는 것이 옳다.

**② 의미 있는 레벨 마일스톤은 이미 뱃지로 존재한다.**
카탈로그에 `lvl_5 / 10 / 15 / 20 / 25 / 30 / 40 / 50 / 60` 9종이 있고, 이들은 `level_gte`
조건으로 정상 발급되어 **기존 `AchievementCelebrationHost`가 이미 잡는다.** 즉 인앱 축하
풀페이지는 이미 동작하고 있다. 새 경로가 필요한 게 아니다.

**③ 매 레벨 풀페이지 축하는 축하를 죽인다.**
만렙 60이므로 사용자는 생애 59번 레벨업한다. 초반 구간(L1→L5)은 러닝 두세 번이면 지나간다.
59번 풀페이지 애니메이션은 스킵 대상이 되고, 그러면 정말 중요한 뱃지 축하까지 함께
스킵당한다.

**확정 구조:**

| 사건 | 인앱 축하 | 푸시 | 알림함 |
|---|---|---|---|
| 뱃지 획득 | ✅ 기존 `user_badges` 큐 (변경 없음) | ✅ | ✅ |
| **마일스톤 레벨업**(5/10/15/20/25/30/40/50/60) | ✅ `lvl_*` 뱃지가 발급되므로 **기존 큐가 자동 처리** | ✅ (뱃지와 묶임) | ✅ |
| **그 외 레벨업** | ❌ 풀페이지 없음. 러닝 요약 화면의 **XP 바가 레벨 선을 넘어가는 인라인 연출**로 충분 | ✅ | ✅ |

🔵 아키텍트 §4.1의 "소비 지점은 하나"(ARCHITECTURE §7.4.1)가 그대로 유지된다. 레벨업이
축하 큐를 건드리지 않으므로 두 번째 소비 지점이 생기지 않는다.

**flutter-ui-designer 인계:** 일반 레벨업의 인라인 연출은 러닝 요약 화면의 기존 XP
프로그레스 바를 쓴다 — `AppUser.level` 이 저장 전후로 바뀌었으면 바가 100%까지 찬 뒤
0%로 리셋되며 레벨 숫자가 +1 되는 애니메이션. `LevelCurve.levelProgress`가 그대로 쓰인다.
별도 위젯이 필요 없다.

### 5.2 묶음 처리 — **한 러닝 = 성취 푸시 최대 1건**

한 러닝에 뱃지 3개 + 레벨업이 동시에 터지면 푸시 **1건**이다. 4건이 아니다.

| 발생 조합 | 발행 건수 | title |
|---|---|---|
| 뱃지 1개 | 1 | `"{badge_name} 획득!"` |
| 뱃지 N≥2 | 1 | `"뱃지 {N}개를 획득했어요"` |
| 레벨업만 | 1 | `"Lv.{level} 달성"` |
| 뱃지 N + 레벨업 | **1** | `"Lv.{level} 달성 · 뱃지 {N}개 획득"` |

```
dedupe_key = badge_level:run:{run_id}          -- 러닝 저장 유래 (대부분)
             badge_level:weekly:{week_id}      -- 주간 랭킹 확정 유래 (§6)
             badge_level:level:{level}         -- 러닝 없이 레벨만 오른 경우
```

마지막 키가 필요한 이유: `XP_badge`/`XP_tier`는 `user_badges.verified` 변경이나
`tier_change_history` INSERT로도 갱신된다(TRD §3.8.4 트리거 2종). 러닝 없이 레벨이 오를 수
있고, 그때 `run_id`가 없다.

**body / payload:**
```
body : 뱃지 1개  → "{badge_description}"
       뱃지 N≥2 → "{대표 뱃지명} 외 {N-1}개"    // 대표 = 최고 grade, 동급이면 카탈로그 순
       레벨업만 → "누적 {total_xp}XP · 다음 레벨까지 {xp_to_next}XP"
route: /runs/{run_id}  (러닝 유래) / /profile/badges (그 외)
payload: { user_badge_id: "<대표 1개>", badge_count: 3, level: 12, run_id: "..." }
```

⚠️ `user_badge_id`는 **참조용이며 이 값으로 인앱 축하를 띄우지 않는다**(architect §4.1).
푸시를 탭하면 이동만 하고, 큐에 `is_seen = false` 행이 있으면 호스트가 알아서 축하한다.
뱃지 3개면 호스트가 3개를 순차 축하한다 — 푸시가 1건인 것과 무관하며, 이것이 정상이다.
**푸시는 재방문 유도(1건이면 충분), 인앱 축하는 성취 연출(개수만큼)** 이라는 역할 분리다.

### 5.3 NT-01과의 관계

티어 승급은 `badge_level`로 묶지 **않는다.** 별도 `tier_promotion` 1건을 유지한다:
- 토글이 다르다(NT-08은 PRD 표와 1:1)
- 승급은 이 앱의 최상위 사건이며 뱃지 개수 안에 섞이면 묻힌다
- `stier_*` 뱃지도 함께 발급되지만, 그건 `badge_level` 문구에서 **제외**한다
  (같은 사건을 두 번 세지 않는다 — "골드 승급!" + "뱃지 1개 획득(골드 뱃지)"는 중복이다)

**따라서 한 러닝의 최대 성취 푸시 = 2건**(`tier_promotion` + `badge_level`). 그 이상 없다.

### 5.4 방해 금지 시간 예외

NT-01 / NT-02 / NT-06(**트리거 계열**)은 22:00~08:00에도 **보낸다.**
NT-03 / NT-04 / NT-05(**배치 계열**)만 08:00~22:00으로 제한한다.

근거: 트리거 계열은 사용자가 **방금 러닝을 끝낸 순간**이다. 새벽 5시에 뛴 사람에게
"방금 골드로 승급했어요"를 08:00까지 미루면 러닝의 문맥이 사라진 뒤 도착한다. 반면 배치
계열은 사용자의 행동과 무관한 시각에 발화하므로 심야 발송이 순수한 방해다.

---

## 6. RK-06 주간 상위권 뱃지 — **이미 구현되어 있다. 다만 결함 3건 발견**

### 6.1 현황

구현되어 있다. 알림 작업 범위에 새로 넣을 것은 없다.

- 카탈로그 **12종**: `srank_{bronze|silver|gold|platinum}_{top1|top10|top10pct}`
  (`docs/badge-catalog.csv` 121~132행, `supabase/migrations/20260825120100_26_...sql` 157~168행)
- 판정: `condition_type = 'season_weekly_rank_lte'`,
  `supabase/migrations/20260825210000_32_season_badge_condition_logic.sql` 400~418행
- 알림: 이 뱃지도 `user_badges` 행이므로 **NT-06(`badge_level`)으로 자연히 나간다.**
  새 알림 타입 불필요. 단 `dedupe_key`는 `badge_level:weekly:{week_id}`(§5.2)를 쓴다 —
  주간 배치 유래라 `run_id`가 없다.

### 6.2 발견된 결함 — 알림이 아니라 **랭킹/뱃지 버그**다

| # | 결함 | 증상 | 위치 |
|---|---|---|---|
| **1** | **최소 모집단 조건이 판정 SQL에 없다.** TRD §10.2가 `top1은 N≥10`, `top10`/`top10pct`는 `N≥20`으로 규정했으나 마이그레이션 32에는 `participant_count` 검사가 `top10pct`의 백분율 계산에만 쓰이고 게이트가 없다 | **참가자 3명인 티어에서 1위 뱃지가 발급된다.** 뱃지의 희소성이 무너지고, 이 뱃지는 영구 자산(PRD §5.5)이라 회수도 못 한다 | `..._32_...sql:400-418` |
| **2** | **진행 중인 주간을 판정에 포함한다.** 조건이 `period_start >= v_season_start and period_start < v_season_end`뿐이라 **이번 주 진행 중 스냅샷**도 매칭된다 | 화요일 오전 일시적 1위로 "위클리킹" 뱃지가 **확정 발급**되고, 주말에 순위가 밀려도 남는다. 뱃지 회수는 부정행위 한정(PRD §8.1)이라 정상 경로로 되돌릴 수 없다 | 동일 |
| **3** | **주간 확정 후 발급 트리거가 없다.** `evaluate_badges`는 `runs` INSERT에서만 돈다 | 주간 1위를 했는데 **다음 러닝을 할 때까지 뱃지가 안 붙는다.** 다시 안 뛰면 영영 안 붙는다. 그리고 그때는 §2의 결함으로 "그 시점의 진행 중 주간" 기준으로 판정된다 | `..._13_evaluate_badges.sql` 계열 |

**#1·#2 수정안 (backend에 그대로 이식 가능):**
```sql
when 'season_weekly_rank_lte' then
  v_tier_cond := (p_condition ->> 'tier')::public.tier;
  v_bucket    := p_condition ->> 'bucket';
  return exists (
    select 1 from public.leaderboard_entries le
    where le.user_id      = p_user_id
      and le.period       = 'weekly'
      and le.metric       = 'distance'
      and le.scope        = 'global'
      and le.tier         = v_tier_cond
      and le.period_start >= v_season_start
      and le.period_start <  v_season_end
      -- 결함 #2: 확정된 지난 주만. 진행 중인 주는 제외한다.
      and le.period_start <  (select b.period_start
                              from public.leaderboard_period_bounds('weekly', now()) b)
      -- 결함 #1: 최소 모집단 게이트 (TRD §10.2)
      and coalesce(le.participant_count, 0)
            >= case when v_bucket = 'top1' then 10 else 20 end
      and (
        (v_bucket = 'top1'     and le.rank <= 1)
        or (v_bucket = 'top10'    and le.rank <= 10)
        or (v_bucket = 'top10pct' and le.rank
              <= greatest(1, ceil(coalesce(le.participant_count, 1) * 0.1)))
      )
  );
```
(`leaderboard_period_bounds(ranking_period, timestamptz)`는 마이그레이션 03의 기존 함수 —
`returns table (period_start, period_end)`이므로 위와 같이 스칼라 서브쿼리로 꺼낸다.)

**#3 수정안:** 주간 확정 배치(월 00:10 KST — TRD §14-#12가 이미 미구현으로 기록) 안에서
직전 주 `leaderboard_entries`의 `rank <= 10 or rank <= ceil(pc*0.1)` 대상자에 한해
`evaluate_badges(user_id)`를 호출한다. 전 사용자 루프는 불필요하다.

### 6.3 권고: **별도 백로그로 분리. 단 NT-04 배치 작업과 같은 PR에서 처리**

- **범위 분리 근거:** 이건 알림 규칙이 아니라 뱃지 판정 정확성 버그다. 알림 PR에 섞으면
  "알림을 넣었더니 뱃지가 바뀌었다"가 되어 회귀 추적이 불가능해진다.
- **같은 PR을 권하는 근거:** #3의 수정 위치(주간 확정 배치)가 NT-04의 `notified_rank`
  갱신 위치와 같은 함수다. 두 번 나눠 손대면 배치 함수를 두 번 재작성하게 된다.
- **긴급도:** TRD §14-#11이 이미 기록했듯 현재 시드 규모(티어당 1~4명)에서는 **아무도
  이 뱃지를 못 받으므로 실사용 피해가 없다.** 다만 결함 #1 때문에 **베타 사용자가 10명을
  넘는 순간 잘못된 뱃지가 나가기 시작하고, 그 시점부터는 되돌릴 수 없다.**
  → **베타 오픈 전 필수 수정.** 알림 구현과 같은 스프린트 안에 넣을 것.

---

## 7. backend-engineer 인계 요약

### 7.1 서버 재검증 필수 (클라이언트 판정으로 대체 불가)

**이 문서의 모든 조건은 서버가 판정한다.** 클라이언트는 어떤 알림 조건도 계산하지 않는다.
architect 문서 §0이 이미 못박았고, 여기에 게이미피케이션 관점의 근거를 하나 더 붙인다:

NT-02의 `remaining_m`, NT-04의 `rank`, NT-05의 `gap_m`은 전부 **티어·랭킹이라는 이 앱의
화폐**에서 파생된 값이다. 클라이언트가 이 값을 계산하면 조작된 거리로 "곧 승급" 알림을
띄우는 경로가 열리고, 그 알림은 실제 승급으로 이어지지 않아 **서버 확정값과 어긋난 알림**이
된다. PRD §8.4의 서버 재계산 원칙이 알림에도 그대로 적용된다.

특히 NT-02는 **`is_flagged = false` 이고 PRD §8.3 반영 대상인 러닝**에서만 발화해야 한다
(§1.2-#4). 실내·수동 기록으로 "곧 골드예요"를 보내면 티어 반영이 안 되는 기록으로 승급을
약속하는 것이 되고, 승급이 오지 않는 순간 신뢰가 깨진다.

### 7.2 스키마 추가 요청

```sql
-- NT-04. rank_delta(5분 단위 변동)와 역할이 다르다. 둘 다 유지한다.
alter table public.leaderboard_entries
  add column notified_rank integer,
  add column notified_at   timestamptz;

-- NT-02. 임계치를 상수 테이블로 (§1.1)
create function public.tier_proximity_threshold_m(public.tier) returns integer ...;
```

### 7.3 dedupe_key 규약 정본

| 알림 | 키 | 상한 |
|---|---|---|
| NT-01 | `tier_promotion:{season_id}:{tier}` | 시즌 3 |
| NT-02 | `tier_proximity:{season_id}:{next_tier}` | 시즌 3 |
| NT-03 | `season_ending:{season_id}:d{14\|3}` | 시즌 2 |
| NT-04 | `rank_change:{week_id}:{up\|down}:{n}` | 주 down 3 / up 2 / 합계 4 |
| NT-05 | `weekend_push:{week_id}:{sat\|sun}` | 주 2 |
| NT-06 | `badge_level:run:{run_id}` / `badge_level:weekly:{week_id}` / `badge_level:level:{level}` | 러닝 1 |

`week_id`는 ISO 주 표기(`2026-W35`), `season_id`는 `2026-Q3`. **키 안의 모든 경계는 KST**
(PRD §8.5)이며 `leaderboard_entries.period_start`와 같은 기준을 쓴다.

### 7.4 배치 스케줄

| 배치 | 주기 (KST) | 비고 |
|---|---|---|
| NT-03 | 매일 09:00 | `season_end` 까지 D-14/D-3 여부 판정 |
| NT-04 | 매시 정각, 08~22시 | 랭킹 갱신 배치 **직후 체이닝**. `notified_rank` 갱신은 발송 실패·상한 초과 시에도 수행 |
| NT-05 | 토 10:00 / 일 18:00 | 주 2회 고정 |
| RK-06 뱃지 발급(§6.3-#3) | 월 00:10 | 주간 확정 배치 안에서 대상자만 `evaluate_badges` |

---

## 8. flutter-ui-designer 인계 — payload 필드

architect §1.2의 payload 규약에 아래를 추가한다. 전부 **서버가 채우고 클라이언트는 읽기만**.

| 키 | 타입 | 쓰는 알림 | 용도 |
|---|---|---|---|
| `variant` | string | NT-03(`A`/`B`/`C`) · NT-05(`A`/`B`/`C`) | 아이콘·톤 선택. **문구 조립에는 쓰지 않는다** |
| `season_distance_m` | number | NT-03 | 시즌 누적 거리 표시 |
| `previous_rank` | number | NT-04 | "128위 → 131위" 화살표 표시 |
| `participant_count` | number | NT-04 · NT-05 | 상위 % 재계산(RK-04 산식) |
| `gap_m` | number | NT-04 · NT-05 | **격차. 이 앱 랭킹 표기의 1차 지표**(§4.2) |
| `badge_count` | number | NT-06 | "외 2개" 표시 |
| `level` | number | NT-06 | 레벨 배지 |

**알림함 타일 표기도 랭킹 화면과 같은 포맷을 쓴다** — `"앞사람까지 0.8km · 128위(상위 34%)"`.
같은 값이 두 화면에서 다르게 보이면 어느 쪽이 진짜인지 판단할 근거가 없어진다.

일반 레벨업(마일스톤 아님)은 **풀페이지 축하를 띄우지 않는다**(§5.1). 러닝 요약 화면의
XP 프로그레스 바 인라인 연출로 처리한다.

---

## 9. PRD와의 차이 — 오케스트레이터 확인 필요 1건

| 항목 | PRD 기재 | 이 문서의 결정 | 사유 |
|---|---|---|---|
| NT-05 문구 | §5.10 NT-05 행: `"10위까지 2.1km"` | **"앞사람까지 0.8km · 128위(상위 34%)"** | §5.4.1(확정 트레이드오프)·RK-04가 "격차 우선, 절대순위·상위% 병기"를 확정했고, "10위까지"는 다수 사용자에게 도달 불가능한 목표다. §5.10 예시가 §5.4.1 확정 이전 표현으로 남아 있는 것으로 보인다 |

→ PRD §5.10 NT-05 행의 예시 문구를 §5.4.1과 정합하도록 갱신할지 **사용자 확인 필요**
(CLAUDE.md 규칙 4). 확인 전까지는 §5.4.1이 상위 원칙이므로 이 문서의 결정을 따른다.
