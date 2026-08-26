# 업로드 응답 채택 — `_push()`에 `.select().single()` 추가

- 작성: 2026-08-26 / gps-tracking-engineer
- 요청: `_workspace/20260826_050000_architect_sharing-cards.md` §4.2.1, §7 (mobile-architect → gps-tracking-engineer)
- 근거: PRD §8.4(서버 재검증), TRD §3.9 매핑표, 마이그레이션 `39_xp_level_and_weekly_streak.sql` 39-6 `trg_runs_guard`
- 범위: `lib/features/tracking/data/local_run_repository.dart` 한 파일 + 신규 테스트 1개. presentation 레이어 미변경.

---

## 0. 세 줄 요약

1. `_push()`가 `.upsert(payload).select(...).single()`로 서버 확정 행을 되받고, `applyServerConfirmation()`이 그 값을 로컬 행에 반영한다. 이제 `RunRecord.isFlagged`가 실제로 채워진다.
2. `.select()`를 **인자 없이** 쓰지 않았다 — 그러면 방금 올린 3600 샘플이 그대로 되돌아온다. `_serverOwnedKeys` + PK만 요청한다.
3. 오프라인 큐/재시도에 부작용 없다. 새로 생긴 실패 지점은 전부 "로컬 `failed` → `syncPending()` 재시도"로 흡수되고, 업로드가 멱등이라 중복 행이 생기지 않는다.

---

## 1. 무엇이 문제였나

`RunRecord.isFlagged`/`flagReason`은 모델과 `_serverOwnedKeys`(업로드 payload 스트립)까지 준비돼 있었지만, **서버가 확정한 값을 읽어올 경로가 없었다.** `_push()`가 `.upsert(payload)`만 하고 응답을 버렸기 때문이다.

결과적으로 `isFlagged`가 영구히 `null`이고, `achievement_moment.dart`의 게이트가

```dart
if (runFlagged == null) return AchievementGate.pending;
```

에서 멈춘다 — 축하 연출도 공유 버튼도 영원히 안 뜬다.

## 2. 변경 내용

### 2.1 `_push()` — 응답을 받는다

```dart
final confirmed = await _client
    .from(_table)
    .upsert(_remotePayload(record))
    .select(_confirmationColumns)   // ← 전체가 아니라 서버 소유 컬럼 + PK
    .single();
await applyServerConfirmation(record.id, confirmed);
```

`_confirmationColumns`는 `['id', ..._serverOwnedKeys].join(',')`이다. **보낼 때 빼는 키 집합과 받을 때 채우는 키 집합이 같은 상수 하나**라서 어긋날 수가 없다. 이 대칭이 이 변경의 핵심이고, 코드 주석에도 "두 방향을 혼동하지 말 것"으로 남겼다.

전체 `.select()`를 쓰지 않은 이유: `runs.samples`가 jsonb 컬럼이라 인자 없는 `.select()`는 1시간 러닝 기준 약 3600 샘플을 **방금 업로드한 그대로 다시 내려받는다.** 업로드 트래픽이 사실상 2배가 된다.

### 2.2 `applyServerConfirmation()` — 읽고-겹치고-쓴다

인메모리 `RunRecord`를 통째로 다시 쓰지 않고, **DB의 현재 `summaryJson`을 읽어 서버 소유 키만 겹쳐 쓴다**(drift 트랜잭션 안에서). 이유 두 가지:

| 이유 | 통째로 썼다면 |
|---|---|
| 업로드가 도는 동안 사용자가 제목/메모를 고칠 수 있다 | 그 수정이 조용히 롤백된다 (lost update) |
| `samplesJson` 컬럼을 아예 안 건드린다 | 3600 샘플을 재직렬화 |

행이 사라졌으면(업로드 중 `discard()`→`delete()`) 조용히 no-op — 삭제한 기록을 응답으로 되살리지 않는다.

`drift` 스키마 변경 없음. 요약이 JSON blob이라 마이그레이션이 필요 없다.

### 2.3 실패 경로 정리

`_markSyncStatus(id, status)` 헬퍼로 중복 제거. 동작은 이전과 동일하다.

## 3. `.select().single()`이 에러 의미를 어떻게 바꾸나 (요청 항목 4)

`single()`은 행이 정확히 1개가 아니면 `PostgrestException`을 던진다. 실제로 문제가 될 수 있는 경우를 하나씩 따졌다:

| 경우 | 판단 |
|---|---|
| 2행 이상 | 불가능. `runs.id`가 PK다. |
| 0행 | RLS `runs_select_own`(`user_id = auth.uid()`) 거부뿐. 자기 기록을 올리는 정상 경로에서는 발생하지 않는다. 발생한다면 그건 **인증이 깨진 상태**이고, `failed`로 남겨 재시도하는 것이 맞는 처리다. |
| upsert는 성공했는데 응답 파싱/로컬 반영이 실패 | **새로 생긴 실패 지점.** 서버에는 이미 행이 있지만 로컬은 `failed`가 된다 → `syncPending()`이 같은 `id`로 다시 upsert → 응답을 다시 받아 반영. **업로드가 멱등**(`id`가 클라이언트 생성 UUID v4 = 서버 PK)이라 중복 행도, 잃어버린 판정도 없다. |
| `is_flagged`가 아직 계산 전일 가능성 | 없다. `trg_runs_guard`는 **BEFORE INSERT/UPDATE 트리거**라 `is_flagged`/`flag_reason`/`awarded_xp`/`avg_pace_sec_per_km`을 동기적으로 확정한 뒤 RETURNING 된다. 재조회도 realtime 구독도 필요 없다. |

즉 오프라인 큐(`SyncStatus.pending/failed` → `syncPending()` → `RunSyncCoordinator`의 로그인/포그라운드 복귀/2분 폴백)의 의미는 그대로다. 실패가 늘어날 수 있는 만큼 재시도가 그것을 흡수한다.

## 4. 다른 호출부 영향 (요청 항목 5)

`_push()` 호출부는 `save()`와 `syncPending()` 둘뿐이고, 둘 다 시그니처(`Future<bool>`)와 성공/실패 의미가 그대로다.

- `save()`: 업로드 실패는 여전히 `save()`의 실패가 아니다.
- `syncPending()`: `includeSamples: true`로 읽은 레코드를 넘기지만, 이제 `samplesJson` 컬럼을 건드리지 않으므로 샘플 왕복이 없다.
- `findById()`의 원격 폴백(`_fromRemote`)은 전체 `select()`라 `is_flagged`가 원래부터 들어온다 — 변경 불필요.
- `RunRepository` 인터페이스 변경 없음 → `repository_providers.dart` / `run_sync_coordinator.dart` 영향 없음.

## 5. 남은 이음매 — flutter-ui-designer / mobile-architect 확인 요망

⚠️ **`TrackingController.stop()`이 돌려주는 `RunRecord`는 업로드 이전 스냅샷이다.**

```dart
final record = await _service.stop();
await ref.read(runRepositoryProvider).save(record);  // ← 여기서 서버 판정이 로컬 DB에 들어간다
state = AsyncData(record);                            // ← 하지만 이 record는 그 전 값 (isFlagged: null)
```

`save()`가 `Future<void>`라 확정본을 돌려줄 자리가 없다. 요약 화면이 `stop()`의 반환값을 그대로 들고 게이트를 판정하면 **항상 `pending`**이다. 로컬 DB에는 값이 들어갔으므로 요약 화면은 `id`로 다시 구독해야 한다(`watchByUser`는 drift `watch()`라 `sync_status`/`summaryJson` 변경 시 자동 재발행된다 — 즉 `pending → confirmed` 승격이 그 스트림으로 자연히 흐른다).

이 부분은 presentation 레이어라 이번 작업에서 건드리지 않았다. `findById(id)` 단건 구독 provider가 필요하면 요청해 달라 — 트래킹 쪽에서 붙이겠다.

## 6. 문서 갱신

- `docs/TRD.md` §3.9 매핑표 `RunRecord.isFlagged` 행 — 채워지는 경로(업로드 응답)와 BEFORE 트리거 근거를 명시.
- `docs/ARCHITECTURE.md` §9 — "업로드는 단방향이 아니다" 불릿 추가.

> 참고(내 담당 밖): ARCHITECTURE §9의 나머지 서술이 현재 구현과 어긋나 있다 — "Edge Function 업로드"라고 돼 있지만 실제로는 PostgREST 직접 upsert이고, "저장소 선택(Hive/Drift/Isar 등)은 TRD §14 미확정"이라고 돼 있지만 drift로 확정돼 구현까지 끝났다. mobile-architect 몫이라 손대지 않았다.

## 7. 검증

| 항목 | 결과 |
|---|---|
| `flutter analyze lib/features/tracking test/tracking` | **No issues found** |
| `flutter analyze`(전체) | 1건 — `lib/features/sharing/presentation/widgets/share_card_surface.dart:124` `non_exhaustive_switch_expression`. **flutter-ui-designer가 작업 중인 파일이고 내 변경과 무관**(내 diff는 `local_run_repository.dart` 1개 파일) |
| `flutter test` | **115건 전부 통과** (기존 108 + 신규 7, 회귀 0) |

### 신규 테스트 — `test/tracking/run_push_confirmation_test.dart` (7건)

인메모리 drift(`NativeDatabase.memory()`)로 로컬 반영 계약을 직접 검증한다. 네트워크를 타지 않는다.

1. 서버가 `is_flagged=true` → 로컬 `RunRecord.isFlagged == true`, `flagReason` 저장, `syncStatus == synced`, 게이트가 `flagged`
2. `is_flagged=false`가 `null`과 구별 저장 → 게이트가 `pending` → `confirmed`로 승격 (nullable 3상태 설계의 핵심 회귀)
3. `awarded_xp`/`created_at`/`updated_at`도 함께 채택
4. 사용자 소유 필드(`title`)와 `samples`가 응답 반영으로 사라지지 않음 (lost update 방어)
5. 업로드 도중 삭제된 기록은 응답으로 되살아나지 않음
6. 응답에 없는 키는 로컬 값을 지우지 않음
7. 채택한 판정이 `summaryJson`에 남아 앱 재시작(행 → 모델 복원) 후에도 읽힘
