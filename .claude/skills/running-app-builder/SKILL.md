---
name: running-app-builder
description: "Runnit(러닝 기록/랭킹/뱃지 게이미피케이션 Flutter 앱)의 개발 작업을 조율하는 오케스트레이터. GPS 트래킹, 웨어러블(Apple Watch/Wear OS) 연동, 러닝 기록, 랭킹/리더보드, 뱃지·레벨 게이미피케이션, Flutter 화면, Supabase 백엔드 등 이 프로젝트의 기능 개발/구현/수정 요청 시 사용. 예: '러닝 트래킹 화면 만들어줘', '뱃지 시스템 추가해줘', '랭킹 API 붙여줘', 'GPS 정확도 개선', '워치 연동 붙여줘'. 후속 작업 키워드: 기존 기능 수정/보완/재작업/버그 수정/업데이트/개선 요청, '트래킹만 다시', '뱃지 조건 바꿔줘', '이전 결과 기반으로' 요청 시에도 반드시 이 스킬을 사용."
---

# Runnit Builder — 러닝 앱 개발 오케스트레이터

Runnit(**개인 중심** 러닝 기록·티어·랭킹·뱃지 앱) Flutter 앱의 기능 개발을 전문 에이전트 팀으로 조율하는 통합 스킬.

> 📌 **제품 사양의 단일 진실 원천은 `docs/PRD.md`(v1.0 확정)이며, 사업 맥락은 `docs/BRD.md`다.**
> 이 스킬을 포함한 모든 하네스 문서의 서술이 PRD와 충돌하면 **PRD가 우선한다.**
> 핵심 구조 — **티어**(3개월 분기 시즌, 절대평가, 4단계 0/25/100/250km) × **주간 랭킹**(티어 내 상대평가) × **뱃지·레벨**(영구). 포인트는 Phase 4로 MVP 범위 밖이며, **크루/그룹은 P2다.**

## 실행 모드: 에이전트 팀 (감독자 + 전문가 풀 하이브리드)

이 오케스트레이터는 매 요청마다 6명 전원을 소집하지 않는다. **감독자(리더)가 요청 범위를 분석해 필요한 전문가만 선별하여 동적으로 팀을 구성**하고, 선별된 팀원들은 공유 작업 목록과 SendMessage로 자체 조율한다. QA는 팀 전체가 끝난 뒤 한 번이 아니라, 모듈이 완성되는 즉시 투입한다(incremental QA).

## 에이전트 구성 (전문가 풀)

| 전문가 | 에이전트 타입 | 담당 | 스킬 | 산출물 |
|--------|-------------|------|------|--------|
| mobile-architect | 커스텀 | 앱 구조·상태관리·핵심 데이터 모델 | flutter-architecture-setup | `lib/models/`, `_workspace/*_architect_data-model.md` |
| gps-tracking-engineer | 커스텀 | GPS·웨어러블 트래킹, 거리/페이스 계산 | gps-wearable-tracking | `lib/features/tracking/`, `_workspace/*_gps_tracking_notes.md` |
| gamification-designer | 커스텀 | 뱃지·랭킹 로직·레벨·챌린지 | gamification-system-design | `lib/features/gamification/`, `_workspace/*_badge_rules.md` |
| backend-engineer | 커스텀 | Supabase 스키마·RLS·랭킹 API·서버 검증 | supabase-running-backend | Supabase 마이그레이션, `lib/core/api/`, `_workspace/*_backend_schema.md` |
| flutter-ui-designer | 커스텀 | 화면·위젯·디자인 시스템 | flutter-ui-patterns | `lib/features/*/presentation/`, `_workspace/*_ui_design_tokens.md` |
| qa-integration-tester | general-purpose | 경계면 통합 정합성 검증 | integration-qa-flutter | `_workspace/*_qa_report.md` |

모든 Agent/TeamCreate 호출에 `model: "opus"`를 명시한다.

## 워크플로우

### Phase 0: 컨텍스트 확인 (후속 작업 지원)

0. **`docs/PRD.md`를 먼저 읽는다 (생략 불가).** 요청과 관련된 섹션(티어 §5.3 / 주간 랭킹 §5.4 / 뱃지 §5.5 / 정책 §8)을 확인하고, 요청이 PRD의 확정 사양과 충돌하면 **구현 전에 사용자에게 알린다.** 요청이 PRD에 없는 신규 기능이면 그 사실을 보고하고, 구현 후 PRD 반영이 필요함을 명시한다.
1. `_workspace/` 디렉토리와 `pubspec.yaml`(Flutter 프로젝트 존재 여부)을 확인한다.
2. 실행 모드 결정:
   - **`pubspec.yaml` 미존재** → 초기 실행. mobile-architect를 반드시 포함해 프로젝트 골격부터 시작.
   - **`pubspec.yaml` 존재 + 새 기능 요청** → 증분 실행. 기존 `lib/models/`, `_workspace/*_architect_data-model.md` 등을 팀원 프롬프트에 포함해 기존 산출물을 존중하도록 지시.
   - **`_workspace/` 존재 + 특정 영역 수정/버그 요청** → 부분 재실행. 관련 전문가만 재소집.
3. 이전 `_workspace/*_qa_report.md`가 있으면 미해결 항목을 확인하고, 이번 작업 범위와 겹치면 우선 반영 대상에 포함한다.

### Phase 1: 요청 분석 및 전문가 선별 (감독자 판단)

리더가 사용자 요청을 분석해 관여할 전문가를 결정한다. 판단 기준:

| 요청 키워드/성격 | 소집 전문가 |
|-----------------|-----------|
| 신규 데이터 모델이 필요하거나 앱 구조 관련 | mobile-architect (거의 항상 포함 — 새 필드/모델이 생기면 이 팀부터) |
| GPS, 위치, 워치, 백그라운드 추적, 거리/페이스 계산 | gps-tracking-engineer |
| 뱃지, 업적, **티어·시즌**, 랭킹 규칙, 레벨, 챌린지, 포인트 | gamification-designer |
| 백엔드, DB, API, 인증, 랭킹 쿼리, 실시간 동기화 | backend-engineer |
| 화면, UI, 위젯, 디자인, 지도/차트 표시 | flutter-ui-designer |

기능이 여러 계층에 걸치면(예: "GPS 트래킹 화면 만들어줘" → 모델+트래킹+UI, 최소 3명) 관련 전문가 전원을 팀에 포함한다. 단일 계층 수정(예: "뱃지 아이콘 색상만 바꿔줘")은 flutter-ui-designer 1명을 **서브 에이전트**로 호출해도 충분하다 — 이 경우 팀 통신 오버헤드가 불필요하므로 `Agent` 도구 직접 호출로 처리한다.

`_workspace/` 생성(초기 실행 시, 또는 이전 작업 보존이 필요한 새 실행에서는 `_workspace_{YYYYMMDD_HHMMSS}/`로 이동 후 재생성).

### Phase 2: 팀 구성

```
TeamCreate(
  team_name: "runnit-team",
  members: [
    { name: "architect", agent_type: "mobile-architect", model: "opus", prompt: "{요청 요약 + 기존 산출물 경로 + 'docs/PRD.md를 먼저 읽고 확정 사양을 따를 것'}" },
    { name: "tracking", agent_type: "gps-tracking-engineer", model: "opus", prompt: "..." },
    { name: "gamification", agent_type: "gamification-designer", model: "opus", prompt: "..." },
    { name: "backend", agent_type: "backend-engineer", model: "opus", prompt: "..." },
    { name: "ui", agent_type: "flutter-ui-designer", model: "opus", prompt: "..." }
    // Phase 1에서 선별된 전문가만 포함
  ]
)
```

```
TaskCreate(tasks: [
  { title: "데이터 모델 확정", assignee: "architect" },
  { title: "GPS 트래킹 구현", assignee: "tracking", depends_on: ["데이터 모델 확정"] },
  { title: "뱃지/랭킹 로직 구현", assignee: "gamification", depends_on: ["데이터 모델 확정"] },
  { title: "백엔드 스키마·API", assignee: "backend", depends_on: ["데이터 모델 확정"] },
  { title: "화면 구현", assignee: "ui", depends_on: ["GPS 트래킹 구현", "뱃지/랭킹 로직 구현", "백엔드 스키마·API"] }
])
```

> **모든 팀원 프롬프트에 `docs/PRD.md`를 먼저 읽으라는 지시를 반드시 포함한다.** 팀원은 PRD를 모른 채 시작하면 크루 중심·상대평가 리그 등 폐기된 전제로 설계할 위험이 있다.
>
> mobile-architect의 데이터 모델이 다른 모든 작업의 선행 조건이다. 팀원당 3~5개 작업이 적정 범위(팀 크기 가이드라인 참조).

### Phase 3: 협업 실행

**실행 방식:** 팀원들이 공유 작업 목록에서 자체 조율.

- architect가 데이터 모델을 확정하면 즉시 전원에게 SendMessage로 브로드캐스트 — 나머지 작업은 이 브로드캐스트를 신호로 시작한다.
- tracking이 세션 종료 이벤트 구조를 확정하면 gamification에게 SendMessage로 전달.
- backend가 스키마를 확정하면 architect에게 필드 매핑 확인 요청, 불일치 시 즉시 SendMessage로 조율.
- ui는 architect/gamification/backend 산출물을 순차적으로 소비하므로 의존 작업이 완료되기 전까지 목업 데이터로 골격만 먼저 진행할 수 있다.
- 리더는 팀원 유휴 알림을 모니터링하고, 막힌 팀원에게 SendMessage로 개입하거나 TaskUpdate로 작업을 재조정한다.

**incremental QA:** 각 팀원이 담당 모듈을 완료했다고 보고하면(TaskUpdate 완료), 리더는 즉시 qa-integration-tester를 **서브 에이전트로** 호출해 해당 모듈의 경계면만 검증한다. 팀 전체 작업이 끝날 때까지 QA를 미루지 않는다. 발견된 이슈는 담당 팀원에게 SendMessage로 즉시 전달해 같은 세션 내에서 수정한다.

### Phase 4: 최종 통합 검증

모든 작업 완료 후(TaskGet으로 확인), qa-integration-tester를 1회 더 호출해 전체 경계면(모델↔스키마↔API↔UI↔이벤트 흐름)을 종합 재검증한다. incremental QA에서 다룬 항목은 "재확인"으로, 새로 나타난 통합 지점만 신규 검증으로 표시한다.

### Phase 5: 정리

1. 팀원들에게 종료 요청(SendMessage) 후 TeamDelete
2. `_workspace/` 보존 (설계 문서, QA 리포트는 다음 세션의 컨텍스트로 재사용됨)
3. 사용자에게 요약 보고: 구현된 기능, 소집된 전문가, QA 결과(통과/미해결), 다음 추천 작업

## 데이터 흐름

```
[architect] --SendMessage(모델 확정)--> [tracking, gamification, backend, ui]
     |
     v
lib/models/*.dart  (모든 팀원의 공통 기준점)
     |
     +--> [tracking] --이벤트--> [gamification] --뱃지 판정--> [backend] --재검증--> leaderboard_cache
     |                                                              |
     +--> [backend] --스키마 확정--> [architect] (필드 매핑 재확인)   |
     |                                                              v
     +----------------------------------------------------------> [ui] (최종 소비자)
     |
     v
[qa-integration-tester] --incremental--> 각 모듈 완료 시 즉시 검증
                        --final--> 전체 완료 후 종합 검증
```

## 에러 핸들링

| 상황 | 전략 |
|------|------|
| 팀원 1명 실패/중지 | 리더가 유휴 알림으로 감지 → SendMessage로 상태 확인 → 재시작. 재시작 실패 시 해당 영역을 리더가 직접 서브 에이전트로 대체 호출 |
| architect의 모델이 확정되지 않은 채 다른 팀원이 대기 | 리더가 architect에게 우선순위 상향 요청, 30분 이상 지연 시 잠정 모델로 나머지 팀원을 우선 진행시키고 추후 조정 |
| QA에서 CONFIRMED 이슈 발견 | 담당 팀원에게 즉시 SendMessage, 수정 완료까지 해당 모듈은 "미완료"로 유지 |
| 팀원 간 데이터(필드명 등) 충돌 | 삭제하지 않고 양쪽 주장을 병기해 사용자에게 보고, architect가 최종 결정 |
| **팀원 산출물이 PRD 확정 사양과 불일치** | qa-integration-tester가 PRD 대조로 검출 → 담당 팀원에게 SendMessage로 수정 요청. PRD가 항상 우선하며, PRD 자체를 바꿔야 한다면 **사용자 확인 후** `docs/PRD.md`를 갱신한다 |
| Supabase 마이그레이션 실패 | backend-engineer가 원인을 리더에게 보고, 파괴적 변경이면 사용자 확인 후 재시도 |

## 팀 크기

이 프로젝트는 소~중규모 기능 단위 작업이 반복되므로, 매 실행마다 Phase 1에서 선별된 2~5명 규모를 유지한다(가이드라인상 소규모 2~3명, 중규모 3~5명). 6명 전원이 필요한 요청(예: "MVP 전체 뼈대 잡아줘")은 예외적으로 발생할 수 있다.

## 테스트 시나리오

### 정상 흐름
1. 사용자: "러닝 시작하면 GPS로 경로 기록하고, 끝나면 완주 뱃지 주는 기능 만들어줘"
2. Phase 0: `pubspec.yaml` 없음 → 초기 실행
3. Phase 1: 데이터 모델(신규) + GPS + 뱃지 + 화면 필요 → architect, tracking, gamification, ui 4명 선별 (backend는 이번 요청에 없으므로 제외)
4. Phase 2: TeamCreate 4명, TaskCreate 4개(의존관계 포함)
5. Phase 3: architect가 RunSample/RunRecord/Badge 모델 확정 → 브로드캐스트 → tracking·gamification·ui 병렬 착수 → 각 완료 시 qa-integration-tester incremental 검증
6. Phase 4: 종합 검증, 경계면 문제 없음 확인
7. Phase 5: 팀 정리, 사용자에게 구현 요약 + "다음으로 랭킹/백엔드 연동을 추천합니다" 보고

### 에러 흐름
1. Phase 3에서 gamification이 뱃지 판정 로직 작성 중 architect의 `Badge` 모델에 필드(등급) 누락을 발견
2. gamification이 architect에게 SendMessage로 필드 추가 요청
3. architect가 모델을 확장하고 변경 사실을 전원에게 재브로드캐스트
4. tracking·ui는 이미 진행 중이던 작업에 영향 없음을 확인, gamification만 갱신된 모델로 재작업
5. incremental QA에서 확장된 필드가 실제 DB 스키마에는 아직 반영 안 됐음을 발견(backend가 이번 요청에 없었으므로) → 리포트에 "backend 미포함 — 다음 세션에서 반영 필요"로 명시
6. Phase 5 보고에 이 미해결 항목을 명확히 포함
