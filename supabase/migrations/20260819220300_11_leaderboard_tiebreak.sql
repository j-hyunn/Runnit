-- =============================================================================
-- Runnit :: 11. 리더보드 동점 처리 확정 반영
-- -----------------------------------------------------------------------------
-- 근거: _workspace/20260819_210450_badge_rules.md §5
--
--   metric      | score                 | tie_break_value (작을수록 상위)
--   ------------+-----------------------+--------------------------------------
--   distance    | sum(distance_meters)  | sum(moving_seconds)        [현행 유지]
--   duration    | sum(moving_seconds)   | -1 * sum(distance_meters)  [변경]
--   run_count   | count(*)              | -1 * sum(distance_meters)  [변경]
--   points      | sum(awarded_points)   | sum(moving_seconds)        [현행 유지]
--
-- run_count 에서 sum(moving_seconds) 오름차순을 쓰면 "짧게 뛴 사람이 상위"가 되어
-- 지표의 취지와 정면 충돌한다. duration 은 총 시간이 동일하므로 거리 내림차순이
-- 평균 페이스 오름차순과 완전히 동치다(나눗셈/0 예외 없이 같은 순서를 얻는다).
--
-- ⚠️ tie_break_value 가 음수로 저장된다. 컬럼은 double precision nullable, 제약
--    없음이라 스키마 변경 불필요. **화면에 절대 노출하지 않는 정렬 전용 내부값**이다
--    (규칙서 §5.3 — flutter-ui-designer 는 run_count / total_moving_seconds 를 쓸 것).
--
-- 정렬 규약(score DESC -> tie_break_value ASC -> user_id ASC)과 RANK() 표시는
-- 03 파일 그대로다. 함수 본문 중 scored CTE 의 tie_break_value 계산만 달라진다.
-- =============================================================================

create or replace function public.refresh_leaderboard(
  p_period public.ranking_period,
  p_metric public.ranking_metric,
  p_scope  public.ranking_scope default 'global',
  p_crew_id uuid default null,
  p_anchor timestamptz default now()
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz;
  v_end   timestamptz;
  v_now   timestamptz := now();
  v_count integer;
begin
  if p_scope = 'friends' then
    raise exception 'friends 스코프는 아직 미지원 (친구 관계 테이블 미정의)';
  end if;
  if (p_scope = 'crew') <> (p_crew_id is not null) then
    raise exception 'crew 스코프에는 p_crew_id 가 필요하고, 그 외 스코프에는 NULL 이어야 한다';
  end if;

  select b.period_start, b.period_end
    into v_start, v_end
    from public.leaderboard_period_bounds(p_period, p_anchor) b;

  with base as (
    select
      r.user_id,
      sum(r.distance_meters)                     as dist_m,
      sum(r.moving_seconds)::bigint              as moving_s,
      count(*)::bigint                           as run_cnt,
      coalesce(sum(r.awarded_points), 0)::bigint as pts
    from public.runs r
    join public.profiles p on p.id = r.user_id
    where r.status = 'completed'
      and r.is_flagged = false          -- 서버 재검증 이상치 제외
      and r.started_at >= v_start
      and r.started_at <  v_end
      and (p_scope <> 'crew' or p.crew_id = p_crew_id)
    group by r.user_id
  ),
  scored as (
    select
      b.user_id,
      case p_metric
        when 'distance'  then b.dist_m
        when 'duration'  then b.moving_s::double precision
        when 'run_count' then b.run_cnt::double precision
        when 'points'    then b.pts::double precision
      end                                as score,
      -- 동점 보조값(작을수록 상위) — badge_rules §5.1 확정.
      case p_metric
        when 'duration'  then -1 * b.dist_m
        when 'run_count' then -1 * b.dist_m
        else                   b.moving_s::double precision
      end                                as tie_break_value,
      b.run_cnt::integer                 as run_count,
      b.moving_s::integer                as total_moving_seconds
    from base b
  ),
  ranked as (
    select
      s.*,
      -- 확정 정렬: score DESC -> tie_break_value ASC -> user_id ASC
      -- RANK() 이므로 동점자는 순위를 공유하고 다음 순위를 건너뛴다 (1,2,2,4).
      rank() over (
        order by s.score desc, s.tie_break_value asc, s.user_id asc
      )::integer as rnk
    from scored s
    where s.score > 0
  )
  insert into public.leaderboard_entries as le (
    user_id, username, display_name, avatar_url,
    rank, rank_delta, metric, score, tie_break_value,
    period, scope, crew_id, period_start, period_end,
    run_count, total_moving_seconds, computed_at
  )
  select
    k.user_id, p.username, p.display_name, p.avatar_url,
    k.rnk, null, p_metric, k.score, k.tie_break_value,
    p_period, p_scope, p_crew_id, v_start, v_end,
    k.run_count, k.total_moving_seconds, v_now
  from ranked k
  join public.profiles p on p.id = k.user_id
  on conflict (scope, crew_key, period, metric, period_start, user_id)
  do update set
    username             = excluded.username,
    display_name         = excluded.display_name,
    avatar_url           = excluded.avatar_url,
    rank_delta           = le.rank - excluded.rank,
    rank                 = excluded.rank,
    score                = excluded.score,
    tie_break_value      = excluded.tie_break_value,
    period_end           = excluded.period_end,
    run_count            = excluded.run_count,
    total_moving_seconds = excluded.total_moving_seconds,
    computed_at          = excluded.computed_at;

  get diagnostics v_count = row_count;

  delete from public.leaderboard_entries le
  where le.scope        = p_scope
    and le.crew_key     = coalesce(p_crew_id, '00000000-0000-0000-0000-000000000000'::uuid)
    and le.period       = p_period
    and le.metric       = p_metric
    and le.period_start = v_start
    and le.computed_at  < v_now;

  return v_count;
end;
$$;

revoke execute on function public.refresh_leaderboard(
  public.ranking_period, public.ranking_metric, public.ranking_scope, uuid, timestamptz
) from public, anon, authenticated;

comment on column public.leaderboard_entries.tie_break_value is
  '동점 보조값(작을수록 상위). 지표별 의미가 다르다(badge_rules §5): distance/points=sum(moving_seconds), '
  'duration/run_count=-1*sum(distance_meters). **정렬 전용 내부값이며 UI 노출 금지.**';
