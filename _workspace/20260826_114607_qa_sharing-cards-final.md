# 공유 카드(HI-08 · HI-10) 최종 통합 검증 — qa-integration-tester

- 작성: 2026-08-26 / 대상: 커밋 전 working tree (`claude/organize-todo-list-e416ed`)
- 근거: PRD §5.2(HI-08·HI-10) §5.4.1 §8.1 §8.4, TRD §3.9 §4.1 §14, ARCHITECTURE §7.4 §9 §12
- 입력: `_workspace/20260826_050000_architect_sharing-cards.md`, `..._105607_gamification_sharing-trigger-timing.md`, `..._121500_gps_run-push-select.md`, `..._113745_ui_sharing-cards.md`
- 방법: 경계면 양쪽 동시 읽기 + `flutter analyze` / `flutter test` 재실행. 파일은 수정하지 않았다.

## 판정: **통과 (커밋 가능)**

검증 항목 9개 중 **9개 통과**. 별도로 **차단성 아님(P1) 결함 2건 + 관찰 6건**을 아래에 남긴다.
어느 것도 이번 커밋을 막지 않는다.

| # | 항목 | 결과 |
|---|---|---|
| 1 | 게이트 판정 ↔ 실제 데이터 흐름 | ✅ PASS (CONFIRMED, 코드 추적 완료) |
| 2 | RunRecap 카드 게이트 미적용의 타당성 | ✅ PASS — PRD §8.4 위반 아님 |
| 3 | 뱃지 회수 방어 (`verified`/`revoked` 필터) | ✅ PASS (단, 갤러리 경로에 구멍 — F-1) |
| 4 | 밀린 뱃지 폭탄 방어 + 무한 루프 방지 | ✅ PASS |
| 5 | 캡처 계약 4가지 준수 | ✅ PASS (단, 텍스트 배율 — F-2) |
| 6 | `isFlagged` 왕복 / `sourceRunId` 사용 | ✅ PASS |
| 7 | 요약 화면 문구 교체 (포인트 제거) | ✅ PASS |
| 8 | 회귀 (`analyze` 0 / `test` 139) | ✅ PASS — 재실행으로 직접 확인 |
| 9 | 문서 정합성 (TRD/ARCHITECTURE) | ✅ PASS (경미한 잔여 불일치 3건) |

---

## 1. 게이트 판정 ↔ 실제 데이터 흐름 — **CONFIRMED PASS**

가장 꼼꼼히 본 항목. "온라인에서도 공유 버튼이 영원히 안 뜨는 회귀"는 **없다.**
사슬 6칸을 전부 코드로 이어서 확인했다.

| # | 칸 | 근거 |
|---|---|---|
| 1 | `stop()`이 `save()`를 **await** 한다 | `tracking/data/tracking_providers.dart:152-155` — 업로드 시도가 끝난 뒤에야 `state = AsyncData(record)`가 되므로 요약 화면 등장 시점에 이미 확정본이 로컬에 있는 것이 정상 경로다 |
| 2 | `_push()`가 응답을 받아 로컬에 반영 | `local_run_repository.dart:120-133` → `applyServerConfirmation()` (`:152-177`) |
| 3 | 반영이 `summaryJson`에 남는다 | `applyServerConfirmation`가 `_serverOwnedKeys`만 겹쳐 쓰고 `syncStatus`를 `synced`로 올린다. `local_run_database.dart:75-91`의 `toRow()`가 `toJson()−samples`를 `summaryJson`으로 저장하므로 `is_flagged`가 애초에 그 blob의 키다 |
| 4 | 재시작 후에도 복원된다 | `runRecordFromRow` (`local_run_database.dart:95-103`)가 `summaryJson`을 그대로 `RunRecord.fromJson`에 넣는다. `run_record.g.dart:48,87` — `is_flagged` ↔ `isFlagged` 매핑 확인 |
| 5 | UI가 **스냅샷이 아니라 DB**를 본다 | `summary_achievements.dart:67` `ref.watch(storedRunProvider(record.id)) ?? record` → `tracking_ui_providers.dart:33-40` → `myRunsProvider` → `watchByUser()`의 drift `query.watch()` (`local_run_repository.dart:274`). **`stop()` 반환값은 폴백일 뿐이고, 폴백일 때 값은 보수적으로 `pending`이 된다** |
| 6 | 게이트가 3상태를 정확히 가른다 | `achievement_moment.dart:32-40` — `null`(모름)을 `confirmed`로 승격시키지 않는다 |

**보낼 때 빼는 키 집합과 받을 때 채우는 키 집합이 상수 하나(`_serverOwnedKeys`)로 같다**
(`local_run_repository.dart:56-73`). 이 대칭이 이 경계면에서 가장 어긋나기 쉬운 지점인데,
한 곳에서 파생되므로 구조적으로 어긋날 수 없다.

**필터 통과 확인**: `watchByUser`는 `userId` + `status = completed`로 거르고 `startedAt desc limit 200`이다
(`:263-278`). 방금 끝낸 러닝은 완료 상태이자 최신이므로 항상 목록 안에 있다. 게이트가 리스트
경계 밖으로 밀려 `pending`에 갇히는 경로는 없다.

**테스트 커버리지**: `test/tracking/run_push_confirmation_test.dart`가 리포지토리→DB 왕복(7건,
`false`와 `null`의 구별 회귀 포함)을, `test/sharing/summary_achievements_test.dart`가
`myRunsProvider`만 override하고 **`storedRunProvider`는 실물로 태워** UI 분기(9건)를 검증한다.
미커버는 `myRunsProvider → repo.watchByUser` 한 줄뿐이며 양쪽이 각각 검증돼 있다.

---

## 2. RunRecap 카드(게이트 미적용) — **PRD §8.4 위반 아님. 판단 타당**

구현이 문서의 서술과 일치한다: `summary_achievements.dart:195-196`

```dart
final stored = ref.watch(storedRunProvider(record.id)) ?? record;
if (stored.isFlagged == true) return const SizedBox.shrink();
```

게이트를 걸지 않고 **`flagged`만 제외**한다. 명시된 대로다.

**§8.4 위반이 아닌 근거 (카드 내용을 직접 읽고 확인)**

| 확인 | 근거 |
|---|---|
| 카드에 뱃지·PB·티어 **성취 문구가 없다** | `share_card_data.dart:332,341` — headline `"5.01km 완주"`, shareText `"5.01km 러닝 완료! #Runnit"`. `_recapStats`(`share_card_body.dart`)의 타일은 시간·페이스·칼로리뿐 |
| 하단 `Lv.N · 티어 라벨`은 **클라이언트 판정값이 아니다** | `ShareAthlete.fromUser(user)`, `user`는 `currentProfileProvider` = 서버 `profiles.level` / `current_tier`. 클라이언트가 계산한 티어(`TierX.fromSeasonDistanceMeters`)를 쓰는 경로는 없다 |
| 성취 카드 쪽은 게이트와 무관하게 이미 서버 확정 | 큐가 `verified=true, revoked=false, is_seen=false` 서버 행이므로 (§3) 요약 화면 게이트가 `pending`이어도 공유 가능하다는 UI 판단이 맞다 |
| `flagged`면 성취 블록과 러닝 버튼이 **함께** 사라진다 | `summary_achievements.dart:73`(블록)과 `:196`(버튼)이 같은 `stored`를 본다 — 한쪽만 남는 비대칭이 없다 |

**잔여 위험(수용 가능, 기록만)**: 오프라인 러닝은 `isFlagged == null`이라 버튼이 뜬다. GPS 조작
기록이 업로드되기 **전에** 기록 카드로 나갈 수 있다. 다만 그 카드는 순위·뱃지·PB를 주장하지 않고
브랜드 마크 + 서버 발급 티어 라벨만 얹으므로, 리더보드 정합성에는 영향이 없고 손해는 브랜드
신뢰도에 국한된다. 뒤집으려면 `RunShareButton` 한 곳(`summary_achievements.dart:185-212`)만
고치면 되도록 격리돼 있다. **P0 출시 판단으로 타당하다.**

---

## 3. 뱃지 회수 방어 — PASS + 구멍 1건

✅ `supabase_gamification_repository.dart:84-85` — `watchUnseenBadges`에 `.eq('verified', true)
.eq('revoked', false)` **실제로 추가돼 있다.**

### 🔴 F-1 (CONFIRMED, P1) — 뱃지 갤러리 공유 경로에는 같은 방어가 없다

같은 방어를 축하 큐에만 걸었고, **트리거 지점 #3(뱃지 갤러리 상세의 공유 버튼)** 이 쓰는 경로에는 없다.

- `supabase_gamification_repository.dart:45-57` `fetchUserBadges()` — `revoked` 필터 없음
- `lib/models/badge.dart` — `UserBadge`에 `revoked` 필드 없음 (TRD §4.1이 서버 전용으로 유지)
- RLS는 **본인 행 전체 SELECT를 허용**한다 (TRD §830: "본인 전체, 타인은 `revoked=false and verified=true`만")
- 따라서 운영자가 수동 회수한 뱃지가 갤러리에 남고, `badge_gallery_page.dart:247` `_BadgeShareButton`이
  그 뱃지의 공유 카드를 만들어 준다 — gamification 문서 §1이 막으려던 바로 그 시나리오가 다른 문으로 열린다

현재 저장소에 `revoked=true`를 세우는 코드 경로가 **없으므로 실제 발생 확률은 0에 가깝다**(그래서
차단성 아님). 다만 같은 방어를 한쪽에만 건 비대칭은 남는다.

권고(backend-engineer 또는 gamification-designer, 다음 라운드): `fetchUserBadges()`에도
`.eq('revoked', false)`를 추가하거나, `UserBadge.revoked`를 읽기 전용으로 노출하고
**이미 만들어 둔 `isBadgeShareable(verified:, revoked:)`** 를 갤러리 버튼에 적용한다.

> 참고: `achievement_moment.dart`의 `isBadgeShareable`와 `isTierPromotion`은 **현재 호출부가 0건**이다
> (grep 확인). 회수 방어는 쿼리 레벨로, 승급 감지는 `stier_*` 뱃지 큐로 대체됐다 — 후자는
> 아키텍처 문서 §1.2의 "프로필 폴링 금지" 결정과 일치하므로 설계상 옳고, 그 결과
> gamification 문서 §6의 "(seasonId, tier) 로컬 영속화" 요청도 불필요해졌다(서버 `is_seen`이 그 역할).
> 두 함수는 F-1을 고칠 때 `isBadgeShareable`에 소비자가 생긴다.

---

## 4. 밀린 뱃지 폭탄 + 무한 루프 방지 — **CONFIRMED PASS**

| 확인 | 근거 |
|---|---|
| `isAchievementBacklog()` 구현 | `sharing/domain/achievement_backlog.dart:42-53` — 개수 > 5 **또는** `earnedAt` 간격 > 24h |
| 요약 화면 흐름에 연결 | `summary_achievements.dart:86-91` → `_BacklogSummary` + **일괄** `_dismiss(queue 전체)` |
| 전역 흐름에 연결 | `achievement_celebration.dart:128-138` → `AchievementBacklogDialog` + 일괄 `markAchievementsSeenFrom` |
| 무한 루프 방지 Set (요약) | `summary_achievements.dart:56` `final Set<String> _dismissed` |
| 무한 루프 방지 Set (전역) | `achievement_celebration.dart:95` `final Set<String> _presented` |
| 이중 축하 방지 | `achievementCelebrationSuppressors` 카운터(`:45`) ↔ `_SummaryViewState.initState/dispose`(`tracking_page.dart:1497-1507`) |

두 지점 모두 스트림 결과를 **로컬 Set으로 필터한 뒤** 큐로 쓴다(`:79`, `:103`) — 문서 서술 그대로다.

### 🟡 F-2 (PLAUSIBLE, P2) — 억제 카운터와 전역 다이얼로그의 프레임 경합

`suppressAchievementCelebrations()`는 `addPostFrameCallback`으로 **다음 프레임에** +1 한다
(`achievement_celebration.dart:52-56`, 빌드 중 notifier 수정을 피하려는 의도된 지연).
`AchievementCelebrationHost`도 같은 프레임의 build에서 `_present`를 post-frame으로 등록한다(`:113`).
호스트가 조상이라 **호스트 콜백이 먼저 등록·실행**되고, `_present` 첫 줄의
`if (suppressors > 0) return`(`:123`)은 아직 0을 본다.

→ **요약 화면이 뜨는 그 프레임에 큐가 이미 비어 있지 않으면** 전역 다이얼로그와 인라인 축하가
동시에 뜰 수 있다. 정상 흐름(러닝 종료 후 뱃지가 뒤늦게 도착)에서는 그때 이미 +1이라 발생하지
않고, "요약 화면 진입 시점에 이미 큐가 차 있는 경우"(밀린 뱃지, 직전 러닝의 잔여분)에 한정된다.

권고: `_present` 진입부에서 `await WidgetsBinding.instance.endOfFrame` 후 suppressors를 한 번 더
확인한다(한 줄). 같은 지연 패턴에서 파생된 부수 위험으로, 요약 화면이 **자신의 initState
post-frame이 실행되기 전에** dispose되면 카운터가 +1로 고착돼 세션 내내 전역 축하가 억제된다 —
현실적으로 도달하기 어렵지만 같은 수정으로 같이 막힌다.

---

## 5. 캡처 계약 4가지 — PASS + 관찰 1건

| 계약 | 준수 여부 |
|---|---|
| ① 카드가 화면에 실제로 올라가 있을 것 | ✅ `share_card_sheet.dart:113-121` — `Flexible > ConstrainedBox > ShareCardSurface`. `Offstage`/`Visibility(visible:false)` 사용 0건 |
| ② 같은 `GlobalKey`를 surface와 `shareCard(...)` 양쪽에 | ✅ `_boundaryKey`가 State 소유(`:54`)이고 surface(`:117`)와 `shareCard(boundaryKey:)`(`:89`)에 같은 인스턴스가 간다 |
| ③ 캡처 중 버튼 잠금 | ✅ `onPressed: (_sharing \|\| !_artReady) ? null : _share` (`:134`) — 연타 잠금 + SVG 프리캐시 전 잠금 |
| ④ 카드 안에서 `MediaQuery`·다크모드 미참조 | ✅ `share_card_body.dart` 전체에 `MediaQuery` / `Theme.of` / `Brightness` **0건**(grep 확인). 모든 치수가 `LayoutBuilder`의 `w` 비율이고 폰트도 `Pretendard Variable`을 명시한다 |

출력 규격도 확인: `pixelRatio = targetWidth / logicalWidth`(`share_card_renderer.dart:83`) +
`AspectRatio(9/16)` → 기기 무관 1080×1920. `image.dispose()`(`:94`)도 있다.

### 🟡 관찰 O-1 (CONFIRMED 사실 / 영향은 PLAUSIBLE) — 텍스트 배율은 여전히 암묵적 `MediaQuery` 의존

계약 ④를 **명시적 API 수준에서는** 지키지만, `Text`는 `MediaQuery.textScalerOf(context)`를
암묵적으로 읽는다. 저장소 전체에 `textScaler` override가 **0건**이므로, 시스템 글꼴 크기를 크게
설정한 사용자는 **다른 글씨 크기가 구워진 카드**를 얻는다(헤드라인 `maxLines: 2` + `ellipsis`라
잘려 나갈 수 있다). 위젯 테스트의 "오버플로 없음"은 기본 배율에서만 검증된다.

권고(1줄, 다음 UI 라운드): `ShareCardSurface`의 child를
`MediaQuery.withNoTextScaling(child: ...)`으로 감싼다. 계약 ④의 의도를 코드로 완성하는 변경이다.

### 관찰 O-2 (PLAUSIBLE) — 프리캐시가 flutter_svg의 **그림 캐시**를 데우지는 않는다

`precacheShareCardArt`(`share_card_body.dart:755-763`)는 `SvgAssetLoader(path).loadBytes(null)`을
부른다. 이는 에셋 번들 바이트를 데울 뿐, `flutter_svg`가 `SvgPicture` 렌더에 쓰는
`PictureInfo` 캐시(`svg.cache`)를 채우는 문서화된 경로는 아니다. 실제로는 카드가 시트에 이미
마운트된 채 프리캐시를 기다리므로 탭 시점엔 대개 디코드가 끝나 있어 **효과는 있다** — 다만
주석이 주장하는 만큼의 보장은 아니다. UI 문서 §7의 "실기기 캡처 검증" 항목이 그대로 유효하다.
**시뮬레이터에서 메달이 PNG에 실제로 찍히는지 확인 필요 — 위젯 테스트로는 검증 불가.**

---

## 6. 모델 필드 왕복 — **CONFIRMED PASS**

`RunRecord.isFlagged` / `flagReason`:

- **업로드(제거)**: `_serverOwnedKeys`에 `is_flagged`/`flag_reason` 포함(`local_run_repository.dart:63-64`) → `_remotePayload`가 `toJson()`에서 제거(`:135-141`)
- **다운로드(반영)**: 같은 상수로 `_confirmationColumns` 생성(`:72-73`) → `applyServerConfirmation`가 그 키만 덮어씀(`:165-166`)
- **로컬 보존**: `summaryJson`에 남아 재시작 후에도 게이트가 동작 (§1 3~4칸)
- **원격 폴백**: `findById`의 `_fromRemote`는 전체 `select()`라 원래부터 들어온다(`:226-234`) — 누락 없음
- **nullable 3상태**가 `@Default(false)`로 뭉개지지 않았다(`run_record.dart:143,147`)

`UserBadge.sourceRunId`:

- 모델(`badge.dart:101`) ↔ 생성 코드(`badge.g.dart:68,82` `source_run_id`) 매핑 확인
- **실제 소비 확인**: `share_providers.dart:76` `_sourceRunProvider(userBadge.sourceRunId)` →
  `findById(runId, includeSamples: true)` → `ShareCardBuilder.fromUserBadge(sourceRun:)` →
  `routeOf(sourceRun)` (뱃지·PB 카드의 경로 그림) 및 `_pbCard`의 `certifiedSeconds`/`runDistanceMeters`
- 쓰기 경계 안전: `markBadgesSeen`이 `{'is_seen': true}`만 보내므로(`supabase_gamification_repository.dart:100`) `toJson()`에 `source_run_id`가 생긴 것이 업로드로 새지 않는다

---

## 7. 요약 화면 문구 교체 — **CONFIRMED PASS**

옛 문구 `'포인트와 뱃지는 서버 확인 후 기록 화면에 반영돼요.'`는 **삭제됐다**(diff 확인).
게이트별 문구로 대체(`summary_achievements.dart:110-117`):

- `confirmed` → `'기록이 확인됐어요. 새 뱃지나 티어 변화가 있으면 여기에 바로 표시돼요.'`
- `pending` → `'아직 서버에 올리는 중이에요. 연결되면 뱃지와 티어가 확정돼요.'`
- `flagged` → 빈 문자열(블록 자체가 `:73`에서 이미 제거되므로 도달 불가한 방어 분기)

**"포인트" 언급 0건** — PRD §5.6 Phase 4 범위 밖 개념이 사용자 문구에서 빠졌다. 하네스 규칙 준수.

---

## 8. 회귀 — **직접 재실행 확인**

```
flutter analyze  → No issues found! (ran in 2.0s)      [exit 0]
flutter test     → 00:02 +139: All tests passed!        [exit 0]
flutter test test/sharing → +41 통과
```

gps 문서 §7이 남긴 `share_card_surface.dart:124 non_exhaustive_switch_expression` 1건은
**해소됐다**(UI 라운드에서 `runRecap` 추가 시 정리). 신규 테스트는 sharing 41건 +
tracking 왕복 7건이며 기존 108건 회귀 0.

---

## 9. 문서 정합성 — PASS, 잔여 불일치 3건(전부 경미)

✅ 갱신이 코드와 맞는 것:
- ARCHITECTURE §12 #3 / TRD §14 #3 → **해소(취소선) 표기 정확** — 실제로 클라이언트 위젯 캡처로 구현됨
- TRD §14 #19 → **해소 표기 정확** — `isAchievementBacklog()`가 양쪽 흐름에 실재
- TRD §14 #18 신설(P1 `achieved_value`) — 코드의 폴백 서술과 일치
- TRD §3.9 카드 4종 enum + `RunRecapCardData` 서술 — 코드와 일치
- TRD §4.1 `isFlagged`/`flagReason`/`sourceRunId` 행 — 실제 매핑·왕복 경로와 일치
- ARCHITECTURE §7.4/§7.4.1(단일 큐·두 소비 지점·억제 카운터), §9 "업로드는 단방향이 아니다" — 코드와 일치

⚠️ 남은 불일치(전부 서술 수준, 동작 영향 없음):

| # | 위치 | 내용 |
|---|---|---|
| D-1 | ARCHITECTURE §9 첫 불릿 / TRD §14 #1 | "저장소 선택(Hive/Drift/Isar 등)은 **미확정**"이라고 남아 있으나 **drift로 확정·구현 완료**(`local_run_database.dart`). gps 문서 §6이 "mobile-architect 몫"으로 넘긴 항목이 아직 그대로다 |
| D-2 | TRD §3.9 도입부 표 / `share_card_data.dart` 헤더 | "카드 **3종**이 필요한 값" — 바로 아래 enum은 4종이고 `runRecap`의 출처(`runs`) 행이 표에 없다 |
| D-3 | `badge_assets.dart:9-10` (코드 주석) | "⚠️ `badge_gallery_page.dart`에 아직 private 사본이 남아 있다"고 경고하지만 **이미 제거됐다**(`:595-596`이 이관 완료를 기록). 미래 독자를 오도한다 |

부수 관찰: 뱃지 SVG 종수를 ARCHITECTURE/TRD는 "146종", `share_card_renderer.dart:7`은 "158종"으로
적는다. 어느 쪽도 판정 로직에 쓰이지 않는 서술 숫자다.

---

## 그 외 관찰 (차단성 아님, 다음 라운드 참고)

| # | 내용 | 근거 |
|---|---|---|
| O-3 | **지난 시즌 티어 카드의 누적 거리가 현재 시즌 값이다.** `_tierCard`는 `rank`/`participantCount`는 `seasonId == user.tierSeasonId`일 때만 붙이는데(`share_card_builder.dart:150-152`), `seasonDistanceMeters`는 조건 없이 `user.seasonDistanceMeters`를 쓴다(`:147`). 갤러리에서 지난 시즌 `stier_*` 뱃지를 공유하면 subhead가 `"2026-Q2 시즌 34.2km"`처럼 **다른 시즌의 거리**를 말한다(`share_card_data.dart:166-169`). 필드 주석은 "승급 시점의 시즌 누적 거리"라 서술과도 어긋난다 | CONFIRMED |
| O-4 | 아트 경로 규칙이 다시 두 곳이다 — `badge_assets.dart`의 `badgeAssetPath`(정본)와 `share_card_body.dart:730` `tierEmblemAssetPath`. 현재는 `assets/badges/tier/{bronze,silver,gold,platinum}.svg`가 티어명·등급명 양쪽과 우연히 일치해 같은 파일을 가리키지만, 이번 라운드가 없앤 이원화와 같은 형태다 | CONFIRMED |
| O-5 | `_writeTempPng`(`share_service.dart:79-88`)가 공유할 때마다 타임스탬프 파일을 쌓고 정리하지 않는다. 캐시 디렉터리라 OS가 회수하므로 실피해는 없다 | CONFIRMED |
| O-6 | 홈 티어 공유 버튼의 탭 타깃이 `minWidth/minHeight: 32`(`home_page.dart`)로 `AppTokens.minTapTarget`(다른 공유 버튼들이 쓰는 값)보다 작다 | CONFIRMED |
| O-7 | `_present`에서 dismiss 후 `markAchievementsSeenFrom`이 실패하면 `_presented`만 갱신되고 리빌드 트리거가 없어, 남은 큐가 다음 스트림 이벤트까지 이어지지 않는다. 안전한 방향(조용히 멈춤)이고 다음 실행에서 복구된다 | PLAUSIBLE |

## 재현 불가 / 미검증 (환경 제약)

- 실기기·시뮬레이터 캡처 결과가 실제로 1080×1920인지, 메달 SVG가 PNG에 찍히는지 — 위젯 테스트로 검증 불가 (O-2)
- 실제 Supabase realtime 왕복(업로드 → 큐 도착 → `is_seen=true` → 큐 제거) — 로컬 테스트는 provider override 기반
- 트리거 지점 #5(기록 상세) — 화면이 `RunDetailPlaceholder`라 검증 대상 없음. **HI-10 수용 기준("요약 화면 연출 종료 직후 노출")은 #1·#2로 충족된다**

## 다른 에이전트에게

- **backend-engineer / gamification-designer**: F-1(`fetchUserBadges`에 `revoked` 필터 부재, 갤러리 공유 경로) — 이미 만들어 둔 `isBadgeShareable`이 여기서 소비자를 얻는다
- **flutter-ui-designer**: F-2(억제 카운터 프레임 경합, `_present`에 `endOfFrame` 후 재확인), O-1(`MediaQuery.withNoTextScaling`), O-4, O-6
- **mobile-architect**: O-3(지난 시즌 티어 카드의 `seasonDistanceMeters`), D-1(ARCHITECTURE §9 / TRD §14 #1의 drift 확정 반영), D-2, D-3
