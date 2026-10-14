--!strict
--[[
    Matchmaking v3  ·  Kimtan / CukingStudio
    ---------------------------------------------------------------
    Antrian 5v5: jendela MMR melebar seiring waktu, prioritas region sama,
    lalu backfill (region longgar -> bot) kalau menunggu kelewatan batas.
    Semua state hidup di server, jadi tidak bisa disuap dari klien.

    Alur:
      1. enqueue(player)
      2. tick 0.5s: kelompokkan kandidat yang sudah menunggu > grace
      3. pilih window 10 pemain dengan selisih rata-rata MMR terkecil
      4. claim -> reserve server -> teleport; gagal = rollback ke antrian
]]

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local const_TICK = 0.5
local const_TEAM_SIZE = 5
local const_GRACE = 2                   -- detik, beri kesempatan antrian membesar dulu
local const_MAX_WAIT = 75               -- detik, setelah ini backfill boleh melanggar region
local const_MMR_GROW = 40               -- tiap 10 detik menunggu, toleransi MMR melebar

type Entry = {
    player: Player,
    mmr: number,
    region: string,
    joinedAt: number,
    isBot: boolean?,
}

local Matchmaking = {
    _queue = {} :: { Entry },
    _locked = {} :: { [Player]: boolean },
}

local REGIONS: { [string]: string } = {
    ID = "asia", SG = "asia", MY = "asia", PH = "asia", TH = "asia", VN = "asia",
    TW = "asia", HK = "asia", JP = "asia", KR = "asia", IN = "asia", AU = "asia",
    US = "amer", CA = "amer", MX = "amer", BR = "amer", AR = "amer", CO = "amer", CL = "amer",
    GB = "emea", DE = "emea", FR = "emea", NL = "emea", PL = "emea", IT = "emea",
    ES = "emea", SE = "emea", RU = "emea", TR = "emea", SA = "emea", AE = "emea", EG = "emea",
}

local function now(): number
    return os.clock()
end

local function regionOf(player: Player): string
    local ok, info = pcall(function()
        return game:GetService("GeoService"):GetGeoInfoAsync(player.UserId)
    end)
    if ok and info and info.CountryCode then
        return REGIONS[string.upper(info.CountryCode)] or "other"
    end
    return "unknown"
end

local function waited(entry: Entry): number
    return now() - entry.joinedAt
end

function Matchmaking.enqueue(player: Player): (boolean, string?)
    if Matchmaking._locked[player] then
        return false, "kamu sudah di antrian"
    end
    for _, entry in Matchmaking._queue do
        if entry.player == player then
            return false, "kamu sudah di antrian"
        end
    end
    table.insert(Matchmaking._queue, {
        player = player,
        mmr = player:GetAttribute("MMR") or 1000,
        region = regionOf(player),
        joinedAt = now(),
    })
    return true, nil
end

function Matchmaking.dequeue(player: Player)
    Matchmaking._locked[player] = nil
    for index = #Matchmaking._queue, 1, -1 do
        if Matchmaking._queue[index].player == player then
            table.remove(Matchmaking._queue, index)
        end
    end
end

local function avgMmr(list: { Entry }): number
    local sum, n = 0, 0
    for _, entry in list do
        if not entry.isBot then
            sum += entry.mmr
            n += 1
        end
    end
    return if n > 0 then sum / n else 0
end

--[[ Kandidat = yang sudah lewat masa grace. Window digeser sepanjang daftar MMR. ]]
function Matchmaking._candidates(): { Entry }
    local out = {}
    for _, entry in Matchmaking._queue do
        if waited(entry) >= const_GRACE then
            table.insert(out, entry)
        end
    end
    table.sort(out, function(a, b)
        return a.mmr < b.mmr
    end)
    return out
end

function Matchmaking._tryForm(): { Entry }?
    local size = const_TEAM_SIZE * 2
    local candidates = Matchmaking._candidates()
    if #candidates < size then
        return nil
    end

    local longestWait = 0
    for _, entry in candidates do
        longestWait = math.max(longestWait, waited(entry))
    end
    local tolerance = 120 + math.floor(longestWait / 10) * const_MMR_GROW

    local best: { Entry }? = nil
    local bestScore = math.huge

    for start = 1, #candidates - size + 1 do
        local window = { table.unpack(candidates, start, start + size - 1) }

        -- tolak kalau spread MMR window lebih lebar dari toleransi
        local spread = window[size].mmr - window[1].mmr
        if spread <= tolerance then
            local regionSeed = window[1].region
            local sameRegion = 0
            for _, entry in window do
                if entry.region == regionSeed then
                    sameRegion += 1
                end
            end
            -- region boleh bolong maksimal 2 slot (kecuali sudah nunggu lama)
            if sameRegion >= size - 2 or longestWait > const_MAX_WAIT then
                local half = math.floor(size / 2)
                local teamA, teamB = {}, {}
                for index, entry in window do
                    table.insert(if index <= half then teamA else teamB, entry)
                end
                local score = math.abs(avgMmr(teamA) - avgMmr(teamB)) + (spread * 0.25)
                if score < bestScore then
                    bestScore = score
                    best = window
                end
            end
        end
    end
    return best
end

--[[ Backfill: antrian terlalu lama -> isi slot kosong, terakhir pakai bot. ]]
function Matchmaking._backfill(window: { Entry }): { Entry }
    local out = table.clone(window)
    local size = const_TEAM_SIZE * 2

    for _, entry in Matchmaking._queue do
        if #out >= size then
            break
        end
        local taken = false
        for _, have in out do
            if have.player == entry.player then
                taken = true
                break
            end
        end
        if not taken then
            table.insert(out, entry)
        end
    end

    while #out < size do
        table.insert(out, { player = nil :: any, mmr = 1000, region = "bot", joinedAt = 0, isBot = true })
    end
    return out
end

function Matchmaking._claim(window: { Entry })
    for _, entry in window do
        if entry.player then
            Matchmaking._locked[entry.player] = true
            for index = #Matchmaking._queue, 1, -1 do
                if Matchmaking._queue[index].player == entry.player then
                    table.remove(Matchmaking._queue, index)
                end
            end
        end
    end
end

function Matchmaking._rollback(window: { Entry }, reason: string)
    warn(`[Matchmaking] {reason} -> kembalikan {#window} pemain ke antrian`)
    for _, entry in window do
        if entry.player and not entry.isBot then
            Matchmaking._locked[entry.player] = nil
            entry.joinedAt = now() - 1          -- boleh langsung dihitung lagi
            table.insert(Matchmaking._queue, entry)
        end
    end
end

function Matchmaking._launch(window: { Entry }, placeId: number)
    Matchmaking._claim(window)

    local ok, reservation = pcall(function()
        return TeleportService:ReserveServer(placeId)
    end)
    if not ok or not reservation then
        Matchmaking._rollback(window, "ReserveServer gagal")
        return
    end

    local payload = HttpService:JSONEncode({
        seed = HttpService:GenerateGUID(false),
        roster = table.fold(window, {}, function(acc, entry)
            if entry.player then
                table.insert(acc, { uid = entry.player.UserId, mmr = entry.mmr, region = entry.region })
            end
            return acc
        end),
    })

    for _, entry in window do
        local player = entry.player
        if player and player.Parent and not entry.isBot then
            task.spawn(function()
                local options = Instance.new("TeleportOptions")
                options:SetShouldRequestPhysics(true)
                local success, err = TeleportService:TeleportAsync(placeId, { player }, options)
                if not success then
                    warn(`[Matchmaking] teleport {player.Name} gagal: {tostring(err)}`)
                    Matchmaking._rollback({ entry }, "teleport gagal")
                end
            end)
        end
    end
    print(`[Matchmaking] launch: {#window} pemain, roster size {#payload} byte`)
end

function Matchmaking.start(getPlaceId: () -> number)
    task.spawn(function()
        while true do
            task.wait(const_TICK)
            local window = Matchmaking._tryForm()
            if window then
                local oldest = 0
                for _, entry in window do
                    oldest = math.max(oldest, waited(entry))
                end
                local final = if oldest > const_MAX_WAIT then Matchmaking._backfill(window) else window
                Matchmaking._launch(final, getPlaceId())
            end
        end
    end)

    Players.PlayerRemoving:Connect(function(player)
        Matchmaking.dequeue(player)
    end)
end

return Matchmaking
