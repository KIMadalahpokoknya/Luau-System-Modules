--!strict
--[[
    ProfileStore v2  ·  Kimtan / CukingStudio
    ---------------------------------------------------------------
    Pembungkus DataStore untuk data pemain: session lock, retry dengan
    exponential backoff + jitter, operasi `update` (bukan set), flush saat
    server ditutup, dan cache baca supaya tidak ada write-then-read mahal.

    Kenapa tidak pakai :SetAsync()?
      SetAsync menimpa data milik session lain (biar tidak duplikasi item).
      UpdateAsync + session lock memastikan satu penulis per pemain.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local PROFILE_STORE = DataStoreService:GetDataStore("CukingStudio_Profiles_v2")
local const_RETRIES = 4
local const_BACKOFF_BASE = 0.5          -- detik: 0.5 / 1 / 2 / 4 (+ jitter)
local const_LOCK_TTL = 90               -- detik: lock lebih tua dari ini dianggap ditinggal crash

export type Profile = {
    version: number,
    cash: number,
    inventory: { [string]: number },
    lastSeen: number,
    lockedBy: string?,
    lockedAt: number?,
}

local defaultProfile: Profile = {
    version = 2,
    cash = 0,
    inventory = {},
    lastSeen = os.time(),
}

local ProfileStore = {
    _cache = {} :: { [number]: Profile },
    _dirty = {} :: { [number]: boolean },
}

local function keyFor(userId: number): string
    return "u_" .. userId
end

-- backoff + jitter: 20 server tidak boleh retry serentak (throttling makin parah)
local function retryDelay(attempt: number): number
    return (const_BACKOFF_BASE * 2 ^ (attempt - 1)) + (Random.new():NextNumber(0, 0.35))
end

local function callWithRetry(label: string, fn: () -> any): (boolean, any)
    local lastErr: any = "unknown"
    for attempt = 1, const_RETRIES do
        local ok, result = pcall(fn)
        if ok then
            return true, result
        end
        lastErr = result
        warn(`[ProfileStore] {label} gagal (percobaan {attempt}/{const_RETRIES}): {tostring(lastErr)}`)
        if attempt < const_RETRIES then
            task.wait(retryDelay(attempt))
        end
    end
    return false, nil
end

--[[ Session lock: penulis tunggal. Nilai lockedBy = nil berarti tidak ada yang memegang. ]]
local function acquireLock(userId: number): (boolean, Profile?)
    local ownerId = tostring(game.JobId) .. ":" .. tostring(RunService:Identity())

    local ok, latest = callWithRetry("readForLock", function()
        return PROFILE_STORE:GetAsync(keyFor(userId))
    end)

    if not ok then
        -- DataStore mati total: tetap izinkan pemain main, jangan kunci dia di lobby.
        warn("[ProfileStore] baca gagal, lanjut tanpa lock (risiko overwrite kecil)")
        return true, nil
    end

    local data = latest :: Profile?
    if data and data.lockedBy and data.lockedBy ~= ownerId then
        local stale = (os.time() - (data.lockedAt or 0)) > const_LOCK_TTL
        if not stale then
            return false, data          -- masih dipegang session lain -> jangan load
        end
    end

    local merged = data or table.clone(defaultProfile)
    merged.lockedBy = ownerId
    merged.lockedAt = os.time()

    callWithRetry("writeLock", function()
        PROFILE_STORE:SetAsync(keyFor(userId), merged)
    end)
    return true, merged
end

function ProfileStore.load(player: Player): Profile?
    local acquired, data = acquireLock(player.UserId)
    if not acquired then
        return nil                      -- pemanggil wajib menangani (mis. "coba lagi 5 detik")
    end
    local profile = data or table.clone(defaultProfile)
    ProfileStore._cache[player.UserId] = profile
    ProfileStore._dirty[player.UserId] = false
    return profile
end

--[[ Cara benar menulis data: berikan fungsi mutator, engine yang me-resolve konflik.
     UpdateAsync otomatis mencoba ulang sampai 10x di sisi Roblox = hemat kuota request. ]]
function ProfileStore.update(player: Player, mutator: ((Profile) -> ())?): (boolean, Profile?)
    local profile = ProfileStore._cache[player.UserId]
    if not profile then
        return false, nil
    end

    local ok, saved = callWithRetry("update", function()
        return PROFILE_STORE:UpdateAsync(keyFor(player.UserId), function(old: Profile?)
            local base = old or table.clone(defaultProfile)
            base.version = profile.version
            base.cash = profile.cash
            base.inventory = profile.inventory
            base.lastSeen = os.time()
            if mutator then
                mutator(base)
            end
            base.lockedBy = nil
            base.lockedAt = nil
            return base, "SET"
        end)
    end)

    if ok and saved then
        ProfileStore._cache[player.UserId] = saved :: Profile
        ProfileStore._dirty[player.UserId] = false
    end
    return ok, saved
end

function ProfileStore.markDirty(player: Player)
    ProfileStore._dirty[player.UserId] = true
end

-- simpan bertahap: 1 pemain per beberapa tick, hindari spike write saat server ramai
function ProfileStore.flushAll(reason: string)
    local flushed = 0
    for userId, dirty in ProfileStore._dirty do
        if dirty then
            local player = Players:GetPlayerByUserId(userId)
            if player then
                ProfileStore.update(player, nil)
                flushed += 1
            end
            task.wait(0.05)
        end
    end
    if flushed > 0 then
        print(`[ProfileStore] flush {flushed} profil ({reason})`)
    end
end

function ProfileStore.bind()
    Players.PlayerRemoving:Connect(function(player)
        ProfileStore.update(player, nil)
        ProfileStore._cache[player.UserId] = nil
        ProfileStore._dirty[player.UserId] = nil
    end)

    game:BindToClose(function()
        if RunService:IsStudio() then
            task.wait(2)
            return
        end
        ProfileStore.flushAll("BindToClose")
    end)
end

return ProfileStore
