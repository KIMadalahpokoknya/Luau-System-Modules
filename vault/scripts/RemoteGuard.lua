--!strict
--[[
    RemoteGuard  ·  Kimtan / CukingStudio
    ---------------------------------------------------------------
    Prinsip: setiap RemoteEvent / RemoteFunction dianggap MUSUH.
    Modul ini memaksa tiap remote punya rate limit, cek tipe argumen,
    dan clamp nilai SEBELUM logika game jalan. Tanpa ini, satu
    exploit script bisa spam "giveItem" 200x/detik atau kirim angka minus.

    Pemakaian:
        local Guard = require(ReplicatedStorage.RemoteGuard)

        Guard.declare("buyItem", {
            rate = 6, burst = 2,
            args = {
                { kind = "string", max = 48, enum = { "sword", "shield", "potion" } },
                { kind = "number", min = 1, max = 99 },
            },
        }, function(player: Player, itemId: string, qty: number)
            Shop.buy(player, itemId, qty)
        end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local const_STRIKE_LIMIT = 12          -- pelanggaran beruntun -> kick
local const_WINDOW = 1                 -- detik
local const_DEFAULT_RATE = 10          -- request per detik kalau rule tidak menyebut

type ArgRule = {
    kind: "string" | "number" | "boolean" | "Vector3" | "Instance",
    max: number?,
    min: number?,
    class: string?,
    enum: { any }?,
}

type RemoteRule = {
    rate: number?,
    burst: number?,
    args: { ArgRule }?,
    public: boolean?,                  -- true = boleh dipanggil sebelum profil siap
    mode: "event" | "function"?,
}

local RemoteGuard = {
    _rules = {} :: { [string]: RemoteRule },
    _buckets = {} :: { [string]: { [Player]: { tokens: number, last: number } } },
    _strikes = {} :: { [Player]: number },
    _onReject = nil :: ((Player, string, string) -> ())?,
}

local function typeOk(value: any, rule: ArgRule): boolean
    if rule.kind == "string" then
        if typeof(value) ~= "string" then
            return false
        end
        if #value == 0 then
            return false
        end
        if rule.max and #value > rule.max then
            return false
        end
    elseif rule.kind == "number" then
        if typeof(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
            return false                          -- NaN / inf = manipulasi
        end
        if rule.min and value < rule.min then
            return false
        end
        if rule.max and value > rule.max then
            return false
        end
    elseif rule.kind == "boolean" then
        if typeof(value) ~= "boolean" then
            return false
        end
    elseif rule.kind == "Vector3" then
        if typeof(value) ~= "Vector3" then
            return false
        end
        if rule.max and value:Magnitude() > rule.max then
            return false
        end
    elseif rule.kind == "Instance" then
        if typeof(value) ~= "Instance" then
            return false
        end
        if rule.class and not value:IsA(rule.class) then
            return false
        end
    end

    if rule.enum then
        local found = false
        for _, allowed in rule.enum do
            if allowed == value then
                found = true
                break
            end
        end
        if not found then
            return false
        end
    end
    return true
end

-- token bucket > "max N per detik" mentah: kasih ruang untuk klik ganda yang sah
local function rateOk(name: string, player: Player, rule: RemoteRule): boolean
    local rate = rule.rate or const_DEFAULT_RATE
    local burst = rule.burst or 1
    local capacity = rate * const_WINDOW + burst

    local buckets = RemoteGuard._buckets[name]
    if not buckets then
        buckets = {}
        RemoteGuard._buckets[name] = buckets
    end

    local now = os.clock()
    local bucket = buckets[player]
    if not bucket then
        buckets[player] = { tokens = capacity - 1, last = now }
        return true
    end

    bucket.tokens = math.min(capacity, bucket.tokens + (now - bucket.last) * rate)
    bucket.last = now

    if bucket.tokens < 1 then
        return false
    end
    bucket.tokens -= 1
    return true
end

local function punish(player: Player, name: string, why: string)
    local strikes = (RemoteGuard._strikes[player] or 0) + 1
    RemoteGuard._strikes[player] = strikes
    warn(`[RemoteGuard] {player.Name} -> {name}: {why} (strike {strikes}/{const_STRIKE_LIMIT})`)
    if RemoteGuard._onReject then
        task.spawn(RemoteGuard._onReject, player, name, why)
    end
    if strikes >= const_STRIKE_LIMIT then
        player:Kick("Aktivitas tidak valid terdeteksi. Hubungi owner jika ini salah.")
    end
end

function RemoteGuard.onReject(callback: (Player, string, string) -> ())
    RemoteGuard._onReject = callback
end

function RemoteGuard.validate(name: string, player: Player, ...: any): boolean
    local rule = RemoteGuard._rules[name]
    if not rule then
        warn(`[RemoteGuard] remote "{name}" dipakai tanpa declare() -> ditolak`)
        return false
    end

    if not rule.public and player:GetAttribute("ProfileReady") ~= true then
        punish(player, name, "dipanggil sebelum profil siap")
        return false
    end

    if not rateOk(name, player, rule) then
        punish(player, name, "rate limit lewat")
        return false
    end

    local args = { ... }
    if rule.args then
        if #args > #rule.args then
            punish(player, name, "argumen berlebih")
            return false
        end
        for index, argRule in rule.args do
            if not typeOk(args[index], argRule) then
                punish(player, name, `arg #{index} tidak valid`)
                return false
            end
        end
    end
    return true
end

function RemoteGuard.declare(name: string, rule: RemoteRule, handler: (Player, ...any) -> any?): Instance
    RemoteGuard._rules[name] = rule

    local folder = ReplicatedStorage:FindFirstChild("GuardedRemotes")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "GuardedRemotes"
        folder.Parent = ReplicatedStorage
    end

    local mode = rule.mode or "event"
    if mode == "function" then
        local remote = Instance.new("RemoteFunction")
        remote.Name = name
        remote.OnServerInvoke = function(player, ...)
            if not RemoteGuard.validate(name, player, ...) then
                return nil
            end
            return handler(player, ...)
        end
        remote.Parent = folder
        return remote
    end

    local remote = Instance.new("RemoteEvent")
    remote.Name = name
    remote.OnServerEvent:Connect(function(player, ...)
        if not RemoteGuard.validate(name, player, ...) then
            return
        end
        handler(player, ...)
    end)
    remote.Parent = folder
    return remote
end

Players.PlayerRemoving:Connect(function(player)
    RemoteGuard._strikes[player] = nil
    for _, buckets in RemoteGuard._buckets do
        buckets[player] = nil
    end
end)

return RemoteGuard
