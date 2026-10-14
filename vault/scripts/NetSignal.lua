--!strict
--[[
    NetSignal v1  ·  Kimtan / CukingStudio
    ---------------------------------------------------------------
    Signal tereplikasi dengan BATCHING per-tick + last-write-wins.

    Masalah nyata: 300-400 RemoteEvent per detik bikin packet loss, menabrak
    throttle ±500 request/detik per klien, dan memakan budget bandwidth.
    Solusi: kumpulkan perubahan dalam 1 tick, buang update yang sudah ditimpa
    oleh update lebih baru untuk slot yang sama, lalu kirim sekaligus.

    Dua mode:
      reliable   -> RemoteEvent            (paket dijamin sampai, berurutan)
      unreliable -> UnreliableRemoteEvent  (untuk data yang boleh bolong:
                                            posisi, HP bar, animasi idle)
                     payload maksimum ±900 byte -> batch diperkecil & yang
                     lama dibuang, bukan dikirim terpisah.

    JANGAN pakai modul ini untuk kejadian yang harus presisi (pemberian item,
    pembayaran, hit registration) -> pakai RemoteEvent reliabel biasa.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local const_TICK = 1 / 30                    -- 30 batch per detik: cukup untuk gameplay
local const_MAX_ITEMS_RELIABLE = 64
local const_MAX_ITEMS_UNRELIABLE = 8        -- jaga payload < ±900 byte
local const_CLASS_UNRELIABLE = "UnreliableRemoteEvent"

type Item = { slot: number, payload: any, target: Player? }

export type NetSignal = {
    name: string,
    fire: (payload: any) -> (),
    fireFor: (player: Player, payload: any) -> (),
    onClient: (callback: (any) -> ()) -> RBXScriptConnection,
    setRelevance: (player: Player, keep: boolean) -> (),
    flush: () -> (),
    destroy: () -> (),
    stats: () -> { batches: number, dropped: number, sent: number, queued: number },
}

local NetSignal = {}

local created = 0

function NetSignal.create(name: string, unreliable: boolean?): NetSignal
    created += 1
    unreliable = unreliable or false

    local remote = Instance.new(if unreliable then const_CLASS_UNRELIABLE else "RemoteEvent") :: RemoteEvent | UnreliableRemoteEvent
    remote.Name = `NetSignal_{name}`
    remote.Parent = ReplicatedStorage

    local maxItems = if unreliable then const_MAX_ITEMS_UNRELIABLE else const_MAX_ITEMS_RELIABLE

    local pending: { Item } = {}
    local relevant: { [Player]: boolean } = {}
    local sequence = 0
    local tickAccum = 0
    local destroyed = false
    local live = { batches = 0, dropped = 0, sent = 0, queued = 0 }

    local function flush()
        if destroyed or #pending == 0 then
            return
        end

        -- last-write-wins: jalan mundur, slot yang sama -> ambil yang paling baru
        local seen: { [number]: boolean } = {}
        local batch: { Item } = {}
        for index = #pending, 1, -1 do
            local item = pending[index]
            if seen[item.slot] then
                live.dropped += 1
            elseif #batch < maxItems then
                seen[item.slot] = true
                table.insert(batch, item)
            else
                live.dropped += 1          -- batch penuh + unreliable: yang lama dibuang
            end
        end
        table.clear(pending)
        live.queued = 0

        if #batch == 0 then
            return
        end

        sequence += 1
        live.batches += 1
        live.sent += #batch

        if unreliable then
            -- satu paket untuk semua: payload kecil, boleh bolong
            (remote :: UnreliableRemoteEvent):FireAllClients(batch)
            return
        end

        -- reliable: pisahkan paket milik semua orang dan paket per pemain
        local generic: { Item } = {}
        for _, item in batch do
            if item.target then
                if relevant[item.target] ~= false then
                    (remote :: RemoteEvent):FireClient(item.target, { item })
                end
            else
                table.insert(generic, item)
            end
        end
        if #generic > 0 then
            (remote :: RemoteEvent):FireAllClients(generic)
        end
    end

    local conn = RunService.Heartbeat:Connect(function(dt)
        tickAccum += dt
        if tickAccum >= const_TICK then
            tickAccum = 0
            flush()
        end
    end)

    local function push(target: Player?, payload: any)
        if destroyed then
            return
        end
        sequence += 1
        table.insert(pending, { slot = sequence, payload = payload, target = target })
        live.queued += 1
        -- anti membengkak kalau jaringan macet: buang yang paling tua
        if live.queued > maxItems * 8 then
            table.remove(pending, 1)
            live.dropped += 1
            live.queued -= 1
        end
    end

    local signal: NetSignal
    signal = {
        name = remote.Name,

        fire = function(payload)
            push(nil, payload)
        end,

        fireFor = function(player, payload)
            if player then
                push(player, payload)
            end
        end,

        onClient = function(callback)
            -- di sisi klien, keduanya memakai OnClientEvent
            local event = (remote :: any).OnClientEvent :: RBXScriptSignal
            return event:Connect(function(items: { Item })
                for _, item in items do
                    callback(item.payload)
                end
            end)
        end,

        setRelevance = function(player, keep)
            relevant[player] = keep
        end,

        flush = flush,

        destroy = function()
            destroyed = true
            conn:Disconnect()
            remote:Destroy()
        end,

        stats = function()
            return table.clone(live)
        end,
    }
    return signal
end

--[[ Helper: panggil saat server mau shut down supaya antrean tidak hilang. ]]
function NetSignal.flushAll(signals: { NetSignal })
    for _, signal in signals do
        signal:flush()
    end
end

return NetSignal
