# QA — "동기화 대기" 사용자 안내 (A-옵션1) 경계 검증

| 항목 | 내용 |
|------|------|
| 일자 | 2026-09-02 |
| 범위 | **증분 QA — 이번 변경 1건의 경계만.** 전체 회귀 아님 |
| 대상 | `sync_pending.dart`(신규), `run_detail_page.dart`, `widgets/run_tile.dart`, `local_run_repository.dart _fromRemote`, docs 3종 |
| 근거 | ARCHITECTURE §9.1, PRD v1.9 §10.1 #13 / TR-08 |
| 결과 | **차단 결함 0.** PASS 4 / 관찰 3(모두 low) / 재현 불가 0 |
| 도구 | `flutter analyze` → No issues found. `flutter test` → **All tests passed (284)** |

---

## 1. `_fromRemote`의 `synced` 확정이 다른 경로를 깨지 않는가 — **PASS**

**호출부는 하나뿐이다.** `_fromRemote`는 `local_run_repository.dart:419`(=`findById`의 원격 폴백)에서만 불린다. `syncPending()`·`_push()`의 응답 채택은 `_fromRemote`를 타지 않고 `applyServerConfirmation()`(213)이 `_serverOwnedKeys`만 겹쳐 쓰며 **같은 트랜잭션에서 이미 `synced`로 올린다**(231). 목록 경로(`listByUser` 450 / `watchByUser` 467)는 전부 로컬 `runRecordFromRow`라 실제 `sync_status` 컬럼값을 그대로 싣는다. 즉 이번 변경으로 상태가 바뀌는 지점은 **원격 폴백 1곳**뿐이다.

### 1-1. 로컬 캐시 upsert에 `synced`를 쓰는 것이 맞는가 — 맞다

`findById`의 캐시 쓰기(424)는 `includeSamples`일 때만 실행되고(QA I-2 가드 유지), 그 행은 방금 서버에서 온전히 읽어온 행이다. 원격에 행이 존재한다 = 업로드 완료이므로 `synced`가 사실과 일치한다.

### 1-2. 미전송 로컬 편집을 삼키는가 — **현재 코드에서 도달 불가**

원격 분기에 들어가려면 ① 로컬 행이 없거나 ② `incomplete`(= `includeSamples && samples.isEmpty && routePolyline != null/빈값 아님`, 403~405)여야 한다.

- 오프라인 저장분(`pending`/`failed`)은 `save()`가 `toRow()`로 **samples까지 함께** 쓰므로 `samples.isEmpty`가 성립하지 않는다 → `incomplete == false` → 397~406에서 로컬 히트로 조기 반환. 원격을 아예 보지 않는다.
- 오프라인 메타 편집도 삼키지 않는다. `updateMeta`(302)는 비-`synced` 행을 **로컬만** 고치고 `sync_status`를 건드리지 않으며(주석 §"아직 서버에 없는 기록"), 이후 `syncPending()` → `_remotePayload`가 title/note를 함께 올린다. 그 행은 위 이유로 원격 덮어쓰기 경로에 도달하지 않는다.

⚠️ **감시 항목(코드 변경 아님).** 424의 `_writeLocal`은 행 **전체**를 덮어쓴다(`applyServerConfirmation`/`_applyMeta`가 `summaryJson` 부분 겹쳐쓰기를 택한 것과 대비). 지금은 도달 불가라 무해하지만, 앞으로 (a) samples 없는 원격 응답을 캐시하도록 I-2 가드를 완화하거나 (b) 오프라인 메타 편집 큐를 도입하면 **이 한 줄이 미전송 편집을 삼키는 지점이 된다.** 그때는 424도 부분 겹쳐쓰기로 바꿔야 한다.

### 1-3. 기존 계약과의 모순 — 없다

`§저장 순서`(14~26), `§왜 업로드가 멱등한가`, `§서버가 덮어쓰는 값`, I-2 가드(420~425) 모두 그대로 성립한다. `_serverOwnedKeys`에 `sync_status`가 들어가지 않는다는 점도 유지된다(서버에 없는 기기 로컬 컬럼).

---

## 2. `isSyncPending` 술어의 상태 커버리지 — **PASS**

| `RunStatus` | 목록/상세 도달 경로 | 판정 |
|---|---|---|
| `recording`/`paused` | 목록 SQL이 `status = completed`로 걸러 낸다(`listByUser` 438, `watchByUser` 459). 복구는 `findInterrupted`(476) 전용 경로 | 도달 불가, 술어도 제외 — 이중 안전 |
| `discarded` | `geolocator_run_tracking_service.dart:411`이 세션 **스트림에만** 실어 보내고 DB에 쓰지 않는다. `delete()`가 행을 지운다 | 도달 불가 |
| `completed` | 정상 | 대상 |

`SyncStatus` 4값 × `completed`: `synced` 미표시 / `pending`·`failed` 표시(정상 큐 상태) / `local` 표시 — `local`+`completed`는 `save()` 경로상 원래 생기지 않지만(108~109가 완료 기록을 `pending`으로 쓴다) 만약 생기면 "미업로드"가 맞으므로 표시가 옳다. **커버리지 결함 없음.**

---

## 3. flagged ↔ syncPending 배타 — **PASS (설계대로, 사실상 도달 불가)**

`isFlagged`를 채우는 유일한 경로가 `applyServerConfirmation`(213)이고, 이 함수는 **같은 트랜잭션에서** `syncStatus`를 `synced`로 올린다(231). `syncPending()`은 비-`synced` 행만 고르므로(251~256) 확정 이후 되돌아갈 경로도 없다. 따라서 `isFlagged == true && syncStatus != synced`는 실질적으로 성립하지 않고, `else if`는 방어적 분기다. 겹칠 경우 플래그 우선도 맞다(확정 사실 > 대기 안내).

`isFlagged == null`(검증 전) + 미동기화 → **배너 표시.** 이것이 이 기능의 주 케이스(오프라인 완주 직후)이며 의도대로 동작한다. 테스트도 `local`/`pending`/`failed` 3케이스와 flagged 우선 1케이스를 덮는다(`run_detail_page_test.dart:207~270`).

---

## 4. 요약 화면 오염 — **PASS**

`RunHistoryTile` 사용처는 `history_page.dart:374`(최근 기록)와 `run_history_list_page.dart:40` **둘뿐**이다. 러닝 종료 직후 요약 화면은 타일을 재사용하지 않고 `storedRunProvider`(`tracking_ui_providers.dart:35`) → `summary_achievements.dart:55`에서 `syncStatus == synced`를 **공유 게이트 입력으로만** 읽는다. 칩이 뜰 경로 없음. 이번 변경이 그 게이트를 건드리지도 않았다(오히려 원격 폴백 시 `local`로 남던 값이 `synced`로 정정돼 게이트가 더 정확해진다).

---

## 5. 관찰 사항 (모두 low, 코드 수정 없음)

| # | 분류 | 내용 |
|---|---|---|
| O-1 | **CONFIRMED** / low | `local_run_repository.dart:424`의 `.copyWith(syncStatus: SyncStatus.synced)`가 이제 `_fromRemote`(507)의 보장과 **중복**이다. 같은 사실을 두 곳이 주장한다 — 나중에 `_fromRemote`가 응답의 상태를 존중하도록 바뀌면 424가 조용히 이깁니다. 한쪽(424)을 지우고 `_fromRemote`를 단일 진원지로 두는 편이 낫다 |
| O-2 | **CONFIRMED** / low | **이번 수정에 회귀 가드가 없다.** `test/tracking/find_by_id_samples_cache_test.dart`가 원격 폴백을 덮지만 반환값의 `syncStatus`를 단언하지 않고, `syncStatus`를 검사하는 테스트는 전부 로컬 행 기준이다(`offline_sync_test`, `run_push_confirmation_test`, `update_meta_test`). 원격 폴백 결과가 `SyncStatus.synced`인지 `expect` 한 줄을 그 테스트에 추가하면 오탐 재발을 막는다 |
| O-3 | **CONFIRMED** / low(UX) | **상세 배너가 실시간으로 사라지지 않는다.** `runDetailProvider`는 `FutureProvider.autoDispose` 단발이고 invalidate 지점이 재시도 버튼(`run_detail_page.dart:84`)과 메타 편집 후(122)뿐이다. 목록 칩은 drift `watch()`(467) 덕에 업로드 완료 즉시 사라지지만, 상세를 연 채로 네트워크가 복구돼 코디네이터가 업로드를 끝내면 배너는 재진입 전까지 "동기화 대기"로 남는다. 잘못된 정보를 잠깐 보여 주는 것이라 무해하지는 않다. 선례가 이미 있다 — `storedRunProvider`는 같은 이유로 단발 조회 대신 `myRunsProvider` 스트림에서 골라낸다 |
| O-4 | 사전 존재(이번 변경 아님) | TRD §3.2 `RunRecord` 스니펫(194~213)이 실제 모델과 크게 어긋나 있다 — `syncStatus`·`status`·`activityType`·`elapsedSeconds`·`isFlagged`가 없고 `memo`/`duration`/`flagged`/`RunRecordType` 등 폐기된 이름이 남아 있다. 이번 기능의 근거 필드(`syncStatus`)가 TRD에 아예 없다는 점만 기록해 둔다. ARCHITECTURE §9.1(607~614)은 정확하다 |

---

## 6. 문서 정합

- ARCHITECTURE §9.1이 P2로 남겨 뒀던 항목을 닫고 표·주의문까지 코드와 일치(`isSyncPending` 술어, 파일 경로, 플래그 우선 규칙). **일치.**
- PRD v1.9 TR-08 수용 기준 + §10.1 #13 추가. 정책(소급 미반영) 불변, UX 노출만 추가 — 스펙 확대 아님. **일치.**
- TRD v0.25 변경 이력은 이번 라운드와 **무관한 내용**(#27↔#26 상호참조)이다. 문서 버전만 올라갔을 뿐 sync-pending 관련 기술 서술은 TRD에 없다 — ARCHITECTURE가 담당하므로 결함은 아니나, O-4와 함께 다음 TRD 정리 라운드에서 §3.2 스니펫을 실제 모델로 맞출 때 `syncStatus`(기기 로컬, `@JsonKey(includeToJson:false, includeFromJson:false)`, 기본값 `local`)를 반드시 포함할 것.
- nit: PRD 변경 이력 표에서 v1.9 행이 v1.7 행 위에 삽입돼 시간순이 아니다(v1.8도 이미 같은 상태 — 사전 존재).
