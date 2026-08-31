# Runnit TRD (Technical Requirements Document)

| 항목 | 내용 |
|------|------|
| 문서 버전 | v0.18 |
| 작성일 | 2026-08-27 |
| 작성자 | jehyun (Claude Code 하네스 산출) |
| 상태 | **살아있는 문서 — 구현 반영본.** §3 Dart 코드·§4 DDL·§6 API의 원문은 Phase 0 설계 시점 버전이며 **실제 정본은 `lib/models/*.dart`와 `supabase/migrations/00~42`**다. 각 절 상단의 "구현 갱신" 노트가 실제 상태를 가리킨다 |
| 근거 문서 | [`docs/PRD.md`](./PRD.md) v1.5 (확정), [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md) v0.4, 실제 구현(`lib/`, `supabase/migrations/`) |

**변경 이력**
| 버전 | 변경 내용 |
|------|----------|
| v0.1 | 최초 작성. `docs/ARCHITECTURE.md`의 구조 결정을 구현 가능한 스펙(데이터 모델 코드, DDL, API, 검증 규칙)으로 세분화 |
| v0.2 | 뱃지 카탈로그 확장(30종 → 158개 템플릿) 설계 반영. `Badge`에 `category`(16종)·`scope`(permanent/seasonal)·`description`·`seasonId` 필드 추가, `tierLabel`→`badgeGrade`로 개명(시즌 티어 시스템과 명칭 혼동 방지). 카탈로그 원본은 `docs/badge-catalog.csv` |
| v0.3 | 뱃지 판정 실제 구현 완료(§10.1) — `runs` 트리거 기반 `evaluate_badges`/`evaluate_badge_condition`, `condition_type` 44→40종 중 사실상 전량 판정 가능. 시즌 뱃지 인스턴스 발급을 실제로 구현(`{templateId}@{seasonId}`, `ensure_season_badge_instances()`, §3.6 상단 정정 노트). 티어 도달 시각 이력 테이블 `tier_change_history` 신규 추가. 2026-08-26 사용자 요청으로 `seasonCumulativeDistance`/`seasonFinisher` 카테고리와 소속 뱃지 9종 삭제(158→148 템플릿, 16→14 카테고리, `condition_type` 44→40종) |
| v0.4 | 뱃지 백로그 설계 결정 7건 반영(`_workspace/20260826_000340_gamification_badge-backlog-decisions.md`) — **XP/레벨 공식 확정**(§3.8 신설, `total_points`→`total_xp` 개명·만렙 60), **주 단위 스트릭 + 1회 유예 규칙 확정**, `season_weekly_rank_lte`의 `bucket` 도메인 확정, device source 토큰 7종·OR 표현식 문법 확정, §10.1의 미문서화 가정표를 §10.2 정본 규칙으로 교체, 음력 룩업 테이블 채택. `district_diversity_gte`(`route_district_3`/`route_district_10`) 사용자 요청으로 삭제(148→146 템플릿, `condition_type` 40→39종) |
| v0.5 | **기기 벤더 모델 중재 확정**(`_workspace/20260826_012000_architect_device-vendor-arbitration.md`) — 병렬 워크트리의 두 상충 설계(배열 `runs.device_vendors` vs 스칼라 `runs.device_source`) 중 **배열 안 채택**, 스칼라 안의 OR 문법(`_or_`)·판정 대상 규칙은 흡수. 토큰 **5종 확정**(`watchWearOS`/`external`/`manual` 불채택). §3.1.2 뱃지 매칭 시맨틱 신설(배열 겹침 `&&` 단일 규칙), §4.0 벤더 DDL 신설, §3.1 `RunSampleSource` 초안 코드블록을 구현값(`phone`/`watch`/`external`)으로 정정, §4.1 매핑표의 잘못된 `watchApple → watch_apple` 행 교체, §14 #9 해소·#10 신설. `device_both_used` 설명문에서 "단독" 제거 |
| v0.6 | **뱃지 백로그 7건 실제 구현·적용 완료**(마이그레이션 36~41, Supabase `xwtbwexcofcgmbvktwdo`). §3.8·§10.2가 설계 확정 문서였던 것을 라이브 스키마 사실로 갱신 — `device_vendor` enum + `runs.device_vendors`(36), `district_diversity_gte` 삭제 + `condition_type` CHECK 39종·`category` CHECK 14종·`bucket` 도메인 CHECK(37), `lunar_holidays` 테이블 2026~2040(38), `total_points`→`total_xp`/`awarded_points`→`awarded_xp` 개명 + XP 4원천 + 60레벨 정수 배열 + 주간 스트릭 4컬럼 + XP 갱신 트리거 2개 + `evaluate_badges` 3패스 수렴 루프(39), `leaderboard_entries.reached_at` + PRD §8.2 3단계 타이브레이크(40), 판정 스텁 5종 전량 해제 + §5 임계값 정본화 + 스플릿 선형 보간(41). **`evaluate_badge_condition`의 `raise notice … 보류` 스텁이 0개가 됐다.** §4.2 신설(음력 룩업), §4.3 신설(랭킹 캐시 실제 테이블명) |
| v0.7 | **거리 허용오차 통일**(마이그레이션 42) — `session_first_long_distance`(고정 98%)와 `session_distance_gte` 5종(허용오차 없음)을 `pb_first_achieved`/`pb_time_lte`와 동일한 `목표 − min(목표×2%, 300m)`로 통일. gamification-designer 확인 완료(§14 #13·#15 해소). 완화 방향이라 소급 회수 없음, `evaluate_badges` 재실행으로 미지급분 즉시 채움 |
| v0.8 | **공유 카드 규격 확정 — 9:16 투명 오버레이 스티커**(§3.9.2). 같은 날 16:9 가로 밴드로 바꿨다가, 사용자가 준 정확한 레퍼런스 이미지(9:16 세로, 투명 배경 + 흰색 콘텐츠, 그림자 없음)를 확인하고 되돌렸다 — 최종 확정은 **9:16, 배경/그림자/모서리 전부 없음, 세로 1열 중앙 정렬**(워드마크 → 시각 → 아트 → [성취 3종만 헤드라인] → 수치 스택), 기록 카드 수치 라벨은 레퍼런스 그대로 영문(`Distance`/`Pace`/`Time`). 규격 변경 히스토리 표는 §3.9.2 참조 |
| v0.10 | **"Phase 0 초안"에서 "구현 반영 살아있는 문서"로 승격.** (1) §2 확정 스택을 실제 `pubspec.yaml`에 맞춤 — 지도 `flutter_naver_map` → **`flutter_map`+`latlong2`**(PRD §7과 불일치, ARCHITECTURE §12-#2), 로컬 저장소 `🔴 미정` → **drift 확정**, `riverpod_generator` 제거(수동 Provider), FCM `NT-01~08` → **미도입(Phase 2)**, 누락 패키지(`flutter_svg`/`share_plus`/`shared_preferences`/`intl`/`collection`/`uuid`/`logger`) 추가. (2) §3 상단에 "Dart 코드는 설계 스냅샷, 정본은 `lib/models/`" 노트 추가 — 실제 enum은 `RunRecordType`이 아니라 `ActivityType`+`RunStatus`+`SyncStatus`, 랭킹은 `RankingPeriod`/`RankingMetric`/`RankingScope` 4축. (3) **§6 "API / Edge Function 사양"은 폐기** — Deno Edge Function은 구현되지 않았고, 업로드는 PostgREST upsert + `runs` 트리거 체인이다(§6.0 노트). (4) §13 Phase 0 DoD를 실제 완료 상태로 갱신 |
| v0.9 | **성취 축하 연출을 다이얼로그→풀페이지로 전환, 공유 버튼을 PB 전용으로 축소**(§3.9.3, PRD v1.4·HI-10). `AchievementCelebrationHost`가 `showDialog` 대신 `Navigator.of(context, rootNavigator: true)` + `MaterialPageRoute(fullscreenDialog: true)`로 진짜 풀페이지를 띄운다(하단 네비바 우회, §7 구조와 동일 패턴). 글로우 링·컨페티·엘라스틱 팝인으로 구성된 `_AchievementBurst` 애니메이션 신설. **일반 뱃지·티어 승급은 공유 버튼을 받지 않는다** — PB만 받는다(사용자 확정, 2026-08-27). `summary_achievements.dart`의 인라인 축하·억제 카운터(`achievementCelebrationSuppressors`)를 전부 제거 — 전역 호스트 하나가 유일한 소비 지점이 되면서 §14 #20(프레임 경합)이 원인 자체가 사라져 해소됨 |
| v0.12 | **러닝·뱃지 삭제 불가 + 시즌 중 티어 강등 없음**(PRD v1.6, 마이그레이션 43, Supabase `xwtbwexcofcgmbvktwdo`). §9의 "기록 삭제 시 재계산" 항목을 재작성 — 사용자 삭제 경로가 없으므로 티어 하향 시나리오는 부정 판정(`is_flagged`)뿐이고, 그 경우에도 `recompute_season_tier`가 같은 시즌이면 `current_tier := greatest(tier_for_distance(dist), 직전)`로 등급을 유지한다(`season_distance_meters`만 실제값으로 하락). §3.5의 `tier_change_history` 서술에서 "강등" 시나리오 표현 정리. 스테일 데이터 1건(`stier_silver@2026-Q3`, 테스트 계정) 삭제 |
| v0.13 | **HI-07 서버 강제 — 저장된 러닝은 제목·메모만 수정 가능**(마이그레이션 51, **원격 적용 완료** 2026-08-31 — over-limit 행 0건이라 51-1 정리 UPDATE는 no-op, 조작 UPDATE 되돌리기 스모크 테스트 통과, advisor 신규 경보 없음). §4.4 신설: `trg_runs_guard`의 UPDATE 분기가 터미널 상태(`completed`/`discarded`) 행에 대해 `new := old` 후 `title`/`note`만 재적용한다 — 화이트리스트라 앞으로 추가되는 컬럼도 자동 보호되고, 되돌리기가 파생값 재계산보다 앞서므로 편집이 페이스·XP·티어·랭킹·뱃지를 흔들지 않는다. 예외를 던지지 않는 이유는 오프라인 멱등 재 upsert(`syncPending`)를 깨뜨리지 않기 위함. `runs_title_len`(60자)·`runs_note_len`(500자) CHECK 백스톱 + 가드의 `btrim`→절단→`NULL` 정규화. PRD v1.6에서 이미 제거된 사용자 삭제 경로의 잔재인 RLS `runs_delete_own` 정책 삭제(테이블 GRANT는 유지 — 회수하면 미완결 세션 "버리기"가 42501로 실패한다). §5 RLS 표 `runs` 행·§9 갱신. QA 지적 반영 — 51-1 정리 UPDATE를 `set_config('runnit.server_write','on')`로 감싸 AFTER 트리거 4종의 대량 재집계를 차단(C-5), 51-2에 체크포인트 업로드 도입 시 우회 경로 경고 주석 추가(L-3) |
| v0.14 | **HI-06 후속 (2026-08-31)** — (1) `season_histories` RLS 서술 정정: §5 표가 "본인 행만 select"라고 적었으나 실제 `season_histories_select_visible`(마이그레이션 21)은 `is_voided=false or user_id=auth.uid()` — 무효 아닌 타인 행도 `authenticated`에게 공개다(TI-09/AC-03 전제). `tier_change_history`와 한 셀에 묶여 있던 것을 분리. (2) **마이그레이션 52** — `recompute_season_tier`의 `season_histories.best_weekly_rank` 서브쿼리에 `and le.tier is not null` 추가. 마이그레이션 23 이후 `leaderboard_entries`에 통합 보드(`tier IS NULL`)와 티어별 보드가 공존해 `min(rank)`가 두 스코프를 섞을 수 있었다(마감 후 수정 불가 컬럼). 43 함수 본문에서 이 한 줄 외 변경 없음. §9 갱신. **원격 적용 완료**(2026-08-31, `xwtbwexcofcgmbvktwdo`) |
| v0.15 | **AC-02 프로필 편집 / AC-03 타인 프로필 백엔드**(마이그레이션 53~55, 2026-08-31, 원격 적용 완료 — v0.18 참조). §4.5 신설. (1) `profiles.weekly_goal_km double precision` + CHECK `> 0 and <= 500`, `NULL`=미설정 — **단위가 km**인 프로젝트 유일한 거리 컬럼이고 서버 판정에 쓰이지 않는 표시 전용이다. `trg_profiles_guard`는 **블랙리스트**(서버 전용 컬럼만 되돌림)라 가드 변경 없이 편집이 열린다 — `runs`의 화이트리스트 가드(§4.4)와 기본값이 정반대라는 점을 §4.5 표로 대비시켜 기록. (2) `avatars` Storage 버킷 신설 + `storage.objects` RLS — 읽기 전체 공개(게스트 랭킹이 남의 아바타를 그린다), 쓰기는 `(storage.foldername(name))[1] = auth.uid()::text`로 본인 폴더만, 용량/MIME 제한은 버킷 설정(2MiB·jpeg/png/webp). (3) `user_badges_select_public` — 타인의 `verified and not revoked` 행 공개. **스키마 드리프트 정정**: 이 정책은 원격 DB에 **이미 살아 있었으나 마이그레이션 파일 어디에도 없었다**(적용 이력은 52에서 끝난다 — 대시보드/임시 SQL로 만들어진 것). 원격에는 있고 파일에는 없으니 `db reset`·스테이징·브랜치 DB에서만 AC-03이 조용히 깨지는 상태였다. 술어를 라이브와 한 글자도 다르지 않게(`user_id <> auth.uid() and revoked = false and verified = true`) 맞추고 drop-then-create로 감싸 **원격 적용이 진짜 no-op**이 되도록 했다. 인덱스는 마이그레이션 25의 `user_badges_public_idx`가 동일 술어로 이미 존재. ⚠️ 부수효과: Realtime 구독에 타인 행 이벤트가 도달하므로 `user_id` 필터가 유일한 방어선이 된다. **`runs` RLS는 손대지 않았다** — AC-03은 타인의 러닝 목록을 노출하지 않는다 |
| v0.18 | **마이그레이션 53~56 원격 적용 완료**(2026-08-31, `xwtbwexcofcgmbvktwdo`). 53/55/56 은 `apply_migration`. 54 는 버킷만 `apply_migration`, `storage.objects` 정책 4종은 `apply_migration`이 `42501 must be owner of table objects`로 거부돼 `execute_sql`(대시보드 SQL 에디터 동등)로 적용 — 원격 반영됐으나 `supabase_migrations` 이력엔 정책 부분이 빠졌다(파일엔 있음, `db reset`/브랜치 DB 정상). `get_advisors(security)` 신규 경보 없음 |
| v0.17 | **AC-02/03 QA 수정**(2026-08-31, 마이그레이션 56 추가). F-1 랭킹에서 본인 행 탭 시 홈 탭이 스피너에 갇히던 것 — 진입점(`home_page`·`full_ranking_page`)에서 본인 행을 `/users/:me` push 대신 마이 탭 전환으로 갈라내고, `user_profile_page` 방어 분기는 `pop()` 우선으로. F-2 `username` 서버 강제 고정(마이그레이션 56 — `trg_profiles_guard`가 UPDATE 시 되돌림) + 클라 `_editablePatch`에서 키 제거. F-3 리포지토리 주석의 "화이트리스트" 오기 정정. §4.5 갱신 |
| v0.16 | **AC-05(기록 공개 범위) 삭제**(PRD v1.7, 2026-08-31 사용자 확정). `profiles.visibility` 컬럼·`ProfileVisibility` enum 설계(§3.3 레거시 블록, §4 보존 DDL)를 폐기. §5 RLS 표 `profiles` 행에서 "AC-03/AC-05" → "전체 공개(`profiles_select_all`), 공개 범위 분기 없음"으로 정정. §14 이슈 #24(알림 문구 `display_name`이 비공개 설정을 우회) 비쟁점화 — 우회할 설정이 사라졌다 |
| v0.11 | **지도 SDK를 `flutter_map`(OSM 타일) → `flutter_naver_map`으로 교체**(2026-08-28, 사용자 결정, ARCHITECTURE v0.4 §12-#2 해소). §2 확정 스택의 지도 행 갱신. `latlong2`는 **앱 내부 표준 좌표 모델로 유지**하고 `NLatLng` 변환은 지도 위젯 경계(`lib/core/map/map_geo.dart`)에 가둔다. 지도 표면 생성은 `mapSurfaceBuilderProvider`(`lib/core/map/map_surface.dart`) 하나로 격리 — 글로벌 확장 시 SDK 교체 지점이자 위젯 테스트 스텁 주입점이다(`flutter_map`의 `TileProvider`에 묶여 있던 `mapTileProviderOverride`는 제거). OSM 전용 `core/widgets/osm_attribution.dart` 삭제(네이버 SDK가 로고·저작권 자체 렌더). NCP 클라이언트 ID는 플레이스홀더 상태 — 배포 전 교체 필요 |

> 📌 **원천 우선순위**: PRD > ARCHITECTURE.md > 이 문서. 요구사항 ID(TR-xx, HI-xx 등)는 `docs/PRD.md` §5 기준.

---

## 1. 목적 및 범위

이 문서는 `docs/ARCHITECTURE.md`에서 정의한 구조를 **실제로 구현 가능한 수준**까지 구체화한다. 대상 범위는 PRD §11 로드맵의 **Phase 0**(아키텍처·데이터 모델·Supabase 스키마 확정) 산출물이며, Phase 1 착수 시 이 문서의 스키마/모델을 기준으로 코드를 작성한다.

---

## 2. 확정 기술 스택

PRD §7의 확정 스택을 실제 패키지 단위로 구체화한다.

> ⚠️ **실제 정본은 `pubspec.yaml`이다.** 아래는 현재 반영 상태.

| 영역 | 선택 | 패키지 | 비고 |
|---|---|---|---|
| 앱 프레임워크 | Flutter | — | iOS/Android 동시 출시, iOS 15+ / Android 8.0(API 26)+ |
| 상태관리 | Riverpod | `flutter_riverpod` | **코드 생성 안 씀** — Provider는 `*_providers.dart`에 수동 선언 |
| 불변 모델·직렬화 | freezed | `freezed`, `json_serializable`, `freezed_annotation`, `json_annotation` | `build_runner`로 생성. 수동 `toJson`/`fromJson` 금지 |
| GPS | `geolocator` | 백그라운드 지원, 정확도 옵션(`LocationAccuracy`) |
| 백그라운드 | `flutter_background_service` | 화면 꺼짐/앱 전환 시 트래킹 세션 유지 |
| 웨어러블 센서 | `health` | HealthKit(iOS)/Health Connect(Android) 통합 래퍼 |
| 권한 | `permission_handler` | iOS/Android 권한 흐름 통합 |
| 라우팅 | `go_router` | 딥링크(OAuth 콜백), 중첩 라우트(바텀 네비 shell) |
| 지도 | **`flutter_naver_map`** + **`latlong2`**(앱 내부 좌표 모델) | PRD §7 확정 SDK. NCP 클라이언트 ID 필요(`core/map/naver_map_config.dart`). 좌표는 `latlong2`의 `LatLng`가 내부 표준이고 **지도 위젯 경계에서만** `NLatLng`로 변환한다(`core/map/map_geo.dart`). 표면 생성 주입점 `core/map/map_surface.dart`(교체 여지·테스트 스텁). `run_map_view.dart`(진행 중), `run_route_map.dart`(HI-02 정적 경로) |
| 차트 | `fl_chart` | 월간 통계 막대(`monthly_chart.dart`). HI-02 페이스 그래프는 미구현 |
| SVG | `flutter_svg` | 뱃지 아트·아이콘 |
| 공유 | `share_plus` | 공유 시트(HI-08) |
| 백엔드 클라이언트 | `supabase_flutter` | Auth/Postgres(PostgREST)/Realtime. **앱은 Edge Function을 호출하지 않는다**(`push-dispatch`는 pg_cron이 부른다) |
| 푸시 | Firebase Cloud Messaging | `firebase_core`, `firebase_messaging` | 서버는 마이그레이션 44~48(§6-N), 클라이언트는 `core/notifications/`(초기화·권한·토큰 동기화·딥링크) + `features/notifications/`(알림함·설정). **FCM 프로젝트·서비스 계정과 네이티브 설정 파일은 운영이 넣어야 한다** — 없으면 초기화가 실패해도 앱은 뜨고 푸시만 꺼진다 |
| 로컬 영속 저장소 | **drift** | `drift`, `sqlite3_flutter_libs`, `path`, `path_provider` | `tracking/data/local_run_database.dart`. §14-#1 해소 |
| 로컬 KV | `shared_preferences` | 경량 설정·플래그 |
| 유틸 | `intl`(날짜/페이스 포맷), `collection`, `uuid`(클라이언트 RunRecord id), `logger` | |
| 백엔드 인프라 | Supabase | Postgres + Auth + Realtime + **pg_cron** + `pg_net`/Vault, **Edge Function은 `push-dispatch` 하나뿐** | 제품 로직은 전부 마이그레이션 SQL(트리거·함수). Edge Function 예외의 근거는 §6-N.6 |

---

## 3. 데이터 모델 사양 (Dart)

모든 모델은 `lib/models/`에 위치하며 `freezed` + `json_serializable`로 생성한다.

> ⚠️ **이 절의 Dart 코드 블록은 Phase 0 설계 스냅샷이다. 필드 단위 정본은 [`lib/models/*.dart`](../lib/models)** — 구현이 발전하면서 아래와 어긋난 곳이 있다:
> - 모든 enum은 `lib/models/enums.dart`에 집약. `RunSampleSource` = `phone`/`watch`/`external`(§3.1.1), `DeviceVendor` = `phone`/`watchApple`/`watchGarmin`/`watchOther`/`unknown`.
> - `RunRecord`는 `RunRecordType` 대신 **`ActivityType`(outdoor_run/indoor_run/trail_run/walk) × `RunStatus`(recording/paused/completed/discarded)** 를 쓰고, `SyncStatus`(local/pending/synced/failed)·`deviceVendors`·서버 확정 `isFlagged`/`flagReason`/`awardedXp`를 포함한다. 시간은 `elapsedSeconds`/`movingSeconds` 두 종류.
> - `UserProfile`이 아니라 **`AppUser`**(테이블 `profiles`) — `username`/`displayName`/`heightCm`/`weightKg`/`birthDate`/`gender`/`preferredUnit`/`weeklyGoalKm`(AC-02, 2026-08-31 추가) + 통계 캐시(`totalDistanceMeters`/`totalMovingSeconds`/`totalRunCount`/`totalXp`/`level`) + 티어(`currentTier`/`seasonDistanceMeters`/`tierSeasonId`) + 주간 스트릭.
> - `Season`은 클래스가 아니라 **경계 계산 유틸**(`Season.idAt`/`startOf`/`endOf`). `UserSeasonTier` 모델은 없다(→ `AppUser`/`profiles` 컬럼).
> - `RankingEntry`는 `period`(daily/weekly/monthly/all_time) × `metric`(distance/duration/run_count) × `scope`(global/crew/friends) × `tier` 4축 + `ownerTier`·`rankDelta`·표시 스냅샷(`username`/`avatarUrl`).
> - `SeasonHistory`(테이블 `season_histories`), `ChallengeParticipation`이 추가로 존재.

### 3.1 `RunSample` — 단일 GPS/센서 포인트

```dart
enum RunSampleSource { phone, watch, external }   // 초안의 watchApple/watchGarmin은 §3.1.1에서 벤더 축으로 분리됨

@freezed
class RunSample with _$RunSample {
  const factory RunSample({
    required double lat,
    required double lng,
    required DateTime timestamp,
    double? altitude,
    double? accuracy,          // 미터 단위, 스무딩 판단에 사용
    int? heartRate,            // 웨어러블 연동 시에만 존재
    required RunSampleSource source,
  }) = _RunSample;

  factory RunSample.fromJson(Map<String, dynamic> json) => _$RunSampleFromJson(json);
}
```

- `accuracy`는 GPS 스무딩(§8.2) 판정에 쓰인다.

#### 3.1.1 소스 축과 벤더 축의 분리 (2026-08-26 확정 · 구현 반영됨)

> 📌 **이 절은 2026-08-26 mobile-architect 중재의 결과다.** gps-tracking-engineer(러닝 단위 **배열** `runs.device_vendors`, 토큰 5종)와 gamification-designer(러닝 단위 **스칼라** `runs.device_source`, 토큰 7종)가 병렬 워크트리에서 양립 불가능한 두 설계를 냈고, **배열 안을 정본으로 채택**하되 스칼라 안의 OR 표현식 문법(`_or_`)과 판정 대상 세션 규칙을 흡수했다. 결정 근거·폐기 사유는 `_workspace/20260826_012000_architect_device-vendor-arbitration.md`.

위 초안은 `source` **한 축**에 "어떤 경로로 들어왔나"와 "어느 기기가 만들었나"를 함께 담았다. 구현하면서 **직교하는 두 축으로 분리**했다.

| 축 | 타입 | 답하는 질문 | 값 | 위치 |
|---|---|---|---|---|
| 소스 | `RunSampleSource` / pg `run_sample_source` | 어떤 경로로 **언제** 들어왔나 | `phone` / `watch`(실시간) / `external`(사후 동기화) | 샘플 단위 + `runs.sources` |
| 벤더 | `DeviceVendor` / pg `device_vendor` | **어느 기기**가 만들었나 | `phone` / `watchApple` / `watchGarmin` / `watchOther` / `unknown` | **러닝 단위** `runs.device_vendors` |

**분리 사유**
- 한 축으로 접으면 `watchGarminLive` × `watchGarminImported` 식으로 값이 곱해진다. Garmin은 항상 동기화 경유(§8.4)라 벤더와 실시간성의 상관이 높지만 **동치는 아니다** — Apple Watch 워크아웃도 나중에 HealthKit에서 통째로 임포트하면 `external`이 된다.
- 실시간성 축은 이미 UI 계약("워치 데이터는 동기화 후 반영됩니다" 배너)이 소비 중이라 벤더로 덮어쓸 수 없다.

**벤더를 샘플이 아니라 러닝 단위에 두는 이유**
1. 뱃지 조건(`device_source_count_gte` = "애플워치로 누적 50회")이 전부 **러닝 단위 집계**다.
2. 폰 GPS + 워치 심박 세션에서 좌표는 전부 폰이 만든다. 샘플마다 벤더를 달면 3600개 샘플에 상수를 복제하는 셈이다.
3. 한 세션에 두 기기가 동시에 기여하는 것이 P1의 기본 경로이므로 **배열**이어야 한다. 스칼라 `device_vendor` 하나로는 그 세션을 폰 기록이라 부를지 워치 기록이라 부를지 손실 없이 표현할 수 없다.

**값 문자열 규약 — 이 목록이 최종 확정본이다.** `phone` / `watchApple` / `watchGarmin` / `watchOther` / `unknown`. 프로젝트의 snake_case 규약에 대한 **유일한 예외**이며, 사유는 이미 시드된 뱃지 카탈로그(`docs/badge-catalog.csv`, `badge_catalog.condition_value` jsonb, `device_watchApple_1` 같은 뱃지 id(PK))가 camelCase를 쓰고 있기 때문이다. 저장 라벨을 따로 두면 토큰↔라벨 매핑이 어긋날 때 **뱃지가 조용히 미지급**된다. 따라서 **뱃지 조건 토큰 / Postgres enum 라벨 / Dart `@JsonValue` / `wire_enums.dart` 네 곳을 같은 문자열로 통일**하고 매핑 테이블을 두지 않는다.

**벤더 판별 시점** — 폰 단독 러닝은 세션 시작 시점부터 `phone` 확정. 워치는 HealthKit `sourceRevision.source.bundleIdentifier`/Health Connect `dataOrigin.packageName`에서 **지표가 도착하는 즉시**(실시간 경로) 또는 **워크아웃 임포트 시점**(P1)에 확정한다. 판별 한계는 §8.4.1.

**빈 배열 `{}`의 의미** — `{phone}`과 **다르다**. 수동 입력, 기기 정보 없는 임포트, 마이그레이션 이전 레거시 행이 `{}`다. `unknown`은 "외부 기여가 있었으나 기기를 식별하지 못함"이라는 또 다른 상태다.

**채택하지 않은 토큰과 사유** — 대안 설계가 제안한 `watchWearOS` / `external` / `manual` 3종은 넣지 않았다.

| 토큰 | 불채택 사유 |
|---|---|
| `watchWearOS` | 이 토큰을 요구하는 뱃지가 없고, Health Connect 패키지명만으로 "Wear OS 워치"와 "그 외 안드로이드 웨어러블"을 신뢰성 있게 가를 방법이 없다(§8.4.1). 판별할 수 없는 값을 enum에 두면 실제로는 전부 `watchOther`로 떨어지면서 스키마만 커진다. `watchOther`가 이미 Wear OS·Samsung·Polar·Coros·Suunto를 포괄한다 |
| `external` | **소스 축의 값이다**(`RunSampleSource.external` = 사후 동기화 경로). 벤더 enum에 넣으면 §3.1.1이 방금 분리한 두 축이 다시 섞인다 |
| `manual` | 수동 입력은 기여한 기기가 **없는** 상태이고 `device_vendors = {}`로 이미 표현된다. 활동 유형은 `RunRecordType.manual`이 따로 들고 있어 세 번째 이름이 된다 |

#### 3.1.2 뱃지 조건 매칭 시맨틱 (정본)

`device_source_count_gte` / `device_source_diversity_gte` 두 `condition_type`이 `runs.device_vendors`를 읽는 방식이다. **규칙은 하나뿐이다.**

**표현식 문법** (대안 설계에서 흡수 — 배열/스칼라와 무관하게 유효하다)

```
expr  := token ( "_or_" token )*
token := §3.1.1의 5개 값 중 하나 (대소문자 구분, exact match)
```

| 규칙 | 확정 |
|---|---|
| 구분자 | **`_or_`** — 소문자, 앞뒤 밑줄 포함 |
| AND 연산자 / 괄호 / 공백 | **없다.** 1단계 평면 OR만 |
| 미지 토큰 | 파싱 오류. 그 뱃지는 `false`로 두고 **로그를 남긴다**. 조용히 무시 금지 |
| 검증 정규식 | `^[a-z][A-Za-z0-9]*(_or_[a-z][A-Za-z0-9]*)*$` |

**매칭 규칙 (단일)** — 러닝 1건이 `expr`에 매칭되는 조건은 **배열 겹침**이다. 두 `condition_type` 모두 같은 규칙을 쓴다.

```sql
run.device_vendors && ARRAY[tokens(expr)]::public.device_vendor[]
```

`_or_`의 OR가 배열 겹침으로 그대로 떨어진다 — 표현식마다 다른 연산자를 쓰지 않는다.

**판정 대상 세션 (공통)**: `status = 'completed' AND NOT is_flagged`. 카탈로그 설명이 "기록한 러닝이 처음 **검증**될 때"이므로 플래그된 기록은 제외한다.

**`device_source_count_gte`** — `{"source": "<expr>", "count": N}`
→ 대상 세션 중 매칭되는 건수 `>= N`.
예: `device_watchApple_50` = `device_vendors && '{watchApple}'`인 세션 50건. 폰 GPS + 애플워치 심박 하이브리드 세션도 **포함된다** — 카탈로그 설명 "애플워치로 기록한 러닝"이 곧 그 뜻이다.

**`device_source_diversity_gte`** — `{"sources": ["<expr1>", "<expr2>", …]}`
→ **모든** i에 대해 매칭 세션이 1건 이상 (원소 간 AND, 원소 내부 OR).
예: `device_both_used` = `{"sources": ["phone", "watchApple_or_watchGarmin"]}`
→ `device_vendors && '{phone}'` 세션 ≥1건 **그리고** `device_vendors && '{watchApple,watchGarmin}'` 세션 ≥1건.

⚠️ **"서로 다른 세션" 요구는 두지 않는다.** 폰 GPS + 애플워치 심박 세션 1건(`{phone, watchApple}`)이 두 원소를 동시에 충족하면 `device_both_used`가 지급된다. 대안 설계는 이 원소를 "폰 **단독** 기록"으로 서술했으나, 그 서술은 스칼라 모델에서 `phone`이 필연적으로 "폰만"을 뜻했던 **모델의 한계를 옮겨 적은 것**이지 독립적인 제품 요구가 아니다. 뱃지의 짧은 설명은 원래 "폰 + 워치 모두 사용"이고, 하이브리드 세션은 그 문장을 그대로 만족한다. 올라운더를 받으려고 워치를 두고 나가야 하는 규칙은 제품으로서 더 나쁘다. **`docs/badge-catalog.csv`의 `device_both_used` 설명문에서 "단독"을 제거해 코드와 문구를 일치시켰다.**

### 3.2 `RunRecord` — 완결된 러닝 세션

```dart
enum RunRecordType { outdoor, treadmill, manual }

@freezed
class RunRecord with _$RunRecord {
  const factory RunRecord({
    required String id,
    required String userId,
    required DateTime startedAt,
    required DateTime endedAt,
    required double distanceMeters,
    required Duration duration,
    required List<RunSample> samples,
    required RunRecordType type,
    int? avgHeartRate,
    double? estimatedCalories,
    String? title,
    String? memo,
    @Default(false) bool hasRouteSamples,  // PRD §5.7 반영 판정 기준 — 서버가 최종 확정
    @Default(false) bool flagged,          // 서버 재검증 결과, 클라이언트는 읽기 전용
  }) = _RunRecord;

  factory RunRecord.fromJson(Map<String, dynamic> json) => _$RunRecordFromJson(json);
}
```

- `deviceVendors: List<DeviceVendor>` (§3.1.1): 이 세션에 기여한 기기 벤더. 폰 단독 = `[phone]`, 폰+애플워치 = `[phone, watchApple]`, 워치 워크아웃 임포트 = `[watchApple]`, 수동 입력 = `[]`(빈 배열은 `[phone]`과 **다른 뜻**). 뱃지 `device_source_count_gte`/`device_source_diversity_gte`의 원천이며, "폰 단독 기록"은 `== [phone]`(정확히 일치), "워치 사용"은 `watchApple`/`watchGarmin` **포함** 여부로 판정한다. enum 선언 순서로 정렬해 payload를 결정적으로 유지한다.
- `hasRouteSamples`: 클라이언트가 잠정 세팅하지만 **서버가 업로드 시점에 재검증하여 최종값을 확정**한다(ARCHITECTURE §6.3). 이 필드가 `false`면 `type`과 무관하게 티어·랭킹 미반영.
- `flagged`: §8 서버 검증 실패 시 서버가 설정. 클라이언트에서 직접 쓰지 않는다.
- 랩 기록(TR-07, 1km 구간)은 `samples`로부터 파생 계산하며 별도 저장 필드를 두지 않는다(중복 저장 방지) — 필요 시 조회 시점에 계산하거나, 성능 이슈가 확인되면 `laps: List<LapSplit>` 캐시 필드를 추가한다.

### 3.3 `User` (`Profile`)

```dart
@freezed
class UserProfile with _$UserProfile {
  const factory UserProfile({
    required String id,               // == auth.uid()
    required String displayName,
    String? photoUrl,
    double? weightKg,                 // 칼로리 계산(TR-06)에 필요
    double? weeklyGoalKm,
    required double totalDistanceMeters,   // 캐시 필드, 서버 트리거로 갱신
    required int totalRunCount,
    required DateTime createdAt,
  }) = _UserProfile;

  factory UserProfile.fromJson(Map<String, dynamic> json) => _$UserProfileFromJson(json);
}
```

> ⚠️ 위 블록은 Phase 0 설계 잔재다. 실제 모델은 `lib/models/app_user.dart`의 `AppUser`이며 `weeklyGoalKm`(2026-08-31 추가)를 포함한다. **`visibility` / `ProfileVisibility`는 AC-05 삭제로 폐기**(v1.7, 2026-08-31) — 만들지 않는다.

### 3.4 `Season` / `UserSeasonTier`

```dart
enum Tier { bronze, silver, gold, platinum }

@freezed
class Season with _$Season {
  const factory Season({
    required String id,          // 예: '2026-Q3'
    required DateTime startsAt,
    required DateTime endsAt,
    @Default(false) bool isShortened,  // 첫 시즌/말 시즌 단축 여부 (PRD §8.5)
  }) = _Season;

  factory Season.fromJson(Map<String, dynamic> json) => _$SeasonFromJson(json);
}

@freezed
class UserSeasonTier with _$UserSeasonTier {
  const factory UserSeasonTier({
    required String userId,
    required String seasonId,
    required double cumulativeDistanceMeters,  // 절대평가 기준값
    required Tier currentTier,
    required DateTime tierUpdatedAt,
  }) = _UserSeasonTier;

  factory UserSeasonTier.fromJson(Map<String, dynamic> json) => _$UserSeasonTierFromJson(json);
}

/// 티어 기준선 (PRD §5.3.2 확정)
const Map<Tier, double> tierThresholdsMeters = {
  Tier.bronze: 0,
  Tier.silver: 25000,
  Tier.gold: 100000,
  Tier.platinum: 250000,
};
```

### 3.5 `RankingEntry` (`WeeklyRankingCache`)

```dart
@freezed
class RankingEntry with _$RankingEntry {
  const factory RankingEntry({
    required String userId,
    required Tier tier,                  // 랭킹 스코프 파티션 키 — PRD §5.4
    required String weekId,               // 예: '2026-W34' (KST 월~일)
    required double weeklyDistanceMeters,
    required int rank,
    required int tierParticipantCount,    // "상위 N%" 계산용 (PRD RK-04)
    required DateTime computedAt,
  }) = _RankingEntry;

  factory RankingEntry.fromJson(Map<String, dynamic> json) => _$RankingEntryFromJson(json);
}
```

동점 처리(PRD §8.2)는 서버 집계 쿼리에서 `(weeklyDistanceMeters desc, runCount asc, firstReachedAt asc, totalDuration asc)` 순서로 정렬해 `rank`를 확정한다 — 클라이언트는 산정하지 않는다.

> ⚠️ **구현 갱신(2026-08-25, 시즌 뱃지 활성화)**: 아래 §3/§4의 `seasons` / `user_season_tier` /
> `weekly_ranking_cache` 테이블 설계는 **실제로 만들어지지 않았다**. 실제 구현(마이그레이션
> 19~24, 31, 32)은 다음으로 대체됐다 — 이 문서가 실제 스키마와 어긋난 채 방치되지 않도록
> 여기 명시한다:
> - `seasons` → `season_id_at(ts)` / `season_start(id)` / `season_end(id)` 순수 계산 함수
>   (분기는 달력에서 결정론적으로 유도되고 운영자가 조정할 절차가 없어 테이블이 불필요하다는
>   판단, 마이그레이션 20).
> - `user_season_tier` → `profiles.current_tier` / `profiles.season_distance_meters` /
>   `profiles.tier_season_id` (마이그레이션 19, 22) + 시즌 마감 스냅샷은
>   `season_histories`(마이그레이션 21)에 남는다.
> - `weekly_ranking_cache` → 기존 `leaderboard_entries`를 그대로 재사용
>   (`period='weekly', metric='distance', scope='global', tier=<티어>`). 5분 주기로 티어별
>   4개 보드가 갱신되고(마이그레이션 23 `refresh_all_leaderboards`), 지난 주차 행은 삭제되지
>   않고 누적 보존된다.
> - `badges.season_id`는 `seasons` FK가 아니라 `season_id_at`과 같은 정규식(`^\d{4}-Q[1-4]$`)으로만
>   검증되는 text 컬럼이다(마이그레이션 25 `badges_season_id_scope`).
> - 시즌 뱃지 인스턴스 id는 `{templateId}_{season}` 이 아니라 **`{templateId}@{seasonId}`**
>   형식이다(예: `stier_platinum@2026-Q3`) — `badges_id_slug_format` CHECK가 `@`를 구분자로 허용.
>   인스턴스 발급은 `ensure_season_badge_instances()`가 담당하며 `evaluate_badges` /
>   `sync_my_season` / `reset_stale_seasons` 3개 진입점에서 멱등 호출된다(마이그레이션 31).
> - `evaluate_badge_condition`의 seasonal 19종은 마이그레이션 32에서 18종, 마이그레이션
>   33/34에서 나머지 1종(`season_max_tier_reached_before_pct`)까지 전부 실제 판정으로
>   구현됐다. 이 마지막 1종은 `profiles.current_tier`/`season_histories`만으로는 "시즌 중
>   특정 티어에 처음 도달한 시각"을 알 수 없어(전자는 현재 상태만, 후자는 시즌 마감
>   스냅샷만 보유) 신규 테이블 `public.tier_change_history(user_id, season_id, tier,
>   reached_at)`를 추가했다 — `recompute_season_tier`(마이그레이션 22)가 티어 판정 후
>   **직전보다 실제로 상승했을 때만**(enum 비교, 하드코딩 없음) 이 테이블에 최초 1행을
>   기록한다(UNIQUE(user_id, season_id, tier) + ON CONFLICT DO NOTHING이 동시성 안전망).
>   같은 시즌에 유지 시에는 기록하지 않는다(마이그레이션 43 이후로는 시즌 중 강등
>   자체가 없다 — PRD v1.6 TI-08). `season_max_tier_reached_before_pct`는
>   `enum_range(null::public.tier)`에서 유도한 "최고 티어"(하드코딩 금지) 도달 시각을
>   `season_start + (season_end - season_start) * pct/100.0`과 비교한다.
>   ⚠️ **소급 불가**: 이 테이블은 2026-08-25(마이그레이션 33/34) 이후의 상승분만 담는다.
>   그 이전에 이미 어떤 티어에 도달해 있던 기존 유저는 도달 "시각"을 역산할 근거가
>   없어(season_histories는 마감 스냅샷뿐) 이력이 소급 생성되지 않는다 — 근사치도 만들지
>   않았다(false negative만 발생, 오지급 없음). 이후 실제로 다시 그 티어로 오르는 순간부터
>   (다음 시즌) 정확하게 기록된다.

### 3.6 `Badge` / `UserBadge`

뱃지 카탈로그(**146개 템플릿, 14개 카테고리** — 2026-08-26 `seasonCumulativeDistance`/`seasonFinisher`
카테고리와 소속 뱃지 9종, 그리고 `district_diversity_gte` 2종(`route_district_3`/`route_district_10`,
역지오코딩 인프라 부담 대비 가치 부족)을 사용자 요청으로 삭제해 158/16에서 축소)의 확정 스펙은
[`docs/badge-catalog.csv`](./badge-catalog.csv) 참고. `category`·`scope`는 이 카탈로그에서 역산한 필드다.

```dart
enum BadgeTriggerType { session, cumulative }

/// 영구 뱃지(평생 누적 기준, 딱 한 번만 존재) vs 시즌 뱃지(시즌 스코프 판정,
/// 시즌마다 새 인스턴스 재발급 가능 — 획득한 인스턴스는 영구 보존).
enum BadgeScope { permanent, seasonal }

enum BadgeCategory {
  cumulativeDistance,        // 누적거리 (permanent)
  cumulativeCount,           // 누적횟수 (permanent)
  longestStreak,             // 최장스트릭 (permanent)
  personalBest,              // PB갱신 (permanent, 검증된 실외 기록만)
  singleSessionDistance,     // 단일세션거리 (permanent)
  timeOfDayWeekday,          // 시간대요일 (permanent)
  routeExploration,          // 경로탐험 (permanent, GPS 기반)
  specialDay,                // 특별한날 (permanent)
  paceSpeed,                 // 페이스속도 (permanent)
  deviceIntegration,         // 기기연동 (permanent)
  level,                     // 레벨 (permanent) — XP 공식 미정, 값은 GM-04 별도 설계 후 확정
  seasonTier,                // 시즌티어달성 (seasonal, GM-07)
  seasonWeeklyRank,          // 시즌주간랭킹 (seasonal, RK-06)
  seasonEvent,               // 시즌한정이벤트 (seasonal, GM-08 P1)
  // seasonCumulativeDistance/seasonFinisher는 2026-08-26 사용자 요청으로
  // 카테고리·소속 뱃지 9종(sdist_*/sfin_*, 마이그레이션 35)을 완전히 삭제했다.
}

@freezed
class Badge with _$Badge {
  const factory Badge({
    required String id,        // slug, 예: 'dist_cum_1000km'
    required String name,      // 표시명 (예: '천리길') — badge-catalog.csv의 display_name
    required String description, // 획득 조건 설명 — 뱃지 갤러리 상세(GM-03)에 노출
    required BadgeCategory category,
    required BadgeScope scope,
    required BadgeTriggerType triggerType,
    required String conditionType,             // 판정 함수 **디스패치 키**. badge-catalog.csv의
                                                 // condition_type 열과 1:1 (현재 39종).
                                                 // condition 맵만으로는 어느 판정 함수를 쓸지 알 수 없다.
    @Default(<String, dynamic>{})
    Map<String, dynamic> condition,            // 판정 함수 입력 파라미터. 키 집합은 conditionType마다
                                                 // 다르다 (예: cumulative_distance_gte → {"distanceKm": 1000},
                                                 // season_weekly_rank_lte → {"tier": "gold", "bucket": "top1"}).
                                                 // 파라미터가 없는 종류는 {} — NULL도 {}와 동치로 취급한다.
    required String badgeGrade,                // bronze/silver/gold/platinum/diamond/special — 뱃지 자체 표시 등급.
                                                 // ⚠️ scope=seasonal인 시즌티어달성(stier_*) 4종을 제외하면
                                                 // 실제 시즌 티어 시스템과 무관한 순수 장식용 값이다.
    String? seasonId,          // scope=seasonal 템플릿이 시즌 시작 시 실제 발급된 인스턴스일 때만 값 존재
                                 // (예: '2026-Q3'). 카탈로그의 템플릿 자체는 null.
  }) = _Badge;

  factory Badge.fromJson(Map<String, dynamic> json) => _$BadgeFromJson(json);
}

@freezed
class UserBadge with _$UserBadge {
  const factory UserBadge({
    required String id,              // UUID. 서버 생성 — markBadgesSeen()이 이 값으로 개별 행을 갱신한다.
    required String userId,
    required String badgeId,         // seasonal이면 템플릿이 아니라 인스턴스 id (`{templateId}@{seasonId}`)
    required DateTime earnedAt,
    @Default(false) bool verified,   // 서버 재검증 결과
    @Default(false) bool isSeen,     // 획득 연출(GM-02)을 봤는지. RLS상 클라이언트가 쓸 수 있는 유일한 컬럼.
    String? sourceRunId,             // 이 뱃지를 촉발한 러닝. 2026-08-26 공유 카드(HI-08)를 위해
                                     // 모델에 노출 — 카드에 그 러닝의 경로/거리를 얹어야 한다(§3.9).
                                     // cumulative 뱃지·원본 삭제 시 null.
    Badge? badge,                    // 조인 임베드(선택) — 갤러리 조회 왕복 절감
  }) = _UserBadge;

  factory UserBadge.fromJson(Map<String, dynamic> json) => _$UserBadgeFromJson(json);
}
```

### 3.7 판정 로직 — 순수 함수 시그니처 (클라이언트/서버 공유 규칙)

```dart
/// 클라이언트에서 잠정 판정, 서버(Postgres 함수/트리거)가 동일 규칙으로 재검증.
bool isTierPromotion({
  required Tier currentTier,
  required double cumulativeDistanceMeters,
}) {
  final next = Tier.values.elementAtOrNull(currentTier.index + 1);
  if (next == null) return false;
  return cumulativeDistanceMeters >= tierThresholdsMeters[next]!;
}

/// 뱃지 조건 판정 — 순수 함수. 부수효과 없음(gamification-designer 협약).
bool evaluateBadgeCondition(Badge badge, Map<String, num> context);
```

서버 판정은 Postgres 함수(`evaluate_badge_condition` 디스패치, `compute_level`, `recompute_season_tier` 등)이므로 위 로직은 **동일한 임계값 상수**(`TierX.thresholdMeters`, `xp_level_thresholds()` 등)를 클라이언트 Dart와 서버 SQL 양쪽에 정수 배열/상수로 중복 정의한다. 값 변경 시 세 곳(Dart · SQL · 이 문서)을 함께 갱신한다.

### 3.8 XP / 레벨 사양 (PRD GM-04) — 2026-08-26 확정

정본: [`_workspace/20260826_000340_gamification_badge-backlog-decisions.md`](../_workspace/20260826_000340_gamification_badge-backlog-decisions.md) §1.

#### 3.8.1 이름 규약 — `points`는 XP가 아니다

PRD §5.6이 "포인트"를 **Phase 4의 상품 교환 화폐**(거리 비연동 적립)로 확정했으므로,
레벨용 재화는 **XP**로 개명하고 `points`라는 이름을 Phase 4에 반납한다.

| 현재 | 변경 후 |
|---|---|
| `profiles.total_points` | `profiles.total_xp` |
| `runs.awarded_points` | `runs.awarded_xp` |
| `compute_awarded_points(...)` | `compute_run_xp(...)` |
| `compute_level(p_total_points)` | `compute_level(p_total_xp)` |
| `AppUser.totalPoints` | `AppUser.totalXp` |

#### 3.8.2 XP 4원천 (전부 원본 데이터에서 재계산 가능 — 증분 가산 금지)

```
total_xp = XP_run + XP_streak + XP_badge + XP_tier
```

| 원천 | 규칙 |
|---|---|
| **XP_run** | `compute_run_xp(status, is_flagged, distance_m, moving_s, elev_gain_m, **activity_type**)`. 완주·비플래그·≥500m 세션마다. **실외**: `min(20 + floor(m/100) + floor(floor(m/100)×pace_mult) + min(floor(max(elev,0)/10),100), 1000)`, `pace_mult` = 0.30(≤300s/km) / 0.20(≤360) / 0.10(≤420) / 0(그 외·거리<2km). **실내·수동**: `min(20 + floor(m/100), 300)` — 보너스 없음(검증 불가 입력의 어뷰징 차단) |
| **XP_streak** | §10.2 활동 주 1개마다 `30 × min(n, 5)` (n = 스트릭 내 순번). **유예로 메운 주는 0** |
| **XP_badge** | `verified AND NOT revoked` 뱃지의 `badge_grade`별: bronze 100 / silver 250 / gold 600 / platinum 1,500 / diamond 4,000 / special 200. **⚠️ `category='level'` 뱃지 9종은 0** (XP↔레벨 순환 차단) |
| **XP_tier** | `tier_change_history`의 distinct `(season_id, tier)`마다: silver 300 / gold 800 / platinum 2,000 (bronze 0). 시즌마다 재지급 |

#### 3.8.3 레벨 임계값 — **정본은 아래 60개 정수 배열**

유도식은 `XP_required(L) = ceil(50 × (L−1)^2.2)`, **만렙 60**. 다만 지수 역함수의
부동소수 오차가 "레벨업까지 1pt 남음" 고착 버그를 실제로 일으킨 전례가 있으므로
(`_workspace/20260819_210450_badge_rules.md` §4.3), **양쪽에 정수 배열을 그대로 심고
역함수를 계산하지 않는다.** `level(xp) = max{L : XP_LEVEL_THRESHOLDS[L] <= xp}`.

```
L1..L10   0, 50, 230, 561, 1056, 1725, 2576, 3616, 4851, 6285
L11..L20  7925, 9774, 11836, 14114, 16614, 19337, 22287, 25466, 28879, 32526
L21..L30  36412, 40538, 44906, 49519, 54380, 59490, 64851, 70465, 76334, 82461
L31..L40  88846, 95492, 102401, 109573, 117011, 124716, 132690, 140934, 149450, 158239
L41..L50  167303, 176643, 186260, 196156, 206332, 216790, 227530, 238554, 249863, 261458
L51..L60  273341, 285513, 297974, 310726, 323770, 337108, 350739, 364666, 378889, 393410
```

**구현(2026-08-26)**: 서버는 `public.xp_level_thresholds() returns integer[]`(immutable)에 60개 정수를 담고, `compute_level(p_total_xp)`이 `generate_subscripts` 로 `max{i : thresholds[i] <= xp}` 를 찾는다 — **정수 비교만** 하므로 부동소수 경계 버그가 원천적으로 없다. 클라이언트는 `LevelCurve.thresholds`(같은 60개 정수) + 이진 탐색이며, `test/gamification/level_curve_test.dart` 가 L=2..60 전수 경계를 잠근다.

`profiles.level` CHECK를 `between 1 and 60`으로(제약명 `profiles_level_range`, 구 `profiles_level_positive` 대체). `LevelCurve.maxLevel = 60`
(현행 100은 구 포인트 곡선의 잔재이고, 카탈로그 `lvl_60` 표시명이 이미 "만렙"이다).

#### 3.8.4 저장·갱신 (뷰가 아니라 저장 컬럼)

`profiles.total_xp`(int, default 0) / `profiles.level`(int, default 1) 저장 컬럼을 유지하고
`recompute_profile_stats(p_user_id)`가 4원천을 재집계해 갱신한다. 뷰로 두지 않는 이유:
① `level_gte` 판정이 프로필 1행 읽기로 끝나야 한다(뱃지 146행 루프) ② GM-04의 "레벨업 시 알림"이
old→new 전이 감지를 요구한다 ③ 원천이 3개 테이블에 흩어져 있다.

호출 트리거 3곳(**전부 적용됨 — 마이그레이션 39**):

| 트리거 | 테이블 | 담당 XP |
|---|---|---|
| `runs_01_recompute_stats` (기존) | `runs` INSERT/UPDATE/DELETE | XP-1, XP-2 |
| `user_badges_02_recompute_xp` (신규) | `user_badges` AFTER INSERT/DELETE/UPDATE OF (verified, revoked) | XP-3 |
| `tier_change_history_01_recompute_xp` (신규) | `tier_change_history` AFTER INSERT | XP-4 |

뒤의 둘은 공통 함수 `trg_recompute_xp_source()` 를 쓰며 `pg_trigger_depth() > 8` 가드가 있다.

**재진입 수렴**: 레벨 뱃지 XP=0 덕분에 2패스에서 수렴한다. `evaluate_badges` 를 "새 뱃지가 생겼으면
다시 한 번, 최대 3회" 루프로 감쌌고, 패스 끝에서만 `recompute_profile_stats` 를 한 번 호출한다.
그 사이 `user_badges` 트리거는 세션 변수 `runnit.badge_eval='on'` 을 보고 스킵한다 —
켜둔 채로 두면 한 번의 평가에서 지급된 뱃지 N개마다 전체 재집계가 N번 돌기 때문이다(결과는 동일, 비용만 N배).

⚠️ **`challenges.reward_points` 는 `total_xp` 에 들어가지 않는다.** XP 4원천에 챌린지가 없고
`reward_points` 는 Phase 4 포인트 이름이다 — 구 `recompute_profile_stats` 가 이 항을 더하던 것을 39번에서 제거했다.

### 3.9 공유 카드 뷰모델 (PRD HI-08 / HI-10) — 2026-08-26 확정

구현: `lib/features/sharing/domain/share_card_data.dart` (유니온) ·
`share_card_builder.dart` (조합 규칙) · 설계 근거는
[`_workspace/20260826_050000_architect_sharing-cards.md`](../_workspace/20260826_050000_architect_sharing-cards.md).

**신규 테이블·컬럼은 없다.** 카드 4종(성취 3종 + 러닝 기록 1종)이 필요한 값은 전부 이미 저장돼 있다:

| 카드 | 데이터 출처 |
|---|---|
| 티어 승급 | `profiles.current_tier` / `season_distance_meters` / `tier_season_id`, `user_badges`의 `stier_{tier}@{seasonId}` 인스턴스, `leaderboard_entries`(순위·모집단) |
| 뱃지 획득 | `badges` + `user_badges` (+ `source_run_id` → `runs`의 경로) |
| PB 갱신 | `badges.condition->>'distanceKm'` + `user_badges.source_run_id` → `runs` |
| 러닝 기록(`runRecap`) | `runs`(거리·시간·페이스·칼로리·경로) — 뱃지를 터뜨리지 않은 대부분의 러닝을 위한 4번째 카드. 서버 확정 성취(뱃지·PB·티어)를 주장하지 않으므로 `AchievementGate`를 적용하지 않고 `isFlagged=true`만 제외한다(2026-08-26 UI 라운드, §7.4.1) |

공유 **행위**를 기록하는 테이블(`share_events` 등)도 두지 않는다 — OS 공유 시트는 사용자가
실제로 게시했는지 앱에 돌려주지 않으므로(iOS는 취소 여부만, 대상 앱은 미공개) 게시 여부를
모르는 행은 분석에도 쓸 수 없다. 전환율이 필요해지면 도메인 테이블이 아니라 텔레메트리 이벤트로 붙인다.

```dart
enum ShareCardKind { tierPromotion, badgeEarned, personalBest, runRecap }

sealed class ShareCardData {
  ShareAthlete get athlete;      // displayName / tier / level / avatarUrl (신체 정보는 넘기지 않는다)
  DateTime get achievedAt;       // 서버 확정 시각 (UserBadge.earnedAt)
  ShareRoute? get route;         // 좌표 ≤240점. samples 우선, 없으면 routePolyline 해독
  ShareCardKind get kind;
  String get headline;           // 카드 큰 글씨
  String? get subhead;
  String get shareText;          // 공유 시트에 곁들이는 텍스트
}

final class TierPromotionCardData extends ShareCardData { Tier tier; String seasonId;
  double seasonDistanceMeters; int? rank; int? participantCount; /* topPercent 파생 */ }
final class BadgeEarnedCardData  extends ShareCardData { Badge badge; String badgeAssetPath; }
final class PersonalBestCardData extends ShareCardData { double targetKm; int? certifiedSeconds;
  double? runDistanceMeters; String badgeAssetPath; }
final class RunRecapCardData     extends ShareCardData { double distanceMeters; int movingSeconds;
  int elapsedSeconds; double? avgPaceSecPerKm; int? caloriesKcal; }
```

`RunRecapCardData`는 2026-08-26 UI 구현에서 추가됐다. HI-08은 "**기록**·성취 이미지 공유 카드"이고
대부분의 러닝은 뱃지를 터뜨리지 않으므로, 성취 카드 3종만으로는 요약 화면의 공유 버튼이 열 번 중
아홉 번 아무것도 만들지 못한다. 이 카드는 서버가 확정한 성취를 **주장하지 않는다** — 사용자가 방금
기록한 자기 러닝의 거리·시간·경로만 그리므로 PRD §8.4에 걸리지 않는다(반대로 이 카드에 뱃지·PB
문구를 얹으면 그 순간 위반이 된다). 그림은 `presentation/widgets/share_card_body.dart`가 4종을
`switch` 하나로 그리며, `sealed` union이라 카드가 늘면 컴파일 에러로 알려준다.

`freezed`를 쓰지 않는다 — 직렬화되지 않고 `copyWith`도 필요 없어 코드 생성이 순수 비용이다
(같은 계층의 `GamificationStats`/`BadgeProgress`와 동일한 판단).

#### 3.9.1 PB 카드의 `certifiedSeconds`가 null일 수 있는 이유

§10.2 `pb_time_lte`는 세션 거리가 목표의 **102%를 넘으면 GPS 샘플 선형 보간으로 목표 거리 통과
시각**을 쓴다. 그 보간값은 현재 **어디에도 저장되지 않는다**(`user_badges`에 값 컬럼이 없음).
따라서 클라이언트 규칙은:

- 세션 거리 ≤ 목표×102% → `runs.moving_seconds`. 이 구간에서는 그것이 **서버 규칙 그 자체**라 값이 정확히 일치한다.
- 초과 → **null**. 카드는 시간 없이 "5km PB 갱신"만 말한다.

클라이언트가 보간을 흉내 내지 않는 이유: 서버 확정값을 클라이언트가 재유도하면 정본이 둘이 되고,
어긋나는 순간 사용자가 인스타에 올린 기록이 앱 화면과 다른 값이 된다.

🔵 **해소 방법(P1, backend-engineer)**: `user_badges.achieved_value numeric null` 한 컬럼.
서버가 판정 시점에 확정한 값(PB 초, 스트릭 주, 주간 순위 …)을 그대로 적으면 위 폴백이 사라지고
모든 뱃지 카드가 서버 값만 그린다. §14 #18 참조.

#### 3.9.2 렌더링 방식 — 클라이언트 위젯 캡처 (확정)

`RenderRepaintBoundary.toImage()`. 출력은 항상 **1080×1920 (9:16), 배경 투명 PNG**이며,
`pixelRatio = 1080 / 카드논리폭`으로 역산해 기기 DPI와 무관하게 같은 결과를 낸다.
별도 캡처 패키지(`screenshot` 등)는 추가하지 않는다 — 그 래퍼는 우리가 직접 계산해야 하는
경계 크기를 감춘다. 공유 시트만 `share_plus: ^10.1.4`. 근거는 §14 #3 해소 항목.

##### 규격 히스토리 — 9:16 불투명 → 16:9 투명 오버레이 → 9:16 투명 오버레이

2026-08-26 하루 동안 두 번 바뀌었다. 처음엔 "배경 없는 오버레이 스티커"라는 요구를
가로로 넓은 밴드로 해석해 16:9로 만들었는데, 사용자가 준 **정확한 레퍼런스 이미지**
(396×704 픽셀, 즉 9:16 세로, 투명 배경 + 흰색 콘텐츠)를 확인하고서야 원래 의도가
"세로 스토리 캔버스에 그대로 앉는 투명 스티커"였다는 게 드러났다. 16:9로 해석한 시도는
전량 되돌렸다.

| | 최초(9:16 불투명) | 중간(16:9 투명, 폐기) | **현재(9:16 투명)** |
|---|---|---|---|
| 비율 | 9:16 | 16:9 | **9:16** |
| 해상도 | 1080×1920 | 1920×1080 | **1080×1920** |
| 배경 | `Color(0xFF101216)` 불투명 | 없음 | **없음(알파 0)** |
| 모서리 | `ClipRRect(rLg)` | 없음 | 없음 |
| 그림자/halo | 없음 | 이중 halo(텍스트)+언더스트로크(경로) | **없음(사용자 요청으로 제거)** |
| 서체 | Pretendard Variable | Orbitron + Pretendard 폴백 | **Orbitron + Pretendard 폴백**(유지) |
| 레이아웃 | 세로 3단(브랜드/본문/바닥) | 가로 밴드 3층(머리띠/본문 2열/바닥) | **세로 1열 중앙 정렬**(워드마크 → 시각 → 아트 → [헤드라인] → 수치 스택) |
| 사용 방식 | 이미지 자체를 스토리에 게시 | 사용자 사진 위 오버레이 | **사용자 사진 위 오버레이**(유지) |

- **투명 유지는 코드가 아니라 규율이다.** `ui.ImageByteFormat.png`가 알파를 보존하므로
  **위젯 트리에 불투명 배경을 넣지 않는 것**이 유일한 조건이다.
  `share_card_body_test.dart`의 "카드에 불투명 배경이 없다" 테스트가 캡처 이미지의 모서리
  알파를 직접 검사해 회귀를 막는다.
- **그림자/halo가 없는 이유:** 레퍼런스 이미지가 순수한 흰 선·글자였고, 사용자가 명시적으로
  걷어내라고 지시했다. 밝은 사진 위 대비를 카드가 강제로 만들지 않는다 — 사용자가 어떤
  사진 위에 얹을지는 카드가 알 수 없고, 대비를 넣으면 레퍼런스와 다른 그림이 된다.
- **경로는 기록 카드에서만 그린다.** 성취 카드(티어/뱃지/PB)에 경로를 얹으면 "무엇을
  달성했는가"라는 카드의 목적과 무관한 장식이 된다 — 레퍼런스도 기록 카드 한 장뿐이었다.
- **레퍼런스에 없는 3종(티어/뱃지/PB)**은 같은 시각 언어(워드마크 → 시각 → 아트 → 수치
  스택)를 쓰되, "무엇을 달성했는가"를 말해야 하므로 아트 아래에 헤드라인/부제를 추가했다.
  기록 카드는 헤드라인이 없다 — 수치 자체가 답이라 별도 문구가 군더더기다.
- ⚠️ **PRD §5.2 HI-08 원문("인스타 스토리 비율(9:16) 지원")과는 결과적으로 다시 합치됐다**
  (비율은). 다만 "배경 없는 오버레이 스티커"·"그림자 없음"은 여전히 PRD 원문에 없는
  구현 세부 확장이다 — 실사용에 문제가 없다면 PRD 갱신은 보류하되, 사용자 확인 대상으로
  남긴다.

**카드 공통 레이아웃(세로 1열, 중앙 정렬)**: `Runnit` 워드마크 → 촬영 시각(KST,
`2026.08.26  21:37` 형식) → 아트(기록=경로 폴리라인, 그 외=엠블럼/메달) → [성취 3종만]
헤드라인/부제 → 수치 스택(라벨 위 · 값 아래, 세로로 쌓음).
기록 카드의 수치 라벨은 레퍼런스 그대로 **영문**(`Distance`/`Pace`/`Time`)이고, 값도
레퍼런스와 같은 콜론 표기(`5:51 /km`)를 쓴다 — 도메인의 `paceLabel`(`4'59"/km`, 공유
캡션 등에서 계속 쓰임)과는 별개로 이 카드 그림에서만 다르게 표기한다. 나머지 3종의
라벨은 한글을 유지한다(레퍼런스가 다루지 않은 영역이라 기존 표기를 바꿀 근거가 없었다).

#### 3.9.3 성취 축하 연출 — 풀페이지 + 애니메이션, 공유는 PB 전용 (2026-08-27 확정)

구현: `lib/features/sharing/presentation/widgets/achievement_celebration.dart`.
ARCHITECTURE §7.4.1의 "두 소비 지점" 구조는 폐기됐다 — `summary_achievements.dart`는
더 이상 성취를 축하하지 않고 게이트 상태 문구(확정/잠정/비노출)만 그린다. **성취 축하는
전역 `AchievementCelebrationHost` 하나가 유일한 권한자**다: 러닝 요약 화면이 떠 있든
아니든, 새 성취가 큐에 오르면 항상 같은 풀페이지가 그 위를 덮는다.

- **다이얼로그 → 풀페이지 전환 이유**: `showDialog`는 배경 화면 위에 뜨는 오버레이라
  "성취 하나에 화면 하나"라는 무게감이 안 나오고, 좁은 다이얼로그 폭 안에서 컨페티
  애니메이션이 잘려 보였다. `Navigator.of(context, rootNavigator: true)` +
  `MaterialPageRoute(fullscreenDialog: true)`로 바꿔 `AppShell`의 하단 네비바까지
  완전히 가린다 — 공유 카드 페이지(§3.9.2)가 같은 이유로 같은 패턴을 쓴다(둘 다 처음엔
  `rootNavigator: true`를 빼먹어 네비바가 떠 있는 회귀가 있었다, 커밋 `607f8dc`).
- **`_AchievementBurst` 애니메이션**: 단일 900ms `AnimationController`가 글로우 링 확장
  (`Curves.easeOut`) · 컨페티 파티클(`_ConfettiPainter`, 고정 시드 `math.Random(7)`로
  스크린샷/골든 테스트 재현성 확보) · 뱃지 엘라스틱 팝인(`Curves.elasticOut`)을 동시에 구동한다.
- **공유 버튼은 `PersonalBestCardData`에만 있다.** `AchievementCelebrationView`는
  `if (data is! BadgeEarnedCardData && data is! TierPromotionCardData)` 조건으로
  버튼을 숨긴다. 같은 규칙이 뱃지 갤러리 상세(`badge_gallery_page.dart`의
  `_BadgeShareButton`)에도 적용돼, 어느 진입점에서 봐도 뱃지·티어 카드는 공유 버튼이
  없다. 사용자가 세 라운드에 걸쳐 범위를 좁혔다(처음엔 뱃지만 제외 → 티어도 제외) —
  최종적으로 "PB만 공유, 나머지는 풀페이지 축하로 끝"이 확정 규칙이다. PRD 반영은
  v1.4/HI-10 참조.
- **억제 카운터 삭제**: 예전에는 요약 화면이 떠 있는 동안 전역 호스트를 죽이는
  `achievementCelebrationSuppressors`(전역 `ValueNotifier<int>`)가 있었다 — 인라인
  축하와 전역 다이얼로그가 동시에 뜨는 걸 막기 위해서였다. 소비 지점이 하나로 줄면서
  이 메커니즘 자체가 필요 없어져 통째로 제거했다(`tracking_page.dart`의
  `initState`/`dispose` 훅도 함께 제거). §14 #20(프레임 경합 버그)은 이 카운터가
  없어지면서 원인이 사라져 자동 해소됐다.
- **테스트**: `test/sharing/achievement_celebration_test.dart`(신규)가
  `AchievementCelebrationView`를 네비게이션 우회하고 직접 pump해 카드 종류별
  공유 버튼 유무를 검증한다. `test/sharing/summary_achievements_test.dart`는
  게이트 문구 분기만 남기고 인라인 축하/큐 소비 테스트를 제거했다.

---

### 3.10 알림 모델 (PRD §5.10 NT-01~08) — 2026-08-28 확정

정본은 `lib/models/app_notification.dart` · `notification_settings.dart` ·
`push_device_token.dart`, enum은 `lib/models/enums.dart`의 `NotificationType` ·
`DevicePlatform`이다.

| 모델 | 테이블 | 키 | 클라이언트 쓰기 권한 |
|---|---|---|---|
| `AppNotification` | `notifications` | `id uuid` | **`read_at` 한 컬럼뿐** (`user_badges.is_seen`과 동일 규약) |
| `NotificationSettings` | `notification_settings` | `user_id` (유저당 1행) | 종류별 bool + `push_enabled` |
| `PushDeviceToken` | `push_tokens` | `token` (유저당 N행) | 본인 행 upsert/delete |

**`NotificationType` 값 = PRD 요구사항 ID 1:1** (`tier_promotion` NT-01 /
`tier_proximity` NT-02 / `season_ending` NT-03 / `rank_change` NT-04 /
`weekend_push` NT-05 / `badge_level` NT-06 / `points` NT-07 **Phase 4·미발행**).
NT-08의 "항목"이 이 값 단위이므로 요구사항보다 잘게 쪼개지 않는다 — 추월함/추월당함,
D-14/D-3 같은 뉘앙스는 전부 `notifications.payload` jsonb에 담는다
(`direction` / `days_left` / `remaining_m` / `rank` / `season_id` / `tier` /
`user_badge_id`, 그리고 딥링크용 `route`).

`points`는 enum에만 있고 `notification_settings`에는 **컬럼이 없다.** enum 값을 미리
둔 이유는 Phase 4에 서버가 그 타입을 발행했을 때 구버전 앱의 `fromJson`이 예외를 던져
알림함 전체가 깨지는 것을 막기 위해서다.

**문구(`title`/`body`)는 서버가 완성해서 저장한다.** 클라이언트가 payload로 문구를
조립하면 푸시 트레이 문구(서버 조립)와 알림함 문구(클라이언트 조립)가 갈라져 같은
사건이 두 가지로 보인다.

### 4.1-N 알림 테이블 camelCase ↔ snake_case 매핑

| Dart 필드 | Postgres 컬럼 | 타입 | 비고 |
|---|---|---|---|
| `AppNotification.id` | `notifications.id` | uuid | 서버 생성 |
| `AppNotification.userId` | `notifications.user_id` | uuid FK → `profiles.id` | |
| `AppNotification.type` | `notifications.type` | `public.notification_type` | 라벨은 `NotificationTypeWire.wire`와 동일 |
| `AppNotification.title` / `body` | `notifications.title` / `body` | text | 서버 전용 쓰기 |
| `AppNotification.payload` | `notifications.payload` | jsonb not null default `'{}'` | 미지 키 무시 규약 |
| `AppNotification.createdAt` | `notifications.created_at` | timestamptz | 정렬 인덱스 `(user_id, created_at desc)` |
| `AppNotification.readAt` | `notifications.read_at` | timestamptz nullable | **클라이언트가 쓸 수 있는 유일한 컬럼.** 부분 인덱스 `where read_at is null` |
| *(대응 필드 없음)* | `notifications.dedupe_key` | text | **서버 전용 멱등 키.** `unique (user_id, dedupe_key)`. 예: `season_ending:2026-Q3:d3`, **`rank_change:2026-W35:down:2`**(NT-04는 키 끝에 순번 `n`이 붙어 주당 상한을 unique 제약이 강제한다 — §6-N.3). 배치 재실행·트리거 중복 발화로 같은 알림이 두 번 가는 것을 DB가 막는다 |
| *(대응 필드 없음)* | `notifications.sent_at` / `send_error` | timestamptz / text | 발송 결과 로그. 알림함 표시와 무관해 모델에 없다 |
| `NotificationSettings.userId` | `notification_settings.user_id` | uuid PK FK | |
| `NotificationSettings.pushEnabled` | `notification_settings.push_enabled` | boolean default true | 마스터 스위치 |
| `NotificationSettings.tierPromotion` | `notification_settings.tier_promotion` | boolean default true | NT-01 |
| `NotificationSettings.tierProximity` | `notification_settings.tier_proximity` | boolean default true | NT-02 |
| `NotificationSettings.seasonEnding` | `notification_settings.season_ending` | boolean default true | NT-03 |
| `NotificationSettings.rankChange` | `notification_settings.rank_change` | boolean default true | NT-04 |
| `NotificationSettings.weekendPush` | `notification_settings.weekend_push` | boolean default true | NT-05 |
| `NotificationSettings.badgeLevel` | `notification_settings.badge_level` | boolean default true | NT-06 |
| `NotificationSettings.updatedAt` | `notification_settings.updated_at` | timestamptz | 트리거 갱신 |
| `PushDeviceToken.token` | `push_tokens.token` | text PK | FCM 등록 토큰 |
| `PushDeviceToken.userId` | `push_tokens.user_id` | uuid FK | 유저당 N행(기기 여러 대)이 정상 |
| `PushDeviceToken.platform` | `push_tokens.platform` | `public.device_platform` | `ios` / `android` |
| `PushDeviceToken.deviceId` | `push_tokens.device_id` | text nullable | 설치 단위 식별자. 같은 기기의 옛 토큰 정리 근거 |
| `PushDeviceToken.appVersion` | `push_tokens.app_version` | text nullable | 진단용 |
| `PushDeviceToken.updatedAt` | `push_tokens.updated_at` | timestamptz | 장기 미갱신 토큰 정리 기준 |

> ⚠️ **종류별 on/off를 jsonb 한 컬럼으로 접지 않는다.** 발송 주체가 pg_cron 배치라
> `join notification_settings s ... where s.weekend_push` 처럼 SQL 한 번으로 수신
> 거부자를 걸러내야 한다. jsonb면 매 행 키 추출이 붙고 인덱스도 걸기 어렵다.
>
> **행이 없는 사용자는 전 종류 on으로 간주한다** (서버·클라이언트 공통). 가입 직후
> 행 생성 실패로 알림이 조용히 끊기는 쪽이, 기본값을 한 번 더 보내는 것보다 나쁘다.

---

## 4. Supabase 스키마 사양 (DDL)

> 🛑 **아래 초안 DDL은 실제로 생성되지 않았다.** 라이브 스키마는 `supabase/migrations/00~42`이며, 주요 차이:
>
> | 초안 DDL | 라이브 스키마 |
> |---|---|
> | `run_records` + 별도 `run_samples` 테이블 | 단일 **`runs`** 테이블, 샘플은 `runs.samples jsonb`. 서버 전용 `is_flagged`/`flag_reason`/`awarded_points`(구 이름 유지), `route_polyline`, `sources`(`run_sample_source[]`), `device_vendors`(`device_vendor[]`) |
> | `seasons` 테이블 | **없음.** `season_id_at(ts)` / `season_start(id)` / `season_end(id)` 계산 함수 (마이그레이션 20) |
> | `user_season_tier` 테이블 | **없음.** `profiles.current_tier` / `season_distance_meters` / `tier_season_id` 컬럼 (마이그레이션 19, 22) + 마감 스냅샷은 `season_histories` (21) |
> | `weekly_ranking_cache` 테이블 | **없음.** `leaderboard_entries` 재사용 (마이그레이션 03, `period='weekly'`). §4.3 참조 |
> | `badges.season_id` FK → `seasons` | `seasons` 테이블이 없으므로 정규식 검증 text 컬럼. seasonal 인스턴스 id = `{templateId}@{seasonId}` (마이그레이션 25, 31) |
> | `user_badges` PK `(user_id, badge_id)` | `id uuid` PK 추가 + `revoked`·`is_seen`·`source_run_id` (마이그레이션 27 이후) |
>
> 실제 테이블 목록: `profiles` · `runs` · `badges` · `user_badges` · `leaderboard_entries` · `season_histories` · `tier_change_history` · `lunar_holidays` · `challenges` · `challenge_participations` (+ 뷰 `run_summaries`).
> XP/레벨·주간 스트릭·기기 벤더·음력 명절 등 확장은 §3.8 / §4.0 / §4.2 / §10.2 및 마이그레이션 36~42가 정본.
>
> 아래 블록은 Phase 0 설계 의도를 남겨두기 위해 보존한다 — 컬럼 이름·타입의 **개념**은 대체로 유효하나 테이블 이름과 배치는 위 표를 따른다.

```sql
-- ─────────────────────────────────────────────
-- 1. profiles (auth.users 확장)
-- ─────────────────────────────────────────────
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  photo_url text,
  weight_kg numeric,
  weekly_goal_km numeric,
  total_distance_m numeric not null default 0,   -- 캐시, 트리거로 갱신
  total_run_count integer not null default 0,    -- 캐시, 트리거로 갱신
  -- (visibility 컬럼은 AC-05 삭제로 폐기 — v1.7, 2026-08-31)
  created_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- 2. run_records / run_samples
-- ─────────────────────────────────────────────
create table public.run_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  distance_m numeric not null,
  duration_s integer not null,
  type text not null check (type in ('outdoor','treadmill','manual')),
  avg_heart_rate integer,
  estimated_calories numeric,
  title text,
  memo text,
  has_route_samples boolean not null default false,  -- 서버가 검증 후 확정 (PRD §5.7)
  flagged boolean not null default false,             -- 서버 재검증 실패 시 true
  flag_reason text,
  created_at timestamptz not null default now()
);

-- 초기엔 jsonb로 시작(ARCHITECTURE §12-#4). 샘플 수 증가 시 별도 테이블 분리 검토.
create table public.run_samples (
  run_record_id uuid not null references public.run_records(id) on delete cascade,
  seq integer not null,               -- 세션 내 순번
  lat double precision not null,
  lng double precision not null,
  ts timestamptz not null,
  altitude numeric,
  accuracy numeric,
  heart_rate integer,
  source text not null check (source in ('phone','watch_apple','watch_garmin','watch_other')),
  primary key (run_record_id, seq)
);

create index idx_run_records_user_started on public.run_records (user_id, started_at desc);

-- ─────────────────────────────────────────────
-- 3. seasons / user_season_tier  (절대평가, 시즌 단위)
-- ─────────────────────────────────────────────
create table public.seasons (
  id text primary key,              -- '2026-Q3'
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  is_shortened boolean not null default false
);

create table public.user_season_tier (
  user_id uuid not null references public.profiles(id) on delete cascade,
  season_id text not null references public.seasons(id),
  cumulative_distance_m numeric not null default 0,
  current_tier text not null default 'bronze'
    check (current_tier in ('bronze','silver','gold','platinum')),
  tier_updated_at timestamptz not null default now(),
  primary key (user_id, season_id)
);

create index idx_user_season_tier_season_tier on public.user_season_tier (season_id, current_tier);

-- ─────────────────────────────────────────────
-- 4. weekly_ranking_cache  (상대평가, 티어 내, 주 단위)
--    ⚠️ user_season_tier와 절대 병합하지 않는다 — 집계 주기·평가 방식이 다름 (ARCHITECTURE §4)
-- ─────────────────────────────────────────────
create table public.weekly_ranking_cache (
  user_id uuid not null references public.profiles(id) on delete cascade,
  season_id text not null references public.seasons(id),
  week_id text not null,             -- '2026-W34' (KST 월~일 기준)
  tier text not null check (tier in ('bronze','silver','gold','platinum')),
  weekly_distance_m numeric not null default 0,
  run_count integer not null default 0,
  rank integer,
  tier_participant_count integer,
  computed_at timestamptz not null default now(),
  primary key (user_id, week_id)
);

create index idx_weekly_ranking_tier_week on public.weekly_ranking_cache (season_id, week_id, tier, rank);

-- ─────────────────────────────────────────────
-- 5. badges / user_badges
-- ─────────────────────────────────────────────
create table public.badges (
  id text primary key,               -- 'dist_cum_1000km' 같은 slug. scope='seasonal' 인스턴스는 'stier_platinum_2026q3'처럼 season_id를 slug에 포함
  name text not null,                -- 표시명 (badge-catalog.csv의 display_name)
  description text not null,
  category text not null,            -- BadgeCategory 값 (예: 'cumulativeDistance')
  scope text not null check (scope in ('permanent','seasonal')),
  trigger_type text not null check (trigger_type in ('session','cumulative')),
  condition jsonb not null,
  badge_grade text not null default 'bronze',  -- 표시용 등급. 시즌티어달성 카테고리 제외 시즌 티어 시스템과 무관
  season_id text references public.seasons(id)  -- scope='seasonal' 템플릿이 실제 발급된 인스턴스일 때만 not null
);

create table public.user_badges (
  user_id uuid not null references public.profiles(id) on delete cascade,
  badge_id text not null references public.badges(id),
  earned_at timestamptz not null default now(),
  verified boolean not null default false,
  revoked boolean not null default false,   -- 부정 기록 판정 시 회수 (PRD §8.1)
  primary key (user_id, badge_id)
);
```

> ⚠️ 위 DDL은 Phase 0 초안이고 **라이브 스키마의 테이블명은 `public.runs`**(마이그레이션 01)다. 아래 §4.0 이후의 추가 DDL은 라이브 이름을 기준으로 적는다.

#### 4.0 기기 벤더 (§3.1.1 확정 — ✅ **적용 완료**, 마이그레이션 36)

```sql
-- ─────────────────────────────────────────────
-- 라벨이 camelCase인 것은 의도적이다. badge_catalog.condition_value 와
-- device_watchApple_1 같은 뱃지 id(PK)가 이미 이 문자열로 시드돼 있고,
-- 별도 매핑을 두면 어긋날 때 뱃지가 조용히 미지급된다. TRD §3.1.1 참조.
-- ─────────────────────────────────────────────
create type public.device_vendor as enum (
  'phone', 'watchApple', 'watchGarmin', 'watchOther', 'unknown'
);

-- runs.sources(run_sample_source[])와 **직교하는 축**이다. 합치지 말 것.
--   sources        = 어떤 경로로 언제 들어왔나 (phone/watch/external)
--   device_vendors = 어느 기기가 만들었나
alter table public.runs
  add column device_vendors public.device_vendor[] not null default '{}';

comment on column public.runs.device_vendors is
  '이 세션에 기여한 기기 벤더 집합. {} 는 {phone} 과 다른 뜻(정보 없음/수동 입력). TRD §3.1.1';

-- device_source_count_gte 가 사용자별로 겹침(&&) 필터를 돈다.
create index runs_device_vendors_gin on public.runs using gin (device_vendors);

-- 백필: {}(정보 없음)과 {phone}(폰 단독 확정)은 의미가 다르므로
-- 무조건 채우지 말고 sources 를 근거로만 채운다.
update public.runs
   set device_vendors = '{phone}'::public.device_vendor[]
 where device_vendors = '{}'
   and sources @> '{phone}'::public.run_sample_source[];
```

- **RLS**: `runs`의 기존 정책을 그대로 상속한다. 새 정책 불필요.
- **쓰기 주체**: 클라이언트가 `RunRecord.toJson()`으로 함께 올린다(`_serverOwnedKeys` 아님). P1에서 워크아웃 임포트가 서버 경유로 바뀌면 그때 서버가 재확정한다.
- **판정 헬퍼**: `_device_vendor_tokens(text) returns device_vendor[]` 가 `_or_` 표현식을 파싱한다. 문법 오류·미지 토큰이면 `null` + `raise notice` 를 내고 해당 뱃지는 `false` — 조용히 무시하지 않는다(§3.1.2).

#### 4.2 음력 명절 룩업 (✅ **적용 완료**, 마이그레이션 38)

`calendar_date_match` 의 `date='chuseok'` / `'lunar_newyear'` 판정 원천. **음력 변환 함수를 구현하지 않는다** —
정확한 한국 음력은 한국천문연구원의 삭(朔) 계산을 **동경 135°E(KST)** 기준으로 따라야 하고, 중국 음력(120°E)과
날짜가 갈리는 해가 실제로 있다(삭이 KST 자정 직후에 들면 한국은 하루 뒤가 초하루다).

```sql
create table public.lunar_holidays (
  holiday_key text    not null,   -- 'lunar_newyear' | 'chuseok'
  year        integer not null,
  solar_date  date    not null,   -- KST 양력 날짜
  primary key (holiday_key, year),
  check (holiday_key in ('lunar_newyear','chuseok')),
  check (extract(year from solar_date)::integer = year)
);
```

- `holiday_key` 는 `badges.condition ->> 'date'` 값과 **같은 문자열**이다 — 매핑 계층을 두지 않는다.
- **RLS**: `anon`/`authenticated` SELECT 허용(공개 상수), 쓰기 정책 없음 + write 권한 revoke.
- 2026~2040 15년치(30행) 시드 완료. **미등재 연도는 `false` + `raise notice`** — 조용히 넘어가지 않는다.
- ⚠️ 회귀 테스트 대상: **2027 설날 한국 2/7(중국 2/6)**, **2028 설날 한국 1/27(중국 1/26)**.
  중국 음력 라이브러리를 참조 구현으로 쓰면 이 두 해가 하루 틀린다.
- §6.4 연휴 3일(전날·당일·다음날) 확대는 **채택하지 않았다** — 같은 카테고리 다른 8종이 전부 당일 기준이라
  설날·추석만 3일로 하면 규칙이 불균질해진다. 넓히려면 `solar_date` 를 `start_date`/`end_date` 로 확장해
  **데이터만** 고치면 되고 판정식은 그대로다.

#### 4.3 주간 랭킹 캐시의 실제 테이블명 (⚠️ 문서 ↔ 라이브 스키마)

위 §4 초안 DDL과 여러 설계 문서가 이 캐시를 **`weekly_ranking_cache`** 라고 부르지만,
**라이브 스키마의 실제 이름은 `public.leaderboard_entries`**(마이그레이션 03)이고 §2.5가 요구한 컬럼이
이미 전부 들어 있다. 새 테이블을 만들지 않고 이 테이블을 쓴다 — 마이그레이션 32/33의
`season_weekly_rank_*` 판정도 이미 이 테이블을 읽고 있다.

| 설계 문서의 이름 | 라이브 컬럼 |
|---|---|
| `week_id` | `period_start` (+ `period='weekly'`) |
| `season_id` | `period_start` 이 속한 시즌(`season_id_at()`) |
| `weekly_distance_m` | `score` (`metric='distance'`) |
| `weekly_run_count` | `run_count` |
| `weekly_moving_sec` | `total_moving_seconds` |
| `rank` | `rank` — **배치가 확정해 기록**하며 조회 시 재계산하지 않는다 |
| `tier` | `tier` (주 종료 시점 확정 티어) |
| `N`(모집단) | `participant_count` |
| `reached_at` | **`reached_at` — 마이그레이션 40에서 신설.** 유일하게 없던 컬럼이고, 이것 없이는 PRD §8.2 ②를 구현할 수 없었다 |

**순위 정렬(마이그레이션 40, `metric='distance'` 한정)** — PRD §8.2 3단계 + 결정성 폴백:
`score desc → run_count asc → reached_at asc → total_moving_seconds asc → user_id asc`.
공동 순위를 만들지 않는다. `duration`/`run_count` 지표는 §8.2의 적용 대상이 아니므로 기존 `tie_break_value` 순서를 유지한다.
`reached_at` = 그 기간의 마지막 집계 대상 러닝의 `started_at`(= 누적 거리가 최종값에 도달하는 시점).

### 4.1 camelCase ↔ snake_case 매핑

| Dart 필드 | Postgres 컬럼 | 타입 | 비고 |
|---|---|---|---|
| `RunRecord.distanceMeters` | `run_records.distance_m` | numeric | |
| `RunRecord.duration` (`Duration`) | `run_records.duration_s` | integer | 초 단위 변환 |
| `RunRecord.avgHeartRate` | `run_records.avg_heart_rate` | integer nullable | |
| `RunRecord.hasRouteSamples` | `run_records.has_route_samples` | boolean | 서버가 최종 확정 |
| `RunSample.source` (`RunSampleSource`) | `run_samples.source` / `runs.sources[]` | `public.run_sample_source` | `phone` / `watch` / `external` — snake_case 규약 대상이 아닌 단어들이라 변환 없음 |
| `RunRecord.deviceVendors` (`List<DeviceVendor>`) | `runs.device_vendors` | `public.device_vendor[]` | ⚠️ **값 문자열은 camelCase 그대로**(`watchApple`). 프로젝트 유일한 규약 예외 — §3.1.1 |
| `UserSeasonTier.cumulativeDistanceMeters` | `user_season_tier.cumulative_distance_m` | numeric | |
| `RankingEntry.score` | `leaderboard_entries.score` | numeric | 단위는 `metric`에 종속(distance→미터). ⚠️ 정본 테이블명은 `leaderboard_entries`다 — `weekly_ranking_cache`는 초기 설계 문서에만 있던 이름이고 실제로 생성된 적이 없다(§4.3) |
| `RankingEntry.participantCount` | `leaderboard_entries.participant_count` | integer nullable | |
| `UserProfile.totalDistanceMeters` | `profiles.total_distance_m` | numeric | 트리거 갱신 캐시 |
| `AppUser.weeklyGoalKm` | `profiles.weekly_goal_km` | double precision nullable | **AC-02, 마이그레이션 53.** ⚠️ 단위가 **km**다 — 프로젝트의 다른 거리 컬럼은 전부 m이고 이것만 다르다(컬럼명 `_km`가 그 표식). 사용자가 "주 30km"로 입력·인지하는 값이라 저장 단위를 입력 단위에 맞췄다. 달성률은 클라이언트가 계산(`total_distance_meters / 1000` 대비). **서버는 이 값으로 아무 판정도 하지 않는다** — 랭킹·티어·뱃지와 무관한 표시 전용. `NULL` = 미설정(0이 아니다). CHECK `> 0 and <= 500`. 타입을 `numeric`(폐기된 §4 DDL 초안)이 아니라 `double precision`으로 잡은 것은 같은 화면에서 함께 편집되는 `weight_kg`·`height_cm`와 맞추기 위함 |
| `AppUser.totalXp` | `profiles.total_xp` | integer | ⚠️ 구 `totalPoints`/`total_points` 개명(2026-08-26). **PRD §5.6 Phase 4 포인트와 다른 개념** |
| `AppUser.level` | `profiles.level` | integer | CHECK `between 1 and 60` |
| `AppUser.weeklyGoalKm` | `profiles.weekly_goal_km` | double precision nullable | AC-02 사용자 편집 컬럼(마이그레이션 53, 2026-08-31). **단위가 km다** — 다른 거리 컬럼이 미터인 것과 의도적으로 다르며, 사용자가 직접 입력·확인하는 표시값이라 표시 단위와 맞췄다. `NULL` = 미설정(`0`이 아니다), CHECK `> 0 and <= 500`. 티어·랭킹·뱃지 판정 입력이 **아니다**. `trg_profiles_guard`는 화이트리스트가 아니라 **블랙리스트**라(서버 전용 컬럼만 old 값으로 되돌린다) 컬럼 추가만으로 사용자 편집이 열린다 — 역으로 새 **서버 전용** 컬럼은 반드시 가드에 등록해야 한다 |
| `RunRecord.awardedXp` | `runs.awarded_xp` | integer nullable | ⚠️ 구 `awardedPoints`/`awarded_points` 개명. 서버 전용 쓰기(`_serverOwnedKeys`) |
| `RunRecord.isFlagged` | `runs.is_flagged` | boolean nullable | 2026-08-26 읽기 전용 노출(공유 게이트). **`@Default(false)`가 아니라 nullable** — `null`(아직 모름) / `false`(서버가 정상 확정) / `true`(플래그) 세 상태를 구분해야 미검증 기록을 축하·공유해 버리는 사고를 막는다. 업로드 payload에서 제거(`_serverOwnedKeys`), 로컬 `summaryJson`에는 보존. **채워지는 유일한 경로는 업로드 응답**(`_push()`의 `.upsert(payload).select(...).single()`) — `trg_runs_guard`가 BEFORE 트리거에서 동기 확정하므로 재조회·realtime 없이 그 응답에 이미 들어 있다 |
| `RunRecord.flagReason` | `runs.flag_reason` | text nullable | 위와 동일 규칙. 내부 코드성 문구라 사용자에게 그대로 노출하지 않는다 |
| *(대응 필드 없음)* | `profiles.current_streak_weeks` | integer | 리플레이 결과 캐시 |
| *(대응 필드 없음)* | `profiles.longest_streak_weeks` | integer | 리플레이 결과 캐시 · **`streak_weeks_gte` 판정의 유일한 소스** |
| *(대응 필드 없음)* | `profiles.streak_freeze_credits` | smallint | 리플레이 파생값 캐시(표시용, 0 또는 1) |
| *(대응 필드 없음)* | `profiles.streak_last_active_week` | text | KST ISO 주 키 `YYYY-Www`. 알림 판단용 |
| *(대응 필드 없음)* | `leaderboard_entries.reached_at` | timestamptz | PRD §8.2 ② 타이브레이크 근거(§4.3) |
| `Badge.conditionType` | `badges.condition_type` | text (check, 39종) | 판정 함수 디스패치 키 |
| `Badge.condition` | `badges.condition` | jsonb | 키 집합은 `condition_type`마다 다름 |
| `Badge.badgeGrade` | `badges.badge_grade` | text (check, 6종) | 표시용 등급 — 경쟁 `Tier`와 무관 |
| `Badge.triggerType` | `badges.trigger_type` | text (enum check) | `session` / `cumulative` |
| `Badge.scope` | `badges.scope` | text (enum check) | `permanent` / `seasonal` |
| `Badge.category` | `badges.category` | text (enum check, 14종) | CSV의 한국어 라벨은 시드 시 snake_case 영문으로 매핑 |
| `Badge.seasonId` | `badges.season_id` | text nullable | seasonal **인스턴스**일 때만 값 존재 |
| `Badge.name` | `badges.name` | text | 시드 원천은 CSV `display_name` 열이다 (`functional_name` 열은 **시드하지 않는다** — Dart 모델에 대응 필드가 없고 `description`이 상위집합) |
| `UserBadge.id` | `user_badges.id` | uuid | 서버 생성. `markBadgesSeen()`이 이 값으로 개별 행을 갱신 |
| `UserBadge.userId` | `user_badges.user_id` | uuid | |
| `UserBadge.badgeId` | `user_badges.badge_id` | text FK → `badges.id` | seasonal이면 템플릿이 아니라 **인스턴스** id |
| `UserBadge.earnedAt` | `user_badges.earned_at` | timestamptz | 서버가 확정(클라이언트 시각 불신) |
| `UserBadge.verified` | `user_badges.verified` | boolean | 서버 재검증 결과 |
| `UserBadge.isSeen` | `user_badges.is_seen` | boolean | 클라이언트가 쓸 수 있는 유일한 컬럼 |
| *(대응 필드 없음)* | `user_badges.revoked` | boolean | **서버 전용.** 부정 기록 회수(PRD §8.1) — 행은 남기고 플래그만 세운다. 타인 조회 RLS 술어에 쓰인다 |
| `UserBadge.sourceRunId` | `user_badges.source_run_id` | uuid nullable | **쓰기는 여전히 서버 전용**(가드 트리거가 되돌린다). 2026-08-26 읽기 전용으로 Dart 모델에 노출 — 공유 카드가 "이 뱃지를 만든 러닝"의 경로를 그려야 한다(§3.9) |

> **`source_run_id` 노출 이력 (2026-08-26)**: 이 표는 원래 "Dart 모델에 추가하지 않는다"고
> 못 박고 있었다. 당시엔 소비자가 회수 판정(서버) 하나뿐이었기 때문이다. 공유 카드(HI-08)가
> 두 번째 소비자로 등장하면서 뒤집었다 — 카드에 그 러닝의 경로·거리를 얹으려면 "어느 러닝인가"를
> 알아야 하고, 이 값이 없으면 클라이언트가 `earned_at` 근처 러닝을 **시간으로 추측**하게 되는데
> 같은 날 두 번 뛴 사용자에게서 조용히 틀린다. 노출은 **읽기뿐**이고 쓰기 경계는 그대로다.
>
> `revoked`는 여전히 서버 전용이며 Dart 모델에 없다 — `select *`로 내려가도
> `json_serializable`이 미지 키를 무시하므로 무해하다. 클라이언트가 회수 여부를 렌더링할
> 이유가 없다(타인 것은 애초에 RLS가 가린다).

이 표는 필드 추가 시마다 갱신한다 — 암묵적 매핑은 QA 단계에서 필드 불일치 버그로 드러난다(`backend-engineer` 작업 원칙).

---

### 4.4 러닝 편집 정책 (PRD HI-07 / §8.1) — 2026-08-31 확정 · 마이그레이션 51

**규칙 한 줄**: 서버에 저장된(터미널 상태) 러닝에서 사용자가 바꿀 수 있는 컬럼은 `title`·`note` **둘뿐**이고, 사용자 삭제 경로는 **없다**.

| 항목 | 값 |
|---|---|
| 편집 가능 컬럼 | `runs.title` (≤ 60자), `runs.note` (≤ 500자) |
| 터미널 상태 정의 | `runs.status in ('completed', 'discarded')` |
| 강제 지점 | `trg_runs_guard` BEFORE UPDATE (마이그레이션 51-2) |
| 위반 시 동작 | **예외가 아니라 무시** — `new := old` 후 `title`/`note`만 재적용 |
| 삭제 | RLS 정책 `runs_delete_own` 제거(51-3). GRANT는 유지 |

**왜 예외를 던지지 않는가.** 오프라인 동기화(`LocalRunRepository.syncPending`)가 같은 `id`로 **행 전체를 재 upsert**하는 것을 멱등성의 근거로 삼는다(`07_rls.sql`의 `runs_update_own` 주석). 여기서 422/403을 내면 재시도 큐가 영구히 실패한다. 값이 같은 재 upsert는 되돌려도 결과가 동일해 무해하고, 실제 편집 시도만 조용히 무시된다 — `05_server_guards.sql` 헤더가 세운 "서버 전용 컬럼은 되돌린다" 방침의 연장이다.

**왜 화이트리스트(`new := old`)인가.** 블랙리스트로 컬럼을 열거하면 `runs`에 컬럼이 늘 때마다(36 `device_vendors`, 39 `awarded_xp` …) 이 파일을 고치는 것을 잊는 순간 구멍이 생긴다. 행 통째 대입은 신설 컬럼을 자동으로 보호하고, enum 배열·`jsonb`·`timestamptz`가 json을 경유하지 않아 왕복 변환 손실도 없다.

**순서가 중요하다.** 되돌리기는 페이스·`validate_run`·`compute_run_xp` 재계산보다 **먼저** 수행한다. 그래야 파생값이 전부 `old`의 원본값 기준으로 계산되어 최초 업로드 때와 같은 결과로 수렴한다 — 즉 편집 UPDATE는 티어·랭킹·XP·뱃지를 흔들지 않는다.

**`title`/`note` 정규화(가드가 수행).** `btrim` → 상한 절단(`left`) → 빈 문자열은 `NULL`. `runs_title_len`/`runs_note_len` CHECK는 **백스톱**일 뿐, 정상 경로에서는 절단이 먼저 일어나 클라이언트가 400을 받지 않는다. 상한값(60/500)은 이전 근거 문서가 없어 이번에 확정했다 — 60자는 목록/공유 카드에서 줄바꿈 없이 읽히는 한 줄 제목, 500자는 TOAST 임계에 한참 못 미치는 짧은 회고 메모.

**기존 데이터 정리(51-1)는 `set_config('runnit.server_write','on', true)`로 감싼다.** `runs`의 AFTER 트리거 4종(`runs_01`~`_04`)에 `WHEN` 절이 없어, 플래그 없이 절단 UPDATE를 돌리면 매칭 행마다 티어·챌린지·뱃지 전량 재평가와 알림 인큐가 돌기 때문이다(QA C-5). 적용 전 대상 행 수를 세고(`char_length(title) > 60 or char_length(note) > 500`), 0이면 이 UPDATE는 no-op이다.

**진행 중(`recording`/`paused`) 행은 이 잠금에서 제외**한다. 현재 클라이언트는 완료 기록만 업로드하므로(`LocalRunRepository.save`) 서버 행은 항상 이미 터미널이지만, 향후 체크포인트 업로드가 생기면 그 경로는 정상적으로 원본을 갱신해야 한다. `is_server_write()` 경로(부정 판정·재집계·백필)도 제외된다.

**클라이언트 계약**: 편집은 별도 RPC 없이 기존 upsert 경로 그대로다. `title`/`note`만 담은 부분 UPDATE(`update().eq('id', …)`)를 권장하며, 전체 행 upsert를 보내도 나머지는 조용히 무시된다. 서버가 정규화한 최종값이 필요하면 `.select('id,title,note,updated_at').single()`로 되받는다.

### 4.5 프로필 편집·타인 프로필 (PRD AC-02 / AC-03) — 2026-08-31 · 마이그레이션 53~56

**편집 가능 항목은 넷뿐이다**: `display_name` · `avatar_url` · `weight_kg` · `weekly_goal_km`. `username`(고유 핸들)은 고정이다.

⚠️ **`username` 고정은 서버가 강제한다 (마이그레이션 56).** 블랙리스트 가드라 `username`은 원래 클라이언트 UPDATE로 통과됐고, `profiles_update_self` RLS는 본인 행 전권을 준다 — REST 직접 호출로 핸들 변경이 가능했다(QA F-2). `trg_profiles_guard`의 UPDATE 분기가 `new.username := old.username`을 PK(`new.id`)와 같은 취급으로 되돌린다. 클라이언트도 `_editablePatch`에서 `username` 키를 뺐다(이중 방어). 훗날 관리자 개명이 필요하면 별도 SECURITY DEFINER 경로로 연다.

⚠️ **`profiles`의 가드 트리거는 화이트리스트가 아니라 블랙리스트다.** `trg_profiles_guard`(05 → 19 → 39에서 갱신)는 서버 전용 컬럼(`total_*`/`level`/`current_tier`/`season_distance_meters`/`streak_*`/`crew_id`)을 `old` 값으로 **되돌리는** 방식이고, 열거되지 않은 컬럼은 그대로 통과한다. `runs`(§4.4, `new := old` 화이트리스트)와 정반대의 기본값이다.

| | `runs` | `profiles` |
|---|---|---|
| 가드 방식 | 화이트리스트(`new := old` 후 2개 컬럼만 재적용) | 블랙리스트(서버 전용 컬럼만 되돌림) |
| 신설 컬럼의 기본값 | **자동으로 보호됨** | **자동으로 사용자 편집 가능** |
| 그래서 할 일 | 사용자 편집 컬럼을 늘리려면 가드를 고친다 | 서버 전용 컬럼을 만들면 **반드시 가드에 등록** |

`weekly_goal_km`(53)은 사용자 편집 컬럼이므로 가드 변경이 **필요 없었다** — `weight_kg`가 지금까지 편집 가능했던 것과 같은 이유다.

**아바타 Storage (54)**

| 항목 | 값 |
|---|---|
| 버킷 | `avatars`, `public = true` |
| 경로 규약 | `avatars/{auth.uid()}/{filename}` — 첫 폴더 세그먼트가 곧 쓰기 권한 술어 |
| 제한 | 2 MiB, `image/jpeg`·`image/png`·`image/webp` (**버킷 설정**. RLS 술어에서는 업로드 바이트를 알 수 없다) |
| 읽기 | 전체 공개(`anon` 포함) — 게스트 모드 global 랭킹도 아바타를 그린다(마이그레이션 17) |
| 쓰기 | 본인 폴더만. update는 `using`/`with check` 양쪽에 걸어 남의 파일을 내 폴더로 rename 하는 경로까지 막는다 |
| 권장 업로드 방식 | 같은 경로 덮어쓰기가 아니라 **타임스탬프 파일명으로 새 경로 업로드 → `avatar_url` 갱신 → 이전 파일 delete**. 덮어쓰기는 CDN/이미지 캐시 때문에 앱에 옛 사진이 남는다. 업로드 전 장변 512px 리사이즈 권장 |
| 미해결 | AC-04(계정 삭제) 시 `auth.users` 삭제가 `storage.objects`를 cascade 하지 않는다 → 고아 파일 정리 경로 필요(§14) |

**타인 프로필에 보이는 것 (AC-03)** — 티어·시즌 진행률·누적 요약·레벨(전부 `profiles` 공개 컬럼, `profiles_select_all`), 획득 뱃지(마이그레이션 55), 역대 시즌(`season_histories_select_visible`, 마이그레이션 21). **최근 러닝 목록은 노출하지 않는다** — `runs`는 `runs_select_own` 그대로이고 이번 작업에서 손대지 않았다. `user_badges.source_run_id`가 타인에게 보이지만 그 uuid로 `runs`를 조회할 수는 없다.

> **AC-05(기록 공개 범위)는 삭제됐다**(2026-08-31 사용자 확정). `profiles.visibility` 컬럼도 `ProfileVisibility` enum도 만들지 않는다 — 모든 프로필은 공개다.

---

## 5. RLS 정책 사양

> 정본은 `07_rls.sql` + 이후 각 기능 마이그레이션. 아래는 현재 원칙 요약 (Edge Function이 아니라 **SECURITY DEFINER 트리거·함수**가 서버 쓰기 주체다).

| 테이블 | select | insert/update | 근거 |
|---|---|---|---|
| `profiles` | 전체 공개 (`profiles_select_all`, `authenticated`) — AC-03이 이를 그대로 쓴다. 타인 화면에 체중·신장·생년월일·주간목표를 렌더링하지 않는 것은 표현 계층 책임 | 본인만 (`id = auth.uid()`). 서버 관리 컬럼 + `username`(마이그레이션 56)은 `profiles_guard`가 `old` 값으로 되돌림. 편집 가능: `display_name`·`avatar_url`·`weight_kg`·`weekly_goal_km` | AC-05(비공개) 삭제로 공개 범위 분기 없음 (v1.7) |
| `runs` | 본인 것만 | 본인만, `user_id = auth.uid()`. `is_flagged`/`awarded_xp` 등은 `runs_guard`가 확정. **터미널 상태 행의 UPDATE는 `title`/`note`만 반영**(§4.4, 마이그레이션 51). **delete 정책 없음**(PRD v1.6 — 사용자 삭제 불가) | 랭킹 공개는 `leaderboard_entries` 경유. 컬럼 단위 화이트리스트는 RLS로 표현할 수 없어 가드 트리거가 강제한다 |
| `leaderboard_entries` | 전체 공개 | `refresh_all_leaderboards()`(SECURITY DEFINER)만 | 절대/상대평가 신뢰성 |
| `season_histories` | `is_voided=false`면 타인 행도 공개(`authenticated`), `is_voided=true`는 본인만, `anon` 차단 (`season_histories_select_visible`, 마이그레이션 21) | 서버 함수만 (`recompute_season_tier`) | TI-09 "역대 최고 티어 프로필 표시" / AC-03 타인 프로필의 역대 시즌이 이 공개 범위를 그대로 재사용한다 |
| `tier_change_history` | 본인 행만 | 서버 함수만 | 시즌 중 티어 도달 시각은 본인만 필요 |
| `badges` / `lunar_holidays` | 전체 공개 | 시드/운영만 (write 권한 revoke) | 카탈로그·상수는 정적 |
| `user_badges` | 본인 전체(`user_badges_select_own` — 회수된 뱃지도 본인은 봐야 한다), 타인은 `verified and not revoked`만 (`user_badges_select_public`, **마이그레이션 55**). `anon` 차단 | insert는 트리거(`evaluate_badges`)만, 클라이언트는 `is_seen`만 update | 클라이언트가 직접 뱃지를 확정할 수 없음(PRD §8.4). 공개 select는 AC-03(타인 프로필 뱃지 갤러리)이 유일한 소비자. ⚠️ 이 정책 이후 **Realtime 구독에도 타인 행 이벤트가 도달**한다 — `user_badges`를 구독하는 코드는 반드시 `user_id=eq.{내 uuid}` 필터를 건다(현재 `watchUnseenBadges()`는 이미 걸려 있다) |
| `storage.objects` (`avatars` 버킷) | 전체 공개(`anon` 포함) — 랭킹·타인 프로필이 남의 아바타를 그린다 | insert/update/delete 모두 `(storage.foldername(name))[1] = auth.uid()::text`, 즉 **본인 uuid 폴더 안에서만** (마이그레이션 54) | AC-02 프로필 사진. 경로 규약 `avatars/{uid}/{filename}`이 곧 권한 술어다. 용량(2MiB)·MIME(jpeg/png/webp) 제한은 RLS로 표현할 수 없어 **버킷 설정**으로 건다 |
| `challenges` / `challenge_participations` | 공개/본인 | 참가는 본인, 진척은 트리거 | |

---

## 6. API / Edge Function 사양

> 🛑 **이 절 전체는 폐기됐다 (구현되지 않음).** Deno Edge Function은 하나도 만들지 않았다(`supabase/functions/` 없음). 실제 동작:
>
> | 초안 (§6.1~6.4) | 실제 구현 |
> |---|---|
> | `POST /functions/v1/upload-run-record` | 클라이언트가 `supabase_flutter`로 **`runs` 테이블에 직접 upsert**(id = 클라이언트 UUID, 멱등). `runs_guard` BEFORE 트리거가 원시 `samples`로 거리/페이스 재계산·플래그·`awarded_points` 확정, AFTER 트리거(`runs_01_recompute_stats`/`_02_challenge_progress`/`_03_evaluate_badges`)가 통계·XP·티어·뱃지 갱신. 서버 확정값은 upsert 응답(`.select(...).single()`)으로 동기 반환 |
> | `GET /functions/v1/weekly-ranking` | PostgREST 자동 API로 `leaderboard_entries` 직접 select (`ranking/data/supabase_ranking_repository.dart`) |
> | 배치 함수 (`pg_cron`) | `refresh_all_leaderboards()` — 5분 주기(마이그레이션 15/16). `transition_challenge_statuses()` — 10분 주기 |
> | `season-rollover` 배치 | 시즌은 계산 함수라 롤오버 배치 불필요. 마감 스냅샷은 `sync_my_season`/`reset_stale_seasons` + `season_histories`. **D-14/D-3 알림(NT-03)은 아직 없음 — Phase 2** |
>
> 아래 원문은 초기 요청/응답 shape 설계로만 보존한다.

### 6.1 `POST /functions/v1/upload-run-record`

**요청**
```json
{
  "runRecord": { "startedAt": "...", "endedAt": "...", "type": "outdoor", "...": "..." },
  "samples": [ { "lat": 37.5, "lng": 127.0, "ts": "...", "source": "phone" } ]
}
```

**처리 순서**
1. 원시 `samples`로 거리·페이스 재계산 (§7 검증 규칙 적용).
2. 검증 통과 시:
   - `run_records`/`run_samples` insert (`flagged=false`).
   - `type='outdoor'` 이고 경로 샘플 존재 시 → `user_season_tier.cumulative_distance_m` 즉시 갱신 → 승급 판정(§3.7 규칙과 동일 임계값) → 승급 시 전용 뱃지 지급.
   - `weekly_ranking_cache`에 해당 주 누적 거리 증분 반영(동기 갱신 or 다음 배치 사이클에 반영 — ARCHITECTURE §5.3 2단계 이후 결정).
3. 검증 실패/의심 시: `flagged=true`, `flag_reason` 기록, 티어·랭킹 미반영. 업로드 자체는 `2xx`로 성공 응답(기록은 보존).
4. 뱃지 판정 함수 재실행(세션형 + 누적형 모두).

**응답**
```json
{
  "runRecordId": "...",
  "flagged": false,
  "tierPromotion": { "from": "bronze", "to": "silver" },
  "newBadges": ["cumulative_100km"]
}
```

### 6.2 `GET /functions/v1/weekly-ranking?tier=silver&weekId=2026-W34`

`weekly_ranking_cache`에서 조회. 배치 갱신 주기를 벗어나지 않는 한 Postgres 직접 select로도 충분 — 별도 Edge Function 없이 PostgREST(Supabase 자동 API)로 대체 가능(§9 참고).

### 6.3 배치 함수 — 랭킹 캐시 갱신 (`pg_cron` 트리거)

5분 주기로 실행되는 스케줄 함수. 활성 시즌·주(week)에 대해 티어별로 파티션하여 `rank`를 재계산한다(§7 동점 규칙 적용). 초기 구현은 SQL 윈도우 함수(`rank() over (partition by season_id, week_id, tier order by ...)`)로 충분하며, 별도 배치 엔진 없이 Edge Function + `pg_cron`으로 처리한다.

### 6.4 시즌 경계 배치 (`season-rollover`)

역년 분기 시작 시각(1/4/7/10월 1일 00:00 KST)에 실행:
1. 종료된 시즌의 `user_season_tier.current_tier`를 이력 테이블(HI-06, 별도 `season_history` 또는 `user_season_tier` 자체를 이력으로 유지)로 보존.
2. 신규 `seasons` row 생성.
3. 신규 시즌의 `user_season_tier`는 필요 시점(첫 기록 업로드)에 지연 생성(lazy insert)하거나, 활성 사용자 전원에 대해 `bronze`/`0`으로 미리 생성 — 운영 부하 대비 후자를 권장(랭킹 조회 시 NULL 분기 처리를 피함).
4. D-14/D-3 알림(NT-03)은 이 배치가 아니라 별도 스케줄(시즌 종료 14일/3일 전) 함수에서 발행.

---

## 6-N. 알림 서버 구현 사양 (NT-01~08) — 2026-08-28 실구현

> 정본 마이그레이션: `44_notifications_core` · `45_notifications_triggers` ·
> `46_notifications_batches` · `47_push_dispatch` · `48_notifications_fixes`.
> 모델·필드 매핑은 §3.10 · §4.1-N, 판정 규칙의 근거는
> `_workspace/20260828_181500_gamification_notification-rules.md`.

### 6-N.1 발화 주체 — §7.3의 "티어=동기 / 랭킹=배치"가 알림에도 그대로 적용된다

| ID | 발화 | 위치 |
|---|---|---|
| NT-01 티어 승급 | 트리거 (동기) | `tier_change_history` AFTER INSERT → `trg_tier_promotion_notify` |
| NT-02 티어 근접 | 트리거 (동기) | `runs_04_notifications` |
| NT-03 시즌 D-14/D-3 | pg_cron | `notify_season_ending()` |
| NT-04 순위 변동 | pg_cron | `notify_rank_changes()` — 랭킹 갱신과 **같은 함수 안에서 체이닝** |
| NT-05 주말 유도 | pg_cron | `notify_weekend_push()` |
| NT-06 뱃지·레벨 | 트리거 (동기) | `runs_04_notifications` + `profiles_02_level_notify` |
| NT-07 포인트 | — | Phase 4. enum 라벨만 있고 발행 경로 없음 |

**NT-01을 `profiles.current_tier` 감시가 아니라 `tier_change_history` INSERT에 건 이유**:
그 테이블은 마이그레이션 34 이후 **상승만** 기록한다. 시즌 하드 리셋(전원 브론즈)과
부정 기록 무효화는 행을 만들지 않으므로, INSERT 되는 것이 곧 "승급"이다. `profiles`를
감시하면 시즌 경계 리셋을 승급과 구분하는 분기를 따로 써야 하고, 그 분기가 틀리면
**분기 첫날 전 사용자에게 "브론즈 승급!"이 나간다.**

`runs` 트리거 순서는 접두 번호로 고정된다 —
`runs_01_recompute_stats` → `_02_challenge_progress` → `_03_evaluate_badges` →
**`_04_notifications`**(신설). 04는 앞 셋의 **결과를 읽으므로** 반드시 마지막이다.

### 6-N.2 한 러닝 = 성취 푸시 최대 2건

`tier_promotion` 1건 + `badge_level` 1건. 뱃지 3개와 레벨업이 동시에 터져도
`badge_level`은 1건으로 묶인다. 묶음 판정에는 트랜잭션 로컬 설정 두 개를 쓴다:

- `runnit.notify_run_id` — `runs_01`이 심고 `runs_04`가 지운다
- `runnit.notify_level` — `profiles_02_level_notify`가 심는다. 이 값이 있으면
  레벨업 알림을 **따로 보내지 않고** `runs_04`가 뱃지와 합쳐 1건으로 낸다

`category='season_tier'` 뱃지(`stier_*`)는 `badge_level` 개수에서 **제외**한다 —
NT-01이 같은 사건을 이미 알렸고, "골드 승급!" + "뱃지 1개 획득(골드 뱃지)"는 같은 것을
두 번 세는 것이다.

> ⚠️ 레벨업은 `user_badges`에 합성 행을 만들지 않는다(gamification §5.1). 만들면
> `XP_badge`가 행마다 XP를 주므로 **레벨업 → XP → 레벨업 순환**이 생기고, 집계 쿼리
> 3곳에 예외 분기를 심어야 한다. ARCHITECTURE §7.4.1의 "소비 지점은 하나"도 유지된다.

### 6-N.3 상한은 count가 아니라 `dedupe_key` unique 제약이 강제한다

`unique (user_id, dedupe_key)`. 애플리케이션 레벨 count 체크는 pg_cron 재실행 경합에서
새어 나간다.

| 알림 | 키 | 상한 |
|---|---|---|
| NT-01 | `tier_promotion:{season}:{tier}` | 시즌 3 |
| NT-02 | `tier_proximity:{season}:{next_tier}` | 시즌 3 |
| NT-03 | `season_ending:{season}:d{14\|3}` | 시즌 2 |
| NT-04 | `rank_change:{week}:{up\|down}:{n}` | 주 down 3 / up 2 / 합계 4 |
| NT-05 | `weekend_push:{week}:{sat\|sun}` | 주 2 |
| NT-06 | `badge_level:run:{run_id}` / `:level:{level}` | 러닝 1 |

`week_id`는 KST ISO 주(`2026-W35`, `week_id_at()`), `season_id`는 `2026-Q3`.

### 6-N.4 임계치 상수 (계산식 아님 — 부동소수 경계 사고 차단)

`tier_proximity_threshold_m(next_tier)`: 실버 **5,000** / 골드 **10,000** /
플래티넘 **15,000**. 전 구간 5km 안을 쓰지 않은 이유는 골드→플래티넘 구간(150km)에서
5km가 3.3%라 **밴드를 통과하는 사람이 거의 없기** 때문이다(플래티넘 페이스 러너의 주
평균은 19km). 레벨 임계값(§3.8.3)과 같은 원칙이다.

NT-03 승급 가능권: D-14 **40,000m** / D-3 **10,000m**(남은 일수 × 페르소나 주간 거리).
NT-05 격차 상한 **5,000m**. NT-04 순위권 밴드 `greatest(30, ceil(pc × 0.3))`.

### 6-N.5 배치 스케줄 (pg_cron, 서버는 UTC / KST가 정본)

| job | KST | cron(UTC) |
|---|---|---|
| `runnit-notify-season-ending` | 매일 09:00 | `0 0 * * *` |
| `runnit-rank-notify` | 매시 정각, 08~22시 | `0 23,0-13 * * *` |
| `runnit-weekend-push-sat` | 토 10:00 | `0 1 * * 6` |
| `runnit-weekend-push-sun` | 일 18:00 | `0 9 * * 0` |
| `runnit-push-dispatch` | 매분 | `* * * * *` |

`runnit-rank-notify`는 `refresh_leaderboards_and_notify()`를 부른다 — 랭킹 갱신과 평가가
**같은 트랜잭션**이라야 rank 스냅샷이 어긋나지 않는다. 기존 5분 주기
`runnit-leaderboard`(화면 신선도용)는 그대로 둔다.

**방해 금지**: 배치 계열(NT-03/04/05)만 KST 08:00~22:00으로 제한한다(`_batch_hours_ok`).
트리거 계열은 사용자가 **방금 러닝을 끝낸 순간**이므로 심야에도 보낸다 — 새벽 5시에 뛴
사람에게 "방금 골드로 승급했어요"를 08:00까지 미루면 러닝의 문맥이 사라진 뒤 도착한다.

**NT-04 기준선**: `leaderboard_entries.notified_rank` / `notified_at`(마이그레이션 44).
`rank_delta`는 직전 5분 배치 대비 변동이라 알림 기준으로 쓸 수 없다 — 진동하는 사용자에게
하루 수십 건이 나가고, 3계단 내려갔다 올라온 사용자는 순 변동 0인데 알림 2건이다.
`rank_delta`는 UI의 "↑3" 표시용으로 그대로 둔다. **발송을 건너뛴 경우에도 기준선은
갱신한다** — 갱신하지 않으면 같은 변동이 매 주기 조건을 만족해 계속 재시도한다.

### 6-N.6 FCM 발송 경로 — Edge Function 예외 1건 (결정 근거)

ARCHITECTURE §5의 "Deno Edge Function을 쓰지 않는다"에 대한 **명시적 예외**를 둔다.

| 안 | 판정 |
|---|---|
| (a) `pg_net`으로 pg_cron 함수에서 FCM REST 직접 호출 | ❌ **구현 불가.** FCM HTTP v1은 서비스 계정 JWT를 **RS256**으로 서명해 액세스 토큰으로 교환해야 하는데, Postgres에 RSA 서명 수단이 없다(pgjwt = HMAC 전용, pgcrypto는 raw RSA sign 미노출). 토큰은 1시간마다 만료돼 "미리 발급해 Vault에 둔다"도 성립하지 않는다. 레거시 server-key API는 2024-06 폐지. 또한 pg_net은 fire-and-forget이라 토큰별 응답으로 무효 토큰을 지우려면 `net._http_response` 폴링 워커를 결국 따로 만들어야 한다 |
| **(b) 최소 Edge Function 1개** | ✅ **채택.** Deno WebCrypto의 RSASSA-PKCS1-v1_5로 서명·55분 캐시가 가능하다. 응답을 동기로 받으므로 무효 토큰 정리와 재시도 판정을 한 자리에서 한다 |

**예외의 범위를 좁게 고정한다 — `supabase/functions/push-dispatch/index.ts`에는 제품
판정이 없다.** 누구에게 무엇을 언제 보낼지는 44~46의 SQL이 이미 `notifications` 행으로
확정한 뒤다. 함수가 하는 일은 `claim_push_batch()` → FCM 전달 →
`mark_push_result()` / `prune_push_token()` 셋뿐이다. **새 알림 종류는 반드시 SQL 쪽에
추가할 것** — 판정이 두 곳으로 갈라지면 "알림함에는 있는데 푸시는 안 온다"의 원인을 두
곳에서 찾아야 한다.

**insert와 발송의 분리(필수)**: `enqueue_notification()`은 러닝 저장 트랜잭션 **안**에서
알림함 행만 만든다. 푸시 발송은 `dispatch_pending_pushes()`(pg_cron 매분 → pg_net →
Edge Function)가 **트랜잭션 밖에서** 훑는다. 발송을 트랜잭션에 넣으면 FCM이 느리거나
죽었을 때 **사용자의 러닝 저장이 실패한다.**

큐 상태 전이는 전부 SQL이 소유한다(`claim_push_batch`): `push_enabled = false` →
`send_error='push_disabled'`, 토큰 없음 → `'no_token'`, 24시간 경과 또는 3회 실패 →
`'expired'`. 성공하면 `sent_at`, 실패면 `sent_at`을 비워 둔 채 오류만 남겨 재시도한다.

> ⚠️ **`notifications`에 쓰는 서버 함수는 반드시 `_server_write_enter()`/`_server_write_exit()`
> 구간 안에서 써야 한다**(마이그레이션 49). 44-5의 `notifications_guard`는 UPDATE 시
> `is_server_write()`가 아니면 `sent_at`·`send_error`·`send_attempts`를 **전부 old 값으로
> 되돌린다.** 47번이 이걸 빠뜨려서, 발송 상태가 저장되지 않아 ① 같은 푸시가 매분 무한
> 재발송되고 ② 3회 실패 만료 경로가 죽고 ③ `push_enabled=false` 큐 배출이 무효라
> **마스터 스위치를 끈 사용자에게도 푸시가 나가는**(NT-08 위반) 상태였다.
> `is_server_write()`는 세션 GUC만 보므로 SECURITY DEFINER나 service_role 여부와 무관하다.
>
> `_server_write_enter()`는 **이전 값을 돌려주고 exit이 그 값을 복원한다.** 무조건
> `'off'`로 되돌리는 옛 관례는 중첩 호출에서 바깥 구간을 조기 종료시킨다.

**FCM `data` 페이로드**: `notification_id` + `type`(= `notifications.type` 컬럼) +
`payload` 전개. **`type`은 payload에서 오지 않는다** — `claim_push_batch()`가 전용
컬럼으로 돌려주고 Edge Function이 `data.type`에 싣는다. 클라이언트는 이 값으로 성취
계열을 판정해 인앱 배너를 생략하므로, 없으면 배너 + 풀페이지 축하가 **같은 사건을 두 번**
알린다(§7.4.1 위반). payload에 중복해 넣지 않는 이유는 종류가 이미
`notifications.type` 컬럼이자 `AppNotification.type` 필드이기 때문이다 — 같은 사실을 두
곳에 적으면 어긋났을 때 어느 쪽이 진짜인지 판단할 근거가 사라진다.

**운영 준비 항목(미완료)**: Vault 시크릿 `push_dispatch_url` / `push_dispatch_token`,
Edge Function 시크릿 `FCM_SERVICE_ACCOUNT`, 그리고 함수 배포. 셋이 없으면
`dispatch_pending_pushes()`는 **조용히 no-op** 한다 — FCM 연결 전에도 알림함 적재는
정상 동작해야 하고, cron이 매분 에러 로그를 쌓으면 안 된다.

### 6-N.7 종류별 딥링크 목적지 — 서버 발행값의 정본

> 이 표가 없어서 QA C-3이 문서 검토로 잡히지 않았다. **route를 바꾸거나 라우트를
> 개편할 때 이 표와 `lib/core/notifications/notification_deep_link.dart`의 목적지 표,
> `docs/ARCHITECTURE.md` §5.6.1을 함께 고칠 것.**

| 종류 | 발행처 | `payload.route` | 실제 go_router 경로 |
|---|---|---|---|
| NT-01 tier_promotion | `trg_tier_promotion_notify` | `/home` | `Routes.home` |
| NT-02 tier_proximity | `trg_runs_notifications` | `/home` | `Routes.home` |
| NT-03 season_ending 변형 A(승급권) | `notify_season_ending` | `/home` | `Routes.home` |
| NT-03 season_ending 변형 B(비승급권) | `notify_season_ending` | `/profile` | `Routes.profile` |
| NT-03 season_ending 변형 C(플래티넘) | `notify_season_ending` | `/home` | `Routes.home` |
| NT-04 rank_change | `notify_rank_changes` | `/home` | `Routes.home` |
| NT-05 weekend_push (A·B·C) | `notify_weekend_push` | `/home` | `Routes.home` |
| NT-06 badge_level (러닝 유래) | `trg_runs_notifications` | `/history/run/{run_id}` | `Routes.runDetailOf(runId)` |
| NT-06 badge_level (레벨 단독) | `trg_level_up_notify` | `/history?tab=badges` | `Routes.badgeGallery` |
| NT-07 points / 종류 미상 | — | — | 클라이언트 폴백 `Routes.notifications` |

**랭킹과 티어가 둘 다 `/home`인 이유**: 2026-08-21 4탭 개편에서 주간 랭킹은 홈 화면
안(티어 카드 아래)으로, 뱃지 갤러리는 활동 화면의 **하위 탭**으로 흡수됐다. `/ranking`,
`/profile/badges`, `/runs/{id}`는 **이 앱에 존재한 적이 없다** — 45~48이 개편 이전의 화면
구성을 가정하고 지어낸 값이었고, 마이그레이션 50이 정정했다.

⚠️ `/history?tab=badges`는 **쿼리까지 정확히** 보내야 한다. `/history`만 보내면 기록
탭으로 열린다(크래시는 아니다). 클라이언트는 화이트리스트 판정에서만 쿼리를 떼고,
이동에는 원문을 그대로 쓴다.

### 6-N.8 클라이언트 계약

| 목적 | 경로 |
|---|---|
| 알림함 조회 | `notifications` 직접 select (`user_id` = 본인, `created_at desc` 커서) |
| 미읽음 수 | `notifications` head count, `read_at is null` (부분 인덱스) |
| 실시간 | `notifications`가 `supabase_realtime` publication에 등록됨 — INSERT를 **재조회 신호로만** 쓴다 |
| 읽음 처리 | RPC `mark_notifications_read(p_ids uuid[])` — `p_ids`가 null이면 전체 읽음. 서버 시각으로 확정하고 이미 읽은 행은 건드리지 않는다 |
| 설정 | `notification_settings` 직접 select/upsert (컬럼 하나만 부분 갱신) |
| 토큰 등록 | RPC `register_push_token(p_token, p_platform, p_device_id, p_app_version)` |
| 토큰 해제 | `push_tokens` delete (본인 행) |

> ⚠️ **알림함 목록을 `NotificationSettings.isEnabled`로 필터하지 말 것.** 그 메서드는
> `pushEnabled`가 꺼져 있으면 false를 돌려주는 **설정 화면용** 판정이다. 서버는 종류별
> 토글이 꺼진 알림은 애초에 행을 만들지 않고, 마스터 스위치는 **푸시만** 막고 알림함
> 기록은 남긴다(§6-N.6). 클라이언트가 한 번 더 거르면 마스터를 끈 사용자의 알림함이
> 통째로 비어 보인다.

> ⚠️ `register_push_token`이 단순 upsert가 아닌 이유: 같은 기기를 다른 계정이 쓰면 FCM
> 토큰은 그대로인 채 `user_id`만 바뀌는데, update 정책의 USING이 `user_id = auth.uid()`를
> 요구해 이전 소유자의 행에 매칭되지 않아 실패한다. 그 상태로 두면 **기기를 넘겨받은
> 사용자에게 이전 사용자의 순위·티어 알림이 간다.**

---

## 7. 서버 검증 규칙 (PRD §8.4 기술 스펙화)

| 검사 | 기준값 | 구현 |
|---|---|---|
| 비현실적 평균 페이스 | 평균 3:00/km 미만(= 20km/h 초과 평균 속도) | `distance_m / duration_s` 재계산 후 판정 |
| 순간 속도 이상 | 인접 샘플 간 구간 속도 25km/h 초과 | 샘플 페어별 Haversine 거리 / 시간차. 초과 구간은 제거 후 총거리 재계산 |
| 시간 대비 거리 불일치 | 샘플 타임스탬프 역행, 또는 `ended_at - started_at`과 샘플 시간 범위 모순 | 기록 거부(422) |
| 중복 업로드 | 동일 `user_id` + 시간대 겹침 기존 `run_record` 존재 | 기존 기록과 병합 제안 또는 거부 |
| GPS 샘플 부재 | `samples.length == 0` 이면서 `distance_m > 0` | `has_route_samples=false` → 수동 기록 분류 |
| 경로 비현실성 | 연속 3개 이상 샘플이 완전 직선 + 등간격(순간이동 패턴) | 플래그, 수동 검토 큐(운영 콘솔, Phase 1 이후) |
| 다계정 의심 | 동일 기기 식별자로 다수 계정의 유사 경로 반복 | Phase 4 대상 — 현재는 로깅만, 포인트 없음 |

**동점 처리 정렬 규칙 (PRD §8.2)** — 실제 구현은 §4.3 (마이그레이션 40, `refresh_all_leaderboards`):
```sql
-- leaderboard_entries, metric='distance'
order by score desc, run_count asc, reached_at asc, total_moving_seconds asc, user_id asc
```

---

## 8. GPS/웨어러블 기술 사양

### 8.1 권한 요청 순서

1. `permission_handler`로 `whenInUse` 위치 권한 요청 (앱 최초 진입 시, 왜 필요한지 설명 화면 선행).
2. 러닝 시작(`[START]`) 시점에 `always` 권한 승격 요청 — Android는 포그라운드/백그라운드 위치 권한이 분리되어 있으므로 별도 요청.
3. 웨어러블 연동은 `health` 패키지의 HealthKit/Health Connect 권한을 **독립된 플로우**로 요청(위치 권한과 섞지 않음).

### 8.2 백그라운드 트래킹

- **Android**: Foreground Service(`type=location`) 사용. 알림 상시 노출로 OS의 강제 종료 방지.
- **iOS**: Background Modes `location` 활성화. `CLLocationManager`의 `allowsBackgroundLocationUpdates=true`.
- 권한 거부 시 백그라운드 트래킹 없이 포그라운드 트래킹만으로 우아하게 저하(degrade)한다 — 트래킹 자체를 막지 않는다.

### 8.3 GPS 스무딩 파라미터

- 알고리즘: 이동평균 또는 Kalman filter(구현 난이도 대비 이동평균으로 시작, 정확도 이슈 발생 시 Kalman으로 승격).
- 이상치 판정: `accuracy > 20m`인 샘플은 거리 계산에서 제외. 순간 속도 25km/h 초과 구간은 제거(§7과 동일 기준 클라이언트 1차 필터).
- 거리 계산: 스무딩된 연속 포인트 간 Haversine 공식 누적.
- 페이스: `duration / distance_km`(분/km), 1km 구간별 split 별도 계산(TR-07).
- 칼로리: MET 기반 추정 — `weightKg`, 평균 페이스 활용. 심박수 있으면 정교화(P1, WR-05 연동 후).

### 8.4 웨어러블 연동 경로 (재확인)

| 기기 | 연동 경로 | 실시간성 | Runnit 지원 우선순위 |
|---|---|---|---|
| Apple Watch | HealthKit 네이티브(`HKWorkoutSession`) | 높음 | 1순위 |
| Garmin | Garmin Connect → HealthKit(iOS)/Health Connect(Android) 동기화 | 낮음(지연) | 1순위 (경로는 다르나 지원 등급 동일) |
| 기타 Wear OS | Health Connect | 중간 | 2순위 |
| 워치 미연동 | 폰 GPS 단독 | — | 기본 폴백(에러 아님) |

#### 8.4.1 벤더 판별 (`DeviceVendor`, §3.1.1)

판별 입력은 `health` 패키지(11.1.1)가 주는 `sourceId`/`sourceName`이다. **플랫폼별로 형태가 다르다** — 소스 코드로 직접 확인한 사실이다:

| 플랫폼 | `sourceId` | `sourceName` |
|---|---|---|
| iOS (`SwiftHealthPlugin.swift`) | `sourceRevision.source.bundleIdentifier` | `sourceRevision.source.name` (사용자에게 보이는 기기/앱 이름) |
| Android (`HealthPlugin.kt`) | **항상 빈 문자열** | `metadata.dataOrigin.packageName` |

→ 두 필드를 합쳐 매칭해야 한다. 한쪽만 보면 Android가 통째로 샌다.

| 벤더 | 판별 근거 | 신뢰도 |
|---|---|---|
| `watchGarmin` | `garmin` 부분 문자열 — iOS `com.garmin.connect.mobile`, Android `com.garmin.android.apps.connectmobile`, 표시명 `Garmin Connect`가 모두 포함 | 높음 |
| `watchApple` | `com.apple.*` 번들 + 기기명에 `watch` | **중간 — 아래 한계 참조** |
| `watchOther` | Samsung Health / Google Fit / Polar / Coros / Suunto / Fitbit 등 힌트 목록 | 낮음(뱃지 무관) |
| `unknown` | 위 어디에도 안 걸림. 단, 러닝 중 심박 폴링 경로는 `watchOther`로 저하한다 — 폰은 러닝 중 심박을 연속 측정하지 못하므로 연속 심박의 존재 자체가 웨어러블의 증거다 | — |

⚠️ **Apple Watch 판별의 알려진 한계.** HealthKit에서 Apple Watch가 쓴 데이터의 bundleIdentifier는 `com.apple.health.<기기 UUID>`인데 **iPhone이 쓴 데이터도 같은 형태**라 번들 id만으로는 구분되지 않는다. 기본 기기 이름("○○의 Apple Watch")에 `Watch`가 들어가는 것에 의존하므로 **사용자가 워치 이름을 바꾸면 판별에 실패**해 `watchOther`로 떨어진다. 방향은 안전하다 — 애플워치 뱃지가 **안 붙을 뿐 잘못 붙지는 않는다**. 정확한 판별에는 `HKDevice.manufacturer`/`model`(iOS)과 `Metadata.device`(Health Connect)가 필요한데 `health` 패키지가 노출하지 않는다(§14 #8).

### 8.5 배터리 모드

| 모드 | `LocationAccuracy` | 폴링 주기 |
|---|---|---|
| 고정밀 | `best` | 1~2초 |
| 표준(기본값) | `high` | 5초 |
| 절전 | `medium` | 10초+ |

---

## 9. 티어·랭킹 집계 기술 사양

- **티어 판정**: `runs` upsert의 트리거 트랜잭션 내에서 동기 처리(`recompute_season_tier` 등). 배치 지연 없음(PRD TI-03).
- **주간 랭킹 집계**: `pg_cron` 5분 주기 배치(`refresh_all_leaderboards`). 조회는 PostgREST 직접 select.
- **시즌/주간 경계**: 시즌은 `season_id_at()`/`season_start()`/`season_end()` 계산 함수(역년 분기 KST). 주 경계는 KST 월요일 00:00 ~ 일요일 23:59, `leaderboard_entries.period_start`. 러닝 **시작 시각** 기준으로 귀속(PRD §8.5).
- **주중 승급 시 랭킹 이관**: `leaderboard_entries`의 `tier` 파티션만 갱신, 주간 거리는 `runs` 재집계로 자연 유지 — row 재생성 안 함(PRD §8.6).
- **누적 거리 재계산 시 티어 (PRD v1.6, 마이그레이션 43)**: 사용자는 러닝을 삭제할 수 없다(HI-07은 제목·메모 수정만). 누적 거리가 줄어드는 유일한 경로는 서버의 부정 판정(`is_flagged=true`)이며, 이 경우 `recompute_season_tier`가 `season_distance_meters`는 실제값으로 낮추되 **같은 시즌이면 `current_tier`는 내리지 않는다** — `v_new_tier := greatest(tier_for_distance(dist), 직전_티어)`. 시즌 경계를 넘은 첫 recompute만 하드 리셋(다음 시즌 bronze부터). 부정으로 획득된 뱃지는 행을 남기고 `user_badges.revoked=true`. 정상 러닝은 삭제 자체가 없으므로 티어 하향 시나리오가 존재하지 않는다.
- **시즌 마감 `best_weekly_rank`는 티어 스코프만 (마이그레이션 52)**: `recompute_season_tier`가 시즌 경계에서 `season_histories.best_weekly_rank`를 채울 때 `leaderboard_entries`에서 `min(rank)`를 뽑는데, 마이그레이션 23 이후 통합 보드(`tier IS NULL`)와 티어별 보드가 공존하므로 `and le.tier is not null`로 티어별 보드만 집계한다. 클라이언트가 노출하는 주간 랭킹도 항상 티어 스코프이므로 마감 스냅샷도 동일 기준이다. 마감 후 수정 불가한 컬럼이라 명시적으로 고정.
- **사후 편집으로도 집계가 흔들리지 않는다 (마이그레이션 51, §4.4)**: v1.6 시점에는 삭제 경로만 막혀 있었고 `runs` UPDATE로 `distance_meters`·`samples`·`started_at`을 바꾸는 경로가 남아 있었다(파생값은 재계산되지만 그것은 *조작된 원본에 대한* 정합성이다 — 3km를 저장한 뒤 42km로 UPDATE하면 티어·랭킹·뱃지가 전부 따라 올라간다). 51-2가 터미널 상태 행의 UPDATE를 `title`/`note`로 한정하면서 이 경로가 닫혔다. 편집 UPDATE는 `old` 원본으로 재계산되므로 `recompute_season_tier`·`refresh_all_leaderboards`·`evaluate_badges`가 모두 최초 업로드와 같은 값으로 수렴한다.

---

## 10. 뱃지 판정 기술 사양

> 구현 정본은 §10.1 / §10.2 및 마이그레이션 13·27·31~42. 아래 첫 3개 불릿은 초기 서술이며 §10.1이 실제 구현으로 대체한다.

- ~~트리거: 세션형/누적형을 Edge Function에서 재실행~~ → 실제: `runs` AFTER 트리거 `runs_03_evaluate_badges` → `evaluate_badges(user_id, run_id)`가 매 INSERT/UPDATE/DELETE마다 미획득 뱃지 전체를 재평가(§10.1).
- 판정 함수는 `condition jsonb`를 입력으로 받는 범용 평가기로 구현(예: `{"type": "cumulative_distance_gte", "value": 100000}`) — 뱃지 추가 시 코드 배포 없이 데이터로 확장 가능하게 한다.
- 클라이언트 잠정 판정 → 서버 확정 결과 Realtime 반영까지의 사이, UI는 "확인 중" 상태를 명시(연출 자체는 잠정치로 먼저 보여주되 최종 확정 실패 시 취소 애니메이션 없이 조용히 `verified=false`로 유지 — 게이미피케이션 원칙: 설명 없이 박탈하지 않음).
- **카탈로그 시딩**: [`docs/badge-catalog.csv`](./badge-catalog.csv)의 146개 행을 `badges` 시드 데이터로 적재한다. `scope='permanent'`(115개)는 그대로 1행 = 1뱃지. `scope='seasonal'`(31개 템플릿)은 시즌 시작 배치 작업이 시즌마다 `id`에 `season_id`를 붙여 실제 인스턴스로 복제 발급한다(예: 템플릿 `stier_platinum` → 인스턴스 `stier_platinum_2026q3`). 템플릿 자체는 `badges`에 유저에게 노출되지 않는 참조용 행으로 유지하거나, 시즌 인스턴스 생성 로직의 입력 메타데이터로만 별도 관리한다 — 어느 쪽으로 할지는 `backend-engineer`가 시딩 스크립트 작성 시 확정.

### 10.1 실제 구현 노트 (v2, 2026-08-25 · 마이그레이션 27_badge_evaluation_logic)

위 §10 서술은 Edge Function 트리거를 전제로 썼으나, **실제 구현은 Postgres 트리거**다
(`runs` 테이블의 `runs_03_evaluate_badges` AFTER 트리거 → `evaluate_badges(user_id, run_id)` →
`evaluate_badge_condition(user_id, condition_type, condition)` 디스패치). 세션형/누적형을
따로 구분하지 않고 매 `runs` INSERT/UPDATE/DELETE마다 미획득 permanent 뱃지 전체를
재평가한다 — 카탈로그가 146행 규모라 전체 스캔 비용이 낮기 때문(§6.4 근거와 동일 판단).

44개 `condition_type` 중 21종을 이번에 구현했고, 23종(레벨/시즌 19종/역지오코딩/기기판별 2종)은
선행 의존성 미해결로 `false` 스텁을 유지한다. 상세는 `_workspace/{날짜}_backend_badge-evaluation-logic.md` 참조.

> ✅ **2026-08-26 완료(마이그레이션 41)**: **`evaluate_badge_condition` 의 `raise notice … 보류` 스텁이 0개가 됐다.**
> 해제된 5종 — `level_gte`(→ `profiles.level`, 39번), `device_source_count_gte`/`device_source_diversity_gte`
> (→ `runs.device_vendors` 배열 겹침, 36번), `calendar_date_match` 음력 2건(→ `lunar_holidays`, 38번).
> `district_diversity_gte` 는 분기 자체를 삭제했다(37번에서 뱃지 2종·CHECK 제거).
> 현재 `condition_type` **39종 전량이 실제 판정**이며, `false` 가 나오는 경우는 스텁이 아니라 조건 미충족이다.

> **이후 진행 상황(2026-08-25~26)**: 시즌 조건 19종은 이후 라운드(마이그레이션 31~34)에서
> 전부 실제 판정 로직으로 교체됐다(§3.6 상단 정정 노트 참고). 2026-08-26에는 사용자 요청으로
> `seasonCumulativeDistance`/`seasonFinisher` 카테고리와 그 조건 타입 4종
> (`season_cumulative_distance_gte`/`consecutive_seasons_participated_gte`/
> `season_first_and_last_week_active`/`season_final_week_active`)이 카탈로그에서 완전히
> 삭제됐다(마이그레이션 35) — 이후 2026-08-26에 `district_diversity_gte` 2종
> (`route_district_3`/`route_district_10`)도 사용자 요청으로 삭제되어 현재
> `condition_type`은 **39종**이다.

### 10.2 판정 규칙 정본 (2026-08-26 확정 — gamification-designer)

§10.1 구현 당시 문서화되지 않은 가정으로 채웠던 항목들이 정식 규칙으로 확정됐다.
정본은 [`_workspace/20260826_000340_gamification_badge-backlog-decisions.md`](../_workspace/20260826_000340_gamification_badge-backlog-decisions.md)이며,
아래는 그 요약이다. **⚠️ 표시는 기존 구현에서 값이 바뀌는 항목**이라 마이그레이션이 필요하다.

| 조건 | 확정 규칙 |
|---|---|
| `pb_first_achieved` | 세션 거리 ≥ `목표 − min(목표×2%, 300m)`. **상한 없음**. 실외·완주·비플래그만 ⚠️ |
| `pb_time_lte` | 위 거리 조건 + 기록 시간: 거리가 목표의 102% 이하면 `moving_seconds`, 초과하면 **GPS 샘플 선형 보간으로 목표 거리 통과 시각**. 보간 불가(샘플 없음)면 해당 거리 PB로 인정하지 않는다. 거리 비례 환산 금지 ⚠️ |
| `season_first_long_distance` | **`pb_first_achieved`와 동일한 거리 허용오차** `목표 − min(목표×2%, 300m)`(고정 98% 폐기, 하프 기준 20,678m → 20,800m). 같은 "목표 거리 완주" 판정에 두 기준을 두지 않는다. 대상 필터(실외·완주·비플래그·시즌 범위)는 유지. ✅ 적용됨(마이그레이션 42) |
| `session_distance_gte` | 위와 동일한 이유로 동일 허용오차 적용(고정 허용오차 없음 → `목표 − min(목표×2%, 300m)`). 대상 필터(완주·비플래그)는 유지. ✅ 적용됨(마이그레이션 42) |
| `route_diversity_count_gte` | 시작점 **반경 300m 그리디 클러스터링**. `started_at` 오름차순 처리, 클러스터 대표점(anchor) 갱신 없음 → 결정적 ⚠️ |
| `loop_course_count_gte` | 출발-도착 haversine **≤150m** + 총 거리 **≥2.0km** + GPS 샘플 ≥10개 ⚠️ |
| `streak_weeks_gte` | KST 월~일 주. **활동 주 = 완주 1건 이상 AND 주 합산 거리 ≥1.0km**(실내·수동 포함). **1회 유예 크레딧 자동 소모**, 유예 후 4주 연속 활동 시 회복, 스트릭 종료 시 크레딧 리셋. 유예 주는 스트릭 카운트·XP 모두 0. 크레딧은 저장 상태가 아니라 가입 주부터의 **리플레이 파생값**. 판정 대상은 `longest_streak_weeks` ⚠️ |
| `pace_negative_split_count_gte` | 총 거리 절반 지점(보간) 기준 후반<전반. **세션 거리 ≥4km**만 대상 ⚠️ |
| `pace_final_km_faster_pct_gte` | **세션 거리 ≥5km**. 마지막 **완주된** 1km 스플릿 vs 그 앞 구간 평균 km 페이스 ⚠️ |
| `pace_variance_lte` | CV = stddev/mean×100. **완주된 정수 km 스플릿만**(자투리 제외), **스플릿 ≥3개**여야 판정 ⚠️ |
| 스플릿 헬퍼 `_run_km_split_seconds` | 경계를 사이에 둔 두 샘플 간 **누적거리 비율 선형 보간**으로 시각 산출. 워치 동기화 기록은 샘플 간격이 60초 이상일 수 있어 무보간 근사는 최대 1분 오차가 난다 ⚠️ |
| `calendar_date_match` 음력 | **고정 룩업 테이블 `public.lunar_holidays(holiday_key, year, solar_date)`** 채택. `holiday_key`는 `condition->>'date'` 값(`lunar_newyear`/`chuseok`)과 동일 문자열. 2026~2040 15년치 확정(한국천문연구원 기준 — 중국 음력 라이브러리와 2027·2028 설날이 하루 다르므로 회귀 테스트 필수). 미등재 연도는 `false` |
| `season_weekly_rank_lte` | `bucket ∈ {top1, top10, top10pct}` 3종 확정. 모집단 = 주 종료 시점 해당 티어 + 주간 거리>0. 순위는 PRD §8.2 3단계 타이브레이크 + `user_id` 최종 폴백으로 **고유 순위**. `top1`은 N≥10, `top10`/`top10pct`는 N≥20일 때만 발급 |
| `device_source_count_gte` / `device_source_diversity_gte` | **정본은 §3.1.2**(중재 결과 — 스칼라 `runs.device_source` 안은 폐기). `runs.device_vendors`(`device_vendor[]`) 배열 겹침 `&&` 단일 규칙. 토큰 5종 `phone`/`watchApple`/`watchGarmin`/`watchOther`/`unknown`. OR 구분자 **`_or_`**, `sources` 배열 원소 간은 **AND**. 대상은 완주·비플래그 세션 |
| `level_gte` | §3.7 참조 |

> ✅ **위 표 전체가 2026-08-26 마이그레이션 41 로 구현·적용됐다.** 관련 헬퍼 함수:
> `_run_time_at_distance`(선형 보간) / `_run_km_split_seconds`(보간 기반, 완주된 정수 km만 방출) /
> `_run_negative_split(samples, distance_m)` / `_run_final_km_faster_pct(samples, pct, distance_m)` /
> `_run_pace_variance_pct`(스플릿 3개 미만이면 null) / `_route_cluster_count(user_id)`(300m 그리디) /
> `_pb_best_seconds(user_id, target_km)` / `_device_vendor_tokens(text)`.
>
> **구현 노트 — `_route_cluster_count` 의 "첫 매칭에서 멈춤"**: 정본은 "가장 가까운 클러스터에 편입"이지만
> anchor 를 갱신하지 않으므로 어느 클러스터에 넣든 **클러스터 개수는 동일**하고, 이 함수의 반환값은
> 개수뿐이라 결과가 정확히 같다. 최근접 탐색을 생략해 상수만 줄인 것이다.
>
> **구현 노트 — 스트릭 리플레이 시작 주**: 정본은 "가입 주"지만 서버 `_weekly_streak_state` 와
> 클라이언트 `GamificationStats.computeWeeklyStreak` 모두 `least(가입 주, 첫 활동 주)` 로 감쌌다.
> 프로덕션 불변식(가입 ≤ 첫 러닝) 아래에서는 결과가 정본과 동일하고, 시드/임포트 데이터처럼 러닝이
> 가입보다 앞서는 경우에 러닝을 리플레이에서 잃지 않는다.

**공통**: 모든 날짜·시간대 판정은 KST(UTC+9 고정) · 러닝 귀속은 `started_at` 기준.
**임계값이 조여진 항목이라도 이미 지급된 뱃지는 회수하지 않는다**(PRD §8.1) —
`evaluate_badges`는 INSERT 전용이므로 자동으로 지켜지며, DELETE/revoke 경로를 추가하지 말 것.



## 11. 비기능 요구사항 → 기술 목표치 매핑

| 요구사항 | 목표 | 검증 방법 | 담당 계층 |
|---|---|---|---|
| GPS 거리 오차 | ±3% 이내 | 실측 1km 코스 반복 측정 | `tracking` 모듈(§8.3) |
| 배터리 소모 | 1시간 10% 이하 | 실기기 배터리 로그 측정(표준 모드) | `tracking` 모듈(§8.5) |
| 콜드 스타트 | 3초 이내 | 프로파일링(cold start trace) | `core/router` 초기 의존성 최소화 |
| 랭킹 조회 | 1초 이내 | API 응답 시간 측정(p95) | `leaderboard_entries` 배치(§9) |
| 기록 손실 | 0건 | 강제 종료/크래시 재현 테스트 | 로컬 영속 저장(ARCHITECTURE §9) |
| 오프라인 동기화 | 100% 업로드 | 비행기 모드 테스트 | 업로드 큐(ARCHITECTURE §9) |
| 티어·랭킹 정합성 | 서버 단일 진실 원천 | 클라이언트 잠정치 vs 서버 확정치 비교 로그 | `runs` 트리거·함수(§6.0, §7) |
| 접근성(러닝 중 화면) | 최소 24sp, 명암비 4.5:1 | 디자인 QA | `presentation/` (flutter-ui-designer 영역) |

---

## 12. 보안 요구사항

- **인증**: Supabase Auth. **현재 카카오 OAuth 웹 플로우만 구현**(`core/auth/`). Apple/Google 로그인은 Phase 2(AC-01) — iOS는 Apple 로그인 필수 제공(App Store 심사 요건).
- **RLS**: §5 전 테이블 적용. 서버 쓰기는 SECURITY DEFINER 트리거·함수. service role 키는 클라이언트 번들에 절대 포함하지 않는다(현재 클라이언트는 anon 키만 사용, `AppConfig` — `--dart-define`).
- **데이터 삭제(AC-04)**: *(미구현 — Phase 2)*. 설계상 계정 삭제 시 `profiles` cascade로 `runs`/`user_badges`/`season_histories`/`tier_change_history` 전량 삭제. 삭제 후 `leaderboard_entries`는 다음 배치 사이클에 자동 반영.
- **GPX 내보내기(HI-09, P1)**: **구현 완료(클라이언트 전용, 2026-08-31).** `RunRecord.samples`를 `history/domain/gpx_encoder.dart`에서 GPX 1.1 XML로 직렬화(외부 패키지 없이 `StringBuffer` + 수동 이스케이프), 임시 파일로 써서 `share_plus` 공유 시트로 전달(`history/data/gpx_export_service.dart`). 좌표 있는 샘플 2개 미만이면 상세 화면 진입점(오버플로 메뉴)을 노출하지 않는다. 심박/케이던스는 Garmin `TrackPointExtension` 네임스페이스로 포함. 서버 렌더링 불필요.
- **부정 기록 데이터 보존**: `flagged=true` 기록은 삭제하지 않고 보존(§7 원칙) — 이의 제기 대응 근거.

---

## 13. Phase 0 완료 기준 (Definition of Done) — ✅ 완료

PRD §11 "Phase 0 — 아키텍처·데이터 모델·Supabase 스키마 확정"의 완료 조건:

- [x] `docs/ARCHITECTURE.md`, `docs/TRD.md` — 작성 완료, 구현 반영본으로 유지 중
- [x] `lib/models/*.dart` — freezed 클래스로 생성 완료(설계와 일부 진화, §3 상단 노트)
- [x] Supabase 스키마 마이그레이션 00~42 적용 (`backend-engineer`)
- [x] RLS 정책 적용 (`07_rls.sql` + 이후 마이그레이션)
- [x] §4.1 camelCase↔snake_case 매핑표 유지 (`wire_enums.dart` 대조)
- [~] ~~`upload-run-record` Edge Function 스켈레톤~~ — **폐기.** PostgREST upsert + `runs` 트리거 체인으로 대체(§6.0). Phase 1 클라이언트 업로드 코드는 이 방식으로 작성됨

**현재 위치: Phase 1~2 진행 중.** 남은 P0 항목은 ARCHITECTURE §13 참조.

---

## 14. 미확정 기술 이슈 (Open Items)

| # | 이슈 | 확정 필요 시점 |
|---|---|---|
| ~~1~~ | ~~로컬 영속 저장소 패키지(Hive/Drift/Isar)~~ → **해소. drift로 확정·구현 완료**(`lib/features/tracking/data/local_run_database.dart`) | — |
| 2 | `run_samples` jsonb → 별도 테이블 전환 임계 규모 | Phase 1 실측 후 |
| ~~3~~ | ~~공유 카드(HI-08) 이미지 렌더링 방식(클라이언트 위젯 캡처 vs 서버 렌더링)~~ → **해소(2026-08-26). 클라이언트 위젯 캡처 확정** — `RenderRepaintBoundary.toImage()`로 1080×1920 투명 PNG(규격 히스토리는 §3.9.2). 서버 렌더링을 버린 이유: (a) 디자인 시스템(`AppTokens`·Pretendard 가변 폰트·뱃지 SVG 146종)이 전부 Flutter 자산이라 서버에 **두 번째 구현**이 필요하고 어긋나면 앱에서 본 카드와 올라간 카드가 달라진다, (b) 마케팅 예산 0원(BRD)인데 유일한 성장 레버에 서버 비용·왕복을 얹을 이유가 없다, (c) HI-10은 러닝 종료 직후에 동작해야 하는데 그 지점은 신호가 나쁠 수 있다(오프라인 우선 §9의 연장), (d) 경로 좌표가 이미지 한 장 만들자고 기기 밖으로 나가지 않는다. 서버 렌더링은 **링크 공유의 OG 이미지**가 필요해질 때 이 경로를 대체하는 게 아니라 추가된다 — PRD가 요구하는 건 스토리에 올릴 이미지 파일이다. 스펙은 §3.9.2 | — |
| ~~4~~ | ~~시즌 롤오버 시 `user_season_tier` 신규 row를 lazy insert할지~~ → **무효.** `user_season_tier` 테이블 자체가 없다. 티어는 `profiles` 컬럼이고 `sync_my_season`/`reset_stale_seasons`가 조회 시점에 시즌 리셋을 지연 처리한다 | — |
| 5 | 이상치 판정 임계값(가속도, accuracy 등)의 실측 튜닝 | Phase 1 실기기 테스트 후 |
| 6 | GPX 내보내기 클라이언트 vs 서버 처리 | Phase 1 이후(P1) |
| 7 | 포인트 이코노미(Phase 4) 테이블 설계 | Phase 4 착수 전 — PRD §10.2 |
| 8 | Apple Watch 벤더 판별의 기기명 의존(§8.4.1) — `HKDevice`/`Metadata.device`를 얻는 얇은 platform channel이 필요한지 | P1 웨어러블 실기기 테스트에서 오분류가 실제로 확인되면 |
| ~~9~~ | ~~`device_source_diversity_gte`의 OR 표현식 파싱 규약~~ → **해소(2026-08-26)**. 문법·매칭 시맨틱 모두 §3.1.2에 정본화 | — |
| ~~10~~ | ~~`runs.device_vendors` 마이그레이션(§4.0) 미적용~~ → **해소(2026-08-26, 마이그레이션 36)**. 컬럼·GIN 인덱스·백필·판정 로직 전부 적용됐다. 뱃지 5종은 이제 판정 가능하며, 실제 지급은 P1 웨어러블 연동으로 `device_vendors` 에 값이 실리기 시작한 뒤부터다 | — |
| 11 | **`season_weekly_rank_lte` 최소 모집단(top1 N≥10 / 나머지 N≥20)이 현재 시드 규모에서 절대 충족되지 않는다.** 티어별 모집단이 1~4명이라 이 뱃지 12종은 실사용자가 붙기 전까지 아무도 못 받는다. 판정 로직은 정확하지만 **아직 실데이터로 검증되지 않았다** | 베타 사용자 20명 이상 확보 시 |
| 12 | **주간 랭킹 확정 배치가 아직 `pg_cron` 에 없다.** 정본(§2.2)은 "매주 월요일 KST 00:10(`10 15 * * 0` UTC)"이고, 현재는 마이그레이션 16의 기존 `refresh_all_leaderboards` 주기 스케줄 + 46번의 `runnit-rank-notify`(매시)에 의존한다. 주 경계 직후 확정 시점이 스펙과 다르다. **이 배치가 없어서 딸려 있는 미구현 2건**: (a) RK-06 주간 상위권 뱃지가 "주간 확정 직후"가 아니라 다음 러닝 때 발급된다, (b) NT-06의 `badge_level:weekly:{week_id}` 키(주간 유래 뱃지 알림)를 쓰는 발화점이 아직 없다 | Phase 2 랭킹 모듈 |
| 23 | **`season_weekly_rank_lte` 판정에 최소 모집단 게이트와 "확정된 지난 주" 필터가 없다**(gamification 문서 §6.2 결함 #1·#2, 마이그레이션 32). 참가자 3명인 티어에서 1위 뱃지가 나가고, 진행 중인 주간의 일시적 1위로도 발급된다 — 뱃지는 영구 자산이라 정상 경로로 회수할 수 없다. 현재 시드 규모(티어당 1~4명)에서는 아무도 못 받아 실피해가 없으나, **베타 사용자가 10명을 넘는 순간부터 되돌릴 수 없다.** 수정 SQL은 그 문서 §6.2에 그대로 이식 가능 | 🔴 **베타 오픈 전 필수** |
| 25 | **알림 시스템(NT-01~08) 검증이 자동 테스트(208개) 수준에서 멈춰 있다.** ① 서버 알림 생성 + 인앱 알림함 검증 — FCM 없이 가능. 동기 트리거(NT-01/02/06)는 테스트 계정 러닝 업로드로, 배치(NT-03/04/05)는 `select notify_season_ending()` / `refresh_leaderboards_and_notify()` / `notify_weekend_push()` 수동 호출로 `notifications` 적재를 확인하고, 앱 알림함(마이페이지→종)에서 렌더·딥링크·읽음·미읽음 배지·종류별 토글을 눈으로 검증. NT-04는 `participant_count >= 10` 게이트로 현재 시드에선 안 뜸(#11·#12와 동일 제약). ② 실기기 푸시 검증 8항목 — FCM 운영 설정(프로젝트·서비스계정·네이티브 설정 파일·Vault 시크릿 2개·`push-dispatch` 배포) 완료 후. 절차·트리아지 표는 `_workspace/20260828_174224_ui_notifications.md` §5. 레벨 단독 알림(§5 항목 6, C-3 크래시하던 경로)은 러닝으로 발화 안 함 — 테스트 계정에 XP 경로를 별도로 태워야 함 | ① 지금 가능(테스트 계정 uid 확보 시) / ② FCM 운영 설정 후 |
| ~~24~~ | ~~알림 문구의 `display_name`이 공개 범위(AC-05)를 우회한다~~ → **비쟁점화(2026-08-31, v1.7)**. AC-05(비공개)를 삭제해 모든 프로필이 공개이므로 알림에 이름을 그대로 써도 우회할 설정이 없다. 이름이 비면 `"순위가 128위 → 131위로 내려갔어요"` / `"2위가 …"` 폴백은 그대로 유지 | — |
| ~~13~~ | ~~`season_first_long_distance` 의 거리 허용오차가 PB 조건과 다르다~~ → **해소(2026-08-26, 마이그레이션 42)**. `목표 − min(목표×2%, 300m)` 으로 통일(§10.2 표) — 같은 "목표 거리 완주" 판정이므로 별도 기준을 둘 이유가 없다 | — |
| ~~15~~ | ~~`session_distance_gte` 5종은 허용오차 없이 정확히 `≥ 목표×1000m`~~ → **해소(2026-08-26, 마이그레이션 42)**. 동일 허용오차 `목표 − min(목표×2%, 300m)`로 통일(완화 방향이라 소급 회수 없음, `evaluate_badges` 재실행으로 미지급분 채움) | — |
| 14 | **`tier_change_history` 가 0행이라 XP-4(티어 도달 XP)가 아무에게도 적립되지 않고 있다.** 마이그레이션 34가 "상승 이벤트만 기록"으로 정정하면서 백필을 취소했고(소급 복원 불가는 의도된 결정), 기존 유저는 이번 시즌에 강등 없이는 다시 상승할 기회가 없다. 다음 시즌부터 정상 적립된다 — 그때까지 `total_xp` 는 XP-4 만큼 과소 집계된 상태다 | 2026-Q4 시즌 시작 시 자연 해소 |
| 16 | **`session_distance_gte`는 실내 러닝을 제외하지 않는데 `pb_first_achieved`/`season_first_long_distance`는 제외한다.** 마이그레이션 42가 세 조건을 "같은 목표 거리 판정"으로 선언해 허용오차만 통일했고 실내 취급 차이는 그대로 남았다 — 트레드밀 42.2km는 `session_dist_full`(풀런)은 받고 `pb_first_full`/`season_first_long_distance`는 못 받는다. PRD §8.3(실내 기록 처리)만으로는 이 셋 중 무엇이 맞는 기준인지 단정할 수 없다 | gamification-designer 확인 대상 |
| 18 | **`user_badges`에 "판정 확정값" 컬럼이 없다** — PB 카드가 서버가 확정한 기록(초)을 그릴 수 없는 구간이 생긴다(§3.9.1). 제안: `achieved_value numeric null` 한 컬럼에 서버가 판정 시점 값(PB 초 / 스트릭 주 / 주간 순위)을 적는다. **P0는 이것 없이 성립**한다(102% 이내는 `moving_seconds`가 곧 서버 규칙, 초과 구간은 시간을 비운 카드) — 이 컬럼이 생기면 폴백 분기가 사라진다 | P1, backend-engineer |
| ~~19~~ | ~~성취 큐에 소비자가 없어 밀린 `is_seen=false` 뱃지가 한꺼번에 쏟아진다~~ → **해소(2026-08-26, UI 구현)**. `isAchievementBacklog()`(`features/sharing/domain/achievement_backlog.dart`)가 **개수(>5) 또는 획득 시각 간격(>24h)** 중 하나라도 걸리면 큐를 "밀린 성취"로 보고 "그동안 받은 뱃지 N개" 한 장으로 접은 뒤 **일괄** `markBadgesSeen` 한다. 요약 화면·전역 호스트 양쪽에 같은 판정이 걸려 있다. **로컬 "이미 처리함" 플래그는 두지 않았다** — 접고 나면 서버 행이 `is_seen=true`가 되어 큐에서 영구히 빠지므로 그 상태는 이미 서버가 들고 있고, 같은 사실을 두 곳에 적으면 재설치·기기 변경에서 어긋난다 | — |
| 17 | **클라이언트 진행률 바가 마이그레이션 42의 새 허용오차(§10.2)를 반영하지 않는다.** `badge_condition.dart`의 `sessionDistanceGte` 진행률 계산이 여전히 `distance/목표`(정확 비율)라, 텐런을 9.8km(서버 인정 기준)에서 뛰어도 바는 98.00%로 멈춘다. 실제 지급 시점에 `isEarned`가 `ratio: 1.0`으로 스냅해 자가 치유되므로 사용자에게 "받았는데 바가 98%"로 잠깐 보이는 정도이며, 클라이언트가 값을 내는 조건이 이 하나뿐이라 영향 범위는 좁다 | 다음 gamification-designer/flutter-ui-designer 라운드에서 진행률 계산에 동일 허용오차 반영 |
| ~~20~~ | ~~성취 억제 카운터와 전역 축하 다이얼로그 사이에 프레임 경합이 있다~~ → **해소(2026-08-27).** 인라인 축하(요약 화면)와 억제 카운터 메커니즘 자체를 제거하고 전역 `AchievementCelebrationHost` 풀페이지 하나로 통합했다(사용자 요청, §3.9.3). 경합을 일으키던 두 소비 지점 중 하나가 사라져 원인이 구조적으로 없어졌다 | — |
| 21 | **뱃지 아트 경로 규칙이 다시 두 곳이다**(QA O-4) — `badge_assets.dart`의 정본 `badgeAssetPath`와 `share_card_body.dart`의 `tierEmblemAssetPath`가 별도로 존재한다. 현재는 `assets/badges/tier/{bronze,silver,gold,platinum}.svg` 파일명이 우연히 일치해 문제가 드러나지 않지만, 이번 라운드가 없앤 이원화와 같은 형태다 | flutter-ui-designer, 정본으로 통합 |
| 22 | **`share_card_renderer.dart` 주석의 뱃지 SVG 종수가 158종으로 적혀 있으나 정본(`docs/badge-catalog.csv`)은 현재 146개다.** 판정 로직에 쓰이는 숫자는 아니고 서술뿐이지만, 카탈로그 삭제(마이그레이션 35/37)가 반영 안 된 흔적이다 | 문서 정리, 낮은 우선순위 |
