# Runnit :: 카카오 OAuth 등록 체크리스트 + 게스트(anon) RLS 확장

- 작성: backend-engineer / 2026-08-20
- 대상 프로젝트: `xwtbwexcofcgmbvktwdo` (`https://xwtbwexcofcgmbvktwdo.supabase.co`)
- 관련 마이그레이션: `supabase/migrations/20260820120000_17_anon_guest_access.sql`
  (원격 적용 이름: `18_anon_guest_access` — 원격 이력에 이미 `17_remove_points_ranking_metric`이
  올라가 있어 번호가 하나씩 밀렸다. 파일명 번호(로컬)와 원격 이력 번호는 이 시점부터 1 차이가 난다.)

---

## 1. 게스트 모드 RLS/GRANT 확장 (적용 완료)

### 공개된 것

| 테이블 | anon SELECT | 정책 | GRANT |
|---|---|---|---|
| `badges` | 전체 행 | `badges_select_anon` (`using (true)`) | `grant select ... to anon` |
| `leaderboard_entries` | **`scope = 'global'` 행만** | `leaderboard_select_anon_global` | `grant select ... to anon` |

기존 `to authenticated` 정책(`badges_select_all`, `leaderboard_select_all`)은 **건드리지 않았다**.
정책은 OR로 합쳐지고 롤이 달라 서로 간섭하지 않으므로, 로그인 사용자의 동작은 이전과 100% 동일하다.

### 차단 유지된 것 (실측 확인)

`set role anon` 상태에서 직접 조회해 확인했다:

```
badges                    -> VISIBLE rows=29
leaderboard_entries       -> VISIBLE rows=0   (테이블 자체가 아직 비어 있음)
profiles                  -> BLOCKED: permission denied for table profiles
runs                      -> BLOCKED: permission denied for table runs
user_badges               -> BLOCKED: permission denied for table user_badges
challenges                -> BLOCKED: permission denied for table challenges
challenge_participations  -> BLOCKED: permission denied for table challenge_participations
run_summaries (view)      -> BLOCKED: permission denied for view run_summaries
```

`information_schema.role_table_grants` 기준 anon이 가진 권한은 `badges: SELECT`, `leaderboard_entries: SELECT` 둘뿐이다.
INSERT/UPDATE/DELETE는 어느 테이블에도 없다.

### 판단 근거: 왜 랭킹을 `scope = 'global'`로 제한했나

요청은 "랭킹 전체 공개"였지만 `ranking_scope` enum은 `global | crew | friends` 세 값이다.
`crew`/`friends` 스코프 행은 순위 자체보다 **"누가 어느 크루 소속인가 / 누구와 친구인가"라는 관계 정보**를
순위표 형태로 드러낸다. 로그인 사용자에게는 기존대로 전부 보이지만(정책 무변경), 익명 사용자에게까지
관계 그래프를 흘릴 이유가 없어 anon 정책만 `global`로 좁혔다.
→ 게스트가 크루/친구 탭을 열면 **에러가 아니라 빈 결과**가 온다. UI는 이 상태에서 로그인 유도 화면을 띄우면 된다
(flutter-ui-designer에게 전달 필요).

### 남는 노출 (의도적으로 허용)

`leaderboard_entries`에는 집계 시점 스냅샷인 `username` / `display_name` / `avatar_url`이 비정규화돼 있고,
글로벌 랭킹이 공개되는 이상 이 세 필드도 익명 사용자에게 보인다.

- **판단**: 요구사항이 "랭킹 전체 공개"이므로 그대로 진행한다. 랭킹 UI는 이름+아바타 없이는 성립하지 않는다.
- **잔여 리스크**: `display_name`은 사용자가 자유 입력하는 필드라 실명을 넣는 사람이 나올 수 있다.
  이건 RLS로 막을 문제가 아니라 **프로필 편집 UX에서 다룰 문제**다 —
  "랭킹에 공개되는 이름입니다" 같은 안내 문구를 프로필 편집 화면에 넣는 것을 권장한다.
  (별도 판단이 필요하면: 랭킹 공개 여부를 프로필 단위 opt-out으로 두고 `refresh_leaderboard()`에서
  제외하는 방식이 다음 후보다. 이번 범위 밖.)

### get_advisors(security) 재검증 결과

anon 권한 확장 후 재실행. **anon 확장으로 새로 생긴 경고는 없다.** 남아 있는 WARN 2건은 동일 함수 1개에 대한 것이다:

| 레벨 | 대상 | 내용 |
|---|---|---|
| WARN | `public.rls_auto_enable()` | SECURITY DEFINER 함수를 anon이 RPC로 호출 가능 |
| WARN | `public.rls_auto_enable()` | 동일 — authenticated 롤 |

- 이 함수는 **Runnit 마이그레이션이 만든 것이 아니라 Supabase 플랫폼이 심어둔 이벤트 트리거 함수**다
  (`returns event_trigger`, 새 테이블 생성 시 RLS를 자동으로 켜주는 가드).
- `event_trigger` 반환 함수는 PostgREST RPC로 실제 호출이 불가능하고, 이벤트 트리거 컨텍스트 밖에서
  실행하면 즉시 에러가 난다. 실효 위험 없음 → 조치하지 않았다. 플랫폼 관리 객체이므로 임의 변경도 피했다.
- 참고: https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable

---

## 2. `handle_new_auth_user()` 트리거 — 카카오 대응 (수정함)

### 발견한 문제

06_auth_bootstrap.sql 원본은 `raw_user_meta_data`에서 `username` / `display_name` / `avatar_url` 키만 읽는다.
이 키들은 이메일+비밀번호 가입 시 클라이언트가 `signUp(data: ...)`로 직접 넣어주던 것이고,
**GoTrue가 OAuth 프로바이더 응답으로 채우는 키 이름은 다르다.** 카카오는 대략 다음이 들어온다:

```
iss, sub, provider_id, name, full_name, nickname, picture, avatar_url, email(동의 시), email_verified
```

`display_name` 키는 **오지 않는다.** 원본 그대로 두면 카카오로 가입한 모든 사용자의 `profiles.display_name`이
NULL이 되어 랭킹/프로필에 표시할 이름이 없어진다. 로그인 수단이 카카오 하나뿐이므로 = 전원.

### 수정 내용 (마이그레이션 17에 포함)

- `display_name` 폴백 체인: `display_name` → `full_name` → `name` → `nickname` → NULL, 50자 절단
- `avatar_url` 폴백 체인: `avatar_url` → `picture`
- `username` 기반값 체인에 `preferred_username` / `user_name` 추가 (기존: 명시 username → 이메일 로컬파트 → `'runner'`)
- 함수 재정의로 되살아나는 기본 EXECUTE 권한을 14/15와 동일하게 다시 회수

### 이메일 미동의 케이스 — 확인 완료

카카오는 이메일 제공이 **선택 동의 항목**이라 `auth.users.email`이 NULL일 수 있다.
원본의 `'runner'` 폴백 + 충돌 시 4자리 랜덤 접미사 루프는 이 경우에도 정상 동작한다.
실제로 원격 DB에 카카오 형태의 `auth.users` 행을 넣어 트리거 결과를 확인하고 즉시 삭제했다 (테스트 후 `auth.users` / `profiles` 모두 0행 복귀):

| 케이스 | 입력 | 생성된 username | display_name | avatar_url |
|---|---|---|---|---|
| 이메일 미동의 + `name` 제공 | email=null, name/full_name="홍길동", avatar_url | `runner` | `홍길동` | `https://k.kakaocdn.net/x.jpg` |
| 이메일 동의 + `nickname`만 | email=`runner.kim@kakao.com`, nickname="러너킴", picture | `runner.kim` | `러너킴` | `https://k.kakaocdn.net/y.jpg` |

주의: 카카오 닉네임은 대개 한글이고 `username`은 `^[a-zA-Z0-9._-]{2,30}$` 제약이 있어 ASCII 외 문자가 제거된다.
따라서 이메일 미동의 사용자의 최초 핸들은 `runner`, 이후 가입자는 `runner_0417` 같은 형태가 된다.
**의도된 동작이다** — 핸들은 온보딩에서 사용자가 직접 정하게 하는 것이 맞다.
→ mobile-architect / flutter-ui-designer에게: 신규 가입 후 "핸들 설정" 온보딩 스텝이 필요하다.

---

## 3. 카카오 OAuth 프로바이더 등록 체크리스트 (사용자 수동 작업)

> 이 절차는 대시보드 수동 작업이다. backend-engineer는 Supabase Auth 프로바이더 설정을 자동화할 도구가 없다.

### 3-1. Kakao Developers 콘솔에서 확인/설정

- [ ] https://developers.kakao.com → 내 애플리케이션 → 해당 앱 선택
- [ ] **앱 키 → REST API 키** 복사 → Supabase의 *Client ID*로 쓴다
- [ ] **카카오 로그인 → 활성화 설정: ON** (꺼져 있으면 인가 요청이 즉시 실패한다)
- [ ] **카카오 로그인 → 보안 → Client Secret**: 코드 발급 후 **활성화 상태: 사용함**으로 설정
      → 이 값이 Supabase의 *Client Secret*이다. 생성만 하고 "사용함"으로 바꾸지 않으면
      Supabase가 secret을 함께 보낼 때 불일치가 날 수 있으니 상태까지 확인할 것
- [ ] **카카오 로그인 → 동의항목**: 최소 `profile_nickname`. 프로필 이미지가 필요하면 `profile_image`.
      이메일(`account_email`)은 선택 동의로 두어도 되고 아예 요청하지 않아도 된다
      (§2에서 이메일 없는 경우 동작을 확인 완료)

### 3-2. Redirect URI 등록 (정확히 이 문자열)

- [ ] Kakao Developers → **카카오 로그인 → Redirect URI**에 등록:

```
https://xwtbwexcofcgmbvktwdo.supabase.co/auth/v1/callback
```

경로 끝에 슬래시를 붙이지 말 것. 이 URI는 **Supabase가 받는 주소**이고, 앱 딥링크(§3-4)와는 별개다.

### 3-3. Supabase 대시보드 설정

- [ ] Dashboard → 프로젝트 `xwtbwexcofcgmbvktwdo` → **Authentication → Sign In / Providers → Kakao**
- [ ] **Enable Sign in with Kakao**: ON
- [ ] **Kakao Client ID**: 3-1에서 복사한 REST API 키
- [ ] **Kakao Client Secret**: 3-1의 Client Secret
- [ ] Save
- [ ] 저장 후 화면에 표시되는 Callback URL이 §3-2 문자열과 **동일한지 눈으로 대조**

### 3-4. 앱 복귀 딥링크 (모바일 리다이렉트)

`supabase_flutter`의 `signInWithOAuth(OAuthProvider.kakao, redirectTo: ...)`는
브라우저 세션이 끝난 뒤 **앱 커스텀 스킴**으로 돌아온다. 현재 코드베이스에 이미 정의된 값:

- `lib/core/auth/auth_config.dart` → `appScheme = 'io.runnit.app'`, 콜백 호스트 `login-callback`
- 즉 리다이렉트 URL = **`io.runnit.app://login-callback`**

체크리스트:

- [ ] Supabase Dashboard → **Authentication → URL Configuration → Redirect URLs**에 추가:
      `io.runnit.app://login-callback`
      (와일드카드로 `io.runnit.app://*`도 가능하나, 정확한 값을 권장)
- [ ] iOS `ios/Runner/Info.plist` → `CFBundleURLTypes` / `CFBundleURLSchemes`에 `io.runnit.app` 등록
- [ ] Android `android/app/src/main/AndroidManifest.xml` → `MainActivity`의 intent-filter에
      `<data android:scheme="io.runnit.app" android:host="login-callback" />` 등록
      (`android:launchMode="singleTask"` 권장)

> ⚠️ **architect 산출물 확인 후 보완 필요**
> mobile-architect가 병행 작업 중이며 `_workspace/*_auth_architecture.md`는 아직 생성되지 않았다.
> 위 스킴 문자열은 architect가 이미 커밋한 `lib/core/auth/auth_config.dart`에서 읽은 **현재 값**이다.
> architect 산출물이 나오면 스킴/호스트가 바뀌지 않았는지 대조하고, 바뀌었다면
> Supabase Redirect URLs 등록값과 위 두 플랫폼 설정을 함께 갱신해야 한다.
> (플랫폼 설정 파일은 architect 담당 범위라 backend-engineer가 손대지 않았다.)

### 3-5. 동작 확인

- [ ] 앱에서 카카오 로그인 → 브라우저 → 동의 → 앱 복귀 → 세션 생성
- [ ] SQL로 확인: `select id, email, raw_user_meta_data from auth.users;`
      → `raw_app_meta_data.provider = 'kakao'`
- [ ] `select id, username, display_name, avatar_url from public.profiles;`
      → 트리거가 만든 행이 있고 `display_name`이 카카오 닉네임으로 채워졌는지
- [ ] 로그아웃(게스트) 상태에서 랭킹 탭 / 뱃지 카탈로그가 뜨는지, 마이페이지/기록은 로그인 유도로 빠지는지

---

## 4. 후속 전달 사항

- **flutter-ui-designer**: 게스트 상태에서 `crew`/`friends` 랭킹은 에러가 아니라 **빈 배열**로 온다.
  빈 상태를 "데이터 없음"이 아니라 "로그인하면 볼 수 있어요"로 렌더해야 한다.
- **mobile-architect**: (a) 딥링크 스킴 확정값 대조 요청(§3-4), (b) 신규 가입 후 핸들 설정 온보딩 스텝 필요(§2).
- **qa-integration-tester**: anon 세션(publishable key만 사용)으로 `badges` / `leaderboard_entries(scope=global)`
  두 엔드포인트만 200이 나오고 나머지는 401/403이 나오는지 교차 검증 요청.
