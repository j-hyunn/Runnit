# P0 잔여 방어 보강 2건 — `LocalRunRepository`

| 항목 | 내용 |
|------|------|
| 일자 | 2026-09-08 |
| 담당 | mobile-architect |
| 대상 | QA `_workspace/20260907_qa_p0-group1.md` **PLAUSIBLE-1** · **PLAUSIBLE-3** |
| 범위 | **클라이언트 코드만** — 스키마·마이그레이션·PRD 스펙 변경 없음 |
| 근거 문서 | `docs/TRD.md` §7.2 · §14 #27 잔여 · §14 #29, `docs/ARCHITECTURE.md` §9.1 |
| 커밋 | **하지 않았다** — 오케스트레이터가 QA 후 취합 |

---

## 1. 수정 1 — `applyServerConfirmation` 의 jsonb-문자열 방어 (PLAUSIBLE-1)

### 무엇이 문제였나

v0.29 QA 후속에서 `_fromRemote` 에는 `client_reported` 문자열 방어가 들어갔지만(`samples` 와 대칭), **확정 채택 경로에는 없었다.** `applyServerConfirmation` 은 `_adoptedKeys` 루프로 `confirmed[key]` 를 `summary` 에 그대로 넣고 `jsonEncode` 해 `summaryJson` 컬럼에 저장한다.

PostgREST 가 jsonb 를 파싱된 구조가 아니라 원문 문자열로 돌려주는 드문 경우, 이 경로는 **던지지 않는다** — 문자열을 조용히 DB에 박아 둔다. 예외는 **다음** `runRecordFromRow` → `RunRecord.fromJson` 의 `as Map<String, dynamic>` 캐스트에서 나온다.

**두 경로의 실패 모습이 다르다는 것이 핵심이다.**

| 경로 | 언제 던지나 | 사용자에게 보이는 것 |
|---|---|---|
| `_fromRemote` | 그 자리에서 | `findById` 원격 폴백 실패 (`guardSupabase` 가 삼킴) |
| `applyServerConfirmation` | **다음 조회에서** | 상세 화면이 원인 없이 빈다 — 업로드 왕복과 시간·코드상 멀리 떨어져 있어 추적이 어렵다 |

즉 방어가 빠진 쪽이 더 나쁜 형태로 실패한다.

### 어떻게 고쳤나

```dart
static const Set<String> _jsonbKeys = <String>{'client_reported', 'samples'};
```

방어 대상 키 목록을 **상수 한 곳**으로 뽑았다. 두 소비 지점이 각자 리터럴을 들고 있으면 이번과 똑같이 한쪽만 갱신되는 일이 반복된다. `samples` 는 `_adoptedKeys` 에 없어 확정 경로로는 도달하지 않지만 목록에 남겼다 — **목록이 갈라지는 것이 방어가 하나 빠지는 것보다 위험하다**는 것이 이번 결함의 교훈이다.

채택 루프는 값이 `_jsonbKeys` 의 키이면서 `is String` 일 때만 `jsonDecode` 한다. 정상 경로(이미 `Map`)는 종전 그대로 통과한다.

### 왜 모델·스키마를 안 건드렸나

이것은 wire 파싱 계층의 방어이지 스펙 변경이 아니다. `client_reported` 의 정본 모양은 `runs.client_reported jsonb`(마이그레이션 64) 그대로이고, `ClientReportedRun` 모델과 `_serverOwnedKeys`·`_adoptedKeys`·`_confirmationColumns` 세 집합도 **한 글자도 바뀌지 않았다.**

---

## 2. 수정 2 — `watchSyncRetryExhausted` 에 `status == completed` 필터 (PLAUSIBLE-3)

### 무엇이 문제였나

`watchSyncRetryExhausted` 는 id + `syncStatus != synced` + `syncAttempts >= maxSyncAttempts` 만 봤다. `syncPending()` 은 여기에 더해 `status == RunStatus.completed` 를 요구한다.

두 술어는 코드 주석·QA 보고서(§4)에서 **"정확히 상보"** 라고 선언돼 있다 — "자동 큐에서 빠진 행"과 "수동 재시도 버튼이 뜨는 행"이 같은 집합이어야 한다는 계약이다. 술어 하나가 빠져 있으면 그 계약이 코드에서 깨진다.

실무상 도달 불가한 것은 맞다(체크포인트 행은 `_push` 대상이 아니라 `sync_attempts` 가 오르지 않는다). 하지만 **도달 불가의 근거가 다른 모듈의 동작**(`_push` 가 완료 기록만 올린다)이라, 그쪽이 바뀌면 여기가 조용히 틀려진다. 계약을 선언해 둔 이상 그 사실에 기대지 않고 상태로 한 번 더 막는 편이 옳다.

### 어떻게 고쳤나

map 콜백 맨 앞에 한 줄:

```dart
if (row.status != runStatusWire(RunStatus.completed)) return false;
```

`syncStatus == synced` 가드 **앞**에 뒀다 — `syncPending` 의 where 절이 `status` 를 먼저 거르는 순서와 맞춘다.

---

## 3. 변경 파일

| 파일 | 변경 |
|---|---|
| `lib/features/tracking/data/local_run_repository.dart` | `_jsonbKeys` 상수 신설 / `applyServerConfirmation` 채택 루프에 문자열 방어 / `watchSyncRetryExhausted` 에 `completed` 필터 + 두 곳 주석 |
| `test/sync/offline_sync_test.dart` | 회귀 3건 추가(§10 1건 · §11 신설 2건), `package:drift/drift.dart show Value` import |
| `docs/TRD.md` | 헤더 v0.29 → **v0.30**, 변경 이력 v0.30 행 추가, §7.2 에 "jsonb 를 문자열로 받는 경우" 문단 + `_serverAdjustedKeys` 표 행의 stale 표기 정정(`max_speed_mps` 누락 — v0.29 에서 추가됐는데 표에 반영 안 돼 있었다), §14 #27 잔여·#29 ④ 에 각 한 줄 |

`docs/ARCHITECTURE.md` 는 **건드리지 않았다.** §9.1 이 서술하는 것은 배너 표시 규칙과 판정 입력(`runSyncRetryExhaustedProvider`)이고, 이번 두 수정은 그 판정의 **내부 술어**와 wire 파싱 방어라 문서상 서술이 달라지지 않는다.

---

## 4. 회귀 테스트

| # | 테스트 | 무엇을 고정하나 |
|---|---|---|
| 1 | `완료되지 않은 체크포인트 행은 예산과 무관하게 항상 false다` (§10) | `recording`·`paused` 두 상태를 각각, `syncAttempts` 를 상한 +5 로 **강제 주입**한 뒤 스트림이 false 인지 + `syncPending()` 도 0 인지 — 두 술어가 상보임을 한 테스트에서 함께 고정한다 |
| 2 | `확정 응답의 client_reported가 문자열이어도 이후 조회가 깨지지 않는다` (§11) | `applyServerConfirmation` 에 `jsonEncode` 된 문자열을 넘긴 뒤 **`findById` 가 크래시 없이** 중첩 모델을 돌려주는지, 확정 거리·`distanceWasAdjusted` 까지 정상인지 |
| 3 | `client_reported가 이미 Map이면 종전대로 그대로 채택한다` (§11) | 방어가 정상 경로를 건드리지 않는지 — 회귀 방향의 반대편 |

**결함 재현 확인.** `lib/` 수정을 되돌린 상태로 이 테스트들을 돌려 **둘 다 실제로 실패하는 것**을 확인했다(테스트가 방어를 실제로 잡고 있다는 증거).

```
00:01 +27 -1: 완료되지 않은 체크포인트 행은 예산과 무관하게 항상 false다 [E]
  Expected: false
    Actual: <true>
00:01 +27 -2: 확정 응답의 client_reported가 문자열이어도 이후 조회가 깨지지 않는다 [E]
  type 'String' is not a subtype of type 'Map<String, dynamic>' in type cast
```

---

## 5. 검증 결과

| 검사 | 결과 |
|---|---|
| `flutter analyze` | **No issues found!** (exit 0) |
| `flutter test` | **All tests passed! — 322건** (exit 0, 종전 319 + 신규 3) |

> ⚠️ 이 워크트리에는 생성 파일(`*.freezed.dart` · `*.g.dart` · drift 생성분)이 없어 첫 `flutter analyze` 가 646 에러를 냈다. `flutter pub get` + `dart run build_runner build --delete-conflicting-outputs` 로 348개 생성 후 정상. **소스 결함이 아니라 워크트리 초기 상태**다.

---

## 6. 남은 것

이번 라운드에서 **닫지 않은** QA 항목:

- **PLAUSIBLE-2**(`max_speed_mps` 되받기) — v0.29 에서 이미 `_serverAdjustedKeys` 에 추가돼 코드상 해소됐다. 이번에는 §7.2 표의 stale 표기만 정정했다.
- **UNVERIFIED-1**(`client_reported` 서버→클라 실 왕복) — 원격에 `client_reported is not null` 행이 0건이라 여전히 실측 불가. TRD §14 #27 잔여 ①(F-7 진단 쿼리)과 같은 시점에 함께 볼 항목.
- **UNVERIFIED-2**(수동 재시도의 실제 네트워크 복구) — 실기기 검증 묶음.
