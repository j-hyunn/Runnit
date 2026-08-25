-- =============================================================================
-- Runnit :: 36. 기기 벤더 축 (device_vendor enum + runs.device_vendors 배열)
-- -----------------------------------------------------------------------------
-- 정본: _workspace/20260826_012000_architect_device-vendor-arbitration.md §2
--       docs/TRD.md §3.1.1 · §3.1.2 · §4.0
--
-- mobile-architect 중재 결과: 병렬 워크트리의 두 상충안 중 **배열 안**을 채택하고
-- 스칼라 안(`runs.device_source`, 토큰 7종)은 폐기했다. 이 마이그레이션은 그
-- 결정을 그대로 옮긴 것이며 새로운 설계 판단을 포함하지 않는다.
--
-- ⚠️ enum 라벨이 camelCase인 것은 **의도적**이다. badge_catalog(=public.badges)의
--    condition jsonb 와 device_watchApple_1 같은 뱃지 id(PK)가 이미 이 문자열로
--    시드돼 있고, 별도 매핑 계층을 두면 어긋나는 순간 뱃지가 **조용히 미지급**된다.
--    프로젝트 snake_case 규약의 유일한 예외(TRD §3.1.1 · §4.1).
--
--    4계층이 한 글자도 달라지면 안 된다:
--      badges.condition jsonb  /  public.device_vendor  /  Dart @JsonValue  /  wire_enums.dart
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 36-1. enum + 컬럼
-- -----------------------------------------------------------------------------
create type public.device_vendor as enum (
  'phone', 'watchApple', 'watchGarmin', 'watchOther', 'unknown'
);

comment on type public.device_vendor is
  '기기 벤더 축. runs.sources(run_sample_source[])와 **직교**한다 — 합치지 말 것. '
  'sources = 어떤 경로로 언제 들어왔나(phone/watch/external), device_vendor = 어느 기기가 만들었나. '
  '라벨 camelCase는 뱃지 카탈로그 토큰과의 정합을 위한 의도적 예외(TRD §3.1.1).';

alter table public.runs
  add column device_vendors public.device_vendor[] not null default '{}';

comment on column public.runs.device_vendors is
  '이 세션에 기여한 기기 벤더 집합. {} 는 {phone} 과 다른 뜻(정보 없음/수동 입력/레거시)이고, '
  'unknown 은 "외부 기여는 있었으나 기기 식별 실패". TRD §3.1.1';

-- device_source_count_gte 가 사용자별로 겹침(&&) 필터를 돈다.
create index runs_device_vendors_gin on public.runs using gin (device_vendors);

-- -----------------------------------------------------------------------------
-- 36-2. 백필 — sources 를 근거로만 채운다
-- -----------------------------------------------------------------------------
-- {}(정보 없음)과 {phone}(폰 단독 확정)은 의미가 다르므로 무조건 채우지 않는다.
-- 폐기된 스칼라 안의 `default 'phone'` 전면 백필과는 다른 동작이다(중재 문서 §1.3).
update public.runs
   set device_vendors = '{phone}'::public.device_vendor[]
 where device_vendors = '{}'::public.device_vendor[]
   and sources @> '{phone}'::public.run_sample_source[];

-- -----------------------------------------------------------------------------
-- 36-3. RLS / 쓰기 주체
-- -----------------------------------------------------------------------------
-- RLS: runs 의 기존 정책을 그대로 상속한다. 새 정책 불필요.
-- 쓰기: 클라이언트가 RunRecord.toJson() 으로 함께 올린다(_serverOwnedKeys 아님).
--       trg_runs_guard 는 이 컬럼을 건드리지 않으므로 그대로 통과한다.
--       P1 에서 워크아웃 임포트가 서버 경유로 바뀌면 그때 서버가 재확정한다.

-- -----------------------------------------------------------------------------
-- 36-4. device_both_used 설명문 정정 ("단독" 제거)
-- -----------------------------------------------------------------------------
-- 중재 문서 §3 / TRD §3.1.2. "폰 **단독**" 이라는 문구는 스칼라 모델의 한계를
-- 옮겨 적은 것이지 독립적인 제품 요구가 아니었다. 배열 모델에서는 하이브리드
-- 세션 1건(`{phone, watchApple}`)이 두 원소를 동시에 충족하면 지급된다.
-- id / name / condition / condition_type 은 전부 불변 — 지급된 user_badges 무영향.
-- docs/badge-catalog.csv 는 이미 수정됐고, 적용 완료된 마이그레이션 26 은 고치지 않는다.
update public.badges
   set description = '폰으로 기록한 러닝과 워치로 기록한 러닝을 각각 최소 1회 이상 보유하면 획득 (한 러닝이 둘 다 만족해도 인정)'
 where id = 'device_both_used';
