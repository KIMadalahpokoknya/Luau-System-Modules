--!strict
--[[
    RbxHttpAuth v1  ·  Kimtan / CukingStudio
    ---------------------------------------------------------------
    Cara aman memanggil API Roblox (thumbnail, group, economy) dari dalam
    game. ATURAN KERAS: cookie `.ROBLOSECURITY` dan CSRF token tidak boleh
    berada di tempat yang bisa dibaca exploit (ScriptService/ReplicatedStorage).

    Alur yang dipakai:
        Server (Luau)   ->   proxy kecil (Cloudflare Worker)   ->   *.roblox.com
        (bearer token)       (pegang cookie + CSRF, cache, rate limit)

    Kenapa tidak HttpService:PostAsync langsung ke roblox.com?
      1. Endpoint tulis butuh `X-CSRF-TOKEN` + cookie -> token bocor kalau disimpan di game.
      2. Budget HttpService 500 request/menit per server -> wajib cache + dedupe.
      3. Proxy bikin rotasi kredensial tanpa publish ulang place.

    Bagian bawah file ini berisi worker proxy-nya (±40 baris, deploy gratis).
]]

local HttpService = game:GetService("HttpService")

local const_BASE = "https://cuking-proxy.YOUR-ACCOUNT.workers.dev"   -- TODO: URL worker kamu
local const_BEARER = "ganti-dengan-service-token"                    -- harus sama dengan env WORKER_TOKEN
local const_RETRIES = 3

local RbxHttpAuth = {
    _cache = {} :: { [string]: { at: number, ttl: number, data: any } },
    _failCount = 0 :: number,
}

local function retryDelay(attempt: number): number
    return 0.4 * 2 ^ (attempt - 1) + Random.new():NextNumber(0, 0.25)
end

local function headers(): { [string]: string }
    return {
        ["Authorization"] = "Bearer " .. const_BEARER,
        ["Accept"] = "application/json",
    }
end

local function request(path: string, method: string?, body: string?): (boolean, any)
    local url = const_BASE .. path
    for attempt = 1, const_RETRIES do
        local ok, result = pcall(function()
            return HttpService:RequestAsync({
                Url = url,
                Method = method or "GET",
                Headers = headers(),
                Body = body,
            })
        end)

        if ok and typeof(result) == "table" then
            if result.Success then
                local decodedOk, decoded = pcall(function()
                    return HttpService:JSONDecode(result.Body)
                end)
                if decodedOk then
                    return true, decoded
                end
                return false, "body bukan JSON"
            elseif result.StatusCode == 429 then
                RbxHttpAuth._failCount += 1
                task.wait(2 + attempt * 2)                -- hormati rate limit proxy
                continue
            elseif result.StatusCode == 403 then
                return false, "token proxy salah / kadaluarsa"
            else
                RbxHttpAuth._failCount += 1
            end
        else
            RbxHttpAuth._failCount += 1
        end

        if attempt < const_RETRIES then
            task.wait(retryDelay(attempt))
        end
    end
    return false, "semua percobaan gagal"
end

--[[ GET dengan cache + stale-if-error: data lama lebih berguna daripada kosong.
     ttl default 60s; untuk thumbnail 300s sudah cukup (avatar jarang berubah). ]]
function RbxHttpAuth.cachedGet(path: string, ttl: number?): (boolean, any)
    local seconds = ttl or 60
    local hit = RbxHttpAuth._cache[path]
    if hit and (os.clock() - hit.at) < hit.ttl then
        return true, hit.data
    end

    local ok, data = request(path)
    if ok then
        RbxHttpAuth._cache[path] = { at = os.clock(), ttl = seconds, data = data }
        return true, data
    end
    if hit then
        warn(`[RbxHttpAuth] {path} gagal, pakai cache berumur {math.floor(os.clock() - hit.at)}s`)
        return true, hit.data
    end
    return false, data
end

function RbxHttpAuth.post(path: string, payload: { [string]: any }): (boolean, any)
    return request(path, "POST", HttpService:JSONEncode(payload))
end

---- endpoint siap pakai --------------------------------------------------

function RbxHttpAuth.avatarHeadshot(userIds: { number }): (boolean, any)
    return RbxHttpAuth.cachedGet(`/v1/thumbnails/avatar-headshot?userIds={table.concat(userIds, ",")}&size=150x150&format=Png`, 300)
end

function RbxHttpAuth.userInfo(userId: number): (boolean, any)
    return RbxHttpAuth.cachedGet(`/v1/users/{userId}`, 600)
end

function RbxHttpAuth.groupMemberCount(groupId: number): (boolean, any)
    return RbxHttpAuth.cachedGet(`/v1/groups/{groupId}/member-count`, 120)
end

function RbxHttpAuth.premiumStatus(userId: number): (boolean, any)
    return RbxHttpAuth.cachedGet(`/v1/users/{userId}/premium`, 600)
end

--[[ Pakaian proxy: 1 file, deploy `wrangler deploy`. Cookie Roblox hanya
     hidup di environment worker, tidak pernah masuk ke game.

     // wrangler.toml
     name = "cuking-proxy"
     [vars]
     WORKER_TOKEN = "samakan-dengan-const_BEARER"
     [secrets]  # npx wrangler secret put ROBLOX_COOKIE

     export default {
       async fetch(req, env) {
         if (req.headers.get("authorization") !== "Bearer " + env.WORKER_TOKEN)
           return new Response("forbidden", { status: 403 });

         const path = new URL(req.url).pathname.replace(/^\/v1/, "");
         const upstream = `https://users.roblox.com${path}`;   // atau thumbnails./groups.

         const csrf = await ensureCsrf(env);
         const res = await fetch(upstream, {
           method: req.method,
           headers: {
             "cookie": env.ROBLOX_COOKIE,
             "x-csrf-token": csrf,
             "content-type": "application/json",
           },
         });
         // 403 "TokenValidated" dari Roblox = CSRF basi -> refresh 1x lalu ulangi
         return new Response(res.body, {
           status: res.status,
           headers: { "cache-control": "public, max-age=30" },
         });
       },
     };
]]

return RbxHttpAuth
