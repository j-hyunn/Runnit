# 기기 벤더 모델 중재 — 최종 결정 (정본)

**작성**: mobile-architect · 2026-08-26
**결정 권한**: 데이터 모델 소유자로서의 최종 결정. 이 문서가 기기 벤더 표현의 **단일 진실 원천**이다.
**중재 대상**: 병렬 워크트리에서 나온 상충 설계 2건
- 안 A — `_workspace/20260826_000822_gps_device-vendor-design.md` (gps-tracking-engineer, 코드 병합 완료)
- 안 B — `_workspace/20260826_000340_gamification_badge-backlog-decisions.md` §4 (gamification-designer, 문서만)

**문서 반영**: `docs/TRD.md` §3.1 · §3.1.1 · **§3.1.2(신설)** · §4.0(신설) · §4.1 · §10.2 · §14, `docs/badge-catalog.csv`

---

## 0. 결정 요약

| 항목 | 결정 |
|---|---|
| **구조** | **안 A 채택** — 러닝 단위 **배열** `runs.device_vendors public.device_vendor[]` |
| **폐기** | 안 B의 스칼라 컬럼 `runs.device_source` — 생성하지 않는다 |
| **흡수** | 안 B의 **OR 표현식 문법(`_or_`)**과 **판정 대상 세션 규칙**(`completed AND NOT is_flagged`)은 그대로 채택 |
| **토큰** | **5종** `phone` / `watchApple` / `watchGarmin` / `watchOther` / `unknown` (안 A). 안 B의 `watchWearOS`·`external`·`manual` 불채택 |
| **매칭** | 단일 규칙 — **배열 겹침** `device_vendors && ARRAY[tokens(expr)]` |
| **카탈로그** | `device_both_used` **설명문만** 수정("단독" 제거). id·name·`condition_value`는 **불변** |
| **코드 변경** | **없음.** 안 A가 이미 코드에 반영돼 있고 그대로 정본이다 |

`flutter analyze` 0건 · `flutter test` 80건 전부 통과 · `build_runner` 재생성 완료.

---

## 1. 결정 근거 — 카탈로그가 실제로 요구하는 것

두 안 중 어느 쪽이 옳은지는 취향이 아니라 **카탈로그 조건이 요구하는 판정 시맨틱**으로 갈렸다. 실제 5개 행을 대조했다.

### 1.1 결정적 근거 — 스칼라는 P1 기본 경로에서 뱃지를 깨뜨린다

P1의 **가장 흔한** 러닝 형태는 "폰 GPS로 좌표 + 애플워치로 심박"인 **하이브리드 세션**이다(안 A §3.2, ARCHITECTURE §6.2). 이 세션을 스칼라 하나로 표현하려면 **주 기기 하나를 골라 나머지를 버려야** 한다. 그러면 `device_both_used`(올라운더)가 이렇게 깨진다.

| 스칼라가 하이브리드를 뭐라고 부르는가 | 폰+워치만 쓰는 사용자에게 벌어지는 일 |
|---|---|
| `phone`으로 기록 | 모든 러닝이 `phone`. `watchApple` 세션이 영원히 0건 → **올라운더·애플워치런·애플워치러너 4종 전부 미지급** |
| `watchApple`으로 기록 | 모든 러닝이 `watchApple`. `phone` 세션이 0건 → **올라운더 미지급** |

어느 쪽을 골라도 뱃지가 조용히 안 나온다. **표현 불가능한 상태를 스키마가 강요하는 것**이므로, 판정 로직을 아무리 잘 짜도 복구되지 않는다.

배열은 같은 세션을 `{phone, watchApple}`로 손실 없이 적고, 두 조건 모두 정상적으로 매칭한다.

### 1.2 안 B의 반론("배열은 집계가 모호하다")은 유효하지 않다

안 B의 근거는 *"한 러닝이 phone·watchApple 샘플을 모두 가질 때 '애플워치로 뛴 50회' 집계가 모호해진다 — 같은 세션이 여러 카운트 뱃지에 동시에 잡힌다"* 였다. 두 가지 이유로 기각한다.

1. **모호함이 아니라 미정의였다.** 규칙을 하나 정하면 사라진다 — §2의 겹침 규칙. 모호성은 모델의 결함이 아니라 스펙의 공백이었다.
2. **"여러 뱃지에 동시에 잡히는 것"은 이 시스템의 정상 동작이다.** 10km 러닝 한 건은 이미 `첫 10K`·`누적 거리`·`단일 세션 거리`·시간대 뱃지에 동시에 기여한다. 뱃지 간 배타성은 카탈로그 어디에도 없는 요구다. 반면 §1.1의 정보 손실은 **복구 불가능한 실제 오작동**이다.

카탈로그 문구도 겹침 해석과 일치한다 — `device_watchApple_50`은 "애플워치로 **기록한** 러닝이 누적 50회"다. 심박을 애플워치로 받은 러닝은 애플워치로 기록한 러닝이 맞다.

### 1.3 안 B에서 가져온 것

배열/스칼라 논쟁과 **무관하게 유효한** 산출물이고, 안 A가 명시적으로 gamification-designer 소관으로 남겨둔 공백을 정확히 메운다. 그대로 채택했다.

- **`_or_` 표현식 문법** (구분자·검증 정규식·미지 토큰 시 로그 남기고 false·괄호/AND 없음)
- **판정 대상 세션**: `status = 'completed' AND NOT is_flagged`
- **원소 간 AND / 원소 내부 OR** 구조

배열에서는 OR가 **배열 겹침으로 그대로 떨어진다** — 표현식마다 다른 연산자를 쓸 필요가 없다.

### 1.4 절충안을 만들지 않은 이유

"배열 유지 + 대표 벤더 스칼라를 파생 컬럼/뷰로 추가"를 검토했으나 **채택하지 않았다.** 파생 스칼라를 소비할 판정이 하나도 없다(§2의 규칙이 배열만으로 5개 행을 전부 커버한다). 소비자 없는 두 번째 표현은 한 개념에 이름을 둘 늘리고, 이 프로젝트가 이미 데인 **문자열 드리프트**(`wire_enums.dart` 상단 경고)의 표면을 넓힐 뿐이다.

---

## 2. 정본 스키마 — backend-engineer 적용 대상

### 2.1 DDL (그대로 마이그레이션에 넣으면 된다)

```sql
-- ─────────────────────────────────────────────
-- 라벨이 camelCase인 것은 의도적이다. badge_catalog.condition_value 와
-- device_watchApple_1 같은 뱃지 id(PK)가 이미 이 문자열로 시드돼 있고,
-- 별도 매핑을 두면 어긋날 때 뱃지가 조용히 미지급된다. TRD §3.1.1.
-- ─────────────────────────────────────────────
create type public.device_vendor as enum (
  'phone', 'watchApple', 'watchGarmin', 'watchOther', 'unknown'
);

-- runs.sources(run_sample_source[])와 **직교하는 축**이다. 합치지 말 것.
--   sources        = 어떤 경로로 언제 들어왔나 (phone/watch/external)
--   device_vendors = 어느 기기가 만들었나
alter table public.runs
  add column device_vendors public.device_vendor[] not null default '{}';

comment on column public.runs.device_vendors is
  '이 세션에 기여한 기기 벤더 집합. {} 는 {phone} 과 다른 뜻(정보 없음/수동 입력). TRD §3.1.1';

create index runs_device_vendors_gin on public.runs using gin (device_vendors);

-- 백필: {}(정보 없음)과 {phone}(폰 단독 확정)은 의미가 다르므로
-- 무조건 채우지 말고 sources 를 근거로만 채운다.
update public.runs
   set device_vendors = '{phone}'::public.device_vendor[]
 where device_vendors = '{}'
   and sources @> '{phone}'::public.run_sample_source[];
```

- **RLS**: `runs`의 기존 정책 상속. 새 정책 불필요.
- **쓰기 주체**: 클라이언트(`RunRecord.toJson()` → `device_vendors`). `_serverOwnedKeys` 아님. P1에서 워크아웃 임포트가 서버 경유로 바뀌면 그때 서버가 재확정.
- **`{}` vs `{phone}`**: 다른 뜻이다. `{}` = 수동 입력·기기 정보 없는 임포트·레거시. `unknown` = 외부 기여는 있었으나 식별 실패.

### 2.2 판정 규칙 (`evaluate_badge_condition`의 두 스텁 교체)

현재 세 마이그레이션(27 / 32 / 33)에 `raise notice … 보류` 스텁이 남아 있다. 아래로 대체한다.

**표현식 파싱**
```
expr  := token ( "_or_" token )*
token := 위 5개 enum 라벨 중 하나 (exact match, 대소문자 구분)
검증 정규식: ^[a-z][A-Za-z0-9]*(_or_[a-z][A-Za-z0-9]*)*$
미지 토큰 → 파싱 오류. 해당 뱃지는 false, 그리고 로그를 남긴다(조용히 무시 금지).
괄호·중첩·AND 연산자·공백은 문법에 없다.
```

**매칭 (단일 규칙, 두 condition_type 공통)**
```sql
run.device_vendors && ARRAY[tokens(expr)]::public.device_vendor[]
```

**대상 세션 (공통)**: `status = 'completed' AND NOT is_flagged`

**`device_source_count_gte`** — `{"source": "<expr>", "count": N}`
```sql
select count(*) >= N
  from public.runs r
 where r.user_id = p_user_id
   and r.status = 'completed' and not r.is_flagged
   and r.device_vendors && ARRAY[…tokens…]::public.device_vendor[]
```

**`device_source_diversity_gte`** — `{"sources": ["<expr1>", …]}`
모든 원소에 대해 위 매칭 세션이 **1건 이상**(원소 간 AND).
```sql
-- device_both_used = {"sources": ["phone", "watchApple_or_watchGarmin"]}
exists (select 1 from public.runs r where r.user_id = p_user_id
          and r.status='completed' and not r.is_flagged
          and r.device_vendors && '{phone}'::public.device_vendor[])
and
exists (select 1 from public.runs r where r.user_id = p_user_id
          and r.status='completed' and not r.is_flagged
          and r.device_vendors && '{watchApple,watchGarmin}'::public.device_vendor[])
```

⚠️ **"서로 다른 세션" 제약은 두지 않는다.** 하이브리드 세션 1건(`{phone, watchApple}`)이 두 원소를 동시에 충족하면 올라운더가 지급된다. 상세 근거는 §3.

### 2.3 카탈로그 설명문 1행 수정 (미적용 — backend 작업)

`docs/badge-catalog.csv`는 이 커밋에서 수정했다. **이미 적용된 마이그레이션 26은 수정하지 않았으므로**, 벤더 마이그레이션과 함께 `badge_catalog.description`을 갱신하는 UPDATE를 넣을 것.

```sql
update public.badge_catalog
   set description = '폰으로 기록한 러닝과 워치로 기록한 러닝을 각각 최소 1회 이상 보유하면 획득 (한 러닝이 둘 다 만족해도 인정)'
 where id = 'device_both_used';
```

id / name / `condition_value` / `condition_type`은 **전부 불변**이다. 지급된 `user_badges`에 영향 없음.

---

## 3. `device_both_used`("올라운더") 시맨틱 — 명시적 결정

카탈로그의 긴 설명문은 원래 "폰 **단독** 기록과 워치 연동 기록을 각각 최소 1회"였다. 이 "단독"을 제거했다.

**사유**
1. 그 문장은 **스칼라 모델의 한계를 옮겨 적은 것**이지 독립적인 제품 요구가 아니었다. 스칼라에서는 `device_source='phone'`이 필연적으로 "폰만"을 뜻하므로 "단독"이라고 쓸 수밖에 없었다.
2. 뱃지의 **짧은 설명은 원래부터 "폰 + 워치 모두 사용"**이고, 하이브리드 세션은 이 문장을 그대로 만족한다. 이름도 "올라운더"다.
3. "단독"을 문자 그대로 구현하려면 `= '{phone}'`(정확히 일치) 같은 **두 번째 매칭 시맨틱**이 필요하다. 같은 토큰 `phone`이 `device_source_count_gte`에서는 겹침, `device_source_diversity_gte`에서는 정확히 일치를 뜻하게 되고, 이건 정확히 이 프로젝트가 피하려는 종류의 드리프트다.
4. **제품으로도 나쁘다** — 올라운더를 받으려고 워치를 두고 나가야 하는 규칙이 된다.

대안으로 "원소마다 서로 다른 세션" 제약도 검토했으나 기각했다. 하이브리드 세션 2건이면 서로 다른 세션으로 두 원소를 채워 어차피 지급되므로 **"폰 단독"을 재현하지도 못하면서** 원소↔세션 매칭 로직만 늘린다.

**영향**: 하이브리드 세션을 처음 기록하는 순간 `device_watchApple_1`과 `device_both_used`가 동시에 지급될 수 있다. 의도된 동작이다.

---

## 4. 확정된 4계층 문자열 (한 글자도 달라지면 안 됨)

| 계층 | 위치 | 상태 |
|---|---|---|
| 뱃지 카탈로그 조건값 | `docs/badge-catalog.csv`, `badge_catalog.condition_value` jsonb (마이그레이션 26에 시드됨) | ✅ 기존값 유지 |
| Postgres enum 라벨 | `public.device_vendor` | ⏳ **backend 미적용** (§2.1) |
| Dart `@JsonValue` | `lib/models/enums.dart` `DeviceVendor` | ✅ 반영됨 |
| 쿼리 계층 | `lib/core/api/wire_enums.dart` `DeviceVendorWire.wire` | ✅ 반영됨 |

`test/tracking/device_vendor_test.dart`의 `뱃지 토큰 정합성` 그룹이 값 목록을 리터럴로 고정한다. 토큰을 바꾸려는 시도는 이 테스트에서 먼저 깨진다.

**snake_case 규약의 유일한 예외**임을 `lib/models/enums.dart` 헤더·`DeviceVendor` 주석·TRD §3.1.1·§4.1에 모두 명시해뒀다.

---

## 5. 불채택 토큰 3종과 사유

| 토큰 | 제안 | 불채택 사유 |
|---|---|---|
| `watchWearOS` | 안 B | 요구하는 뱃지가 없고, Health Connect 패키지명만으로 "Wear OS 워치"와 "그 외 안드로이드 웨어러블"을 신뢰성 있게 가를 수 없다(TRD §8.4.1). 판별 불가능한 값을 enum에 두면 실제로는 전부 `watchOther`로 떨어지면서 스키마만 커진다 |
| `external` | 안 B | **소스 축의 값이다**(`RunSampleSource.external` = 사후 동기화 경로). 벤더 enum에 넣으면 §3.1.1이 방금 분리한 두 축이 다시 섞인다 |
| `manual` | 안 B | 수동 입력은 기여 기기가 **없는** 상태이고 `device_vendors = '{}'`로 이미 표현된다. 활동 유형은 `RunRecordType.manual`이 따로 들고 있어 세 번째 이름이 된다 |

Strava 등 외부 앱 임포트의 벤더가 필요해지면 그때 **벤더 축에** 값을 추가한다(`external`이 아니라). 지금은 `unknown`이 받아낸다.

---

## 6. 팀별 액션

| 담당 | 할 일 | 차단 여부 |
|---|---|---|
| **backend-engineer** | §2.1 DDL 마이그레이션 + §2.2로 3개 마이그레이션(27/32/33)의 `device_source_*` 스텁 교체 + §2.3 설명문 UPDATE | 이 문서만으로 착수 가능 |
| **gamification-designer** | §4 스칼라 전제 폐기 확인. `_or_` 문법과 대상 세션 규칙은 **채택됐다** | 없음 |
| **gps-tracking-engineer** | 클라이언트 변경 없음. 단 §2.3 안 §2.2의 겹침 규칙 확인 — 원 문서 §2.3의 `= '{phone}'`(정확히 일치) SQL은 폐기됐다 | 없음 |
| **qa-integration-tester** | 마이그레이션 적용 후 4계층 문자열 일치 + 하이브리드 세션의 3뱃지 동시 지급 회귀 확인 | backend 대기 |

**뱃지 5종이 실제로 지급되기 시작하는 시점은 P1 웨어러블 연동 이후**다. 그전까지 조건은 판정 오류가 아니라 정상적으로 `false`를 돌려준다.
