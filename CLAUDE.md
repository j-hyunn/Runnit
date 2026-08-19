## 하네스: Runnit 러닝 앱 개발

**목표:** 러닝 기록/GPS·웨어러블 트래킹/랭킹/뱃지 게이미피케이션을 갖춘 Flutter 러닝 앱(Runnit) 개발을 전문 에이전트 팀으로 조율.

**트리거:** 이 앱의 기능 개발/구현/수정 요청 시 `running-app-builder` 스킬을 사용하라 (GPS 트래킹, 웨어러블 연동, 러닝 기록, 랭킹/리더보드, 뱃지·레벨, Flutter 화면, Supabase 백엔드 등). 단순 질문은 직접 응답 가능.

**변경 이력:**
| 날짜 | 변경 내용 | 대상 | 사유 |
|------|----------|------|------|
| 2026-08-19 | 초기 구성 (에이전트 6개, 스킬 7개, 오케스트레이터 1개) | 전체 | 신규 프로젝트 하네스 구축 |
| 2026-08-19 | 백엔드 Supabase 확정(변경 없음, 기존 기본값 유지), 웨어러블 우선순위를 Apple Watch·Garmin으로 명시 — Garmin은 Garmin Connect→HealthKit/Health Connect 동기화 경유로 설계, references/garmin-integration.md 추가 | agents/gps-tracking-engineer.md, skills/gps-wearable-tracking/ | 사용자가 백엔드/워치 우선순위를 확정 |
