-- =============================================================================
-- Runnit :: 64. 서버 샘플 기반 거리·이동시간 재계산 (PRD §8.4 / TRD §7 · §14 #27)
-- -----------------------------------------------------------------------------
-- 왜 필요한가
--   PRD §8.4 의 원칙은 "클라이언트 계산 값을 신뢰하지 않고 **서버에서 원본
--   샘플로 재계산**한다" 이지만, 04 의 `validate_run` 은 클라이언트가 올린
--   집계값(`distance_meters` · `moving_seconds`)에 **플래그만** 세웠다.
--   즉 앱을 개조한 클라이언트가 평균 7.0 m/s(= 2'23"/km) 미만이 되도록만
--   맞추면 임의 거리를 티어·랭킹·XP 에 그대로 태울 수 있었다(TRD §14 #27).
--   25km/h 구간 필터는 지금까지 **클라이언트에만** 존재했다(§8.3
--   `GpsFilterConfig.maxPlausibleSpeedMps`) — 즉 공격자가 통째로 우회 가능.
--
-- 무엇을 하는가
--   샘플이 2개 이상 있는 기록에 한해, 인접 샘플 쌍(구간)을 다시 걸어
--   거리·이동시간을 서버가 재계산하고, 클라이언트 값과 크게 어긋나면 그 값을
--   **서버 값으로 확정**한다. 확정 전 원본 주장값은 `runs.client_reported` 에
--   증거로 보존한다(§8.4 "이의 제기 경로 필수 제공").
--
-- 무엇을 하지 않는가 (⚠️ 의도된 스킵)
--   **샘플이 없는 기록은 재계산하지 않는다.** 폰 실내 러닝 · 웨어러블이 넘긴
--   경로 없는 기기 측정 거리가 여기 해당한다. 샘플 기반 재계산을 그대로
--   적용하면 그 거리가 전부 0 으로 깎인다. 이 취급의 최종 결정은 TRD §14 #26 ②
--   (웨어러블 실내 거리의 티어·랭킹 반영 범위)와 함께 내리기로 되어 있으므로,
--   여기서는 **"샘플 있으면 재계산 / 없으면 클라이언트 값 유지"** 분기만
--   명시적으로 세운다. `activity_type = 'indoor_run'` 도 같은 이유로 무조건 스킵.
--
-- 왜 거부(422)가 아니라 플래그인가
--   05 · 51 헤더의 방침을 잇는다. 오프라인 큐(`LocalRunRepository.syncPending`)
--   는 같은 id 재 upsert 로 멱등성을 얻는데, 여기서 예외를 던지면 그 큐가
--   영구히 실패한다(= 지하 주차장에서 끝낸 러닝이 영원히 안 올라간다).
--   TRD §7 표의 "기록 거부(422)"는 그래서 **플래그로 구현**한다(§7 갱신).
--
-- 멱등성: create or replace / add column if not exists / drop if exists 뿐이라
--         재실행 안전. 과거 행 백필은 **하지 않는다**(아래 §64-5 참조).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 64-1. 원본 주장값 보존 컬럼
-- -----------------------------------------------------------------------------
-- 서버가 값을 덮어쓰면 "내 시계는 10km 라는데 앱은 9.2km"라는 문의에 답할 근거가
-- 사라진다. 삭제하지 않고 플래그만 남기는 §8.4 원칙과 같은 이유로, 덮어쓰기
-- **직전의 클라이언트 주장값**을 남긴다. 재계산이 적용된 행에만 채워진다.
alter table public.runs
  add column if not exists client_reported jsonb;

comment on column public.runs.client_reported is
  '서버 재계산 직전의 클라이언트 주장값 {distance_meters, moving_seconds, max_speed_mps}. '
  '재계산이 실제로 값을 바꾼 행에만 채워진다. 이의 제기 대응 근거(PRD §8.4). 서버 전용 컬럼.';

-- -----------------------------------------------------------------------------
-- 64-2. 재계산 결과 복합 타입
-- -----------------------------------------------------------------------------
-- out 파라미터 5개를 record 로 흘리는 것보다 이름 있는 타입이 호출부에서 읽기 쉽다.
do $$
begin
  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'run_recalc_result'
  ) then
    create type public.run_recalc_result as (
      applied           boolean,           -- false = 샘플 부족/실내 → 스킵
      distance_meters   double precision,
      moving_seconds    integer,
      max_speed_mps     double precision,  -- 유효 구간의 최대 구간속도
      segment_count     integer,
      removed_count     integer,           -- 25km/h 초과로 제거된 구간 수
      time_regression   boolean,           -- 타임스탬프 역행/중복 구간 존재
      samples           jsonb              -- cumulative_distance_meters 재기입본
    );
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 64-3. 재계산 본체
-- -----------------------------------------------------------------------------
-- 구간(인접 샘플 쌍) 규칙 — 클라이언트 필터(§8.3 `gps_smoothing.dart`)와 **같은
-- 상수**를 쓴다. 서버가 더 느슨하면 검증이 무의미하고, 더 빡빡하면 정직한
-- 사용자의 거리가 깎인다.
--
--   dt  = t[i] - t[i-1]
--   d   = haversine(좌표) — 좌표가 없으면 cumulative_distance_meters 차분으로 대체
--         (워치 임포트처럼 좌표 없이 거리만 오는 샘플을 위한 폴백)
--   v   = d / dt
--
--   dt <= 0            → 구간 제거 + time_regression = true (역행/중복 타임스탬프)
--   v  > 6.944 m/s     → 구간 제거 (= 25km/h, PRD §8.4 "해당 구간 제거 후 재계산")
--   v  < 0.6 m/s       → 거리·시간에 **미산입** (정지/노이즈. minMovingSpeedMps)
--   그 외              → distance += d, moving += min(dt, 20)
--
-- min(dt, 20) 의 20 은 `GpsFilterConfig.signalGapSeconds`. 신호 유실 구간을
-- 통째로 이동시간에 넣지 않기 위한 상한으로, 클라이언트와 같은 값이다.
--
-- ⚠️ 좌표는 클라이언트가 **스무딩을 마친 뒤** 올린 값이다(SmoothedFix). 서버가
--    다시 스무딩하지는 않으므로 재계산값은 클라이언트 값과 정확히 같지 않고,
--    보통 소수 % 안쪽에서 흔들린다. 그래서 64-4 에서 **허용 밴드** 안이면
--    클라이언트 값을 그대로 둔다 — 정직한 기록의 표시값을 흔들지 않기 위해서다.
create or replace function public.recalc_run_from_samples(
  p_samples       jsonb,
  p_activity_type public.activity_type
)
returns public.run_recalc_result
language plpgsql
-- immutable 이 아니라 stable: 본문이 text -> timestamptz 캐스트를 하고, 그 결과는
-- DateStyle/TimeZone 설정에 의존한다(같은 인자라도 세션 설정이 다르면 달라질 수 있다).
-- 실사용 경로에서는 샘플이 ISO-8601 UTC 문자열이라 차이가 나지 않지만, immutable 로
-- 선언하면 플래너가 인덱스식 등에서 사전 계산해도 된다고 믿게 되므로 정확한 쪽을 쓴다.
stable
set search_path = public, pg_temp
as $$
declare
  r public.run_recalc_result;
begin
  r.applied         := false;
  r.distance_meters := null;
  r.moving_seconds  := null;
  r.max_speed_mps   := null;
  r.segment_count   := 0;
  r.removed_count   := 0;
  r.time_regression := false;
  r.samples         := null;

  -- 스킵 분기 ①: 실내 러닝. 경로가 없는 기기 측정 거리를 0 으로 깎지 않는다(#26 ②).
  if p_activity_type = 'indoor_run'::public.activity_type then
    return r;
  end if;

  -- 스킵 분기 ②: 샘플이 2개 미만이면 구간 자체가 없다 = 수동/기기 측정 기록.
  --
  -- ⚠️ `a is null or jsonb_typeof(a) <> 'array' or jsonb_array_length(a) < 2` 로 쓰면
  --    안 된다. Postgres 는 OR 피연산자의 **평가 순서를 보장하지 않으므로**
  --    `jsonb_array_length` 가 스칼라 jsonb 에 대해 먼저 평가돼 에러를 던질 수 있다
  --    (단락 평가는 최적화이지 계약이 아니다). CASE 는 순차 평가가 문법으로 보장된다.
  --
  -- ⚠️ 원소 타입까지 본다. `[1, 2]` 처럼 **객체가 아닌 원소**로 채운 배열은 길이
  --    검사만으로는 통과하는데, 아래 `jsonb_set(elem, ...)` 이 스칼라에 대해
  --    `cannot set path in scalar` 로 **예외를 던진다**. BEFORE 트리거에서 예외가
  --    나면 이 파일 헤더의 원칙("거부하지 않는다 — 오프라인 큐가 영구 실패한다")이
  --    바로 그 경로에서 깨진다. 객체 원소가 2개 미만이면 재계산 자체를 스킵한다.
  --    (객체 1개 + 쓰레기 조합으로 재계산을 우회할 수는 있지만, 그것은 애초에
  --     "샘플 1개짜리 업로드"와 같은 취급이라 새로운 우회로가 아니다.)
  if (case
        when p_samples is null                     then true
        when jsonb_typeof(p_samples) <> 'array'    then true
        when jsonb_array_length(p_samples) < 2     then true
        when (select count(*)
                from jsonb_array_elements(p_samples) as e(elem)
               where jsonb_typeof(e.elem) = 'object') < 2 then true
        else false
      end)
  then
    return r;
  end if;

  -- 집합 연산 한 번으로 끝낸다. 루프 + jsonb 이어붙이기로 쓰면 3,600 샘플에서
  -- 배열 복사가 O(n²)로 터진다(BEFORE 트리거 안이라 업로드 지연에 그대로 얹힌다).
  with pts as (
      select ord,
             (elem ->> 'timestamp')::timestamptz                       as t,
             (elem ->> 'latitude')::double precision                   as lat,
             (elem ->> 'longitude')::double precision                  as lon,
             (elem ->> 'cumulative_distance_meters')::double precision as cum,
             elem
      from jsonb_array_elements(p_samples) with ordinality as e(elem, ord)
      -- 객체가 아닌 원소는 여기서 떨궈 jsonb_set 예외를 원천 차단한다. 실데이터가
      -- 아니라 손상/조작된 항목이므로 재기입본에서 빠져도 잃는 정보가 없다.
      where jsonb_typeof(e.elem) = 'object'
    ),
    seq as (
      select ord, t, lat, lon, cum, elem,
             lag(t)   over (order by ord) as pt,
             lag(lat) over (order by ord) as plat,
             lag(lon) over (order by ord) as plon,
             lag(cum) over (order by ord) as pcum
      from pts
    ),
    seg as (
      select
        ord,
        elem,
        -- 첫 샘플은 앞 구간이 없다 → dt null.
        case when pt is null then null
             else extract(epoch from (t - pt))::double precision end as dt,
        case
          when pt is null then null
          when lat is not null and lon is not null
           and plat is not null and plon is not null
            then public._haversine_meters(plat, plon, lat, lon)
          -- 좌표 없는 샘플(워치 임포트)의 폴백. 음수 차분은 0 으로 클램프.
          when cum is not null and pcum is not null
            then greatest(cum - pcum, 0)
          else null
        end as seg_m
      from seq
    ),
    cls as (
      select
        ord, elem, dt, seg_m,
        case when dt > 0 and seg_m is not null then seg_m / dt end as v,
        (dt is not null and dt <= 0)                            as regression
      from seg
    ),
    flag as (
      select *,
        (v is not null and v > 6.944)                as removed,   -- 25km/h 초과
        (v is not null and v >= 0.6 and v <= 6.944)  as counted    -- 유효 이동 구간
      from cls
    ),
    acc as (
      select *,
        sum(case when counted then seg_m else 0 end)
          over (order by ord rows between unbounded preceding and current row) as cum_m
      from flag
    )
    select
      true,
      coalesce(max(cum_m), 0),
      coalesce(round(sum(case when counted then least(dt, 20) else 0 end)), 0),
      max(case when counted then v end),
      (count(*) filter (where dt is not null)),
      (count(*) filter (where removed or regression)),
      coalesce(bool_or(regression), false),
      jsonb_agg(
        jsonb_set(elem, '{cumulative_distance_meters}', to_jsonb(cum_m))
        order by ord
      )
  into
    r.applied, r.distance_meters, r.moving_seconds, r.max_speed_mps,
    r.segment_count, r.removed_count, r.time_regression, r.samples
  from acc;

  return r;
end;
$$;

comment on function public.recalc_run_from_samples(jsonb, public.activity_type) is
  'RunSample 배열에서 거리·이동시간을 서버가 재계산한다(PRD §8.4). '
  '인접 구간 속도 25km/h 초과 구간 제거, 0.6 m/s 미만 구간 미산입, '
  '구간 시간은 20초 상한. 샘플 2개 미만 또는 indoor_run 은 applied=false 로 스킵.';

-- ⚠️ `authenticated` 는 회수하지 **않는다.** `trg_runs_guard()` 는 security definer 가
-- 아니라 호출자(= 업로드하는 사용자) 권한으로 실행되므로, authenticated 에서 실행
-- 권한을 뺏으면 트리거 안의 이 호출이 42501 로 죽고 **러닝 업로드가 전면 실패**한다.
-- 마이그레이션 39 의 `compute_run_xp` 도 같은 이유로 `from public, anon` 까지만 회수했다.
-- (순수 함수라 직접 호출돼도 남의 데이터를 읽지 않는다 — 인자로 준 jsonb 만 본다.)
revoke execute on function public.recalc_run_from_samples(jsonb, public.activity_type)
  from public, anon;

-- -----------------------------------------------------------------------------
-- 64-4. runs 가드 — 재계산을 파생값 확정 앞에 끼워 넣는다
-- -----------------------------------------------------------------------------
-- 51-2 판본과 동일하되, "파생값 정규화" **직전**에 재계산 블록을 넣는다.
-- 순서가 계약이다: 재계산 → 페이스 → validate_run → XP.
-- 그래야 페이스·플래그·XP 가 전부 **서버가 확정한 거리**를 근거로 산정된다.
--
-- 덮어쓰기와 플래그는 **분리된 결정**이다 (2026-09-03 사용자 확정, QA F-3/F-7/F-8).
--
--   ① 덮어쓰기는 **항상** — 재계산이 유효하면(applied) 서버 값이 곧 확정값이다.
--      허용 밴드 개념은 폐기했다. PRD §8.4 "구간 제거 후 재계산"은 *수용 조치*이지
--      *예외 조치*가 아니므로, 밴드를 두면 그만큼이 그대로 우회 여지가 된다.
--      이 값이 티어·주간랭킹·XP·뱃지의 근거가 된다.
--
--   ② 플래그는 **훨씬 큰 임계에서만** — 서버 값이 클라 주장의 80% 미만
--      (= 20% 초과 축소)일 때만 `distance_mismatch`. 그 이하 축소는 조용히
--      덮어쓰기만 한다. 정직한 기록에서도 스무딩 차이·신호등 정지(앵커 변위를
--      서버가 세지 못함, QA F-7)로 서버 값이 체계적으로 조금 짧게 나오는데,
--      그것을 부정으로 낙인찍으면 안 되기 때문. 임계는 아래 v_flag_shrink_ratio
--      한 곳에만 있으므로 실데이터를 보고 조정한다(산출물 §6 진단 쿼리).
--
--   ③ 늘리는 방향은 **채택하지 않는다** (QA F-8). 서버 재계산이 클라 주장보다
--      크게 나와도 클라 값을 유지한다 = least(recalc, claimed). 사용자가 주장한
--      적 없는 거리를 서버가 만들어 랭킹에 실을 이유가 없다. 플래그도 하지 않는다.
create or replace function public.trg_runs_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_reason  text;
  v_title   text;
  v_note    text;
  v_recalc  public.run_recalc_result;
  -- v_recalc 는 서버 쓰기 경로에서 아예 대입되지 않을 수 있다. 미대입 복합 변수의
  -- 필드를 읽는 대신 별도 불리언으로 "재계산이 돌았는가"를 들고 다닌다.
  v_applied boolean := false;
  v_claimed double precision;
  v_shrunk  boolean := false;
  -- `distance_mismatch` 를 세우는 축소 임계. 서버값 < 클라값 × 이 비율이면 플래그.
  -- 0.8 = 20% 초과 축소. 보수적으로 크게 잡은 값이며(QA F-3 결정), 실데이터
  -- 편차 분포를 본 뒤 조정한다 — 바꿀 곳은 여기 한 줄뿐이다.
  v_flag_shrink_ratio constant double precision := 0.8;
  -- HI-07 되돌리기가 걸린 UPDATE 인가 = 플래그를 재판정하지 말고 보존해야 하는가.
  v_keep_flag boolean := false;
  -- 재계산이 **다시 돌지 않은** UPDATE 에서 승계해야 하는 재계산발 사유.
  v_inherited text;
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    -- 서버 전용 컬럼. 클라이언트가 위조한 "원본 주장값"을 그대로 남기지 않는다.
    -- (UPDATE 경로는 아래 HI-07 되돌리기가 old 값을 복원하므로 별도 처리 불필요.)
    if not public.is_server_write() then
      new.client_reported := null;
    end if;
  else
    new.id         := old.id;          -- PK 변조 차단
    new.user_id    := old.user_id;     -- 소유권 이전 차단
    new.created_at := old.created_at;

    -- HI-07. 이미 확정된(터미널) 러닝은 title/note 외 어떤 컬럼도 바뀌지 않는다.
    -- (51-2 와 동일 — 근거는 그 파일 주석 참조. 체크포인트 업로드를 도입할 때
    --  진행 중 행에도 잠금을 걸어야 한다는 경고도 그대로 유효하다.)
    if not public.is_server_write()
       and old.status in ('completed'::public.run_status,
                          'discarded'::public.run_status)
    then
      v_title := new.title;
      v_note  := new.note;
      new       := old;
      new.title := v_title;
      new.note  := v_note;

      -- 🛑 플래그 세탁 차단. 이 분기를 지난 뒤에는 원본이 old 로 복원되므로
      --    재계산 차이가 0 이 되어 밴드 안으로 들어온다. 그대로 두면 아래
      --    `new.is_flagged := (v_reason is not null)` 가 **최초 판정에서 세운
      --    `distance_mismatch` 를 지워 버린다** — 제목 한 줄 고치거나 오프라인
      --    큐가 같은 행을 재 upsert 하는 것만으로 부정 기록이 정상으로 바뀌고,
      --    compute_run_xp 가 만점 XP 를 다시 매겨 AFTER 트리거가 티어·랭킹·뱃지에
      --    편입시킨다. 재계산발 사유는 상태(old)에서 재현되지 않으므로 반드시
      --    명시적으로 보존해야 한다.
      --
      --    validate_run 기반 사유는 old 값에서 결정적으로 재현되므로 보존해도
      --    결과가 같다. 64 이전에 들어온 legacy 행이 이 경로로 처음 재계산되며
      --    새로 플래그되는 일도 함께 막히는데, 그것은 "과거 행 백필 안 함"(64-5)
      --    정책과 일치한다.
      v_keep_flag := true;
    end if;
  end if;
  new.updated_at := now();

  new.title := nullif(left(btrim(new.title), 60), '');
  new.note  := nullif(left(btrim(new.note), 500), '');

  -- ── 서버 재계산 (PRD §8.4, TRD §14 #27) ────────────────────────────────
  -- 서버 쓰기 경로(재집계·백필)는 건너뛴다. 그 경로는 이미 확정된 값을 다루며,
  -- 여기서 다시 재계산하면 백필 한 번에 전 사용자 거리가 흔들린다.
  if not public.is_server_write() then
    v_recalc  := public.recalc_run_from_samples(new.samples, new.activity_type);
    v_applied := coalesce(v_recalc.applied, false);

    if v_applied then
      v_claimed := coalesce(new.distance_meters, 0);

      -- ③ 늘리는 방향은 채택하지 않는다(F-8). 그래서 조건이 `<=` 다:
      --    재계산값이 주장값 이하일 때만 확정으로 삼는다 = least(recalc, claimed).
      --
      --    클램프될 때(재계산 > 주장) 거리·이동시간·샘플을 **하나도 건드리지
      --    않는** 이유: 거리만 클라 값으로 두고 샘플 누적거리는 서버 값으로
      --    재기입하면 `distance_meters` 와 `max(cumulative_distance_meters)` 가
      --    어긋나 스플릿·PB 가 확정 거리와 다른 근거로 산출된다. 채택하지 않기로
      --    한 이상 그 기록은 클라이언트 값 한 벌로 일관되게 남는 것이 옳다.
      if v_recalc.distance_meters <= v_claimed then
        -- 원본 주장값 보존(증거) — **최초 확정 때만** 쓴다.
        -- 재 upsert 는 F-4 이후 이미 서버 확정 거리를 실어 오므로, 매번 덮어쓰면
        -- "원래 얼마를 주장했는가"가 서버 값으로 세탁된다. UPDATE 되돌리기 분기가
        -- old.client_reported 를 복원해 주므로 null 검사만으로 충분하다.
        if new.client_reported is null
           and abs(v_recalc.distance_meters - v_claimed) >= 1.0 then
          new.client_reported := jsonb_build_object(
            'distance_meters', new.distance_meters,
            'moving_seconds',  new.moving_seconds,
            'max_speed_mps',   new.max_speed_mps,
            'recalculated_at', now()
          );
        end if;

        -- ② 플래그는 훨씬 큰 임계에서만. 그 이하 축소는 조용히 덮어쓰기만 한다.
        v_shrunk := v_recalc.distance_meters < v_claimed * v_flag_shrink_ratio;

        -- ① 덮어쓰기는 항상(밴드 없음).
        new.distance_meters := v_recalc.distance_meters;
        -- 이동시간은 거리를 덮어쓸 때만 함께 덮어쓴다. 거리를 그대로 두면서
        -- 시간만 바꾸면 페이스가 근거 없이 흔들린다(두 값은 한 쌍이다).
        --
        -- `elapsed_seconds` 상한은 **그 값이 유효할 때만** 건다. 0/null 인 기록
        -- (외부 임포트에서 경과시간이 안 온 경우)에 그대로 least 를 걸면
        -- moving_seconds 가 0 이 되고, 바로 아래 validate_run 이 거리는 있는데
        -- 이동시간이 0 이라며 `zero_moving_time` 을 **오발**한다.
        new.moving_seconds := greatest(v_recalc.moving_seconds, 0);
        if coalesce(new.elapsed_seconds, 0) > 0 then
          new.moving_seconds := least(new.moving_seconds, new.elapsed_seconds);
        end if;
        new.max_speed_mps   := coalesce(v_recalc.max_speed_mps, new.max_speed_mps);
        -- 샘플의 누적거리도 서버 기준으로 재기입한다. km 스플릿 · PB 시각 ·
        -- 네거티브 스플릿은 전부 `cumulative_distance_meters` 를 읽으므로
        -- (41-0-a `_run_time_at_distance`), 여기서 맞춰 두지 않으면 확정 거리와
        -- 스플릿이 서로 다른 근거로 산출된다.
        new.samples := coalesce(v_recalc.samples, new.samples);
      end if;
    end if;
  end if;

  -- 파생값 정규화: 페이스는 항상 moving_seconds 를 분모로 서버가 재계산한다.
  if new.distance_meters > 0 and new.moving_seconds > 0 then
    new.avg_pace_sec_per_km := new.moving_seconds / (new.distance_meters / 1000.0);
  else
    new.avg_pace_sec_per_km := null;
  end if;

  -- 서버 재검증. 물리적 불가능(04 규칙)을 먼저 보고, 없으면 샘플 근거 사유를 본다.
  v_reason := public.validate_run(
    new.distance_meters, new.elapsed_seconds, new.moving_seconds,
    new.max_speed_mps, new.elevation_gain_meters
  );

  if v_reason is null and v_applied then
    v_reason := case
      when v_recalc.time_regression then 'sample_time_regression'
      when v_shrunk                 then 'distance_mismatch'
      else null
    end;
  end if;

  -- 🛑 플래그 세탁 차단 ②: **서버 쓰기 경로** (QA G-1, F-2 의 나머지 절반).
  --    위 재계산 블록은 `is_server_write()` 일 때 통째로 건너뛰므로 v_applied 가
  --    false 이고, v_keep_flag 는 클라이언트 되돌리기 분기에서만 세워진다. 그래서
  --    서버측 UPDATE 한 번이면 재판정이 일어나는데, `distance_mismatch` 와
  --    `sample_time_regression` 은 validate_run 이 **만들 수 없는 사유**라 조용히
  --    사라지고 compute_run_xp 가 만점 XP 를 다시 매긴다. 51-1 이 이미
  --    `set_config('runnit.server_write','on') + update runs` 패턴을 쓰므로,
  --    다음 백필/재집계 마이그레이션이 그대로 밟는다.
  --
  --    규칙: **재계산이 실제로 다시 돈 경우에만 재계산발 플래그를 재판정한다.**
  --    안 돌았으면 old 의 사유를 승계한다. validate_run 사유가 새로 잡히면 그쪽이
  --    우선이므로(위에서 이미 대입됨) coalesce 순서가 곧 우선순위다.
  if tg_op = 'UPDATE' and not v_applied
     and old.flag_reason in ('distance_mismatch', 'sample_time_regression')
  then
    v_inherited := old.flag_reason;
  end if;
  v_reason := coalesce(v_reason, v_inherited);

  if v_keep_flag then
    -- 되돌리기 UPDATE: 최초 판정을 그대로 승계한다(위 v_keep_flag 주석 참조).
    new.is_flagged  := old.is_flagged;
    new.flag_reason := old.flag_reason;
  else
    new.is_flagged  := (v_reason is not null);
    new.flag_reason := v_reason;
  end if;

  -- XP 는 클라이언트 입력을 무시하고 항상 서버가 산정한다.
  new.awarded_xp := public.compute_run_xp(
    new.status, new.is_flagged, new.distance_meters,
    new.moving_seconds, new.elevation_gain_meters, new.activity_type
  );

  return new;
end;
$$;

comment on function public.trg_runs_guard() is
  'runs 서버 가드. INSERT: 원본 수용 + **샘플 기반 거리·이동시간 재계산**(PRD §8.4) + '
  '파생값 서버 확정. UPDATE(터미널 상태 + 클라이언트 경로): title/note 를 제외한 전 컬럼을 '
  'old 값으로 되돌린다(PRD HI-07) — 이때 is_flagged/flag_reason 은 재판정하지 않고 '
  '승계한다(플래그 세탁 차단). 샘플이 없거나 indoor_run 이면 재계산을 스킵하고 '
  '클라이언트 값을 유지한다(TRD §14 #26 ② 와 함께 최종 결정).';

revoke execute on function public.trg_runs_guard() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 64-5. 과거 행 백필은 하지 않는다
-- -----------------------------------------------------------------------------
-- 51 헤더와 같은 이유다: runs 의 AFTER 트리거 4종에는 WHEN 절이 없어, 대량
-- UPDATE 한 번이 전 사용자의 티어 재계산 · 챌린지 진척 · 미획득 뱃지 전량
-- 재평가 · 알림 인큐를 돌린다. 게다가 재계산으로 거리가 줄면 **이미 지급된
-- 뱃지·티어의 근거가 사라지는데, 시즌 중 강등은 금지**다(PRD TI-08).
-- 따라서 이 마이그레이션은 **앞으로 올라올 기록**에만 적용된다.
-- 과거 행 점검이 필요하면 아래를 읽기 전용으로 돌려 규모부터 확인할 것:
--
--   select r.id, r.distance_meters as claimed,
--          (public.recalc_run_from_samples(r.samples, r.activity_type)).distance_meters as server
--     from public.runs r
--    where r.status = 'completed' and jsonb_array_length(r.samples) >= 2
--    limit 200;
