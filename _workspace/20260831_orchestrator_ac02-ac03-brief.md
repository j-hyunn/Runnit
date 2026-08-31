# AC-02 / AC-03 작업 브리핑 (orchestrator)

작성일: 2026-08-31 · 근거: PRD §5.8, ARCHITECTURE §13, 사용자 확정

## 확정 결정

### AC-05 (기록 공개 범위) — **완전 삭제**
- 사용자 확정: 비공개 기능을 만들지 않는다.
- 모든 프로필은 공개(`profiles_select_all` 유지).
- **조치**: PRD §5.8에서 AC-05 행 삭제, TRD의 `visibility` 컬럼/`ProfileVisibility` enum 설계 서술 제거, ARCHITECTURE §13에서 AC-05 제거, PRD 변경 이력 + HARNESS 변경 이력 기록. (orchestrator가 직접 처리)

### AC-02 (프로필 편집) — 편집 항목: 표시이름 · 사진 · 체중 · 주간 목표
- `username`(고유 핸들)은 **편집 불가**, 고정.
- `displayName` 편집.
- 아바타 사진: **Supabase Storage 버킷 신설**(`avatars`). 업로드 → `profiles.avatar_url` 갱신.
- `weightKg` 편집 (기존 컬럼, 20~400 CHECK 존재).
- **주간 목표: 신규.** `AppUser`에 `weeklyGoalKm` 필드 없음, `profiles`에 `weekly_goal_km` 컬럼 없음 → 둘 다 신설. (TRD 설계 블록엔 `weekly_goal_km numeric` 있음)
  - 05_server_guards가 클라이언트의 `profiles` UPDATE에서 어떤 컬럼을 되돌리는지 확인 — `weight_kg`는 현재 편집 허용됨. `weekly_goal_km`도 사용자 편집 허용 컬럼으로 추가.

### AC-03 (타인 프로필 조회) — 노출: 티어 · 획득 뱃지 · 누적 요약
- 진입점: 랭킹 리스트(홈 `full_ranking_page.dart`, `ranking_widgets.dart`)에서 항목 탭 → `/users/:id` (또는 `/profile/:id`).
- 노출 내용:
  - 티어(`profiles.current_tier`) + 시즌 진행률
  - 누적 요약: 누적 거리 / 러닝 횟수 / 레벨 (전부 `profiles` 공개 캐시 필드)
  - 획득 뱃지 갤러리 (기존 badge_gallery 재사용, 미획득/진행률은 본인만 → 타인은 획득분만)
  - 역대 최고 티어(TI-09) — `season_histories_select_visible`로 이미 타인 행 조회 가능
- **최근 러닝 목록은 노출 안 함** → `runs` RLS는 손대지 않는다.
- **필요한 RLS 변경**: `user_badges`에 공개 SELECT 정책 추가(타인의 `revoked=false` 행 조회 허용). 현재는 `user_badges_select_own`만 존재.
  - `is_seen` 등 개인 상태 컬럼이 타인에게 노출되지만 민감정보 아님. 판단은 backend가.

## 담당 분배

| 담당 | 작업 |
|------|------|
| architect | `AppUser.weeklyGoalKm` 추가(+ freezed 재생성), 타인 프로필용 뷰모델/provider 구조(본인 `currentProfileProvider`와 분리한 `userProfileProvider(id)`), 획득 뱃지 조회 provider 분기 설계. `_workspace/*_architect_ac02-ac03.md` |
| backend | 마이그레이션: (1) `profiles.weekly_goal_km numeric` + CHECK(0~정상범위), 05 가드 화이트리스트에 추가 (2) `avatars` Storage 버킷 + RLS(본인 폴더 쓰기, 공개 읽기) (3) `user_badges` 공개 SELECT 정책. 원격 적용은 사용자 승인 후. `_workspace/*_backend_ac02-ac03.md` |
| ui | (1) 프로필 편집 화면 — 표시이름/사진(image_picker)/체중/주간목표, `profile_page.dart`의 "설정" 아이콘 → 편집 진입 배선 (2) 타인 프로필 화면 — 랭킹에서 진입, 티어/뱃지/누적요약 (3) 라우터에 `/users/:id` 추가. `_workspace/*_ui_ac02-ac03.md` |
| qa | 모델↔스키마↔RLS↔UI 경계, 특히 weekly_goal_km snake/camel, Storage 정책, user_badges 공개 조회가 본인 갤러리(미획득 표시)에 회귀 없는지 |

## 참고 파일
- `lib/models/app_user.dart` — visibility 필드 없음(추가 안 함), weeklyGoalKm 추가
- `lib/features/profile/presentation/profile_page.dart` — "설정" 아이콘 자리표시자(line ~275)
- `lib/features/home/presentation/full_ranking_page.dart`, `lib/features/home/presentation/widgets/ranking_widgets.dart` — 진입점
- `lib/features/gamification/presentation/badge_gallery_page.dart` — 뱃지 갤러리 재사용
- `supabase/migrations/20260819140500_05_server_guards.sql` — 클라 쓰기 가드
- `supabase/migrations/20260819140700_07_rls.sql` — RLS
- 최신 마이그레이션 번호: 52
