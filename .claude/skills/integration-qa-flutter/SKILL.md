---
name: integration-qa-flutter
description: "러닝 앱의 통합 정합성 검증 체크리스트와 방법론. Flutter 모델↔Supabase 스키마, API↔프론트 훅, GPS 이벤트↔뱃지 판정, 라우팅 경계면 검증 절차를 제공. qa-integration-tester 에이전트가 각 모듈 완성 직후 사용."
---

# Flutter 러닝 앱 통합 QA

경계면(모듈 간 연결 지점) 불일치는 각 모듈을 개별 검증해서는 잡히지 않는다. 반드시 양쪽을 동시에 열어 비교한다.

> 📌 **제품 사양은 `docs/PRD.md`가 단일 진실 원천이다.** 이 스킬의 서술과 충돌하면 PRD가 우선한다. 티어(분기 시즌·절대평가)와 주간 랭킹(티어 내·상대평가)의 구분, 크루가 P2라는 점을 반드시 확인하고 작업한다.
>
> 📐 검증 시 `docs/ARCHITECTURE.md`·`docs/TRD.md`와 실제 코드의 일치 여부도 확인 대상에 포함한다 — 특히 TRD §4.1(매핑표), §7(검증 규칙)과 실제 구현의 대조.

## 검증 체크리스트

### 모델 ↔ 스키마
- [ ] Dart freezed 모델의 모든 필드가 Supabase 테이블 컬럼과 1:1 매핑되는가 (`_workspace/*_backend_schema.md`의 매핑 표와 실제 코드 대조)
- [ ] nullable 필드가 Dart(`?`)와 Postgres(`nullable`) 양쪽에서 일치하는가
- [ ] `RunSample`처럼 소스가 여럿인 모델(`source: phone | watch`)이 스키마에서도 동일하게 표현되는가

### API ↔ 프론트
- [ ] Supabase 쿼리/RPC의 실제 반환 shape과 Repository의 파싱 타입이 일치하는가 (래핑된 응답이면 unwrap 로직이 있는가)
- [ ] 즉시 응답(로컬 판정)과 서버 재검증 후 최종값을 프론트가 구분해서 표시하는가 (예: 뱃지 `verified: false` 상태 UI가 별도로 존재하는가)

### GPS 이벤트 ↔ 뱃지 판정
- [ ] 세션 종료 이벤트 발행 코드(`lib/features/tracking/`)와 뱃지 판정 구독 코드(`lib/features/gamification/`)가 실제로 연결되어 있는가 (이벤트명/스트림이 일치하는가)
- [ ] 누적형 뱃지 조건이 세션 종료 시점뿐 아니라 누적 통계 갱신 시점에도 체크되는가
- [ ] 오프라인 큐에 쌓인 뱃지가 온라인 복귀 시 실제로 서버 동기화 함수를 호출하는가

### 라우팅
- [ ] 코드 내 모든 `context.go`/`Navigator.push` 값이 `go_router`에 실제 정의된 라우트와 매칭되는가
- [ ] 동적 세그먼트(`/run/:id`)가 올바른 파라미터로 채워지는가

### 랭킹 정합성
- [ ] 클라이언트가 표시하는 점수/순위가 서버 재검증을 거친 `leaderboard_cache` 값을 사용하는가 (클라이언트 로컬 계산값을 그대로 노출하고 있지 않은가)
- [ ] 동점 처리 규칙(`_workspace/*_badge_rules.md`)이 실제 정렬 쿼리에 반영되어 있는가

## 검증 방법: 양쪽 동시 읽기

| 검증 대상 | 왼쪽 (생산자) | 오른쪽 (소비자) |
|----------|-------------|---------------|
| 모델↔스키마 | `lib/models/*.dart` | Supabase 마이그레이션 SQL |
| API↔프론트 | Supabase 쿼리/RPC 정의 | `lib/core/api/`, Repository |
| 이벤트↔뱃지 | 트래킹 모듈의 이벤트 발행부 | 게이미피케이션 모듈의 구독부 |
| 라우팅 | `go_router` 라우트 정의 | 코드 내 모든 네비게이션 호출 |

## 실행 시점

각 기능 모듈이 완성되는 즉시 해당 모듈의 경계면만 검증한다. 프로젝트 전체가 끝난 뒤 한 번에 몰아서 검증하지 않는다 — 초기 단계의 불일치가 후속 모듈에 전파되면 수정 비용이 커진다.

## 리포트 형식

`_workspace/{date}_qa_report.md`:

```
## [CONFIRMED] RunRecord.avgHeartRate ↔ run_records.avg_heart_rate 타입 불일치
- 파일: lib/models/run_record.dart:23, supabase/migrations/0003_run_records.sql:8
- 문제: Dart는 int?, Postgres는 numeric으로 정의됨
- 수정 제안: Postgres 컬럼을 integer로 통일

## [PASS] GPS 세션 종료 이벤트 → 뱃지 판정 연결 확인
- lib/features/tracking/domain/run_session_notifier.dart:45 에서 onSessionEnd 발행
- lib/features/gamification/domain/badge_evaluator.dart:12 에서 구독 확인
```
