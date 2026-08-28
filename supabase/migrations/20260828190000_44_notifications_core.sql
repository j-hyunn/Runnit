-- =============================================================================
-- Runnit :: 44. 알림 시스템 코어 스키마 (PRD §5.10 NT-01~08)
-- -----------------------------------------------------------------------------
-- 정본
--   _workspace/20260828_164428_architect_notifications.md  (데이터 모델·인계 계약)
--   _workspace/20260828_181500_gamification_notification-rules.md (판정 규칙)
--   docs/TRD.md §3.10 · §4.1-N   docs/ARCHITECTURE.md §7.3 · §7.4
--
-- 이 파일은 **테이블·enum·헬퍼 함수·RLS**만 만든다. 실제 발화 로직은
--   45 = 트리거 계열(NT-01/02/06), 46 = 배치 계열(NT-03/04/05), 47 = FCM 발송 경로.
--
-- 설계 고정점 3가지
--   1) `notifications` 는 **알림함이자 발송 로그**다. 두 테이블로 쪼개면 "푸시는
--      갔는데 알림함에 없다"는 상태가 생기고 어느 쪽이 진실인지 판단할 근거가 없다.
--   2) 멱등성의 유일한 방어선은 `unique (user_id, dedupe_key)` 다. pg_cron 재실행·
--      트리거 중복 발화는 반드시 일어나며, 애플리케이션 레벨 count 체크는 경합에서
--      새어 나간다. **발송 상한도 키에 순번을 넣어 이 제약으로 강제한다**(NT-04).
--   3) 종류별 on/off 는 jsonb 가 아니라 **컬럼**이다. 발송 주체가 pg_cron 이라
--      `left join notification_settings s ... where coalesce(s.rank_change, true)`
--      한 번으로 수신 거부자를 걸러야 한다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 44-1. enum 2종 — 라벨 3계층 일치 (Postgres = @JsonValue = wire)
-- -----------------------------------------------------------------------------
-- lib/models/enums.dart 의 NotificationType / DevicePlatform,
-- lib/core/api/wire_enums.dart 의 NotificationTypeWire.wire 와 **글자 그대로** 같다.
-- 어긋나면 조회가 에러 없이 빈 결과를 돌려준다.
--
-- `points`(NT-07)는 Phase 4 라 **발행하지 않지만 라벨은 지금 심는다** — 나중에
-- 서버가 그 타입을 발행했을 때 구버전 앱의 fromJson 이 예외를 던져 알림함 전체가
-- 깨지는 사고를 막기 위해서다. notification_settings 에는 컬럼을 만들지 않는다
-- (적립 규칙이 미정이라 지금 만든 토글은 아무것도 제어하지 못한다).
create type public.notification_type as enum (
  'tier_promotion',   -- NT-01
  'tier_proximity',   -- NT-02
  'season_ending',    -- NT-03
  'rank_change',      -- NT-04
  'weekend_push',     -- NT-05
  'badge_level',      -- NT-06
  'points'            -- NT-07 (Phase 4, 미발행)
);

comment on type public.notification_type is
  '알림 종류. 값 하나 = PRD §5.10 요구사항 ID 하나. NT-08 토글의 "항목"이 이 단위이므로 '
  '요구사항보다 잘게 쪼개지 않는다 — 추월함/추월당함, D-14/D-3 같은 뉘앙스는 payload 로 간다.';

create type public.device_platform as enum ('ios', 'android');

-- -----------------------------------------------------------------------------
-- 44-2. push_tokens — PK 는 token, 유저당 N행이 정상
-- -----------------------------------------------------------------------------
-- user_id 를 PK 로 잡으면 두 번째 기기가 첫 번째를 밀어내고 "이 폰에서는 오는데
-- 저 폰에서는 안 온다"가 된다.
create table public.push_tokens (
  token       text primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  platform    public.device_platform not null,
  device_id   text,
  app_version text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index push_tokens_user_idx on public.push_tokens (user_id);
create index push_tokens_stale_idx on public.push_tokens (updated_at);

comment on table public.push_tokens is
  'FCM 등록 토큰. PK=token, 유저당 여러 행이 정상(기기 다대). 토큰은 재설치·데이터 삭제로 '
  '조용히 만료되며, 발송 시 UNREGISTERED/INVALID_ARGUMENT 응답이 오면 서버가 행을 지운다 '
  '— 그것이 유일한 정리 경로다.';
comment on column public.push_tokens.device_id is
  '설치 단위 식별자. 같은 기기의 옛 토큰을 정리하는 근거. 못 얻으면 null.';

-- -----------------------------------------------------------------------------
-- 44-3. notification_settings (NT-08) — 기본값 전부 on, 행 부재 = 전부 on
-- -----------------------------------------------------------------------------
create table public.notification_settings (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  push_enabled   boolean not null default true,   -- 마스터 스위치
  tier_promotion boolean not null default true,   -- NT-01
  tier_proximity boolean not null default true,   -- NT-02
  season_ending  boolean not null default true,   -- NT-03
  rank_change    boolean not null default true,   -- NT-04
  weekend_push   boolean not null default true,   -- NT-05
  badge_level    boolean not null default true,   -- NT-06
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

comment on table public.notification_settings is
  'NT-08 종류별 알림 on/off. **행이 없으면 전 종류 on 으로 간주한다**(서버·클라이언트 공통) — '
  '가입 직후 행 생성 실패로 알림이 조용히 끊기는 쪽이, 기본값을 한 번 더 보내는 것보다 나쁘다. '
  'NT-07(points) 컬럼은 만들지 않는다: 적립 규칙 미정이라 아무것도 제어하지 못하는 스위치가 된다.';
comment on column public.notification_settings.push_enabled is
  '마스터 스위치. **끄면 푸시만 멈추고 알림함 기록은 남는다**(47번 디스패처가 이 컬럼을 본다) — '
  '종류별 토글을 끄는 것은 "알려주지 마"이고, 마스터를 끄는 것은 "푸시로는 받지 않겠다"이다.';

-- -----------------------------------------------------------------------------
-- 44-4. notifications — 알림함 겸 발송 로그
-- -----------------------------------------------------------------------------
create table public.notifications (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  type          public.notification_type not null,
  title         text not null,
  body          text not null,
  payload       jsonb not null default '{}'::jsonb,
  dedupe_key    text not null,
  created_at    timestamptz not null default now(),
  read_at       timestamptz,
  -- 발송 결과 로그. 알림함 표시와 무관해 Dart 모델에는 대응 필드가 없다(TRD §4.1-N).
  sent_at       timestamptz,
  send_error    text,
  send_attempts smallint not null default 0,
  constraint notifications_dedupe_unique unique (user_id, dedupe_key)
);

-- 알림함 정렬 (최신 우선 커서 페이지네이션)
create index notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

-- 미읽음 배지 head count
create index notifications_unread_idx
  on public.notifications (user_id)
  where read_at is null;

-- 47번 디스패처가 훑는 대기열
create index notifications_pending_idx
  on public.notifications (created_at)
  where sent_at is null;

comment on table public.notifications is
  '알림함이자 발송 로그. 문구(title/body)는 **서버가 완성해서 저장한다** — 클라이언트가 '
  'payload 로 조립하면 푸시 트레이 문구와 알림함 문구가 갈라져 같은 사건이 두 가지로 보인다. '
  '클라이언트가 쓸 수 있는 컬럼은 read_at 하나뿐(가드 트리거가 강제).';
comment on column public.notifications.dedupe_key is
  '멱등 키. `{type}:{scope}` 규약 — tier_promotion:2026-Q3:gold / season_ending:2026-Q3:d3 / '
  'rank_change:2026-W35:down:2 / weekend_push:2026-W35:sun / badge_level:run:{run_id}. '
  'unique(user_id, dedupe_key) 가 곧 **발송 상한**이다(NT-04 는 키에 순번 n 을 넣어 강제).';
comment on column public.notifications.payload is
  '딥링크(route)와 부가 표시값. 서버가 채우고 클라이언트는 읽기 전용, 미지 키는 무시한다.';

-- -----------------------------------------------------------------------------
-- 44-5. 가드 트리거 — 클라이언트 UPDATE 는 read_at 만
-- -----------------------------------------------------------------------------
-- user_badges.is_seen 과 동일 규약(마이그레이션 05). RLS 정책만으로는 "어느 컬럼을
-- 바꿨는가"를 막을 수 없어 가드 트리거가 필요하다.
create or replace function public.trg_notifications_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if not public.is_server_write() then
      -- 클라이언트는 알림을 만들 수 없다. RLS 에 insert 정책도 없으므로 여기까지
      -- 오는 경로는 없지만, 방어선을 두 겹으로 둔다.
      raise exception 'notifications 는 서버만 생성한다' using errcode = '42501';
    end if;
    new.created_at := coalesce(new.created_at, now());
    return new;
  end if;

  if not public.is_server_write() then
    new.id            := old.id;
    new.user_id       := old.user_id;
    new.type          := old.type;
    new.title         := old.title;
    new.body          := old.body;
    new.payload       := old.payload;
    new.dedupe_key    := old.dedupe_key;
    new.created_at    := old.created_at;
    new.sent_at       := old.sent_at;
    new.send_error    := old.send_error;
    new.send_attempts := old.send_attempts;
    -- 읽은 시각은 뒤로 밀리지 않는다. 이미 읽은 행의 재-읽음 처리는 무시.
    if old.read_at is not null then
      new.read_at := old.read_at;
    end if;
  end if;
  return new;
end;
$$;

create trigger notifications_guard
before insert or update on public.notifications
for each row execute function public.trg_notifications_guard();

-- notification_settings / push_tokens updated_at
create or replace function public.trg_touch_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger notification_settings_touch
before update on public.notification_settings
for each row execute function public.trg_touch_updated_at();

create trigger push_tokens_touch
before insert or update on public.push_tokens
for each row execute function public.trg_touch_updated_at();

-- -----------------------------------------------------------------------------
-- 44-6. RLS
-- -----------------------------------------------------------------------------
alter table public.push_tokens           enable row level security;
alter table public.notification_settings enable row level security;
alter table public.notifications         enable row level security;

-- push_tokens : 본인 행 전권
create policy push_tokens_select_own on public.push_tokens
  for select to authenticated using (user_id = (select auth.uid()));
create policy push_tokens_insert_own on public.push_tokens
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy push_tokens_update_own on public.push_tokens
  for update to authenticated using (user_id = (select auth.uid()))
                                 with check (user_id = (select auth.uid()));
create policy push_tokens_delete_own on public.push_tokens
  for delete to authenticated using (user_id = (select auth.uid()));

-- notification_settings : 본인 행 select/insert/update (삭제 경로 없음)
create policy notification_settings_select_own on public.notification_settings
  for select to authenticated using (user_id = (select auth.uid()));
create policy notification_settings_insert_own on public.notification_settings
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy notification_settings_update_own on public.notification_settings
  for update to authenticated using (user_id = (select auth.uid()))
                                 with check (user_id = (select auth.uid()));

-- notifications : 본인 행 select + update(read_at 한정, 가드가 강제). insert/delete 정책 없음.
create policy notifications_select_own on public.notifications
  for select to authenticated using (user_id = (select auth.uid()));
create policy notifications_update_own on public.notifications
  for update to authenticated using (user_id = (select auth.uid()))
                                 with check (user_id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- 44-7. realtime publication
-- -----------------------------------------------------------------------------
-- 미읽음 배지가 앱을 껐다 켜야만 갱신되면 배지의 의미가 없다.
-- 클라이언트는 INSERT 를 **재조회 신호로만** 쓴다(architect §3.2).
alter publication supabase_realtime add table public.notifications;

-- -----------------------------------------------------------------------------
-- 44-8. push_tokens 등록 RPC — 기기 이양·토큰 재사용을 RLS 없이 안전하게 처리
-- -----------------------------------------------------------------------------
-- 순수 upsert 로는 처리할 수 없는 경우가 하나 있다: **같은 기기를 다른 계정이 쓰는**
-- 경우 FCM 토큰이 그대로인 채 user_id 만 바뀌는데, update 정책의 USING 이
-- `user_id = auth.uid()` 를 요구하므로 이전 소유자의 행에 매칭되지 않아 실패한다.
-- 그 상태로 두면 기기를 넘겨받은 사용자에게 **이전 사용자의 순위·티어 알림이 간다.**
-- SECURITY DEFINER 로 "그 토큰 행을 지우고 내 것으로 다시 만든다"를 원자적으로 한다.
create or replace function public.register_push_token(
  p_token       text,
  p_platform    public.device_platform,
  p_device_id   text default null,
  p_app_version text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception '인증이 필요하다' using errcode = '42501';
  end if;
  if p_token is null or length(p_token) = 0 then
    raise exception 'token 이 비어 있다' using errcode = '22000';
  end if;

  -- 같은 기기의 옛 토큰 정리(architect §1.4). device_id 를 못 얻으면 건너뛴다.
  if p_device_id is not null then
    delete from public.push_tokens t
     where t.device_id = p_device_id
       and t.token <> p_token;
  end if;

  insert into public.push_tokens (token, user_id, platform, device_id, app_version)
  values (p_token, v_uid, p_platform, p_device_id, p_app_version)
  on conflict (token) do update
    set user_id     = excluded.user_id,
        platform    = excluded.platform,
        device_id   = excluded.device_id,
        app_version = excluded.app_version,
        updated_at  = now();
end;
$$;

comment on function public.register_push_token(text, public.device_platform, text, text) is
  'FCM 토큰 등록/갱신. NotificationRepository.upsertToken 의 서버 진입점. 같은 device_id 의 '
  '옛 토큰과 다른 계정이 점유하던 같은 토큰을 원자적으로 정리한다 — 기기를 넘겨받은 사용자에게 '
  '이전 사용자의 알림이 가는 사고를 막는 유일한 경로다.';

revoke execute on function public.register_push_token(text, public.device_platform, text, text)
  from public, anon;
grant execute on function public.register_push_token(text, public.device_platform, text, text)
  to authenticated;

-- -----------------------------------------------------------------------------
-- 44-9. 알림함 헬퍼 RPC — 전체 읽음
-- -----------------------------------------------------------------------------
-- 클라이언트가 `update ... set read_at = now() where read_at is null` 을 직접 쏴도
-- RLS + 가드로 안전하지만, 읽은 시각을 **서버 시각**으로 확정하기 위해 RPC 를 둔다
-- (기기 시계를 믿지 않는다 — NotificationRepository.markRead 주석).
create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_cnt integer;
begin
  if v_uid is null then
    raise exception '인증이 필요하다' using errcode = '42501';
  end if;

  update public.notifications n
     set read_at = now()
   where n.user_id = v_uid
     and n.read_at is null
     and (p_ids is null or n.id = any (p_ids));

  get diagnostics v_cnt = row_count;
  return v_cnt;
end;
$$;

comment on function public.mark_notifications_read(uuid[]) is
  '읽음 처리. p_ids 가 null 이면 전체 읽음(markAllRead). 이미 읽은 행은 건드리지 않는다 — '
  '읽은 시각이 뒤로 밀리면 안 된다.';

revoke execute on function public.mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;

-- -----------------------------------------------------------------------------
-- 44-10. leaderboard_entries — NT-04 기준선 2컬럼
-- -----------------------------------------------------------------------------
-- ⚠️ `rank_delta` 를 알림 기준으로 쓰면 안 된다. 그것은 **직전 5분 배치 대비 변동**이라
--    ±1~2계단 진동하는 사용자에게 하루 수십 건이 나가고, 3계단 내려갔다 3계단 올라온
--    사용자에게 "추월당함"+"추월함" 두 건이 나간다(순 변동은 0인데 알림은 2건).
--    기준선은 "5분 전 순위"가 아니라 **"마지막으로 사용자에게 알려준 순위"** 여야 한다.
--    rank_delta 는 UI 의 "↑3" 표시용으로 그대로 둔다 — 역할이 다르다.
alter table public.leaderboard_entries
  add column notified_rank integer,
  add column notified_at   timestamptz;

comment on column public.leaderboard_entries.notified_rank is
  'NT-04 기준선 — 이 사용자에게 마지막으로 통지한 rank. 발송 상한에 걸려 건너뛴 경우에도 '
  '갱신한다(갱신하지 않으면 같은 변동이 매 주기 조건을 만족해 계속 재시도한다).';
comment on column public.leaderboard_entries.notified_at is
  'NT-04 마지막 통지 시각. 6시간 간격 게이트 판정용.';

-- -----------------------------------------------------------------------------
-- 44-11. 판정 공용 헬퍼
-- -----------------------------------------------------------------------------

-- 다음 티어. 플래티넘이면 null(= 다음 목표 없음 → NT-02 발송 안 함).
create or replace function public.next_tier(p_tier public.tier)
returns public.tier
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_tier
    when 'bronze' then 'silver'::public.tier
    when 'silver' then 'gold'::public.tier
    when 'gold'   then 'platinum'::public.tier
    else null
  end;
$$;

-- 해당 티어 진입 기준선(m). tier_for_distance(마이그레이션 19)의 역함수다.
create or replace function public.tier_threshold_m(p_tier public.tier)
returns double precision
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_tier
    when 'bronze'   then 0::double precision
    when 'silver'   then 25000::double precision
    when 'gold'     then 100000::double precision
    when 'platinum' then 250000::double precision
  end;
$$;

-- NT-02 근접 임계치 — **구간별 고정 테이블**(계산식 아님).
-- 전 구간 5km 안을 채택하지 않은 이유: 골드→플래티넘 구간(150km)에서 5km 는 3.3%라
-- 밴드가 너무 좁아 거의 아무도 통과하지 못한다. 플래티넘 페이스 러너의 주 평균이
-- 19km(PRD §5.3.2)이므로 한 번의 러닝이 밴드를 통째로 건너뛴다.
-- 레벨 임계값(TRD §3.8.3)과 같은 원칙 — 비율 계산식을 런타임에 돌리지 않고 정수를 심어
-- "잔여 5,000.0001m"가 밴드 밖으로 새는 부동소수 경계 사고를 원천 차단한다.
create or replace function public.tier_proximity_threshold_m(p_next public.tier)
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_next
    when 'silver'   then 5000
    when 'gold'     then 10000
    when 'platinum' then 15000
    else null
  end;
$$;

comment on function public.tier_proximity_threshold_m(public.tier) is
  'NT-02 근접 알림 밴드 폭(m). 실버 5,000 / 골드 10,000 / 플래티넘 15,000 — 각 구간의 '
  '20% / 13% / 10%. 정본: _workspace/20260828_181500_gamification_notification-rules.md §1.1';

-- 티어 한글 라벨 — 서버가 문구를 완성하므로 서버가 소유한다.
create or replace function public.tier_ko(p_tier public.tier)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_tier
    when 'bronze'   then '브론즈'
    when 'silver'   then '실버'
    when 'gold'     then '골드'
    when 'platinum' then '플래티넘'
  end;
$$;

-- KST ISO 주 키. leaderboard_entries.period_start(weekly)와 같은 기준(PRD §8.5).
create or replace function public.week_id_at(p_at timestamptz default now())
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select to_char(p_at at time zone 'Asia/Seoul', 'IYYY-"W"IW');
$$;

-- 소수점 1자리 km 문자열. "4.7km"가 "5km"보다 구체적이고, 구체적인 숫자가 행동을 부른다.
create or replace function public.fmt_km(p_meters double precision)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select trim(to_char(round((greatest(coalesce(p_meters, 0), 0) / 100.0))::numeric / 10.0, 'FM999999990.0'));
$$;

-- 시즌 라벨 "2026 Q3"
create or replace function public.season_label(p_season_id text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select replace(p_season_id, '-', ' ');
$$;

-- RK-04 상위 % 산식. 랭킹 화면과 알림이 같은 값을 보여야 한다.
create or replace function public.top_pct(p_rank integer, p_participants integer)
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when coalesce(p_participants, 0) <= 0 or p_rank is null then null
    else greatest(1, ceil(p_rank::numeric / p_participants::numeric * 100)::integer)
  end;
$$;

-- NT-08 수신 여부. **행이 없으면 on**(coalesce). points 는 컬럼이 없으므로 항상 false
-- (Phase 4 — 발행 경로 자체가 없다).
create or replace function public.notification_enabled(
  p_user_id uuid,
  p_type    public.notification_type
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case p_type
    when 'points' then false
    else coalesce(
      (select case p_type
         when 'tier_promotion' then s.tier_promotion
         when 'tier_proximity' then s.tier_proximity
         when 'season_ending'  then s.season_ending
         when 'rank_change'    then s.rank_change
         when 'weekend_push'   then s.weekend_push
         when 'badge_level'    then s.badge_level
       end
       from public.notification_settings s
       where s.user_id = p_user_id),
      true)
  end;
$$;

comment on function public.notification_enabled(uuid, public.notification_type) is
  'NT-08 수신 여부. 설정 행이 없으면 **on**. 마스터 스위치(push_enabled)는 여기서 보지 않는다 '
  '— 마스터는 푸시 발송만 막고 알림함 기록은 남기므로 47번 디스패처가 본다.';

revoke execute on function public.notification_enabled(uuid, public.notification_type)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 44-12. enqueue_notification — 모든 알림의 유일한 발행 진입점
-- -----------------------------------------------------------------------------
-- 발행이 여기 하나로 모이므로 NT-08 필터·멱등 처리·payload 규약을 한 곳에서 강제한다.
-- 반환값: 삽입된 알림 id, 또는 null(수신 거부 / dedupe 충돌).
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
  v_id uuid;
begin
  if p_user_id is null or p_dedupe_key is null then
    return null;
  end if;
  if not public.notification_enabled(p_user_id, p_type) then
    return null;
  end if;

  perform set_config('runnit.server_write', 'on', true);

  insert into public.notifications (user_id, type, title, body, payload, dedupe_key)
  values (
    p_user_id, p_type, p_title, p_body,
    coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('route', p_route),
    p_dedupe_key
  )
  on conflict (user_id, dedupe_key) do nothing
  returning id into v_id;

  perform set_config('runnit.server_write', 'off', true);

  return v_id;
end;
$$;

comment on function public.enqueue_notification(
  uuid, public.notification_type, text, text, text, jsonb, text) is
  '알림 발행의 **유일한 진입점**. NT-08 필터 + dedupe_key 멱등 + route payload 주입을 '
  '한 곳에서 강제한다. 충돌하거나 수신 거부면 null 을 반환하고 아무것도 하지 않는다. '
  '⚠️ 여기서 하는 것은 알림함 insert 까지이며, 실제 FCM 발송은 47번 디스패처가 '
  '**트랜잭션 밖에서** 담당한다 — 발송 실패가 러닝 저장 트랜잭션을 깨면 안 된다.';

revoke execute on function public.enqueue_notification(
  uuid, public.notification_type, text, text, text, jsonb, text)
  from public, anon, authenticated;
