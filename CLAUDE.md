## 하네스: Runnit 러닝 앱 개발

**목표:** 러닝 기록/GPS·웨어러블 트래킹/랭킹/뱃지 게이미피케이션을 갖춘 Flutter 러닝 앱(Runnit) 개발을 전문 에이전트 팀으로 조율.

**트리거:** 이 앱의 기능 개발/구현/수정 요청 시 `running-app-builder` 스킬을 사용하라 (GPS 트래킹, 웨어러블 연동, 러닝 기록, 티어/랭킹, 뱃지·레벨, Flutter 화면, Supabase 백엔드 등). 단순 질문은 직접 응답 가능.

## 📌 제품 사양 — 단일 진실 원천

| 문서 | 역할 |
|------|------|
| [docs/PRD.md](docs/PRD.md) (v1.4 확정) | **제품 사양의 유일한 기준.** 기능·정책·우선순위 |
| [docs/BRD.md](docs/BRD.md) (v0.1) | 사업 배경·수익 모델·GTM·손익 구조 |

**규칙**
1. 이 앱의 기능을 설계·구현·검증하기 전에 **반드시 `docs/PRD.md`의 관련 섹션을 읽는다.**
2. 하네스 문서(에이전트·스킬·이 파일)의 서술이 PRD와 충돌하면 **PRD가 우선한다.**
3. PRD에 없는 신규 기능을 구현했거나 확정 사양을 바꿔야 하면, **사용자 확인 후 `docs/PRD.md`를 갱신하고 변경 이력에 기록한다.** 코드와 PRD가 어긋난 채로 두지 않는다.

## 📐 기술 설계 문서 (PRD를 구현 구조로 번역)

| 문서 | 역할 |
|------|------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (v0.2 초안) | 시스템 아키텍처 — 클라이언트/백엔드 구조, 데이터 흐름, 모듈 경계 |
| [docs/TRD.md](docs/TRD.md) (v0.9 초안) | 기술 요구사항 — 데이터 모델 코드, Supabase DDL, API/검증 규칙 스펙 |

PRD와 이 두 문서가 충돌하면 **PRD가 우선**한다. 이 문서들은 사양을 새로 정의하지 않고 구현 구조로 번역한 것이다.

**모든 에이전트·스킬은 기능을 설계·구현·검증하기 전에 `docs/PRD.md`와 함께 이 두 문서의 관련 섹션을 확인한다.** 구현이 발전해 이 문서들과 달라지면(스키마 확장, 배치 전략 변경 등) 문서를 갱신해 코드와 어긋나지 않게 한다 — PRD처럼 고정된 확정 사양이 아니라, 구현과 함께 갱신되는 살아있는 문서다.

**핵심 구조 (자주 혼동되는 부분)**

| 축 | 주기 | 평가 방식 | 요약 |
|----|------|----------|------|
| **티어** | 3개월 (분기 시즌) | **절대평가** | 시즌 누적 거리 기준. 4단계 — 브론즈 0 / 실버 25km / 골드 100km / 플래티넘 250km. 시즌 중 강등 없음 |
| **주간 랭킹** | 1주 (월~일 KST) | **상대평가** | 같은 **티어 내** 주간 누적 거리 순위. 매주 리셋 |
| **뱃지 · 레벨** | 영구 | 절대평가 | 리셋 없음 |
| **포인트** | Phase 4 | — | MVP 범위 밖 |

⚠️ **폐기된 전제 (하네스 초기 구성에 남아 있던 것들)**
- ~~크루 중심 설계~~ → **개인 중심 앱.** 크루/그룹은 **P2** (PRD §2.3, §5.9)
- ~~상대평가 리그 매칭~~ → **절대평가 티어.** 서브 그룹 매칭 로직을 만들지 않는다 (PRD §5.4.1)
- ~~포인트를 MVP에 포함~~ → **Phase 4**

**변경 이력:**
| 날짜 | 변경 내용 | 대상 | 사유 |
|------|----------|------|------|
| 2026-08-19 | 초기 구성 (에이전트 6개, 스킬 7개, 오케스트레이터 1개) | 전체 | 신규 프로젝트 하네스 구축 |
| 2026-08-19 | 백엔드 Supabase 확정(변경 없음, 기존 기본값 유지), 웨어러블 우선순위를 Apple Watch·Garmin으로 명시 — Garmin은 Garmin Connect→HealthKit/Health Connect 동기화 경유로 설계, references/garmin-integration.md 추가 | agents/gps-tracking-engineer.md, skills/gps-wearable-tracking/ | 사용자가 백엔드/워치 우선순위를 확정 |
| 2026-08-19 | **PRD/BRD 작성 및 하네스 연결** — CLAUDE.md에 제품 사양 진입점 추가, 에이전트 6개·스킬 7개 전체에 `docs/PRD.md` 참조 주입, 오케스트레이터 Phase 0에 PRD 선독 단계 추가 | CLAUDE.md, agents/* (6), skills/* (7), docs/PRD.md, docs/BRD.md | 제품 사양이 확정되어 하네스가 이를 기준으로 작업하도록 연결 |
| 2026-08-19 | **폐기된 전제 정리** — 크루 중심 랭킹/챌린지, 상대평가 리그를 티어(절대평가)+주간 랭킹(상대평가) 이중 구조로 교체. backend 스키마 가이드에 seasons/user_season_tier/weekly_ranking_cache 분리 명시 | agents/gamification-designer.md, agents/backend-engineer.md, agents/mobile-architect.md, skills/gamification-system-design/, skills/supabase-running-backend/ | 하네스가 PRD 확정 이전 전제로 설계하는 것을 방지 |
| 2026-08-25 | **아키텍처/TRD 초안 작성 (Phase 0 산출물)** — PRD v1.3과 하네스 에이전트·스킬에 이미 반영돼 있던 기술 결정(데이터 모델, Supabase 스키마 골격, GPS/웨어러블 연동 경로, 서버 검증 파이프라인)을 종합해 `docs/ARCHITECTURE.md`, `docs/TRD.md` 신규 작성 | CLAUDE.md, docs/ARCHITECTURE.md(신규), docs/TRD.md(신규) | PRD §11 Phase 0(아키텍처·데이터 모델·Supabase 스키마 확정) 산출물을 문서화해 Phase 1 착수 근거를 마련 |
| 2026-08-26 | **뱃지 시스템 백로그 7건 실제 구현** — XP/레벨 공식(만렙 60), 주 단위 스트릭 + 1회 유예, 기기 벤더 배열 모델(`runs.device_vendors`), PB/거리 뱃지 허용오차 통일(목표−min(목표×2%, 300m)), 음력 룩업 테이블(2026~2040), `district_diversity_gte` 뱃지 삭제. TRD v0.1→v0.8까지 단계적으로 갱신 | docs/TRD.md, Supabase 마이그레이션 36~42 | 사용자가 정리한 5개 백로그 중 1번(뱃지 시스템) 처리 |
| 2026-08-26 | **공유 카드 기능 구현 (PRD HI-08·HI-10, P0)** — 클라이언트 위젯 캡처(`RenderRepaintBoundary`) 방식 확정, 레퍼런스 이미지 기준 9:16 투명 오버레이 스티커로 규격 확정(그림자·배경 없음), 바텀시트→풀페이지 전환(하단 네비바 회귀 수정 포함) | lib/features/sharing/*, docs/TRD.md §3.9 | 5개 백로그 중 3번(공유 카드) 처리, BRD §5.2가 요구하는 무료 성장 레버 확보 |
| 2026-08-27 | **PRD v1.4: HI-10 범위를 PB 갱신 공유로 축소** — 뱃지 획득·티어 승급 축하를 다이얼로그→풀페이지+애니메이션(`_AchievementBurst`)으로 전환하면서, 공유 버튼은 PB 갱신에만 남기고 뱃지/티어는 축하만 하도록 확정. 요약 화면 인라인 축하와 억제 카운터(`achievementCelebrationSuppressors`) 제거 — 전역 `AchievementCelebrationHost` 풀페이지가 유일한 소비 지점 | docs/PRD.md(v1.4), docs/TRD.md(v0.9, §3.9.3), docs/ARCHITECTURE.md(v0.2, §7.4.1), lib/features/sharing/presentation/widgets/achievement_celebration.dart | 사용자가 구현 중 세 차례에 걸쳐 공유 범위를 PB 전용으로 확정, 문서를 실제 구현과 일치시킴 |
