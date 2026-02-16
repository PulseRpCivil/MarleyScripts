Config = {}

-- ========== Debug ==========
Config.Debug = true
Config.DebugProduction = false

-- ========== Prices ==========
Config.BuyPrice = 250000
Config.SellPrice = 175000

-- ========== Repair ==========
Config.RepairTime = 5
Config.RepairToHealth = 100
Config.WearPriceMultiplier = 1.0

-- ========== Oil rig ==========
Config.TargetModel = `p_oil_pjack_03_s`
Config.MaxUseDistance = 6.0

Config.Parts = {
  { id = 'belt',       label = 'Ремень привода',        price = 5000 },
  { id = 'valve',      label = 'Клапан давления',       price = 7500 },
  { id = 'bearing',    label = 'Подшипник',             price = 6500 },
  { id = 'filter',     label = 'Фильтр масла',          price = 3000 },
  { id = 'controller', label = 'Блок управления',       price = 12000 },
}

Config.InitialHealthMin = 65
Config.InitialHealthMax = 100

-- ========== Banking (p_banking) ==========
Config.UsePBanking = true
Config.PBankingCreateHistory = true
Config.TransactionTitles = {
  buy = 'Oil Rig Purchase',
  sell = 'Oil Rig Sell',
  repair = 'Oil Rig Repair'
}

-- ========== Stash (ox_inventory) ==========
Config.StashSlots = 40
Config.StashMaxWeight = 2000000
Config.StashLabel = 'Склад нефтяной вышки'

-- ========== Production ==========
Config.OilItem = 'oil'
Config.OilPerHour = 500
Config.ProductionTickSeconds = 10
Config.EarlyTickSeconds = 10
Config.MenuAutoRefreshSeconds = 5

-- Event ACK timeout (ms) for start/stop requests
Config.ProductionRequestTimeout = 8000

-- ========== Maintenance ==========
Config.MaintenanceHours = 12
Config.StopProductionOnBreak = true

-- ========== Registry / Scan ==========
Config.ScanDefaultRadius = 200.0


-- ========== Map blips ==========
-- Работают для вышек, которые есть в таблице oilrig_rigs (регистрируются командой /oilrig_scan).
Config.Blips = {
  Enabled = true,


  -- false = видно по всей карте (рекомендуется)
  ShortRange = false,

  ForSale = {
    sprite = 441,      -- можно заменить на любой blip sprite id
    color = 2,         -- зелёный
    scale = 0.75,
    label = 'Нефтяная вышка (в продаже)'
  },

  Owned = {
    sprite = 441,
    color = 1,         -- красный
    scale = 0.75,
    label = 'Нефтяная вышка (куплена)'
  }
}


-- ========== Refinery / Sales (Stage 2) ==========
Config.OilItem = Config.OilItem or 'oil' -- "нефть"

Config.Refinery = {
  Enabled = true,

  -- Координаты точки продажи/переработки
  Coords = vector3(1713.28, -1555.23, 113.93),

  -- Если Z в конфиге неточный, можно привязать таргет к земле автоматически
  UseGroundZ = true,
  GroundProbeHeight = 100.0,


  -- ox_target зона
  TargetRadius = 3.0,
  TargetDistance = 3.5,


  -- Время переработки одной операции (сек). По ТЗ: 5 минут.
  ProcessDurationSeconds = 300,

  -- Повторная попытка создать target-зону, если ox_target ещё не поднялся
  TargetRetrySeconds = 2.0,
  TargetRetryMax = 30,


  -- Продажа нефти (за 1 шт.)
  SellPricePerUnit = 25,

  -- Переработка (сколько нефти нужно на 1 продукт)
  Recipes = {
    rubber = { oil = 5, item = 'rubber', out = 1, label = 'Резина' },
    plastic = { oil = 3, item = 'plastic', out = 1, label = 'Пластик' },
  }
}


-- ========== Rig registry (pre-seeded rigs) ==========
-- Идея: все вышки заранее перечислены тут, сервер при старте сам заносит их в БД (oilrig_rigs),
-- чтобы каждая имела постоянный уникальный идентификатор (rig_key + rig_id в БД).
--
-- Как быстро заполнить список:
-- 1) Встань рядом с вышкой и используй существующий /oilrig_scan (если есть) или добавь свои координаты вручную
-- 2) Скопируй координаты сюда.
--
-- Формат:
-- { id = 'rig_001', coords = vector3(x,y,z), deposit = 15000 } -- deposit в "единицах нефти" (т.е. oil)
Config.Rigs = {
  -- Пример (замени на свои реальные точки):
  -- { id = 'rig_001', coords = vector3(695.02, 2886.95, 48.79), deposit = 50000 },
}

Config.Deposit = {
  Enabled = true,
  -- если у вышки нет своего deposit, будет использован этот дефолт
  DefaultTotal = 15000
}


-- ========== Oil License ==========
-- Требование лицензии для покупки/владения нефтевышкой.
Config.License = {
  Enabled = true,
  Item = 'oillicense',        -- item name in ox_inventory (добавь предмет в items)
  Price = 50000,               -- цена лицензии (банк)
  Coords = vector3(1710.50, -1562.10, 113.93), -- точка покупки лицензии (рядом с НПЗ, можешь поменять)
  TargetRadius = 1.8,
  TargetDistance = 2.5,
  Icon = 'id-card',
  IconColor = 'yellow',
  ValidDays = 30 -- срок действия лицензии (дней). 0 = бессрочно
}

-- cooldown после истощения месторождения
Config.DepositCooldownSeconds = 7 * 24 * 60 * 60 -- 7 дней

-- Workers (права доступа для работников вышки)
Config.Workers = {
  DefaultPerms = { stash = false, production = false, repair = true }, -- по умолчанию: только ремонт
}
