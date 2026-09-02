# 미업로드 기록 "동기화 대기" 안내 (ARCHITECTURE §9.1 P2 과제 마감)

작성일: 2026-09-02 / 담당: flutter-ui-designer / 근거: PRD v1.9 TR-08·§10.1 #13, ARCHITECTURE v0.19 §9.1

## 배경

서버는 오프라인으로 시즌·주 경계를 넘겨 지각 업로드된 기록을 **과거 구간에 소급 반영하지 않는다**(정책, 버그 아님). 기록·거리·뱃지·XP는 손실되지 않지만 그 기록이 속했던 과거 시즌의 티어 누적과 주간 순위 반영은 잃는다. 서버 로직은 그대로 두고, 사용자가 **아직 손을 쓸 수 있는 시점(업로드 전)** 에 그 사실을 알도록 UI만 추가했다.

## 변경 파일

| 파일 | 변경 |
|---|---|
| `lib/features/history/presentation/sync_pending.dart` | **신설.** 단일 술어 `isSyncPending(record)` = `status == completed && syncStatus != synced` |
| `lib/features/history/presentation/run_detail_page.dart` | `_SyncPendingBanner` 신설 + 제목 아래·지도 위 배치. flagged 배너와 `else if`로 배타 |
| `lib/features/history/presentation/widgets/run_tile.dart` | `_SyncPendingChip`(앰버 pill "동기화 대기") 신설 + 날짜 라벨 아래 배치 |
| `lib/features/tracking/data/local_run_repository.dart` | `_fromRemote`가 `syncStatus: synced` 확정 — 오탐 수정(아래) |
| `test/history/run_detail_page_test.dart` | 케이스 5개 추가, 헬퍼 `run()`에 `syncStatus`/`status` 파라미터 |
| `docs/ARCHITECTURE.md` | §9.1 "P2 과제로 남긴다" → 구현 완료 + 화면별 표 + 함정 경고. v0.19 변경이력 |
| `docs/PRD.md` | TR-08 수용 기준 한 줄, §10.1 #13, v1.9 변경이력 |

## 판단

**1. 우선순위 — flagged가 이긴다.** 두 배너를 겹쳐 띄우지 않는다. 검토 대상 기록은 이미 업로드된 상태라 원래 동시에 성립하기 어렵고, 겹칠 경우 사용자가 먼저 알아야 할 쪽은 "반영되지 않았다"는 **확정된 사실**이지 "아직 안 올라갔다"는 진행 상태가 아니다.

**2. 대상을 `completed`로 좁힌 이유.** `RunRecord.syncStatus`의 모델 기본값은 `local`이라, 상태로 좁히지 않으면 `recording`/`paused`/`discarded` 행까지 전부 "동기화 대기"가 된다. 그것들은 애초에 업로드 대상이 아니다.

**3. 톤 — 경고가 아니라 안내.** 앰버 info 박스(`_FlaggedBanner`와 동일 토큰: `#FFF4E5` 배경, `#8A5A00` 잉크, `rMd`, `s12` 패딩, `info_outline` 18px)를 쓰되 문구는 손실을 강조하지 않는다. 실제로 잃는 것이 없고 사용자가 할 일도 "네트워크에 연결한다"뿐이기 때문. `failed`일 때만 "업로드에 실패해 다시 시도하고 있어요"로 사실을 맞춘다 — 재시도는 코디네이터가 자동으로 돌리므로(§9의 4신호) 사용자 행동 요구는 같다.

**4. 목록 칩은 날짜 "옆"이 아니라 "아래".** 왼쪽 열은 통계 3개와 chevron이 남긴 공간이라, 320pt 폰에서 날짜(`2026.08.27 (목)`)와 칩을 한 줄에 넣으면 넘친다. 아래 배치는 미동기화 행에서만 높이가 늘고 chevron·stat 레이아웃을 건드리지 않는다.

**5. 발견한 오탐 — `_fromRemote`.** `syncStatus`는 기기 로컬 컬럼이라 서버 응답에 없고 모델 기본값이 `local`이다. `LocalRunRepository._fromRemote`는 이 값을 확정하지 않은 채 레코드를 반환했다(로컬 캐시 쓰기 경로만 `copyWith(synced)`를 했다). 이 배너를 붙이기 전에는 아무도 그 필드를 화면에서 읽지 않아 무해했지만, 이제는 **다른 기기에서 기록해 원격으로만 조회되는 러닝이 "동기화 대기"로 보인다.** `_fromRemote`가 `synced`를 확정하도록 수정. 원격에 행이 있다는 것이 곧 업로드 완료다.

## 테스트

`test/history/run_detail_page_test.dart` 추가 5건:
- synced 완료 러닝 → 배너 없음
- `local`·`pending` 완료 러닝 → 배너 표출 + 티어·랭킹 문구, 재시도 문구는 없음 (각각)
- `failed` → 재시도 문구까지
- flagged + `failed` → flagged 배너만, 동기화 배너 없음

기존 케이스 보존을 위해 헬퍼 `run()`의 `syncStatus` 기본값을 `synced`로 뒀다(모델 기본값 `local`을 그대로 쓰면 모든 케이스에 배너가 따라붙어 검증 대상이 흐려진다).

## 결과 (1차)

- `flutter analyze` — **No issues found**
- `flutter test` — **284/284 통과** (신규 5건 포함)

> 이 워크트리에는 freezed/drift 생성 파일이 없어 최초 analyze가 581 error였다. `flutter pub get` + `dart run build_runner build --delete-conflicting-outputs` 후 클린. 코드 변경과 무관한 환경 이슈.

---

# 증분 QA 관찰 3건 반영 (2026-09-02, 2차)

차단 결함 0건. 관찰 O-1·O-2·O-3 모두 반영했다.

## O-1 — `syncStatus` 확정 지점 중복 제거

`findById`의 원격 폴백에서 `_writeLocal(record.copyWith(syncStatus: synced))` → `_writeLocal(record)`. `_fromRemote`가 이미 `synced`로 확정하므로 중복이었다. `_writeLocal`은 `record.toRow()`가 `syncStatusWire(record.syncStatus)`를 그대로 쓰므로 동작 동일. `_fromRemote`가 단일 진원지라는 주석을 호출부에 남겼다.

## O-2 — 오탐 회귀 가드 신설

`test/tracking/find_by_id_remote_sync_status_test.dart` (신규 2건).

기존 `find_by_id_samples_cache_test.dart`에 한 줄 추가하는 방식은 **불가능**했다 — 그 파일은 원격을 `http://127.0.0.1:1`(도달 불가)로 두고 "원격을 시도했는가"를 예외 발생으로만 관찰한다. 성공 응답 경로를 아예 타지 않아 `syncStatus`를 볼 수 없다. 그래서 응답을 stub하는 별도 파일을 신설했다.

- `MockClient`로 PostgREST 응답을 주입(`SupabaseClient(..., httpClient:)`). 이를 위해 `http`를 **dev_dependencies에 추가** — supabase가 이미 전이 의존으로 끌고 있어 해석 위험은 없다.
- stub 응답 JSON에 **`sync_status` 키를 넣지 않는다.** 그게 결함의 조건이다(서버에 없는 컬럼 + 모델 기본값 `local`).
- 케이스 2건: ① 원격에서 가져온 기록이 `synced` ② 그 결과를 캐시한 뒤 재조회한 로컬 히트도 `synced`(O-1로 지운 `copyWith`가 실제로 불필요했음을 함께 고정).
- **가드 유효성 확인** — `_fromRemote`의 `copyWith`를 임시로 되돌리자 2건 모두 실패했다.

> 함정 하나: `MockClient`가 만드는 `http.Response`에 `request:`를 되돌려주지 않으면 postgrest가 `response.request!.method`에서 널 체크 예외를 던진다.

## O-3 — 상세 배너 실시간 소멸: **스트림 전환으로 반영**

선례(`storedRunProvider`)와 같은 크기로 끝나서 backlog로 미루지 않고 구현했다. 구조 변경 없음 — provider 하나 + 술어에 override 파라미터 하나.

`runSyncStatusProvider(runId)` 신설(`run_detail_providers.dart`): `myRunsProvider`(drift `watch()`)에서 해당 id의 `syncStatus`만 골라낸다. `runDetailProvider`(단발 `FutureProvider`)는 그대로 두고 **실시간이 필요한 값 하나만** 스트림에서 가져오는 방식이라, 상세 조회의 `autoDispose` 메모리 전제(1시간 러닝 ≈ 3,600 샘플)를 건드리지 않는다.

- 술어를 `isSyncPending(record, {SyncStatus? syncStatus})`로 확장 — 넘기면 그 값으로 판정. 목록 칩은 인자 없이 그대로 쓴다(스트림 레코드가 이미 최신).
- **null 폴백을 명시적으로 뒀다.** 목록 상한(200건) 밖의 오래된 기록과 로컬 행이 없는 다른 기기 기록에서 null이 된다. 그때는 조회 시점의 `record.syncStatus`를 쓴다 — 모르면 아는 값을 쓰는 쪽이지, 배너를 지우는 쪽이 아니다.
- ⚠️ 이 provider에서 꺼내 쓸 값은 `syncStatus`뿐이다. 목록 스트림 레코드는 payload 절감으로 `samples`가 비어 있어 경로·랩에 쓰면 안 된다(`storedRunProvider`와 같은 주의).

테스트 2건 추가(`run_detail_page_test.dart`): 열어 둔 채 `pending → synced`가 스트림으로 도착하면 배너가 사라진다 / 목록이 모르는 기록은 조회 시점 상태로 판정한다. 헬퍼 `pump()`에 `userId` 스위치를 넣어(넘길 때만 `myRunsProvider`가 살아난다) 기존 케이스는 그대로 폴백 경로를 탄다. 여기서도 **가드 유효성 확인** — 페이지를 `isSyncPending(record)`로 되돌리자 첫 번째 케이스가 실패했다.

## 추가 변경 파일 (2차)

| 파일 | 변경 |
|---|---|
| `lib/features/history/data/run_detail_providers.dart` | `runSyncStatusProvider` 신설 |
| `lib/features/history/presentation/sync_pending.dart` | `syncStatus` override 파라미터 |
| `lib/features/history/presentation/run_detail_page.dart` | 실시간 상태 watch + 배너/`failed` 판정에 반영 |
| `lib/features/tracking/data/local_run_repository.dart` | O-1 중복 제거 |
| `test/tracking/find_by_id_remote_sync_status_test.dart` | **신설** — O-2 회귀 가드 2건 |
| `test/history/run_detail_page_test.dart` | O-3 케이스 2건 + `pump(userId:)` |
| `pubspec.yaml` | dev_dependencies에 `http` |
| `docs/ARCHITECTURE.md` | §9.1에 실시간 소멸 경로 1문단, 변경이력에 회귀 가드 파일 |

## 결과 (2차)

- `flutter analyze` — **No issues found**
- `flutter test` — **288/288 통과** (1차 284 + O-2 2건 + O-3 2건)
