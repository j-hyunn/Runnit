> ⚠️ **2026-09-01 이 설계는 이번 라운드에서 채택되지 않았다.** 사용자가 실내 러닝 관련 전체(측정 방식·XP·스트릭·전용 뱃지·웨어러블 실내 거리)를 **Phase 4 웨어러블 연동 라운드로 일괄 연기**하기로 확정. 이 문서에 반영했던 PRD v1.8 / TRD §3.8.2·§10.2·§14 / ARCHITECTURE 초안은 되돌렸다. 대신 PRD §10.2 #14, TRD §14 #26에 연기 항목으로 기록. 아래 설계안은 웨어러블 라운드 착수 시 출발점으로 참고.

# A-6 · C-5/C-6 처리 설계 — 실내 러닝을 시간 기반으로 (보류)

| 항목 | 내용 |
|---|---|
| 작성 | 2026-09-01, mobile-architect |
| 사용자 방향 | **C-6**: 실내 러닝은 거리가 아니라 **시간으로 측정** / **C-5**: `hasRouteSamples` 도입은 **P1 웨어러블 라운드로 연기**, 지금은 문서 명시만 |
| 근거 문서 | PRD §5.1(TR-10) · §5.7 · §8.3, ARCHITECTURE §4 · §6.3, TRD §3 · §3.8.2 · §10.2 · §14, `_workspace/20260901_gps_field-accuracy-verification.md` §8.2 |
| 상태 | **설계 초안 + 문서/모델 반영본.** 커밋하지 않았다 — 오케스트레이터가 사용자 확정 후 커밋 |

---

## 0. 착수 전에 확인된 사실 (설계 전제를 바꾼 것)

코드를 읽고 나서 C-6의 문제 규모가 **보고서보다 크다**는 것이 확인됐다.

| 사실 | 확인 위치 | 함의 |
|---|---|---|
| 실내 러닝은 GPS 스트림을 열지 않는다 | `geolocator_run_tracking_service.dart:149` | 거리 0 (보고서 그대로) |
| **`movingSeconds`도 0이다** | `run_session_aggregator.dart:91` — `_filter.movingSeconds`는 GPS fix에서만 누적된다. fix가 0개면 0 | 🔴 **시간조차 기록되지 않는다.** 실내 기록에서 0이 아닌 것은 `elapsedSeconds`(벽시계) 하나뿐 |
| 실내 XP는 **20점이 아니라 0점**이다 | 마이그레이션 39, `compute_run_xp` — `distance < 500` 조기 반환이 실내 분기보다 **먼저** 있다 | 과제 지시문의 "거리 0이면 항상 20점"은 실제로는 0점 |
| 실내 칼로리도 0이다 | `_kcalForSegment`는 GPS 세그먼트마다 호출된다 | 세그먼트가 없으므로 미적립 |
| 실내만 뛴 주는 스트릭이 끊긴다 | 마이그레이션 39 `_weekly_streak_state` — `having sum(distance_meters) >= 1000` | 같은 함수 주석은 "실내·수동을 **포함한다**"고 선언 — **선언과 동작이 어긋나 있다** |
| **"전용 실내 뱃지"가 카탈로그에 0종이다** | `docs/badge-catalog.csv` grep 0건 | PRD §8.3의 "전용 실내 뱃지 ✅ 지급" 약속이 미이행 상태 |

➡️ 즉 현재 실내 러닝은 **거리 0 · 시간 0 · XP 0 · 칼로리 0 · 스트릭 미인정 · 전용 뱃지 0종**으로, PRD §8.3이 약속한 "저장·통계·전용 뱃지"가 사실상 `elapsed_seconds` 한 칸으로만 성립한다. 시간 기반 전환은 "지표 축 변경"이 아니라 **미구현 기능의 완성**에 가깝다.

---

## 1. 실내 러닝 = 시간 기반 데이터 모델

### 1.1 `distanceMeters` — 권장안: **non-null 0 유지 + 사용자 입력 경로를 열지 않는다**

세 안을 검토했다.

| 안 | 내용 | 판정 |
|---|---|---|
| A | `distanceMeters` non-null 0 유지, 입력 경로 없음 | ✅ **채택** |
| B | `distanceMeters` nullable화 | ❌ 기각 |
| C | 사용자가 트레드밀 콘솔 거리를 선택 입력 → `distanceMeters`에 저장 | ❌ **강하게 기각** |

**B(nullable)를 기각한 이유** — 표현하려는 정보가 이미 다른 필드에서 파생 가능하다. "거리를 측정하지 않았다"는 `activityType == indoorRun`과 완전히 동치이고, 그 사실 하나를 표현하려고 `runs.distance_meters not null default 0`을 nullable로 바꾸면 **서버 집계 39개 지점**(`sum(r.distance_meters)`, 티어·랭킹·뱃지·시즌 스냅샷)과 클라이언트 파생값(`distanceKm`, `avgSpeedMps`, 포맷터) 전부가 null 분기를 지게 된다. 얻는 것은 표시 계층의 편의 하나뿐이고, 그 편의는 `isDistanceMeasured` 게터로 비용 없이 얻어진다. **타입에서 파생되는 사실을 위해 스키마를 nullable로 만들지 않는다.**

**C(사용자 입력 거리를 `distanceMeters`에 저장)를 기각한 이유** — 이것이 이번 설계에서 가장 중요한 판단이다.

`runs.distance_meters`는 티어 누적·주간 랭킹·시즌 스냅샷·거리 조건 뱃지 **전부가 합산하는 단일 컬럼**이다. 검증 불가능한 자가 신고 숫자가 이 컬럼에 들어가면, 그것이 티어를 오염시키지 않도록 막는 것은 **집계 지점마다 반복되는 `activity_type <> 'indoor_run'` 필터 한 줄**뿐이다. 그리고 그 필터는 **실제로 빠진 전례가 있다** — 마이그레이션 23이 "트레드밀 기록이 주간 랭킹 점수에 합산되고 있었다"를 사후 수정했다. 앞으로도 새 집계·새 뱃지 조건이 추가될 때마다 같은 한 줄을 잊으면 안 되는 구조다.

거리를 **애초에 받지 않으면 이 실패 양상이 존재할 수 없다.** §8.3의 "티어·랭킹 미반영"이 필터 39개의 성실함이 아니라 **데이터의 부재**로 보장된다. 이것이 시간 기반 전환의 진짜 이득이다.

> 콘솔 거리를 표시용으로 남기고 싶다는 요구가 나오면, **`reported_distance_meters numeric null` 별도 컬럼**으로 P1에 검토한다. 어떤 판정에도 참여하지 않고 상세 화면에 "자가 입력" 라벨과 함께만 노출한다. 지금은 만들지 않는다 — 소비처 없는 컬럼을 미리 만들면 나중에 누군가 "이왕 있으니" 집계에 넣는다.

### 1.2 `movingSeconds` — 실내의 1급 지표, **벽시계에서 일시정지를 뺀 값**

실내는 GPS 상태기계가 없으므로 이동/정지를 판별할 수단이 없다. 따라서:

```
indoor movingSeconds = (now − startedAt) − 누적 일시정지 시간
```

`RunSessionAggregator`가 `activityType == indoorRun`일 때 이 경로를 쓴다. 구현 스케치(**gps-tracking-engineer 담당**):

```dart
// 일시정지 구간을 누적하는 벽시계 타이머. 실내에서만 movingSeconds의 소스가 된다.
DateTime? _pausedAt;
Duration _pausedTotal = Duration.zero;

void pause()  { if (_pausedAt == null) _pausedAt = DateTime.now().toUtc(); /* 기존 로직 */ }
void resume() { final p = _pausedAt; if (p != null) { _pausedTotal += DateTime.now().toUtc().difference(p); _pausedAt = null; } /* 기존 로직 */ }

int _indoorMovingSeconds(DateTime now) {
  final paused = _pausedTotal + (_pausedAt == null ? Duration.zero : now.difference(_pausedAt!));
  return math.max(0, now.toUtc().difference(startedAt).inSeconds - paused.inSeconds);
}

// snapshot() 안에서
final moving = activityType == ActivityType.indoorRun
    ? _indoorMovingSeconds(now)
    : movingSeconds;
```

⚠️ 기존 `movingSeconds: math.min(moving, elapsed)` 클램프는 그대로 유지한다 — 서버 `validate_run`의 `moving_exceeds_elapsed` 플래그를 유발하지 않기 위해서다. 정의상 실내 moving ≤ elapsed이므로 클램프가 걸릴 일은 없고, 시계 되감김에 대한 방어로 남는다.

⚠️ **TR-03 자동 일시정지는 실내에 적용되지 않는다.** 실내는 "정지"를 감지할 센서가 없다. 사용자가 명시적으로 누른 일시정지만 반영된다 — UI가 이를 알릴 필요가 있는지는 flutter-ui-designer 판단 항목.

### 1.3 페이스 · 랩 · 칼로리

| 지표 | 실내 처리 | 근거 |
|---|---|---|
| **페이스** | `avgPaceSecPerKm` = **null**, 화면은 `—` | 거리가 없으면 분모가 없다. 현행 `TrackingFormat.paceOf`가 이미 `distanceMeters <= 0`에서 `emptyPace`를 반환하므로 **코드 변경 불필요** |
| **1km 랩** | **미표시** | 랩은 거리 경계 개념이다. "10분 스플릿"으로 대체하고 싶어지지만, 실내 세션은 페이스 변화를 알 수 없어 모든 스플릿이 동일한 무의미한 표가 된다. 표시하지 않는 것이 정직하다 |
| **경로 지도** | 미표시 (현행 유지) | `TrackingFormat.hasRoute` / `run_detail_page.dart:323` 문구가 이미 처리 |
| **칼로리** | **고정 MET 8.0 × 시간 추정** | 아래 |

**칼로리 — 고정 MET 8.0 채택, 강도 선택 UI는 두지 않는다**

```
kcal = 8.0 (MET) × 3.5 × 체중(kg) / 200 × (movingSeconds / 60)
```

- **왜 ACSM 대사 방정식이 아닌가**: ACSM 러닝 공식(`VO2 = 0.2 × 속도 + 3.5`)의 입력은 **속도**이고, 실내에는 속도가 없다. 공식을 쓸 수 없다.
- **왜 8.0인가**: ACSM Compendium 기준 트레드밀 러닝 8km/h ≈ 8.3 MET, 조깅 일반 ≈ 7.0. 8.0은 "가벼운 러닝"의 중앙값이고, 체중 65kg 기준 시간당 약 546kcal로 실제 감각과 어긋나지 않는다.
- **왜 강도 선택 UI를 두지 않는가**: ① 러닝 시작 전 입력이 하나 늘면 시작 마찰이 커진다(트레드밀 러닝은 즉흥적으로 시작한다), ② 칼로리는 **티어·랭킹·XP·뱃지 어디에도 입력으로 쓰이지 않는다**(전 카탈로그 146종에 kcal 조건 0건, 마이그레이션 grep 확인) — 정확도를 높여도 판정이 달라지지 않는 순수 표시값이다, ③ 실외 칼로리도 체중 미입력 시 65kg 가정으로 추정 중이라 이미 같은 성격의 값이다.
- **P1 옵션(지금은 안 함)**: 요구가 나오면 요약 화면에서 사후에 강도 3단계(걷기 3.5 / 조깅 7.0 / 빠른 러닝 9.8)를 고르게 하는 방식이 낫다 — 시작 전이 아니라 끝난 뒤에 물으면 마찰이 없다.

### 1.4 히스토리 · 통계 화면에서의 노출

| 화면 | 실내 기록 처리 |
|---|---|
| **히스토리 목록 카드** | 거리 대신 **시간을 큰 글씨로**. `isTimeBased`로 분기. 뱃지형 "실내" 라벨 |
| **기록 상세** | 요약 그리드에서 거리·페이스 타일을 **제거**(0.00km / — 를 그리지 않는다). 시간·칼로리·심박만. 지도 자리는 현행 안내 문구 유지 |
| **월간 차트(거리)** | 실내는 0이므로 **자연히 기여하지 않는다** — 별도 필터 불필요 |
| **프로필 누적 거리** (`total_distance_meters`) | 실내가 0이므로 자연히 미반영 |
| **프로필 누적 시간·횟수** (`total_moving_seconds`, `total_run_count`) | ✅ **반영** — 여기가 실내 기록이 실제로 살아있는 자리다 |

**§8.3 "누적 통계 반영"과 모순되는가 — 아니다.** §8.3이 "누적 통계 반영"이라고 쓴 것은 "기록이 어딘가에는 남는다"는 약속이지 "거리 통계에 실내 거리를 더한다"는 뜻이 아니다. 시간 기반 전환 후에는 **실내가 시간·횟수 통계에 기여하고 거리 통계에는 기여하지 않는다** — 거리를 측정하지 않았으니 거리 통계에 없는 것이 맞다. 실내를 거리 통계에서 "빼는" 별도 로직은 필요 없고, 넣을 값이 애초에 없다.

⚠️ **`total_moving_seconds`가 실내 시간을 실제로 받으려면 §1.2 구현이 선행**돼야 한다. 지금은 실내 `moving_seconds`가 0이라 누적 시간 통계에도 0을 더하고 있다.

### 1.5 모델 파일 변경 (적용 완료)

**필드 추가·삭제 없음.** 실내 시간 기반은 기존 필드(`movingSeconds`)의 의미를 확정하는 문제이지 새 필드를 요구하지 않는다. 변경은 **주석 + 파생 게터 2개**뿐이다.

| 파일 | 변경 |
|---|---|
| `lib/models/enums.dart` | `ActivityType.indoorRun` 주석 확정 — "거리를 측정하지 않는다, 1급 지표는 시간", 사용자 입력 거리를 `distanceMeters`에 넣지 않는 이유 |
| `lib/models/run_record.dart` | `distanceMeters` 주석(실내 항상 0, nullable화하지 않는 이유) / `movingSeconds` 주석(실내 1급 지표, 벽시계−일시정지) / 게터 **`isDistanceMeasured`** · **`isTimeBased`** 추가 |

```dart
/// 이 기록이 거리를 측정했는가. false면 화면은 시간을 1급 지표로 그린다.
bool get isDistanceMeasured => activityType != ActivityType.indoorRun;
bool get isTimeBased => !isDistanceMeasured;
```

게터 판정이 `activityType` 한 축인 것은 **C-5와 같은 이유**다(§3). `hasRouteSamples`가 도입되면 이 게터 본문만 갈아끼우면 되도록 소비처를 게터로 모아 둔다 — 화면마다 `activityType == indoorRun`을 직접 쓰면 나중에 교체 지점이 흩어진다.

- `dart run build_runner build --delete-conflicting-outputs` ✅ (340 outputs)
- `flutter analyze` → **1 error, 이번 변경과 무관한 기존 실패**: `test/sync/run_sync_coordinator_test.dart:144` `_FakeRunRepository.syncPending`이 `{String? userId}` 시그니처를 따라가지 않음. `lib/` 는 0 issue.

---

## 2. XP 재설계 — 거리 기반 → 시간 기반

### 2.1 현행의 실제 동작

```sql
if p_distance_meters is null or p_distance_meters < 500 then return 0; end if;   -- ← 실내가 여기서 죽는다
...
if p_activity_type = 'indoor_run' then return least(20 + floor(m/100), 300); end if;
```

거리 게이트가 실내 분기보다 **먼저** 있으므로 실내는 20점이 아니라 **0점**이다. 실내 분기는 도달 불가능한 죽은 코드다.

### 2.2 권장 산식

| 항목 | 실내(신규) | 실외(불변) |
|---|---|---|
| 게이트 | **`moving_s ≥ 300`** (5분) | `distance ≥ 500m` |
| 산식 | **`min(20 + floor(moving_s / 60), 180)`** | `min(20 + 거리 + 페이스보너스 + 고도, 1000)` |

**계수·상한 근거 (어뷰징 관점)**

- **게이트 5분**: 실외 500m 게이트의 시간 등가. "앱을 켰다 껐다"를 배제한다.
- **분당 1 XP**: 실외 8km/h 러너는 시간당 약 230 XP(거리 80 + 페이스 보너스 16 → 30분 116점). 실내는 시간당 60 XP로 **약 1/4**. 실내가 무의미하지도, 실외보다 유리하지도 않다. 매일 실내 60분 = 80XP/일이 매일 실외 8km = 116XP/일의 69% — 완충 장치로는 충분하고 대체재가 되지는 않는 비율.
- **세션 상한 180 (기존 300에서 하향)**: 🔴 **이 부분이 거리 기반과 어뷰징 성격이 다르다.** 거리는 움직여야 늘지만 **시간은 가만히 있어도 흐른다.** 폰을 책상에 두고 러닝을 시작해 두면 그대로 적립된다. 상한 300은 280분(4h40m)이 필요해 사실상 도달 불가능한 값이라 **방어 기능이 없었다.** 180은 160분(2h40m)에서 포화 — 정직한 장시간 트레드밀 러너는 거의 손해를 보지 않으면서(실사용 트레드밀 세션 대부분이 60분 이하) 방치형 적립의 천장을 실제로 만든다.
- **일일/주간 상한을 두지 않은 이유**: `compute_run_xp`는 `immutable` 순수 함수라 세션 밖 상태를 볼 수 없다. 일일 상한을 넣으려면 `recompute_profile_stats` 쪽으로 로직을 옮겨야 하고, 그러면 "러닝 1건의 XP"라는 단순한 계약이 깨진다(§3.8.2의 "원본에서 재계산 가능, 증분 가산 금지" 원칙과도 충돌). 세션 상한으로 충분하다고 본다 — 하루에 실내 세션을 여러 번 방치하는 어뷰징은 관측되면 그때 `validate_run` 쪽 플래그로 다루는 것이 맞다.

### 2.3 `compute_run_xp` 시그니처 — **변경 없음**

`moving_seconds`·`activity_type` 모두 이미 인자에 있다. 바뀌는 것은 **본문 두 곳**뿐이다.

```sql
-- 변경 diff 초안 (마이그레이션 신규 57)
   if p_status <> 'completed' or coalesce(p_is_flagged, false) then
     return 0;
   end if;

-- ❌ 삭제: 활동 유형과 무관한 거리 게이트
-- if p_distance_meters is null or p_distance_meters < 500 then return 0; end if;

+  -- ✅ 실내·수동: 시간 기반 (PRD v1.8 §8.3). 거리 게이트를 적용하지 않는다 —
+  --    실내는 distance_meters 가 항상 0 이라 거리 게이트가 곧 전면 배제였다.
+  if p_activity_type = 'indoor_run' then
+    if coalesce(p_moving_seconds, 0) < 300 then return 0; end if;
+    return least(20 + floor(p_moving_seconds::numeric / 60.0), 180)::integer;
+  end if;
+
+  -- 실외 게이트(기존과 동일)
+  if p_distance_meters is null or p_distance_meters < 500 then return 0; end if;

   v_distance_pts := floor(p_distance_meters::numeric / 100.0);
-  if p_activity_type = 'indoor_run' then
-    return least(v_base + v_distance_pts, 300)::integer;
-  end if;
```

함수 comment도 갱신한다: `'... 실내·수동(indoor_run): 이동 5분 이상, 완주20 + 분당1, 상한 180.'`

**소급 영향 없음**: 기존 실내 기록은 `moving_seconds`도 0이라 새 게이트(≥300)에서도 0점이다. `recompute_profile_stats`를 전량 재실행해도 **XP 값이 변하지 않는다.** 소급 XP 증가 → 소급 레벨업 → 소급 뱃지 지급 사고가 구조적으로 없다. (§1.2 구현 이후 저장되는 **새 기록부터** 적립된다.)

---

## 3. C-5 — `hasRouteSamples`는 P1 웨어러블 라운드로 연기 (문서 명시만)

**결정**: 필드를 도입하지 않는다. 현행 `activity_type <> 'indoor_run'` 유지.

**근거**: P0(폰 GPS 단독)에서 "경로 샘플이 있다" = "실내 러닝이 아니다"가 **동치**다. 지금 필드를 도입하면 서버 39개 지점의 술어를 같은 뜻의 다른 컬럼으로 바꾸는 순수 비용과, 그 과정에서 한 지점을 빠뜨릴 리스크만 남는다.

**동치가 깨지는 시점**: 워치 임포트(WR-01~03). Apple Watch 실내 워크아웃은 `indoor_run`이 아닌 활동 유형으로 경로 없이 들어올 수 있고, 반대로 경로 있는 임포트도 생긴다. 그 순간 `activity_type` 판정은 **검증 구멍**이 된다.

**따라서**: `hasRouteSamples` 도입을 **P1 웨어러블 라운드의 착수 전 선행 작업**으로 고정하고, 문서에 명시했다.

- PRD §5.7 — 표 아래 "구현 메모(2026-09-01, C-5)" 블록
- ARCHITECTURE **§6.3.1 신설** — 현재 39개 대체 지점, 동치가 깨지는 조건, 도입 시 작업 범위(컬럼 + 술어 교체 + 백필)

---

## 4. 실내 뱃지 영향 (TRD §14 #16) — gamification-designer 확인 목록

**#16 자체는 실질 해소된다.** 실내 거리가 항상 0이므로 "트레드밀 42.2km"가 존재할 수 없고, `session_distance_gte`가 실내를 제외하지 않는 것과 `pb_first_achieved`가 제외하는 것 사이에 **관측 가능한 차이가 없어진다.** TRD §14의 #16을 취소선 처리하고 후속 항목 **#26**을 신설했다.

**gamification-designer가 별도로 볼 항목 (= TRD §14 #26)**

| # | 항목 | 왜 지금 결정해야 하나 |
|---|---|---|
| **G-1** | 거리 조건 뱃지(`session_distance_gte` 5종, `cumulative_distance_gte` 14종)에 `activity_type <> 'indoor_run'`을 **명시**할 것인가 | 지금은 값이 0이라 무해하다. 그러나 §1.1의 `reported_distance_meters`가 P1에 생기면 "명시하지 않은 조건"이 곧 구멍이다. **"거리 조건 뱃지 = 전부 실외 전용"으로 규칙을 하나로 통일**하는 쪽을 권장한다 — 조건별로 다른 규칙은 사람이 기억해야 하는 예외를 만든다 |
| **G-2** 🔴 | **`session_duration_gte` 2종(투아워런 7200s / 쓰리아워런 10800s)이 실내를 제외하지 않는다** | 실내가 시간 1급이 되는 순간 **이 둘이 새 어뷰징 표면**이 된다. 폰을 켜두면 3시간이 흐르고, 뱃지는 영구 자산이라 정상 경로로 회수할 수 없다. XP는 상한 180으로 막았지만 뱃지에는 상한이 없다. **실외 전용으로 좁히거나, 실내는 별도 뱃지(예: 실내 90분)로 분리**할 것을 권장 |
| **G-3** | **PRD §8.3이 약속한 "전용 실내 뱃지"가 카탈로그에 0종이다** | `docs/badge-catalog.csv` grep 0건. §8.3의 완충 장치("기록은 남고 인정도 받는다")가 문서에만 존재한다. 시간 기반 실내 뱃지 신설 제안: **누적 실내 시간**(10h/50h/100h) + **단일 실내 세션 시간**(45분/90분). 새 `condition_type` 2종(`indoor_cumulative_seconds_gte`, `indoor_session_duration_gte`)이 필요할 수 있다 |
| **G-4** | 스트릭 규칙 변경(§5)에 따른 `streak_weeks_gte` 9종 영향 | 소급 변화는 없다(§5). 신규 인정 경로만 생긴다 |
| **G-5** | 페이스 계열 뱃지 | 실내는 `avg_pace_sec_per_km`이 null이라 **자동 제외**된다. 조치 불필요 — 확인만 |

---

## 5. 스트릭 — 활동 주 판정에 실내 시간 대안 조건

**문제**: 현행 `활동 주 = 완주 1건 AND 주 합산 거리 ≥ 1.0km`. 실내 거리가 0이므로 **실내만 뛴 주는 항상 끊긴다.** 같은 함수의 주석은 "실내·수동을 포함한다"고 선언하고 있어 **선언과 동작이 어긋난 상태**다.

**권장안**:

```sql
having sum(case when r.activity_type = 'indoor_run' then 0 else r.distance_meters end) >= 1000.0
    or sum(case when r.activity_type = 'indoor_run' then r.moving_seconds else 0 end) >= 600
```

| 판단 | 근거 |
|---|---|
| **600초(10분)** | 1.0km 하한의 시간 등가(1km 러닝 ≈ 5~8분). 원 하한의 의도는 "50m 기록으로 104주 스트릭 연명 방지"였고, 시간 축에서 같은 의도를 지킨다 |
| **XP 게이트(5분)보다 엄격** | "XP는 받지만 스트릭은 못 받는" 구간이 의도적으로 존재한다. 스트릭은 XP보다 값비싼 자산(뱃지 9종 + 유예 크레딧)이므로 문턱이 더 높은 것이 맞다 |
| **주 합산 기준 유지** | 3분 × 4회도 통과한다. 원 규칙이 400m × 3회를 통과시키는 것과 같은 성질이라 새 완화가 아니다 |
| **실외 거리 조건에서 실내를 명시적으로 0 처리** | 현행은 `sum(distance_meters)`가 전 기록 합이다. 실내 거리가 0이라 지금은 결과가 같지만, `reported_distance_meters`류가 생겼을 때를 대비해 **의도를 SQL에 적어 둔다** |
| **소급 영향 0** | 기존 실내 기록은 `moving_seconds`도 0이라 새 조건에서도 활동 주가 아니다. 스트릭은 리플레이 파생값이라 규칙을 바꿔도 **기존 `longest_streak_weeks`가 변하지 않는다** — 뱃지 소급 지급 사고가 없다 |

---

## 6. 문서 변경 — 적용 위치 (전부 반영 완료, 미커밋)

| 문서 | 위치 | 변경 |
|---|---|---|
| **PRD** | 헤더 | 문서 버전 v1.7 → **v1.8** |
| **PRD** | 변경 이력 | **v1.8 행 신설** (아래 전문) |
| **PRD** | §5.1 TR-10 | `실내 러닝(트레드밀) 수동 입력` → **`실내 러닝(트레드밀) — 시간 기반 기록`**, 수용 기준에 "거리를 입력·측정하지 않고 시간만 기록" |
| **PRD** | §5.7 | 표 아래 **"구현 메모(2026-09-01, C-5)"** 블록 신설 — P0 `activity_type` 대체, `hasRouteSamples`는 P1 선행 작업 |
| **PRD** | **§8.3** | "실내 러닝은 거리가 아니라 시간으로 측정한다(v1.8 확정)" **표 + 근거 블록 신설**. 지표별 처리 9행 + 자가 신고 거리를 받지 않는 근거 |
| **PRD** | §10.1 | **#13 신설** — "실내 러닝 측정 축 = 시간 기반" |
| **TRD** | §3 모델 주석 블록 | `indoorRun`은 시간 기반, `distanceMeters` nullable화하지 않는 이유, `isDistanceMeasured`/`isTimeBased` 게터 |
| **TRD** | **§3.8.2** | XP_run 표의 실내 항목 → 시간 산식. 아래에 **"실내 XP가 시간 기반이 된 이유와 계수 근거"** 블록 신설(게이트/계수/상한 3행 표 + 시그니처 불변 + 소급 영향 없음) |
| **TRD** | **§10.2** | `streak_weeks_gte` 행 규칙 변경 + 표 아래 **"활동 주 판정의 실내 대안 조건"** 블록 신설(SQL diff 포함) |
| **TRD** | §14 | **#16 취소선 처리**(실질 해소) + **#26 신설**(gamification-designer 확인 3건 = G-1·G-2·G-3) |
| **ARCHITECTURE** | §4 모델 표 | `RunRecord` 행에 실내 시간 기반 명시 |
| **ARCHITECTURE** | **§6.3.1 신설** | C-5 — P0 `activity_type` 대체 현황(39개 지점), 동치가 깨지는 조건, 도입 시 작업 범위 |

**PRD 변경 이력 v1.8 문구 (적용본 전문)**

> | **v1.8** | **실내 러닝(TR-10)을 거리 기반 → 시간 기반으로 확정**(2026-09-01, 사용자 확정 · GPS 현장검증 후속 C-6). ① 트레드밀은 거리를 측정하지 않고 **사용자 입력도 받지 않는다** — 1급 지표는 이동 시간이고 `distance_meters`는 항상 0(§8.3 신설 표), ② 칼로리는 고정 MET 8.0 기반 **시간 추정**으로 전환, ③ XP_run 실내 산식을 `min(20 + floor(m/100), 300)` → **`min(20 + floor(moving_s/60), 180)`**, 게이트도 `거리≥500m` → `이동시간≥5분`(TRD §3.8.2), ④ 주간 스트릭 활동 주 판정에 **실내 시간 대안 조건**(주 합산 실내 이동 시간 ≥10분) 추가 — 실내만 뛴 주가 스트릭을 끊던 결함 해소(TRD §10.2), ⑤ §5.7 "경로 샘플 유무" 판정은 P0 동안 `activity_type` 대체를 정식 명시하고 `hasRouteSamples` 도입을 P1 웨어러블 선행 작업으로 확정(C-5). §10.1 #13 추가 |

---

## 7. 후속 담당자별 할 일

### gps-tracking-engineer (선행 — 이것 없이는 나머지가 전부 0을 본다)
1. `RunSessionAggregator`에 **실내 `movingSeconds` 경로** 구현 — 벽시계 − 누적 일시정지(§1.2 스케치). `pause()`/`resume()`에 일시정지 구간 누적 추가.
2. **실내 칼로리** — 고정 MET 8.0 시간 기반(§1.3). `_kcalForSegment`(GPS 세그먼트 기반)와 별도 경로로, `snapshot()`에서 `movingSeconds`로 산출.
3. 실내 세션에서 `routePolyline` = null, `samples` = 빈 배열, `sources`/`deviceVendors`는 `[phone]` 유지(기기 기여 사실은 남긴다).
4. 단위 테스트: 실내 30분 세션(중간 5분 일시정지) → `movingSeconds == 1500`, `distanceMeters == 0`, `avgPaceSecPerKm == null`, `caloriesKcal > 0`.

### backend-engineer
1. **마이그레이션 57(신규)** — `compute_run_xp` 실내 분기 시간 기반 전환(§2.3 diff). 시그니처·호출부 불변, 함수 comment 갱신.
2. 같은 마이그레이션에서 `_weekly_streak_state`의 활동 주 `having` 절 교체(§5 SQL).
3. 두 변경 모두 **소급 영향이 없음을 적용 전에 확인** — `select count(*) from runs where activity_type='indoor_run' and moving_seconds > 0;` 이 **0인지** 확인하고 진행(0이 아니면 소급 XP·스트릭이 움직인다).
4. `runs.distance_meters`에 실내 CHECK를 걸지는 **않는다** — 오프라인 재 upsert 멱등성(마이그레이션 51 헤더 방침)을 깨지 않기 위해, 거부가 아니라 가드에서 조용히 0으로 정규화하는 쪽을 검토.
5. G-1·G-2 결정이 나오면 뱃지 판정 술어 반영.

### gamification-designer
- §4의 **G-1 ~ G-5** 결정. 특히 **G-2(`session_duration_gte` 실내 어뷰징)는 베타 오픈 전 필수** — 뱃지는 영구 자산이라 회수 경로가 없다.
- **G-3(전용 실내 뱃지 0종)** — PRD §8.3이 이미 약속한 것이라 카탈로그 신설이 필요하다.

### flutter-ui-designer
1. 히스토리 목록 카드 · 기록 상세 요약 그리드에서 `RunRecord.isTimeBased` 분기 — **거리·페이스 타일을 그리지 않고 시간을 1급으로** 승격(§1.4). `0.00 km` / `—` 를 보여주지 않는다.
2. 트래킹 중 화면(`tracking_stats.dart`)도 동일 — 실내에서 거리·페이스 카운터가 0에 멈춰 있는 현재 상태가 C-6의 사용자 체감 증상이다.
3. 러닝 설정 시트(`tracking_page.dart:960`)의 "러닝 머신" 항목에 **"거리 대신 시간으로 기록해요"** 보조 문구.
4. 실내는 TR-03 자동 일시정지가 없다는 사실을 알릴지 판단(§1.2).
5. TR-11 목표 설정 — 실내에서는 **거리 목표를 숨기고 시간 목표만** 노출.

### qa-integration-tester
- 실내 세션 e2e: 시작 → 일시정지 → 재개 → 종료 → 업로드 → `moving_seconds`/`awarded_xp`/스트릭/뱃지까지. 특히 **XP가 0이 아닌 것**과 **거리 통계·티어·주간 랭킹이 움직이지 않는 것**을 동시에 확인.
