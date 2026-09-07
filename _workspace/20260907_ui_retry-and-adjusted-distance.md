# 상세 화면 마감 — 수동 재시도(F-5) + 확정 거리 병기(G-3 / F-4)

| 항목 | 내용 |
|------|------|
| 작성일 | 2026-09-07 |
| 담당 | flutter-ui-designer |
| 브랜치 | `claude/task-list-planning-c1f2a8` (기준 커밋 `64bd7d6`) |
| 근거 | PRD §8.3·§8.4 / ARCHITECTURE §9.1 / TRD §14 #27·#29 / `_workspace/20260903_backend_p0-validate-recalc-upload-guard.md` §4·§5.5 / `_workspace/20260907_architect_client-reported-g3g4.md` §4 |
| 범위 | **상세 화면 UI + 그 판정에 필요한 구독 경로 1개.** 스키마·마이그레이션·PRD 스펙 변경 없음 |
| 상태 | 코드·문서·테스트 변경 완료, **커밋하지 않음** |

확정 스펙의 **미구현 UI 마감**이다. 새 정책을 만들지 않았고, 문구도 이미 정해진 서버 동작을 서술만 한다.

---

## 1. 작업 1 — 수동 재시도 (TRD §14 #29 잔여 F-5)

### 1.1 판정 입력을 어디서 얻는가 — 모델이 아니다

`sync_attempts`는 **drift 로컬 컬럼이고 `runRecordFromRow`가 모델로 올리지 않는다**(서버에 대응 컬럼이 없고, 목록 200건이 들고 다닐 이유도 없는 값이다). 그래서 상세 화면은 `RunRecord`만으로는 "자동 재시도가 이미 멈췄다"를 알 수 없다.

모델에 필드를 추가하는 선택지는 **택하지 않았다.** 그러면 `RunRecord.toJson()` → 업로드 payload 에 `runs` 에 없는 컬럼이 섞이거나(`_runsColumns` 정합 테스트가 깨진다) `_serverOwnedKeys` 를 또 갈라야 한다 — 아키텍트가 `client_reported` 에서 피한 것과 같은 형태의 비용이다. 대신 **행 구독 하나**를 새로 뚫었다.

```dart
// LocalRunRepository
Stream<bool> watchSyncRetryExhausted(String id);   // synced 는 항상 false
```
```dart
// run_detail_providers.dart
final runSyncRetryExhaustedProvider =
    StreamProvider.autoDispose.family<bool, String>(...);  // Local 구현이 아니면 false
```

`runSyncStatusProvider`(목록 스트림에서 골라내기)와 **갈라 둔 이유**는 원천이 다르기 때문이다 — `syncStatus`는 모델에 실려 있어 목록에서 뽑을 수 있지만 `sync_attempts`는 그렇지 않다. 두 provider 모두 drift `watch()` 위에 있어 **업로드가 끝나면 배너가 그 자리에서 사라진다**는 성질은 같다.

### 1.2 배너 상태가 둘에서 셋으로

| 상태 | 문구 | 버튼 |
|---|---|---|
| 미시도 (`local`/`pending`) | "아직 서버에 올라가지 않았어요. 네트워크에 연결되면 자동으로 업로드돼요…" | 없음 |
| 자동 재시도 중 (`failed`, 예산 남음) | "업로드에 실패해 다시 시도하고 있어요…" | 없음 |
| **예산 소진** (`maxSyncAttempts=10`) | "여러 번 시도했지만 올리지 못했어요. 네트워크 상태를 확인하고 다시 시도해 주세요…" | **다시 시도** |

앞의 두 상태에 버튼을 주지 않는 이유는 하나다 — 코디네이터가 어차피 하는 일을 사용자에게 시키는 셈이고, 눌러도 관측되는 변화가 없다. 세 번째 상태에서만 "기다리면 된다"가 **거짓**이 되므로 거기서만 문구를 갈랐다.

세 상태 모두 "그 전까지 이번 시즌 티어·주간 랭킹 미반영"(ARCHITECTURE §9.1)은 유지한다.

### 1.3 탭 동작 — 예산 복구만으로는 부족하다

```
resetSyncAttempts(id)  →  스낵바 "다시 시도하고 있어요"  →  syncPending(userId:) 1회 (await 하지 않음)
```

`resetSyncAttempts`만 부르면 다음 코디네이터 신호(최대 2분)까지 아무 일도 일어나지 않아 **버튼이 먹통처럼 보인다.** `RunSyncCoordinator`에는 외부에서 부를 수 있는 트리거가 없어(`_trySync`는 private) 화면이 `syncPending`을 직접 한 번 태운다. `userId`를 좁혀 부르는 것은 코디네이터와 같은 이유다(계정 전환 후 남의 행으로 RLS 42501을 반복하지 않기 위해 — QA C-5).

**완료를 기다리지 않는다.** 3,600 샘플 업로드는 수십 초가 걸릴 수 있고, 결과는 두 provider가 drift `watch()`로 받아 배너를 스스로 지운다. 실패하면 행이 다시 `failed`로 남아 배너가 유지되므로 별도 에러 안내를 겹쳐 띄우지 않는다.

### 1.4 목록 칩(`run_tile.dart`)은 건드리지 않았다 — 판단

과하다고 봤다. 근거 둘:
- **비용** — 칩이 상한 여부를 알려면 200행이 각각 행 스트림을 열어야 한다. 목록 스트림 하나로 끝나는 현재 구조가 깨진다.
- **역할 분담** — 목록 칩은 원래부터 "존재만 알리고 이유는 상세에 맡긴다"는 방침이다(ARCHITECTURE §9.1). 상한 도달은 **설명이 필요한 상태**라 정확히 상세의 몫이다.

---

## 2. 작업 2 — 확정 거리 병기 (TRD §14 #27 잔여 ② / G-3 ⓐ안 + F-4)

### 2.1 배치 결정 — 배너 아님, 요약 그리드 거리 셀의 인라인 보조 표기

```
2.70 km        ← 확정 거리(주 숫자, 18px w700)
거리            ← 라벨(13px)
기기 기록 3.00 km ← 보조(11px 회색, maxLines 2)
```

- **주 숫자는 언제나 `distanceMeters`(확정값)다.** 히스토리·통계·랭킹·공유 카드가 전부 그 값을 쓰므로 이 화면에서만 다른 숫자를 크게 보여주면 화면 간 수치가 갈린다.
- 노출 조건은 `record.distanceWasAdjusted` **하나**(> 10m). 아키텍트가 준 파생 getter를 그대로 쓰고, true일 때만 `clientReportedDistanceMeters`가 non-null이라는 계약에 기댄다.
- 11px·`maxLines: 2`인 이유: 그리드 셀 폭이 320pt 폰에서 96pt까지 좁아진다(열 수는 `LayoutBuilder`가 폭에서 정한다).

**왜 배너가 아닌가** — 조정은 정상 기록에서도 일어나는 상시 현상이다. 배너로 만들면 앰버 배타 규칙(플래그 > 동기화 대기)의 **세 번째 대상**이 되어 규칙이 복잡해지고, 무엇보다 **플래그된 기록에서 조정 사실이 사라진다**(플래그가 우선이므로). 인라인이면 플래그 배너와 공존한다 — 회귀 테스트로 고정했다.

### 2.2 랩 섹션의 한 줄 안내 — divergence 설명

> 랩·페이스·경로는 기기가 기록한 원본 거리 기준이에요. 티어·랭킹에는 확정 거리 2.70 km가 반영돼요.

서버가 재기입한 샘플을 되받지 않기로 했으므로(3,600건 재다운로드) 랩·페이스·경로는 계속 로컬 samples 기준이고, 요약의 거리만 확정값이다. 이 한 줄이 그 divergence에 대한 유일한 설명이며, 아키텍트 문서 §4가 "열린 항목 2번(G-3 ⓐ안)과 3번(F-4 잔여)은 같은 화면 작업 하나"라고 한 지점이다.

배치는 **랩 테이블 아래**(일시정지 안내와 같은 자리, 12px 회색). 랩이 안 나오는 짧은 기록에도 경로가 있으면 붙인다 — 지도 역시 원본 샘플이다. 실내 러닝은 서버가 재계산을 스킵하므로 애초에 이 상태가 되지 않는다.

---

## 3. 변경 파일 · 검증

| 파일 | 변경 |
|---|---|
| `lib/features/tracking/data/local_run_repository.dart` | `watchSyncRetryExhausted(id)` 신설 (읽기 전용 구독 1개. 기존 로직 변경 없음) |
| `lib/features/history/data/run_detail_providers.dart` | `runSyncRetryExhaustedProvider` 신설 |
| `lib/features/history/presentation/run_detail_page.dart` | `retrySyncUpload()` 신설 / `_SyncPendingBanner`에 `onRetry` + 3번째 문구 / `_SummaryGrid` 항목을 `(라벨, 값, 보조)` 3튜플로 확장 + 거리 병기 / `_lapSections`에 `adjustedDistanceKm` 안내 |
| `test/sync/offline_sync_test.dart` | §10 신설 — 상한 도달·복구 스트림, `synced` 예외, 없는 id (3건) |
| `test/history/run_detail_page_test.dart` | 재시도 4건(미노출/노출/탭/배너 자체 없음) + 병기 4건(노출/미노출/임계 이하/플래그와 공존) |
| `docs/TRD.md` | §14 #27 잔여 ② 해소, #29 ④ 추가, 변경 이력 v0.29 |
| `docs/ARCHITECTURE.md` | §9.1 배너 표에 상한 도달 상태 추가 + "배타 규칙에 세 번째를 추가하지 않는다" 명시 |

`run_tile.dart`는 **바꾸지 않았다**(§1.4).

| 검증 | 결과 |
|---|---|
| `flutter analyze` | **No issues found!** |
| `flutter test` | **317개 전부 통과** (기존 306 + 11) |

커밋하지 않았다.

---

## 4. QA 가 볼 경계

| 경계 | 확인할 것 |
|---|---|
| provider ↔ repo | `runSyncRetryExhaustedProvider`는 `runRepositoryProvider`가 `LocalRunRepository`일 때만 실제 스트림이다. **원격 구현으로 갈아끼우면 조용히 항상 false** — 상한이라는 개념 자체가 없어 의도된 동작이지만, 로컬 구현을 갈아끼우는 변경이 들어오면 재시도 UI가 통째로 사라진다 |
| provider ↔ repo | `watchSyncRetryExhausted`는 `sync_attempts >= maxSyncAttempts`를 본다. `syncPending()`의 제외 조건은 `isSmallerThanValue(maxSyncAttempts)` — **두 경계가 같은 방향이어야** "큐에서 빠졌는데 버튼이 없다"가 생기지 않는다 |
| 모델 getter ↔ 위젯 | 위젯은 `distanceWasAdjusted`가 true일 때 `clientReportedDistanceMeters!`를 **강제 언랩**한다. 이 계약(true ⇒ non-null)이 `run_record.dart`에서 깨지면 런타임 크래시다 |
| 표시 임계 ↔ 서버 임계 | 클라이언트 10m(표시)와 서버 `v_flag_shrink_ratio` 0.8(플래그)은 **무관**하다. 한쪽을 조정할 때 다른 쪽을 따라 바꾸면 안 된다 |
| 화면 간 수치 | 상세 요약·목록 행·공유 카드·랭킹이 모두 `distanceMeters`(확정값)를 써야 한다. 병기는 상세의 보조 텍스트 한 곳뿐 |
| 미검증 | 실기기에서 실제로 상한(10회 실패)까지 몰아 본 적은 없다 — 위젯 테스트는 provider 경계에서 술어를 주입하고, 리포지토리 테스트는 가짜 PostgREST로 상한을 만든다 |
