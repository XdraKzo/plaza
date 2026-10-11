--[[
    PS99 Plaza Auto Sell
    - Oyuna girince Trading Plaza'ya ışınlanır (plazadaysan atlar)
    - Boş booth claim eder
    - GUI: Pets / Items / Potions / Enchants ... sekmeleri, resimli liste, arama
    - 50k'lık paketler halinde listeler, 50k altı kalanı tek seferde koyar
    - Satıldıkça yeniden listeler
    - Anti-AFK
    Ayarlar "ps99_plaza_sell.json" dosyasına kaydedilir, autoexec'te otomatik başlar.
]]

local function log(...) print("[PlazaSell]", ...) end

-- Tekrar çalıştırılırsa eski GUI'yi ve döngüyü kapat, yenisini başlat
if getgenv().PS99_PLAZA_SELL_STOP then pcall(getgenv().PS99_PLAZA_SELL_STOP) end

---------------------------------------------------------------- AYARLAR
local PLAZA_PLACE_ID   = 15502339080   -- Trading Plaza place id
local MAX_PER_LISTING  = 50000         -- bir listing'e konabilecek max adet
local RELIST_INTERVAL  = 30            -- kaç saniyede bir booth kontrol edilsin
local CONFIG_FILE      = "ps99_plaza_sell.json"
local MAIL_INTERVAL    = 60            -- kaç saniyede bir mail toplansın

-- Remote isimleri (remote spy ile doğrula, güncelleme gelirse değişebilir)
local REMOTE_CLAIM_ANY = "Booths_ClaimAnyBooth"
local REMOTE_LIST      = "Booths_CreateListing"
---------------------------------------------------------------------------

if not game:IsLoaded() then game.Loaded:Wait() end

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService   = game:GetService("TeleportService")
local HttpService       = game:GetService("HttpService")
local VirtualUser       = game:GetService("VirtualUser")
local LP                = Players.LocalPlayer

---------------------------------------------------------------- ANTI-AFK
pcall(function()
    if getconnections then
        for _, c in ipairs(getconnections(LP.Idled)) do
            if c.Disable then pcall(c.Disable, c) end
        end
    end
end)
LP.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

---------------------------------------------------------------- PLAZA KONTROL
log("PlaceId:", game.PlaceId, "| Plaza:", PLAZA_PLACE_ID)
if game.PlaceId ~= PLAZA_PLACE_ID then
    log("Plazada değilsin, ışınlanıyor...")
    task.wait(5)
    while true do
        pcall(function() TeleportService:Teleport(PLAZA_PLACE_ID, LP) end)
        task.wait(15)
    end
end

---------------------------------------------------------------- MODÜLLER
log("Plazadasın, modüller yükleniyor...")

local function SafeRequire(path, timeout)
    local inst = ReplicatedStorage
    for part in path:gmatch("[^%.]+") do
        inst = inst:WaitForChild(part, 10)
        if not inst then return nil, path .. " bulunamadı (" .. part .. ")" end
    end
    local done, result, err = false, nil, nil
    task.spawn(function()
        local ok, r = pcall(require, inst)
        if ok then result = r else err = r end
        done = true
    end)
    local t = 0
    while not done and t < timeout do task.wait(0.1) t += 0.1 end
    if not done then return nil, path .. " require timeout" end
    return result, err
end

local Save, errS      = SafeRequire("Library.Client.Save", 15)
log("Save modülü:", Save and "OK" or ("HATA: " .. tostring(errS)))
local Network, errN   = SafeRequire("Library.Client.Network", 15)
log("Network modülü:", Network and "OK" or ("HATA: " .. tostring(errN)))
local Directory, errD = SafeRequire("Library.Directory", 15)
log("Directory modülü (resimler):", Directory and "OK" or ("HATA: " .. tostring(errD)))
if not Save then return end

local loaded = false
for _ = 1, 60 do
    local ok, s = pcall(Save.Get)
    if ok and s then loaded = true break end
    task.wait(0.5)
end
if not loaded then log("HATA: Save.Get() 30 saniyede veri döndürmedi") return end
log("Save hazır, GUI açılıyor")

local function Invoke(name, ...)
    local ok, res = pcall(function(...)
        if Network and Network.Invoke then
            return Network.Invoke(name, ...)
        end
        return ReplicatedStorage.Network[name]:InvokeServer(...)
    end, ...)
    return ok and res, res
end

---------------------------------------------------------------- CONFIG
-- items: { [key] = {class, id, pt, sh, tn, price, enabled} }
local Config = { items = {}, autoStart = false }

local function SaveConfig()
    if not writefile then log("HATA: executor writefile desteklemiyor, ayarlar kaydedilemez") return end
    local ok, err = pcall(function() writefile(CONFIG_FILE, HttpService:JSONEncode(Config)) end)
    if not ok then log("HATA: ayar kaydedilemedi:", err) end
end
local function LoadConfig()
    if not (isfile and readfile) then log("HATA: executor isfile/readfile desteklemiyor") return end
    local okExists, exists = pcall(isfile, CONFIG_FILE)
    if not (okExists and exists) then log("Kayıtlı ayar yok, yeni oluşturulacak") return end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)
    if ok and type(data) == "table" then
        Config = data
        Config.items = Config.items or {}
        local n = 0
        for _ in pairs(Config.items) do n += 1 end
        log("Ayarlar yüklendi:", n, "item, autoStart =", tostring(Config.autoStart))
    else
        log("HATA: ayar dosyası okunamadı:", data)
    end
end
LoadConfig()

---------------------------------------------------------------- ENVANTER
-- Sekme sırası ve görünen isimler (envanterde olmayan sekme gösterilmez)
local CLASS_ORDER = { "Pet", "Misc", "Potion", "Enchant", "Charm", "Lootbox", "Egg", "Fruit", "Hoverboard", "Booth", "Ultimate", "Card", "Seed" }
local CLASS_LABEL = {
    Pet = "Pets", Misc = "Items", Potion = "Potions", Enchant = "Enchants", Charm = "Charms",
    Lootbox = "Lootboxes", Egg = "Eggs", Fruit = "Fruits", Hoverboard = "Hoverboards",
    Booth = "Booths", Ultimate = "Ultimates", Card = "Cards", Seed = "Seeds",
}
-- Inventory class -> Directory tablosu
local DIR_MAP = {
    Pet = "Pets", Misc = "MiscItems", Potion = "Potions", Enchant = "Enchants", Charm = "Charms",
    Lootbox = "Lootboxes", Egg = "Eggs", Fruit = "Fruits", Hoverboard = "Hoverboards",
    Booth = "Booths", Ultimate = "Ultimates", Card = "Cards", Seed = "Seeds",
}
local PT_NAME = { [1] = "Golden", [2] = "Rainbow" }

local function Key(class, d)
    return table.concat({ class, d.id, d.pt or 0, d.sh and 1 or 0, d.tn or 0 }, "|")
end

local function DisplayName(class, g)
    local s = ""
    if g.sh then s = s .. "Shiny " end
    if class == "Pet" then s = s .. (PT_NAME[g.pt] and (PT_NAME[g.pt] .. " ") or "") end
    s = s .. tostring(g.id)
    if g.tn and class ~= "Pet" then s = s .. " T" .. g.tn end
    return s
end

local iconCache = {}
local function GetIcon(class, g)
    if not Directory then return nil end
    local ck = class .. "|" .. tostring(g.id) .. "|" .. tostring(g.pt) .. "|" .. tostring(g.tn)
    if iconCache[ck] ~= nil then return iconCache[ck] or nil end
    local ok, icon = pcall(function()
        local dir = Directory[DIR_MAP[class] or (class .. "s")]
        local e = dir and dir[g.id]
        if not e then return nil end
        if class == "Pet" then
            return (g.pt == 1 and e.goldenThumbnail) or e.thumbnail
        end
        local tiers = e.Tiers or e.tiers
        if g.tn and tiers and tiers[g.tn] then
            local t = tiers[g.tn]
            local ic = t.icon or t.Icon or t.thumbnail
            if ic then return ic end
        end
        return e.icon or e.Icon or e.thumbnail
    end)
    icon = (ok and type(icon) == "string") and icon or nil
    iconCache[ck] = icon or false
    return icon
end

-- class -> key -> {class, id, pt, sh, tn, stacks={{uid,amount}}, total}
local function ScanInventory()
    local result = {}
    local inv = Save.Get().Inventory or {}
    for class, items in pairs(inv) do
        if type(items) == "table" then
            local bucket = {}
            for uid, d in pairs(items) do
                if type(d) == "table" and d.id then
                    local k = Key(class, d)
                    local g = bucket[k]
                    if not g then
                        g = { class = class, id = d.id, pt = d.pt, sh = d.sh == true, tn = d.tn, stacks = {}, total = 0 }
                        bucket[k] = g
                    end
                    local am = d._am or 1
                    table.insert(g.stacks, { uid = uid, amount = am })
                    g.total += am
                end
            end
            if next(bucket) then result[class] = bucket end
        end
    end
    return result
end

---------------------------------------------------------------- BOOTH
local function BoothCandidates()
    local list = {}
    local things = workspace:FindFirstChild("__THINGS")
    local roots = {}
    if things then
        for _, n in ipairs({ "Booths", "BoothSpawns" }) do
            local f = things:FindFirstChild(n)
            if f then table.insert(roots, f) end
        end
    end
    if #roots > 0 then
        for _, r in ipairs(roots) do
            for _, c in ipairs(r:GetChildren()) do table.insert(list, c) end
        end
    else
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("Model") and d.Name:lower():find("booth") then table.insert(list, d) end
        end
    end
    return list
end

local function OwnerOf(b)
    for name, v in pairs(b:GetAttributes()) do
        if name:lower():find("owner") then return v end
    end
end

local function IsMine(b)
    local o = OwnerOf(b)
    if o ~= nil and (o == LP.UserId or tostring(o) == tostring(LP.UserId) or o == LP.Name) then
        return true
    end
    -- Owner attribute yoksa tabeladaki isimden bak
    for _, d in ipairs(b:GetDescendants()) do
        if d:IsA("TextLabel") and (d.Text:find(LP.DisplayName, 1, true) or d.Text:find(LP.Name, 1, true)) then
            return true
        end
    end
    return false
end

local function MyBooth()
    for _, b in ipairs(BoothCandidates()) do
        if IsMine(b) then return b end
    end
end

local function BoothId(b)
    for _, n in ipairs({ "ID", "Id", "BoothID", "BoothId", "Index", "BoothSlot" }) do
        local v = b:GetAttribute(n)
        if v ~= nil then return v end
    end
    return tonumber(b.Name:match("%d+")) or b.Name
end

local function GoTo(inst)
    local char = LP.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local ok, cf = pcall(function() return inst:IsA("Model") and inst:GetPivot() or inst.CFrame end)
    if ok and cf then hrp.CFrame = cf + Vector3.new(0, 4, 0) end
end

local function ClaimBooth()
    local mine = MyBooth()
    if mine then return true end

    -- Oyunun kendi "boş herhangi bir booth al" remote'u
    local ok, res = Invoke(REMOTE_CLAIM_ANY)
    log("ClaimAnyBooth ->", tostring(ok), tostring(res))

    -- Booth'un __THINGS.Booths'a gelmesini bekle
    for _ = 1, 20 do
        mine = MyBooth()
        if mine then
            log("Booth alındı:", mine:GetFullName())
            GoTo(mine)
            return true
        end
        task.wait(0.25)
    end
    return false
end

local function DebugBooths()
    local things = workspace:FindFirstChild("__THINGS")
    log("==== BOOTH DEBUG ====")
    if things then
        local names = {}
        for _, c in ipairs(things:GetChildren()) do table.insert(names, c.Name) end
        log("__THINGS:", table.concat(names, ", "))
    else
        log("__THINGS yok")
    end
    log("Benim UserId:", LP.UserId)

    -- Gerçek remote isimleri
    local remotes = {}
    local net = ReplicatedStorage:FindFirstChild("Network")
    if net then
        for _, r in ipairs(net:GetChildren()) do
            if r.Name:lower():find("booth") then table.insert(remotes, r.Name .. "(" .. r.ClassName .. ")") end
        end
    end
    log("Booth remote'ları:", #remotes > 0 and table.concat(remotes, ", ") or "bulunamadı")

    -- __THINGS.Booths dışında adında booth/stand/spawn geçen her şey (boş yerler burada olmalı)
    local found = 0
    local boothsFolder = things and things:FindFirstChild("Booths")
    for _, d in ipairs(workspace:GetDescendants()) do
        if found >= 15 then break end
        local n = d.Name:lower()
        if (n:find("booth") or n:find("stand") or n:find("spawn")) and not (boothsFolder and d:IsDescendantOf(boothsFolder)) and d ~= boothsFolder then
            found += 1
            local attrs = {}
            for an, v in pairs(d:GetAttributes()) do table.insert(attrs, an .. "=" .. tostring(v)) end
            log("Diğer:", d:GetFullName(), d.ClassName, "| children:", #d:GetChildren(), "| attr:", table.concat(attrs, ", "))
        end
    end

    local cands = BoothCandidates()
    log("Booth adayı sayısı:", #cands)
    for i = 1, math.min(3, #cands) do
        local b = cands[i]
        local attrs = {}
        for n, v in pairs(b:GetAttributes()) do table.insert(attrs, n .. "=" .. tostring(v)) end
        local kids = {}
        for _, c in ipairs(b:GetChildren()) do table.insert(kids, c.Name .. "(" .. c.ClassName .. ")") end
        log(i, b:GetFullName(), b.ClassName)
        log("   attr:", table.concat(attrs, ", "))
        log("   children:", table.concat(kids, ", "))
    end
    log("=====================")
end

---------------------------------------------------------------- GEM TAKİBİ
local function Fmt(n)
    n = tonumber(n) or 0
    local abs = math.abs(n)
    local units = { { 1e12, "t" }, { 1e9, "b" }, { 1e6, "m" }, { 1e3, "k" } }
    for _, u in ipairs(units) do
        if abs >= u[1] then
            return (("%.2f"):format(n / u[1]):gsub("%.?0+$", "")) .. u[2]
        end
    end
    return tostring(math.floor(n))
end

local function GetDiamonds()
    local ok, v = pcall(function()
        for _, d in pairs(Save.Get().Inventory.Currency or {}) do
            if d.id == "Diamonds" then return d._am or 0 end
        end
        return 0
    end)
    return ok and v or 0
end

Config.totalEarned = Config.totalEarned or 0
local Stats = {
    startTime     = os.clock(),
    startGems     = GetDiamonds(),
    lastGems      = GetDiamonds(),
    sessionEarned = 0,
    listedCount   = 0,
    mailEarned    = 0,
    paused        = false, -- mail toplarken gem takibi durur (mail gem'i satış sayılmasın)
}

---------------------------------------------------------------- AUTO MAIL
local MailRemote
do
    local names = {}
    local net = ReplicatedStorage:FindFirstChild("Network")
    if net then
        for _, r in ipairs(net:GetChildren()) do
            if r.Name:lower():find("mail") then table.insert(names, r.Name) end
        end
    end
    log("Mail remote'ları:", #names > 0 and table.concat(names, ", ") or "bulunamadı")
    -- Önce "claim all", yoksa "claim" içeren remote
    for _, n in ipairs(names) do
        local l = n:lower()
        if l:find("claim") and l:find("all") then MailRemote = n break end
    end
    if not MailRemote then
        for _, n in ipairs(names) do
            if n:lower():find("claim") then MailRemote = n break end
        end
    end
    log("Kullanılacak mail remote:", tostring(MailRemote))
end

local function ClaimMail()
    if not MailRemote then return false, "mail remote bulunamadı" end
    Stats.paused = true
    local before = GetDiamonds()
    local ok, res = Invoke(MailRemote)
    task.wait(1.5)
    local after = GetDiamonds()
    if after > before then Stats.mailEarned += after - before end
    Stats.lastGems = after
    Stats.paused = false
    log("Mail toplandı ->", tostring(ok), tostring(res), "| gem farkı:", after - before)
    return ok, res
end

---------------------------------------------------------------- LİSTELEME
local Running = false
local Status = "Bekliyor"

-- Tikli item'lardan sırayla birer listing koyar (Normal, Golden, Rainbow, Normal, Golden...)
-- Böylece booth dolduğunda her item'dan eşit sayıda listing olur.
local function ListAll()
    local inv = ScanInventory()
    local active = 0
    local queue = {}
    for k, item in pairs(Config.items) do
        if item.enabled and item.price and item.price > 0 then
            active += 1
            local g = inv[item.class] and inv[item.class][k]
            if g and g.total > 0 then
                table.insert(queue, { key = k, item = item, g = g, si = 1, left = g.stacks[1].amount, done = false })
            end
        end
    end
    table.sort(queue, function(a, b) return a.key < b.key end)

    if active == 0 then
        Status = "Aktif item yok: satmak istediğin satıra tik at ve fiyat yaz"
        return
    end

    local listedThisRound = 0
    while Running do
        local progressed = false
        for _, q in ipairs(queue) do
            if not Running then break end
            if not q.done then
                -- Bitmiş stack'leri atla
                while q.left <= 0 and q.si < #q.g.stacks do
                    q.si += 1
                    q.left = q.g.stacks[q.si].amount
                end
                if q.left <= 0 then
                    q.done = true
                else
                    local stack = q.g.stacks[q.si]
                    local amount = math.min(q.left, MAX_PER_LISTING)
                    local ok, err = Invoke(REMOTE_LIST, stack.uid, q.item.price, amount)
                    log("CreateListing(", DisplayName(q.item.class, q.g), q.item.price, amount, ") ->", tostring(ok), tostring(err))
                    if ok then
                        q.left -= amount
                        progressed = true
                        listedThisRound += 1
                        Stats.listedCount += amount
                        Status = ("Listelendi: %s x%s @ %s"):format(DisplayName(q.item.class, q.g), Fmt(amount), Fmt(q.item.price))
                    else
                        -- Booth dolu ya da fiyat geçersiz: bu turda bu item'ı bırak
                        q.done = true
                    end
                    task.wait(1.5)
                end
            end
        end
        if not progressed then break end
    end

    if listedThisRound == 0 then
        Status = "Yeni listing konamadı (booth dolu ya da fiyat geçersiz), bekleniyor"
    end
end

local function MainLoop()
    while Running do
        if not MyBooth() then
            Status = "Booth alınıyor..."
            if not ClaimBooth() then
                Status = "Booth alınamadı, 10 sn sonra tekrar denenecek"
                task.wait(10)
                continue
            end
            task.wait(2)
        end
        Status = "Booth hazır, listeleniyor..."
        ListAll()
        for _ = 1, RELIST_INTERVAL do
            if not Running then break end
            task.wait(1)
        end
    end
    Status = "Durduruldu"
end

---------------------------------------------------------------- GUI
local C = {
    bg     = Color3.fromRGB(16, 16, 22),
    card   = Color3.fromRGB(28, 28, 38),
    panel  = Color3.fromRGB(20, 20, 27),
    row    = Color3.fromRGB(34, 34, 46),
    btn    = Color3.fromRGB(52, 52, 68),
    accent = Color3.fromRGB(90, 110, 240),
    green  = Color3.fromRGB(40, 150, 75),
    red    = Color3.fromRGB(170, 50, 50),
    gem    = Color3.fromRGB(80, 190, 255),
    text   = Color3.new(1, 1, 1),
    dim    = Color3.fromRGB(150, 150, 170),
}
local VARIANT_COLORS = {
    [0] = Color3.fromRGB(235, 235, 235),
    [1] = Color3.fromRGB(255, 200, 60),
    [2] = Color3.fromRGB(200, 120, 255),
}

local gui = Instance.new("ScreenGui")
gui.Name = "PS99PlazaSell"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end

getgenv().PS99_PLAZA_SELL_STOP = function()
    Running = false
    gui:Destroy()
end

local function corner(p, r) Instance.new("UICorner", p).CornerRadius = UDim.new(0, r or 8) end

local function Label(parent, text, size, pos, ts, font, color)
    local l = Instance.new("TextLabel", parent)
    l.Size, l.Position = size, pos
    l.BackgroundTransparency = 1
    l.TextColor3 = color or C.text
    l.Font = font or Enum.Font.GothamBold
    l.TextSize = ts or 16
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = text
    return l
end

local function Button(parent, text, size, pos, color, ts)
    local b = Instance.new("TextButton", parent)
    b.Size, b.Position = size, pos
    b.BackgroundColor3 = color or C.btn
    b.TextColor3 = C.text
    b.Font = Enum.Font.GothamBold
    b.TextSize = ts or 16
    b.Text = text
    corner(b)
    return b
end

local function TextBox(parent, placeholder, size, pos, ts)
    local t = Instance.new("TextBox", parent)
    t.Size, t.Position = size, pos
    t.BackgroundColor3 = C.panel
    t.TextColor3 = C.text
    t.PlaceholderColor3 = C.dim
    t.PlaceholderText = placeholder
    t.Font = Enum.Font.Gotham
    t.TextSize = ts or 16
    t.ClearTextOnFocus = false
    t.Text = ""
    corner(t)
    return t
end

-- Tam ekran ana pencere
local main = Instance.new("Frame", gui)
main.Size = UDim2.fromScale(1, 1)
main.BackgroundColor3 = C.bg
main.BackgroundTransparency = 0.03
main.Active = true

local header = Instance.new("Frame", main)
header.Size = UDim2.new(1, 0, 0, 56)
header.BackgroundColor3 = C.card
Label(header, "PS99 Plaza Auto Sell", UDim2.new(0, 400, 1, 0), UDim2.fromOffset(24, 0), 22)
local miniGems = Label(header, "", UDim2.new(0, 300, 1, 0), UDim2.fromOffset(24, 0), 15, Enum.Font.GothamBold, C.gem)
miniGems.Visible = false
local minBtn = Button(header, "Küçült", UDim2.fromOffset(110, 36), UDim2.new(1, -134, 0.5, -18))

local body = Instance.new("Frame", main)
body.Size = UDim2.new(1, -48, 1, -76)
body.Position = UDim2.fromOffset(24, 68)
body.BackgroundTransparency = 1

-- İstatistik kartları
local statsRow = Instance.new("Frame", body)
statsRow.Size = UDim2.new(1, 0, 0, 90)
statsRow.BackgroundTransparency = 1
local statsLayout = Instance.new("UIGridLayout", statsRow)
statsLayout.CellSize = UDim2.new(1/6, -10, 1, 0)
statsLayout.CellPadding = UDim2.fromOffset(12, 0)

local function StatCard(title, color)
    local f = Instance.new("Frame", statsRow)
    f.BackgroundColor3 = C.card
    corner(f, 10)
    Label(f, title, UDim2.new(1, -24, 0, 24), UDim2.fromOffset(16, 12), 14, Enum.Font.Gotham, C.dim)
    local v = Label(f, "-", UDim2.new(1, -24, 0, 40), UDim2.fromOffset(16, 38), 30, Enum.Font.GothamBold, color or C.text)
    v.TextScaled = false
    return v
end
local stCurrent = StatCard("Mevcut Gem", C.gem)
local stSession = StatCard("Bu Oturum Kazanç", Color3.fromRGB(110, 230, 130))
local stTotal   = StatCard("Toplam Kazanç (kayıtlı)", Color3.fromRGB(110, 230, 130))
local stHourly  = StatCard("Saatlik Ortalama", Color3.fromRGB(255, 200, 90))
local stListed  = StatCard("Listelenen (bu oturum)")
local stMail    = StatCard("Mail'den Gelen Gem", C.gem)

-- Sekmeler
local tabBar = Instance.new("ScrollingFrame", body)
tabBar.Size = UDim2.new(1, 0, 0, 44)
tabBar.Position = UDim2.fromOffset(0, 104)
tabBar.BackgroundTransparency = 1
tabBar.ScrollBarThickness = 3
tabBar.ScrollingDirection = Enum.ScrollingDirection.X
tabBar.AutomaticCanvasSize = Enum.AutomaticSize.X
tabBar.CanvasSize = UDim2.new()
local tabLayout = Instance.new("UIListLayout", tabBar)
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 8)
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder

-- Arama
local search = TextBox(body, "Ara... (ör. goat)", UDim2.new(1, 0, 0, 40), UDim2.fromOffset(0, 154))
search.TextXAlignment = Enum.TextXAlignment.Left
Instance.new("UIPadding", search).PaddingLeft = UDim.new(0, 12)

-- Liste
local list = Instance.new("ScrollingFrame", body)
list.Size = UDim2.new(1, 0, 1, -300)
list.Position = UDim2.fromOffset(0, 202)
list.BackgroundColor3 = C.panel
list.ScrollBarThickness = 8
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new()
corner(list, 10)
local listLayout = Instance.new("UIListLayout", list)
listLayout.Padding = UDim.new(0, 6)
local listPad = Instance.new("UIPadding", list)
listPad.PaddingTop, listPad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
listPad.PaddingLeft, listPad.PaddingRight = UDim.new(0, 6), UDim.new(0, 14)

local statusLbl = Label(body, "Durum: " .. Status, UDim2.new(1, 0, 0, 26), UDim2.new(0, 0, 1, -90), 15, Enum.Font.Gotham)
statusLbl.TextTruncate = Enum.TextTruncate.AtEnd

local scanBtn  = Button(body, "Envanteri Tara", UDim2.new(1/4, -9, 0, 52), UDim2.new(0, 0, 1, -56))
local debugBtn = Button(body, "Booth Debug",    UDim2.new(1/4, -9, 0, 52), UDim2.new(1/4, 3, 1, -56))
local mailBtn  = Button(body, "Auto Mail: Kapalı", UDim2.new(1/4, -9, 0, 52), UDim2.new(2/4, 6, 1, -56))
local startBtn = Button(body, "Başlat",         UDim2.new(1/4, -9, 0, 52), UDim2.new(3/4, 9, 1, -56), C.green)

local function UpdateMailBtn()
    mailBtn.Text = "Auto Mail: " .. (Config.autoMail and "Açık" or "Kapalı")
    mailBtn.BackgroundColor3 = Config.autoMail and C.green or C.btn
end
mailBtn.MouseButton1Click:Connect(function()
    Config.autoMail = not Config.autoMail
    SaveConfig()
    UpdateMailBtn()
    if Config.autoMail then task.spawn(ClaimMail) end
end)
UpdateMailBtn()

task.spawn(function()
    while gui.Parent do
        for _ = 1, MAIL_INTERVAL do
            if not gui.Parent then return end
            task.wait(1)
        end
        if Config.autoMail then ClaimMail() end
    end
end)

local Inventory = {}
local CurrentTab = "Pet"
local tabButtons = {}
local HIDDEN_CLASSES = { Currency = true }

local function RenderList()
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    local bucket = Inventory[CurrentTab] or {}
    local filter = search.Text:lower()
    local keys = {}
    for k, g in pairs(bucket) do
        if filter == "" or DisplayName(CurrentTab, g):lower():find(filter, 1, true) then
            table.insert(keys, k)
        end
    end
    table.sort(keys, function(a, b) return bucket[a].total > bucket[b].total end)

    for _, k in ipairs(keys) do
        local g = bucket[k]
        local cfg = Config.items[k]

        local row = Instance.new("Frame", list)
        row.Size = UDim2.new(1, 0, 0, 66)
        row.BackgroundColor3 = C.row
        corner(row)

        local chk = Button(row, cfg and cfg.enabled and "✓" or "", UDim2.fromOffset(34, 34), UDim2.new(0, 12, 0.5, -17), C.btn, 20)
        if cfg and cfg.enabled then chk.BackgroundColor3 = C.green end

        local img = Instance.new("ImageLabel", row)
        img.Size = UDim2.fromOffset(56, 56)
        img.Position = UDim2.new(0, 58, 0.5, -28)
        img.BackgroundColor3 = C.panel
        img.ScaleType = Enum.ScaleType.Fit
        img.Image = GetIcon(CurrentTab, g) or ""
        corner(img)
        if g.pt == 2 then
            local grad = Instance.new("UIGradient", img)
            grad.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 120)),
                ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 255, 160)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 140, 255)),
            })
        end

        local name = Label(row, DisplayName(CurrentTab, g), UDim2.new(1, -420, 0, 26), UDim2.fromOffset(128, 8), 18)
        name.TextColor3 = VARIANT_COLORS[g.pt or 0] or C.text
        name.TextTruncate = Enum.TextTruncate.AtEnd
        Label(row, "Adet: " .. Fmt(g.total) .. "  (" .. tostring(g.total) .. ")", UDim2.new(1, -420, 0, 20), UDim2.fromOffset(128, 36), 14, Enum.Font.Gotham, C.dim)

        local price = TextBox(row, "Fiyat (each)", UDim2.fromOffset(200, 42), UDim2.new(1, -214, 0.5, -21), 17)
        price.Text = cfg and cfg.price and cfg.price > 0 and tostring(cfg.price) or ""

        local function update()
            local p = tonumber(price.Text)
            local enabled = chk.Text == "✓"
            chk.BackgroundColor3 = enabled and C.green or C.btn
            if enabled or p then
                Config.items[k] = { class = CurrentTab, id = g.id, pt = g.pt, sh = g.sh, tn = g.tn, price = p or 0, enabled = enabled }
            else
                Config.items[k] = nil
            end
            SaveConfig()
        end
        chk.MouseButton1Click:Connect(function()
            chk.Text = chk.Text == "✓" and "" or "✓"
            update()
        end)
        -- Fiyat yazınca otomatik tik at
        local hadPrice = cfg and cfg.price and cfg.price > 0
        price:GetPropertyChangedSignal("Text"):Connect(function()
            local p = tonumber(price.Text)
            local valid = p ~= nil and p > 0
            if valid and not hadPrice then chk.Text = "✓" end
            hadPrice = valid
            update()
        end)
    end
end

local function SelectTab(class)
    CurrentTab = class
    for c, b in pairs(tabButtons) do
        b.BackgroundColor3 = (c == class) and C.accent or C.btn
    end
    RenderList()
end

local function BuildTabs()
    for _, b in pairs(tabButtons) do b:Destroy() end
    tabButtons = {}
    local order, seen = {}, {}
    for _, c in ipairs(CLASS_ORDER) do
        if Inventory[c] then table.insert(order, c) seen[c] = true end
    end
    local extra = {}
    for c in pairs(Inventory) do
        if not seen[c] and not HIDDEN_CLASSES[c] then table.insert(extra, c) end
    end
    table.sort(extra)
    for _, c in ipairs(extra) do table.insert(order, c) end

    for i, c in ipairs(order) do
        local b = Button(tabBar, CLASS_LABEL[c] or c, UDim2.fromOffset(130, 40), UDim2.new(), C.btn, 15)
        b.LayoutOrder = i
        b.MouseButton1Click:Connect(function() SelectTab(c) end)
        tabButtons[c] = b
    end
    if not Inventory[CurrentTab] then CurrentTab = order[1] or "Pet" end
    SelectTab(CurrentTab)
end

local function Refresh()
    Inventory = ScanInventory()
    BuildTabs()
end

local function SetRunning(v)
    Running = v
    Config.autoStart = v
    SaveConfig()
    startBtn.Text = v and "Durdur" or "Başlat"
    startBtn.BackgroundColor3 = v and C.red or C.green
    if v then task.spawn(MainLoop) end
end

scanBtn.MouseButton1Click:Connect(Refresh)
debugBtn.MouseButton1Click:Connect(DebugBooths)
startBtn.MouseButton1Click:Connect(function() SetRunning(not Running) end)
search:GetPropertyChangedSignal("Text"):Connect(RenderList)

local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    miniGems.Visible = minimized
    header:FindFirstChildWhichIsA("TextLabel").Visible = not minimized
    minBtn.Text = minimized and "Aç" or "Küçült"
    if minimized then
        main.Size = UDim2.fromOffset(460, 56)
        main.Position = UDim2.fromOffset(12, 80)
        main.BackgroundTransparency = 1
        minBtn.Size = UDim2.fromOffset(70, 36)
        minBtn.Position = UDim2.new(1, -82, 0.5, -18)
        corner(header, 10)
    else
        main.Size = UDim2.fromScale(1, 1)
        main.Position = UDim2.new()
        main.BackgroundTransparency = 0.03
        minBtn.Size = UDim2.fromOffset(110, 36)
        minBtn.Position = UDim2.new(1, -134, 0.5, -18)
        local c = header:FindFirstChildOfClass("UICorner")
        if c then c:Destroy() end
    end
end)

-- Gem takibi + ekran güncelleme
local lastSave = os.clock()
task.spawn(function()
    while gui.Parent do
        local cur = GetDiamonds()
        if not Stats.paused then
            local delta = cur - Stats.lastGems
            if delta > 0 then
                Stats.sessionEarned += delta
                Config.totalEarned += delta
            end
            Stats.lastGems = cur
        end
        if os.clock() - lastSave > 30 then SaveConfig() lastSave = os.clock() end

        local hours = math.max((os.clock() - Stats.startTime) / 3600, 1 / 60)
        stCurrent.Text = Fmt(cur)
        stSession.Text = "+" .. Fmt(Stats.sessionEarned)
        stTotal.Text   = "+" .. Fmt(Config.totalEarned)
        stHourly.Text  = Fmt(Stats.sessionEarned / hours) .. "/sa"
        stListed.Text  = Fmt(Stats.listedCount)
        stMail.Text    = "+" .. Fmt(Stats.mailEarned)
        miniGems.Text  = ("Gem: %s  |  Oturum: +%s"):format(Fmt(cur), Fmt(Stats.sessionEarned))
        statusLbl.Text = "Durum: " .. Status
        task.wait(1)
    end
end)

Refresh()
if Config.autoStart then SetRunning(true) end
