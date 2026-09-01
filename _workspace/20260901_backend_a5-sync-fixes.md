# A-5 오프라인 동기화 findings 수정 (TR-08 후속)

- 일자: 2026-09-01
- 담당: backend-engineer
- 입력: `_workspace/20260901_qa_tr08-offline-sync.md` (A-5 검증 리포트)
- 근거: PRD §5.1 TR-08 · §5.4 · §8.5 · §8.6, ARCHITECTURE §9, TRD §9
- 범위: **클라이언트 동기화 계층 + 문서만.** Supabase 마이그레이션 신규 없음(사용자 정책 확정).

---

## 1. 사용자 확정 정책 — C-1 / C-2는 "수정" 아님

오프라인으로 **시즌·주 경계를 넘겨 뒤늦게 업로드된 기록은 현 시즌/현 주에만 반영**한다
(`started_at` 귀속 규칙은 유지). 마감된 과거 시즌/주는 소급 변경하지 않는다 — PRD §5.4의
"확정 결과 안정성(강등 방지)" 취지이자, 경계 직후 업로드로 지난 주 순위를 뒤집는 부정행위
벡터를 열지 않기 위해서다.

→ **소급 반영 마이그레이션을 만들지 않았다.** 대신 "알려진 제약"으로 문서에 못 박았다
(ARCHITECTURE §9.1 신설, TRD §9 항목 추가). 러닝·거리·뱃지·XP는 정상 반영되므로 데이터
손실은 없고, 잃는 것은 그 기록이 속했던 과거 구간의 티어 누적·주간 순위 반영뿐이다.

---

## 2. 항목별 처리

### C-3 (High) 업로드 HTTP 타임아웃 부재 → **수정**

`LocalRunRepository`에 생성자 인자 `uploadTimeout`(기본 30초) 추가, `_push()`의 PostgREST
왕복에 `.timeout()`을 건다. 타임아웃은 다른 실패와 동일하게 `sync_status = failed`로 흡수되고
다음 재시도 신호에서 다시 올라간다.

- 30초 근거: 1시간 러닝 ≈ 3,600 샘플(압축 전 0.5~1MB)을 저대역에서 올리는 시간.
- `.timeout()`은 **이미 나간 요청을 취소하지 못한다**(소켓은 SDK가 쥐고 있다). 끊기는 것은
  우리 쪽 대기뿐이며, 업로드가 멱등이라 늦게 도착한 요청이 성공해도 중복 행이 생기지 않는다.
- 빌더(`PostgrestTransformBuilder`)는 `Future`를 *구현*할 뿐이라 `_upsertRemote()` async
  함수로 감싼 뒤 타임아웃을 걸었다.
- **래치 해제 위치**: 코디네이터의 `_syncing`은 `finally`에서만 풀린다. 즉 `syncPending()`이
  반드시 끝나야 하고, 그 보장을 한 계층 아래 타임아웃이 한다. 코디네이터에 워치독을 **추가하지
  않았다** — 두면 같은 기록을 두 번 밀어 올리게 된다(이 판단을 코드 주석과 특성 테스트에 기록).

### C-4 (Medium) 종료 UI 블로킹 → **수정 (sync 계층에서만)**

`save()`가 로컬 쓰기까지만 await하고 업로드는 `_schedulePush()`로 넘긴다.
`TrackingController.stop()` / `TrackingPage._stop()`은 **한 줄도 건드리지 않았다** —
gps-tracking-engineer 영역과 겹치지 않게 리포지토리 계약 변경만으로 해결했다.

- 백그라운드 업로드는 `_uploads` 체인으로 **직렬화**한다(연달아 저장된 기록이 동시에 3,600
  샘플씩 밀어 올리지 않도록).
- 체인은 아무도 await하지 않으므로 예외를 삼킨다. `_push()`가 이미 업로드 실패를 전부
  `failed`로 흡수하고, 그 뒤에 던질 수 있는 것은 로컬 DB가 닫힌 경우(앱 종료)뿐이다.
- 테스트 관측점: `@visibleForTesting Future<void> get uploadSettled`.
  기존 `offline_sync_test.dart`는 `saveAndSettle()` 헬퍼를 거치도록만 바꿨고 **단언은
  한 줄도 약화하지 않았다**(11개 전부 그대로 통과).

### C-5 (Medium) 계정 전환 시 42501 영구 재시도 → **수정**

`RunRepository.syncPending({String? userId})`로 계약 확장, `LocalRunRepository`가 drift
쿼리에 `user_id` 조건을 더한다. `RunSyncCoordinator`는 항상 현재 `currentUserIdProvider`
값으로 좁혀 호출한다.

- 이전 계정 행은 **지우지 않는다** — 그 계정으로 다시 로그인하면 그대로 올라간다(데이터 보존
  우선). 테스트로 이 대칭을 잠갔다.
- 인터페이스 변경이라 fake 구현 3곳(`run_detail_page_test` / `tracking_page_test` /
  `run_sync_coordinator_test`) 시그니처를 함께 갱신.

### C-9 (Medium) 실제 연결 감지 부재 → **부분 수정**

`connectivity_plus: ^7.3.1` 추가 + `connectivityRestoredProvider`(오프라인→온라인 **전환**만
흘리는 스트림) 신설, 코디네이터가 이 이벤트에서 `syncPending()`을 건다. 재시도 신호는 3종 →
**4종**(로그인 전이 / 앱 복귀 / 연결 회복 / 2분 주기).

- `onConnectivityChanged`는 인터페이스가 바뀔 때마다 발화하므로 직전 상태를 기억해 전환만
  통과시킨다. 앱 시작 직후 첫 이벤트를 "회복"으로 오인하지 않도록 초기값을 online으로 둔다.
- 연결 감지는 **보조 신호**다 — "연결됨"이 도달 가능을 뜻하지 않으므로(캡티브 포털) 기존
  3신호를 대체하지 않는다. 구독 실패(플러그인 미등록 등)는 삼켜 나머지 신호로 계속 동작한다.
- provider로 분리한 이유는 테스트 주입(플랫폼 채널 회피).
- **범위 밖(TODO 유지)**: 백그라운드 동기화(WorkManager / BGTaskScheduler). 코디네이터
  헤더에 `TODO(sync)`로 남기고, ARCHITECTURE §9에 "앱이 살아 있어야만 재시도가 돈다"를
  명시적 전제로 기록했다.

### C-7 / C-8 문서·주석 드리프트 → **수정**

- ARCHITECTURE §9 mermaid에서 `재시도 대기(지수 백오프)` 제거. 실제 전략(고정 2분 + 4신호,
  타임아웃 30초, `failed` 잔류)을 반영한 다이어그램으로 교체.
- `local_run_repository.dart` 클래스 주석의 "실패하면 `SyncStatus.pending`으로 남고" →
  `failed`로 정정 + 저장 순서 계약을 새 동작(로컬까지만 await)으로 다시 씀.

### 손대지 않은 것

- **C-6**(오프라인 중 이미 업로드된 기록의 메모 편집 소실): 별도 편집 큐 설계가 필요한
  **설계 결정** 항목이라 이번 범위 밖. `sync_status`를 되돌리는 방식은 3,600 샘플 재전송을
  부르므로 채택 불가.
- **L-1**(대용량 samples 단일 요청), **L-2**(재시도 상한), **L-3**(로컬 보존 정책): 계측
  선행 필요.

---

## 3. 변경 파일

| 파일 | 변경 |
|---|---|
| `lib/features/tracking/data/local_run_repository.dart` | `uploadTimeout` 생성자 인자·`_upsertRemote()`·`_push()` 타임아웃, `save()` fire-and-forget + `_schedulePush`/`uploadSettled`, `syncPending({userId})` 필터, 클래스 주석 정정 |
| `lib/core/repositories/run_repository.dart` | `save()` 계약 주석(로컬까지만 보장), `syncPending({String? userId})` 시그니처·계약 |
| `lib/core/sync/run_sync_coordinator.dart` | 연결 회복 신호(4번째) 구독, `syncPending(userId:)` 호출, 래치 주석, 백그라운드 동기화 TODO |
| `pubspec.yaml` | `connectivity_plus: ^7.3.1` (+ 채택 근거 주석) |
| `test/sync/offline_sync_test.dart` | `saveAndSettle` 헬퍼, 가짜 서버 `hang`(스탈 연결) 모드, 신규 3건 |
| `test/sync/run_sync_coordinator_test.dart` | 연결 스트림 override, 신규 3건, 특성 테스트 재해석 |
| `test/history/run_detail_page_test.dart`, `test/tracking/tracking_page_test.dart` | fake `syncPending` 시그니처 |
| `docs/ARCHITECTURE.md` | §9 다이어그램·재시도 전략 재작성, **§9.1 알려진 제약 신설**, 변경 이력 v0.13 |
| `docs/TRD.md` | §9 "알려진 제약 — 경계를 넘긴 지각 업로드", 변경 이력 v0.19 |

## 4. 추가한 테스트 (6건)

| 파일 | 테스트 | 잠그는 것 |
|---|---|---|
| `offline_sync_test.dart` | 응답이 오지 않는 연결은 uploadTimeout에서 끊기고 큐가 계속 돈다 | C-3. 가짜 서버가 응답을 쓰지도 닫지도 않는 **스탈 연결**을 재현한다 — 타임아웃이 없으면 이 테스트는 영원히 끝나지 않는다 |
| | save()는 업로드 응답을 기다리지 않는다 (요약 화면 비차단) | C-4. 스탈 상태에서도 `save()`가 500ms 안에 반환하고, 로컬 데이터(거리·samples)가 온전하다 |
| | syncPending(userId:)는 현재 계정 행만 올린다 (계정 전환) | C-5. 다른 계정 행은 전송되지 않고, **지워지지도 않는다**(재로그인 시 업로드) |
| `run_sync_coordinator_test.dart` | 타임아웃으로 끝난 동기화 뒤에도 다음 신호가 발화한다 | C-3 코디네이터 측 계약(래치 해제) |
| | 오프라인 → 온라인 전환에서 동기화가 발화한다 | C-9 |
| | 현재 로그인 사용자로 좁혀 호출한다 | C-5 호출부 |

기존 `[특성] 끝나지 않는 요청은 이후 모든 발화를 영구히 막는다 (타임아웃 없음)`는
`[특성] 코디네이터 래치 자체에는 워치독이 없다`로 재해석했다 — 단언(`syncCalls == 1`)은
그대로이고, 그것이 **버그가 아니라 계층 분담**(타임아웃은 리포지토리 계층)임을 기록한다.

## 5. 검증

```
flutter analyze  → No issues found!
flutter test     → All tests passed!  (269 → 275, +6)
git status       → 커밋하지 않음
```

⚠️ `pubspec.lock`은 `.gitignore` 대상이라 변경 목록에 뜨지 않는다. 다른 개발자/CI는
`flutter pub get`으로 `connectivity_plus`를 받는다.

## 6. 남은 이슈

| ID | 내용 | 상태 |
|---|---|---|
| C-1·C-2 | 경계 넘긴 지각 업로드의 과거 시즌/주 미반영 | **정책상 유지.** 문서화 완료(ARCHITECTURE §9.1 / TRD §9). 사용자 안내 UX(업로드 대기 배지)는 P2 |
| C-6 | 오프라인 중 이미 업로드된 기록의 메모 편집 소실 | 미해결. 편집 전용 큐 설계 필요(mobile-architect + backend) |
| C-9 잔여 | 백그라운드 동기화(WorkManager / BGTaskScheduler) | 범위 밖. `TODO(sync)` + ARCHITECTURE §9 전제로 기록 |
| L-1 | 대용량 samples 단일 요청 성공률 | 실기기 계측 필요(수동 체크리스트 M-4). 청크/gzip 미도입 |
| L-2 | 재시도 상한 없음 | C-5 해소로 알려진 영구 거부 케이스는 사라졌으나 상한 자체는 없음 |
| L-3 | 로컬 행 보존 정책 없음 | `synced` 후에도 samples 포함 행이 무기한 잔류 |
| 실기기 | M-1·M-2·M-5(스탈 재현), M-9(계정 전환) | 이번 수정의 실환경 확인은 수동 체크리스트로 남는다 |
