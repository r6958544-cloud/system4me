--[[
    sv_job_selector.lua

    Серверная логика меню профессий:
    - смена профессии по запросу клиента с проверкой лимита слотов
      и кулдауна (JOB_CHANGE_COOLDOWN секунд между сменами);
    - выдача/снятие оружия под текущую профессию при выборе и при
      каждом респавне;
    - физган/тулган никогда не выдаются нами сами по себе — они лишь
      НЕ снимаются, если были у игрока непосредственно перед событием
      (перед респавном — на момент смерти; перед выбором профессии —
      на момент выбора, пока игрок ещё жив).

    Вся логика (профессия, слоты, оружие) выполняется только на сервере.
    Клиент лишь отправляет запрос "хочу профессию X" и получает ответ.
]]

if not SERVER then return end

-- Задержка между сменами профессии (в секундах)
local JOB_CHANGE_COOLDOWN = 45

util.AddNetworkString("JobSelector_SelectJob")
util.AddNetworkString("JobSelector_RequestCounts")
util.AddNetworkString("JobSelector_Counts")
util.AddNetworkString("JobSelector_JobFull")
util.AddNetworkString("JobSelector_JobCooldown")
util.AddNetworkString("JobSelector_JobSuccess")
util.AddNetworkString("JobSelector_JobDenied")
util.AddNetworkString("JobSelector_ChangeBlocked")

-- ---------------------------------------------------------------------
-- Считает, сколько игроков сейчас занимают указанную профессию.
-- excludePlayer позволяет не учитывать самого запрашивающего игрока.
-- ---------------------------------------------------------------------
local function CountJobPlayers(job, excludePlayer)
    local count = 0

    for _, target in ipairs(player.GetAll()) do
        if target ~= excludePlayer and target.job == job then
            count = count + 1
        end
    end

    return count
end
JobSelector.CountJobPlayers = CountJobPlayers

-- ---------------------------------------------------------------------
-- Проверяет, есть ли у игрока прямо сейчас физган или тулган.
-- ---------------------------------------------------------------------
local function PlayerHasPreservedTools(ply)
    for _, class in ipairs(JobSelector.PreservedTools) do
        if ply:HasWeapon(class) then
            return true
        end
    end
    return false
end
JobSelector.PlayerHasPreservedTools = PlayerHasPreservedTools

-- ---------------------------------------------------------------------
-- Полностью применяет экипировку профессии игроку:
--   1. снимает всё оружие;
--   2. если keepTools == true — возвращает физган/тулган
--      (мы их не выдаём "от себя", только не даём пропасть тем,
--      что уже были у игрока непосредственно перед событием);
--   3. выдаёт список оружия текущей профессии.
--
-- keepTools вычисляется ДО вызова этой функции — см. использование ниже.
-- ---------------------------------------------------------------------
function JobSelector.ApplyLoadout(ply, job, keepTools)
    local jobData = JobSelector.Jobs[job]
    if not jobData then return end

    ply:StripWeapons()

    if keepTools then
        for _, class in ipairs(JobSelector.PreservedTools) do
            ply:Give(class)
        end
    end

    for _, class in ipairs(jobData.weapons) do
        if not ply:HasWeapon(class) then
            ply:Give(class)
        end
    end
end

-- ---------------------------------------------------------------------
-- Первый заход игрока на сервер в рамках сессии.
-- Если профессия ещё не установлена другим аддоном системы профессий —
-- ставим её по умолчанию. Инструменты на первом спавне не сохраняем —
-- их ещё физически не было (сохранять пока нечего).
-- ---------------------------------------------------------------------
hook.Add("PlayerInitialSpawn", "JobSelector_DefaultJob", function(ply)
    if not ply.job then
        ply.job = "civil"
        ply:SetNWString("job", "civil")
    end

    ply.HadToolsBeforeRespawn = false
end)

-- ---------------------------------------------------------------------
-- Момент смерти — последний момент, когда у игрока ещё реально может
-- быть физган/тулган в инвентаре. Запоминаем это состояние, чтобы
-- использовать его при следующем респавне (когда оружия уже не будет).
-- ---------------------------------------------------------------------
hook.Add("PlayerDeath", "JobSelector_RememberTools", function(ply)
    ply.HadToolsBeforeRespawn = PlayerHasPreservedTools(ply)
end)

-- ---------------------------------------------------------------------
-- Вызывается при каждом спавне игрока (первый вход и респавн после
-- смерти). Обрабатываем только "свои" профессии: без custom == true
-- и присутствующие в JobSelector.Jobs. Профессии сторонних аддонов
-- (custom == true, например "army") пропускаем — их обрабатывает
-- собственный хук PlayerLoadout того аддона.
-- ---------------------------------------------------------------------
hook.Add("PlayerLoadout", "JobSelector_ApplyLoadout", function(ply)
    local job = ply.job or "civil"
    local jobData = JobSelector.Jobs[job]
    if not jobData or jobData.custom then return end

    JobSelector.ApplyLoadout(ply, job, ply.HadToolsBeforeRespawn)
    return true
end)

-- ---------------------------------------------------------------------
-- Клиент запросил смену профессии.
-- ---------------------------------------------------------------------
net.Receive("JobSelector_SelectJob", function(len, ply)
    local job = net.ReadString()
    local jobData = JobSelector.Jobs[job]
    if not jobData then return end

    -- Игрок уже на этой профессии — ничего делать не нужно
    if ply.job == job then return end

    -- Полная блокировка смены профессии (например, игрок сидит в
    -- тюрьме) — проверяется раньше всего остального.
    for _, blocker in pairs(JobSelector.JobChangeBlockers) do
        local reason = blocker(ply)
        if reason then
            net.Start("JobSelector_ChangeBlocked")
                net.WriteString(reason)
            net.Send(ply)
            return
        end
    end

    local oldJob = ply.job -- запоминаем до перезаписи (нужно для OnJobLeft)

    -- Профессии с ограниченным доступом (например "army") — финальная
    -- проверка всегда на сервере, независимо от того, что показывал UI.
    if jobData.requiresPermission then
        local checker = JobSelector.ServerPermissionCheckers[jobData.requiresPermission]
        if not checker or not checker(ply) then
            net.Start("JobSelector_JobDenied")
                net.WriteString(job)
            net.Send(ply)
            return
        end
    end

    -- Проверка кулдауна смены профессии
    local now = CurTime()
    if ply.NextJobChangeAllowed and now < ply.NextJobChangeAllowed then
        net.Start("JobSelector_JobCooldown")
            net.WriteFloat(ply.NextJobChangeAllowed - now)
        net.Send(ply)
        return
    end

    if jobData.maxSlots and CountJobPlayers(job, ply) >= jobData.maxSlots then
        net.Start("JobSelector_JobFull")
            net.WriteString(job)
        net.Send(ply)
        return
    end

    ply.job = job
    ply:SetNWString("job", job)
    ply.NextJobChangeAllowed = now + JOB_CHANGE_COOLDOWN

    -- Уведомляем старую профессию, что игрок с неё ушёл (например,
    -- чтобы вернуть модель/бодигруппы, которые были до входа в неё)
    local leftHandler = JobSelector.OnJobLeft[oldJob]
    if leftHandler then
        leftHandler(ply, job)
    end

    -- "Подготовка" новой профессии — вызывается ВСЕГДА, даже если
    -- следующим шагом игрока убьют (например, чтобы успеть сохранить
    -- модель/бодигруппы до того, как персонаж исчезнет при смерти).
    local prepareHandler = JobSelector.OnJobPrepare[job]
    if prepareHandler then
        prepareHandler(ply)
    end

    -- Некоторые переходы (например гражданский <-> военный) требуют
    -- "перерождения" персонажа. Сначала убиваем — это обязательный шаг,
    -- SSRP_RespawnPlayer вызывается для УЖЕ мёртвого игрока и ничего не
    -- делает, если вызвать её на живом. Затем сразу вызываем
    -- SSRP_RespawnPlayer для самого респавна — если гейммод не
    -- респавнит игроков автоматически после смерти (как ванильный
    -- Sandbox), обычная смерть без этого вызова оставила бы игрока
    -- висеть мёртвым/на экране респавна. Если функции нет — просто
    -- убиваем и полагаемся на респавн гейммода по умолчанию.
    if JobSelector.ShouldKillOnTransition(oldJob, job) and ply:Alive() then
        ply:Kill()

        if SSRP_RespawnPlayer then
            SSRP_RespawnPlayer(ply)
        end
    elseif jobData.custom then
        -- Профессия стороннего аддона — сам решает, что делать
        -- (спавн, оружие, модель и т.д.)
        local handler = JobSelector.OnJobSelected[job]
        if handler and ply:Alive() then
            handler(ply)
        end
    elseif ply:Alive() then
        -- Игрок жив прямо сейчас — проверяем его текущий инвентарь
        -- ДО того, как он будет снят.
        local keepTools = PlayerHasPreservedTools(ply)
        JobSelector.ApplyLoadout(ply, job, keepTools)
    end
    -- Если игрок мёртв (или его только что убили выше) — экипировка
    -- применится при респавне через PlayerLoadout, используя
    -- ply.HadToolsBeforeRespawn (см. PlayerDeath).

    net.Start("JobSelector_JobSuccess")
        net.WriteString(job)
    net.Send(ply)
end)

-- ---------------------------------------------------------------------
-- Клиент запросил актуальное количество занятых слотов (для меню).
-- Отправляем для ВСЕХ профессий с лимитом (maxSlots ~= nil), а не
-- только для одной захардкоженной — так новые профессии с лимитом
-- (например "turner") сразу показывают актуальное число мест.
-- ---------------------------------------------------------------------
net.Receive("JobSelector_RequestCounts", function(len, ply)
    local limited = {}
    for jobId, jobData in pairs(JobSelector.Jobs) do
        if jobData.maxSlots then
            limited[#limited + 1] = jobId
        end
    end

    net.Start("JobSelector_Counts")
        net.WriteUInt(#limited, 8)
        for _, jobId in ipairs(limited) do
            net.WriteString(jobId)
            net.WriteUInt(CountJobPlayers(jobId), 8)
        end
    net.Send(ply)
end)
