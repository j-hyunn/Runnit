# `client_reported` 모델 승격 + G-4(업로드 중 메타 편집 유실) 해소

| 항목 | 내용 |
|------|------|
| 작성일 | 2026-09-07 |
| 담당 | mobile-architect |
| 브랜치 | `claude/task-list-planning-c1f2a8` (기준 커밋 `64bd7d6`) |
| 근거 | PRD §8.3·§8.4 / ARCHITECTURE §9 / TRD §7.2·§14 #27·#29 / `_workspace/20260903_backend_p0-validate-recalc-upload-guard.md` §4 |
| 범위 | **모델 + 리포지토리 계층만.** 상세 화면 병기 UI 는 flutter-ui |
| 상태 | 코드·문서 변경 완료, **커밋하지 않음** |

PRD 스펙 변경은 없다. 이미 확정된 스펙의 **미구현분 마감**이다. 서버 스키마·마이그레이션도 건드리지 않았다(전부 클라이언트 코드).

---

## 1. 작업 A — `client_reported` 를 `RunRecord` 필드로 승격

### 1.1 문제

마이그레이션 64 부터 서버는 샘플 재계산 거리를 **상시** 확정값으로 채택하고, 재계산 직전의 클라이언트 주장값을 `runs.client_reported jsonb` 에 보존한다. 클라이언트는 이미 그 값을 업로드 응답에서 되받고 있었다(`_serverOwnedKeys` → `_adoptedKeys`).

되받은 값이 들어가는 곳은 로컬 행의 `summaryJson` **문자열**뿐이었다. `RunRecord` 에 대응 필드가 없으니 `RunRecord.fromJson` 이 그 키를 조용히 버리고, 다음 전체 로컬 재기록(`toRow()` → `RunRecord.toJson()`)에서 **키 자체가 사라진다.** TRD §7.2 의 "상세 화면에 병기할 데이터는 확보돼 있다"가 앱의 재저장 한 번에 무너지는 상태였다.

### 1.2 결정 — **중첩 freezed 모델**(`ClientReportedRun`), 스칼라 2개 아님

의뢰에서는 스칼라 2개(`clientReportedDistanceMeters` / `clientReportedMovingSeconds`)를 우선 검토하도록 했고, 근거는 "jsonb 를 그대로 매핑하려면 커스텀 컨버터가 필요하다"였다. **그 전제가 사실이 아니다** — freezed/json_serializable 은 중첩 freezed 클래스를 컨버터 없이 직렬화한다(`RunRecord` 는 이미 `explicitToJson: true`). 전제가 빠지면 저울이 반대로 기운다.

| 축 | 중첩 `ClientReportedRun?` (채택) | 스칼라 2개 |
|---|---|---|
| wire 키 | `client_reported` **하나** — 서버 컬럼과 1:1 | `client_reported_distance_meters` 등 **`runs` 에 없는 컬럼명 2개** |
| `_serverOwnedKeys` / `_adoptedKeys` / `_confirmationColumns` | **한 글자도 안 바뀜** | 세 집합을 각각 갈라야 함(보낼 때 뺄 키 ≠ 받을 키) |
| 되받기 로직 | `_adoptedKeys` 루프가 그대로 처리 | jsonb → 스칼라 2개 분해를 루프 **밖에** 따로 |
| 업로드 payload 정합 테스트(`_runsColumns`) | 통과 | **깨짐** — payload 키가 `runs` 컬럼 집합의 부분집합이어야 한다 |
| `summaryJson` 왕복 | `toJson()` 이 그대로 | 동일 |
| `max_speed_mps` · `recalculated_at` | 손실 없이 따라옴 | **버려짐** |

숫자 파싱은 생성 코드에서 `(json['distance_meters'] as num?)?.toDouble()` / `(json['moving_seconds'] as num?)?.toInt()` 로 나와, PostgREST 가 `10000.0` 을 `10000` 으로 내려도 안전하다(회귀 테스트로 고정).

```dart
@freezed
abstract class ClientReportedRun with _$ClientReportedRun {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory ClientReportedRun({
    double? distanceMeters,
    int? movingSeconds,
    double? maxSpeedMps,
    DateTime? recalculatedAt,
  }) = _ClientReportedRun;
  ...
}
```

`RunRecord.clientReported: ClientReportedRun?` — `isFlagged` 와 **같은 방침**(payload 에서 제거, 응답에서 채택, 로컬 저장에는 보존).

### 1.3 `isFlagged` 와 달리 nullable 의 뜻이 하나다

`isFlagged` 는 `null`(아직 모름) / `false`(정상 확정) / `true`(플래그) 세 상태를 구분해야 하지만, `clientReported` 는 그럴 필요가 없다. 서버가 **재계산값 < 주장값이고 차이 ≥ 1m 일 때 최초 한 번만** 채우기 때문에(마이그레이션 64 `trg_runs_guard`), 값의 존재 자체가 "거리가 깎였다"는 뜻이다. 값이 늘어나는 방향은 `least(recalc, claimed)` 때문에 존재하지 않는다.

### 1.4 `_serverOwnedKeys` 에서 달라진 것 하나

승격 전 코드 주석은 `client_reported` 제거를 "클라이언트가 이 컬럼을 만들지 않으므로 no-op" 이라 적어 뒀다. **이제 no-op 이 아니다** — 로컬에 값이 남으므로 `toJson()` 이 실제로 그 키를 만든다. 제거는 여전히 옳다: 이 컬럼은 "재계산 전에 무엇을 주장했는가"의 **증거**이고, 클라이언트가 그것을 다시 주장할 수 있으면 증거가 아니다(서버 가드가 되돌리기는 하지만, 안 싣는 것이 의도를 코드로 남기는 방법이다). 회귀 테스트로 고정했다.

---

## 2. 작업 C — G-3 판단 보조: 표시용 임계 **10m**

samplesJson 되받기(ⓑ안)는 하지 않는다(3,600 샘플 재다운로드). 상세 화면 병기(ⓐ안)에 필요한 데이터만 파생 getter 로 노출한다.

```dart
static const double distanceAdjustmentDisplayThresholdMeters = 10.0;

bool    get distanceWasAdjusted;            // 주장 − 확정 > 10m
double? get clientReportedDistanceMeters;   // 병기할 "기기 기록"(조정 없으면 null)
double? get distanceAdjustmentMeters;       // 깎인 양(조정 없으면 null)
```

**10m 는 표시용이며 서버 `v_flag_shrink_ratio`(0.8) 와 무관하다.** 두 수는 다른 질문에 답한다.

| | 서버 0.8 | 클라이언트 10m |
|---|---|---|
| 질문 | 부정을 의심할 만큼 깎였는가 | 사용자에게 두 숫자를 나란히 보여줄 가치가 있는가 |
| 결과 | `is_flagged` = true | 상세 화면 병기 |

서버는 **1m** 차이부터 `client_reported` 를 남긴다. 그것까지 병기하면(5.000km → 4.998km) 배너가 상시 노출돼 **정말 깎인 기록의 신호를 덮는다.** 반대로 서버 임계(20%)를 그대로 쓰면 플래그 없이 3% 깎인 기록 — 사용자가 실제로 "왜 거리가 다르지?"라고 묻는 대다수 — 이 설명 없이 남는다.

경계는 **초과**(`> 10m`)다. 확정 거리가 더 큰 경우는 서버 설계상 나오지 않지만, 나오더라도 "기기보다 더 뛴 것으로 확정"을 보여줄 이유가 없어 false 로 떨어진다.

---

## 3. 작업 B — G-4: 업로드 중 로컬 메타 편집 유실

### 3.1 문제

업로드가 도는 동안 사용자가 제목/메모를 고치면, 그 요청은 이미 **편집 전** 값을 싣고 나간 뒤다. `applyServerConfirmation` 이 행을 `synced` 로 올려 버리면 `syncPending()` 이 `synced` 행을 다시 집지 않으므로 **편집이 영원히 서버에 반영되지 않는다.** 사용자에게는 저장된 것으로 보인다(행이 아직 `pending` 이라 `updateMeta` 는 네트워크를 타지 않는 로컬 경로로 가서 성공을 돌려준다).

### 3.2 ⚠️ 제안된 `updatedAtLocal` 시각 비교는 이 스키마에서 **동작하지 않는다**

문서 §4 의 제안은 "업로드 시작 시각을 `_inFlight` 에 기록하고(→ `Map<String, DateTime>`), 확정 시점에 행의 `updatedAtLocal` 이 그보다 나중이면 편집으로 본다"였다. 그대로 구현했고, **G-4 회귀 테스트가 `synced` 를 관측했다.**

원인은 drift 의 `DateTimeColumn` **기본 저장 형식이 unix epoch 초**라는 것이다. 로컬 편집은 네트워크 왕복 없이 끝나므로 업로드 시작과 같은 초에 떨어지는 것이 정상 경로이고, 그러면 두 값이 **동일한 정수**가 되어 `isAfter` 가 false 다. (경계를 `>=` 로 바꾸면 반대로 편집이 **없는** 정상 경로까지 매번 `pending` 으로 남아 모든 기록이 순회마다 3,600 샘플을 재전송한다.)

저장 형식을 밀리초/텍스트로 바꾸는 것은 drift 스키마 마이그레이션이다. 판정 하나를 위해 전 기기의 로컬 DB 를 건드릴 이유가 없다.

### 3.3 채택 — 인플라이트 구간의 **메모리 표식**

두 경로(`_schedulePush` 체인 / `syncPending()`)가 **같은 리포지토리 인스턴스** 안에 있으므로, 메모리 표식이 시각 비교보다 정확하고 싸다.

```dart
final Set<String> _inFlight = <String>{};              // 그대로 유지
final Set<String> _localEditDuringUpload = <String>{};  // 신설, 같은 생애주기

// _applyMeta 진입부
if (_inFlight.contains(id)) _localEditDuringUpload.add(id);

// _push
final confirmed = await _upsertRemote(record).timeout(uploadTimeout);
await applyServerConfirmation(record.id, confirmed,
    editedDuringUpload: _localEditDuringUpload.contains(record.id));
// finally 에서 두 집합 모두 remove
```

`applyServerConfirmation(id, confirmed, {bool editedDuringUpload = false})`:

- **서버 확정값은 그대로 채택한다** — 거리·플래그·XP 를 버릴 이유가 없다. `pending` 으로 남기는 것과 **별개의 결정**이다.
- `sync_status` 만 `synced` 대신 `pending`.
- `sync_attempts` 는 **0 으로 되돌린다** — 이번 왕복은 성공했고, 되돌리지 않으면 편집 재업로드가 남은 예산 안에서만 시도된다.

`_inFlight` 는 `Set<String>` 그대로 두었으므로 `inFlightIds` getter 시그니처도 그대로다.

프로세스가 죽어 표식이 사라지는 경우는 문제가 되지 않는다 — 그때는 확정 응답도 도달하지 않아 행이 `pending`/`failed` 로 남는다.

### 3.4 기존 주석과의 정합

`applyServerConfirmation` 은 원래 "업로드 중 편집이 있을 수 있으니 메모리 레코드를 통째로 쓰지 않고 DB 의 `summaryJson` 위에 겹친다"고 적혀 있었다. 그 방어는 편집을 **로컬에서** 지키는 데까지만 유효했다(서버 반영은 지키지 못했다). 두 주석이 서로를 가리키도록 정리했고, `_applyMeta` 쪽에는 "여기는 흔적만 남기고 판단은 확정 반영 쪽이 한다 — 편집 시점에는 업로드가 언제 시작됐는지 알 수 없다"를 명시했다.

---

## 4. flutter-ui 에 넘기는 계약

상세 화면(`run_detail_page.dart`)이 소비할 인터페이스는 **`RunRecord` 의 파생 getter 3개**다. `clientReported` 원본 객체를 직접 읽을 필요는 없다.

| 멤버 | 타입 | 용도 |
|---|---|---|
| `record.distanceWasAdjusted` | `bool` | **병기 여부의 단일 술어.** 이 값이 true 일 때만 아래 둘이 non-null |
| `record.clientReportedDistanceMeters` | `double?` | 병기할 "기기 기록" 거리(m) |
| `record.distanceAdjustmentMeters` | `double?` | 깎인 양(m) — "약 300m 조정됨" 같은 문구용 |
| `record.distanceMeters` | `double` | **확정 거리.** 화면 어디서나 주 표시값은 이것이다 |
| `record.clientReported` | `ClientReportedRun?` | 원본(`maxSpeedMps`·`recalculatedAt` 포함). 통상 필요 없음 |

표시 문안 예: **"기기 기록 10.0km → 확정 9.7km"**. 확정값이 주 숫자이고 기기 기록은 보조다 — 히스토리·통계·랭킹·공유 카드가 모두 확정값을 쓰므로 화면 간 숫자가 갈리면 안 된다.

**배너 우선순위** — 상세 화면에는 이미 배타 규칙이 있다(플래그 배너 > 동기화 대기 배너, ARCHITECTURE §9.1). 거리 조정 병기는 **배너가 아니라 거리 숫자 옆의 인라인 보조 표기**로 두는 것을 권한다. 조정은 정상 기록에서도 일어나는 상시 현상이라 배너로 만들면 세 번째 배타 대상이 되어 규칙이 복잡해지고, 플래그된 기록에서는 조정 사실이 더 중요한 정보(플래그)에 밀려 사라진다.

**G-3 과의 관계**: 랩·페이스·경로는 여전히 **로컬 samples** 기준이라 확정 거리와 갈린다(서버가 재기입한 샘플을 되받지 않기로 했으므로 그대로다). 이 병기가 그 divergence 에 대한 사용자 설명 역할을 겸한다 — 즉 문서 §4 열린 항목 2번(G-3)의 ⓐ안과 3번(F-4 잔여)은 **같은 화면 작업 하나**다.

---

## 5. 변경 파일 · 검증

| 파일 | 변경 |
|---|---|
| `lib/models/run_record.dart` | `ClientReportedRun` 신설, `RunRecord.clientReported` 필드, 파생 getter 3개 + 임계 상수 |
| `lib/features/tracking/data/local_run_repository.dart` | `_localEditDuringUpload` 신설, `_push` / `_applyMeta` / `applyServerConfirmation` 갱신, `_serverOwnedKeys` 주석 정정 |
| `test/models/run_record_client_reported_test.dart` | 신규 — 직렬화 왕복(정수 거리 방어 포함) + 임계 경계 6종 |
| `test/sync/offline_sync_test.dart` | §8(승격 회귀 2건) · §9(G-4 2건) 추가 |
| `docs/TRD.md` | §3.2 · §4.1 매핑 · §7.2 · §14 #27 잔여 ② · §14 #29 ③ · 변경 이력 v0.28 |

`lib/features/tracking/data/local_run_database.dart` 는 **바꾸지 않았다** — row 매핑은 `RunRecord.toJson()` 을 그대로 담으므로 중첩 필드가 자동으로 따라간다. drift 스키마도 그대로(v2).

| 검증 | 결과 |
|---|---|
| `dart run build_runner build` | 성공(346 outputs) |
| `flutter analyze` | **No issues found!** |
| `flutter test` | **306개 전부 통과** (기존 293 + 13) |

커밋하지 않았다.

---

## 6. 남는 항목

| # | 항목 | 담당 |
|---|---|---|
| 1 | 상세 화면 거리 병기 UI (§4 계약) — G-3 ⓐ안 + F-4 잔여를 한 화면에서 | flutter-ui |
| 2 | `resetSyncAttempts` 수동 재시도 UI (F-5) | flutter-ui |
| 3 | F-7 실측(서버 값의 체계적 축소 편향) | backend |
| 4 | drift v1→v2 업그레이드 경로 테스트 (F-6) | 다음 라운드 |
| 5 | 업로드 중 **`save()`** 로 본문이 바뀌는 경우는 이번 가드 대상이 아니다 — `_applyMeta`(title/note) 만 표식을 남긴다. 완료 기록의 본문이 업로드 중에 바뀌는 경로는 현재 없으므로(체크포인트 저장은 `recording`/`paused` 라 업로드하지 않는다) 지금은 공백이 아니지만, 웨어러블 사후 병합(Phase 4)이 들어오면 그 전제가 깨진다 | Phase 4 착수 시 재점검 |
