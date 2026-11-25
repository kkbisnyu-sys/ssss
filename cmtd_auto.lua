-- Cameraman Tower Defense auto farm v11 (lobby + match)
-- v11 = v10 detection + every equipped slot (1-5) is used, each unit modelled from the game's own config:
--   attack   : main attack + SecondaryAttacks (+poison), AOE weighted, per-part range
--   farm     : CashPerWave, bought only if it pays back before the mode's last wave
--   booster  : DamageBuff / CooldownBuff (%) applied to the attack towers inside its range
--   medic    : IsMedic, placed only when stunning enemies are coming (mode wave table) or a stun was seen
--   spawner  : Unit / AllyDPS
--   PlacementLimit per unit, global cap 15 (server PlacedTowers)
--   HideDetection: a tower with it cannot hit enemies with it (game rule) -> its value is cut by the hidden share
-- Strategy: every purchase (new tower of any unit, upgrade of any tower) is ranked by value per money;
-- at the unit cap the weakest tower is replaced by a clearly stronger unit (or the same unit on a much better spot).
-- Detection is the server-confirmed layer of v10 (events + Replication snapshot, per-wave reports in cmtd_log.txt).

local DRY = getgenv().CMTD_DRY -- dry run: plan only, send nothing, do not replace a running instance
local AUTO_LOAD = true          -- true: reload this script from GitHub after every teleport (lobby <-> match). false: manual start only
local SELF = getgenv().CMTD_FILE or "https://raw.githubusercontent.com/kkbisnyu-sys/ssss/main/cmtd_auto.lua"
local VIA_QUEUE = getgenv().CMTD_FILE ~= nil -- set only by the teleport loader below
getgenv().CMTD_FILE = nil
if VIA_QUEUE and not AUTO_LOAD then print("[CMTD] auto-load is off: started by an old teleport loader, exiting") return end
if not DRY then
  getgenv().CMTD_RUN = (getgenv().CMTD_RUN or 0) + 1
  for _, c in ipairs(getgenv().CMTD_CONS or {}) do pcall(function() c:Disconnect() end) end
  getgenv().CMTD_CONS = {}
end
getgenv().CMTD_CONS = getgenv().CMTD_CONS or {}
local MYRUN = getgenv().CMTD_RUN or 0
local function alive() return getgenv().CMTD_RUN == MYRUN end
local function keep(c) table.insert(getgenv().CMTD_CONS, c) return c end

local CFG = {
  map          = "TurkeyTown"   , -- lobby: which map's elevators to use
  mode         = "Easy"         ,  -- match vote: "Easy" (20 waves), "HalloweenEasy" (40, event), "Hard"/"HalloweenHard" (55) ...
  maxUnits     = 15,
  allowOnPath  = true,             -- verified in-game: the server accepts towers on the path tiles
  pathMargin   = 2.2,              -- keep tower centre this far outside a path tile (only when allowOnPath=false)
  minGap       = 4.3,              -- tower hitbox is 4x4; centres closer than this overlap
  clusterRadius = 9,               -- units of one kind are placed within this many studs of the first one (one Repair Drone covers them all)
  stack        = true,             -- false: spread to the stretches that lack damage; true: pile the damage together on the best spots
  stackKeep    = 0.85,             -- stack mode: a spot must keep this share of the best free spot's full value (range stays effective); among those the one nearest to the existing damage cluster wins
  spreadGap    = 8,                -- attack towers prefer to stand at least this far apart (good spots first)
  goodShare    = 0.35,             -- a spread spot is 'good' while its NEW damage is at least this share of the best spot's full value; below that: cluster
  reachFloor   = 1,                -- weight of a path stretch nobody reached lately; 1 = off: every enemy must walk through, so all path counts the same (max coverage x dps)
  reachMin     = 8,                -- enemies seen before the reach weights are used
  reachKeep    = 60,               -- the last N enemies decide the reach weights
  liveMed      = 0.7,              -- an enemy alive this far along the path (0..1) -> at least medium pressure, rear spots get a boost
  liveHigh     = 0.85,             -- this far -> high pressure right now (do not wait for the wave to end)
  rearBoost    = 2,                -- weight multiplier for the stretches from (deepest enemy - 30%) to the end while an enemy is deep
  scanStep     = 1,                -- map scan at the start: every spot on a 1-stud grid near the path is evaluated
  refine       = true,             -- then the best grid spot is refined in 0.25-stud steps
  opening      = 1,                -- the first N attack towers (just enough to survive); then farms, unless the pressure is high
  aoeFactor    = 1.6,              -- value multiplier for AOE / cone attacks (they hit several enemies)
  altRatio     = 0.6,              -- while saving for the best buy, take an affordable one that is at least this good
  -- replacement at the unit cap
  strongEff    = 2,                -- strong unit = max-level damage per money at least this many times the cheap unit's
  strongLevel  = 3,                -- a strong unit is placed on its best level-3 spot and raised to L3 before the next one
  farmLead     = 400,              -- farms may be ahead of strong units by this much money invested (they are bought in turns)
  replace      = true,
  replaceRatio = 1.5,              -- new tower's potential must be this many times the victim's
  replacePerWave = 2,
  sellRefund   = 0.5,              -- measured: a tower sells for half of what was spent on it
  -- support units
  useFarms     = true,
  farmPayback  = 1.5,              -- a farm (or farm upgrade) must earn this many times its price before the last wave
  maxFarms     = 7,                -- (also capped by the farm unit's own PlacementLimit)
  farmAfter    = 1,                -- attack towers that must stand before the first farm
  farmSwapShare = 0.08,            -- at the cap: an attack tower adding less than 8% of the defence may become a farm
  -- phases (share of the mode's waves): early = hold the line, mid = make money when calm, late = all-in damage
  earlyEndWave = 14,               -- early phase: waves 1..14 (at most half of a shorter mode): cheapest units, best spots
  earlyMaxShare = 0.5,
  lateStart    = 9,             -- late phase: after 65% of the waves (no farm buys, farms get replaced by damage) ...
  lateMinLast  = -1,               -- ... but at least the middle phase lasts until only the last 6 waves remain
  -- pressure (from the server: leaks and how far enemies got before dying, + the wave table forecast)
  pressMedAvg  = 2,                -- average kill progress above this -> medium (off: the best spots sit mid-path anyway)
  pressMedMax  = 0.85,             -- an enemy got this far before dying -> medium (it nearly slipped through)
  pressHighMax = 0.95,             -- this far (or any leak) -> high
  bossAhead    = 0,                -- a boss in the next N waves -> at least medium (0 = off: the survive margin covers bosses)
  -- forecast "can we survive the next wave": damage the towers can deal to each enemy group / the group's HP
  ecoProg      = 0.5,              -- farms are bought even under forecast pressure while recent enemies all died before this share of the path
  ecoMinMargin = 0.6,              -- ...and the survive-margin forecast is not below this
  marginHigh   = 1.5,              -- below this -> high pressure (buy defence now, cheapest first)
  marginMed    = 2.0,              -- below this -> medium (no farms, defence first)
  laneShare    = 1.5,              -- coverage counts shared stretches twice; one enemy walks ~1/1.5 of it
  boosterAfter = 5,                -- attack towers that must stand before a booster is worth considering
  medicShare   = 0.15,             -- value of a medic = this share of the tower value it can unstun (only with a stun threat)
  spawnerCov   = 15,               -- a spawner's ally counts like this many studs of covered path
  -- detection / bookkeeping
  skip         = "safe",           -- "always" | "safe" (skip unless the pressure is high) | "never"
  skipMaxAlive = 3,                -- optional hard limit on enemies still alive for a "safe" skip (off)
  resyncEvery  = 15,               -- seconds between full server snapshots
  idleWaves    = 3,                -- enemy inside its range but no shot, this many waves in a row -> tower flagged idle
  reportLag    = 5,                -- a wave is reported when all its enemies are resolved, at the latest this many waves later
  placeFails   = 2,                -- real rejections (money and cap fine) before a spot is disabled
  logFile      = "cmtd_log.txt",   -- per-wave reports are appended here (nil = console only)
  tick         = 0.25,
  verbose      = true,
}
local LOBBY, MATCH = 132929771812494, 114068177100380
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer
local MYID = lp.UserId
local ML = RS:WaitForChild("ModuleLoader")
local Net = ML:WaitForChild("Shared"):WaitForChild("Network")
local RE, RF = Net:WaitForChild("RemoteEvent"), Net:WaitForChild("RemoteFunction")

local function log(...) print("[CMTD]", ...) end
local function report(line)
  print("[CMTD]", line)
  if CFG.logFile and appendfile then
    pcall(appendfile, CFG.logFile, os.date("%m-%d %H:%M:%S ") .. line .. "\n")
  end
end

pcall(function() for _, c in ipairs(getconnections(lp.Idled)) do c:Disable() end end)
if AUTO_LOAD then
  pcall(function()
    queue_on_teleport(([[task.wait(4) getgenv().CMTD_FILE = %q pcall(function() loadstring(game:HttpGet(%q))() end)]]):format(SELF, SELF))
  end)
end

local function money()
  local ls = lp:FindFirstChild("leaderstats")
  return ls and ls:FindFirstChild("Money") and ls.Money.Value or 0
end
local function waitFor(cond, timeout)
  local t0 = os.clock()
  while os.clock() - t0 < timeout do
    local r = cond()
    if r then return r end
    task.wait(0.05)
  end
end

---------------------------------------------------------------- SETTINGS + MENU (WindUI)
-- cmtd_settings.json keeps the menu choices across teleports (map, mode, stacking)
local SETTINGS_FILE = "cmtd_settings.json"
local HttpService = game:GetService("HttpService")
local settings = {}
pcall(function()
  if isfile and isfile(SETTINGS_FILE) then
    local t = HttpService:JSONDecode(readfile(SETTINGS_FILE))
    if type(t) == "table" then settings = t end
  end
end)
local function saveSettings()
  pcall(function() if writefile then writefile(SETTINGS_FILE, HttpService:JSONEncode(settings)) end end)
end
if type(settings.map) == "string" and settings.map ~= "" then CFG.map = settings.map end
if type(settings.mode) == "string" and settings.mode ~= "" then CFG.mode = settings.mode end
if CFG.overlap == nil then CFG.overlap = false end -- "auto" = test once whether two towers fit on one spot | true | false
if settings.overlap ~= nil then CFG.overlap = settings.overlap end
local overlapOK = nil -- can towers stand on top of each other? nil = not tested yet
if CFG.overlap == true then overlapOK = true
elseif CFG.overlap == false then overlapOK = false
elseif settings.overlapResult ~= nil and settings.overlapVer == game.PlaceVersion then overlapOK = settings.overlapResult end
local uiStatus = function() end
local uiList = function() return "not in a match" end -- replaced by the match code: what stands on the map right now
local histLog = {}                                       -- last placements / sales
local function pushHist(line)
  table.insert(histLog, 1, os.date("%H:%M:%S ") .. line)
  while #histLog > 16 do table.remove(histLog) end
end
local function setOverlap(v, why)
  overlapOK = v
  settings.overlapResult, settings.overlapVer = v, game.PlaceVersion
  saveSettings()
  report(("OVERLAP TEST: towers %s stand on one spot (%s)"):format(v and "CAN" or "can NOT", why or ""))
  uiStatus()
end

task.spawn(function()
  local ok, err = pcall(function()
    -- the map names come from the lobby elevators (collected once, remembered in the settings file)
    local maps, seen = {}, {}
    local function addMap(n) if type(n) == "string" and n ~= "" and not seen[n] then seen[n] = true maps[#maps+1] = n end end
    for _, n in ipairs(settings.maps or {}) do addMap(n) end
    if game.PlaceId == LOBBY then
      local el = workspace:WaitForChild("Elevators", 15)
      local t0 = os.clock()
      repeat
        for _, m in ipairs(el and el:GetChildren() or {}) do
          local sg = m:FindFirstChild("StatusGui", true)
          local mn = sg and sg:FindFirstChild("MapName")
          if mn then addMap(mn.Text) end
        end
        if #maps > 0 then break end
        task.wait(0.5)
      until os.clock() - t0 > 8
    else
      addMap(workspace:GetAttribute("Map"))
    end
    addMap(CFG.map)
    settings.maps = maps
    saveSettings()
    local modes = {"Easy", "Normal", "Hard", "Insane", "Nightmare", "Thanksgiving"}
    pcall(function()
      local m = require(RS.ModuleLoader.Shared.Modes)
      local list = {}
      for k in pairs(m) do list[#list+1] = tostring(k) end
      table.sort(list)
      if #list > 0 then modes = list end
    end)
    local seenM = {}
    for _, n in ipairs(modes) do seenM[n] = true end
    if not seenM[CFG.mode] then modes[#modes+1] = CFG.mode end

    local raw = game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/refs/heads/main/dist/main.lua")
    raw = raw:gsub('cloneref%(game:GetService%("HttpService"%)%)', '(game:GetService("HttpService") or {JSONEncode=function() return "{}" end, GenerateGUID=function() return "guid" end})')
    raw = raw:gsub("r%[u%]%s*=%s*v", "pcall(function() r[u] = v end)")
    raw = raw:gsub("x%[z%]%s*=%s*A", "pcall(function() x[z] = A end)")
    local WindUI = loadstring(raw)()
    pcall(function() if getgenv().CMTD_UI then getgenv().CMTD_UI:Destroy() end end)
    local Window = WindUI:CreateWindow({
      Title = "CMTD 自動塔防", Icon = "tower-control", Author = "map / mode / stacking",
      Folder = "CMTD", Size = UDim2.fromOffset(520, 420), Transparent = false, Theme = "Dark",
      Keybind = Enum.KeyCode.RightControl, ToggleKey = Enum.KeyCode.RightControl,
    })
    getgenv().CMTD_UI = Window
    local ready = false
    local Tab = Window:Tab({Title = "設定", Icon = "settings"})
    Tab:Dropdown({
      Title = "地圖 Map", Desc = "在大廳進哪一台電梯(清單來自大廳電梯上的地圖名,逛過就會記住)",
      Values = maps, Value = CFG.map,
      Callback = function(v)
        if not ready then return end -- WindUI calls the callbacks while it builds the menu: ignore those
        if type(v) == "table" then v = v[1] end
        if type(v) ~= "string" or v == "" then return end
        CFG.map, settings.map = v, v
        saveSettings()
        WindUI:Notify({Title = "地圖", Content = v .. "(下次在大廳選電梯時生效)", Duration = 3})
      end,
    })
    Tab:Dropdown({
      Title = "模式 Mode", Desc = "投票用的模式名;這一局不會變,下次投票時生效",
      Values = modes, Value = CFG.mode,
      Callback = function(v)
        if not ready then return end -- WindUI calls the callbacks while it builds the menu: ignore those
        if type(v) == "table" then v = v[1] end
        if type(v) ~= "string" or v == "" then return end
        CFG.mode, settings.mode = v, v
        saveSettings()
        WindUI:Notify({Title = "模式", Content = v .. "(下次投票時生效)", Duration = 3})
      end,
    })
    -- game speed (the x1 / x1.5 / x2 buttons at the bottom right): only used if the user picks one here
    local speedValues = {"不改變", "x1", "x1.5", "x2"}
    local function speedTarget(v) return ({["x1"] = 1, ["x1.5"] = 1.5, ["x2"] = 2})[v] end
    local function applySpeed(v, notify)
      local target = speedTarget(v)
      if not target or game.PlaceId ~= MATCH then return end
      if workspace:GetAttribute("GameSpeed") == target then return end
      local ok, res = pcall(function() return RF.ChangeSpeed:InvokeServer(target) end)
      report(("SPEED x%s -> %s"):format(tostring(target), ok and tostring(res) or ("error " .. tostring(res))))
      if notify then
        WindUI:Notify({Title = "遊戲速度", Content = (ok and res) and ("x" .. tostring(target)) or "伺服器沒有接受(可能需要通行證)", Duration = 3})
      end
    end
    Tab:Dropdown({
      Title = "遊戲速度 Speed", Desc = "右下角 x1 / x1.5 / x2。「不改變」= 腳本完全不動速度;選了才會在比賽中套用",
      Values = speedValues, Value = (table.find(speedValues, settings.speed) and settings.speed) or "不改變",
      Callback = function(v)
        if not ready then return end
        if type(v) == "table" then v = v[1] end
        if type(v) ~= "string" or v == "" then return end
        settings.speed = v
        saveSettings()
        applySpeed(v, true)
      end,
    })
    task.spawn(function() -- every match is a new server: re-apply the chosen speed there (3 tries, then give up)
      local tries = 0
      while alive() do
        task.wait(5)
        local want = speedTarget(settings.speed)
        if want and game.PlaceId == MATCH and workspace:GetAttribute("GameSpeed") ~= want and tries < 3 then
          tries += 1
          applySpeed(settings.speed)
        end
      end
    end)
    local HelpTab = Window:Tab({Title = "說明", Icon = "info"})
    HelpTab:Paragraph({Title = "設定分頁", Desc = "地圖:下次在大廳選哪一台電梯。\n模式:下次投票用哪個模式。\n這一局不會變,下次進大廳或投票時才生效,選擇會存檔。"})
    HelpTab:Paragraph({Title = "放置單位分頁", Desc = "即時列出場上每座塔(輸出 / 農場 / 解暈)的等級和座標,下面是最近的放置和賣出紀錄。"})
    HelpTab:Paragraph({Title = "買東西的順序", Desc = "壓力低時(農場是利滾利,越早升越賺):\n1. 只放 1 隻輸出塔\n2. 立刻放農場,並優先升農場(升到回本為止)\n3. 再放其他 Hacked、升到 3 級、放滿 15 隻、升 Drone、Hacked 4 級以上\n4. 全部單位滿級後才把農場換成輸出塔\n壓力中等以上會先買防守,上面的順序暫停。"})
    HelpTab:Paragraph({Title = "位置怎麼選", Desc = "先分散:每隻塔去最缺傷害、又夠好的位置(離其他輸出塔至少 8 格)。\n好位置用完(新增傷害低於最佳位置的 35%)才扎堆在最佳位置旁邊。\n路徑每一段按「最近敵人實際走到哪」加權:敵人常走到後段,後段位置價值就高。"})
    HelpTab:Paragraph({Title = "看得到敵人位置嗎", Desc = "看得到。腳本每 0.5 秒讀場上敵人模型的座標,換算成路徑上的進度。\n敵人走到 70% 以上算壓力中等,85% 以上算壓力高,立刻改買防守,而且後段位置加權 ×2。\n每隻敵人死亡或漏掉時的進度也會記下來,用來決定哪一段路最重要。"})
    HelpTab:Paragraph({Title = "疊塔", Desc = "已測試:伺服器不允許兩座塔放在同一點,放在上面(加高度)也不行。所以腳本一律把塔放在相鄰的最佳位置,這個選項已經拿掉。"})
    local ListTab = Window:Tab({Title = "放置單位", Icon = "layout-list"})
    local NowP = ListTab:Paragraph({Title = "目前場上的單位", Desc = "讀取中..."})
    local HistP = ListTab:Paragraph({Title = "最近放置 / 賣出", Desc = "還沒有紀錄"})
    task.spawn(function()
      while alive() do
        pcall(function() NowP:SetDesc(uiList()) end)
        pcall(function() HistP:SetDesc(#histLog > 0 and table.concat(histLog, "\n") or "還沒有紀錄") end)
        task.wait(2)
      end
    end)
    pcall(function() Tab:Select() end)
    task.delay(2, function() ready = true end)
  end)
  if not ok then report("menu not shown: " .. tostring(err)) end
end)

---------------------------------------------------------------- LOBBY
if game.PlaceId == LOBBY then
  log("lobby mode, map:", CFG.map)
  local function pick()
    for _, m in ipairs(workspace:WaitForChild("Elevators"):GetChildren()) do
      local sg = m:FindFirstChild("StatusGui", true)
      local mn = sg and sg:FindFirstChild("MapName")
      local pc = sg and sg:FindFirstChild("PlayersCount")
      local hb = m:FindFirstChild("Hitbox") or m:FindFirstChildWhichIsA("BasePart")
      if mn and pc and hb and mn.Text == CFG.map and pc.Text:sub(1, 1) == "0" then return m, hb end
    end
  end
  while alive() do
    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    local m, hb = pick()
    if hrp and m then
      hrp.CFrame = hb.CFrame
      task.wait(2) -- the game's own client loop sends ElevatorEnter once we stand inside the hitbox
      local ok, r = pcall(function() return RF.ElevatorStart:InvokeServer(m.Name) end)
      log("start", m.Name, ok, r)
      task.wait(15)
    else
      task.wait(2)
    end
  end
  return
end

if game.PlaceId ~= MATCH then log("unknown place, nothing to do") return end

---------------------------------------------------------------- MATCH: game data
log("match mode v11 (all equipped slots, server-confirmed detection)")
local G = workspace:WaitForChild("Game")
local area -- the real placement zone = the largest part (new maps put small decoration parts in TowerArea too)
for _, p in ipairs(G:WaitForChild("TowerArea"):GetDescendants()) do
  if p:IsA("BasePart") and (not area or p.Size.X * p.Size.Z > area.Size.X * area.Size.Z) then area = p end
end
local topY = area.Position.Y + area.Size.Y / 2
local Base = G:WaitForChild("Base")
local CONF = ML.Configs.Config

local function serverPlaced()
  local v = lp:FindFirstChild("PlacedTowers")
  return v and v.Value or 0
end

local function slots()
  local t = {}
  for i = 1, 5 do
    local n, id = lp:GetAttribute("Slot"..i), lp:GetAttribute("Slot"..i.."Id")
    if n and n ~= "" and id and id ~= "" then t[#t+1] = {name = n, id = id, slot = i} end
  end
  return t
end

-- enemies: base stats, stun ability, hidden flag
local enemyBase = {}
local function loadEnemies()
  if next(enemyBase) then return end
  for _, d in ipairs(CONF.Enemies:GetDescendants()) do
    if d:IsA("ModuleScript") then
      local ok, c = pcall(require, d)
      if ok and type(c) == "table" and c.BaseHealth then
        enemyBase[d.Name] = {hp = c.BaseHealth, speed = c.Speed or 4, hidden = c.HideDetection == true,
                             stun = c.StunRange and {range = c.StunRange, dur = c.StunDuration, cd = c.StunCooldown}}
      end
    end
  end
end

-- the mode's wave table (Shared.Modes[mode]): "WAVE: n" lines followed by "<enemy name> <count> <interval>"
local waves, totalWaves = nil, nil
local function loadWaves()
  if waves then return end
  local ok, modes = pcall(require, ML.Shared.Modes)
  if not ok or type(modes) ~= "table" then return end
  local key = workspace:GetAttribute("Mode") or CFG.mode
  local src = modes[key] or modes[CFG.mode]
  if type(src) ~= "string" then log("no wave table for mode", tostring(key)) return end
  waves, totalWaves = {}, 0
  local cur
  for line in src:gmatch("[^\n]+") do
    local n = line:match("WAVE:%s*(%d+)")
    if n then
      cur = tonumber(n) waves[cur] = {} totalWaves = math.max(totalWaves, cur)
    elseif cur then
      local name, cnt, gap = line:match("^%s*(.-)%s+(%d+)%s+([%d%.]+)%s*$")
      if name and name ~= "" then table.insert(waves[cur], {name = name, count = tonumber(cnt), gap = tonumber(gap) or 1}) end
    end
  end
  log(("wave table %s: %d waves"):format(tostring(src == modes[key] and key or CFG.mode), totalWaves))
end

local curWave = workspace:GetAttribute("Wave") or 0
local function wavesLeft() return math.max(1, (totalWaves or 20) - curWave) end

-- share of the remaining enemy HP that is hidden (HideDetection) -> towers with HideDetection cannot hit it
local hiddenShare = 0
local function updateHidden()
  if not waves then return end
  local all, hid = 0, 0
  for w = math.max(1, curWave), totalWaves do
    for _, e in ipairs(waves[w] or {}) do
      local b = enemyBase[e.name]
      if b then
        local hp = b.hp * e.count * (1 + 0.2 * (w - 1))
        all += hp
        if b.hidden then hid += hp end
      end
    end
  end
  hiddenShare = all > 0 and hid / all or 0
end

local stunSeen = false
local function stunThreat()
  if stunSeen then return true end
  if not waves then return false end
  for w = math.max(1, curWave), math.min(totalWaves, curWave + 8) do
    for _, e in ipairs(waves[w] or {}) do
      local b = enemyBase[e.name]
      if b and b.stun then return true end
    end
  end
  return false
end

-- units: everything the config says, per level
local units = {}
local function loadUnit(name, slotId)
  if units[name] then if slotId then units[name].id = slotId end return units[name] end
  local m
  for _, d in ipairs(CONF.Towers:GetDescendants()) do if d:IsA("ModuleScript") and d.Name == name then m = d break end end
  if not m then return nil end
  local ok, c = pcall(require, m)
  if not ok or type(c) ~= "table" or type(c.Upgrades) ~= "table" then return nil end
  local tags = type(c.Tags) == "table" and c.Tags or {}
  local u = {name = name, id = slotId, limit = c.PlacementLimit or math.huge, blind = c.HideDetection == true, levels = {}}
  local kinds = {}
  for i, up in ipairs(c.Upgrades) do
    local L = {price = up.Price or 0, range = up.Range or 0, parts = {}, cash = up.CashPerWave or 0,
               buffD = up.DamageBuff or 0, buffCD = up.CooldownBuff or 0, buffR = up.RangeBuff or 0,
               medic = up.IsMedic == true, ally = up.AllyDPS or 0, slow = up.SlowPercent or 0}
    if (up.Damage or 0) > 0 and (up.Cooldown or 0) > 0 then
      local dps = up.Damage / up.Cooldown
      if (up.PoisonDamage or 0) > 0 then dps += up.PoisonDamage / up.Cooldown end
      L.parts[#L.parts+1] = {range = up.Range or 0, dps = dps, aoe = up.AOE == true or tags.AOE ~= nil}
    end
    if type(up.SecondaryAttacks) == "table" then
      for _, a in pairs(up.SecondaryAttacks) do
        if type(a) == "table" and (a.Damage or 0) > 0 and (a.Cooldown or 0) > 0 then
          L.parts[#L.parts+1] = {range = a.Range or up.Range or 0, dps = a.Damage / a.Cooldown, aoe = a.AOE == true}
        end
      end
    end
    u.levels[i] = L
    if L.cash > 0 then kinds.farm = true end
    if L.buffD ~= 0 or L.buffCD ~= 0 or L.buffR ~= 0 then kinds.booster = true end
    if L.medic then kinds.medic = true end
    if up.Unit or L.ally > 0 then kinds.spawner = true end
    if #L.parts > 0 then kinds.attack = true end
  end
  u.kind = (tags.Farm or kinds.farm) and "farm" or (tags.Booster or kinds.booster) and "booster"
        or kinds.medic and "medic" or (tags.Spawner or kinds.spawner) and "spawner" or kinds.attack and "attack" or "other"
  u.total = 0
  for _, L in ipairs(u.levels) do u.total += L.price end
  units[name] = u
  local d = {}
  for i, L in ipairs(u.levels) do
    local dps = 0 for _, p in ipairs(L.parts) do dps += p.dps end
    d[#d+1] = ("L%d $%d R%g%s"):format(i, L.price, L.range,
      u.kind == "attack" and (" dps%.0f"):format(dps) or u.kind == "farm" and (" +$%d/wave"):format(L.cash)
      or u.kind == "booster" and (" dmg+%g%% cd%g%%"):format(L.buffD, L.buffCD) or u.kind == "spawner" and (" ally%g"):format(L.ally) or "")
  end
  log(("unit %s [%s] limit %s%s: %s"):format(name, u.kind, u.limit == math.huge and "-" or tostring(u.limit),
    u.blind and " (cannot hit hidden)" or "", table.concat(d, " | ")))
  return u
end

local slotUnits = {}
local function loadSlots()
  local list = {}
  for _, s in ipairs(slots()) do
    local u = loadUnit(s.name, s.id)
    if u then list[#list+1] = u end
  end
  slotUnits = list
  return #list > 0
end

---------------------------------------------------------------- path + candidate spots
local STEP = 1 -- path sample spacing (studs)
local samples = {}
local pathSource = "?"
local reachW, reachVer = {}, 0   -- weight of every 1% of the path = share of recent enemy HP that got that far (1 = no data yet)
local deaths = {}                -- recent enemies: {path progress when they died or leaked, max HP}
local liveMax, liveAt, emergencyFrom = 0, 0, nil -- deepest live enemy (0..1), last check, rear boost start
local function updateReach()
  local tot = 0
  for _, d in ipairs(deaths) do tot += d[2] end
  if #deaths < CFG.reachMin or tot <= 0 then
    for i = 1, 101 do reachW[i] = 1 end
  else
    for i = 1, 101 do
      local pr, hp = (i - 1) / 100, 0
      for _, d in ipairs(deaths) do if d[1] > pr then hp += d[2] end end
      reachW[i] = CFG.reachFloor + (1 - CFG.reachFloor) * hp / tot
    end
  end
  reachVer += 1
end
local function lanePoints()
  local ok, routes = pcall(function() return require(ML.Shared.MapRoutes).WaitForPoints(G, 10) end)
  local okB, BP = pcall(require, ML.Packages.BezierPath)
  local lanes = {}
  if ok and type(routes) == "table" and #routes > 0 and okB and BP then
    for i, r in ipairs(routes) do
      local okP, bp = pcall(BP.new, r, 2)
      if okP and bp and bp.PathLength and bp.PathLength > 0 then
        local n = math.max(2, math.floor(bp.PathLength / 0.5))
        local pts = {}
        for s = 0, n do
          local p = bp:CalculateUniformPosition(s / n)
          pts[#pts+1] = Vector2.new(p.X, p.Z)
        end
        lanes[i] = pts
      end
    end
    if #lanes > 0 then return lanes, "bezier" end
  end
  for _, lane in ipairs(G:WaitForChild("Waypoints"):GetChildren()) do
    local pts = {}
    for i = 1, #lane:GetChildren() do
      local p = lane:FindFirstChild(tostring(i))
      if p then pts[#pts+1] = Vector2.new(p.Position.X, p.Position.Z) end
    end
    lanes[#lanes+1] = pts
  end
  return lanes, "waypoints"
end

local function buildPath()
  local byKey = {}
  local lanes
  lanes, pathSource = lanePoints()
  for _, pts in ipairs(lanes) do
    local mine = {}
    local total = 0
    for i = 1, #pts - 1 do total += (pts[i+1] - pts[i]).Magnitude end
    total = math.max(total, 1e-6)
    local cum = 0
    for i = 1, #pts - 1 do
      local a, b = pts[i], pts[i+1]
      local seg = (b - a).Magnitude
      local n = math.max(1, math.floor(seg / (STEP / 2)))
      for s = 0, n do
        local q = a:Lerp(b, s / n)
        local k = math.floor(q.X / STEP + 0.5)..","..math.floor(q.Y / STEP + 0.5)
        if not mine[k] then
          mine[k] = true
          local e = byKey[k]
          if e then e[3] += 1 else
            local prog = math.clamp((cum + seg * s / n) / total, 0, 1)
            e = {q.X, q.Y, 1, prog, math.floor(prog * 100) + 1}
            byKey[k] = e samples[#samples+1] = e
          end
        end
      end
      cum += seg
    end
  end
  updateReach()
end

local cands, offSpots, ranges, maxR = {}, {}, {}, 0
local function computeCov(c)
  c.idx, c.cov = {}, {}
  local mx2 = (maxR + 0.01) ^ 2
  for si, s in ipairs(samples) do
    local dx, dz = s[1] - c[1], s[2] - c[2]
    local d2 = dx * dx + dz * dz
    if d2 <= mx2 then c.idx[#c.idx+1] = {si, d2} end
  end
  for _, R in ipairs(ranges) do
    local R2, len = R * R, 0
    for _, e in ipairs(c.idx) do
      if e[2] <= R2 then len += samples[e[1]][3] * STEP end
    end
    c.cov[R] = len
  end
end

local function buildCandidates()
  local tiles = {}
  for _, p in ipairs(G:WaitForChild("Paths"):GetDescendants()) do if p:IsA("BasePart") then tiles[#tiles+1] = p end end
  local function onPath(x, z)
    for _, t in ipairs(tiles) do
      local l = t.CFrame:PointToObjectSpace(Vector3.new(x, t.Position.Y, z))
      if math.abs(l.X) <= t.Size.X / 2 + CFG.pathMargin and math.abs(l.Z) <= t.Size.Z / 2 + CFG.pathMargin then return true end
    end
    return false
  end
  local grid = CFG.scanStep
  local x0, x1 = math.floor(area.Position.X - area.Size.X / 2) + 2, math.floor(area.Position.X + area.Size.X / 2) - 2
  local z0, z1 = math.floor(area.Position.Z - area.Size.Z / 2) + 2, math.floor(area.Position.Z + area.Size.Z / 2) - 2
  local work = 0
  for x = x0, x1, grid do
    for z = z0, z1, grid do
      local dmin = math.huge
      for i = 1, #samples, 3 do
        local s = samples[i]
        local d = (s[1] - x)^2 + (s[2] - z)^2
        if d < dmin then dmin = d end
      end
      dmin = math.sqrt(dmin)
      if dmin <= maxR + 1 and (CFG.allowOnPath or not onPath(x, z)) then cands[#cands+1] = {x, z} end
      if dmin > 4 and (x - x0) % 4 == 0 and (z - z0) % 4 == 0 then offSpots[#offSpots+1] = {x, z, off = true, d = dmin} end
    end
    work += 1
    if work % 3 == 0 then task.wait() end
  end
  for ci, c in ipairs(cands) do
    computeCov(c)
    if ci % 60 == 0 then task.wait() end
  end
  -- off-path spots (farms, spawners): the farther from the path the better, they waste no attack spot
  table.sort(offSpots, function(a, b) return a.d > b.d end)
end

---------------------------------------------------------------- live state (server-confirmed)
local T = {}            -- my towers: id -> {spot, unit, level, x, z, stats, shots, waveShots, idleWaves, stunUntil}
local ALL = {}          -- every tower on the map (any owner): id -> {x, z, mine}
local enemies = {}      -- key -> {name, maxHp, hp, boss, wave}
local modelReady = false
local hpScale, lastScaleWave = nil, -1
local towerVersion = 0  -- bumps whenever the set of towers changes (invalidates cached spot choices)

local WS = {}
local function waveStats(w)
  local s = WS[w]
  if not s then
    s = {wave = w, kills = 0, leaks = 0, leakNames = {}, spawned = 0, baseStart = Base:GetAttribute("Health") or 0,
         bossHp = {}, stuns = 0, t0 = os.clock(), progSum = 0, progN = 0, progMax = 0}
    WS[w] = s
  end
  return s
end
waveStats(curWave)
local holding = true
local enemiesSeeded = false

local function isBoss(name)
  local b = enemyBase[name]
  return tostring(name):find("Boss") ~= nil or (b and b.hp >= 3000) or false
end

local function count()
  local n = 0 for _ in pairs(T) do n += 1 end
  return math.max(n, serverPlaced())
end
local function placedOf(name)
  local n = 0 for _, t in pairs(T) do if t.unit == name then n += 1 end end
  return n
end
local function kindOf(t) local u = units[t.unit] return u and u.kind or "other" end
uiList = function()
  local rows = {}
  for _, t in pairs(T) do rows[#rows+1] = {k = kindOf(t), name = t.unit or "?", lv = t.level or 1, x = t.x or 0, z = t.z or 0} end
  table.sort(rows, function(a, b)
    if a.k ~= b.k then return a.k < b.k end
    if a.name ~= b.name then return a.name < b.name end
    return a.lv > b.lv
  end)
  local label = {attack = "輸出", farm = "農場", medic = "解暈", booster = "增益", spawner = "召喚"}
  local lines = {("第 %s 波 | 金錢 %d | 塔 %d/%d"):format(tostring(workspace:GetAttribute("Wave") or "?"), money(), #rows, CFG.maxUnits)}
  for _, r in ipairs(rows) do
    lines[#lines+1] = ("[%s] %s L%d (%d,%d)"):format(label[r.k] or r.k, r.name, r.lv, math.floor(r.x + 0.5), math.floor(r.z + 0.5))
  end
  return table.concat(lines, "\n")
end
local function attackCount()
  local n = 0 for _, t in pairs(T) do if kindOf(t) == "attack" then n += 1 end end
  return n
end

local function eachSpotList(f) for _, o in ipairs(cands) do f(o) end for _, o in ipairs(offSpots) do f(o) end end
local function markBlocked(x, z)
  eachSpotList(function(o)
    if math.max(math.abs(o[1] - x), math.abs(o[2] - z)) < CFG.minGap then o.blocked = true end
  end)
end
local function rebuildBlocked()
  eachSpotList(function(o) o.blocked = nil end)
  for _, a in pairs(ALL) do markBlocked(a.x, a.z) end
end

local function spotAt(x, z)
  local best, bd = nil, 2.25
  eachSpotList(function(c)
    local d = (c[1] - x) ^ 2 + (c[2] - z) ^ 2
    if d < bd then best, bd = c, d end
  end)
  if best then
    if not best.cov then computeCov(best) end
    return best
  end
  local c = {x, z, synthetic = true}
  computeCov(c)
  return c
end

local function attachSpot(t)
  if t.spot or not modelReady then return end
  t.spot = spotAt(t.x, t.z)
  t.spot.used = true
end

local function trackTower(p)
  if type(p) ~= "table" or not p.Pos then return end
  local id = tostring(p.Id or p.Index)
  local x, z = p.Pos.X, p.Pos.Z
  local mine = p.OwnerUserId == MYID
  if not ALL[id] then towerVersion += 1 end
  ALL[id] = {x = x, z = z, mine = mine}
  if modelReady then markBlocked(x, z) end
  if not mine then return end
  local t = T[id]
  if not t then
    t = {unit = p.Name, level = p.Level or 1, x = x, z = z, shots = 0, waveShots = 0, idleWaves = 0, stunUntil = 0}
    T[id] = t
    if p.Name and not units[p.Name] then task.spawn(loadUnit, p.Name) end
  end
  if p.Level and p.Level ~= t.level then towerVersion += 1 end
  t.level = p.Level or t.level
  t.stats = p.Stats or t.stats
  attachSpot(t)
end

local function dropTower(id)
  if ALL[id] or T[id] then towerVersion += 1 end
  ALL[id] = nil
  local t = T[id]
  if t then
    if t.spot then t.spot.used = nil end
    T[id] = nil
  end
end

local snapAt, snapReq = 0, -1e9
local function applyTowerList(list)
  local present = {}
  for k, p in pairs(list) do
    if type(p) == "table" then
      if p.Id == nil and p.Index == nil then p.Index = k end
      present[tostring(p.Id or p.Index)] = true
      trackTower(p)
    end
  end
  local gone = 0
  for id in pairs(ALL) do if not present[id] then dropTower(id) gone += 1 end end
  for id in pairs(T) do if not present[id] then dropTower(id) gone += 1 end end
  if modelReady then rebuildBlocked() end
  return gone
end

local function requestSnapshot(force)
  if DRY then return end
  if not force and os.clock() - snapReq < 3 then return end
  if os.clock() - snapReq < 1 then return end
  snapReq = os.clock()
  RE.Replication:FireServer()
end

keep(RE.Replication.OnClientEvent:Connect(function(d)
  if type(d) ~= "table" or type(d.Towers) ~= "table" then return end
  snapAt = os.clock()
  local before = 0 for _ in pairs(T) do before += 1 end
  local gone = applyTowerList(d.Towers)
  local after = 0 for _ in pairs(T) do after += 1 end
  if not enemiesSeeded and type(d.Enemies) == "table" then
    enemiesSeeded = true
    for _, p in pairs(d.Enemies) do
      if type(p) == "table" and p.Name then
        local key = p.Key or (tostring(p.Name).."_"..tostring(p.SpawnTime))
        if not enemies[key] then
          enemies[key] = {name = p.Name, maxHp = p.MaxHealth or 0, hp = p.Health or 0, boss = isBoss(p.Name), wave = curWave}
          waveStats(curWave).spawned += 1
        end
      end
    end
  end
  if after ~= before or gone > 0 then
    log(("snapshot: my towers %d -> %d (server PlacedTowers %d)"):format(before, after, serverPlaced()))
  end
end))

keep(RE.TowerAdd.OnClientEvent:Connect(function(p) trackTower(p) end))

keep(RE.TowerRemove.OnClientEvent:Connect(function(p)
  if type(p) ~= "table" then return end
  local id = p.Id or p.Index
  if id then dropTower(tostring(id)) end
  if type(p.Towers) == "table" then applyTowerList(p.Towers) elseif modelReady then rebuildBlocked() end
end))

keep(RE.TowerUpgrade.OnClientEvent:Connect(function(p)
  if type(p) ~= "table" then return end
  local t = T[tostring(p.Id or p.Index)]
  if not t then return end
  if p.Level and p.Level ~= t.level then t.level = p.Level towerVersion += 1 end
  if p.Stats then
    t.stats = p.Stats
    local u = units[t.unit]
    local exp = u and u.levels[t.level]
    if exp and p.Stats.Range and exp.range ~= p.Stats.Range and not p.StatsOnly then
      log(("MODEL MISMATCH %s L%d expected range %s, server says %s"):format(t.unit, t.level, exp.range, p.Stats.Range))
    end
  end
end))

keep(RE.TowerAttack.OnClientEvent:Connect(function(p)
  if type(p) ~= "table" then return end
  local t = T[tostring(p.Id or p.Index)]
  if t then t.shots += 1 t.waveShots += 1 end
end))

keep(RE.EnemyStun.OnClientEvent:Connect(function(p)
  if type(p) ~= "table" or not p.TowerId then return end
  stunSeen = true
  local t = T[tostring(p.TowerId)]
  if t then
    t.stunUntil = tonumber(p.StunEndTime) or (workspace:GetServerTimeNow() + 4)
    waveStats(curWave).stuns += 1
  end
end))
keep(RE.TowerUnstun.OnClientEvent:Connect(function(p)
  if type(p) ~= "table" or not p.Id then return end
  local t = T[tostring(p.Id)]
  if t then t.stunUntil = 0 end
end))

keep(RE.EnemyAdd.OnClientEvent:Connect(function(p)
  if type(p) ~= "table" or not p.Name then return end
  local key = p.Key or (tostring(p.Name).."_"..tostring(p.SpawnTime))
  enemies[key] = {name = p.Name, maxHp = p.MaxHealth or 0, hp = p.Health or p.MaxHealth or 0, boss = isBoss(p.Name), wave = curWave}
  waveStats(curWave).spawned += 1
  local b = enemyBase[p.Name]
  if b and b.hp > 0 and p.MaxHealth then
    hpScale = p.MaxHealth / b.hp
    local w = workspace:GetAttribute("Wave") or 0
    if w ~= lastScaleWave then
      lastScaleWave = w
      log(("wave %s enemy HP scale x%.2f (%s %d)"):format(tostring(w), hpScale, p.Name, p.MaxHealth))
      if b.stun then
        log(("WARNING %s stuns towers within %s studs for %ss (cooldown %ss)"):format(p.Name, tostring(b.stun.range), tostring(b.stun.dur), tostring(b.stun.cd)))
      end
      if b.hidden then log(("NOTE %s is hidden: towers with HideDetection cannot hit it"):format(p.Name)) end
    end
  end
end))

local function setHp(key, hp, maxHp)
  local e = enemies[key]
  if e and hp then e.hp = hp if maxHp then e.maxHp = maxHp end end
end
keep(RE.EnemyDamage.OnClientEvent:Connect(function(p)
  if type(p) == "table" and p.Key then setHp(p.Key, p.Health, p.MaxHealth) end
end))
keep(RE.TowerDamage.OnClientEvent:Connect(function(p)
  if type(p) == "table" and type(p.Hits) == "table" then
    for _, h in pairs(p.Hits) do if type(h) == "table" and h.TargetKey then setHp(h.TargetKey, h.Health, h.MaxHealth) end end
  end
end))

keep(RE.EnemyRemove.OnClientEvent:Connect(function(p)
  if type(p) ~= "table" or not p.Name then return end
  local key = p.Key or (tostring(p.Name).."_"..tostring(p.SpawnTime))
  local e = enemies[key]
  enemies[key] = nil
  local hp = p.Health or (e and e.hp) or 0
  local maxHp = p.MaxHealth or (e and e.maxHp) or 0
  local s = waveStats(e and e.wave or curWave)
  local leaked = (p.Progress or 0) >= 1 and hp > 0
  if leaked then
    s.leaks += 1
    s.leakNames[p.Name] = (s.leakNames[p.Name] or 0) + 1
    holding = false
  else
    s.kills += 1
    local pr = math.clamp(p.Progress or 0, 0, 1) -- how far along the path it got before dying
    s.progSum += pr s.progN += 1
    if pr > s.progMax then s.progMax = pr end
  end
  do
    local pr2 = leaked and 1 or math.clamp(p.Progress or 0, 0, 1)
    deaths[#deaths+1] = {pr2, math.max(maxHp, 1)}
    while #deaths > CFG.reachKeep do table.remove(deaths, 1) end
  end
  if (e and e.boss) or isBoss(p.Name) then
    s.bossHp[#s.bossHp+1] = ("%s %s %d/%d HP (%.0f%% of the path)"):format(
      p.Name, leaked and "LEAKED with" or "killed,", math.max(hp, 0), maxHp, math.min(p.Progress or 0, 1) * 100)
  end
end))

local lastBase = Base:GetAttribute("Health") or 0
keep(Base:GetAttributeChangedSignal("Health"):Connect(function()
  local h = Base:GetAttribute("Health") or 0
  if h < lastBase then holding = false end
  lastBase = h
end))

local function stunnedCount()
  local now, n = workspace:GetServerTimeNow(), 0
  for _, t in pairs(T) do if (t.stunUntil or 0) > now then n += 1 end end
  return n
end

local function closeWave(w)
  local s = waveStats(w)
  if s.closed then return end
  s.closed = true
  pcall(updateReach)
  s.towers, s.shots, s.idle, s.money, s.secs = 0, 0, {}, money(), os.clock() - s.t0
  for _, t in pairs(T) do
    s.towers += 1
    s.shots += t.waveShots
    if kindOf(t) == "attack" then
      if t.waveShots > 0 then
        t.idleWaves, t.idle = 0, nil
      elseif t.waveSeen and not t.waveStunned then
        t.idleWaves += 1
        if t.idleWaves >= CFG.idleWaves and not t.idle then
          t.idle = true
          s.idle[#s.idle+1] = ("%s(%d,%d)"):format(t.unit, t.x, t.z)
        end
      end
    end
    t.waveShots, t.waveSeen, t.waveStunned = 0, nil, nil
  end
end

local enemiesF = G:FindFirstChild("Enemies")
local function scanTargets()
  enemiesF = enemiesF or G:FindFirstChild("Enemies")
  if not enemiesF then return end
  local list = enemiesF:GetChildren()
  if #list == 0 then
    liveMax = 0
    if emergencyFrom then emergencyFrom = nil reachVer += 1 end
    return
  end
  local now = workspace:GetServerTimeNow()
  local pos = {}
  for _, e in ipairs(list) do
    local ok, p = pcall(e.GetPivot, e)
    if ok then pos[#pos+1] = p.Position end
  end
  -- where is the deepest enemy on the path right now? (nearest path sample -> its progress)
  if modelReady and #samples > 0 and now - liveAt >= 0.5 then
    liveAt = now
    local lm = 0
    for _, q in ipairs(pos) do
      local bd, bp = math.huge, 0
      for i = 1, #samples, 2 do
        local sm = samples[i]
        local d = (sm[1] - q.X) ^ 2 + (sm[2] - q.Z) ^ 2
        if d < bd then bd, bp = d, sm[4] or 0 end
      end
      if bd < 400 and bp > lm then lm = bp end
    end
    liveMax = lm
    local ef = lm >= CFG.liveMed and math.floor((lm - 0.3) * 5) / 5 or nil
    if ef ~= emergencyFrom then emergencyFrom = ef reachVer += 1 end
  end
  for _, t in pairs(T) do
    if (t.stunUntil or 0) > now then t.waveStunned = true end
    if not t.waveSeen and kindOf(t) == "attack" then
      local u = units[t.unit]
      local R = (t.stats and t.stats.Range) or (u and u.levels[t.level] and u.levels[t.level].range) or 0
      local R2 = R * R
      for _, p in ipairs(pos) do
        if (p.X - t.x) ^ 2 + (p.Z - t.z) ^ 2 <= R2 then t.waveSeen = true break end
      end
    end
  end
end

local function onWave(new)
  if new == curWave then return end
  closeWave(curWave)
  curWave = new
  waveStats(new)
  updateHidden()
end
keep(workspace:GetAttributeChangedSignal("Wave"):Connect(function() onWave(workspace:GetAttribute("Wave") or 0) end))
-- the voted mode is only known after voting: reload the wave table when the server sets it
keep(workspace:GetAttributeChangedSignal("Mode"):Connect(function()
  waves, totalWaves = nil, nil
  loadWaves()
  updateHidden()
end))

-- total enemy HP of a wave from the mode's wave table (HP grows +20% per wave)
local function waveHP(w)
  if not waves or not waves[w] then return 0 end
  local s = 0
  for _, e in ipairs(waves[w]) do local b = enemyBase[e.name] if b then s += b.hp * e.count end end
  return s * (1 + 0.2 * (w - 1))
end
local clearedHP = 0 -- the biggest wave (by HP) cleared without a leak
local lastReported = 0 -- newest wave that has been reported

local function flushReports(final, reason)
  local ws = {}
  for _, s in pairs(WS) do
    if s.closed and not s.reported and s.wave > 0
       and (final or s.kills + s.leaks >= s.spawned or s.wave <= curWave - CFG.reportLag) then ws[#ws+1] = s end
  end
  table.sort(ws, function(a, b) return a.wave < b.wave end)
  for _, s in ipairs(ws) do
    s.reported = true
    local leakTxt = {}
    for n, c in pairs(s.leakNames) do leakTxt[#leakTxt+1] = n.." x"..c end
    local open = s.spawned - s.kills - s.leaks
    report(("WAVE %d %s| spawned %d killed %d LEAKED %d%s%s | killed at %.0f%%/%.0f%% of the path (avg/max) | base %d->%d | towers %d, %d shots in %.0fs | stuns %d | money %d%s%s"):format(
      s.wave, reason and (reason.." ") or "", s.spawned, s.kills, s.leaks,
      #leakTxt > 0 and (" ("..table.concat(leakTxt, ", ")..")") or "",
      open > 0 and (" still alive "..open) or "",
      s.progN > 0 and s.progSum / s.progN * 100 or 0, s.progMax * 100,
      s.baseStart or 0, Base:GetAttribute("Health") or 0, s.towers or 0, s.shots or 0, s.secs or 0, s.stuns, s.money or money(),
      #s.bossHp > 0 and (" | BOSS: "..table.concat(s.bossHp, "; ")) or "",
      #s.idle > 0 and (" | IDLE towers (enemy in range, no shot, "..CFG.idleWaves.." waves): "..table.concat(s.idle, " ")) or ""))
    -- the newest reported wave decides whether the defence is holding (reports can lag a few waves behind)
    if s.wave >= lastReported then lastReported = s.wave holding = s.leaks == 0 end
    if s.leaks == 0 and open <= 0 then clearedHP = math.max(clearedHP, waveHP(s.wave)) end
  end
end

---------------------------------------------------------------- phase + pressure
-- early = hold the line, mid = make money while calm, late = all-in damage
local function phase()
  local total = totalWaves or 20
  if curWave <= math.min(CFG.earlyEndWave, math.floor(total * CFG.earlyMaxShare)) then return "early" end
  if curWave > math.max(math.floor(total * CFG.lateStart), total - CFG.lateMinLast) then return "late" end
  return "mid"
end

-- low / medium / high, from the last three waves (leaks, how far enemies got before dying) and the wave table
local waveMargin -- defined further down (needs the coverage model); returns damage capacity / HP for a wave
local lastMargin = nil
local function pressure()
  local level = 0
  -- what really happened lately: a leak (or an enemy almost through) means the forecast is too optimistic
  local recentLeak, close = false, false
  for w = curWave - 1, curWave do
    local s = WS[w]
    if s then
      if s.leaks > 0 or s.progMax > CFG.pressHighMax then recentLeak = true
      elseif s.progMax > CFG.pressMedMax or (s.progN > 0 and s.progSum / s.progN > CFG.pressMedAvg) then close = true end
    end
  end
  -- forecast: can the towers standing now kill the current and the next wave? (only as much defence as needed)
  -- high pressure comes ONLY from this forecast; after a recent leak it is discounted by 25%
  if waves and waveMargin and modelReady then
    local mg = math.min(waveMargin(math.max(curWave, 1)), waveMargin(curWave + 1, true)) * (recentLeak and 0.75 or 1)
    lastMargin = mg
    if mg < CFG.marginHigh then level = 2 elseif mg < CFG.marginMed then level = 1 end
  elseif recentLeak then
    level = 2 -- no wave table: fall back to what happened
  end
  if recentLeak or close or not holding then level = math.max(level, 1) end
  if liveMax >= CFG.liveHigh then level = 2 elseif liveMax >= CFG.liveMed then level = math.max(level, 1) end
  -- forecast: a boss in the next waves (from the mode's wave table)
  if waves then
    for w = curWave + 1, math.min(totalWaves, curWave + CFG.bossAhead) do
      for _, e in ipairs(waves[w] or {}) do if isBoss(e.name) then level = math.max(level, 1) end end
    end
  end
  return level == 0 and "low" or level == 1 and "medium" or "high"
end

-- the forecast is a guess; what really happened is the evidence. True = no leak in the last waves, nobody got far,
-- nobody is deep on the path right now -> farms may be bought even while the forecast says medium / high
local function economySafe()
  if liveMax >= CFG.ecoProg then return false end
  if lastMargin and lastMargin < CFG.ecoMinMargin then return false end
  for w = curWave - 2, curWave do
    local s = WS[w]
    if s and (s.leaks > 0 or s.progMax >= CFG.ecoProg) then return false end
  end
  return true
end

---------------------------------------------------------------- model
local function prepare()
  if modelReady then return true end
  loadEnemies()
  loadWaves()
  if not loadSlots() then return false end -- slot attributes not replicated yet: retry on the next loop
  local set = {}
  local function addR(R) if R and R > 0 and not set[R] then set[R] = true ranges[#ranges+1] = R end end
  for _, u in ipairs(slotUnits) do for _, L in ipairs(u.levels) do for _, p in ipairs(L.parts) do addR(p.range) end end end
  for _, t in pairs(T) do local u = units[t.unit] if u then for _, L in ipairs(u.levels) do for _, p in ipairs(L.parts) do addR(p.range) end end end end
  if #ranges == 0 then addR(10) end
  for _, R in ipairs(ranges) do maxR = math.max(maxR, R) end
  buildPath()
  buildCandidates()
  updateHidden()
  modelReady = true
  for _, t in pairs(T) do attachSpot(t) end
  rebuildBlocked()
  local names = {}
  for _, u in ipairs(slotUnits) do names[#names+1] = u.name.."["..u.kind.."]" end
  log(("model ready: path from %s, %d samples, %d attack spots, %d off-path spots, ranges {%s}, units: %s, adopted %d towers"):format(
    pathSource, #samples, #cands, #offSpots, table.concat(ranges, ","), table.concat(names, ", "), count()))
  if hiddenShare > 0 then log(("hidden enemies are %.0f%% of the remaining enemy HP"):format(hiddenShare * 100)) end
  return true
end

-- covered path length within range R of spot c (cached; ranges beyond maxR are clipped to maxR)
local function covAt(c, R)
  if not c.idx then computeCov(c) end
  local v = c.cov[R]
  if v then return v end
  local R2, len = R * R, 0
  for _, e in ipairs(c.idx) do if e[2] <= R2 then len += samples[e[1]][3] * STEP end end
  c.cov[R] = len
  return len
end

-- raw value of an attack unit at a level on a spot: sum over its attacks of dps x covered path (x AOE)
local function val(u, lvl, c)
  local L = u and u.levels[lvl]
  if not L or not c or u.kind ~= "attack" or c.off then return 0 end
  local v = 0
  for _, p in ipairs(L.parts) do
    v += p.dps * covAt(c, p.range) * (p.aoe and CFG.aoeFactor or 1)
  end
  if L.slow > 0 then v *= 1 + L.slow / 100 end -- slowed enemies stay longer inside every tower's range
  if u.blind then v *= (1 - hiddenShare) end
  return v
end

local function towerVal(t) return val(units[t.unit], t.level, t.spot) end

-- forecast for wave w: for every enemy group of the wave table, the damage my attack towers can deal while the
-- group walks past (time in range + the spawn gaps of the group) divided by the group's total HP; worst group wins.
-- damage my attack towers deal to a stream of `count` enemies (speed, hidden, spawn gap) walking past
local function groupDamage(speed, hidden, count, gap)
  local window = (count - 1) * gap
  local dmg = 0
  for _, t in pairs(T) do
    local u = units[t.unit]
    local L = u and u.kind == "attack" and u.levels[t.level]
    if L and t.spot and not (u.blind and hidden) then
      for _, p in ipairs(L.parts) do
        local tir = covAt(t.spot, p.range) / CFG.laneShare / math.max(speed, 0.5) -- seconds one enemy is in range
        dmg += p.dps * (tir + window) * (p.aoe and CFG.aoeFactor or 1)
      end
    end
  end
  return dmg
end

-- withAlive: the enemies still walking now arrive together with this wave (skipped waves pile up)
waveMargin = function(w, withAlive)
  if not waves or not waves[w] then return math.huge end
  local scale = 1 + 0.2 * (w - 1)
  local worst = math.huge
  local totDmg, totHp = 0, 0
  for _, g in ipairs(waves[w]) do
    local b = enemyBase[g.name]
    if b and b.hp > 0 then
      local dmg = groupDamage(b.speed or 4, b.hidden, g.count, g.gap or 1)
      local hp = b.hp * scale * g.count
      totDmg += dmg totHp += hp
      if dmg / hp < worst then worst = dmg / hp end
    end
  end
  if withAlive then
    local n, hp, speed = 0, 0, 0
    for _, e in pairs(enemies) do
      if (e.hp or 0) > 0 then
        n += 1 hp += e.hp
        local b = enemyBase[e.name]
        speed += b and b.speed or 4
      end
    end
    if n > 0 then
      totDmg += groupDamage(speed / n, false, n, 0.5)
      totHp += hp
      if totHp > 0 and totDmg / totHp < worst then worst = totDmg / totHp end
    end
  end
  return worst
end

local function buffMult(L)
  if not L then return 0 end
  return (1 + L.buffD / 100) / math.max(0.05, 1 + L.buffCD / 100) - 1
end

-- value of a support tower (booster / medic / spawner) of unit u at level lvl standing at (x, z)
local function supportVal(u, lvl, x, z)
  local L = u.levels[lvl]
  if not L then return 0 end
  if u.kind == "spawner" then return L.ally * CFG.spawnerCov end
  local R2, sum = (L.range or 0) ^ 2, 0
  for _, t in pairs(T) do
    if kindOf(t) == "attack" and (t.x - x) ^ 2 + (t.z - z) ^ 2 <= R2 then sum += towerVal(t) end
  end
  if u.kind == "booster" then return sum * buffMult(L) end
  if u.kind == "medic" then return stunThreat() and sum * CFG.medicShare or 0 end
  return 0
end

local function anyVal(t)
  local u = units[t.unit]
  if not u then return 0 end
  if u.kind == "attack" then return towerVal(t) end
  return supportVal(u, t.level, t.x, t.z)
end

local function priceTo(u, L) local s = 0 for i = 1, L do s += (u.levels[i] and u.levels[i].price or 0) end return s end

local function free(c) return not c.used and not c.bad and not c.blocked end
local function freeAtk(c) return not c.bad and (overlapOK == true or (not c.used and not c.blocked)) end

-- best free attack spot for unit u: most NEW path value (a stretch already getting k times the new tower's damage
-- from my other towers counts 1/(1+k)), preferring >= spreadGap from my other attack towers.
-- opening = true : ranked at level 1 (cheap early units: the spot where level 1 is best; must reach the path now)
-- opening = false: ranked at CFG.strongLevel (strong units are raised to level 3 right away)
local spotCache = {}
local function rankLevel(u, opening) return opening and 1 or math.min(CFG.strongLevel, #u.levels) end
local function bestSpot(u, opening, reachNow)
  local key = u.name .. (opening and "|o" or "|f") .. (reachNow and "|r" or "")
  local ce = spotCache[key]
  if ce and ce.v == towerVersion and ce.r == reachVer and ce.c and freeAtk(ce.c) then return ce.c, ce.score end
  local rankL = rankLevel(u, opening)
  local L = u.levels[rankL]
  -- damage already standing on every path sample (sum of the dps of my towers whose range covers it), measured in
  -- units of the candidate's own dps: a stretch that already gets a lot of damage is worth little to a new tower,
  -- so new towers spread to the stretches that lack damage
  local ownDps = 0
  for _, p in ipairs(L.parts) do ownDps += p.dps * (p.aoe and CFG.aoeFactor or 1) end
  ownDps = math.max(ownDps, 1)
  local k = {}
  local mine = {}
  for _, t in pairs(T) do
    if kindOf(t) == "attack" and t.spot and t.spot.idx then
      mine[#mine+1] = t
      local tu = units[t.unit]
      local tl = tu and tu.levels[t.level]
      if tl then
        for _, p in ipairs(tl.parts) do
          local R2, d = p.range * p.range, p.dps * (p.aoe and CFG.aoeFactor or 1) / ownDps
          for _, e in ipairs(t.spot.idx) do if e[2] <= R2 then k[e[1]] = (k[e[1]] or 0) + d end end
        end
      end
    end
  end
  -- value of every path sample: its length x how many enemies lately got that far (x boost while an enemy is deep)
  local sw = {}
  for si, sm in ipairs(samples) do
    local w = reachW[sm[5] or 1] or 1
    if emergencyFrom and (sm[4] or 0) >= emergencyFrom then w *= CFG.rearBoost end
    sw[si] = sm[3] * STEP * w
  end
  local function score(c, undisc)
    local sc = 0
    for _, p in ipairs(L.parts) do
      local R2, part = p.range * p.range, 0
      for _, e in ipairs(c.idx) do
        if e[2] <= R2 then part += sw[e[1]] / (1 + (undisc and 0 or (k[e[1]] or 0))) end
      end
      sc += part * p.dps * (p.aoe and CFG.aoeFactor or 1)
    end
    if u.blind then sc *= (1 - hiddenShare) end
    if L.slow > 0 then sc *= 1 + L.slow / 100 end
    return sc
  end
  -- units of one kind: the highest-level one is the anchor of a cluster (used only when no good spread spot is left)
  local clusterAnchor
  for _, t in pairs(T) do
    if t.unit == u.name and t.x and t.z then
      if not clusterAnchor or t.level > clusterAnchor.level
         or (t.level == clusterAnchor.level and (t.x < clusterAnchor.x or (t.x == clusterAnchor.x and t.z < clusterAnchor.z))) then
        clusterAnchor = t
      end
    end
  end
  local rad2 = (CFG.clusterRadius or 9) ^ 2
  -- pass A: full value (no discount) of every usable spot = the yardstick for "good", and the best spot near the anchor
  local okc = {}
  local bu, buC, cs, cC = 0, nil, 0, nil
  for ci, c in ipairs(cands) do
    if freeAtk(c) and not ((opening or reachNow) and val(u, 1, c) <= 0) then
      local su = score(c, true)
      okc[ci] = su -- (a number is truthy; stack mode reuses the score)
      if su > bu then bu, buC = su, c end
      if clusterAnchor and su > cs and (c[1] - clusterAnchor.x) ^ 2 + (c[2] - clusterAnchor.z) ^ 2 <= rad2 then cs, cC = su, c end
    end
    if ci % 400 == 0 then task.wait() end
  end
  -- pass B: spread = the most NEW damage (discounted by what already stands there), >= spreadGap from my other attack towers
  local best, bs, gapUsed = nil, 0, 0
  for pass = 1, CFG.stack and 0 or 2 do
    local gap2 = (pass == 1 and CFG.spreadGap or 0) ^ 2
    for ci, c in ipairs(cands) do
      if okc[ci] then
        local ok = true
        if gap2 > 0 then
          for _, t in ipairs(mine) do if (t.x - c[1]) ^ 2 + (t.z - c[2]) ^ 2 < gap2 then ok = false break end end
        end
        if ok then
          local sd = score(c)
          if sd > bs then best, bs, gapUsed = c, sd, gap2 end
        end
      end
      if ci % 400 == 0 then task.wait() end
    end
    if best then break end
  end
  local mode, chosen, curS = "spread", best, bs
  if CFG.stack then
    -- stack: every attack tower goes next to the damage cluster, but only on a spot that keeps stackKeep of the best
    -- free spot's full value (full = no discount for damage already standing there) -> the range stays effective
    mode, chosen, curS, gapUsed = "stack", buC, bu, 0
    if buC and #mine > 0 then
      local ax, az = 0, 0
      for _, t in ipairs(mine) do ax += t.x az += t.z end
      ax, az = ax / #mine, az / #mine
      local bd = math.huge
      for ci, c in ipairs(cands) do
        local su = okc[ci]
        if su and su >= CFG.stackKeep * bu then
          local d = (c[1] - ax) ^ 2 + (c[2] - az) ^ 2
          if d < bd then bd, chosen, curS = d, c, su end
        end
      end
    end
  elseif not best or bs < CFG.goodShare * bu then
    -- no good spread spot left: pile onto the best spot (next to the anchor if there is one)
    mode, chosen, curS, gapUsed = "cluster", cC or buC, cC and cs or bu, 0
  end
  if not chosen then
    spotCache[key] = {v = towerVersion, r = reachVer, c = nil, score = 0}
    return nil, 0
  end
  -- refine: try sub-stud positions around the chosen grid point (0.25 stud steps, +-0.75)
  if CFG.refine then
    local x0, z0 = chosen[1], chosen[2]
    local ax0, ax1 = area.Position.X - area.Size.X / 2 + 2, area.Position.X + area.Size.X / 2 - 2
    local az0, az1 = area.Position.Z - area.Size.Z / 2 + 2, area.Position.Z + area.Size.Z / 2 - 2
    local undisc = mode == "cluster" or mode == "stack"
    for dx = -0.75, 0.75, 0.25 do
      for dz = -0.75, 0.75, 0.25 do
        local x, z = x0 + dx, z0 + dz
        if (dx ~= 0 or dz ~= 0) and x >= ax0 and x <= ax1 and z >= az0 and z <= az1 then
          local ok = true
          for _, a in pairs(ALL) do
            if overlapOK ~= true and math.max(math.abs(a.x - x), math.abs(a.z - z)) < CFG.minGap then ok = false break end
          end
          if ok and gapUsed > 0 then
            for _, t in ipairs(mine) do if (t.x - x) ^ 2 + (t.z - z) ^ 2 < gapUsed then ok = false break end end
          end
          if ok then
            local c = {x, z, synthetic = true}
            computeCov(c)
            if not ((opening or reachNow) and val(u, 1, c) <= 0) then
              local sc = score(c, undisc)
              if sc > curS * 1.0001 then chosen, curS = c, sc end
            end
          end
        end
      end
    end
  end
  spotCache[key] = {v = towerVersion, r = reachVer, c = chosen, score = curS}
  return chosen, curS
end

-- the map scan result: best spot of every attack unit, at level 1 and at its last level (logged once per map)
local scanLogged = false
local function logScan()
  if scanLogged or not modelReady then return end
  scanLogged = true
  for _, u in ipairs(slotUnits) do
    if u.kind == "attack" then
      local c1, s1 = bestSpot(u, true)
      local cf, sf = bestSpot(u, false)
      report(("SCAN %s: %d spots on a %g-stud grid%s | best L1 spot (%.2f,%.2f) score %.0f | best L%d spot (%.2f,%.2f) score %.0f"):format(
        u.name, #cands, CFG.scanStep, CFG.refine and " + 0.25-stud refinement" or "",
        c1 and c1[1] or 0, c1 and c1[2] or 0, s1 or 0, rankLevel(u, false), cf and cf[1] or 0, cf and cf[2] or 0, sf or 0))
    end
  end
end

-- support spot: booster/medic where the most attack value stands inside its range; farm/spawner off the path
local function supportSpot(u, lvl)
  if u.kind == "farm" or u.kind == "spawner" then
    for _, c in ipairs(offSpots) do if free(c) then return c end end
    for i = #cands, 1, -1 do if free(cands[i]) then return cands[i] end end
    return nil
  end
  local best, bv = nil, 0
  local function try(c)
    if free(c) then
      local v = supportVal(u, lvl, c[1], c[2])
      if v > bv then best, bv = c, v end
    end
  end
  for i, c in ipairs(cands) do if i % 3 == 0 then try(c) end end
  for _, c in ipairs(offSpots) do try(c) end
  return best, bv
end

---------------------------------------------------------------- actions (server-confirmed)
local function doUpgrade(id)
  local t = T[id]
  if not t then return false end
  local u = units[t.unit]
  local nxt = u and u.levels[t.level + 1]
  if not nxt or money() < nxt.price then return false end
  local lv0 = t.level
  RE.TowerUpgrade:FireServer({Id = id})
  local ok = waitFor(function() return not T[id] or T[id].level > lv0 end, 2.5)
  if not ok then
    requestSnapshot(true)
    ok = waitFor(function() return not T[id] or T[id].level > lv0 end, 2.5)
  end
  if not ok or not T[id] then
    t.cool = os.clock() + 4
    log("upgrade rejected by server", t.unit, id:sub(1, 6), "L"..lv0, "money", money())
    return false
  end
  log(("upgraded %s at (%d,%d) to L%d, money %d"):format(t.unit, t.x, t.z, t.level, money()))
  return true
end

-- a tower of mine at (x, z) that did not exist before (ids in `before` are ignored)
local function findMineAt(x, z, before)
  for id, t in pairs(T) do
    if not (before and before[id]) and (t.x - x) ^ 2 + (t.z - z) ^ 2 < 2.5 ^ 2 then return id end
  end
end

local function doPlace(u, c, why, probe)
  local cost = u.levels[1].price
  if serverPlaced() >= CFG.maxUnits or placedOf(u.name) >= u.limit or money() < cost or not u.id then return false end
  local before = {}
  for id in pairs(ALL) do before[id] = true end
  for id in pairs(T) do before[id] = true end
  local p = Vector3.new(c[1], topY, c[2])
  RE.TowerAdd:FireServer({Name = u.name, UnitId = u.id, Pos = p, CFrame = CFrame.new(p)})
  local newId = waitFor(function() return findMineAt(c[1], c[2], before) end, 2.5)
  if not newId then
    requestSnapshot(true)
    newId = waitFor(function() return findMineAt(c[1], c[2], before) end, 2.5)
  end
  if not newId then
    if not probe and serverPlaced() < CFG.maxUnits and money() >= cost and placedOf(u.name) < u.limit then
      c.fails = (c.fails or 0) + 1
      if c.fails >= CFG.placeFails then c.bad = true end
      log(("placement of %s rejected at (%d,%d) [%d/%d]%s"):format(u.name, c[1], c[2], c.fails, CFG.placeFails, c.bad and " -> spot disabled" or ""))
    end
    return false
  end
  local t = T[newId]
  if t.spot ~= c then
    if t.spot then t.spot.used = nil end
    t.spot = c
    if not c.cov then computeCov(c) end
  end
  c.used = true
  markBlocked(c[1], c[2])
  log(("placed %s [%s] at (%d,%d)%s, money %d, server units %d"):format(u.name, u.kind, c[1], c[2], why and (" - "..why) or "", money(), serverPlaced()))
  pushHist(("放置 %s (%d,%d)%s"):format(u.name, c[1], c[2], why and (" - " .. why) or ""))
  return newId
end

local function doSell(id)
  local t = T[id]
  if not t then return false end
  local m0 = money()
  RE.TowerSell:FireServer({Id = id})
  local gone = waitFor(function() return not T[id] end, 2.5)
  if not gone then requestSnapshot(true) gone = waitFor(function() return not T[id] end, 2.5) end
  if gone then
    log(("sold %s L%d at (%d,%d), refund ~%d"):format(t.unit, t.level, t.x, t.z, money() - m0))
    pushHist(("賣出 %s L%d (%d,%d)"):format(t.unit, t.level, t.x, t.z))
    rebuildBlocked()
    return true
  end
  log("sell not confirmed by the server", t.unit)
  return false
end

---------------------------------------------------------------- decision
-- strong units: every attack unit dearer than the cheapest one, strongest (max-level damage) first
local strongCache
local function maxDps(u)
  local L, d = u.levels[#u.levels], 0
  for _, p in ipairs(L.parts) do d += p.dps * (p.aoe and CFG.aoeFactor or 1) end
  if L.slow > 0 then d *= 1 + L.slow / 100 end
  return d
end
-- strong = clearly more damage per money (max-level damage / total price to reach it) than the cheap unit, not just a higher price
local function strongEnough(u, cheapest)
  local baseEff = 0
  for _, c in ipairs(slotUnits) do
    if c.kind == "attack" and c.levels[1].price == cheapest then baseEff = math.max(baseEff, maxDps(c) / math.max(c.total, 1)) end
  end
  return maxDps(u) / math.max(u.total, 1) >= CFG.strongEff * baseEff
end
local function strongList()
  if strongCache and strongCache.n == #slotUnits then return strongCache.list end
  local cheapest = math.huge
  for _, u in ipairs(slotUnits) do if u.kind == "attack" then cheapest = math.min(cheapest, u.levels[1].price) end end
  local list = {}
  for _, u in ipairs(slotUnits) do if u.kind == "attack" and u.levels[1].price > cheapest and strongEnough(u, cheapest) then list[#list+1] = u end end
  table.sort(list, function(a, b) return maxDps(a) > maxDps(b) end)
  strongCache = {n = #slotUnits, list = list}
  return list
end
local function isStrong(u) for _, s in ipairs(strongList()) do if s == u then return true end end return false end

-- every strong unit is placed as often as it may be (or no slot is left) and every one is at its last level
local function strongDone()
  for _, u in ipairs(strongList()) do
    if placedOf(u.name) < u.limit and count() < CFG.maxUnits then return false end
    for _, t in pairs(T) do if t.unit == u.name and t.level < #u.levels then return false end end
  end
  return true
end

-- every unit that may be placed stands (farms up to maxFarms, medics only with a stun threat), or the cap is reached
local medicReserve -- defined below (slots kept for the Repair Drones)
local relaxReserve = false -- latch: slots stayed empty although money was idle -> stop keeping slots free for farms / medics
-- a farm only deserves a slot while its first level still pays back before the last wave
local function farmWorth(u)
  local L1 = u.levels[1]
  return L1.cash * wavesLeft() >= L1.price * CFG.farmPayback
end
local function slotsFilled()
  if count() + medicReserve() >= CFG.maxUnits then return true end
  local farmCap, farms = 0, 0
  for _, u in ipairs(slotUnits) do
    if u.kind == "farm" then
      if farmWorth(u) then farmCap += u.limit end
    elseif u.id and placedOf(u.name) < u.limit and (u.kind == "attack" or (u.kind == "medic" and stunThreat())) then return false end
  end
  for _, t in pairs(T) do if kindOf(t) == "farm" then farms += 1 end end
  if CFG.useFarms and farms < math.min(farmCap, CFG.maxFarms) then return false end
  return true
end
-- latch: once everything is maxed, farms are traded for damage (and never bought again this match)
local liquidate = false
-- all slots filled and every tower on its last level (a farm counts as maxed when its next level would not pay back)
local function allMaxed()
  if liquidate then return true end
  if not slotsFilled() then return false end
  local left = wavesLeft()
  for _, t in pairs(T) do
    local u = units[t.unit]
    local nxt = u and u.levels[t.level + 1]
    if nxt then
      if u.kind ~= "farm" then return false end
      local cur = u.levels[t.level]
      if (nxt.cash - cur.cash) * left >= nxt.price * CFG.farmPayback then return false end
    end
  end
  return true
end

-- slots kept free for farms (early + middle phase, a farm unit equipped): cheap attack towers must not fill the cap
local reservedFarmSlotsBase
-- slots kept free for the medic units (Repair Drone) while a stunning enemy is still to come in the wave table
medicReserve = function()
  if relaxReserve or not waves then return 0 end
  local threat = stunSeen
  if not threat then
    for w = math.max(1, curWave), totalWaves do
      for _, e in ipairs(waves[w] or {}) do
        local b = enemyBase[e.name]
        if b and b.stun then threat = true break end
      end
      if threat then break end
    end
  end
  if not threat then return 0 end
  local need = 0
  for _, u in ipairs(slotUnits) do
    if u.kind == "medic" then need += math.min(u.limit, 2) - placedOf(u.name) end
  end
  return math.max(0, need)
end
local function reservedFarmSlots() return reservedFarmSlotsBase() + medicReserve() end
reservedFarmSlotsBase = function()
  if relaxReserve or not CFG.useFarms or phase() == "late" or liquidate then return 0 end
  local cap, farms = 0, 0
  -- only farms that still pay back are worth a kept-free slot (a farm that is no longer bought must not block an attack tower)
  for _, u in ipairs(slotUnits) do if u.kind == "farm" and farmWorth(u) then cap += math.min(u.limit, CFG.maxFarms) end end
  for _, t in pairs(T) do if kindOf(t) == "farm" then farms += 1 end end
  return math.max(0, math.min(cap, CFG.maxFarms) - farms)
end

-- every candidate purchase with its value per money ("ratio")
local function buildActions()
  local acts = {}
  local nAtk = attackCount()
  -- cheap units are not upgraded while strong units still need money; once those are all placed and maxed, they are
  local hasStrong = #strongList() > 0 and not strongDone()
  local atkRoom = count() < CFG.maxUnits - reservedFarmSlots() -- room for one more attack tower
  if count() < CFG.maxUnits then
    for _, u in ipairs(slotUnits) do
      -- new attack towers bought here are the cheap holding units only (strong units: strongStep / replaceStep)
      if placedOf(u.name) < u.limit and u.id and not (u.kind == "attack" and (isStrong(u) or not atkRoom)) then
        local L1 = u.levels[1]
        if u.kind == "attack" then
          -- while strong units still need money the cheap ones stay level 1 (best L1 spot); once every strong unit is
          -- placed and maxed they get upgraded too, so they go where their upgraded range does the most
          local filling = not hasStrong and #strongList() > 0
          local c, sc = bestSpot(u, not filling)
          if c and sc > 0 then
            local ratio = math.max(val(u, 1, c), 1) / math.max(L1.price, 1)
            acts[#acts+1] = {kind = "new", u = u, c = c, cost = L1.price, ratio = ratio,
                             why = (filling and "filling free slot, best L%d spot, %.0f value per $1000" or "holding unit, best L%d spot, %.0f value per $1000"):format(
                               rankLevel(u, not filling), ratio * 1000)}
          end
        elseif (u.kind == "booster" and nAtk >= CFG.boosterAfter) or (u.kind == "medic" and stunThreat()) or u.kind == "spawner" then
          local c = supportSpot(u, 1)
          if c then
            local g = supportVal(u, 1, c[1], c[2])
            if g > 0 then
              local a = {kind = "new", u = u, c = c, cost = L1.price, ratio = g / math.max(L1.price, 1), why = u.kind}
              if u.kind == "medic" and placedOf(u.name) == 0 then a.ratio, a.why = math.huge, "stun threat" end
              acts[#acts+1] = a
            end
          end
        end
      end
    end
  end
  -- the cheap holding units are never upgraded (money goes to strong units, farms, support);
  -- only when no strong unit is equipped at all do they get upgrades
  for id, t in pairs(T) do
    local u = units[t.unit]
    if u and t.spot and (t.cool or 0) < os.clock() and u.kind ~= "farm"
       and not (hasStrong and u.kind == "attack" and not isStrong(u)) then
      local nxt = u.levels[t.level + 1]
      if nxt then
        local g
        if u.kind == "attack" then g = val(u, t.level + 1, t.spot) - val(u, t.level, t.spot)
        else g = supportVal(u, t.level + 1, t.x, t.z) - supportVal(u, t.level, t.x, t.z) end
        if g > 0 then
          acts[#acts+1] = {kind = "up", id = id, t = t, cost = nxt.price, ratio = g / math.max(nxt.price, 1)}
        end
      end
    end
  end
  table.sort(acts, function(a, b) return a.ratio > b.ratio end)
  return acts
end

local function run(a)
  if a.kind == "new" then return doPlace(a.u, a.c, a.why) else return doUpgrade(a.id) end
end

-- farms: rule based (money, not path value): only when they pay back CFG.farmPayback times before the last wave

-- after the early phase: put down ONE strong unit on its best spot, raise it to CFG.strongLevel, then the next one.
-- Not enough money -> wait for it (returns false, cost, why).
local function strongPlaced()
  local n = 0
  for _, t in pairs(T) do local u = units[t.unit] if u and isStrong(u) then n += 1 end end
  return n
end
-- allowNew = false: only raise the strong tower in progress to L3; true: also put down the next strong one
local function strongStep(m, allowNew)
  local list = strongList()
  if #list == 0 then return false end
  for id, t in pairs(T) do
    local u = units[t.unit]
    if u and isStrong(u) and t.level < math.min(CFG.strongLevel, #u.levels) and (t.cool or 0) < os.clock() then
      local nxt = u.levels[t.level + 1]
      if m >= nxt.price then return doUpgrade(id) end
      return false, nxt.price, ("%s at (%d,%d) to L%d"):format(u.name, t.x, t.z, t.level + 1)
    end
  end
  if not allowNew then return false end
  if count() >= CFG.maxUnits - reservedFarmSlots() then return false end -- no free slot: replaceStep swaps a weak tower out
  for _, u in ipairs(list) do
    if placedOf(u.name) < u.limit and u.id then
      local c = bestSpot(u, false)
      if c then
        if m >= u.levels[1].price then
          return doPlace(u, c, ("strong unit, will be raised to L%d"):format(math.min(CFG.strongLevel, #u.levels))) ~= false
        end
        return false, u.levels[1].price, ("new %s at (%d,%d)"):format(u.name, c[1], c[2])
      end
    end
  end
  return false
end

-- farms are raised above L2 only once two strong towers stand and every strong tower is at its target level
local function strongReady()
  if #strongList() == 0 then return true end
  local n = 0
  for _, t in pairs(T) do
    local u = units[t.unit]
    if u and isStrong(u) then
      n += 1
      if t.level < math.min(CFG.strongLevel, #u.levels) then return false end
    end
  end
  return n >= 2
end

-- strong units are PLACED first (cheap level-1 buys, each on its best corner); their upgrades come afterwards
local function strongPlaceStep(m)
  local list = strongList()
  if #list == 0 then return false end
  if count() >= CFG.maxUnits - reservedFarmSlots() then return false end
  for _, u in ipairs(list) do
    if placedOf(u.name) < u.limit and u.id then
      -- once per game version: put the second tower of a unit on exactly the same spot as the first and see if the server takes it
      if overlapOK == nil and CFG.overlap == "auto" and placedOf(u.name) >= 1 and m >= u.levels[1].price then
        local first
        for _, t in pairs(T) do if t.unit == u.name and t.x then first = t break end end
        if first then
          local c0 = first.spot or {first.x, first.z, synthetic = true}
          if not c0.cov then computeCov(c0) end
          local id = doPlace(u, c0, "overlap test: same spot as the first one", true)
          setOverlap(id and true or false, id and "server accepted the second tower" or "server refused the second tower")
          return true
        end
      end
      local c = bestSpot(u, false, true)
      if c then
        if m >= u.levels[1].price then return doPlace(u, c, "strong unit first, raised afterwards") ~= false end
        return false, u.levels[1].price, ("new %s at (%d,%d)"):format(u.name, c[1], c[2])
      end
    end
  end
  return false
end

local replacedIn = {} -- wave -> swaps done (replacement and farm swaps share it)
local function farmStep(m, placeOnly, force)
  -- early and middle phase, only while the defence is calm (farms must start early to pay off); late = all-in damage
  if not CFG.useFarms or phase() == "late" or (pressure() ~= "low" and not force) then return false end
  if liquidate then return false end -- farms are being traded for damage
  -- returns: acted (bool), cost of the farm buy we are saving for (nil = none wanted)
  local left = wavesLeft()
  local want -- cheapest worthwhile farm action
  for id, t in pairs(T) do
    local u = units[t.unit]
    if u and u.kind == "farm" and (t.cool or 0) < os.clock() then
      local cur, nxt = u.levels[t.level], u.levels[t.level + 1]
      if nxt and not placeOnly and (nxt.cash - cur.cash) * left >= nxt.price * CFG.farmPayback and (not want or nxt.price < want.cost) then
        want = {cost = nxt.price, id = id, why = ("farm upgrade to L%d +$%d/wave"):format(t.level + 1, nxt.cash)}
      end
    end
  end
  local farms = 0
  for _, t in pairs(T) do if kindOf(t) == "farm" then farms += 1 end end
  -- at the unit cap: swap the weakest attack tower for a farm if it adds almost nothing (one per wave, paid up front)
  if not placeOnly and farms < CFG.maxFarms and count() >= CFG.maxUnits and (replacedIn[curWave] or 0) < 1 then
    local total, victim, vv = 0, nil, nil
    for id, t in pairs(T) do
      if kindOf(t) == "attack" then
        local v = towerVal(t)
        total += v
        if not victim or v < vv then victim, vv = id, v end
      end
    end
    for _, u in ipairs(slotUnits) do
      if victim and u.kind == "farm" and placedOf(u.name) < u.limit and u.id and vv < total * CFG.farmSwapShare then
        local L1 = u.levels[1]
        local vt = T[victim]
        local refund = math.floor(priceTo(units[vt.unit], vt.level) * CFG.sellRefund)
        if L1.cash * left >= L1.price * CFG.farmPayback and m >= L1.price then -- money in hand, refund not counted
          local c = supportSpot(u, 1)
          if c then
            log(("farm swap: %s L%d at (%d,%d) adds %.1f%% of the defence -> %s"):format(vt.unit, vt.level, vt.x, vt.z, vv / math.max(total, 1) * 100, u.name))
            replacedIn[curWave] = (replacedIn[curWave] or 0) + 1
            if doSell(victim) and money() >= L1.price then
              doPlace(u, c, ("farm +$%d/wave, %d waves left"):format(L1.cash, left))
            end
            return true
          end
        end
      end
    end
  end
  if farms < CFG.maxFarms and attackCount() >= CFG.farmAfter and count() < CFG.maxUnits then
    for _, u in ipairs(slotUnits) do
      if u.kind == "farm" and placedOf(u.name) < u.limit and u.id then
        local L1 = u.levels[1]
        if L1.cash * left >= L1.price * CFG.farmPayback and (not want or L1.price < want.cost) then
          local c = supportSpot(u, 1)
          if c then want = {cost = L1.price, u = u, c = c, why = ("farm +$%d/wave, %d waves left"):format(L1.cash, left)} end
        end
      end
    end
  end
  if not want then return false end
  if m < want.cost then return false, want.cost, want.why end
  if want.id then return doUpgrade(want.id) end
  return doPlace(want.u, want.c, want.why) ~= false
end

-- at the cap: swap the weakest tower for a clearly stronger unit (or the same unit on a much better spot)
local function replaceStep(m)
  if not CFG.replace or count() < CFG.maxUnits - reservedFarmSlots() or not holding then return false end
  if (replacedIn[curWave] or 0) >= CFG.replacePerWave then return false end
  local victim, vpot
  -- farms are traded for damage in the late phase, or as soon as every strong unit is placed and maxed
  -- (from then on extra money has nothing left to buy, so farm income is worth nothing)
  local late = liquidate
  if late then
    -- farms are only traded for damage once their money has nothing left to buy (we are not saving for anything)
    for _, a in ipairs(buildActions()) do if a.cost > m then late = false break end end
  end
  for id, t in pairs(T) do
    local u = units[t.unit]
    if u and t.spot and (u.kind == "attack" or (late and u.kind == "farm")) then
      -- late phase: a farm's slot is worth more as damage (its value counts as 0)
      local pot = (t.idle or u.kind == "farm") and 0 or val(u, #u.levels, t.spot)
      if not victim or pot < vpot then victim, vpot = id, pot end
    end
  end
  if not victim then return false end
  local vt = T[victim]
  local vnow = vt.idle and 0 or towerVal(vt)              -- what the victim does right now
  local refund = math.floor(priceTo(units[vt.unit], vt.level) * CFG.sellRefund)
  -- One swap at a time, and only when it is FULLY paid before selling: the new tower must be bought and upgraded
  -- right away to a level that is at least as strong as the victim is now (never a weaker defence after the swap).
  local bestU, bestC, bestPot, bestNeedL, bestNeed
  for _, u in ipairs(slotUnits) do
    if u.kind == "attack" and u.id and (placedOf(u.name) < u.limit or u.name == vt.unit) then
      local options = {}
      local c = bestSpot(u, false)
      if c then options[#options+1] = c end
      if vt.spot and not vt.spot.off then options[#options+1] = vt.spot end -- the victim's own spot, once freed
      for _, oc in ipairs(options) do
        local pot = val(u, #u.levels, oc)
        local needL
        for L = 1, #u.levels do if val(u, L, oc) >= vnow then needL = L break end end
        -- a strong unit always goes straight to CFG.strongLevel (place it, then upgrade to L3)
        if needL and isStrong(u) then needL = math.max(needL, math.min(CFG.strongLevel, #u.levels)) end
        if needL and not (u.name == vt.unit and oc == vt.spot) then
          local need = priceTo(u, needL)
          if not bestPot or pot > bestPot then
            bestU, bestC, bestPot, bestNeedL, bestNeed = u, oc, pot, needL, need
          end
        end
      end
    end
  end
  if not bestU or bestPot < CFG.replaceRatio * math.max(vpot, 1) then return false end
  -- money already in hand must cover it; the refund is only a bonus (never a sale we cannot replace). No money: wait.
  if m < bestNeed then
    return false, bestNeed, ("replacing %s with %s L%d"):format(vt.unit, bestU.name, bestNeedL)
  end
  log(("replace: %s L%d at (%d,%d) (now %.0f, potential %.0f%s) -> %s L%d at (%d,%d) (potential %.0f) | cost %d, have %d + refund ~%d"):format(
    vt.unit, vt.level, vt.x, vt.z, vnow, vpot, vt.idle and ", idle" or "", bestU.name, bestNeedL, bestC[1], bestC[2], bestPot,
    bestNeed, m, refund))
  replacedIn[curWave] = (replacedIn[curWave] or 0) + 1
  local wasIdle, oldSpot = vt.idle, vt.spot
  if not doSell(victim) then return false end
  if money() < bestNeed then -- the refund was smaller than expected: do not place a weaker tower, normal buying takes over
    log(("replace: refund too small (have %d, need %d), new tower will be bought normally"):format(money(), bestNeed))
    return true
  end
  if wasIdle and oldSpot and bestC ~= oldSpot then oldSpot.bad = true end -- a spot whose tower never fired is not reused
  if bestC == oldSpot then bestC.used = nil rebuildBlocked() end
  local newId = doPlace(bestU, bestC, "replacement")
  if not newId then return true end
  for _ = 2, bestNeedL do if not doUpgrade(newId) then break end end
  return true
end

local function totalValue()
  local s = 0
  for _, t in pairs(T) do s += anyVal(t) end
  return s
end

-- money standing on the map in farms / in strong towers (farms and strong units are funded in turns)
local function invested(which)
  local s = 0
  for _, t in pairs(T) do
    local u = units[t.unit]
    if u and ((which == "farm" and u.kind == "farm") or (which == "strong" and isStrong(u))) then s += priceTo(u, t.level) end
  end
  return s
end

-- medic (Repair Drone): when a stunning enemy is coming, put it next to the biggest cluster of attack towers, then raise it
local function medicStep(m)
  if not stunThreat() or not strongReady() then return false end
  for _, u in ipairs(slotUnits) do
    if u.kind == "medic" and u.id and placedOf(u.name) < math.min(u.limit, 2) and count() < CFG.maxUnits then
      local c = supportSpot(u, 1)
      if c then
        if m >= u.levels[1].price then return doPlace(u, c, "stun threat: medic next to the damage cluster") ~= false end
        return false, u.levels[1].price, "medic " .. u.name
      end
    end
  end
  return false
end
-- medic upgrades come after the slots are filled and the farms are raised
local function medicUpStep(m)
  if not stunThreat() or not strongReady() or not slotsFilled() then return false end
  for id, t in pairs(T) do
    local u = units[t.unit]
    if u and u.kind == "medic" and t.level < #u.levels and (t.cool or 0) < os.clock() then
      local nxt = u.levels[t.level + 1]
      if m >= nxt.price then return doUpgrade(id) end
      return false, nxt.price, ("%s to L%d"):format(u.name, t.level + 1)
    end
  end
  return false
end
-- after the strong units reached their level: the other units go down until the cap (or every unit) is reached
local function fillStep(m)
  if not strongReady() or slotsFilled() then return false end
  for _, a in ipairs(buildActions()) do
    if a.kind == "new" then
      if a.cost <= m then return run(a) ~= false end
      return false, a.cost, "fill: new " .. a.u.name
    end
  end
  return false
end

-- hold the line: a cheap holding unit on its best level-1 spot; under pressure anything affordable that helps
-- hold the line: the purchase with the most defence per money RIGHT NOW (strong units included, on their best
-- level-1 spot). If the best one is a little out of reach and nothing at least half as good is affordable: wait for it.
local function holdStep(m, pr)
  local opts = {}
  for _, a in ipairs(buildActions()) do opts[#opts+1] = a end -- cheap units (best L1 spot), strong/support upgrades
  if count() < CFG.maxUnits - reservedFarmSlots() then
    for _, u in ipairs(strongList()) do
      if placedOf(u.name) < u.limit and u.id then
        local c = bestSpot(u, false, true) -- best corner for the level it will be raised to, but it must reach the path at level 1
        if c then
          local r = math.max(val(u, 1, c), 1) / math.max(u.levels[1].price, 1)
          opts[#opts+1] = {kind = "new", u = u, c = c, cost = u.levels[1].price, ratio = r,
                           why = ("defence now, best L1 spot, %.0f value per $1000"):format(r * 1000)}
        end
      end
    end
  end
  table.sort(opts, function(a, b) return a.ratio > b.ratio end)
  local best = opts[1]
  if not best then return false end
  if best.cost <= m then return run(best) ~= false end
  for _, a in ipairs(opts) do
    if a.cost <= m and a.ratio >= best.ratio * 0.5 then return run(a) ~= false end
  end
  return false, best.cost, ("defence: %s"):format(best.kind == "new" and ("new " .. best.u.name) or ("upgrade " .. best.t.unit))
end

---------------------------------------------------------------- DRY RUN (planning only)
if DRY then
  while not prepare() do task.wait(1) end
  local m, idN, spent = 300, 0, 0
  for step = 1, 50 do
    local acts = buildActions()
    local a = acts[1]
    if not a then log("DRY nothing left to buy after", step - 1, "steps") break end
    if a.cost > m then m = a.cost end -- pretend we saved up
    m -= a.cost spent += a.cost
    if a.kind == "new" then
      idN += 1
      local id = "dry"..idN
      T[id] = {unit = a.u.name, level = 1, x = a.c[1], z = a.c[2], spot = a.c, shots = 0, waveShots = 0, idleWaves = 0, stunUntil = 0}
      a.c.used = true
      markBlocked(a.c[1], a.c[2])
      towerVersion += 1
      log(("DRY %2d place %s [%s] at (%d,%d) $%d | %s"):format(step, a.u.name, a.u.kind, a.c[1], a.c[2], a.cost, a.why or ""))
    else
      a.t.level += 1
      towerVersion += 1
      log(("DRY %2d upgrade %s at (%d,%d) -> L%d $%d | ratio %.3f"):format(step, a.t.unit, a.t.x, a.t.z, a.t.level, a.cost, a.ratio))
    end
  end
  log(("DRY done: %d towers, spent %d, defence value %.0f"):format(count(), spent, totalValue()))
  return
end

---------------------------------------------------------------- MATCH: main loop
local function roundResult(gs)
  local msg = workspace:GetAttribute("Message")
  if msg == "You Won!" or msg == "You Lost!" then return msg end
  local s = tostring(gs):lower()
  if s == "lost" or s == "won" or s == "victory" or s == "defeat" or s == "gameover" or s == "ended" then return gs end
  if (Base:GetAttribute("Health") or 1) <= 0 then return "base destroyed" end
end

local function voteOk()
  local v = workspace:GetAttribute(CFG.mode.."Voters")
  if type(v) == "string" and (v:find(lp.Name, 1, true) or v:find(tostring(MYID), 1, true)) then return true end
  return (workspace:GetAttribute(CFG.mode.."Votes") or 0) > 0
end

requestSnapshot(true) -- adopt towers that already stand (reload mid-match)
local lastVote, firedAgain, lastState, lastWave, lastWait, ended = 0, false, nil, curWave, 0, false
local lastPhase, lastPress
local lastErrAt = 0
local idleSince = nil
while alive() do
  local okLoop, errLoop = pcall(function()
  local gs = workspace:GetAttribute("GameState")
  if gs ~= lastState then log("GameState", gs, "wave", workspace:GetAttribute("Wave"), "msg", workspace:GetAttribute("Message")) lastState = gs end
  local result = roundResult(gs)
  if gs == "Voting" then
    relaxReserve, idleSince = false, nil -- a new match: reserves apply again
    if os.clock() - lastVote > 3 and not voteOk() then
      RE.ModeVote:FireServer(CFG.mode)
      lastVote = os.clock()
    end
    prepare()
    logScan()
  elseif result then
    if not ended then
      ended = true
      closeWave(curWave)
      flushReports(true, "(round end)")
      report(("ROUND END: %s at wave %s, base %d, towers %d, money %d"):format(
        tostring(result), tostring(workspace:GetAttribute("Wave")), Base:GetAttribute("Health") or 0, count(), money()))
    end
    if not firedAgain then -- PlayAgain is a toggle: fire it exactly once per round end
      firedAgain = true
      RE.PlayAgain:FireServer()
    end
  elseif gs == "Restarting" then
    -- a new round (or a teleport) follows
  else
    ended, firedAgain = false, false
    prepare()
    logScan()
    local w = workspace:GetAttribute("Wave") or 0
    onWave(w)
    scanTargets()
    flushReports()
    local ph, pr = phase(), pressure()
    if w ~= lastWave then
      lastWave = w
      report(("wave %s/%s [%s, pressure %s, survive margin %.2f] | money %d | towers %d (server %d) | farms invested %d, strong invested %d"):format(
        tostring(w), tostring(totalWaves or "?"), ph, pr, lastMargin or -1, money(), count(), serverPlaced(), invested("farm"), invested("strong")))
    end
    if ph ~= lastPhase or pr ~= lastPress then
      if ph ~= lastPhase then report(("PHASE %s from wave %d (%s)"):format(ph, curWave,
        ph == "early" and "hold the line" or ph == "mid" and "make money while calm" or "all-in damage")) end
      if pr ~= lastPress then log(("pressure %s -> %s"):format(tostring(lastPress), pr)) end
      lastPhase, lastPress = ph, pr
    end
    if os.clock() - snapAt > CFG.resyncEvery then requestSnapshot() end
    if workspace:GetAttribute("CanSkip") then
      local alive = 0
      for _ in pairs(enemies) do alive += 1 end
      -- never call the next wave while the field is still full: skipped waves pile up and break through together
      -- skip unless the defence cannot hold (high pressure; enemies still alive count into that forecast)
      if CFG.skip == "always" or (CFG.skip == "safe" and pr ~= "high" and alive <= CFG.skipMaxAlive) then
        RE.WaveSkip:FireServer()
      end
    end
    if modelReady and snapAt > 0 then -- nothing is bought before the server's first snapshot told us what stands
      local m = money()
      -- ECONOMY FIRST, defence only as much as needed to survive:
      --   opening : CFG.opening cheap towers on their best level-1 spots
      --   low     : farms first (every farm buy/upgrade that pays back before the last wave), then the strong unit
      --             in progress -> L3, the next strong unit on its best L3 spot (or a funded swap at the cap)
      --   medium  : defence first: strong unit in progress -> L3, then the next strong unit (wait for the money)
      --   high    : anything affordable that helps right now (cheap tower on its best L1 spot, upgrades)
      -- Each step can say "I need X, wait" -> nothing else is bought meanwhile.
      if not liquidate and allMaxed() then
        liquidate = true
        report(("ALL MAXED at wave %s: farms are now traded for damage units"):format(tostring(curWave)))
      end
      local acted, want, why = false, nil, nil
      local holdNeeded = attackCount() < CFG.opening or pr == "high"
      acted, want, why = medicStep(m)
      if not acted and not want and pr ~= "low" and economySafe() and invested("farm") <= invested("strong") + CFG.farmLead then
        -- the forecast says "defend", the battlefield says "fine": keep the farms growing (compound interest), at most farmLead ahead
        acted, want, why = farmStep(m, false, true)
        if want then why = "(economy) " .. tostring(why) end
      end
      if not acted and not want and holdNeeded then acted, want, why = holdStep(m, pr) end
      if acted or want then
        -- defence first (bought, or waiting for the best defence per money)
      elseif pr == "low" then
        acted, want, why = farmStep(m, true)                -- 1. farms placed right after the first attack tower
        if not acted and not want then acted, want, why = farmStep(m, false) end  -- 2. farm upgrades that pay back (compound interest)
        if not acted and not want then acted, want, why = strongPlaceStep(m) end  -- 3. every strong unit placed (level 1)
        if not acted and not want then acted, want, why = strongStep(m, false) end -- 4. strong units raised to their level
        if not acted and not want then acted, want, why = fillStep(m) end         -- 5. every other unit placed (up to the cap)
        if not acted and not want then acted, want, why = medicUpStep(m) end      -- 6. medic upgrades
        if not acted and not want then acted, want, why = strongStep(m, true) end
        if not acted and not want then acted, want, why = replaceStep(m) end
      else
        acted, want, why = strongStep(m, false)
        if not acted and not want then acted, want, why = medicUpStep(m) end
        if not acted and not want then acted, want, why = strongStep(m, true) end
        if not acted and not want then acted, want, why = replaceStep(m) end
        if not acted and not want and #strongList() == 0 then acted = holdStep(m, "high") end
      end
      if acted then
        -- done for this tick
      elseif want then
        if CFG.verbose and os.clock() - lastWait > 8 then
          lastWait = os.clock()
          log(("saving for %s: costs %d, have %d [%s, pressure %s]"):format(why or "?", want, m, ph, pr))
        end
      elseif not holdNeeded then
        -- nothing to save for: best upgrade of a strong / support tower; once every strong unit is placed and maxed,
        -- also new towers of the other attack units in the free slots (and their upgrades)
        local acts = buildActions()
        local filling = #strongList() == 0 or strongDone()
        local best
        for _, a in ipairs(acts) do
          if a.kind == "up" or (filling and a.kind == "new" and a.u.kind == "attack") then
            best = best or a
            if a.cost <= m and a.ratio >= best.ratio * CFG.altRatio then acted = run(a) ~= false break end
          end
        end
      end
      -- safety valve: slots stay empty and nothing is bought or saved for (money idle) for 10 s -> a reserve (farm /
      -- medic slots) or a unit limit is the cause. Release the reserves for the rest of the match and say why.
      if acted or want then
        idleSince = nil
      else
        idleSince = idleSince or os.clock()
        if not relaxReserve and count() < CFG.maxUnits and os.clock() - idleSince > 10 then
          local lim = {}
          for _, u in ipairs(slotUnits) do
            lim[#lim+1] = ("%s[%s] %d/%s"):format(u.name, u.kind, placedOf(u.name), u.limit == math.huge and "-" or tostring(u.limit))
          end
          report(("SLOTS STUCK at wave %s: towers %d/%d, money %d, kept for farms %d, for medics %d | %s -> reserves released"):format(
            tostring(curWave), count(), CFG.maxUnits, m, reservedFarmSlotsBase(), medicReserve(), table.concat(lim, ", ")))
          relaxReserve = true
        end
      end
    end
  end
  end)
  if not okLoop and os.clock() - lastErrAt > 5 then
    lastErrAt = os.clock()
    report("loop error (continuing): " .. tostring(errLoop))
  end
  task.wait(CFG.tick)
end
