# HI-06 역대 시즌 기록 화면 (프런트) — 구현 메모

| 항목 | 내용 |
|------|------|
| 작성 | 2026-08-31, flutter-ui-designer |
| 범위 | 프런트만. 백엔드(`season_histories` 마이그레이션 21·22, RLS)는 이미 완료 상태였다 |
| 근거 | PRD HI-06 / TI-06 / TI-09 / §4.3 영구 루프 / §5.3 티어 / §8.5 시즌 경계, ARCHITECTURE §13-4 |
| 검증 | `flutter analyze` clean, `flutter test` 220 passed |

---

## 1. 만든 것

| 파일 | 역할 |
|------|------|
| `lib/core/repositories/season_history_repository.dart` | 인터페이스. **읽기 전용** |
| `lib/features/history/data/supabase_season_history_repository.dart` | `season_histories` 조회(`user_id` = 본인, `season_id desc`) |
| `lib/features/history/data/season_history_providers.dart` | `mySeasonHistoriesProvider`, `bestEverTierProvider`(TI-09) |
| `lib/features/history/presentation/season_history_page.dart` | 화면 본체 |
| `test/history/season_history_page_test.dart` | 정상/빈/무효/에러/게스트 + provider 단위 |

수정: `repository_providers.dart`(provider 등록), `app_router.dart`(`/seasons`),
`profile_page.dart`(메뉴 "역대 시즌"), `history_page.dart`(시즌 필),
`full_ranking_page.dart`(스낵바에 링크), `docs/ARCHITECTURE.md`(v0.7, §13-4).

## 2. 판단 근거

### 2.1 리포지토리에 write 경로를 두지 않았다
`season_histories`는 시즌 경계를 넘을 때 `recompute_season_tier`가 쓰고, 마감 후에는
서버도 고치지 않는다(모델 doc의 불변 규칙). 클라이언트에 insert/update 메서드를 두면
"확정 결과"라는 계약이 코드 수준에서 깨진다. 인터페이스는 `fetchByUser` 하나뿐이다.

### 2.2 정렬은 `closed_at`이 아니라 `season_id desc`
`season_id`가 `2026-Q3` 형식이라 문자열 정렬이 곧 시간 역순이다(`Season` doc의 형식
선택 근거). `closed_at`은 cron 실행 시각/읽기경로 복구(`sync_my_season`) 순서에 따라
같은 시즌이라도 유저마다 흔들릴 수 있어 표시 순서의 기준으로 부적합하다.

### 2.3 무효 시즌(`is_voided`)은 숨기지 않는다
RLS(`season_histories_select_visible`)가 무효 행을 본인에게만 보여준다. 목록에서
빼면 사용자는 시즌이 통째로 증발한 것으로 오해한다 — §8.1이 행을 삭제하는 대신
플래그를 세우는 이유(이의 제기 대응 근거 보존)와 같은 논리를 화면에도 적용해,
`Opacity(0.45)` + "무효 처리됨" 라벨 + Semantics 라벨로 구분만 한다.

### 2.4 TI-09(역대 최고 티어)는 진행 중·무효 시즌을 뺀다
- **진행 중 시즌 제외**: 이 값의 의미는 "확정된 명예"다. 아직 안 끝난 시즌의
  `AppUser.currentTier`를 섞으면 확정값과 잠정값이 한 자리에 온다.
- **무효 시즌 제외**: 부정 판정된 시즌이 최고 기록으로 남으면 회수 정책이 무의미해진다.

프로필 카드에는 손대지 않았다(TI-09는 P1, 프로필 카드는 이미 현재 티어를 보여주고
있어 "현재/역대"가 나란히 오면 혼동된다). 역대 최고 티어는 역대 시즌 화면 상단 요약에만
둔다 — 필요해지면 `bestEverTierProvider`를 프로필에서 그대로 watch 하면 된다.

### 2.5 라우트를 마이 탭 브랜치에 둔 이유와 그 대가
`/seasons`는 알림함(`/notifications`)과 같은 성격이다 — 셸(바텀 네비) 유지 + 게스트
차단(`RouteAccess`가 `/home`·`/history`만 허용하므로 자동으로 막힌다) + 진입점이
마이페이지. 그래서 마이 탭 브랜치에 등록했다.

**대가**: `StatefulShellRoute` 특성상 이 라우트는 마이 탭 Navigator에 속하므로,
활동·홈 탭에서 `context.push('/seasons')`를 하면 **보이지 않는 브랜치에 쌓인다.**
그래서 다른 탭의 진입점은 `RunHistoryListPage`가 이미 쓰는 브랜치 내 이동 패턴
(`Navigator.push(MaterialPageRoute)`)을 쓴다. 이 제약은 `Routes.seasonHistory` doc에
경고로 박아 뒀다.

### 2.6 시즌 필 2개의 처리를 다르게 했다 (요청 사항의 핵심 판단)

| 위치 | 처리 | 근거 |
|------|------|------|
| `history_page._SeasonPill` | **역대 시즌 화면으로 이동** | Figma의 원 의도는 "통계를 다른 시즌으로 갈아 끼우는 필터"지만, 활동 탭 통계는 로컬 러닝을 재집계한 값(`myRunsProvider`)이고 시즌 결과는 서버 확정 스냅샷이다. 같은 자리에서 두 성격의 숫자가 번갈아 나오면 안 되므로 **필터가 아니라 전용 화면 이동**으로 해석했다 |
| `full_ranking_page._SeasonPill` | **바텀시트 유지 + 스낵바에 "내 시즌 기록" 링크만 추가** | 여기서 요구되는 것은 *그 시즌의 전체 리더보드 스냅샷*인데, 그런 테이블이 없다(`leaderboard_entries`는 현재 기간만 캐시). `season_histories`는 **내 결과**만 담으므로 대체재가 아니다. 지난 시즌을 고르면 역대 시즌 화면으로 자동 이동시키는 것은 "전체 랭킹을 보여준다"는 기대를 배신한다 — 그래서 이동은 사용자가 선택하는 스낵바 액션으로만 제공한다 |

### 2.7 디자인 토큰
새 색·새 스타일을 만들지 않았다. 배경 `#F8F8F8`, 흰 카드 radius 20 + `black@10%`
blur 2.5(프로필/활동 탭과 동일), 보조 텍스트 `#616161`/`#9B9B9B`, 간격은 전부
`AppTokens.s*`. 티어 색·라벨은 `TierPill`(→ `AppTokens.tier*`) 재사용.

## 3. 상태 처리

| 상태 | 화면 |
|------|------|
| 로딩 | `CircularProgressIndicator` |
| 에러 | "시즌 기록을 불러오지 못했어요 / 잠시 후 다시 시도해 주세요." |
| 빈 목록 | "아직 완료된 시즌이 없어요 / 이번 시즌이 끝나면 여기에 기록돼요." |
| 게스트 | 리포지토리를 호출하지 않고 빈 목록(라우터가 이미 막지만 로그아웃 직후 한 프레임 방어) |
| `bestWeeklyRank == null` | 해당 행 자체를 감춘다("순위 없음"은 실패처럼 보인다) |

## 4. 범위 밖 / 남은 것

1. **과거 시즌 전체 랭킹** — 시즌 마감 시 리더보드를 스냅샷하는 백엔드 작업이 선행돼야 한다.
2. **타 사용자 프로필의 역대 시즌** — AC-03(타 사용자 프로필)과 함께 다뤄야 한다.
   RLS는 이미 `is_voided = false`인 타인 행 조회를 허용하므로 리포지토리에
   `fetchByUser(otherUserId)`를 그대로 쓸 수 있다(인터페이스는 이미 userId를 받는다).
3. **실기기 검증 미완** — 실제 마감된 시즌 행이 있는 계정이 아직 없어 화면은 위젯
   테스트의 fake 데이터로만 확인했다. 첫 분기 마감(2026-10-01 KST) 후 실데이터 확인 필요.
