-- =============================================================================
-- Runnit :: 47. FCM 발송 경로 — 알림함 insert 와 푸시 발송의 분리
-- -----------------------------------------------------------------------------
-- ⚠️ 아키텍처 원칙의 **명시적 예외 1건**을 도입한다. 근거를 여기 남긴다.
--
-- ARCHITECTURE §5 는 "백엔드는 Supabase 단일, 서버 로직은 트리거·함수·pg_cron,
-- Deno Edge Function 은 쓰지 않는다"를 확정했다. FCM HTTP v1 호출은 이 원칙과
-- 충돌한다. 두 안을 비교했다.
--
--   (a) pg_net 으로 pg_cron 함수에서 FCM REST 직접 호출
--       ✗ **구현 불가.** FCM HTTP v1 은 서비스 계정 JWT 를 **RS256** 으로 서명해
--         OAuth2 액세스 토큰으로 교환해야 한다. Postgres 에는 RSA 서명 수단이 없다 —
--         pgjwt 는 HMAC(HS256/384/512)만 지원하고, pgcrypto 는 PGP/digest 일 뿐
--         raw RSA sign 을 노출하지 않는다. 토큰은 1시간마다 만료되므로 "미리 발급해
--         Vault 에 넣어둔다"도 성립하지 않는다.
--       ✗ 단순 `Authorization: key=<server key>` 를 쓰던 레거시 FCM API 는
--         2024-06 에 폐지되어 대안이 아니다.
--       ✗ pg_net 은 fire-and-forget 비동기다. 토큰별 응답을 읽어
--         UNREGISTERED/INVALID_ARGUMENT 행을 지우려면 `net._http_response` 를
--         폴링하는 워커를 결국 따로 만들어야 한다 — 원칙을 지키려다 더 복잡해진다.
--
--   (b) 최소 Edge Function 1개(`push-dispatch`)를 원칙의 예외로 도입   ← **채택**
--       ✓ Deno WebCrypto 가 RSASSA-PKCS1-v1_5 를 지원해 서비스 계정 JWT 서명 →
--         액세스 토큰 발급 → 55분 캐시가 가능하다. 이것이 유일하게 동작하는 경로다.
--       ✓ 응답을 동기로 받으므로 무효 토큰 정리와 재시도 판정을 한 자리에서 한다.
--
-- **예외의 범위를 좁게 고정한다 — 이 Edge Function 에는 제품 판정이 없다.**
--   누구에게 무엇을 언제 보낼지는 전부 44~46번 SQL 이 이미 결정해 `notifications`
--   행으로 확정한 뒤다. Edge Function 이 하는 일은 "확정된 행을 Google 에 전달하고
--   응답을 되돌려 기록"뿐이다. FCM 을 다른 벤더로 바꿔도 이 파일 하나만 바뀐다.
--   ⚠️ 여기에 조건 판정을 추가하면 판정 로직이 SQL 과 Deno 두 곳으로 갈라진다.
--      새 알림 종류는 **반드시 SQL 쪽에** 추가할 것.
--
-- 발송과 트랜잭션의 분리 (필수)
--   `enqueue_notification` 은 러닝 저장 트랜잭션 **안**에서 알림함 행만 만든다.
--   푸시 발송은 이 파일의 디스패처가 **트랜잭션 밖에서** 훑는다. 발송을 트랜잭션에
--   넣으면 FCM 이 느리거나 죽었을 때 사용자의 **러닝 저장이 실패한다** — 알림 하나
--   때문에 기록을 잃는 것은 어떤 경우에도 정당화되지 않는다(PRD §6 안정성).
-- =============================================================================

create extension if not exists pg_net with schema extensions;

-- -----------------------------------------------------------------------------
-- 47-1. 발송 대기열 claim — 상태 전이를 전부 SQL 이 소유한다
-- -----------------------------------------------------------------------------
-- Edge Function 이 `notifications` 를 직접 쿼리하지 않고 이 함수만 부르게 한다.
-- 그래야 "무엇이 발송 대상인가"(마스터 스위치·재시도·만료)가 SQL 한 곳에 남는다.
create or replace function public.claim_push_batch(p_limit integer default 100)
returns table (
  notification_id uuid,
  user_id         uuid,
  title           text,
  body            text,
  payload         jsonb,
  tokens          text[]
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- ① 마스터 스위치가 꺼진 사용자 — 알림함 기록은 남기고 푸시만 건너뛴다.
  --    (종류별 토글 off 는 애초에 행이 만들어지지 않는다 — 44-12 참조)
  update public.notifications n
     set sent_at = now(), send_error = 'push_disabled'
   where n.sent_at is null
     and exists (select 1 from public.notification_settings s
                  where s.user_id = n.user_id and s.push_enabled = false);

  -- ② 등록된 토큰이 없는 사용자(권한 거부·미로그인 기기 없음).
  update public.notifications n
     set sent_at = now(), send_error = 'no_token'
   where n.sent_at is null
     and not exists (select 1 from public.push_tokens t where t.user_id = n.user_id);

  -- ③ 만료. 하루 지난 알림을 이제 와서 밀어 넣으면 "어제 순위"를 오늘 알리는 꼴이 된다.
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
    returning n.id, n.user_id, n.title, n.body, n.payload
  )
  select c.id, c.user_id, c.title, c.body, c.payload,
         array(select t.token from public.push_tokens t where t.user_id = c.user_id)
    from claimed c;
end;
$$;

comment on function public.claim_push_batch(integer) is
  '발송 대기 알림을 claim 한다(send_attempts 증가). "무엇이 발송 대상인가"를 SQL 한 곳에 '
  '가둬 두기 위한 함수 — Edge Function 은 notifications 를 직접 쿼리하지 않는다. '
  'push_enabled=false / 토큰 없음 / 24h 경과 / 3회 실패는 여기서 큐 밖으로 내보낸다.';
revoke execute on function public.claim_push_batch(integer) from public, anon, authenticated;
grant  execute on function public.claim_push_batch(integer) to service_role;

-- -----------------------------------------------------------------------------
-- 47-2. 발송 결과 기록 / 무효 토큰 정리
-- -----------------------------------------------------------------------------
create or replace function public.mark_push_result(p_id uuid, p_error text default null)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  -- 실패면 sent_at 을 비워 둔 채 오류만 남긴다 -> 다음 주기에 재시도(최대 3회).
  update public.notifications n
     set sent_at    = case when p_error is null then now() else null end,
         send_error = p_error
   where n.id = p_id;
$$;

revoke execute on function public.mark_push_result(uuid, text) from public, anon, authenticated;
grant  execute on function public.mark_push_result(uuid, text) to service_role;

-- 토큰은 재설치·데이터 삭제·장기 미사용으로 조용히 만료된다. FCM 이
-- UNREGISTERED/INVALID_ARGUMENT 를 주는 순간이 **유일한 정리 시점**이다.
-- 클라이언트는 이 사실을 알 수 없고 다음 실행에서 자연 복구된다.
create or replace function public.prune_push_token(p_token text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from public.push_tokens t where t.token = p_token;
$$;

revoke execute on function public.prune_push_token(text) from public, anon, authenticated;
grant  execute on function public.prune_push_token(text) to service_role;

-- -----------------------------------------------------------------------------
-- 47-3. pg_cron -> Edge Function 호출 (pg_net)
-- -----------------------------------------------------------------------------
-- 비밀은 **Supabase Vault** 에 둔다. 마이그레이션에 URL·키를 하드코딩하면 그 값이
-- 리포지토리에 영구히 남는다.
--
--   select vault.create_secret('https://<ref>.functions.supabase.co/push-dispatch',
--                              'push_dispatch_url');
--   select vault.create_secret('<service_role_key>', 'push_dispatch_token');
--
-- 비밀이 없으면 **조용히 no-op** 한다 — FCM 프로젝트가 준비되기 전에도 44~46 의
-- 알림함 적재는 정상 동작해야 하고, cron 이 매분 에러 로그를 쌓으면 안 된다.
create or replace function public.dispatch_pending_pushes()
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_url   text;
  v_token text;
  v_req   bigint;
begin
  if not exists (select 1 from public.notifications n where n.sent_at is null) then
    return null;
  end if;

  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'push_dispatch_url';
  select decrypted_secret into v_token
    from vault.decrypted_secrets where name = 'push_dispatch_token';

  if v_url is null or v_token is null then
    return null;   -- 아직 FCM 미연결. 알림함 적재는 계속 정상 동작한다.
  end if;

  select net.http_post(
           url     := v_url,
           headers := jsonb_build_object(
                        'Content-Type',  'application/json',
                        'Authorization', 'Bearer ' || v_token),
           body    := jsonb_build_object('limit', 100),
           timeout_milliseconds := 20000
         )
    into v_req;

  return v_req;
end;
$$;

comment on function public.dispatch_pending_pushes() is
  '푸시 발송 워커 트리거. pg_net 으로 push-dispatch Edge Function 을 깨운다. Vault 에 '
  'push_dispatch_url / push_dispatch_token 이 없으면 조용히 no-op — FCM 연결 전에도 '
  '알림함 적재는 정상 동작해야 한다.';
revoke execute on function public.dispatch_pending_pushes() from public, anon, authenticated;

select cron.unschedule('runnit-push-dispatch')
 where exists (select 1 from cron.job where jobname = 'runnit-push-dispatch');

-- 매분. 트리거 계열(NT-01/02/06)은 러닝 직후 도착해야 의미가 있으므로 지연 상한을
-- 1분으로 잡는다. 대기 행이 없으면 함수가 즉시 빠져나오므로 비용은 사실상 0이다.
select cron.schedule('runnit-push-dispatch', '* * * * *',
  $cron$ select public.dispatch_pending_pushes(); $cron$);
