# 공유 카드(HI-08 / HI-10) 아키텍처 — mobile-architect

- 작성: 2026-08-26
- 대상: **flutter-ui-designer**(주 수신자), backend-engineer, gamification-designer, qa-integration-tester
- 근거: PRD §5.2 HI-08·HI-10 (P0), ARCHITECTURE §3.1/§7.4/§12, TRD §3.9/§14
- 상태: **데이터 계약·파이프라인 확정. UI 아트만 남았다.** `flutter analyze` 무이슈 / `flutter test` 108건 통과

---

## 0. 세 줄 요약

1. **트리거 3개는 이미 하나의 큐로 모인다.** 서버가 티어 승급·PB·일반 뱃지를 전부 `user_badges` INSERT로 끝내므로, 감지 경로를 세 벌 만들지 말고 `pendingAchievementsProvider` 하나를 구독한다.
2. **렌더링은 클라이언트 위젯 캡처로 확정.** 서버 렌더링은 디자인 시스템을 두 번 구현하게 만든다. 출력은 항상 1080×1920.
3. **신규 Supabase 테이블·컬럼은 필요 없다.** 단, PB 카드의 "시간"이 일부 구간에서 비는데 그것을 없애려면 컬럼 하나(`user_badges.achieved_value`)가 P1에 있으면 좋다 — P0는 그것 없이 성립한다.

---

## 1. 현황 조사 — 지금 무엇이 없는가

### 1.1 뱃지 획득 UI: **없다**

`isSeen`을 소비하는 화면이 코드베이스에 **하나도 없다.**

| 계층 | 상태 |
|---|---|
| DB | `user_badges.is_seen` 컬럼 존재, 클라이언트가 쓸 수 있는 유일한 컬럼(가드 트리거) |
| Repository | `GamificationRepository.watchUnseenBadges()` / `markBadgesSeen()` **구현 완료** (`supabase_gamification_repository.dart:60,85`) — realtime 구독까지 붙어 있다 |
| Provider | **없었다** → 이번에 `pendingAchievementsProvider` 신설 |
| UI | **없다.** `badge_gallery_page.dart`는 획득 목록만 보여주고 "방금 받았다"는 개념이 없다 |

즉 리포지토리의 realtime 스트림은 **구독자가 없어 지금까지 한 번도 흐른 적이 없고**, `is_seen`은 전부 `false`로 쌓여 있다.

> ⚠️ **마이그레이션 이슈**: 연출을 붙이는 순간 기존 사용자에게 밀린 뱃지가 한꺼번에 큐로 쏟아진다. 최초 1회는 "그동안 받은 뱃지 N개" 요약으로 접고 일괄 `markBadgesSeen`을 권한다 (TRD §14 #19에 등록).

### 1.2 티어 승급 UI: **없다**

`currentTier`를 읽는 곳은 세 군데뿐이고 전부 **현재 상태 표시**다 — 변화 감지가 아니다.

| 위치 | 용도 |
|---|---|
| `home_page.dart:194` | 홈 티어 카드(현재 티어 + 진행률) |
| `profile_page.dart:207` | 마이 탭 티어 배지 |
| `ranking_providers.dart:38` | 랭킹 조회 스코프 결정 |

`tier_change_history` 테이블(마이그레이션 33/34)이 상승 이벤트를 기록하지만 **클라이언트는 이 테이블을 조회하지 않으며**, realtime publication에도 없다.

🔵 **그런데 승급 감지는 이미 가능하다** — 승급 시 서버가 `stier_{tier}@{seasonId}` 뱃지 인스턴스를 발급하고(마이그레이션 31/32, `season_tier_reached`), 그건 `user_badges` INSERT라 realtime으로 온다. **`profiles.current_tier`를 폴링하거나 before/after 비교를 하지 말 것** — 시즌 롤오버 리셋을 "강등"으로 오인한다.

### 1.3 PB 갱신 확정 시점: **서버 재검증 후. 클라이언트 판정은 존재하지 않는다**

- **PB 테이블이 없다.** `personal_bests` 같은 테이블은 스키마에 존재하지 않는다. PB는 **뱃지로만 물질화**된다(`pb_first_achieved` / `pb_time_lte`).
- 확정 경로: `runs` INSERT → 트리거 `runs_03_evaluate_badges` → `evaluate_badges(user_id, run_id)` → 통과분을 `user_badges`에 **`verified = true`로** INSERT (마이그레이션 27:567).
- 즉 **큐에 뜬 시점에 이미 서버 확정**이다. "낙관적으로 축하했다가 뒤집힌다"는 상황이 구조적으로 없다.
- 클라이언트에는 PB 판정 코드가 없다. `badge_progress.dart:174` 주석이 `pbFirstAchieved`/`pbTimeLte`를 **클라이언트 판정 불가 목록**에 명시해 뒀다.

⚠️ **주의 — 요약 화면의 기존 문구는 이제 반만 맞다.** `tracking_page.dart:1579`의 "포인트와 뱃지는 서버 확인 후 기록 화면에 반영돼요"는 큐가 붙으면 **요약 화면에서 바로 축하가 뜬다**. 문구 교체가 필요하다(§6.1).

---

## 2. 렌더링 방식 — 클라이언트 위젯 캡처로 **확정**

ARCHITECTURE §12 #3 / TRD §14 #3을 **해소**로 갱신했다. 잠정 권고를 뒤집을 이유가 없었고, 조사 결과 근거가 오히려 강해졌다.

| 근거 | 내용 |
|---|---|
| **디자인 시스템 이중 구현** | 티어 색(`AppTokens`), Pretendard 가변 폰트, 뱃지 SVG 146종이 전부 Flutter 자산이다. 서버에서 같은 그림을 그리려면 HTML/Canvas 스택에 그 전부를 두 번째로 구현해야 하고, 두 구현이 어긋나는 날 사용자는 앱에서 본 것과 다른 카드를 인스타에 올린다 |
| **비용·지연 0** | 마케팅 예산 0원(BRD)이라 공유가 유일한 성장 레버다. 그 레버에 서버 왕복과 이미지 저장 비용을 얹을 이유가 없다 |
| **오프라인 동작** | HI-10은 러닝 종료 직후에 동작해야 하는데 그 지점은 신호가 나쁠 수 있다. 오프라인 우선(§9)의 자연스러운 연장 |
| **프라이버시** | 이미지 한 장 만들자고 집 근처 GPS 트랙을 서버로 올리지 않는다 |

**서버 렌더링이 필요해지는 유일한 경우**는 링크 공유의 OG 이미지(웹 URL 미리보기)인데, PRD가 요구하는 건 스토리에 올릴 **이미지 파일**이다. 그 요구가 생기면 이 경로를 대체하는 게 아니라 추가한다.

### 캡처 스펙 (`data/share_card_renderer.dart`)

```
출력      1080 × 1920 (9:16) PNG — 인스타 스토리 권장 해상도
배율      pixelRatio = 1080 / 카드논리폭   ← 기기 DPI가 아니라 목표 폭에서 역산
타이밍    await WidgetsBinding.instance.endOfFrame 후 캡처
정리      ui.Image.dispose() 필수 (1080×1920 RGBA ≈ 8MB)
```

---

## 3. 패키지 — `share_plus: ^10.1.4` **하나만** 추가

`pubspec.yaml`에 추가하고 `flutter pub get` 검증 완료(충돌 없음).

**캡처 패키지는 추가하지 않았다.** `screenshot` 등은 `RenderRepaintBoundary.toImage()`를 30줄 감싼 래퍼이고, 우리는 기기 해상도와 무관하게 1080px 폭을 내려고 **경계의 논리 크기를 직접 읽어야** 하는데 래퍼는 바로 그 값을 감춘다. 내장 API로 충분하다.

파일 쓰기는 이미 있는 `path_provider` + `path`를 쓴다. `XFile`은 `share_plus`가 재수출하므로 `cross_file` 직접 의존도 불필요.

---

## 4. 데이터 모델 — 신규 테이블 **불필요**

### 4.1 왜 불필요한가

| 카드 | 필요한 값 | 이미 있는 출처 |
|---|---|---|
| 티어 승급 | 티어, 시즌, 시즌 누적 거리, 순위 | `profiles.current_tier` / `season_distance_meters` / `tier_season_id`, `stier_*@{season}` 뱃지, `leaderboard_entries` |
| 뱃지 획득 | 이름, 설명, 등급, 아트, 획득 시각 | `badges` + `user_badges` |
| PB 갱신 | 종목 거리, 기록, 경로 | `badges.condition->>'distanceKm'` + `user_badges.source_run_id` → `runs` |

**공유 행위 로그 테이블(`share_events`)도 두지 않는다.** OS 공유 시트는 사용자가 실제로 게시했는지 앱에 돌려주지 않는다(iOS는 취소 여부만, 대상 앱은 미공개). 게시 여부를 모르는 행은 분석에도 쓸 수 없다 — 전환율이 필요해지면 도메인 테이블이 아니라 텔레메트리 이벤트(`share_sheet_opened`)로 붙인다.

### 4.2 모델 변경 1건 (**전 팀 공지**)

```dart
// lib/models/badge.dart — UserBadge
String? sourceRunId,   // 신규. DB 컬럼 user_badges.source_run_id (마이그레이션 02부터 존재)
```

- **breaking change 아님.** nullable 추가이므로 기존 호출부 전부 그대로 컴파일된다. `build_runner` 재생성 완료(`source_run_id` ↔ `sourceRunId` 매핑 확인).
- **쓰기 경계는 그대로다** — 서버 전용(가드 트리거가 되돌린다). 읽기만 노출했다.
- ⚠️ **TRD의 기존 서술을 뒤집은 것**이라 §4.1 매핑표와 그 아래 주석을 함께 갱신했다. 원래 "Dart 모델에 추가하지 않는다"였는데, 당시엔 소비자가 회수 판정(서버) 하나뿐이었다. 공유 카드가 두 번째 소비자다 — 없으면 클라이언트가 `earned_at` 근처 러닝을 **시간으로 추측**하게 되고, 같은 날 두 번 뛴 사용자에게서 조용히 틀린다.

### 4.2.1 모델 변경 2건 추가 — `RunRecord.isFlagged` / `flagReason`

병렬 작업 중이던 **gamification-designer**가 `_workspace/20260826_105607_gamification_sharing-trigger-timing.md` §2에서 요청한 사항(그쪽 `achievement_moment.dart`의 게이트 판정이 이 필드 없이는 구현 불가)을 반영했다.

```dart
// lib/models/run_record.dart
bool? isFlagged,      // runs.is_flagged
String? flagReason,   // runs.flag_reason
```

**`@Default(false)`가 아니라 nullable인 것이 핵심**이다:

| 값 | 의미 |
|---|---|
| `null` | 아직 모른다 (로컬 저장만 됐거나 서버 응답 미수신) |
| `false` | 서버가 정상으로 확정 |
| `true` | 서버가 이상치로 플래그 |

기본값을 `false`로 두면 "아직 검증 전"이 "정상 확정"으로 둔갑해, 나중에 플래그될 기록을 축하하고 **공유까지 시켜 버린다.** 공유 카드는 앱 밖으로 나가면 회수할 수 없으므로 이 구분이 곧 안전장치다.

쓰기 경계: `local_run_repository.dart`의 `_serverOwnedKeys`에 `is_flagged` / `flag_reason`을 추가해 업로드 payload에서 제거했다(서버 가드가 한 번 더 되돌리지만, 보내지 않는 것이 의도를 코드로 남기는 방법이다). **로컬 `summaryJson`에는 보존**되므로 앱 재시작 후에도 게이트가 동작하며, drift 스키마 마이그레이션은 불필요하다(요약이 JSON blob이라).

🔵 **남은 절반은 gps-tracking-engineer 몫**: `_push()`가 `.upsert(payload)`만 하고 `.select()`를 하지 않아 **서버가 확정한 값을 읽어올 경로가 아직 없다.** `.upsert(payload).select().single()`로 바꿔 응답을 로컬에 반영해야 `isFlagged`가 실제로 채워진다. `_push`의 에러 처리 의미가 바뀌는 변경이라 그 모듈 소유자가 하는 편이 안전하다.

### 4.3 뷰모델 — `lib/features/sharing/domain/share_card_data.dart`

```dart
enum ShareCardKind { tierPromotion, badgeEarned, personalBest }

sealed class ShareCardData {
  ShareAthlete athlete;   // displayName / tier / level / avatarUrl
  DateTime achievedAt;    // 서버 확정 시각
  ShareRoute? route;      // 좌표 ≤240점, 실내·누적형이면 null
  ShareCardKind kind;
  String headline;        // 카드 큰 글씨
  String? subhead;
  String shareText;       // 공유 시트 곁들임 텍스트
}

final class TierPromotionCardData  // tier, seasonId, seasonDistanceMeters, rank?, participantCount?, topPercent
final class BadgeEarnedCardData    // badge, badgeAssetPath
final class PersonalBestCardData   // targetKm, certifiedSeconds?, runDistanceMeters?, distanceLabel, timeLabel?
```

**freezed를 쓰지 않았다** — 직렬화되지 않고 `copyWith`도 필요 없어 코드 생성이 순수 비용이다. 같은 계층의 `GamificationStats`/`BadgeProgress`와 동일한 판단이다. `sealed`라 UI는 `switch`로 3종을 빠짐없이 다뤄야 하고, 카드가 늘면 컴파일 에러로 알려준다.

**`AppUser`를 통째로 넘기지 않는다** — 카드에 필요한 건 4개 필드인데 `AppUser`는 체중·생년월일까지 들고 있다. 공유 이미지를 만드는 계층에 신체 정보를 흘리지 않는 게 기본값으로 안전하다.

### 4.4 ⚠️ PB 카드의 시간이 비는 구간 (읽어야 할 항목)

서버 규칙(TRD §10.2 `pb_time_lte`)은 세션 거리가 목표의 **102%를 넘으면 GPS 샘플 선형 보간으로 목표 거리 통과 시각**을 쓴다. **그 보간값은 어디에도 저장되지 않는다.**

클라이언트 규칙(`ShareCardBuilder.certifiedPbSeconds`):

| 조건 | `certifiedSeconds` |
|---|---|
| 세션 거리 ≤ 목표 × 102% | `runs.moving_seconds` — 이 구간에서는 그게 **서버 규칙 그 자체**라 값이 정확히 일치 |
| 초과 | **null** → 카드는 시간 없이 "5km 개인 최고 기록"만 말한다 |

보간을 클라이언트가 흉내 내지 않는 이유: 서버 확정값을 재유도하면 정본이 둘이 되고, 어긋나는 순간 **사용자가 인스타에 올린 기록이 앱 화면과 다른 값**이 된다.

🔵 **backend-engineer에게 (P1, TRD §14 #18)**: `user_badges.achieved_value numeric null` 한 컬럼이면 이 폴백이 통째로 사라진다. 서버가 판정 시점 값(PB 초 / 스트릭 주 / 주간 순위)을 적어 두면 모든 뱃지 카드가 서버 값만 그린다. **P0는 이것 없이 성립한다.**

---

## 5. 생성한 파일

```
lib/features/sharing/
  domain/
    share_card_data.dart       ✅ 완성 — 유니온 + 문구 규칙
    share_card_builder.dart    ✅ 완성 — 조합 로직(순수 함수, 테스트 17건)
  data/
    share_card_renderer.dart   ✅ 완성 — 캡처
    share_service.dart         ✅ 완성 — 임시 PNG + 공유 시트
    share_providers.dart       ✅ 완성 — 큐/카드 Provider
  presentation/
    share_card_sheet.dart      🟡 동작하는 골격 — 아트는 UI 담당
    widgets/share_card_surface.dart  🟡 9:16 프레임 + 캡처 계약(유지 필수) + 자리표시자 본문

lib/features/gamification/domain/badge_assets.dart  ✅ 신설(아트 경로 규칙 정본화)
lib/features/tracking/domain/polyline_codec.dart    ✏️ decodePolyline 추가
lib/models/badge.dart                               ✏️ UserBadge.sourceRunId 추가
test/sharing/share_card_builder_test.dart           ✅ 17건
```

### 5.1 flutter-ui-designer가 바꿔도 되는 것 / 안 되는 것

`ShareCardSurface`의 **`child`만 갈아 끼우면 된다.** `DefaultShareCardBody`는 디자인이 아니라 자리표시자다(디자인 없이도 실기기에서 파이프라인 전체를 검증할 수 있게 넣어 뒀다).

**유지해야 캡처가 성립하는 것:**

1. 카드가 `ShareCardSurface`로 감싸여 **화면에 실제로 올라가 있을 것.** `Offstage` / `Visibility(visible: false)`는 페인트를 건너뛰어 빈 이미지가 된다.
2. 같은 `GlobalKey`를 surface와 `shareCard(...)` 양쪽에 넘길 것.
3. 캡처 중 버튼 잠금 — 연타하면 8MB 이미지를 여러 장 동시에 굽는다.
4. 카드 안에서 `MediaQuery` 크기·다크모드를 읽지 말 것. 카드는 1080×1920으로 구워지는 **고정 규격 인쇄물**이고, 스토리에 올라간 뒤에는 보는 사람의 테마와 무관하다. 치수는 카드 폭 대비 비율(`LayoutBuilder`)로 잡는다.

### 5.2 카드별로 그려야 할 것 (PRD HI-08: 티어·뱃지·순위·경로)

| 카드 | 필수 | 선택 |
|---|---|---|
| 티어 승급 | 티어 엠블럼(`assets/badges/tier/{tier}.svg`), `headline`("골드 달성"), 시즌 라벨 + 시즌 누적 km | `topPercent`("상위 12%") — **`rank`보다 우선**(PRD §5.4.1), `route` |
| 뱃지 획득 | `badgeAssetPath` 메달, 뱃지명, 설명 | `route` |
| PB 갱신 | PB 메달, `distanceLabel`("5km"/"하프"), `timeLabel` | `timeLabel`이 **null일 수 있다** — 시간 자리를 비워도 레이아웃이 무너지지 않게 |

공통 하단: `athlete.displayName` · `Lv.{level}` · 티어 라벨. 브랜드 마크는 필수(무료 광고 1회가 목적).

⚠️ **`participantCount`가 null이면 `topPercent`도 null**이다(집계 전/모집단 미상). 순위 영역 전체가 빠질 수 있다.

⚠️ **`badge_gallery_page.dart`에 아트 경로 규칙의 private 사본이 아직 남아 있다.** 정본은 `badge_assets.dart`로 옮겼다 — 갤러리 쪽을 위임으로 정리하는 건 UI 담당 몫이다(별도 작업으로 분리 등록). 두 사본이 갈라지면 갤러리에서 본 메달과 공유 카드의 메달이 달라진다.

---

## 6. 트리거 지점 — 어디서 감지하고 무엇을 구독하는가

### 핵심: 감지 경로는 **하나**다

| HI-10 트리거 | 서버가 만드는 행 | 클라이언트 판별 |
|---|---|---|
| 티어 승급 | `stier_{tier}@{seasonId}` (마이그레이션 31/32) | `Badge.category == seasonTier` |
| PB 갱신 | `pb_first_achieved` / `pb_time_lte` | `Badge.category == personalBest` |
| 뱃지 획득 | 해당 뱃지 (마이그레이션 27/41) | 나머지 12개 카테고리 |

`user_badges`는 realtime publication에 있고(07_rls.sql), `watchUnseenBadges`가 `is_seen = false` 행을 밀어 준다.

### Provider 계약 (`data/share_providers.dart`)

```dart
pendingAchievementsProvider            // StreamProvider<List<UserBadge>> — 미확인 큐(오래된 순)
nextAchievementProvider                // Provider<UserBadge?> — 큐 맨 앞 1건
shareCardForAchievementProvider(ub)    // FutureProvider.family<ShareCardData?, UserBadge>
currentTierShareCardProvider           // FutureProvider<TierPromotionCardData?> — "지금 내 티어 자랑"
shareServiceProvider                   // Provider<ShareService>
markAchievementsSeen(ref, ids)         // 연출 종료 후 호출 → is_seen = true
```

**연출은 1건씩** 처리한다(`nextAchievementProvider`). 10km 달성 러닝 하나가 뱃지를 5개 터뜨리는 일이 실제로 있고, 다이얼로그 5개가 동시에 쌓이면 아무것도 축하가 되지 않는다.

### 6.1 지점별 배치 — UI 담당 작업

| # | 지점 | 현재 코드 | 필요한 것 |
|---|---|---|---|
| 1 | **러닝 요약 화면** (주 무대) | `tracking_page.dart:1471` `_SummaryView` — 이미 존재 | 큐를 `ref.listen`해 축하 오버레이/다이얼로그 → 공유 버튼. 러닝 자체 공유 버튼도 여기. ⚠️ **1579행 문구 교체**("서버 확인 후 반영돼요"는 이제 반만 맞다) |
| 2 | **앱 전역** (뒤늦게 도착하는 성취) | 없음 | 서버 판정은 업로드 후 비동기라 사용자가 이미 홈으로 갔을 수 있다. `AppShell`(`core/widgets/app_shell.dart`) 수준에 큐 리스너 하나를 두면 화면과 무관하게 잡힌다 |
| 3 | **뱃지 갤러리** | `badge_gallery_page.dart` — 획득 목록 존재 | 획득한 뱃지 상세에 "공유" — 성취 직후를 놓쳐도 나중에 자랑할 수 있어야 한다 |
| 4 | **홈 티어 카드** | `home_page.dart:194` | `currentTierShareCardProvider`로 공유 버튼 |
| 5 | **기록 상세** | `RunDetailPlaceholder` (미구현) | 러닝 카드 공유 |

**1·2번이 HI-10의 수용 기준("요약 화면 연출 종료 직후 노출")을 만족시키는 최소 조합**이다. 3·4·5는 HI-08의 일반 공유 경로.

축하 연출 UI(다이얼로그/배너/오버레이) 자체는 **전부 flutter-ui-designer 담당**이다. 데이터는 위 Provider가 전부 공급한다 — 새로 조회를 짤 필요가 없다.

---

## 7. 다른 에이전트에게

### backend-engineer
- `UserBadge.sourceRunId` 읽기 노출 — 쓰기 경계 변경 없음(가드 트리거 그대로).
- **P1 요청**: `user_badges.achieved_value numeric null` (§4.4, TRD §14 #18).
- **확인 요청**: `tier_change_history`를 realtime publication에 넣을 계획이 있는지. 현재 설계는 필요로 하지 않지만(스티어 뱃지로 충분), 승급 시각을 초 단위로 정확히 써야 할 카드가 생기면 필요해진다.

### gps-tracking-engineer
- **요청 1건**: `local_run_repository.dart`의 `_push()`를 `.upsert(payload).select().single()`로 바꿔 서버 응답(`is_flagged` 포함)을 로컬에 반영해 달라(§4.2.1). 모델·payload 스트립은 이미 준비돼 있고, 이 한 줄이 없으면 `isFlagged`가 영원히 `null`이다.
- `polyline_codec.dart`에 `decodePolyline`을 추가했다(공유 카드가 `routePolyline`만 들고 경로를 그려야 하는 경우). 왕복 테스트 포함.

### gamification-designer
- 요청한 `RunRecord.isFlagged` / `flagReason`을 **반영 완료**(§4.2.1). nullable로 둔 이유가 그쪽 `achievementGate(runFlagged: null → pending)` 판정과 정확히 맞물린다.
- `stier_*` 뱃지가 **티어 승급 알림의 사실상 이벤트 소스**가 됐다. 발급 타이밍이 바뀌면 승급 축하 타이밍도 함께 바뀐다.
- `Badge.description`이 뱃지 카드의 `subhead`로 **그대로 인스타에 올라간다.** 카탈로그 문구를 그 관점에서 한 번 볼 가치가 있다(현재는 획득 조건 설명체).

### qa-integration-tester
- 검증 포인트: (a) 러닝 업로드 → 큐 도착 → 연출 → `is_seen=true` → 큐에서 제거, (b) 캡처 결과가 기기 무관하게 1080×1920인지, (c) 실내 러닝(좌표 없음)에서 경로 없는 카드가 정상인지, (d) PB 102% 경계 전후로 시간 표시/미표시가 규칙대로인지.
- 기존 108개 테스트 무회귀 확인 완료.

---

## 8. 남은 위험

| 위험 | 영향 | 대응 |
|---|---|---|
| 밀린 `is_seen=false` 뱃지가 한꺼번에 쏟아짐 (§1.1) | 첫 실행에서 다이얼로그 폭탄 | 최초 1회 요약 후 일괄 처리 (TRD §14 #19) |
| PB 시간이 비는 구간 (§4.4) | 카드에 시간 없음 | P0 허용, P1에 컬럼 추가 |
| `badge_assets.dart` 사본 이원화 (§5.2) | 갤러리/카드 메달 불일치 | 갤러리 위임 정리 |
| 캡처 시 SVG 미로드 | 메달 없는 카드 | `endOfFrame` 대기로 대부분 해결. 실기기 검증 필요 |
