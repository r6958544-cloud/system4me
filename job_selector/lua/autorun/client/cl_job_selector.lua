--[[
    cl_job_selector.lua

    Клиентское F4-меню выбора профессии.
    Стиль: синяя тема, скруглённые углы, на весь экран.
    Слева — 3 пункта: "Профессия", "Навигатор" и "Инфо".

    Кулдаун смены профессии (45 сек, задаётся на сервере) отображается
    прямо на кнопке "Выбрать", звук проигрывается при неудачной попытке
    (КД / нет мест) и при успешной смене профессии.

    Вкладка "Навигатор": список точек с расстоянием в метрах. При выборе
    точки меню закрывается, взгляд игрока разворачивается в её сторону,
    и на экране (сквозь стены) появляется метка "название + расстояние".
    Метка исчезает, когда игрок подходит ближе 3 метров. Выбор новой
    точки заменяет текущую навигацию.

    Меню открывается по нажатию F4. Клавиша отслеживается через
    input.IsKeyDown в хуке Think (с защитой от повторного срабатывания
    при удержании), так как RunConsoleCommand("bind", ...) заблокирован
    движком для вызова из Lua.
]]

if not CLIENT then return end

surface.CreateFont("JobSelector_Title", {
    font = "Roboto",
    size = 26,
    weight = 700,
})

surface.CreateFont("JobSelector_Job", {
    font = "Roboto",
    size = 20,
    weight = 600,
})

surface.CreateFont("JobSelector_Text", {
    font = "Roboto",
    size = 16,
    weight = 400,
})

-- ---------------------------------------------------------------------
-- Цветовая палитра (синяя тема)
-- ---------------------------------------------------------------------
local COLOR_BG          = Color(22, 34, 62, 250)
local COLOR_BG_LIGHT    = Color(30, 46, 82, 250)
local COLOR_SIDEBAR     = Color(15, 24, 46, 255)
local COLOR_CARD        = Color(36, 54, 94, 255)
local COLOR_CARD_HOV    = Color(42, 62, 106, 255)
local COLOR_ACCENT      = Color(55, 120, 250, 255)
local COLOR_ACCENT_HOV  = Color(80, 145, 255, 255)
local COLOR_ACCENT_DIM  = Color(55, 120, 250, 60)
local COLOR_DANGER      = Color(120, 55, 60, 255)
local COLOR_DANGER_HOV  = Color(150, 65, 70, 255)
local COLOR_TEXT        = Color(235, 240, 255)
local COLOR_TEXT_DIM    = Color(160, 175, 210)
local COLOR_SHADOW      = Color(0, 0, 0, 70)

-- Используем системные звуки переключения оружия — они есть в любой
-- сборке GMod без зависимости от контента HL2, поэтому точно
-- воспроизведутся (в отличие от некоторых "buttons/*.wav").
local SOUND_FAIL    = "common/wpn_denyselect.wav"
local SOUND_SUCCESS = "common/wpn_select.wav"
local SOUND_HOVER   = "ui/buttonrollover.wav"

local CHAT_PREFIX = { Color(80, 145, 255), "[Профессии] " }

local jobCounts = {}
local jobFrame
local nextJobChangeAllowed = 0 -- локальная копия для отображения КД на кнопках

-- ---------------------------------------------------------------------
-- Плавный переход цвета для hover-эффектов. Панель хранит собственную
-- "долю" (0..1) и приближает её к цели каждый кадр — без таймеров,
-- просто в Paint (который и так вызывается ежекадрово).
-- ---------------------------------------------------------------------
local function LerpHover(panel, isHovered)
    panel._hoverFrac = Lerp(FrameTime() * 9, panel._hoverFrac or 0, isHovered and 1 or 0)
    return panel._hoverFrac
end

local function LerpColorFrac(frac, from, to)
    return Color(
        Lerp(frac, from.r, to.r),
        Lerp(frac, from.g, to.g),
        Lerp(frac, from.b, to.b),
        Lerp(frac, from.a, to.a)
    )
end

-- Карточка с лёгкой тенью — используется для строк профессий/точек/списков
local function DrawCard(w, h, baseColor)
    draw.RoundedBox(10, 2, 4, w, h, COLOR_SHADOW)
    draw.RoundedBox(10, 0, 0, w, h, baseColor)
end

-- Единый стиль скроллбара для всех списков в меню
function JobSelector.StyleScrollbar(scrollPanel)
    local vbar = scrollPanel:GetVBar()
    vbar:SetWide(6)
    vbar.Paint = function(self, w, h)
        draw.RoundedBox(3, 0, 0, w, h, Color(255, 255, 255, 15))
    end
    vbar.btnUp.Paint = function() end
    vbar.btnDown.Paint = function() end
    vbar.btnGrip.Paint = function(self, w, h)
        draw.RoundedBox(3, 0, 0, w, h, COLOR_ACCENT)
    end
end

-- ---------------------------------------------------------------------
-- Сеть
-- ---------------------------------------------------------------------
local function RequestCounts()
    net.Start("JobSelector_RequestCounts")
    net.SendToServer()
end

local function SelectJob(jobId)
    net.Start("JobSelector_SelectJob")
        net.WriteString(jobId)
    net.SendToServer()
end

net.Receive("JobSelector_Counts", function()
    local count = net.ReadUInt(8)

    jobCounts = {}
    for i = 1, count do
        local jobId = net.ReadString()
        jobCounts[jobId] = net.ReadUInt(8)
    end

    if IsValid(jobFrame) and jobFrame.RefreshJobsList then
        jobFrame:RefreshJobsList()
    end
end)

-- Не удалось зайти на профессию: все места заняты
net.Receive("JobSelector_JobFull", function()
    local jobId = net.ReadString()
    local jobData = JobSelector.Jobs[jobId]
    local label = jobData and jobData.name or jobId

    surface.PlaySound(SOUND_FAIL)
    chat.AddText(CHAT_PREFIX[1], CHAT_PREFIX[2], Color(255, 255, 255), label .. ": все места заняты")
end)

-- Попытка сменить профессию во время кулдауна
net.Receive("JobSelector_JobCooldown", function()
    local remaining = net.ReadFloat()
    nextJobChangeAllowed = CurTime() + remaining -- синхронизируемся с сервером

    surface.PlaySound(SOUND_FAIL)
    chat.AddText(
        CHAT_PREFIX[1], CHAT_PREFIX[2],
        Color(255, 255, 255), "Сменить профессию можно через ",
        Color(255, 130, 130), math.ceil(remaining) .. " сек."
    )
end)

-- Успешная смена профессии
net.Receive("JobSelector_JobSuccess", function()
    local jobId = net.ReadString()
    local jobData = JobSelector.Jobs[jobId]

    nextJobChangeAllowed = CurTime() + 45

    surface.PlaySound(SOUND_SUCCESS)
    chat.AddText(
        CHAT_PREFIX[1], CHAT_PREFIX[2],
        Color(255, 255, 255), "Вы выбрали профессию: ",
        Color(130, 255, 150), jobData and jobData.name or jobId
    )
end)

-- Отказ: недостаточно прав на выбранную профессию
net.Receive("JobSelector_JobDenied", function()
    local jobId = net.ReadString()
    local jobData = JobSelector.Jobs[jobId]

    surface.PlaySound(SOUND_FAIL)
    chat.AddText(CHAT_PREFIX[1], CHAT_PREFIX[2], Color(255, 130, 130), "Нет доступа к профессии: ", Color(255, 255, 255), jobData and jobData.name or jobId)
end)

-- Отказ: смена профессии полностью заблокирована (например, тюрьма)
net.Receive("JobSelector_ChangeBlocked", function()
    local reason = net.ReadString()

    surface.PlaySound(SOUND_FAIL)
    chat.AddText(CHAT_PREFIX[1], CHAT_PREFIX[2], Color(255, 130, 130), reason)
end)

-- ---------------------------------------------------------------------
-- Навигация
-- ---------------------------------------------------------------------
local ARRIVAL_DISTANCE_METERS = 3

local navTarget -- { name = "...", pos = Vector(...) } или nil

-- Запускает навигацию на точку: закрывает меню, разворачивает взгляд,
-- включает метку. Выбор новой точки автоматически заменяет старую,
-- так как navTarget — одна переменная.
local function StartNavigation(loc)
    navTarget = loc

    local ply = LocalPlayer()
    if IsValid(ply) then
        local dir = (loc.pos - ply:EyePos()):Angle()
        ply:SetEyeAngles(dir)
    end
end

-- Метка на экране (сквозь стены — используется чистая проекция
-- в экранные координаты без трассировки видимости) + проверка прибытия.
hook.Add("HUDPaint", "JobSelector_NavHUD", function()
    if not navTarget then return end

    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    local distanceMeters = ply:GetPos():Distance(navTarget.pos) / JobSelector.UnitsPerMeter

    if distanceMeters <= ARRIVAL_DISTANCE_METERS then
        chat.AddText(CHAT_PREFIX[1], CHAT_PREFIX[2], Color(255, 255, 255), "Вы прибыли: ", Color(130, 255, 150), navTarget.name)
        surface.PlaySound(SOUND_SUCCESS)
        navTarget = nil
        return
    end

    local screenPos = navTarget.pos:ToScreen()
    if not screenPos.visible then return end

    draw.SimpleTextOutlined(navTarget.name, "JobSelector_Job", screenPos.x, screenPos.y - 10, COLOR_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, Color(0, 0, 0, 220))
    draw.SimpleTextOutlined(string.format("%.0f м", distanceMeters), "JobSelector_Text", screenPos.x, screenPos.y + 14, COLOR_ACCENT_HOV, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, Color(0, 0, 0, 220))
end)

-- ---------------------------------------------------------------------
-- Кнопка вкладки сайдбара (общий конструктор)
-- ---------------------------------------------------------------------
local function CreateSidebarButton(parent, text, yPos, onClick)
    local btn = vgui.Create("DButton", parent)
    btn:SetPos(16, yPos)
    btn:SetSize(168, 44)
    btn:SetText("")
    btn.active = false

    btn.Paint = function(self, w, h)
        local hoverFrac = LerpHover(self, self:IsHovered())
        local activeFrac = Lerp(FrameTime() * 9, self._activeFrac or 0, self.active and 1 or 0)
        self._activeFrac = activeFrac

        local col = LerpColorFrac(math.max(hoverFrac * 0.5, activeFrac), color_transparent, COLOR_ACCENT)
        draw.RoundedBox(8, 0, 0, w, h, col)

        -- Полоска-индикатор активной вкладки слева
        if activeFrac > 0.02 then
            surface.SetDrawColor(255, 255, 255, 255 * activeFrac)
            surface.DrawRect(0, 8, 3, h - 16)
        end

        local textCol = LerpColorFrac(math.max(hoverFrac, activeFrac), COLOR_TEXT_DIM, COLOR_TEXT)
        draw.SimpleText(text, "JobSelector_Text", 18, h / 2, textCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    btn.OnCursorEntered = function(self)
        surface.PlaySound(SOUND_HOVER)
    end

    btn.DoClick = function()
        surface.PlaySound("ui/buttonclick.wav")
        onClick()
    end

    return btn
end

-- ---------------------------------------------------------------------
-- Строка профессии в списке "Профессия"
-- ---------------------------------------------------------------------
local function CreateJobRow(parent, jobId, jobData)
    local row = vgui.Create("DPanel", parent)
    row:Dock(TOP)
    row:DockMargin(0, 0, 0, 12)
    row:SetTall(108)
    row.Paint = function(self, w, h)
        local hoverFrac = LerpHover(self, self:IsHovered())
        DrawCard(w, h, LerpColorFrac(hoverFrac, COLOR_CARD, COLOR_CARD_HOV))
        surface.SetDrawColor(COLOR_ACCENT.r, COLOR_ACCENT.g, COLOR_ACCENT.b, 255)
        surface.DrawRect(0, 10, 3, h - 20)
    end

    local name = vgui.Create("DLabel", row)
    name:SetPos(28, 10)
    name:SetSize(320, 24)
    name:SetFont("JobSelector_Job")
    name:SetTextColor(COLOR_TEXT)
    name:SetText(jobData.name)

    local description = vgui.Create("DLabel", row)
    description:SetPos(28, 36)
    description:SetSize(0, 34) -- ширина выставляется в PerformLayout (зависит от кнопки справа)
    description:SetFont("JobSelector_Text")
    description:SetTextColor(COLOR_TEXT_DIM)
    description:SetWrap(true)
    description:SetAutoStretchVertical(false)
    description:SetText(jobData.description or "")

    local sub = vgui.Create("DLabel", row)
    sub:SetPos(28, 78)
    sub:SetSize(320, 20)
    sub:SetFont("JobSelector_Text")
    sub:SetTextColor(COLOR_TEXT_DIM)

    local function IsFull()
        return jobData.maxSlots ~= nil and (jobCounts[jobId] or 0) >= jobData.maxSlots
    end

    local function IsOnCooldown()
        return CurTime() < nextJobChangeAllowed
    end

    if jobData.maxSlots then
        sub:SetText("Занято мест: " .. (jobCounts[jobId] or 0) .. " / " .. jobData.maxSlots)
    else
        sub:SetText("Без ограничения мест")
    end

    local selectBtn = vgui.Create("DButton", row)
    selectBtn:SetText("")
    selectBtn:SetSize(140, 42)
    selectBtn:SetPos(row:GetWide() - 160, 33)

    selectBtn.Paint = function(self, w, h)
        local hoverFrac = LerpHover(self, self:IsHovered())
        local col, label

        if IsFull() then
            col, label = COLOR_DANGER, "Нет мест"
        elseif IsOnCooldown() then
            col = COLOR_DANGER
            label = "КД: " .. math.max(0, math.ceil(nextJobChangeAllowed - CurTime())) .. "с"
        else
            col = LerpColorFrac(hoverFrac, COLOR_ACCENT, COLOR_ACCENT_HOV)
            label = "Выбрать"
        end

        draw.RoundedBox(8, 0, 0, w, h, col)
        draw.SimpleText(label, "JobSelector_Text", w / 2, h / 2, COLOR_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    selectBtn.DoClick = function()
        if IsFull() then
            surface.PlaySound(SOUND_FAIL)
            chat.AddText(CHAT_PREFIX[1], CHAT_PREFIX[2], Color(255, 255, 255), jobData.name .. ": все места заняты")
            return
        end

        if IsOnCooldown() then
            surface.PlaySound(SOUND_FAIL)
            chat.AddText(
                CHAT_PREFIX[1], CHAT_PREFIX[2],
                Color(255, 255, 255), "Сменить профессию можно через ",
                Color(255, 130, 130), math.max(0, math.ceil(nextJobChangeAllowed - CurTime())) .. " сек."
            )
            return
        end

        SelectJob(jobId)
        if IsValid(jobFrame) then
            jobFrame:Close()
        end
    end

    -- Кнопка выбора всегда прижата к правому краю строки, описание
    -- тянется до неё, оставляя отступ
    row.PerformLayout = function(self, w, h)
        selectBtn:SetPos(w - 160, 33)
        description:SetSize(w - 28 - 180, 34)
    end

    return row
end

-- ---------------------------------------------------------------------
-- Строка точки в списке "Навигатор"
-- ---------------------------------------------------------------------
local function CreateLocationRow(parent, loc)
    local row = vgui.Create("DPanel", parent)
    row:Dock(TOP)
    row:DockMargin(0, 0, 0, 12)
    row:SetTall(78)
    row.Paint = function(self, w, h)
        local hoverFrac = LerpHover(self, self:IsHovered())
        DrawCard(w, h, LerpColorFrac(hoverFrac, COLOR_CARD, COLOR_CARD_HOV))
        surface.SetDrawColor(COLOR_ACCENT.r, COLOR_ACCENT.g, COLOR_ACCENT.b, 255)
        surface.DrawRect(0, 10, 3, h - 20)
    end

    local name = vgui.Create("DLabel", row)
    name:SetPos(28, 12)
    name:SetSize(320, 26)
    name:SetFont("JobSelector_Job")
    name:SetTextColor(COLOR_TEXT)
    name:SetText(loc.name)

    local sub = vgui.Create("DLabel", row)
    sub:SetPos(28, 42)
    sub:SetSize(320, 20)
    sub:SetFont("JobSelector_Text")
    sub:SetTextColor(COLOR_TEXT_DIM)

    sub:SetText("Расстояние: — м")

    -- Дистанция обновляется каждый кадр через Think — VGUI вызывает
    -- его автоматически, пока панель видима, без ручных таймеров.
    sub.Think = function(self)
        local ply = LocalPlayer()
        if not IsValid(ply) then return end

        local meters = ply:GetPos():Distance(loc.pos) / JobSelector.UnitsPerMeter
        self:SetText(string.format("Расстояние: %.0f м", meters))
    end

    local goBtn = vgui.Create("DButton", row)
    goBtn:SetText("")
    goBtn:SetSize(160, 42)
    goBtn:SetPos(row:GetWide() - 180, 18)

    goBtn.Paint = function(self, w, h)
        local hoverFrac = LerpHover(self, self:IsHovered())
        local col = LerpColorFrac(hoverFrac, COLOR_ACCENT, COLOR_ACCENT_HOV)
        draw.RoundedBox(8, 0, 0, w, h, col)
        draw.SimpleText("Проложить путь", "JobSelector_Text", w / 2, h / 2, COLOR_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    goBtn.DoClick = function()
        StartNavigation(loc)
        surface.PlaySound(SOUND_SUCCESS)
        if IsValid(jobFrame) then
            jobFrame:Close()
        end
    end

    row.PerformLayout = function(self, w, h)
        goBtn:SetPos(w - 180, 18)
    end

    return row
end

-- ---------------------------------------------------------------------
-- Создание окна меню
-- ---------------------------------------------------------------------
local HEADER_H = 76

local function CreateJobMenu()
    local frameW, frameH = ScrW(), ScrH()

    local frame = vgui.Create("DFrame")
    frame:SetSize(frameW, frameH)
    frame:SetPos(0, 0)
    frame:SetTitle("")
    frame:ShowCloseButton(false)
    frame:SetDraggable(false)
    frame:MakePopup()

    frame.Paint = function(self, w, h)
        draw.RoundedBox(0, 0, 0, w, h, COLOR_BG)
        draw.RoundedBoxEx(0, 0, 0, w, HEADER_H, COLOR_SIDEBAR, false, false, false, false)

        -- Тонкая акцентная линия под шапкой + разделитель сайдбар/контент
        surface.SetDrawColor(COLOR_ACCENT.r, COLOR_ACCENT.g, COLOR_ACCENT.b, 140)
        surface.DrawRect(0, HEADER_H - 2, w, 2)

        surface.SetDrawColor(255, 255, 255, 12)
        surface.DrawLine(200, HEADER_H, 200, h)
    end

    local title = vgui.Create("DLabel", frame)
    title:SetPos(26, 14)
    title:SetSize(400, 30)
    title:SetFont("JobSelector_Title")
    title:SetTextColor(COLOR_TEXT)
    title:SetText("Serbia Side RP")

    local subtitle = vgui.Create("DLabel", frame)
    subtitle:SetPos(28, 44)
    subtitle:SetSize(400, 20)
    subtitle:SetFont("JobSelector_Text")
    subtitle:SetTextColor(COLOR_TEXT_DIM)
    subtitle:SetText("Меню игрока — F4")

    -- Аватар и ник игрока в правой части шапки
    local ply = LocalPlayer()

    local avatar = vgui.Create("AvatarImage", frame)
    avatar:SetSize(44, 44)
    avatar:SetPos(frameW - 240, HEADER_H / 2 - 22)
    if IsValid(ply) then
        avatar:SetPlayer(ply, 44)
    end

    local nick = vgui.Create("DLabel", frame)
    nick:SetPos(frameW - 186, HEADER_H / 2 - 20)
    nick:SetSize(140, 20)
    nick:SetFont("JobSelector_Job")
    nick:SetTextColor(COLOR_TEXT)
    nick:SetText(IsValid(ply) and ply:Nick() or "")

    local jobLabel = vgui.Create("DLabel", frame)
    jobLabel:SetPos(frameW - 186, HEADER_H / 2 + 2)
    jobLabel:SetSize(140, 18)
    jobLabel:SetFont("JobSelector_Text")
    jobLabel:SetTextColor(COLOR_TEXT_DIM)
    jobLabel.Think = function(self)
        if not IsValid(ply) then return end
        local jobId = ply:GetNWString("job", "civil")
        local jobData = JobSelector.Jobs[jobId]
        self:SetText(jobData and jobData.name or jobId)
    end

    local closeBtn = vgui.Create("DButton", frame)
    closeBtn:SetText("")
    closeBtn:SetSize(36, 36)
    closeBtn:SetPos(frameW - 50, HEADER_H / 2 - 18)
    closeBtn.Paint = function(self, w, h)
        local hoverFrac = LerpHover(self, self:IsHovered())
        draw.RoundedBox(8, 0, 0, w, h, LerpColorFrac(hoverFrac, COLOR_CARD, COLOR_DANGER_HOV))
        draw.SimpleText("×", "JobSelector_Job", w / 2, h / 2 - 1, COLOR_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    closeBtn.DoClick = function()
        surface.PlaySound("ui/buttonclickrelease.wav")
        frame:Close()
    end

    -- Сайдбар слева
    local sidebar = vgui.Create("DPanel", frame)
    sidebar:SetPos(0, HEADER_H)
    sidebar:SetSize(200, frameH - HEADER_H)
    sidebar.Paint = function(self, w, h)
        draw.RoundedBoxEx(14, 0, 0, w, h, COLOR_SIDEBAR, false, false, false, true)
    end

    -- Контейнер контента справа
    local content = vgui.Create("DPanel", frame)
    content:SetPos(200, HEADER_H)
    content:SetSize(frameW - 200, frameH - HEADER_H)
    content.Paint = function() end

    -- Вкладка "Профессия"
    local jobsPanel = vgui.Create("DScrollPanel", content)
    jobsPanel:Dock(FILL)
    jobsPanel:DockMargin(20, 20, 20, 20)
    JobSelector.StyleScrollbar(jobsPanel)

    -- Вкладка "Навигатор"
    local navPanel = vgui.Create("DScrollPanel", content)
    navPanel:Dock(FILL)
    navPanel:DockMargin(20, 20, 20, 20)
    navPanel:SetVisible(false)
    JobSelector.StyleScrollbar(navPanel)

    for _, loc in ipairs(JobSelector.Locations) do
        CreateLocationRow(navPanel, loc)
    end

    -- Вкладка "Инфо"
    local infoPanel = vgui.Create("DPanel", content)
    infoPanel:Dock(FILL)
    infoPanel:DockMargin(20, 20, 20, 20)
    infoPanel.Paint = function() end
    infoPanel:SetVisible(false)

    local infoLabel = vgui.Create("DLabel", infoPanel)
    infoLabel:Dock(TOP)
    infoLabel:SetFont("JobSelector_Text")
    infoLabel:SetTextColor(COLOR_TEXT_DIM)
    infoLabel:SetText("Информация о сервере появится здесь позже.")
    infoLabel:SetWrap(true)
    infoLabel:SetAutoStretchVertical(true)

    function frame:RefreshJobsList()
        jobsPanel:Clear()
        for _, jobId in ipairs(JobSelector.JobOrder) do
            local jobData = JobSelector.Jobs[jobId]
            local allowed = true

            if jobData.requiresPermission then
                local checker = JobSelector.PermissionCheckers[jobData.requiresPermission]
                allowed = checker ~= nil and checker() == true
            end

            if allowed then
                CreateJobRow(jobsPanel, jobId, jobData)
            end
        end
    end

    -- Переключение вкладок (generic-система: базовые вкладки + те, что
    -- зарегистрировали сторонние аддоны через JobSelector.ExtraTabs)
    local tabs = {} -- { { button = ..., panel = ... }, ... }

    local function ShowTab(index)
        for i, tab in ipairs(tabs) do
            tab.panel:SetVisible(i == index)
            tab.button.active = (i == index)
        end
    end

    local tabYPos = 20
    local function AddTab(label, panel)
        local index = #tabs + 1
        local btn = CreateSidebarButton(sidebar, label, tabYPos, function() ShowTab(index) end)
        tabYPos = tabYPos + 52
        tabs[index] = { button = btn, panel = panel }
        return index
    end

    AddTab("Профессия", jobsPanel)
    AddTab("Навигатор", navPanel)

    -- Вкладки сторонних аддонов (например "Список армии" от army_job).
    -- Добавляются и сразу (если права уже известны), и динамически позже
    -- через frame:RefreshExtraTabs() — на случай, если ответ сервера
    -- о правах ещё не пришёл в момент открытия меню.
    local addedExtraTabIds = {}

    local function TryAddExtraTab(tabDef)
        if addedExtraTabIds[tabDef.id] then return end
        if tabDef.visible and not tabDef.visible() then return end

        local extraPanel = vgui.Create("DPanel", content)
        extraPanel:Dock(FILL)
        extraPanel:DockMargin(20, 20, 20, 20)
        extraPanel.Paint = function() end
        extraPanel:SetVisible(false)

        tabDef.build(extraPanel)

        AddTab(tabDef.label, extraPanel)
        addedExtraTabIds[tabDef.id] = true
    end

    for _, tabDef in ipairs(JobSelector.ExtraTabs) do
        TryAddExtraTab(tabDef)
    end

    function frame:RefreshExtraTabs()
        for _, tabDef in ipairs(JobSelector.ExtraTabs) do
            TryAddExtraTab(tabDef)
        end
    end

    AddTab("Инфо", infoPanel)

    ShowTab(1)
    frame:RefreshJobsList()

    return frame
end

-- ---------------------------------------------------------------------
-- Открытие/закрытие меню
-- ---------------------------------------------------------------------

-- Позволяет сторонним аддонам (например army_job) дозаявить свою
-- вкладку, если их проверка прав пришла с сервера уже после того,
-- как окно меню было построено.
function JobSelector.RefreshExtraTabs()
    if IsValid(JobSelector.Frame) and JobSelector.Frame.RefreshExtraTabs then
        JobSelector.Frame:RefreshExtraTabs()
    end
end

local function ToggleJobMenu()
    if IsValid(jobFrame) then
        jobFrame:Close()
        jobFrame = nil
        JobSelector.Frame = nil
        return
    end

    -- Запрашиваем свежие данные (слоты, права и т.д.) при каждом
    -- открытии меню — без этого пришлось бы переподключаться к серверу,
    -- чтобы увидеть изменения прав/списков.
    RequestCounts()
    hook.Run("JobSelector_MenuOpened")

    jobFrame = CreateJobMenu()
    JobSelector.Frame = jobFrame
end

-- Оставляем команду доступной (например, для привязки через свой
-- собственный bind в консоли, если понадобится вручную).
concommand.Add("jobselector_togglemenu", ToggleJobMenu)

-- ---------------------------------------------------------------------
-- Отслеживание нажатия F4.
-- Команда "bind" заблокирована движком для вызова из Lua
-- (RunConsoleCommand("bind", ...) не сработает), поэтому вместо
-- принудительного бинда просто следим за состоянием клавиши раз
-- за кадр с защитой от повторного срабатывания при удержании.
-- ---------------------------------------------------------------------
local f4WasDown = false

hook.Add("Think", "JobSelector_WatchF4", function()
    local isDown = input.IsKeyDown(KEY_F4)

    if isDown and not f4WasDown then
        ToggleJobMenu()
    end

    f4WasDown = isDown
end)
