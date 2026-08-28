// =============================================================================
// Runnit :: push-dispatch — FCM HTTP v1 발송 워커
// -----------------------------------------------------------------------------
// ⚠️ 이 프로젝트에서 **유일한 Edge Function** 이며, ARCHITECTURE §5("Deno Edge
//    Function 을 쓰지 않는다")의 명시적 예외다. 도입 근거는
//    supabase/migrations/20260828190300_47_push_dispatch.sql 헤더에 있다. 요약:
//    FCM HTTP v1 은 서비스 계정 JWT 를 RS256 으로 서명해야 하는데 Postgres 에는
//    RSA 서명 수단이 없다(pgjwt = HMAC 전용). 레거시 server-key API 는 폐지됐다.
//
// ⚠️ **여기에 제품 판정을 넣지 말 것.**
//    누구에게 무엇을 언제 보낼지는 마이그레이션 44~46 의 SQL 이 전부 결정해
//    `notifications` 행으로 확정한 뒤다. 이 파일이 하는 일은 세 가지뿐이다:
//      ① claim_push_batch() 로 확정된 행을 받아온다
//      ② FCM 에 전달한다
//      ③ 결과를 mark_push_result() / prune_push_token() 으로 되돌려 기록한다
//    조건을 여기 추가하면 판정 로직이 SQL 과 Deno 두 곳으로 갈라지고, 그 순간
//    "알림함에는 있는데 푸시는 안 온다"의 원인을 두 곳에서 찾아야 한다.
//
// 필요한 시크릿 (supabase secrets set)
//   FCM_SERVICE_ACCOUNT   서비스 계정 JSON 전체(문자열)
//   SUPABASE_URL          (런타임 기본 제공)
//   SUPABASE_SERVICE_ROLE_KEY (런타임 기본 제공)
// =============================================================================

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

interface PushRow {
  notification_id: string;
  user_id: string;
  /** `public.notification_type` 라벨. 클라이언트가 성취 계열을 판정하는 유일한 근거다. */
  type: string;
  title: string;
  body: string;
  payload: Record<string, unknown> | null;
  tokens: string[];
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// 액세스 토큰은 1시간 만료다. 매 요청마다 새로 발급하면 배치 1회당 RS256 서명 +
// 왕복 1회가 낭비된다. 인스턴스 수명 동안 캐시한다.
let cachedToken: { value: string; expiresAt: number } | null = null;

function pemToDer(pem: string): Uint8Array {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(b64);
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

function b64url(bytes: Uint8Array | string): string {
  const s = typeof bytes === "string"
    ? bytes
    : String.fromCharCode(...bytes);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function getAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expiresAt > now + 60) return cachedToken.value;

  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(`${header}.${claim}`),
  ));

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claim}.${b64url(sig)}`,
    }),
  });
  if (!res.ok) throw new Error(`oauth ${res.status}: ${await res.text()}`);

  const json = await res.json();
  cachedToken = { value: json.access_token, expiresAt: now + 3300 };
  return cachedToken.value;
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
    },
    body: JSON.stringify(args),
  });
  if (!res.ok) throw new Error(`${fn} ${res.status}: ${await res.text()}`);
  return await res.json() as T;
}

Deno.serve(async (req) => {
  // pg_cron -> pg_net 이 service_role 키로 부른다. 그 외 호출은 거절한다.
  const auth = req.headers.get("Authorization") ?? "";
  if (auth !== `Bearer ${SERVICE_ROLE}`) {
    return new Response("unauthorized", { status: 401 });
  }

  const sa: ServiceAccount = JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT")!);
  const limit = (await req.json().catch(() => ({}))).limit ?? 100;

  const rows = await rpc<PushRow[]>("claim_push_batch", { p_limit: limit });
  if (rows.length === 0) return Response.json({ claimed: 0 });

  const token = await getAccessToken(sa);
  const endpoint =
    `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;

  let sent = 0;
  let failed = 0;

  for (const row of rows) {
    // 문구는 서버(SQL)가 이미 완성했다. 여기서 조립하지 않는다 — 조립하면 푸시
    // 트레이 문구와 알림함 문구가 갈라져 같은 사건이 두 가지로 보인다.
    // data 는 전부 문자열이어야 한다(FCM v1 제약).
    //
    // ⚠️ `type`은 payload에서 오지 않는다 — `notifications.type` 컬럼을 그대로 싣는다.
    //    클라이언트(`push_messaging.dart`)는 `message.data['type']`으로 종류를 판정해
    //    성취 계열(NT-01·NT-06)의 인앱 배너를 생략한다. 이 키가 없으면 배너가 뜨고
    //    몇 초 뒤 `AchievementCelebrationHost`가 풀페이지 축하를 또 띄워 **같은 사건을
    //    두 번** 알린다(ARCHITECTURE §7.4.1 "소비 지점은 하나"가 깨진다). 딥링크
    //    폴백도 종류별 목적지를 잃고 전부 알림함으로 떨어진다. — QA C-2
    //    payload 뒤가 아니라 **먼저** 쓰고 payload로 덮이지 않게 나중에 한 번 더 박는다.
    const data: Record<string, string> = {
      notification_id: row.notification_id,
      type: row.type,
    };
    for (const [k, v] of Object.entries(row.payload ?? {})) {
      if (v !== null && v !== undefined) data[k] = String(v);
    }
    data.type = row.type;

    let lastError: string | null = null;
    let anyOk = false;

    for (const t of row.tokens) {
      const res = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          message: {
            token: t,
            notification: { title: row.title, body: row.body },
            data,
            android: { priority: "HIGH" },
            apns: { headers: { "apns-priority": "10" } },
          },
        }),
      });

      if (res.ok) {
        anyOk = true;
        continue;
      }

      const text = await res.text();
      lastError = `${res.status} ${text.slice(0, 200)}`;

      // 토큰이 죽은 경우가 유일한 정리 시점이다(architect §1.4). 클라이언트는 이
      // 사실을 알 수 없고 다음 실행의 onTokenRefresh 로 자연 복구된다.
      if (
        res.status === 404 ||
        text.includes("UNREGISTERED") ||
        text.includes("INVALID_ARGUMENT")
      ) {
        await rpc("prune_push_token", { p_token: t });
      }
    }

    // 기기 하나라도 성공하면 발송 성공으로 본다. 한 대가 죽은 토큰이라고 해서
    // 살아 있는 다른 기기에 재발송하면 중복 알림이 된다.
    if (anyOk) {
      await rpc("mark_push_result", { p_id: row.notification_id, p_error: null });
      sent++;
    } else {
      await rpc("mark_push_result", {
        p_id: row.notification_id,
        p_error: lastError ?? "no_delivery",
      });
      failed++;
    }
  }

  return Response.json({ claimed: rows.length, sent, failed });
});
