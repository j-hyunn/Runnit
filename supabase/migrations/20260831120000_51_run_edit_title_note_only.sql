-- =============================================================================
-- Runnit :: 51. HI-07 — 저장된 러닝은 제목·메모만 수정 가능 (PRD v1.6 §8.1)
-- -----------------------------------------------------------------------------
-- 확정 사양(PRD §5.2 HI-07 / §8.1 / §10.1 #10):
--   · 사용자는 러닝 기록을 **삭제할 수 없다**. 저장 후 취소도 없다.
--   · 저장된 러닝에 대해 사용자가 바꿀 수 있는 것은 **title / note 두 컬럼뿐**이다.
--   · 무효화의 유일한 경로는 서버의 부정 판정(`is_flagged`)이며 행은 보존한다.
--
-- 왜 05/39 의 runs_guard 만으로는 부족했나:
--   기존 가드는 UPDATE 시 id / user_id / created_at 만 고정하고, 파생값(페이스·XP·
--   is_flagged)을 재계산했다. 그 결과 `distance_meters` · `moving_seconds` ·
--   `samples` · `started_at` · `status` · `activity_type` 같은 **원본 입력**은
--   클라이언트 UPDATE 로 얼마든지 바뀔 수 있었다. 파생값이 다시 계산되므로
--   "정합성"은 유지되지만, 그것은 **조작된 원본에 대한 정합성**이다 —
--   3km 러닝을 저장한 뒤 42km 로 UPDATE 하면 티어·랭킹·뱃지가 전부 따라 올라간다.
--
-- 왜 EXCEPTION 이 아니라 "old 값으로 되돌리기(무시)" 인가:
--   05 헤더의 방침을 그대로 잇는다. 오프라인 동기화(`LocalRunRepository.syncPending`)
--   는 **같은 id 로 행 전체를 재 upsert** 하는 것을 멱등성의 근거로 삼는다
--   (07_rls.sql `runs_update_own` 주석). 여기서 예외를 던지면 재시도 큐가
--   영구히 실패한다. 값이 같은 재 upsert 는 되돌려도 결과가 동일하므로 무해하고,
--   실제 편집 시도만 조용히 무시된다.
--
-- 왜 컬럼을 하나씩 나열하지 않고 `new := old` 인가:
--   `runs` 는 지금까지 device_vendors(36) · awarded_xp(39) 처럼 계속 컬럼이 늘었다.
--   화이트리스트(= title/note 만 통과)를 열거형이 아니라 **구조적으로** 표현해야
--   앞으로 추가되는 컬럼이 자동으로 보호된다. 블랙리스트를 열거하면 컬럼을 추가한
--   사람이 이 파일을 고치는 것을 잊는 순간 구멍이 생긴다.
--   행 통째 대입이라 enum 배열 · jsonb · timestamptz 가 json 을 경유하지 않고
--   원본 타입 그대로 복사된다(왕복 변환 손실 없음).
--
-- 멱등성: 전부 create or replace / drop if exists / 조건부 DDL 이라 재실행 안전.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 51-1. title / note 길이 상한
-- -----------------------------------------------------------------------------
-- TRD 에 기존 근거값이 없어 이번에 확정한다(TRD §4.4 에 기록).
--   title 60자  — 한 줄 제목. 목록 카드/공유 카드에서 줄바꿈 없이 읽히는 상한.
--   note  500자 — 짧은 회고 메모. TOAST 임계(약 2KB)에 한참 못 미쳐 저장 비용 무시 가능.
-- CHECK 는 **백스톱**이다. 정상 경로에서는 51-2 의 가드가 먼저 trim + 절단하므로
-- 클라이언트가 이 제약 위반으로 400 을 받는 일은 없다(오프라인 큐가 영구 실패하는
-- 사고를 막기 위해 의도적으로 "거부"가 아니라 "절단"을 택했다).
alter table public.runs drop constraint if exists runs_title_len;
alter table public.runs drop constraint if exists runs_note_len;

-- 제약을 붙이기 전에 기존 초과분을 절단한다(과거 데이터는 상한 없이 들어왔다).
--
-- ⚠️ `set_config('runnit.server_write','on', true)` 로 감싸는 이유 (QA C-5):
--   runs 의 AFTER 트리거 4종(`runs_01_recompute_stats` / `_02_challenge_progress` /
--   `_03_evaluate_badges` / `_04_notifications`)에는 **`WHEN` 절이 없다.** 서버 쓰기
--   플래그 없이 이 UPDATE 를 돌리면 매칭되는 행마다 티어 재계산 + 챌린지 진척 재계산 +
--   미획득 뱃지 전량 재평가 + 알림 인큐가 돈다. 중복 푸시 자체는
--   `notifications`의 `unique (user_id, dedupe_key)` + `on conflict do nothing`이
--   막지만(= 알림 폭탄은 없다), 마이그레이션이 임의 사용자의 집계를 대량
--   재계산하는 것은 의도가 아니고 뱃지 오귀속(`source_run_id`가 오래된 러닝) 위험도 있다.
--   세 번째 인자 `true` = 트랜잭션 로컬이라 이 마이그레이션 종료 시 자동으로 풀린다.
--
-- 📋 적용 전 대상 행 수를 먼저 확인할 것 — **0이면 아래 UPDATE 는 no-op** 이고
--   트리거도 전혀 돌지 않는다(현재 title/note 를 입력할 UI 경로가 없어 0일 가능성이 높다):
--
--     select count(*) from public.runs
--      where (title is not null and char_length(title) > 60)
--         or (note  is not null and char_length(note)  > 500);
--
--   0이 아니면 어떤 사용자의 집계가 재계산되는지 인지한 상태로 적용한다.
do $$
begin
  perform set_config('runnit.server_write', 'on', true);

  update public.runs
     set title = left(title, 60)
   where title is not null and char_length(title) > 60;

  update public.runs
     set note = left(note, 500)
   where note is not null and char_length(note) > 500;

  perform set_config('runnit.server_write', 'off', true);
end;
$$;

alter table public.runs
  add constraint runs_title_len check (title is null or char_length(title) <= 60);
alter table public.runs
  add constraint runs_note_len  check (note  is null or char_length(note)  <= 500);

comment on column public.runs.title is
  '사용자 지정 제목(최대 60자). 저장된 러닝에서 note 와 함께 유일하게 수정 가능한 컬럼 (PRD HI-07).';
comment on column public.runs.note is
  '사용자 메모(최대 500자). 저장된 러닝에서 title 과 함께 유일하게 수정 가능한 컬럼 (PRD HI-07).';

-- -----------------------------------------------------------------------------
-- 51-2. trg_runs_guard — 터미널 상태 러닝의 사후 편집을 title/note 로 한정
-- -----------------------------------------------------------------------------
-- 39-6 판본과 동일하되 UPDATE 분기에 화이트리스트 되돌리기 + title/note 정규화를
-- 추가한다(파생값 정규화 · validate_run · compute_run_xp 는 그대로).
--
-- 되돌리기를 **파생값 재계산보다 먼저** 수행하는 것이 중요하다. 그래야 페이스 ·
-- validate_run · XP 가 전부 old 의 원본값을 근거로 계산되어, 최초 업로드 때와
-- 완전히 같은 결과로 수렴한다(= 편집 UPDATE 는 파생값을 흔들지 않는다).
create or replace function public.trg_runs_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_reason text;
  v_title  text;
  v_note   text;
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
  else
    new.id         := old.id;          -- PK 변조 차단
    new.user_id    := old.user_id;     -- 소유권 이전 차단
    new.created_at := old.created_at;

    -- HI-07. 이미 확정된(터미널) 러닝은 title/note 외 어떤 컬럼도 바뀌지 않는다.
    -- 서버 경로(is_server_write)는 예외 — 부정 판정 · 재집계 · 백필이 지나간다.
    -- 진행 중(recording/paused) 행은 제외한다: 현재 클라이언트는 완료 기록만
    -- 업로드하지만(`LocalRunRepository.save`), 향후 체크포인트 업로드가 생기면
    -- 그 경로는 정상적으로 원본을 갱신해야 한다.
    --
    -- 🛑 체크포인트 업로드를 도입하는 사람에게 (QA L-3):
    --    이 예외는 지금 **도달 불가**라서 안전한 것이지, 그 자체로 안전한 것이
    --    아니다. `recording` 상태로 INSERT 하는 경로가 생기는 순간
    --    "recording 으로 INSERT → 자유 UPDATE 로 거리·샘플 조작 → completed 로
    --    확정" 이라는 우회로가 열린다(파생값은 조작된 원본 기준으로 재계산되므로
    --    정합성 검사에 걸리지 않는다 — 이 마이그레이션이 막으려던 바로 그 구멍이다).
    --    체크포인트 업로드를 붙일 때 이 파일도 함께 고칠 것: 예컨대 진행 중 행에도
    --    "거리·시간은 단조 증가만 허용" 같은 잠금을 걸거나, 확정 전환을 전용
    --    SECURITY DEFINER RPC 로 좁혀야 한다.
    if not public.is_server_write()
       and old.status in ('completed'::public.run_status,
                          'discarded'::public.run_status)
    then
      v_title := new.title;
      v_note  := new.note;
      new       := old;          -- 화이트리스트: old 전체를 되돌린 뒤
      new.title := v_title;      -- 허용된 두 컬럼만 다시 얹는다
      new.note  := v_note;
    end if;
  end if;
  new.updated_at := now();

  -- title/note 정규화: 앞뒤 공백 제거 → 상한 절단 → 빈 문자열은 NULL.
  -- (절단 전에 trim 해야 "60자 + 공백"이 공백만 남기고 잘리는 일이 없다.)
  new.title := nullif(left(btrim(new.title), 60), '');
  new.note  := nullif(left(btrim(new.note), 500), '');

  -- 파생값 정규화: 페이스는 항상 moving_seconds 를 분모로 서버가 재계산한다.
  if new.distance_meters > 0 and new.moving_seconds > 0 then
    new.avg_pace_sec_per_km := new.moving_seconds / (new.distance_meters / 1000.0);
  else
    new.avg_pace_sec_per_km := null;
  end if;

  -- 서버 재검증
  v_reason := public.validate_run(
    new.distance_meters, new.elapsed_seconds, new.moving_seconds,
    new.max_speed_mps, new.elevation_gain_meters
  );
  new.is_flagged  := (v_reason is not null);
  new.flag_reason := v_reason;

  -- XP 는 클라이언트 입력을 무시하고 항상 서버가 산정한다.
  new.awarded_xp := public.compute_run_xp(
    new.status, new.is_flagged, new.distance_meters,
    new.moving_seconds, new.elevation_gain_meters, new.activity_type
  );

  return new;
end;
$$;

comment on function public.trg_runs_guard() is
  'runs 서버 가드. INSERT: 원본 수용 + 파생값 서버 확정. '
  'UPDATE(터미널 상태 + 클라이언트 경로): title/note 를 제외한 전 컬럼을 old 값으로 '
  '되돌린다(PRD HI-07 — 저장된 러닝은 제목·메모만 수정 가능). '
  '같은 값 재 upsert(오프라인 멱등 동기화)는 되돌려도 결과가 같아 무해하다.';

-- 14 번에서 revoke 한 실행 권한은 create or replace 로 유지되지 않을 수 있으므로
-- 다시 회수한다(트리거 함수는 트리거를 통해서만 실행돼야 한다).
revoke execute on function public.trg_runs_guard() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 51-3. runs DELETE 경로 차단 (PRD v1.6 §8.1 — 사용자는 러닝을 삭제할 수 없다)
-- -----------------------------------------------------------------------------
-- 07_rls.sql 의 `runs_delete_own` 은 PRD v1.5 이전(HI-07 = "수정/삭제") 사양의
-- 잔재다. v1.6 에서 사용자 삭제가 스펙에서 제거됐으므로 정책을 내린다.
--
-- 클라이언트 영향 없음(확인 완료): `LocalRunRepository.delete()` 호출부는
-- `TrackingController.discard()` 와 미완결 세션 "버리기" 두 곳뿐이고, 둘 다
-- **아직 업로드된 적 없는 recording/paused 체크포인트**를 대상으로 한다
-- (`save()` 가 완료 기록만 서버로 보낸다). 따라서 서버 DELETE 는 원래도 0행이었다.
--
-- ⚠️ 테이블 GRANT(`revoke delete ... from authenticated`)는 **일부러 건드리지
-- 않는다.** GRANT 를 회수하면 PostgREST 가 42501 을 던지고 `guardSupabase` 가
-- 그것을 `Failure.unauthorized` 로 올려 위 두 곳의 "버리기" 흐름이 실패한다.
-- 정책만 내리면 RLS 술어에 매칭되는 행이 없어 **에러 없이 0행**으로 끝난다 —
-- 보안 효과는 같고 기존 흐름은 그대로다.
--
-- service_role 은 RLS 를 우회하므로 운영/GDPR 삭제(AC-04 계정 삭제)는 영향 없다.
drop policy if exists runs_delete_own on public.runs;

-- -----------------------------------------------------------------------------
-- 51-4. RLS 는 그대로 둔다 — 근거
-- -----------------------------------------------------------------------------
-- `runs_update_own`(07)은 유지한다. 컬럼 단위 화이트리스트는 RLS 로 표현할 수 없고
-- (RLS 는 행 단위 술어다), 컬럼 GRANT 로 UPDATE 를 title/note 로 제한하면
-- 오프라인 재 upsert 가 "권한 없는 컬럼 포함"으로 통째로 거부된다 — 즉 멱등
-- 동기화 경로가 깨진다. 그래서 강제 지점은 51-2 의 BEFORE 트리거 하나로 모은다.
-- RLS 의 역할은 "남의 행에 손대지 못하게" 하는 것이고 그 역할은 이미 충분하다.
