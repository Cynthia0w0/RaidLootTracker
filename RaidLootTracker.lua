-- 团队装备需求记录 (Raid Loot Tracker)
-- 功能：
--   1. 小图标开关记录表格，展示上次记录的团队成员
--   2. 一键读取当前队伍/团队成员名称
--   3. Boss 结束后记录掉落分配：需求(骰子) / 贪婪(金币) / 幻化(紫色头盔) / 撤销(删除记录)
--   4. 历史记录：查看已记录的装备分配明细
--   5. 彩蛋：右键成员可登记/取消「最狗团员」，并标记狗头

local ADDON_NAME = "RaidLootTracker"
local addon = CreateFrame("Frame")
addon.name = ADDON_NAME
addon.version = "1.0.0"
_G["RaidLootTracker"] = addon

local DB_NAME = "RaidLootTrackerDB"

----------------------------------------------------------------
-- 工具函数
----------------------------------------------------------------
local function ItemLinkToName(link)
    if not link then return nil end
    return link:match("%[(.-)%]")
end

local function ItemLinkToID(link)
    local id = link and link:match("Hitem:(%d+)")
    return id and tonumber(id)
end

local function ItemLinkToIcon(link)
    local id = ItemLinkToID(link)
    if id and GetItemIcon then
        return GetItemIcon(id)
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function ClassColor(classFile)
    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local c = RAID_CLASS_COLORS[classFile]
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

----------------------------------------------------------------
-- 默认数据
----------------------------------------------------------------
-- 计算「本周四 07:00 (UTC+8)」对应的稳定周标识；每到周四 07:00 该值会跳变一次
local function GetWeeklyResetKey()
    local utc = GetServerTime()
    local t = utc + 8 * 3600                    -- 转为 UTC+8 墙钟时间
    local dayIndex = math.floor(t / 86400)
    local secondsIntoDay = t % 86400
    -- 在 UTC+8 坐标系下，1970-01-01 00:00 是周三，故 dayIndex % 7 == 1 时是周四
    local daysSinceThursday = (dayIndex - 1) % 7
    local secondsSinceReset = daysSinceThursday * 86400 + secondsIntoDay - 7 * 3600
    if secondsSinceReset < 0 then
        secondsSinceReset = secondsSinceReset + 7 * 86400
    end
    return utc - secondsSinceReset
end

local defaults = {
    members = {},      -- { {name=..., class=...}, ... }
    bosses = {},       -- { {name=..., timestamp=..., items={...} }, ... }
    pendingLoot = {},  -- { {link=..., name=..., status=nil, winner=nil}, ... }
    currentBoss = "",
    weekStart = nil,
    dogMember = nil,
}

local DB

local function InitializeDB()
    if not _G[DB_NAME] then
        _G[DB_NAME] = {}
    end
    DB = _G[DB_NAME]
    for k, v in pairs(defaults) do
        if DB[k] == nil then
            DB[k] = v
        end
    end
end

----------------------------------------------------------------
-- 数据模块
----------------------------------------------------------------
local Data = {}
addon.Data = Data

function Data:AddMember(name, classFile)
    if not name or name == "" then return end
    for _, m in ipairs(DB.members) do
        if m.name == name then
            if classFile and not m.class then
                m.class = classFile
            end
            return
        end
    end
    table.insert(DB.members, { name = name, class = classFile })
end

function Data:ClearMembers()
    DB.members = {}
end

function Data:GetBoss(name)
    for _, b in ipairs(DB.bosses) do
        if b.name == name then
            return b
        end
    end
    return nil
end

function Data:GetOrCreateBoss(name)
    local boss = self:GetBoss(name)
    if not boss then
        boss = { name = name, timestamp = GetServerTime(), items = {} }
        table.insert(DB.bosses, boss)
    end
    return boss
end

function Data:AddLootRecord(bossName, itemLink, itemName, winner, lootType)
    local boss = self:GetOrCreateBoss(bossName)
    local record = {
        link = itemLink,
        name = itemName,
        winner = winner,
        type = lootType,
        time = GetServerTime(),
    }
    table.insert(boss.items, record)
    return boss, record
end

function Data:RemoveLootRecord(boss, record)
    if not boss or not record then return false end
    for i, it in ipairs(boss.items) do
        if it == record then
            table.remove(boss.items, i)
            return true
        end
    end
    return false
end

function Data:GetAllRecords()
    local records = {}
    for _, b in ipairs(DB.bosses) do
        for _, it in ipairs(b.items) do
            table.insert(records, {
                bossName = b.name,
                itemName = it.name,
                winner = it.winner,
                type = it.type,
                time = it.time,
            })
        end
    end
    table.sort(records, function(a, b)
        return (a.time or 0) < (b.time or 0)
    end)
    return records
end

function Data:GetDogMember()
    return DB.dogMember
end

function Data:ToggleDogMember(name)
    if DB.dogMember == name then
        DB.dogMember = nil
    else
        DB.dogMember = name
    end
end

function Data:GetMemberSummary(name)
    local need, greed, transmog = {}, {}, {}
    for _, b in ipairs(DB.bosses) do
        for _, it in ipairs(b.items) do
            if it.winner == name then
                if it.type == "need" then
                    table.insert(need, it.name)
                elseif it.type == "greed" then
                    table.insert(greed, it.name)
                elseif it.type == "transmog" then
                    table.insert(transmog, it.name)
                end
            end
        end
    end
    return need, greed, transmog
end

function Data:GetTotalItemCount()
    local n = 0
    for _, b in ipairs(DB.bosses) do
        n = n + #b.items
    end
    return n
end

function Data:AddPendingLoot(link)
    local name = ItemLinkToName(link)
    if not name then return end
    table.insert(DB.pendingLoot, { link = link, name = name, status = nil, winner = nil })
end

function Data:AddPendingLootIfMissing(link)
    local name = ItemLinkToName(link)
    if not name then return end
    for _, p in ipairs(DB.pendingLoot) do
        if p.link == link then
            return
        end
    end
    table.insert(DB.pendingLoot, { link = link, name = name, status = nil, winner = nil })
end

function Data:ClearPendingLoot()
    DB.pendingLoot = {}
end

function Data:CheckWeeklyReset()
    local key = GetWeeklyResetKey()
    if not DB.weekStart then
        DB.weekStart = key
        return
    end
    if DB.weekStart ~= key then
        DB.weekStart = key
        DB.bosses = {}
        print("|cff00ff00团队装备需求记录|r：检测到新的一周（周四 07:00），已清空上周记录。")
    end
end

function Data:ResetWeek()
    DB.weekStart = GetWeeklyResetKey()
    DB.bosses = {}
    DB.pendingLoot = {}
    DB.currentBoss = ""
end

----------------------------------------------------------------
-- 队伍模块
----------------------------------------------------------------
local Group = {}
addon.Group = Group

function Group:GetCurrentMembers()
    local list = {}
    local function add(unit)
        local name = UnitName(unit)
        if name then
            local _, classFile = UnitClass(unit)
            table.insert(list, { name = name, class = classFile })
        end
    end

    add("player")
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() - 1 do
            add("raid" .. i)
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            add("party" .. i)
        end
    end
    return list
end

function Group:ReadIntoDB()
    for _, m in ipairs(self:GetCurrentMembers()) do
        Data:AddMember(m.name, m.class)
    end
    return #DB.members
end

----------------------------------------------------------------
-- 掉落模块
----------------------------------------------------------------
local Loot = {}
addon.Loot = Loot

local function GetBossName(encounterID, encounterName)
    if encounterName and encounterName ~= "" then
        return encounterName
    end
    if encounterID then
        if EJ_GetEncounterInfo then
            local ok, name = pcall(EJ_GetEncounterInfo, encounterID)
            if ok and name and name ~= "" then
                return name
            end
        end
        if C_EncounterInfo and C_EncounterInfo.GetEncounterInfo then
            local ok, info = pcall(C_EncounterInfo.GetEncounterInfo, encounterID)
            if ok and info and info.name and info.name ~= "" then
                return info.name
            end
        end
    end
    local instanceName = select(1, GetInstanceInfo())
    return instanceName or ("Boss " .. tostring(encounterID or "?"))
end

function Loot:CaptureLootWindow()
    local count = 0
    if GetNumLootItems then
        count = GetNumLootItems()
    elseif GetLootInfo then
        count = GetLootInfo()
    end
    if count and count > 0 then
        for i = 1, count do
            if GetLootSlotLink then
                local link = GetLootSlotLink(i)
                if link then
                    Data:AddPendingLoot(link)
                end
            end
        end
    end
end

function Loot:CaptureHistory()
    if not C_LootHistory or not C_LootHistory.GetNumItems then
        return
    end
    local ok, n = pcall(C_LootHistory.GetNumItems)
    if not ok then
        return
    end
    for i = 1, n do
        local ok2, item = pcall(C_LootHistory.GetItem, i)
        if ok2 and item then
            local link = item.itemLink or item.link
            if link then
                Data:AddPendingLoot(link)
            end
        end
    end
end

function Loot:OnEncounterStart()
    Data:ClearPendingLoot()
    DB.currentBoss = ""
end

function Loot:OnEncounterEnd(encounterID, encounterName, difficultyID, groupSize, success)
    if success ~= 1 then
        return
    end
    if not IsInRaid() then
        return
    end
    DB.currentBoss = GetBossName(encounterID, encounterName)
    self:CaptureHistory()
    if addon.UI and addon.UI.OpenLoot then
        addon.UI:OpenLoot()
    end
end

function Loot:OnChatLoot(msg)
    for link in msg:gmatch("|c%x+|Hitem:%d+.-|h%[[^%]]+%]|h|r") do
        Data:AddPendingLootIfMissing(link)
    end
end

----------------------------------------------------------------
-- UI 模块
----------------------------------------------------------------
local UI = {}
addon.UI = UI

local function SetFrameTitle(frame, text)
    if frame.TitleText then
        frame.TitleText:SetText(text)
        return
    end
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    if frame.TitleBg then
        title:SetPoint("TOP", frame.TitleBg, "TOP", 0, -6)
    else
        title:SetPoint("TOP", 0, -8)
    end
    title:SetText(text)
    frame.titleText = title
end

local function CreateScrollList(parent, rowHeight)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -26, 4)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    local list = {
        scroll = scroll,
        content = content,
        rowHeight = rowHeight,
        rows = {},
    }

    function list:SetData(data, rowFactory, update)
        for _, row in ipairs(self.rows) do
            row:Hide()
        end

        local n = #data
        local w = self.scroll:GetWidth() or 260
        if w < 20 then
            w = 260
        end
        self.content:SetWidth(w)
        self.content:SetHeight(math.max(1, n) * self.rowHeight)

        for i = 1, n do
            local row = self.rows[i]
            if not row then
                row = rowFactory(self.content)
                self.rows[i] = row
            end
            row:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -(i - 1) * self.rowHeight)
            row:SetSize(w, self.rowHeight)
            update(row, data[i], i)
            row:Show()
        end

        if self.scroll.GetVerticalScroll and self.scroll.SetVerticalScroll then
            local cur = self.scroll:GetVerticalScroll()
            self.scroll:SetVerticalScroll(cur or 0)
        end
    end

    return list
end

local function MakeSelectableRow(row)
    row:EnableMouse(true)
    row:RegisterForClicks("LeftButtonUp")
    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints(row)
    hl:SetTexture("Interface\\Buttons\\WHITE8x8")
    hl:SetVertexColor(0.3, 0.6, 1, 0.35)
    hl:Hide()
    row.highlight = hl

    row:SetScript("OnEnter", function(self)
        if not self._selected then
            self.highlight:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        if not self._selected then
            self.highlight:Hide()
        end
    end)
end

local function SetSelected(row, selected)
    row._selected = selected
    if selected then
        row.highlight:Show()
    else
        row.highlight:Hide()
    end
end

local function CreateMainMemberRow(content)
    local row = CreateFrame("Button", nil, content)
    row:EnableMouse(true)
    row:RegisterForClicks("RightButtonUp")

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("LEFT", row, "LEFT", 32, 0)
    name:SetPoint("RIGHT", row, "RIGHT", -120, 0)
    name:SetJustifyH("LEFT")

    local dogIcon = row:CreateTexture(nil, "OVERLAY")
    dogIcon:SetSize(18, 18)
    dogIcon:SetPoint("LEFT", row, "LEFT", 8, 0)
    dogIcon:SetTexture("Interface\\Icons\\INV_Pet_Dog")
    dogIcon:Hide()
    row.dogIcon = dogIcon

    local summary = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("RIGHT", row, "RIGHT", -8, 0)

    row.nameText = name
    row.summary = summary

    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" and self.member then
            addon.Data:ToggleDogMember(self.member.name)
            UI:RefreshMain()
        end
    end)

    row:SetScript("OnEnter", function(self)
        if not self.member then return end
        local need, greed, transmog = addon.Data:GetMemberSummary(self.member.name)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.member.name)
        if #need > 0 then
            GameTooltip:AddLine("|cff33ccff需求：" .. table.concat(need, "、") .. "|r")
        end
        if #greed > 0 then
            GameTooltip:AddLine("|cffffcc33贪婪：" .. table.concat(greed, "、") .. "|r")
        end
        if #transmog > 0 then
            GameTooltip:AddLine("|cffa335ee幻化：" .. table.concat(transmog, "、") .. "|r")
        end
        if #need == 0 and #greed == 0 and #transmog == 0 then
            GameTooltip:AddLine("|cff999999本周暂无记录|r")
        end
        GameTooltip:AddLine("|cffffcc00右键点击可登记/取消最狗团员|r")
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return row
end

local function CreateLootItemRow(content)
    local row = CreateFrame("Button", nil, content)
    MakeSelectableRow(row)

    local icon = row:CreateTexture(nil, "OVERLAY")
    icon:SetSize(24, 24)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    name:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    name:SetJustifyH("LEFT")

    row.icon = icon
    row.nameText = name
    row:SetScript("OnClick", function(self)
        UI:SelectItem(self.item)
    end)
    return row
end

local function CreateLootMemberRow(content)
    local row = CreateFrame("Button", nil, content)
    MakeSelectableRow(row)

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("LEFT", row, "LEFT", 8, 0)
    name:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    name:SetJustifyH("LEFT")

    row.nameText = name
    row:SetScript("OnClick", function(self)
        UI:SelectMember(self.member)
    end)
    return row
end

local function CreateChoiceButton(parent, upTex, downTex, labelText, r, g, b, iconColor)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(38, 38)
    btn:RegisterForClicks("LeftButtonUp")
    btn:EnableMouse(true)
    btn:SetNormalTexture(upTex)
    btn:SetPushedTexture(downTex)
    btn:SetHighlightTexture(upTex)
    btn:GetHighlightTexture():SetBlendMode("ADD")
    if iconColor then
        btn:GetNormalTexture():SetVertexColor(iconColor[1], iconColor[2], iconColor[3])
        btn:GetPushedTexture():SetVertexColor(iconColor[1], iconColor[2], iconColor[3])
        btn:GetHighlightTexture():SetVertexColor(iconColor[1], iconColor[2], iconColor[3])
    end

    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetText(labelText)
    label:SetPoint("TOP", btn, "BOTTOM", 0, -2)
    label:SetTextColor(r, g, b)
    btn.label = label
    return btn
end

local function CreateHistoryRow(content)
    local row = CreateFrame("Button", nil, content)
    row:EnableMouse(true)

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", row, "LEFT", 8, 0)
    text:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    text:SetJustifyH("LEFT")

    row.text = text
    row:SetScript("OnEnter", function(self)
        if self.record then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.record.itemName)
            GameTooltip:AddLine(("|cff999999%s → %s|r"):format(self.record.bossName, self.record.winner))
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return row
end

function UI:CreateIconButton()
    local btn = CreateFrame("Button", nil, UIParent)
    btn:SetSize(32, 32)
    btn:RegisterForClicks("LeftButtonUp")
    btn:EnableMouse(true)
    btn:SetMovable(true)
    btn:RegisterForDrag("LeftButton")
    btn:SetNormalTexture("Interface\\Icons\\INV_Misc_Coin_01")
    btn:SetPushedTexture("Interface\\Icons\\INV_Misc_Coin_01")
    btn:SetHighlightTexture("Interface\\Icons\\INV_Misc_Coin_01")
    btn:GetHighlightTexture():SetBlendMode("ADD")
    btn:SetFrameStrata("MEDIUM")

    btn:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    btn:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)
    btn:SetScript("OnClick", function()
        UI:ToggleMain()
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("团队装备需求记录")
        GameTooltip:AddLine("点击打开/关闭记录表格")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    if Minimap then
        btn:SetPoint("BOTTOMLEFT", Minimap, "BOTTOMLEFT", -2, 2)
    else
        btn:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -80)
    end
    btn:Show()
    self.iconButton = btn
end

function UI:CreateMainFrame()
    local f = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(460, 440)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetToplevel(true)
    f:Hide()

    SetFrameTitle(f, "团队装备需求记录")

    if f.CloseButton then
        f.CloseButton:SetScript("OnClick", function() f:Hide() end)
    else
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
        close:SetScript("OnClick", function() f:Hide() end)
    end

    local info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -38)
    f.info = info

    local list = CreateScrollList(f, 42)
    list.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -60)
    list.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 70)
    f.memberList = list

    local function makeButton(text, index, y, onClick)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(82, 22)
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14 + (index - 1) * 88, y)
        b:SetText(text)
        b:SetNormalFontObject("GameFontHighlightSmall")
        b:SetScript("OnClick", onClick)
        return b
    end

    makeButton("读取队伍", 1, 38, function()
        local n = addon.Group:ReadIntoDB()
        UI:RefreshMain()
        print(("|cff00ff00团队装备需求记录|r：已读取 %d 名成员。"):format(n))
    end)

    makeButton("记录掉落", 2, 38, function()
        UI:OpenLoot()
    end)

    makeButton("历史记录", 3, 38, function()
        UI:ToggleHistory()
    end)

    makeButton("打印报告", 4, 38, function()
        UI:ExportReport()
    end)

    makeButton("导出CSV", 5, 38, function()
        UI:ExportCSV()
    end)

    makeButton("重置本周", 1, 12, function()
        addon.Data:ResetWeek()
        UI:RefreshMain()
        print("|cff00ff00团队装备需求记录|r：已开始新的一周。")
    end)

    makeButton("清空记录", 2, 12, function()
        DB.bosses = {}
        UI:RefreshMain()
        print("|cff00ff00团队装备需求记录|r：已清空本周掉落记录。")
    end)

    makeButton("清空成员", 3, 12, function()
        addon.Data:ClearMembers()
        UI:RefreshMain()
        print("|cff00ff00团队装备需求记录|r：已清空成员列表。")
    end)

    f:Hide()
    self.mainFrame = f
end

function UI:CreateLootFrame()
    local f = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(820, 560)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetToplevel(true)
    f:Hide()

    SetFrameTitle(f, "掉落分配记录")

    if f.CloseButton then
        f.CloseButton:SetScript("OnClick", function() f:Hide() end)
    else
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
        close:SetScript("OnClick", function() f:Hide() end)
    end

    local bossLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bossLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -40)
    bossLabel:SetText("Boss：")

    local bossEdit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    bossEdit:SetSize(220, 20)
    bossEdit:SetPoint("LEFT", bossLabel, "RIGHT", 4, 0)
    bossEdit:SetAutoFocus(false)
    bossEdit:SetText("")
    f.bossEdit = bossEdit

    local targetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    targetBtn:SetSize(76, 20)
    targetBtn:SetPoint("LEFT", bossEdit, "RIGHT", 4, 0)
    targetBtn:SetText("当前目标")
    targetBtn:SetNormalFontObject("GameFontHighlightSmall")
    targetBtn:SetScript("OnClick", function()
        local name = UnitName("target")
        if name then
            bossEdit:SetText(name)
        else
            print("|cff00ff00团队装备需求记录|r：当前没有目标。")
        end
    end)

    local addLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    addLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -66)
    addLabel:SetText("手动添加(Shift+点击物品)：")

    local addEdit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    addEdit:SetSize(220, 20)
    addEdit:SetPoint("LEFT", addLabel, "RIGHT", 4, 0)
    addEdit:SetAutoFocus(false)
    addEdit:SetHyperlinksEnabled(true)
    f.addEdit = addEdit

    local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addBtn:SetSize(50, 20)
    addBtn:SetPoint("LEFT", addEdit, "RIGHT", 4, 0)
    addBtn:SetText("添加")
    addBtn:SetNormalFontObject("GameFontHighlightSmall")
    addBtn:SetScript("OnClick", function()
        local link = addEdit:GetText()
        if link and link ~= "" then
            addon.Data:AddPendingLoot(link)
            addEdit:SetText("")
            UI:RefreshLoot()
        end
    end)

    local itemList = CreateScrollList(f, 30)
    itemList.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -110)
    itemList.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -440, 90)
    f.itemList = itemList

    local memberList = CreateScrollList(f, 32)
    memberList.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 410, -110)
    memberList.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 90)
    f.memberList = memberList

    local itemHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemHeader:SetPoint("BOTTOMLEFT", itemList.scroll, "TOPLEFT", 0, 2)
    itemHeader:SetText("本次掉落")

    local memberHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    memberHeader:SetPoint("BOTTOMLEFT", memberList.scroll, "TOPLEFT", 0, 2)
    memberHeader:SetText("选择成员")

    local legend = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    legend:SetPoint("TOPRIGHT", memberList.scroll, "BOTTOMRIGHT", 0, 2)
    legend:SetText("需求=骰子  贪婪=金币  幻化=头盔  撤销=删除记录")

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    status:SetPoint("TOPLEFT", itemList.scroll, "BOTTOMLEFT", 0, 2)
    status:SetText("请先选择装备和成员")
    f.statusText = status

    local needBtn = CreateChoiceButton(f,
        "Interface\\Buttons\\UI-GroupLoot-Dice-Up",
        "Interface\\Buttons\\UI-GroupLoot-Dice-Down",
        "需求", 0.2, 0.8, 1)
    needBtn:SetPoint("BOTTOM", f, "BOTTOM", -135, 28)

    local greedBtn = CreateChoiceButton(f,
        "Interface\\Buttons\\UI-GroupLoot-Coin-Up",
        "Interface\\Buttons\\UI-GroupLoot-Coin-Down",
        "贪婪", 1, 0.8, 0.2)
    greedBtn:SetPoint("BOTTOM", f, "BOTTOM", -45, 28)

    local transmogBtn = CreateChoiceButton(f,
        "Interface\\Icons\\INV_Helmet_01",
        "Interface\\Icons\\INV_Helmet_01",
        "幻化", 0.64, 0.21, 0.93, {0.64, 0.21, 0.93})
    transmogBtn:SetPoint("BOTTOM", f, "BOTTOM", 45, 28)

    local undoBtn = CreateChoiceButton(f,
        "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
        "Interface\\Buttons\\UI-GroupLoot-Pass-Down",
        "撤销", 0.9, 0.2, 0.2)
    undoBtn:SetPoint("BOTTOM", f, "BOTTOM", 135, 28)

    needBtn:SetScript("OnClick", function()
        UI:AssignLoot(UI.currentItem, UI.currentMember and UI.currentMember.name, "need")
    end)
    greedBtn:SetScript("OnClick", function()
        UI:AssignLoot(UI.currentItem, UI.currentMember and UI.currentMember.name, "greed")
    end)
    transmogBtn:SetScript("OnClick", function()
        UI:AssignLoot(UI.currentItem, UI.currentMember and UI.currentMember.name, "transmog")
    end)
    undoBtn:SetScript("OnClick", function()
        UI:UndoLoot(UI.currentItem)
    end)

    needBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("需求（骰子）")
        GameTooltip:AddLine("将该装备记为「需求」获得")
        GameTooltip:Show()
    end)
    greedBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("贪婪（金币）")
        GameTooltip:AddLine("将该装备记为「贪婪」获得")
        GameTooltip:Show()
    end)
    transmogBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("幻化（紫色头盔）")
        GameTooltip:AddLine("将该装备记为「幻化」获得")
        GameTooltip:Show()
    end)
    undoBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("撤销（删除记录）")
        GameTooltip:AddLine("删除该装备已记录的内容")
        GameTooltip:Show()
    end)
    for _, b in ipairs({ needBtn, greedBtn, transmogBtn, undoBtn }) do
        b:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    local readBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    readBtn:SetSize(100, 22)
    readBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 14)
    readBtn:SetText("读取掉落")
    readBtn:SetNormalFontObject("GameFontHighlightSmall")
    readBtn:SetScript("OnClick", function()
        addon.Loot:CaptureLootWindow()
        addon.Loot:CaptureHistory()
        UI:RefreshLoot()
    end)

    local doneBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    doneBtn:SetSize(100, 22)
    doneBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
    doneBtn:SetText("完成")
    doneBtn:SetNormalFontObject("GameFontHighlightSmall")
    doneBtn:SetScript("OnClick", function()
        addon.Data:ClearPendingLoot()
        f:Hide()
    end)

    f:Hide()
    self.lootFrame = f
end

function UI:ToggleMain()
    if not self.mainFrame then
        self:CreateMainFrame()
    end
    if self.mainFrame:IsShown() then
        self.mainFrame:Hide()
    else
        self.mainFrame:Show()
        self:RefreshMain()
    end
end

function UI:RefreshMain()
    if not self.mainFrame then return end
    local members = DB.members
    local dogName = addon.Data:GetDogMember()
    self.mainFrame.memberList:SetData(members, CreateMainMemberRow, function(row, m)
        row.member = m
        local r, g, b = ClassColor(m.class)
        row.nameText:SetText(m.name)
        row.nameText:SetTextColor(r, g, b)
        row.dogIcon:SetShown(dogName == m.name)
        local need, greed, transmog = addon.Data:GetMemberSummary(m.name)
        row.summary:SetText(("需求%d 贪婪%d 幻化%d"):format(#need, #greed, #transmog))
        if #need > 0 then
            row.summary:SetTextColor(0.2, 0.8, 1)
        elseif #greed > 0 then
            row.summary:SetTextColor(1, 0.8, 0.2)
        elseif #transmog > 0 then
            row.summary:SetTextColor(0.64, 0.21, 0.93)
        else
            row.summary:SetTextColor(0.6, 0.6, 0.6)
        end
    end)
    local infoText = ("本周成员 %d 人 · 已记录 %d 件装备"):format(#members, addon.Data:GetTotalItemCount())
    if dogName then
        infoText = infoText .. " · 最狗团员：" .. dogName
    end
    self.mainFrame.info:SetText(infoText)
end

function UI:SelectItem(item)
    self.currentItem = item
    self:RefreshLoot()
end

function UI:SelectMember(member)
    self.currentMember = member
    self:RefreshLoot()
end

function UI:UpdateStatus()
    if not self.lootFrame then return end
    local txt = "请先选择装备和成员，然后点击需求/贪婪/幻化/撤销"
    if self.currentItem then
        txt = "已选装备：" .. self.currentItem.name
        if self.currentMember then
            txt = txt .. "   已选成员：" .. self.currentMember.name
        end
    end
    self.lootFrame.statusText:SetText(txt)
end

function UI:RefreshLoot()
    local f = self.lootFrame
    if not f then return end

    f.itemList:SetData(DB.pendingLoot, CreateLootItemRow, function(row, item)
        row.item = item
        row.icon:SetTexture(ItemLinkToIcon(item.link))
        local suffix = ""
        if item.status == "need" then
            suffix = "  |cff33ccff[需求 " .. (item.winner or "") .. "]|r"
        elseif item.status == "greed" then
            suffix = "  |cffffcc33[贪婪 " .. (item.winner or "") .. "]|r"
        elseif item.status == "transmog" then
            suffix = "  |cffa335ee[幻化 " .. (item.winner or "") .. "]|r"
        end
        row.nameText:SetText(item.name .. suffix)
        SetSelected(row, self.currentItem == item)
    end)

    local members = addon.Group:GetCurrentMembers()
    f.memberList:SetData(members, CreateLootMemberRow, function(row, m)
        row.member = m
        local r, g, b = ClassColor(m.class)
        row.nameText:SetText(m.name)
        row.nameText:SetTextColor(r, g, b)
        SetSelected(row, self.currentMember == m)
    end)

    self:UpdateStatus()
end

function UI:AssignLoot(item, memberName, lootType)
    if not item then
        self:SetStatus("请先选择一件装备")
        return
    end
    if not memberName then
        self:SetStatus("请先选择一名成员")
        return
    end

    local bossName = self.lootFrame.bossEdit:GetText()
    if not bossName or bossName == "" then
        bossName = DB.currentBoss or "未知Boss"
    end

    local boss, record = addon.Data:AddLootRecord(bossName, item.link, item.name, memberName, lootType)
    item.boss = boss
    item.record = record
    item.status = lootType
    item.winner = memberName
    self.currentItem = nil
    self.currentMember = nil
    self:RefreshLoot()
    self:RefreshMain()
end

function UI:UndoLoot(item)
    if not item then
        self:SetStatus("请先选择一件装备")
        return
    end
    if not item.record then
        self:SetStatus("该装备还没有已记录的内容")
        return
    end

    addon.Data:RemoveLootRecord(item.boss, item.record)
    item.boss = nil
    item.record = nil
    item.status = nil
    item.winner = nil
    self.currentItem = nil
    self.currentMember = nil
    self:RefreshLoot()
    self:RefreshMain()
end

function UI:SetStatus(text)
    if self.lootFrame then
        self.lootFrame.statusText:SetText(text)
    end
end

function UI:OpenLoot()
    if not self.lootFrame then
        self:CreateLootFrame()
    end
    local f = self.lootFrame
    f.bossEdit:SetText(DB.currentBoss or "")
    self.currentItem = nil
    self.currentMember = nil
    f:Show()
    self:RefreshLoot()
end

function UI:CreateHistoryFrame()
    local f = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(560, 420)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetToplevel(true)
    f:Hide()

    SetFrameTitle(f, "装备分配历史")

    if f.CloseButton then
        f.CloseButton:SetScript("OnClick", function() f:Hide() end)
    else
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
        close:SetScript("OnClick", function() f:Hide() end)
    end

    local list = CreateScrollList(f, 24)
    list.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -42)
    list.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 16)
    f.recordList = list

    f:Hide()
    self.historyFrame = f
end

function UI:RefreshHistory()
    if not self.historyFrame then return end
    local records = addon.Data:GetAllRecords()
    self.historyFrame.recordList:SetData(records, CreateHistoryRow, function(row, rec)
        row.record = rec
        local typeTag
        if rec.type == "need" then
            typeTag = "|cff33ccff[需求]|r"
        elseif rec.type == "greed" then
            typeTag = "|cffffcc33[贪婪]|r"
        else
            typeTag = "|cffa335ee[幻化]|r"
        end
        row.text:SetText(("%s %s · %s → %s"):format(typeTag, rec.bossName, rec.itemName, rec.winner))
    end)
end

function UI:ToggleHistory()
    if not self.historyFrame then
        self:CreateHistoryFrame()
    end
    if self.historyFrame:IsShown() then
        self.historyFrame:Hide()
    else
        self.historyFrame:Show()
        self:RefreshHistory()
    end
end

function UI:ExportReport()
    local lines = { "=== 团队装备需求记录 ===" }
    for _, m in ipairs(DB.members) do
        local need, greed, transmog = addon.Data:GetMemberSummary(m.name)
        if #need > 0 or #greed > 0 or #transmog > 0 then
            local parts = {}
            if #need > 0 then
                table.insert(parts, "需求：" .. table.concat(need, "、"))
            end
            if #greed > 0 then
                table.insert(parts, "贪婪：" .. table.concat(greed, "、"))
            end
            if #transmog > 0 then
                table.insert(parts, "幻化：" .. table.concat(transmog, "、"))
            end
            table.insert(lines, m.name .. " — " .. table.concat(parts, "；"))
        end
    end

    -- 逐行打印到聊天窗口，直接可见
    for _, line in ipairs(lines) do
        print(line)
    end

    -- 同时写入聊天输入框，方便复制或发送
    if DEFAULT_CHAT_FRAME then
        ChatFrame_OpenChat(table.concat(lines, "\n"), DEFAULT_CHAT_FRAME)
    end
end

function UI:ExportCSV()
    local records = addon.Data:GetAllRecords()
    local lines = { "团员名称,装备名称,需求/贪婪/幻化" }
    for _, rec in ipairs(records) do
        local typeName = "幻化"
        if rec.type == "need" then
            typeName = "需求"
        elseif rec.type == "greed" then
            typeName = "贪婪"
        end
        table.insert(lines, table.concat({ rec.winner, rec.itemName, typeName }, ","))
    end

    local csv = table.concat(lines, "\n")
    if DEFAULT_CHAT_FRAME then
        ChatFrame_OpenChat(csv, DEFAULT_CHAT_FRAME)
    end
    print("|cff00ff00团队装备需求记录|r：CSV 已复制到聊天输入框，请粘贴到文本文件并另存为 .csv。")
end
----------------------------------------------------------------
-- 修复：Shift+点击物品时，把物品链接插入「手动添加」输入框
----------------------------------------------------------------
if HandleModifiedItemClick then
    local origHandleModifiedItemClick = HandleModifiedItemClick
    HandleModifiedItemClick = function(link, ...)
        local f = UI.lootFrame
        if f and f.addEdit and f.addEdit:HasFocus() then
            f.addEdit:Insert(link)
        else
            return origHandleModifiedItemClick(link, ...)
        end
    end
end

----------------------------------------------------------------
-- 事件与斜杠命令
----------------------------------------------------------------
addon:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        InitializeDB()
        Data:CheckWeeklyReset()
        UI:CreateIconButton()
        UI:CreateMainFrame()
        UI:CreateLootFrame()
        print("|cff00ff00团队装备需求记录|r：已加载。输入 /rlt 打开记录，/rlt loot 打开掉落分配。")
    elseif event == "GROUP_ROSTER_UPDATE" then
        if DB and UI.lootFrame and UI.lootFrame:IsShown() then
            UI:RefreshLoot()
        end
    elseif event == "ENCOUNTER_START" then
        if DB then
            addon.Loot:OnEncounterStart(...)
        end
    elseif event == "ENCOUNTER_END" then
        if DB then
            addon.Loot:OnEncounterEnd(...)
        end
    elseif event == "LOOT_OPENED" then
        if DB and IsInRaid() and #DB.pendingLoot == 0 then
            addon.Loot:CaptureLootWindow()
        end
    elseif event == "CHAT_MSG_LOOT" then
        if DB then
            addon.Loot:OnChatLoot(...)
        end
    end
end)

addon:RegisterEvent("PLAYER_LOGIN")
addon:RegisterEvent("GROUP_ROSTER_UPDATE")
addon:RegisterEvent("ENCOUNTER_START")
addon:RegisterEvent("ENCOUNTER_END")
addon:RegisterEvent("LOOT_OPENED")
addon:RegisterEvent("CHAT_MSG_LOOT")

SLASH_RAIDLOOTTRACKER1 = "/rlt"
SLASH_RAIDLOOTTRACKER2 = "/raidloot"
SlashCmdList["RAIDLOOTTRACKER"] = function(msg)
    if not DB then
        return
    end
    msg = (msg or ""):lower()
    if msg == "reset" then
        Data:ResetWeek()
        UI:RefreshMain()
        print("|cff00ff00团队装备需求记录|r：已重置本周记录。")
    elseif msg == "loot" then
        UI:OpenLoot()
    else
        UI:ToggleMain()
    end
end
