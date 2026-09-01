# TR-08 오프라인 동기화 E2E 통합 검증 (A-5)

- 일자: 2026-09-01
- 담당: qa-integration-tester
- 대상 수용 기준: PRD §5.1 TR-08 "오프라인 기록 → 복귀 시 자동 동기화 / 네트워크 없이 기록 후 100% 업로드", PRD §6 "기록 손실 0건", TRD §14 "손실률 0.1% 미만"
- 근거 문서: PRD §5.1·§5.2·§8.4, ARCHITECTURE §9(오프라인 우선 동기화 전략)·§5.4, TRD §4.4·§6.0·§9
- 코드 수정: **없음** (아래 finding은 전부 설계·정책 수준이라 단독 판단으로 고치지 않았다). 추가한 것은 `test/sync/` 두 파일뿐.

---

## 1. 추적한 동기화 경로

### 1.1 텍스트 다이어그램

```
[러닝 종료]
 TrackingPage._stop()                       tracking_page.dart:194
   └ TrackingController.stop()              tracking_providers.dart:150
       ├ RunTrackingService.stop() → RunRecord(status: completed)
       ├ RunRepository.save(record)  ←──── ⚠️ 여기서 업로드까지 await한다 (C-4)
       │   LocalRunRepository.save()        local_run_repository.dart:78
       │     ① isFinal = status == completed
       │        localStatus = completed ? pending : local
       │     ② _writeLocal(record.copyWith(syncStatus: localStatus))   :91
       │        → drift `run_record_rows` INSERT OR REPLACE
       │          (id / user_id / started_at / status / sync_status /
       │           summary_json / samples_json / updated_at_local)
       │     ③ isFinal이면 _push(record)                               :120
       └ _runCompletionBus.add(record)  → 뱃지·축하·공유 게이트 소비

[업로드 1회 시도] LocalRunRepository._push()                            :120
   payload = _remotePayload(record)                                     :135
     = record.toJson()  (FieldRename.snake)
       − _serverOwnedKeys {avg_pace_sec_per_km, awarded_xp,
                           created_at, updated_at, is_flagged, flag_reason}
       (sync_status는 @JsonKey(includeToJson:false)로 애초에 없음)
   POST /rest/v1/runs?select=id,avg_pace_sec_per_km,awarded_xp,
                              created_at,updated_at,is_flagged,flag_reason
        Prefer: resolution=merge-duplicates, return=representation
        Accept: application/vnd.pgrst.object+json      ← .single()
   ├ 성공 → applyServerConfirmation(id, confirmed)                      :153
   │          drift 트랜잭션: summary_json 위에 _serverOwnedKeys만 겹쳐 쓰고
   │          sync_status = 'synced', updated_at_local 갱신
   │          (samples_json은 건드리지 않음 = 3,600 샘플 재직렬화 회피)
   │          행이 사라졌으면 아무것도 하지 않는다(되살리지 않음)
   └ 실패(모든 예외) → _markSyncStatus(id, failed)                      :179
                       save()는 여전히 성공으로 끝난다

[네트워크 복귀 감지 = 3가지 신호]  RunSyncCoordinator                    run_sync_coordinator.dart:26
   ① currentUserIdProvider null→non-null (로그인 성공)                   :31
   ② AppLifecycleListener.onResume (백그라운드→포그라운드)                :28
   ③ Timer.periodic(2분) 폴백                                            :29
   ※ connectivity_plus 등 실제 연결 감지 없음. 앱이 살아 있어야만 동작.
   → _trySync()                                                          :47
        if (_syncing || userId == null) return;   ← 재진입 래치
        _syncing = true → syncPending() → finally _syncing = false

[재시도] LocalRunRepository.syncPending()                                :186
   SELECT * FROM run_record_rows
    WHERE status = 'completed' AND sync_status <> 'synced'
    ORDER BY started_at ASC
   for each row → runRecordFromRow(row, includeSamples: true) → _push()
   반환값 = 성공 건수. 실패건은 failed로 남아 다음 신호에서 다시 시도.
   ※ user_id 필터 없음 (C-5), 재시도 상한/백오프 없음 (L-3)

[서버측] trg_runs_guard (BEFORE INSERT/UPDATE)   05_server_guards.sql + 마이그 39-6, 51-2
   - INSERT: created_at 보정, avg_pace 재계산, validate_run → is_flagged/flag_reason,
             compute_run_xp → awarded_xp
   - UPDATE(터미널 상태 행): new := old 후 title/note만 재적용  ← 멱등 재 upsert의 근거
   AFTER 트리거 3종:
     runs_01_recompute_stats  → recompute_profile_stats + recompute_season_tier (C-1)
     runs_02_challenge_progress
     runs_03_evaluate_badges
   주간 랭킹은 트리거가 아니라 pg_cron refresh_all_leaderboards(anchor=now()) (C-2)
```

### 1.2 상태 전이표

| 국면 | `run_record_rows.status` | `sync_status` | 서버 행 |
|---|---|---|---|
| 트래킹 중 체크포인트 | `recording`/`paused` | `local` | 없음 (업로드 대상 아님) |
| 종료 직후, 업로드 전 | `completed` | `pending` | 없음 |
| 업로드 성공 + 응답 채택 | `completed` | `synced` | 있음 |
| 업로드 실패(오프라인/4xx/응답 파싱 실패) | `completed` | `failed` | 있을 수도, 없을 수도 |
| 폐기 | 행 삭제 | — | 없음 |

`pending`은 **관측하기 어려운 과도 상태**다 — `save()`가 곧바로 `_push()`를 부르고 실패하면 `failed`로 내리므로, 실제 큐에 남는 값은 사실상 `failed`뿐이다. `syncPending()`의 필터는 `<> synced`라 둘 다 잡으므로 동작에는 영향이 없다(C-8 문서 불일치 참조).

### 1.3 관련 파일

| 역할 | 경로 |
|---|---|
| 오프라인 우선 리포지토리 | `lib/features/tracking/data/local_run_repository.dart` |
| 로컬 스키마·행 매퍼 | `lib/features/tracking/data/local_run_database.dart` |
| 재시도 코디네이터 | `lib/core/sync/run_sync_coordinator.dart` |
| 계약(인터페이스) | `lib/core/repositories/run_repository.dart` |
| 앱 수명 결합 | `lib/app.dart:18` (`ref.watch(runSyncCoordinatorProvider)`) |
| 종료 → 저장 호출부 | `lib/features/tracking/data/tracking_providers.dart:150`, `lib/features/tracking/presentation/tracking_page.dart:194`, `:1228`(끊긴 세션 배너) |
| 서버 가드·집계 | `supabase/migrations/…05_server_guards.sql`, `…22_season_tier_recompute.sql`, `…03_leaderboard.sql`, `…51_run_edit_title_note_only.sql` |

---

## 2. Findings

### 2.1 PASS — 자동 테스트로 잠갔다

| ID | 항목 | 근거 |
|---|---|---|
| P-1 | 로컬 우선 저장. 오프라인에서 끝낸 러닝은 거리·시간·samples가 온전히 로컬에 남고, 업로드 실패가 `save()`의 실패로 전파되지 않는다 | `offline_sync_test.dart` "오프라인에서 끝낸 러닝은…" |
| P-2 | **멱등성 CONFIRMED.** 클라 생성 UUID = 서버 PK + `upsert(resolution=merge-duplicates)` → 실패 후 재시도, 심지어 `synced` 상태에서 재전송해도 서버 행은 1개 | 같은 파일 "…서버 행은 하나뿐이다". 서버측 근거: `07_rls.sql:44` 주석, TRD §4.4(터미널 행 `new := old`) |
| P-3 | **페이로드 경계 CONFIRMED.** 전송 키 전부 snake_case, 키 집합 ⊆ `runs` 컬럼(마이그 01+36+39), 서버 소유 6개 컬럼 + `sync_status` 미전송 | "업로드 페이로드는 runs 컬럼 집합 안에…", "서버 소유 컬럼은 페이로드에서 제외된다" |
| P-4 | 부분 실패 격리. 큐 가운데 1건이 4xx로 거부돼도 뒤 건이 막히지 않고(head-of-line blocking 없음), 실패건만 큐에 남아 다음 라운드에 올라간다 | "한 건이 실패해도 나머지는…" |
| P-5 | 큐 순서 = `started_at` 오름차순(오래된 기록 우선) | "큐는 startedAt 오름차순…" |
| P-6 | **앱 강제종료 후 재기동 큐 복구 CONFIRMED.** `sync_status`가 drift 전용 컬럼으로 영속되므로 새 리포지토리 인스턴스가 메모리 상태 없이 큐를 복원하고, samples도 함께 올라간다 | "앱 강제종료 후 새 인스턴스가…" |
| P-7 | 미완결(`recording`/`paused`) 체크포인트는 업로드도 큐 대상도 아니다 — 서버 `validate_run`이 미완결 기록을 평가하지 않는다 | "미완결(recording) 체크포인트는…" |
| P-8 | **RunSample 배치 없음이 의도대로다.** 120샘플 세션이 요청 1건으로 전송되고, 샘플 키도 전부 snake_case. 응답은 `_confirmationColumns`로 좁혀 samples를 되받지 않는다 | "samples는 배치로 쪼개지 않고…" (ARCHITECTURE §9 "세션 단위 한 트랜잭션"과 일치) |
| P-9 | 응답 채택 실패(200이지만 `.single()` 계약 위반)에도 큐가 망가지지 않고, 재시도가 중복 행 없이 수렴 | "응답 채택이 실패해도 큐가…" |
| P-10 | 서버 확정값 역방향 반영. 클라이언트 낙관값(`avg_pace_sec_per_km=350`)이 서버값으로 교체되고 `is_flagged`가 `null`→`false`로 확정되어 공유 게이트가 열린다 | "업로드 성공 응답의 서버 확정값이…" (+ 기존 `run_push_confirmation_test.dart`) |
| P-11 | 코디네이터 발화 조건: 게스트 무발화 / 로그인 전이 발화 / 진행 중 중복 발화 차단 / 예외가 래치를 걸지 않음 | `run_sync_coordinator_test.dart` |

### 2.2 CONFIRMED — 코드로 확인된 결함·위험

#### C-1 (High) 시즌 경계를 넘겨 업로드된 오프라인 기록은 티어에 **영구 미반영**
`supabase/migrations/20260821150300_22_season_tier_recompute.sql:53-101`

`recompute_season_tier(user_id, now())`는 (a) 시즌이 바뀌었으면 이전 시즌을 `season_histories`에 `on conflict (user_id, season_id) do nothing`으로 **한 번만** 마감하고, (b) 현재 시즌 거리를 `started_at >= v_start`로 합산한다. 시즌 마지막 날 오프라인으로 뛴 기록을 다음 시즌 첫날에 업로드하면 — (a)는 이미 마감돼 갱신되지 않고, (b)는 `started_at`이 창 밖이라 제외된다. **러닝 데이터는 남지만 티어 누적 거리에서 사라진다.** PRD §1.4 "티어는 절대평가 = 시즌 누적 거리"와 어긋난다.

같은 이유로 `season_histories.distance_meters`(마감 시점 `profiles.season_distance_meters` 스냅샷)도 그 기록을 포함하지 않는다.

#### C-2 (High) 지난 주 기록을 뒤늦게 올리면 그 주 랭킹에 들어가지 않는다
`supabase/migrations/20260819140300_03_leaderboard.sql:97`, `…15_pg_cron_schedule.sql:13`

`refresh_leaderboard(..., p_anchor default now())`는 앵커가 속한 **한 기간만** 재집계한다. 갱신 진입점은 pg_cron의 `select public.refresh_all_leaderboards();`(앵커=now())뿐이고, `runs` AFTER 트리거는 랭킹을 건드리지 않는다. 일요일 밤 오프라인 러닝을 월요일에 업로드하면 그 주 `leaderboard_entries`는 영원히 갱신되지 않는다(주간 랭킹은 PRD §5.3의 P0 핵심 루프이고, `season_histories.best_weekly_rank`에도 파급된다).

#### C-3 (High) HTTP 타임아웃 부재 + 재진입 래치 → 멈춘 연결 하나가 큐를 앱 수명 동안 정지시킨다
`lib/core/sync/run_sync_coordinator.dart:45-57`, `lib/core/api/supabase_client.dart`

`Supabase.initialize`에 `httpClient`/타임아웃 설정이 없고 `_push()`에도 `.timeout()`이 없다. 스탈된 TCP 연결(캡티브 포털·지하철 셀 전환 등 "연결은 됐는데 응답이 없는" 구간)에서 `syncPending()`이 반환하지 않으면 `_syncing`이 `true`로 고정되고, 이후 로그인·앱 복귀·2분 타이머 발화가 **전부 조용히 무시된다**. 비행기 모드처럼 즉시 실패하는 경우는 해당 없음.
→ `run_sync_coordinator_test.dart`의 `[특성]` 테스트가 현재 동작을 고정해 두었다. 타임아웃이 도입되면 그 테스트가 깨지는 것이 정상이다.

#### C-4 (Medium) 러닝 종료 UI가 업로드 완료까지 블로킹된다
`lib/features/tracking/presentation/tracking_page.dart:194-218` → `tracking_providers.dart:150` → `local_run_repository.dart:78-88`

`_stop()`은 `await stop()`, `stop()`은 `await save()`, `save()`는 `await _push()`다. 즉 **요약 화면이 뜨는 시점이 서버 응답에 묶여 있다.** C-3과 겹치면 종료 버튼이 `_busy=true`로 무한 대기한다. "로컬 저장 후 업로드는 실패해도 무해"라는 설계 의도와 UI 흐름이 어긋난 지점 — 로컬 쓰기(②)까지만 await하고 `_push()`는 fire-and-forget으로 돌려도 계약상 안전하다(실패 시 `failed`로 남고 코디네이터가 재시도).

#### C-5 (Medium) `syncPending()`에 `user_id` 필터가 없다
`lib/features/tracking/data/local_run_repository.dart:186-196`

쿼리 조건은 `status = completed AND sync_status <> synced`뿐이다. 한 기기에서 계정을 바꾸면 이전 계정의 미업로드 행이 현재 세션 JWT로 전송되고, RLS `runs_insert_own`/`runs_update_own`(`user_id = auth.uid()`)에 걸려 42501로 **영구 실패**한다. 그 행은 절대 `synced`가 되지 않으므로 2분마다 무한 재시도 대상으로 남는다(데이터 손실은 아니나 배터리·트래픽·로그 오염). 코디네이터가 `currentUserIdProvider`를 이미 읽고 있으므로 `syncPending({String? userId})`로 좁히는 것이 자연스럽다.

#### C-6 (Medium) 오프라인 중 **이미 업로드된** 기록의 제목·메모 편집은 큐잉되지 않고 소실된다
`lib/features/tracking/data/local_run_repository.dart:234-268`

`updateMeta()`는 `sync_status == synced`이면 서버 UPDATE 경로로 가고, 오프라인이면 `guardSupabase`가 `Failure.network`를 던져 **로컬에도 쓰지 않는다.** 미업로드 기록(오프라인 저장분)은 로컬 편집으로 처리하는 분기가 이미 있으므로(주석 "QA C-1"), 대칭이 깨져 있다. TR-08의 문언("기록 업로드")을 벗어나지만 같은 오프라인 국면의 사용자 경험이다. 큐잉하려면 `sync_status`를 되돌려야 하는데 그러면 3,600 샘플 재전송이 발생하므로(코드 주석 :286 참조) 별도 편집 큐가 필요하다 — **설계 결정 필요**.

#### C-7 (Low) 문서 ↔ 구현 불일치: 지수 백오프
`docs/ARCHITECTURE.md:551` 다이어그램은 `재시도 대기(지수 백오프)`라고 쓰여 있으나, 구현은 **고정 2분 주기 + 로그인/앱 복귀 이벤트**다. 백오프는 없다. ARCHITECTURE §9를 실제 전략(3신호 + 고정 주기)으로 갱신해야 한다. 또한 같은 절이 전제하는 "네트워크 있음/없음" 분기는 실제로 **감지되지 않는다**(C-9).

#### C-8 (Low) 문서 ↔ 구현 불일치: 실패 후 잔류 상태
`lib/features/tracking/data/local_run_repository.dart:18`의 클래스 주석은 "실패하면 로컬에 `SyncStatus.pending`으로 남고"라 쓰여 있으나 `_push()`는 `SyncStatus.failed`로 내린다(:130). `RunSyncCoordinator` 헤더 주석(:12)은 `failed`로 맞게 쓰여 있어 두 주석이 서로 어긋난다. 동작에는 영향 없음(필터가 `<> synced`).

#### C-9 (Medium) 실제 연결 복구 감지가 없다 — "100% 업로드"는 사용자 재방문에 의존한다
`lib/core/sync/run_sync_coordinator.dart:16-25`가 의도를 명시하고 있는 대로, `connectivity_plus` 같은 연결 감지도, 백그라운드 작업(WorkManager / BGTaskScheduler)도 없다. 앱이 포그라운드에 없으면 재시도가 아예 돌지 않으므로, **지하 주차장에서 러닝을 끝내고 앱을 다시 열지 않은 사용자의 기록은 업로드되지 않은 채로 남는다.** 데이터는 로컬에 안전하지만 TR-08 수용 기준("복귀 시 자동 동기화")을 문언 그대로 만족한다고 말하려면 이 전제를 명시해야 한다.
※ 앱이 켜져 있는 상태의 복귀는 최대 2분 지연으로 커버된다 — 이 부분은 허용 가능.

### 2.3 PLAUSIBLE — 코드만으로는 단정 불가, 계측 필요

| ID | 내용 | 확인 방법 |
|---|---|---|
| L-1 | **대용량 samples 단일 요청이 손실률 0.1%의 실질 리스크.** 1시간 러닝 ≈ 3,600 샘플 ≈ 압축 전 0.5~1MB를 한 요청으로 보낸다(P-8은 이게 *설계대로*임을 확인했을 뿐 성공률을 보증하지 않는다). 저대역/불안정 셀에서 반복 실패하면 재시도해도 계속 실패한다. 청크 업로드도, gzip 요청 압축 설정도, 서버측 body size 확인도 없다 | 실기기에서 3G/저품질 네트워크 시뮬레이션으로 60분 러닝 업로드 성공률 측정(수동 체크리스트 M-4) |
| L-2 | 재시도 상한이 없어, 서버가 영구 거부하는 행(CHECK 위반 등)을 2분마다 무한 재시도한다. 현재 알려진 영구 거부 케이스는 C-5(계정 전환)뿐 | 실패 횟수 컬럼 추가 후 로그 관측 |
| L-3 | 로컬 행에 보존 정책이 없다. `synced` 후에도 samples 포함 행이 무기한 남아 SQLite가 계속 커진다(손실 위험은 아님, 저장 공간 이슈) | 장기 사용 기기의 `runnit_runs.sqlite` 크기 측정 |
| L-4 | 오프라인 중에는 뱃지·티어·XP 판정이 전부 지연된다(서버 트리거가 유일한 판정 주체). 업로드 시점에 며칠치 축하 알림이 한꺼번에 터질 수 있다 — 판정 자체는 정확하나 UX 이슈. C-1/C-2와 달리 값 손실은 없다 | 수동 체크리스트 M-6 |

### 2.4 재현 불가 / 검증 범위 밖

- `_syncing` 래치의 실제 데드락(C-3)은 코드상 확실하나 **자동 테스트로 실네트워크 스톨을 재현하지 않았다** — 특성 테스트로 동작만 고정했다.
- Supabase 원격 인스턴스에 대한 실제 RLS·트리거 왕복은 이 검증 범위 밖이다(가짜 PostgREST로 클라이언트 계약만 검증). C-1/C-2는 마이그레이션 SQL 정독 결과이며 **실 DB에서 재현 검증은 하지 않았다**.

---

## 3. 추가한 테스트

| 파일 | 테스트 | 수 |
|---|---|---|
| `test/sync/offline_sync_test.dart` | 가짜 PostgREST(`HttpServer` 실서버) 위에서 `save()`/`_push()`/`syncPending()`의 **HTTP 경로 전체**를 검증. 오프라인 저장→복귀→업로드→큐 비움, 서버 확정값 역반영, 멱등 재전송, 응답 채택 실패 후 수렴, 부분 실패 격리, 큐 정렬, 앱 재기동 복구, 미완결 체크포인트 제외, 페이로드 컬럼 집합·snake_case, 서버 소유 컬럼 제외, samples 세션 단위 전송 | 11 |
| `test/sync/run_sync_coordinator_test.dart` | Fake `RunRepository` + `ProviderContainer`로 코디네이터 발화 조건 검증. 게스트 무발화, 초기 로그인 상태 즉시 발화, 게스트→로그인 전이 발화, 재진입 래치, 예외가 래치를 걸지 않음, **[특성] 타임아웃 부재로 인한 영구 정지**(C-3 고정) | 6 |

**가짜 서버를 세운 이유**: 목 클라이언트로 페이로드를 검증하면 `toJson()`으로 만든 값을 `toJson()`으로 비교하는 순환이 된다. 실제로 무엇이 직렬화되어 나가는지는 HTTP 바이트에서만 관찰할 수 있고, 그래야 `runs` 컬럼 집합과의 경계 검증(P-3)이 의미를 갖는다. `_runsColumns` 상수는 마이그레이션 01+36+39에서 옮겨 둔 것으로, **모델에 필드를 추가하면서 마이그레이션을 빠뜨리면 이 테스트가 깨진다** — 그게 이 상수의 목적이다.

검증 결과:
```
flutter analyze  → No issues found!
flutter test     → All tests passed!  (252 → 269, +17)
git status       → test/sync/ 만 신규. lib/ 수정 없음.
```

---

## 4. 수동 검증 체크리스트 (실기기·실네트워크 전용)

> 실행 전제: 테스트 계정 로그인, `--dart-define-from-file=env/dev.json`, 원격 Supabase 연결.

| ID | 시나리오 | 절차 | 합격 기준 |
|---|---|---|---|
| M-1 | 비행기모드 러닝 | 비행기모드 ON → 5분 이상 러닝 → 종료 | 요약 화면이 **지연 없이** 뜬다(C-4 확인 지점). 히스토리에 기록이 보인다 |
| M-2 | 복귀 자동 동기화 | M-1 직후 비행기모드 OFF → 앱을 백그라운드로 보냈다가 다시 연다 | 30초 내 히스토리 항목이 동기화 상태로 바뀐다. Supabase `runs`에 행 1개 |
| M-3 | 앱 강제종료 후 복구 | M-1 직후 앱 강제종료 → 비행기모드 OFF → 앱 재실행 | 로그인 직후 자동 업로드. 서버 행 1개, 중복 없음 |
| M-4 | **60분 연속 추적 중 네트워크 단절** (L-1) | 60분 러닝. 중간에 비행기모드 3회 토글 → 종료 후 온라인 | 샘플 수 유실 0. 업로드 1회 성공. 실패 시 재시도 횟수·소요 시간 기록 |
| M-5 | 지하철·지하 주차장 (스톨 재현, C-3) | 신호가 약하지만 "연결됨"인 장소에서 러닝 종료 | 종료 버튼이 30초 이상 멈추지 않는다. 멈추면 C-4/C-3 확정 재현 |
| M-6 | 오프라인 뱃지·티어 지연 (L-4) | 뱃지 조건을 충족하는 러닝을 오프라인으로 3건 → 한꺼번에 온라인 | 뱃지·티어·XP가 전부 정확히 반영. 축하/알림 폭주 UX 확인 |
| M-7 | **시즌 경계 넘김** (C-1) | 시즌 마지막 날 오프라인 러닝 → 다음 시즌 첫날 업로드 (스테이징에서 `season_id_at` 조작 필요) | 이전 시즌 `season_histories.distance_meters`에 반영되는지 확인. **현재 코드로는 실패 예상** |
| M-8 | **주 경계 넘김** (C-2) | 일요일 23:30 오프라인 러닝 → 월요일 업로드 | 지난 주 랭킹에 반영되는지. **현재 코드로는 실패 예상** |
| M-9 | 계정 전환 (C-5) | A 계정 오프라인 러닝 미업로드 상태 → 로그아웃 → B 계정 로그인 | B 세션에서 A의 행을 전송해 42501이 반복되는지 로그 확인 |
| M-10 | 오프라인 메모 편집 (C-6) | 이미 동기화된 러닝 상세 → 비행기모드 → 메모 수정 → 저장 | 실패 안내가 뜨는지, 조용히 사라지는지 확인 |
| M-11 | 배터리 최적화 킬 | Android 제조사 배터리 최적화 ON 상태로 러닝 중 프로세스 킬 → 재실행 | 미완결 세션 배너 노출 → "기록으로 저장" → 정상 업로드 |

---

## 5. 코드 수정이 필요한 항목 (우선순위 순)

| 순위 | ID | 제안 | 담당 |
|---|---|---|---|
| 1 | C-1 | `recompute_season_tier`가 **기록의 `started_at`이 속한 시즌**도 함께 재계산하도록 확장하거나, 마감된 `season_histories` 행을 지연 도착 기록으로 갱신하는 경로를 추가. 정책 판단 필요("마감된 시즌은 소급 변경 금지"는 *티어 강등 방지* 취지이므로 누적 거리 가산은 허용 가능한지 PRD 확인) | backend-engineer + 리더(정책) |
| 2 | C-2 | 업로드 AFTER 트리거에서 `refresh_leaderboard('weekly','distance','global',null, new.started_at)`를 호출하거나, cron이 직전 주까지 함께 갱신 | backend-engineer |
| 3 | C-3 | `_push()`/`syncPending()`에 요청 타임아웃(예: 30초·업로드 크기 고려 60초) 부여 + `_syncing` 래치에 워치독 | mobile-architect |
| 4 | C-4 | `save()`의 업로드를 await하지 않거나, `TrackingController.stop()`이 로컬 쓰기까지만 기다리고 업로드는 백그라운드로 넘기도록 분리 | mobile-architect + gps-tracking-engineer |
| 5 | C-5 | `syncPending({String? userId})` — 코디네이터가 현재 사용자로 좁혀 호출 | mobile-architect |
| 6 | C-9 | `connectivity_plus` 도입 또는 백그라운드 동기화(WorkManager/BGTaskScheduler) 검토. 최소한 PRD/ARCHITECTURE에 "앱 재실행 시 동기화" 전제를 명시 | 리더 판단 |
| 7 | C-6 | 오프라인 메타 편집 큐 설계(전체 재 upsert 없이 title/note만 재시도) | mobile-architect + backend-engineer |
| 8 | C-7·C-8 | `docs/ARCHITECTURE.md` §9 다이어그램을 실제 전략(3신호 + 고정 2분, 백오프 없음, 연결 감지 없음)으로 갱신. `local_run_repository.dart:18` 주석의 `pending` → `failed` 정정 | qa/문서 |

---

## 6. 종합 판정

- **클라이언트 오프라인 큐 자체는 견고하다.** 로컬 우선 저장 · 클라 UUID 멱등성 · 부분 실패 격리 · 재기동 복구 · 페이로드 스키마 정합 — 모두 자동 테스트로 확인(P-1~P-11). "기록 손실 0건"은 **로컬 저장 관점에서 PASS**.
- **"100% 업로드"는 조건부다.** 사용자가 앱을 다시 여는 것을 전제한다(C-9). 그리고 스탈된 연결 하나가 큐를 정지시킬 수 있다(C-3).
- **가장 심각한 문제는 업로드 성공 이후에 있다.** 늦게 도착한 기록이 티어(C-1)와 주간 랭킹(C-2)에 반영되지 않는다 — 데이터는 서버에 있으나 PRD §1.4의 핵심 지표에서 조용히 빠진다. TR-08은 "업로드"만 말하지만, 사용자가 체감하는 것은 티어·랭킹이므로 **TR-08의 실질 수용 기준은 이 두 항목을 포함해야 한다.**
