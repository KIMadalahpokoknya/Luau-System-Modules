--!strict
--[[
    PerfProbe v1  ·  Kimtan / CukingStudio
    ---------------------------------------------------------------
    Ukur dulu, baru optimasi. Modul ini menangkap 3 hal yang paling sering
    bikin Roblox game patah-patah: waktu frame, fungsi yang lewat budget,
    dan pertumbuhan memory (indikasi leak).

    Kenapa persentil, bukan rata-rata? Rata-rata menyembunyikan spike.
    p95 = "5 dari 100 frame terasa jelek" -> itu yang dikeluhkan pemain.

    Cara pakai:
        local Probe = require(ReplicatedStorage.PerfProbe)
        Probe.start()

        Probe.begin("pathfinding")
        updateAllAgents()
        Probe.end("pathfinding")

        task.spawn(function()
            while true do
                task.wait(5)
                print(Probe.report())
            end
        end)

    Lalu buka Microprofiler (Ctrl+Shift+P -> Start/Stop MicroProfiler) untuk
    melihat baris mana yang makan waktu, dan Performance UI (Alt+P) untuk
    angka engine sebagai pembanding.
]]

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local const_REPORT_EVERY = 10                    -- detik
local const_HISTORY = 240                         -- sampel (~4 detik di 60fps)
local const_BUDGET_MS = (1 / 60 * 1000) * 0.8    -- 60 fps dengan 20% headroom
local const_LEAK_KB_PER_SEC = 12                  -- di atas ini curiga leak

type Mark = {
    frames: { number },
    t0: number?,
    lastWarn: number,
    calls: number,
}

export type Stats = { n: number, mean: number, p50: number, p95: number, p99: number, max: number }

local PerfProbe = {
    _marks = {} :: { [string]: Mark },
    _frameTimes = {} :: { number },
    _memSamples = {} :: { number },
    _started = false,
    _paused = false,
}

local function percentile(sorted: { number }, p: number): number
    if #sorted == 0 then
        return 0
    end
    local index = math.clamp(math.ceil(#sorted * p), 1, #sorted)
    return sorted[index]
end

local function statsOf(values: { number }): Stats
    local copy = table.clone(values)
    table.sort(copy)
    local sum = 0
    for _, v in copy do
        sum += v
    end
    local n = #copy
    return {
        n = n,
        mean = if n > 0 then sum / n else 0,
        p50 = percentile(copy, 0.50),
        p95 = percentile(copy, 0.95),
        p99 = percentile(copy, 0.99),
        max = copy[n] or 0,
    }
end

local function fmt(ms: number): string
    return string.format("%.2fms", ms)
end

function PerfProbe.begin(label: string)
    if PerfProbe._paused then
        return
    end
    local mark = PerfProbe._marks[label]
    if not mark then
        mark = { frames = {}, t0 = nil, lastWarn = 0, calls = 0 }
        PerfProbe._marks[label] = mark
    end
    mark.calls += 1
    mark.t0 = os.clock()
end

function PerfProbe.finish(label: string)
    local mark = PerfProbe._marks[label]
    if not mark or not mark.t0 then
        return
    end
    local ms = (os.clock() - mark.t0) * 1000
    mark.t0 = nil

    table.insert(mark.frames, ms)
    if #mark.frames > const_HISTORY then
        table.remove(mark.frames, 1)
    end

    if ms > const_BUDGET_MS and (os.clock() - mark.lastWarn) > 5 then
        mark.lastWarn = os.clock()
        warn(`[PerfProbe] {label} {fmt(ms)} lewat budget {fmt(const_BUDGET_MS)}`)
    end
end

-- alias baca: `finish` karena `end` kata kunci di Luau
PerfProbe.stop = PerfProbe.finish

--[[ Bungkus fungsi tanpa mengubah signature: berguna untuk hot path lama. ]]
function PerfProbe.wrap(label: string, fn: (...any) -> ...any): (...any) -> ...any
    return function(...)
        PerfProbe.begin(label)
        local results = { fn(...) }
        PerfProbe.finish(label)
        return table.unpack(results)
    end
end

function PerfProbe.pause(value: boolean)
    PerfProbe._paused = value
end

function PerfProbe.reset(label: string?)
    if label then
        PerfProbe._marks[label] = nil
    else
        table.clear(PerfProbe._marks)
        table.clear(PerfProbe._frameTimes)
        table.clear(PerfProbe._memSamples)
    end
end

function PerfProbe.report(): string
    local frames = statsOf(PerfProbe._frameTimes)
    local lines = {
        `── PerfProbe · {if RunService:IsServer() then "server" else "client"} ──`,
        `frame  p50 {fmt(frames.p50)}  p95 {fmt(frames.p95)}  p99 {fmt(frames.p99)}  max {fmt(frames.max)}  n={frames.n}`,
        `fps ~ {math.floor(1000 / math.max(frames.p50, 0.1))}   (budget per frame {fmt(const_BUDGET_MS)})`,
    }

    local labels = {}
    for label in PerfProbe._marks do
        table.insert(labels, label)
    end
    table.sort(labels, function(a, b)
        return statsOf(PerfProbe._marks[a].frames).p95 > statsOf(PerfProbe._marks[b].frames).p95
    end)

    for _, label in labels do
        local mark = PerfProbe._marks[label]
        if #mark.frames > 0 then
            local s = statsOf(mark.frames)
            table.insert(lines, `  · {label}: p50 {fmt(s.p50)}  p95 {fmt(s.p95)}  max {fmt(s.max)}  x{s.n}`)
        end
    end

    if #PerfProbe._memSamples >= 2 then
        local first = PerfProbe._memSamples[1]
        local last = PerfProbe._memSamples[#PerfProbe._memSamples]
        local spanSec = (#PerfProbe._memSamples - 1) * const_REPORT_EVERY
        local slopeKB = (last - first) / math.max(1, spanSec)
        table.insert(lines, `  lua-mem {string.format("%.1f", last / 1024)}MB  tren {string.format("%+.1f", slopeKB)}KB/s`)
        if slopeKB > const_LEAK_KB_PER_SEC then
            table.insert(lines, "  ⚠ memory naik terus: cek connection yang tidak di-Disconnect & table yang ditahan player")
        end
    end

    return table.concat(lines, "\n")
end

function PerfProbe.start()
    if PerfProbe._started then
        return
    end
    PerfProbe._started = true

    RunService.Heartbeat:Connect(function(dt)
        if PerfProbe._paused then
            return
        end
        table.insert(PerfProbe._frameTimes, dt * 1000)
        if #PerfProbe._frameTimes > const_HISTORY then
            table.remove(PerfProbe._frameTimes, 1)
        end
    end)

    task.spawn(function()
        while true do
            task.wait(const_REPORT_EVERY)
            if not PerfProbe._paused then
                local memKB = collectgarbage("count")
                table.insert(PerfProbe._memSamples, memKB)
                if #PerfProbe._memSamples > 60 then
                    table.remove(PerfProbe._memSamples, 1)
                end
                print(PerfProbe.report())
                PerfProbe._frameTimes = {}
            end
        end
    end)
end

--[[ Kunci kualitas gambar saat benchmark supaya angka antar-run bisa dibandingkan. ]]
function PerfProbe.setQuality(level: number)
    Lighting.GlobalShadows = level >= 2
    Lighting.Technology = if level >= 1 then Enum.LightingTechnology.Future else Enum.LightingTechnology.Voxel
    settings().PerformanceStats.Visible = level >= 3
end

return PerfProbe
