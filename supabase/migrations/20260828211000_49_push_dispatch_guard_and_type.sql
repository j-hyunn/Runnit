-- =============================================================================
-- Runnit :: 49. 발송 워커 결함 수정 — server_write 누락(C-1) · FCM data.type 누락(C-2)
-- -----------------------------------------------------------------------------
-- 정본: `_workspace/20260828_205500_qa_notifications.md` C-1 · C-2 · S-1 · S-3
--
-- 47번이 발송 큐를 만들면서 **44-5 가드 트리거를 계산에 넣지 않았다.** 알림함의
-- 쓰기 보호(클라이언트는 read_at만)를 세운 바로 그 가드가, 서버 자신의 발송 상태
-- 기록까지 되돌리고 있었다. 알림함 경로만 보면 정합해 보였기 때문에 44~48 자체
-- 검증에서는 드러나지 않았고, **푸시가 실제로 나가기 시작하는 순간** 터졌을 결함이다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 49-1. server_write 구간을 여닫는 헬퍼 — 무조건 'off' 복원을 없앤다 (C-1 · S-1)
-- -----------------------------------------------------------------------------
-- 기존 관례는 `set_config(...,'on')` … `set_config(...,'off')` 였다. 이 형태는
-- **바깥이 이미 'on'이었을 때 그 구간을 조기 종료시킨다**(QA S-1). 지금은 호출
-- 그래프상 사고가 나지 않지만, 이번 라운드에서 서버 쓰기 구간 안에서 알림을 발행하는
-- 경로(`claim_push_batch` → 가드 걸린 UPDATE 4건)가 실제로 생겼으므로 더는 미룰 수
-- 없다. 진입 시 이전 값을 받아 두고 그 값으로 되돌린다.
create or replace function public._server_write_enter()
returns text
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_prev text := coalesce(current_setting('runnit.server_write', true), 'off');
begin
  perform set_config('runnit.server_write', 'on', true);
  return v_prev;
end;
$$;

create or replace function public._server_write_exit(p_prev text)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
begin
  perform set_config('runnit.server_write', coalesce(nullif(p_prev, ''), 'off'), true);
end;
$$;

comment on function public._server_write_enter() is
  '서버 쓰기 구간 진입. 이전 값을 돌려주며, 짝이 되는 _server_write_exit() 로 **그 값을 복원**한다. '
  '무조건 off 로 되돌리는 옛 관례는 중첩 호출에서 바깥 구간을 조기 종료시킨다(QA S-1).';

revoke execute on function public._server_write_enter()  from public, anon, authenticated;
revoke execute on function public._server_write_exit(text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 49-2. enqueue_notification — 복원식으로 교체 (S-1 예방)
-- -----------------------------------------------------------------------------
create or replace function public.enqueue_notification(
  p_user_id    uuid,
  p_type       public.notification_type,
  p_title      text,
  p_body       text,
  p_route      text,
  p_payload    jsonb,
  p_dedupe_key text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id   uuid;
  v_prev text;
begin
  if p_user_id is null or p_dedupe_key is null then return null; end if;
  if not public.notification_enabled(p_user_id, p_type) then return null; end if;

  v_prev := public._server_write_enter();

  insert into public.notifications (user_id, type, title, body, payload, dedupe_key)
  values (p_user_id, p_type, p_title, p_body,
          coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('route', p_route),
          p_dedupe_key)
  on conflict (user_id, dedupe_key) do nothing
  returning id into v_id;

  perform public._server_write_exit(v_prev);
  return v_id;
end;
$$;

revoke execute on function public.enqueue_notification(
  uuid, public.notification_type, text, text, text, jsonb, text)
  from public, anon, authenticated;

-- ⚠️ payload 에 `type` 을 넣지 않는다. QA C-2 의 수정 방향 그대로다 —
--    payload 규약(TRD §4.1-N)은 "서버가 채우는 **표시값**"이고, 종류는 이미
--    `notifications.type` 컬럼이자 `AppNotification.type` 필드다. payload 에 또 넣으면
--    같은 사실이 두 곳에 적히고, 둘이 어긋났을 때 어느 쪽이 진짜인지 판단할 근거가
--    사라진다. FCM 으로는 49-3 이 전용 컬럼으로 실어 보낸다.

-- -----------------------------------------------------------------------------
-- 49-3. claim_push_batch — server_write(C-1) + type 반환(C-2)
-- -----------------------------------------------------------------------------
-- (C-1) 큐 배출 UPDATE 3건과 claim UPDATE 는 전부 `notifications` 를 쓰므로 44-5
--       가드를 통과해야 한다. 이게 없으면:
--         ① sent_at 이 영원히 null → 대기열에서 빠지지 않음 → **같은 푸시가 매분 무한 반복**
--         ② send_attempts 가 늘지 않아 3회 실패 만료 경로가 죽음
--         ③ push_enabled=false 배출이 무효 → **마스터 스위치를 끈 사용자에게도 푸시**(NT-08 위반)
--       dedupe_key 는 알림함 insert 만 막지 발송은 막지 못한다.
-- (C-2) 반환에 `type` 을 추가한다. 클라이언트는 `message.data['type']` 으로 종류를
--       판정해 성취 계열(NT-01·NT-06)의 인앱 배너를 생략하는데, 이 값이 도착하지
--       않으면 배너 + 풀페이지 축하가 **같은 사건을 두 번** 알린다
--       (ARCHITECTURE §7.4.1 "소비 지점은 하나"가 깨진다).
drop function if exists public.claim_push_batch(integer);

create function public.claim_push_batch(p_limit integer default 100)
returns table (
  notification_id uuid,
  user_id         uuid,
  type            public.notification_type,
  title           text,
  body            text,
  payload         jsonb,
  tokens          text[]
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prev text;
begin
  v_prev := public._server_write_enter();

  -- 마스터 스위치 off: 알림함 기록은 남기고 푸시만 건너뛴다.
  update public.notifications n
     set sent_at = now(), send_error = 'push_disabled'
   where n.sent_at is null
     and exists (select 1 from public.notification_settings s
                  where s.user_id = n.user_id and s.push_enabled = false);

  -- 등록 토큰 없음(권한 거부 등).
  update public.notifications n
     set sent_at = now(), send_error = 'no_token'
   where n.sent_at is null
     and not exists (select 1 from public.push_tokens t where t.user_id = n.user_id);

  -- 만료. 하루 지난 알림을 이제 와서 밀어 넣으면 "어제 순위"를 오늘 알리는 꼴이 된다.
  update public.notifications n
     set sent_at = now(), send_error = 'expired'
   where n.sent_at is null
     and (n.created_at < now() - interval '24 hours' or n.send_attempts >= 3);

  return query
  with claimed as (
    update public.notifications n
       set send_attempts = n.send_attempts + 1
     where n.id in (
       select c.id from public.notifications c
        where c.sent_at is null
        order by c.created_at
        limit greatest(coalesce(p_limit, 100), 1)
        for update skip locked
     )
    returning n.id, n.user_id, n.type, n.title, n.body, n.payload
  )
  select c.id, c.user_id, c.type, c.title, c.body, c.payload,
         array(select t.token from public.push_tokens t where t.user_id = c.user_id)
    from claimed c;

  perform public._server_write_exit(v_prev);
end;
$$;

comment on function public.claim_push_batch(integer) is
  '발송 대기 알림 claim(send_attempts 증가) + 큐 배출(push_enabled=false / 토큰 없음 / 24h 경과 / 3회 실패). '
  '⚠️ 44-5 notifications_guard 가 sent_at·send_error·send_attempts 를 되돌리므로 '
  '**server_write 구간 안에서 써야 한다**(49번, QA C-1). `type` 은 Edge Function 이 FCM '
  'data.type 으로 실어 보내는 값이다 — 없으면 클라이언트의 성취 중복 억제가 죽는다(QA C-2).';

revoke execute on function public.claim_push_batch(integer) from public, anon, authenticated;
grant  execute on function public.claim_push_batch(integer) to service_role;

-- -----------------------------------------------------------------------------
-- 49-4. mark_push_result — language sql -> plpgsql (C-1)
-- -----------------------------------------------------------------------------
-- `language sql` 로는 set_config 구간을 열 수 없다. 가드를 완화하는 대안도 있었으나
-- **44번의 "가드는 두 겹 방어선" 설계 의도를 유지**하는 쪽을 택했다 — 가드가
-- 되돌리는 컬럼 목록을 줄이면, 나중에 누가 클라이언트 update 정책을 넓혔을 때
-- 방어선이 한 겹 사라진 사실을 아무도 눈치채지 못한다.
create or replace function public.mark_push_result(p_id uuid, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prev text;
begin
  v_prev := public._server_write_enter();

  -- 실패면 sent_at 을 비워 둔 채 오류만 남긴다 -> 다음 주기에 재시도(최대 3회).
  update public.notifications n
     set sent_at    = case when p_error is null then now() else null end,
         send_error = p_error
   where n.id = p_id;

  perform public._server_write_exit(v_prev);
end;
$$;

comment on function public.mark_push_result(uuid, text) is
  '발송 결과 기록. server_write 구간 안에서 쓴다(49번, QA C-1) — 없으면 sent_at 이 저장되지 '
  '않아 같은 푸시가 매분 무한 재발송된다.';

revoke execute on function public.mark_push_result(uuid, text) from public, anon, authenticated;
grant  execute on function public.mark_push_result(uuid, text) to service_role;

-- -----------------------------------------------------------------------------
-- 49-5. runnit-rank-notify 의 UTC 13시 슬롯 제거 (S-3)
-- -----------------------------------------------------------------------------
-- `_batch_hours_ok` 는 `between 8 and 21` 이라 UTC 13:00(= KST 22:00) 슬롯은 항상
-- 0 을 반환한다. 게이트를 22 로 넓히지 않고 cron 을 줄인다 — "08:00~22:00"을
-- 반열림 구간 [08:00, 22:00)으로 읽는 쪽이 마감 시각 표기(주간 마감 23:59, 시즌 경계)와
-- 같은 규약이고, 22:00 정각 발송은 방해 금지 경계에 걸친다.
select cron.unschedule('runnit-rank-notify')
 where exists (select 1 from cron.job where jobname = 'runnit-rank-notify');

select cron.schedule('runnit-rank-notify', '0 23,0-12 * * *',
  $cron$ select public.refresh_leaderboards_and_notify(); $cron$);
