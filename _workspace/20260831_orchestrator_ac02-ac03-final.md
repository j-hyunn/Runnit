# AC-02 / AC-03 최종 정리 (orchestrator)

작성일: 2026-08-31 · 상태: **구현 완료, 마이그레이션 53~56 원격 적용 완료**

## 원격 적용 (2026-08-31, xwtbwexcofcgmbvktwdo)
- 53 (weekly_goal_km), 55 (user_badges_select_public), 56 (username 고정) — apply_migration
- 54 버킷 — apply_migration / 54 storage.objects 정책 4종 — apply_migration 이 owner 권한 부족(42501)으로 거부 → execute_sql 로 적용(대시보드 SQL 에디터 동등). **원격 반영됨, supabase_migrations 이력에는 정책 부분 없음** (파일엔 있으므로 db reset/브랜치 DB 는 정상). 파일 헤더에 기록.
- 검증: `weekly_goal_km` 컬럼 1, avatar 정책 4, avatars 버킷 1, user_badges 공개정책 1, 가드에 username 잠금 확인. `get_advisors(security)` 신규 경보 없음(기존 6건뿐).

## 결과

`flutter analyze` No issues · `flutter test` 251건 통과.

### AC-05 (기록 공개 범위) — 삭제 완료
PRD v1.7 / TRD v0.17 / ARCHITECTURE v0.11 / HARNESS 이력. `visibility` 컬럼·enum 설계 폐기.

### AC-02 (프로필 편집)
- `AppUser.weeklyGoalKm` 신설 (`lib/models/app_user.dart`)
- `/profile/edit` — `edit_profile_page.dart` (표시이름·사진·체중·주간목표, username 읽기 전용)
- 아바타: `avatar_service.dart` + `image_picker` (`avatars/{uid}/{ts}.ext`, 512px 리사이즈, 2MiB·jpeg/png/webp)
- 마이페이지 "설정" 아이콘 → `/profile/edit`

### AC-03 (타인 프로필 조회)
- `/users/:userId` — `user_profile_page.dart` (티어·시즌 진행률·누적 요약·역대 최고 티어·획득 뱃지)
- `other_profile_providers.dart` — `userProfileProvider` / `userBadgesByIdProvider` / `userSeasonHistoriesProvider` / `bestTierOfProvider` (전부 autoDispose.family)
- 진입점: 홈 랭킹 미리보기 + 전체 랭킹 행 탭. 게스트 비활성, 본인 행은 마이 탭 전환
- 노출 금지(체중·신장·생년월일·주간목표·이메일·개별러닝)를 위젯 테스트로 못박음

## QA 지적 처리 (PASS 12 / CONFIRMED 3)

| # | 처리 |
|---|------|
| F-1 랭킹 본인 행 탭 → 홈 탭 스피너 갇힘 | 진입점에서 본인 행 갈라냄(`home_page`·`full_ranking_page`) + `user_profile_page` 방어 분기 `pop()` 우선. ✅ |
| F-2 `username` 고정이 클라에만 | 마이그레이션 56(`trg_profiles_guard` UPDATE 시 되돌림) + `_editablePatch`에서 키 제거. ✅ |
| F-3 리포지토리 주석 "화이트리스트" 오기 | "블랙리스트"로 정정. ✅ |

## 마이그레이션 (53~56, 전부 원격 미적용)

| # | 파일 | 내용 |
|---|------|------|
| 53 | `..._53_profile_weekly_goal.sql` | `profiles.weekly_goal_km double precision` + CHECK (`null or (>0 and <=500)`) |
| 54 | `..._54_avatars_storage_bucket.sql` | `avatars` 버킷 + `storage.objects` RLS (읽기 공개, 쓰기 본인 폴더) |
| 55 | `..._55_user_badges_public_select.sql` | `user_badges_select_public` 파일화 (**원격엔 이미 존재하는 드리프트 정책** — 적용은 no-op) |
| 56 | `..._56_username_immutable.sql` | `trg_profiles_guard` 재정의 — UPDATE 시 `new.username := old.username` |

### ⚠️ 배포 순서 (U-1, QA)
`_editablePatch`는 `weekly_goal_km` 키를 항상 전송한다. **53 미적용 상태에서 프로필 저장은 `PGRST204`로 전부 실패**(표시이름·사진·체중 포함). → 53을 AC-02 클라이언트 배포보다 먼저 적용.
적용 순서: 53 → 54 → 55 → 56. `get_advisors` 재확인 권장.

## 남은 것 / 후속

- **실기기 검증**: 아바타 HEIC→jpeg 재인코딩 시 확장자↔MIME 일치, `image_picker` 권한 흐름, Storage 업로드 지연
- **AC-04 착수 시**: 계정 삭제가 `storage.objects`를 cascade 하지 않음 → 고아 아바타 파일 정리 경로 필요 (TRD §4.5·§14)
- `weeklyGoalKm`는 현재 편집 폼에서만 소비 — 홈/프로필의 주간 목표 대비 진행률 위젯은 별도 과제 (모델 주석이 전제하는 위젯이 아직 없음)
- 서브에이전트 3종이 세션 사용량 한도로 조기 종료됨 — F-1/F-2/F-3 수정은 orchestrator가 직접 마무리

## 산출물
- `_workspace/20260831_191012_architect_ac02-ac03.md`
- `_workspace/20260831_154000_backend_ac02-ac03.md`
- `_workspace/20260831_192935_ui_ac02-ac03.md`
- `_workspace/20260831_193521_qa_ac02-ac03.md`
