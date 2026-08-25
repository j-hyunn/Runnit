# 기기 벤더(Apple Watch / Garmin) 구분 설계 — 확정본

**작성**: gps-tracking-engineer · 2026-08-26
**해결 대상**: `device_source_count_gte`(뱃지 4종) / `device_source_diversity_gte`(뱃지 1종) 판정 불가
**선행 문서**: `_workspace/20260825_193000_backend_badge-evaluation-logic.md` §4, `_workspace/20260825_181914_backend_badge-v2-migration.md` §7.2
**문서 반영**: `docs/TRD.md` §3.1.1(신설) · §3.2 · §8.4.1(신설) · §14 #8·#9, `docs/ARCHITECTURE.md` §6.2

---

## 0. 다른 에이전트가 이 문서에서 가져갈 것 (요약)

| 대상 | 결론 |
|---|---|
| **gamification-designer** | 토큰 목록은 §2가 **최종 확정본**이다: `phone` / `watchApple` / `watchGarmin` / `watchOther` / `unknown`. 매핑 테이블 없음 — 카탈로그 조건값에 쓰는 문자열이 곧 DB 라벨이다. "폰 단독"과 "워치 사용"의 판정식은 §2.3에 SQL로 적어뒀다 |
| **backend-engineer** | §4의 DDL을 그대로 적용. enum `public.device_vendor`(camelCase 라벨), 컬럼 `runs.device_vendors device_vendor[]`, GIN 인덱스, 기존 행 백필 |
| **mobile-architect** | `RunRecord`에 `deviceVendors` 1개 필드 추가, `enums.dart`에 `DeviceVendor` 추가. `RunSample`은 **변경 없음** (§3.2 근거) |
| **qa-integration-tester** | 4계층(카탈로그 jsonb / pg enum / `@JsonValue` / `wire_enums.dart`) 문자열 일치가 이 설계의 단일 실패점이다. `test/tracking/device_vendor_test.dart`의 `뱃지 토큰 정합성` 그룹이 그 고정 장치 |

---

## 1. 문제의 뿌리 — 벤더 정보는 언제 알 수 있는가

지시서가 "실제로 벤더 정보를 어느 시점에 얻을 수 있는지부터 확인하라"고 했으므로 여기서부터 출발한다.

ARCHITECTURE §6.2의 핵심 설계 판단은 **연동 표면을 HealthKit/Health Connect 하나로 수렴**시킨 것이다. Garmin도 Apple Watch도 똑같이 그 저장소를 거쳐 들어온다. 이 수렴에는 대가가 있다 — **경로만으로는 벤더를 알 수 없다.** 이것이 `run_sample_source`에 `watch` 하나밖에 없는 상태의 근본 원인이다.

벤더의 단서는 하나뿐이다. 그리고 **`health` 패키지(11.1.1)의 플랫폼별 구현을 직접 열어 확인한 결과, 두 플랫폼의 필드 의미가 다르다**:

| 플랫폼 | 소스 파일 | `sourceId` | `sourceName` |
|---|---|---|---|
| iOS | `ios/Classes/SwiftHealthPlugin.swift:852` | `sourceRevision.source.bundleIdentifier` | `sourceRevision.source.name` (사용자에게 보이는 이름) |
| Android | `android/.../HealthPlugin.kt:848` | **항상 빈 문자열 `""`** | `metadata.dataOrigin.packageName` |

→ **두 필드를 합쳐 매칭해야 한다.** 기존 코드(`health_wearable_source.dart`의 `sourceFor`)는 `sourceName`만 봤는데, iOS에서는 그게 "지현의 Apple Watch" 같은 표시명이고 Android에서는 패키지명이다. Garmin은 표시명에도 패키지명에도 `garmin`이 들어가서 우연히 양쪽 다 동작했지만, Apple Watch 판별에는 이 비대칭이 그대로 함정이 된다.

**획득 시점** — 세 갈래 모두 **러닝이 끝나기 전 또는 임포트하는 순간**에 확정된다. 사후에 알아내야 하는 정보가 아니다:

| 경로 | 시점 | 벤더 |
|---|---|---|
| 폰 GPS 단독 (P0) | 세션 시작 시점부터 확정 | `phone` |
| 폰 GPS + 워치 심박 폴링 (P1, 이미 구현됨) | 심박 데이터포인트가 **도착하는 즉시** | `sourceId`+`sourceName`으로 판별 |
| 워치 워크아웃 통째 임포트 (P1, WR-01~03) | 임포트 시점 | 워크아웃의 `sourceId`+`sourceName` |

---

## 2. 확정 — 토큰 이름과 값 목록

### 2.1 값 목록 (최종 확정본)

```
phone | watchApple | watchGarmin | watchOther | unknown
```

이 다섯 문자열이 **네 계층에서 문자 그대로 동일**하다:

1. 뱃지 카탈로그 조건값 — `docs/badge-catalog.csv`, `badge_catalog.condition_value` jsonb (마이그레이션 26에 **이미 시드됨**)
2. Postgres enum `public.device_vendor` 라벨
3. Dart `DeviceVendor`의 `@JsonValue`
4. `lib/core/api/wire_enums.dart`의 `DeviceVendorWire.wire`

`watchOther`/`unknown`은 현재 어떤 뱃지도 요구하지 않는다. 알 수 없는 기기를 애플워치·가민 중 하나로 잘못 밀어넣지 않기 위한 값이다.

### 2.2 왜 snake_case 규약을 깨면서까지 camelCase인가

프로젝트 규약은 snake_case다(`enums.dart` 헤더, `outdoor_run`/`all_time` 등). 그런데 **뱃지 카탈로그는 이미 camelCase로 확정·시드돼 있다**:

- `docs/badge-catalog.csv:105` — `{"source": "watchApple", "count": 1}`
- 마이그레이션 26 — 같은 jsonb가 DB에 들어가 있음
- **`device_watchApple_1` 같은 뱃지 id가 PK다** — 마이그레이션 25의 주석(`source 값이 watchApple 이라 id 에 그대로 박혔다`)이 인정하듯, 이름을 바꾸려면 이미 지급된 `user_badges`가 고아가 된다

선택지는 둘이었다:

| 안 | 내용 | 비용 |
|---|---|---|
| A | DB는 `watch_apple`, 평가 함수에 토큰↔라벨 매핑 함수 | 한 개념에 **두 이름**이 생김. 어긋나면 뱃지가 **조용히 미지급**(에러 안 남) |
| B (**채택**) | DB 라벨도 `watchApple`. 매핑 없음 | snake_case 규약 예외 1건. 문서화로 흡수 |

B를 고른 결정적 근거는 이 프로젝트가 이미 문자열 드리프트에 데인 적이 있다는 것이다 — `lib/core/api/wire_enums.dart` 상단의 경고가 그 흔적이다("하나라도 어긋나면 조회가 조용히 빈 결과를 돌려준다"). 카탈로그를 못 바꾸는 이상, **한 개념의 이름 개수를 늘리지 않는 쪽**이 옳다. Postgres enum 라벨에 대소문자가 섞이는 것 자체는 기술적 문제가 없다(항상 문자열 리터럴로 인용된다).

규약 예외는 `lib/models/enums.dart` 헤더와 `DeviceVendor` 주석 양쪽에 사유와 함께 명시해뒀다.

### 2.3 gamification-designer에게 — 판정식

`device_both_used`("올라운더", 조건값 `{"sources": ["phone", "watchApple_or_watchGarmin"]}`)의 설명문은 **"폰 단독 기록과 워치 연동 기록을 각각 최소 1회 이상"**이다. "폰 단독"이 핵심이다 — 배열이므로 두 의미를 구분해 표현할 수 있다:

```sql
-- "폰 단독 기록" — 정확히 일치. 폰+워치 하이브리드 세션은 제외된다.
exists (select 1 from runs r where r.user_id = u and r.device_vendors = '{phone}')

-- "워치 사용 기록" — 겹침. watchApple_or_watchGarmin의 OR가 배열 겹침으로 자연스럽게 떨어진다.
exists (select 1 from runs r where r.user_id = u
        and r.device_vendors && '{watchApple,watchGarmin}'::device_vendor[])

-- device_source_count_gte — "애플워치로 누적 50회"
select count(*) from runs r where r.user_id = u
  and r.device_vendors @> '{watchApple}'::device_vendor[]
```

**여기가 판단이 필요한 지점이다.** 폰 GPS로 뛰면서 애플워치 심박을 같이 받은 세션은 `[phone, watchApple]`이 된다. 이 한 건이 "폰 단독"과 "워치 사용"을 **동시에** 만족시킬지는 OR 파서 규약과 함께 gamification-designer가 정할 문제다. 스칼라 컬럼이었다면 이 선택지 자체가 없었다는 점만 짚어둔다 — **배열은 두 해석을 모두 표현할 수 있다.**

`"watchApple_or_watchGarmin"` 문자열의 **파싱 문법**(구분자 `_or_`, 좌우 토큰 검증 등)은 여전히 gamification-designer 소관이다. 이 문서가 확정한 것은 **좌우에 올 수 있는 토큰의 값 목록**이다.

---

## 3. 설계 결정

### 3.1 소스 축과 벤더 축을 분리한다 (합치지 않는다)

TRD §3.1 초안은 `RunSampleSource { phone, watchApple, watchGarmin, watchOther }`로 **한 축에 두 의미**를 담았다. 구현은 그와 달리 `phone/watch/external`로 갔다 — 실시간성 축을 택하고 벤더를 버린 셈이다. 둘 다 필요하므로 **직교하는 두 축**으로 확정한다:

| 축 | 답하는 질문 | 값 | 저장 위치 |
|---|---|---|---|
| `RunSampleSource` | 어떤 경로로 **언제** 들어왔나 | `phone` / `watch`(실시간) / `external`(사후 동기화) | 샘플 단위 + `runs.sources` |
| `DeviceVendor` | **어느 기기**가 만들었나 | `phone` / `watchApple` / `watchGarmin` / `watchOther` / `unknown` | **러닝 단위** `runs.device_vendors` |

합치지 않는 이유:
- 접으면 `watchGarminLive` × `watchGarminImported` 식으로 값이 곱해진다.
- Garmin은 **항상** 동기화 경유(PRD §5.7 WR-03)라 상관은 높지만 **동치가 아니다** — Apple Watch 워크아웃도 나중에 HealthKit에서 통째로 임포트하면 `external`이 된다.
- 실시간성 축은 이미 UI 계약이 소비 중이다 — `_usesDelayedWearableSync` → "워치 데이터는 동기화 후 반영됩니다" 배너(`tracking_page_test.dart`에 테스트 있음). 벤더로 덮어쓸 수 없다.

### 3.2 벤더는 **러닝 단위 배열**이다 (샘플 단위 아님)

지시서의 후보 (a) `runs.device_vendor` 컬럼 vs (b) 샘플 단위 vendor 키 중 — **(a)의 배열 버전**을 택했다.

**샘플 단위가 아닌 이유**
1. 뱃지 조건이 전부 **러닝 단위 집계**다("애플워치로 누적 50회 완주").
2. 폰 GPS + 워치 심박 세션에서 **좌표는 전부 폰이 만든다.** 샘플마다 벤더를 달면 3600개 샘플에 상수를 복제한다(1시간 러닝 기준). jsonb payload와 로컬 SQLite 양쪽에 그대로 비용이 된다.
3. 현재 집계기가 심박이 실린 샘플의 `source`를 `watch`로 태깅하는 것은 이미 절충이다("좌표는 폰이지만 sources로 남기기 위해" — 코드 주석이 자인). 벤더에서 같은 절충을 반복할 이유가 없다.

**스칼라가 아니라 배열인 이유**
한 세션에 폰(좌표)과 워치(심박)가 **동시에** 기여하는 것이 P1의 기본 경로다. 스칼라 하나로는 그 세션을 폰 기록이라 부를지 워치 기록이라 부를지 손실 없이 표현할 수 없다. 배열이면 §2.3처럼 "정확히 `{phone}`"과 "`watchApple` 포함"을 구분해 물을 수 있다. 기존 `runs.sources`가 이미 같은 패턴이라 스키마·인덱스 전략도 그대로 재사용된다.

**빈 배열의 의미** — `[]`는 `[phone]`과 **다르다**. 수동 입력 기록, 기기 정보가 없는 임포트, 그리고 마이그레이션 이전 레거시 행이 `[]`다. `unknown`은 "외부 기여가 있었으나 식별 실패"라는 다른 상태다.

### 3.3 벤더는 **지표 도착 즉시** 기록한다

집계기에서 `source` 태깅은 다음 GPS fix를 기다린다(심박을 fix에 얹어야 하므로). 벤더는 그러지 않는다 — 워치가 심박을 보낸 직후 터널에 들어가 fix가 끊기면 "워치가 붙어 있었다"는 사실이 통째로 사라지고 **뱃지가 조용히 미지급**된다. `offerWearableMetrics`가 호출되는 순간 `_deviceVendors`에 넣는다. 회귀 테스트 있음(`워치 지표 직후 GPS가 끊겨도 벤더는 남는다`).

---

## 4. backend-engineer에게 — 스키마 제안 (마이그레이션은 작성하지 않았음)

```sql
-- ─────────────────────────────────────────────
-- 기기 벤더. 라벨이 camelCase인 것은 의도적이다 — 뱃지 카탈로그
-- (badge_catalog.condition_value, device_watchApple_1 같은 뱃지 id)가
-- 이미 이 문자열로 시드돼 있고, 별도 매핑을 두면 어긋날 때
-- 뱃지가 조용히 미지급된다. TRD §3.1.1 참조.
-- ─────────────────────────────────────────────
create type public.device_vendor as enum (
  'phone',
  'watchApple',
  'watchGarmin',
  'watchOther',
  'unknown'
);

-- runs.sources(run_sample_source[])와 **직교하는 축**이다. 합치지 말 것.
--   sources        = 어떤 경로로 언제 들어왔나 (phone/watch/external)
--   device_vendors = 어느 기기가 만들었나
alter table public.runs
  add column device_vendors public.device_vendor[] not null default '{}';

-- device_source_count_gte가 사용자별로 `@>` 필터를 돈다.
create index runs_device_vendors_gin
  on public.runs using gin (device_vendors);
```

**백필** — 기존 행은 전부 폰 GPS 기록이다(웨어러블 연동은 P1이고 아직 사용자에게 나가지 않았다). 다만 `[]`(정보 없음)와 `[phone]`(폰 단독 확정)은 의미가 다르므로 무조건 채우지 말고 `sources`를 근거로 판단할 것을 권한다:

```sql
update public.runs
   set device_vendors = '{phone}'::public.device_vendor[]
 where device_vendors = '{}'
   and sources @> '{phone}'::public.run_sample_source[];
```

**클라이언트 payload** — `RunRecord.toJson()`이 `device_vendors` 키를 함께 올린다(`fieldRename: snake`). `LocalRunRepository._serverOwnedKeys`에 넣지 않았으므로 **클라이언트가 쓰는 컬럼**이다. 다만 다른 클라이언트 계산값과 마찬가지로 서버가 신뢰할 필요는 없다 — P1에서 워크아웃 임포트를 서버 경유로 하게 되면 그때 서버가 재확정하면 된다.

**RLS** — `runs`의 기존 정책을 그대로 상속한다. 새 정책 불필요.

---

## 5. 클라이언트 모델 변경 (이미 적용 + 검증 완료)

`flutter analyze` 0건, `flutter test` 전체 통과(신규 테스트 포함 78건).

### 5.1 변경 파일

| 파일 | 변경 |
|---|---|
| `lib/models/enums.dart` | `DeviceVendor` enum(5값) + `DeviceVendorX.isWatch` 추가. 헤더의 snake_case 규약 주석에 예외 1건 명시 |
| `lib/models/run_record.dart` | `@Default(<DeviceVendor>[]) List<DeviceVendor> deviceVendors` 필드 1개 추가 → `device_vendors` |
| `lib/core/api/wire_enums.dart` | `DeviceVendorWire.wire` 추가 (배열 필터·쿼리 계층용) |
| `lib/features/tracking/data/health_wearable_source.dart` | `WearableMetricSample.vendor` 필드 + `vendorFor({sourceId, sourceName, fallback})` 판별 함수 |
| `lib/features/tracking/domain/run_session_aggregator.dart` | `_deviceVendors` 수집, `offerWearableMetrics(vendor:)`, `snapshot()`에서 정렬 방출 |
| `lib/features/tracking/data/geolocator_run_tracking_service.dart` | 벤더를 집계기로 전달 (1줄) |
| `test/tracking/device_vendor_test.dart` | **신규** — 판별 로직 + 4계층 토큰 정합성 고정 |
| `test/tracking/gps_smoothing_test.dart` | `deviceVendors` 그룹 4건 추가 |

### 5.2 `RunSample`은 건드리지 않았다

§3.2의 근거로 샘플 단위 벤더 키를 추가하지 않았다. 나중에 두 기기의 트랙을 병합하는 기능이 생기면 **nullable** `deviceVendor?`를 추가하면 되고, 그때도 기존 데이터와 호환된다.

### 5.3 코드 생성 — 무엇을 재생성해야 하나

**이 워크트리에서 이미 실행했다**: `flutter pub get && dart run build_runner build`

재생성 대상은 `RunRecord` 계열뿐이다:
- `lib/models/run_record.freezed.dart` — 새 필드의 `copyWith`/`==`/`toString`
- `lib/models/run_record.g.dart` — `device_vendors` 직렬화 + `_$DeviceVendorEnumMap`

**생성물은 커밋되지 않는다**(`.gitignore`). 다른 워크트리에서 이 브랜치를 받으면 `dart run build_runner build`를 한 번 돌려야 한다.

**드리프트(로컬 SQLite) 마이그레이션은 불필요하다.** `RunRecordRows`는 `RunRecord` 전체를 `summaryJson` 텍스트로 저장하므로 컬럼이 늘지 않는다. 기존 로컬 행에는 `device_vendors` 키가 없지만 `@Default([])`가 받아낸다 — `schemaVersion` 유지(1).

---

## 6. 남은 한계와 후속 (TRD §14 #8·#9에 등재)

### 6.1 Apple Watch 판별이 **기기 이름 문자열에 의존**한다 — 알려진 한계

HealthKit에서 Apple Watch가 쓴 데이터의 bundleIdentifier는 `com.apple.health.<기기 UUID>`인데, **iPhone이 쓴 데이터도 같은 형태**다. 번들 id만으로는 구분되지 않아 기기명에 `watch`가 들어가는지까지 본다.

- 기본 기기 이름("○○의 Apple Watch")에는 들어간다 → 정상 동작
- 사용자가 워치 이름을 "내시계"로 바꾸면 → 판별 실패, `watchOther`로 저하

**실패 방향이 안전하다** — 애플워치 뱃지가 **안 붙을 뿐 폰 기록에 잘못 붙지는 않는다**. 두 방향 모두 테스트로 고정해뒀다.

정확한 판별에는 iOS `HKDevice.manufacturer`/`model`("Apple Inc." / "Watch")과 Health Connect `Metadata.device`가 필요한데 **`health` 패키지가 노출하지 않는다.** 얇은 platform channel을 새로 파야 하므로, P1 실기기 테스트에서 오분류가 **실제로 관측되면** 착수한다. 지금 선제적으로 만들 근거는 없다.

### 6.2 P1 워크아웃 임포트 경로는 아직 없다

현재 벤더가 채워지는 경로는 (1) 폰 단독 → `[phone]`, (2) 러닝 중 심박 폴링 → 판별값 추가, 두 갈래다. WR-01~03의 **워크아웃 통째 임포트**는 아직 구현 전이며, 그 경로가 생기면 임포트 시점에 같은 `vendorFor`를 호출해 `deviceVendors`를 채우면 된다 — 판별 함수는 임포트 경로에서 재사용 가능하도록 순수 static으로 뒀다.

즉 **`device_watchApple_*` / `device_watchGarmin_*` 뱃지 4종이 실제로 지급되기 시작하는 시점은 P1 웨어러블 연동 이후**다. 스키마와 판정 로직은 그 전에 준비돼 있어도 무방하며(이 문서가 그 준비다), 그때까지는 조건이 정상적으로 false를 반환한다 — 이제는 "판정 불가 스텁"이 아니라 "원천 데이터가 아직 비어 있어서 false"라는 정상 상태다.

### 6.3 `watchOther` 힌트 목록은 불완전해도 된다

Samsung/Google Fit/Polar/Coros/Suunto/Fitbit 등을 부분 문자열로 잡는다. 현재 어떤 뱃지도 `watchOther`를 요구하지 않으므로 **이 목록이 새도 뱃지 판정은 틀리지 않는다** — 통계·UI 표기용이다.
