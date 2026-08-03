math.randomseed(os.time())
local ox_inventory = exports.ox_inventory

local function dbg(msg, ...)
  if not Config.Debug then return end
  print(('[qbx_oilrig][server] ' .. msg):format(...))
end

-- Some MySQL drivers return TINYINT(1) as boolean. Normalize everywhere.
local function asInt01(v)
  if v == true then return 1 end
  if v == false then return 0 end
  local n = tonumber(v)
  return n or 0
end


-- ===== Rig blip cache =====
local RigBlipCache = {} -- rigKey -> { x=, y=, z=, ownerCid=nil|string }
local ensureStash -- forward declaration: used by seeding before function body is assigned

local function loadRigBlipCache()
  RigBlipCache = {}
  local rows = MySQL.query.await([[
    SELECT r.rig_key, r.x, r.y, r.z, o.owner_cid
    FROM oilrig_rigs r
    LEFT JOIN oilrig_ownership o ON o.rig_key = r.rig_key
  ]]) or {}

  for _, r in ipairs(rows) do
    if r and r.rig_key then
      RigBlipCache[r.rig_key] = {
        x = tonumber(r.x) or 0.0,
        y = tonumber(r.y) or 0.0,
        z = tonumber(r.z) or 0.0,
        ownerCid = r.owner_cid
      }
    end
  end
  dbg('blip cache loaded rigs=%d', #rows)
end

local function upsertRigBlipCache(rigKey, x, y, z, ownerCid)
  RigBlipCache[rigKey] = {
    x = tonumber(x) or 0.0,
    y = tonumber(y) or 0.0,
    z = tonumber(z) or 0.0,
    ownerCid = ownerCid
  }
end

local function broadcastRigBlipUpdate(rigKey)
  local r = RigBlipCache[rigKey]
  if not r then return end
  TriggerClientEvent('qbx_oilrig:client:rigBlipUpdate', -1, rigKey, r.x, r.y, r.z, r.ownerCid)
end


-- ===== DB migrate helpers =====
local function columnExists(tableName, columnName)
  local row = MySQL.single.await([[
    SELECT COLUMN_NAME
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = ?
      AND COLUMN_NAME = ?
    LIMIT 1
  ]], { tableName, columnName })
  return row ~= nil
end

local function ensureColumn(tableName, columnName, alterSql)
  local ok = false
  local exists = false
  local success, err = pcall(function()
    exists = columnExists(tableName, columnName)
  end)
  if not success then
    dbg('migrate check failed %s.%s err=%s', tostring(tableName), tostring(columnName), tostring(err))
    return false
  end
  if exists then return true end
  local success2, err2 = pcall(function()
    MySQL.query.await(alterSql)
    ok = true
  end)
  if not success2 or not ok then
    dbg('migrate ALTER failed %s.%s err=%s', tostring(tableName), tostring(columnName), tostring(err2))
    return false
  end
  dbg('migrate ALTER ok %s.%s', tostring(tableName), tostring(columnName))
  return true
end

local function normalizeRigSeedData(rig, index, defaultDeposit)
  local coords = rig and rig.coords
  if not (coords and coords.x and coords.y and coords.z) then
    return nil
  end

  local rigKey = tostring((rig and rig.id) or ('rig_' .. string.format('%03d', index)))
  local deposit = tonumber(rig and rig.deposit) or defaultDeposit
  if deposit < 0 then deposit = 0 end

  return rigKey, coords, deposit
end


-- ===== Rig seeding (Config.Rigs -> oilrig_rigs) =====
local function seedRigsFromConfig()
  if type(Config.Rigs) ~= 'table' then return end
  if #Config.Rigs == 0 then
    dbg('seed rigs: Config.Rigs empty (ok)')
    return
  end

  local defDeposit = (Config.Deposit and tonumber(Config.Deposit.DefaultTotal)) or 50000

  local inserted = 0
  for i, r in ipairs(Config.Rigs) do
    local id, coords, dep = normalizeRigSeedData(r, i, defDeposit)
    if id then
      -- upsert by rig_key (stable)
      MySQL.update.await([[
        INSERT INTO oilrig_rigs (rig_key, x, y, z, deposit_total, deposit_remaining, deposit_initialized)
        VALUES (?, ?, ?, ?, ?, ?, 1)
        ON DUPLICATE KEY UPDATE
          x = VALUES(x),
          y = VALUES(y),
          z = VALUES(z)
      ]], { id, coords.x, coords.y, coords.z, dep, dep })
      inserted = inserted + 1
      -- stash ensure
      pcall(function() ensureStash(id) end)
    end
  end
  dbg('seed rigs: ensured=%d', inserted)

  -- обновить кеш блипов (если используется)
  pcall(function()
    if loadRigBlipCache then loadRigBlipCache() end
  end)
end

-- ===== Schema =====
CreateThread(function()
  MySQL.query([[
    CREATE TABLE IF NOT EXISTS oilrig_rigs (
      rig_id INT AUTO_INCREMENT PRIMARY KEY,
      rig_key VARCHAR(128) NOT NULL UNIQUE,
      x DOUBLE NOT NULL,
      y DOUBLE NOT NULL,
      z DOUBLE NOT NULL,
      heading DOUBLE NOT NULL DEFAULT 0,
      created_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP
    );
  ]])

  MySQL.query([[
    CREATE TABLE IF NOT EXISTS oilrig_ownership (
      id INT AUTO_INCREMENT PRIMARY KEY,
      rig_key VARCHAR(128) NOT NULL UNIQUE,
      owner_cid VARCHAR(64) DEFAULT NULL,
      purchased_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    );
  ]])

MySQL.query([[
  CREATE TABLE IF NOT EXISTS oilrig_workers (
    id INT AUTO_INCREMENT PRIMARY KEY,
    rig_key VARCHAR(128) NOT NULL,
    worker_cid VARCHAR(64) NOT NULL,
    worker_name VARCHAR(128) NULL,
    perm_stash TINYINT(1) NOT NULL DEFAULT 0,
    perm_production TINYINT(1) NOT NULL DEFAULT 0,
    perm_repair TINYINT(1) NOT NULL DEFAULT 0,
    added_at INT NOT NULL DEFAULT 0,
    UNIQUE KEY rig_worker (rig_key, worker_cid)
  );
]])

-- migrate workers columns (older installs)
ensureColumn('oilrig_workers', 'worker_name', "ALTER TABLE oilrig_workers ADD COLUMN worker_name VARCHAR(128) NULL")
ensureColumn('oilrig_workers', 'perm_stash', "ALTER TABLE oilrig_workers ADD COLUMN perm_stash TINYINT(1) NOT NULL DEFAULT 0")
ensureColumn('oilrig_workers', 'perm_production', "ALTER TABLE oilrig_workers ADD COLUMN perm_production TINYINT(1) NOT NULL DEFAULT 0")
ensureColumn('oilrig_workers', 'perm_repair', "ALTER TABLE oilrig_workers ADD COLUMN perm_repair TINYINT(1) NOT NULL DEFAULT 0")
ensureColumn('oilrig_workers', 'added_at', "ALTER TABLE oilrig_workers ADD COLUMN added_at INT NOT NULL DEFAULT 0")


  MySQL.query([[
    CREATE TABLE IF NOT EXISTS oilrig_parts (
      id INT AUTO_INCREMENT PRIMARY KEY,
      rig_key VARCHAR(128) NOT NULL,
      part_id VARCHAR(64) NOT NULL,
      health INT NOT NULL DEFAULT 100,
      updated_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      UNIQUE KEY rig_part (rig_key, part_id)
    );
  ]])

  MySQL.query([[
    CREATE TABLE IF NOT EXISTS oilrig_production (
      id INT AUTO_INCREMENT PRIMARY KEY,
      rig_key VARCHAR(128) NOT NULL,
      is_running TINYINT(1) NOT NULL DEFAULT 0,
      last_tick INT NOT NULL DEFAULT 0,
      remainder_milli INT NOT NULL DEFAULT 0,
      pending_oil INT NOT NULL DEFAULT 0,
      wear_milli INT NOT NULL DEFAULT 0,
      cycle_start INT NOT NULL DEFAULT 0
    );
  ]])


  MySQL.query([[
    CREATE TABLE IF NOT EXISTS oilrig_licenses (
      license_no INT AUTO_INCREMENT PRIMARY KEY,
      cid VARCHAR(64) NOT NULL UNIQUE,
      first_name VARCHAR(64) NULL,
      last_name VARCHAR(64) NULL,
      full_name VARCHAR(128) NOT NULL,
      issued_at INT NOT NULL,
      expires_at INT NOT NULL DEFAULT 0
    );
  ]])

  
-- migrate licenses columns (older installs)
ensureColumn('oilrig_licenses', 'first_name', "ALTER TABLE oilrig_licenses ADD COLUMN first_name VARCHAR(64) NULL")
ensureColumn('oilrig_licenses', 'last_name', "ALTER TABLE oilrig_licenses ADD COLUMN last_name VARCHAR(64) NULL")
ensureColumn('oilrig_licenses', 'expires_at', "ALTER TABLE oilrig_licenses ADD COLUMN expires_at INT NOT NULL DEFAULT 0")

MySQL.query([[
    CREATE TABLE IF NOT EXISTS oilrig_refinery_jobs (
      cid VARCHAR(64) NOT NULL PRIMARY KEY,
      recipe_key VARCHAR(64) NOT NULL,
      out_item VARCHAR(64) NOT NULL,
      out_total INT NOT NULL,
      oil_item VARCHAR(64) NOT NULL,
      oil_total INT NOT NULL,
      started_at INT NOT NULL,
      duration INT NOT NULL
    );
  ]])
  local function ensureCol(col, ddl)
    local r = MySQL.single.await(("SHOW COLUMNS FROM oilrig_production LIKE '%s'"):format(col))
    if not r then pcall(function() MySQL.query.await(ddl) end) end
  end
  ensureCol('wear_milli', "ALTER TABLE oilrig_production ADD COLUMN wear_milli INT NOT NULL DEFAULT 0")
  ensureCol('cycle_start', "ALTER TABLE oilrig_production ADD COLUMN cycle_start INT NOT NULL DEFAULT 0")

  
-- миграции для oilrig_rigs (уникальный id + иссякаемое месторождение)
pcall(function()
  ensureColumn('oilrig_rigs', 'rig_id', [[ALTER TABLE oilrig_rigs ADD COLUMN rig_id INT NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST]])
  ensureColumn('oilrig_rigs', 'deposit_total', [[ALTER TABLE oilrig_rigs ADD COLUMN deposit_total INT NOT NULL DEFAULT 0]])
  ensureColumn('oilrig_rigs', 'deposit_remaining', [[ALTER TABLE oilrig_rigs ADD COLUMN deposit_remaining INT NOT NULL DEFAULT 0]])
  ensureColumn('oilrig_rigs', 'deposit_initialized', [[ALTER TABLE oilrig_rigs ADD COLUMN deposit_initialized TINYINT(1) NOT NULL DEFAULT 0]])
        ensureColumn('oilrig_rigs', 'depleted_until', [[ALTER TABLE oilrig_rigs ADD COLUMN depleted_until INT NOT NULL DEFAULT 0]])
  -- на случай старых строк, где deposit_* = 0
  
local defDeposit = (Config.Deposit and Config.Deposit.DefaultTotal) or 15000
-- Инициализация месторождений (без "рефилла" уже выкачанных)
-- 1) Если total ещё не задан (0/NULL) -> ставим дефолт и remaining=def
MySQL.query.await([[
  UPDATE oilrig_rigs
  SET
    deposit_total = ?,
    deposit_remaining = ?,
    deposit_initialized = 1
  WHERE (deposit_total IS NULL OR deposit_total = 0)
    AND (deposit_initialized IS NULL OR deposit_initialized = 0)
]], { defDeposit, defDeposit })

-- 2) Для всех остальных строк просто помечаем как инициализированные, НЕ трогая remaining
MySQL.query.await([[
  UPDATE oilrig_rigs
  SET deposit_initialized = 1
  WHERE (deposit_total IS NOT NULL AND deposit_total > 0)
    AND (deposit_initialized IS NULL OR deposit_initialized = 0)
]], {})
end)

dbg('schema ready')
  pcall(function() loadRigBlipCache() end)
end)


local function getFullName(player)
  local pd = player and player.PlayerData
  local ci = pd and (pd.charinfo or pd.charInfo or pd.character or pd.char) or nil
  local fn = (ci and (ci.firstname or ci.firstName or ci.first_name)) or nil
  local ln = (ci and (ci.lastname or ci.lastName or ci.last_name)) or nil
  if fn and ln then return tostring(fn) .. ' ' .. tostring(ln) end
  if pd and pd.name then return tostring(pd.name) end
  return 'Unknown'
end

-- forward declarations (shared helpers)
local getPlayer, getCID, notify



local function hasOilLicense(src, cid)
  if not Config.License or not Config.License.Enabled then return true end
  local item = Config.License.Item or 'oillicense'
  local now = os.time()

  -- DB is source of truth (supports expiry)
  local row = MySQL.single.await('SELECT license_no, expires_at FROM oilrig_licenses WHERE cid = ? LIMIT 1', { cid })
  if row then
    local exp = tonumber(row.expires_at) or 0
    if exp > 0 and exp <= now then
      -- expired -> cleanup
      MySQL.update.await('DELETE FROM oilrig_licenses WHERE cid = ?', { cid })
      local cnt = ox_inventory:Search(src, 'count', item) or 0
      if cnt and cnt > 0 then ox_inventory:RemoveItem(src, item, cnt, nil) end
      return false
    end
    return true
  end

  -- fallback: item in inventory (if DB was cleared)
  local cnt = ox_inventory:Search(src, 'count', item) or 0
  return (cnt and cnt > 0) == true
end

local function canGiveLicense(src)
  -- Привязка к стандартной админ-группе QBCore/QBX (без отдельного ACE для ресурса)
  -- Обычно это права 'admin' / 'god' (то же, что нужно для /admin и большинства админ-команд).
  if src == 0 then return true end

  local ok, has = pcall(function()
    -- qbx_core:HasPermission (может быть помечен как deprecated, но обычно присутствует для совместимости)
    if exports and exports.qbx_core and exports.qbx_core.HasPermission then
      if exports.qbx_core:HasPermission(src, 'god') then return true end
      if exports.qbx_core:HasPermission(src, 'admin') then return true end
    end
    return false
  end)
  if ok and has then return true end

  if IsPlayerAceAllowed(src, 'god') then return true end
  if IsPlayerAceAllowed(src, 'admin') then return true end

  return false
end

local function issueOilLicense(targetSrc, issuerSrc)
  local player = getPlayer(targetSrc)
  if not player then
    if issuerSrc and issuerSrc ~= 0 then notify(issuerSrc, 'error', 'Игрок не найден.') end
    return false
  end

  local cid = getCID(player)
  if not cid then
    if issuerSrc and issuerSrc ~= 0 then notify(issuerSrc, 'error', 'Не удалось получить CID игрока.') end
    return false
  end

  -- уже есть лицензия?
  local existing = MySQL.single.await('SELECT license_no, expires_at FROM oilrig_licenses WHERE cid = ? LIMIT 1', { cid })
  local item = (Config.License and Config.License.Item) or 'oillicense'
  local cnt = ox_inventory:Search(targetSrc, 'count', item) or 0
  local now = os.time()
      if existing then
        local exp = tonumber(existing.expires_at) or 0
        if exp > 0 and exp <= now then
          MySQL.update.await('DELETE FROM oilrig_licenses WHERE cid = ?', { cid })
          existing = nil
        end
      end
      if existing or (cnt and cnt > 0) then
    if issuerSrc and issuerSrc ~= 0 then notify(issuerSrc, 'error', 'У игрока уже есть лицензия.') end
    if targetSrc and targetSrc ~= 0 then notify(targetSrc, 'error', 'У вас уже есть лицензия на добычу нефти.') end
    return false
  end

  local pd = player and player.PlayerData
  local ci = pd and (pd.charinfo or pd.charInfo or pd.character or pd.char) or nil
  local firstName = (ci and (ci.firstname or ci.firstName or ci.first_name)) or nil
  local lastName  = (ci and (ci.lastname  or ci.lastName  or ci.last_name)) or nil
  local fullName = getFullName(player)
  local issuedAt = os.time()
  local validDays = tonumber((Config.License and Config.License.ValidDays) or 30) or 30
  local expiresAt = (validDays and validDays > 0) and (issuedAt + (validDays * 86400)) or 0

  MySQL.insert.await('INSERT INTO oilrig_licenses (cid, first_name, last_name, full_name, issued_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)', { cid, firstName, lastName, fullName, issuedAt, expiresAt })
  local row = MySQL.single.await('SELECT license_no FROM oilrig_licenses WHERE cid = ? LIMIT 1', { cid })
  local licNo = tonumber(row and row.license_no) or 0

  local meta = {
    license_no = licNo,
    full_name = fullName,
    issued_at = issuedAt,
    issued_date = os.date('%Y-%m-%d %H:%M:%S', issuedAt)
  }

  if not ox_inventory:CanCarryItem(targetSrc, item, 1) then
    if issuerSrc and issuerSrc ~= 0 then notify(issuerSrc, 'error', 'У игрока нет места в инвентаре.') end
    notify(targetSrc, 'error', 'Нет места в инвентаре для лицензии.')
    return false
  end

  local ok = ox_inventory:AddItem(targetSrc, item, 1, meta)
  if not ok then
    if issuerSrc and issuerSrc ~= 0 then notify(issuerSrc, 'error', 'Не удалось выдать лицензию (инвентарь).') end
    notify(targetSrc, 'error', 'Не удалось выдать лицензию (инвентарь).')
    return false
  end

  notify(targetSrc, 'success', ('Лицензия выдана: #%d'):format(licNo))
  if issuerSrc and issuerSrc ~= 0 then
    notify(issuerSrc, 'success', ('Лицензия выдана игроку %d: #%d'):format(targetSrc, licNo))
  end
  dbg('license issued issuer=%s target=%s cid=%s licNo=%s', tostring(issuerSrc), tostring(targetSrc), tostring(cid), tostring(licNo))
  return true
end

local function revokeOilLicense(targetSrc, issuerSrc)
  local player = getPlayer(targetSrc)
  if not player then
    if issuerSrc and issuerSrc ~= 0 then notify(issuerSrc, 'error', 'Игрок не найден.') end
    return false
  end

  local cid = getCID(player)
  if not cid then
    if issuerSrc and issuerSrc ~= 0 then notify(issuerSrc, 'error', 'Не удалось получить CID игрока.') end
    return false
  end

  local item = (Config.License and Config.License.Item) or 'oillicense'

  local removedInv = 0
  local cnt = ox_inventory:Search(targetSrc, 'count', item) or 0
  if cnt and cnt > 0 then
    local ok = ox_inventory:RemoveItem(targetSrc, item, cnt, nil)
    if ok then removedInv = cnt end
  end

  local affected = MySQL.update.await('DELETE FROM oilrig_licenses WHERE cid = ?', { cid }) or 0

  if (affected <= 0) and (removedInv <= 0) then
    if issuerSrc and issuerSrc ~= 0 then notify(issuerSrc, 'error', 'У игрока нет лицензии.') end
    notify(targetSrc, 'error', 'У вас нет лицензии на добычу нефти.')
    return false
  end

  notify(targetSrc, 'success', 'Лицензия на добычу нефти аннулирована.')
  if issuerSrc and issuerSrc ~= 0 then
    notify(issuerSrc, 'success', ('Лицензия удалена у игрока %d.'):format(targetSrc))
  end
  dbg('license revoked issuer=%s target=%s cid=%s invRemoved=%s dbRows=%s', tostring(issuerSrc), tostring(targetSrc), tostring(cid), tostring(removedInv), tostring(affected))
  return true
end



-- ===== Helpers =====
getPlayer = function(src) return exports.qbx_core:GetPlayer(src) end
getCID = function(player)
  local pd = player and player.PlayerData
  return pd and (pd.citizenid or pd.citizenId or pd.citizen_id) or nil
end

notify = function(src, type, msg)
  TriggerClientEvent('ox_lib:notify', src, { type = type, description = msg })
end

local function hasPBanking()
  return Config.UsePBanking and GetResourceState('p_banking') == 'started'
end

local function getPersonalIban(src)
  if not hasPBanking() then return nil end
  local accounts = exports['p_banking']:getPlayerAccounts(src)
  if type(accounts) ~= 'table' then return nil end
  for _, a in pairs(accounts) do
    if a.type == 'personal' and a.role == 'owner' and a.iban then return a.iban end
  end
  for _, a in pairs(accounts) do if a.iban then return a.iban end end
  return nil
end

local function pbank_getBalance(iban)
  local money = exports['p_banking']:getAccountMoney(iban)
  return tonumber(money) or 0
end

local function pbank_createHistory(iban, kind, amount, title, src)
  if not (Config.PBankingCreateHistory and hasPBanking()) then return end
  local data = { iban = iban, type = kind, amount = amount, title = title or 'Transaction', from = 'SYSTEM', to = ('Player %d'):format(src or 0) }
  pcall(function() exports['p_banking']:createHistory(data) end)
end

local function bank_canAfford(src, amount)
  if hasPBanking() then
    local iban = getPersonalIban(src)
    if not iban then return false end
    return pbank_getBalance(iban) >= amount
  end
  local player = getPlayer(src)
  if not player then return false end
  local bal = player.PlayerData.money and player.PlayerData.money.bank or 0
  return bal >= amount
end

local function bank_remove(src, amount, title)
  if hasPBanking() then
    local iban = getPersonalIban(src)
    if not iban then return false end
    if pbank_getBalance(iban) < amount then return false end
    local ok = exports['p_banking']:removeAccountMoney(iban, amount)
    if not ok then return false end
    local after = pbank_getBalance(iban)
    if after < 0 then exports['p_banking']:addAccountMoney(iban, amount) return false end
    pbank_createHistory(iban, 'outcome', amount, title, src)
    return true
  end
  local player = getPlayer(src)
  if not player then return false end
  return player.Functions.RemoveMoney('bank', amount, title or 'oilrig')
end

local function bank_add(src, amount, title)
  if hasPBanking() then
    local iban = getPersonalIban(src)
    if not iban then return false end
    local ok = exports['p_banking']:addAccountMoney(iban, amount)
    if ok then pbank_createHistory(iban, 'income', amount, title, src) return true end
    return false
  end
  local player = getPlayer(src)
  if not player then return false end
  player.Functions.AddMoney('bank', amount, title or 'oilrig')
  return true
end

-- ===== Refinery helpers =====
local function getRefineryJob(cid)
  if not cid then return nil end
  return MySQL.single.await([[
    SELECT cid, recipe_key, out_item, out_total, oil_item, oil_total, started_at, duration
    FROM oilrig_refinery_jobs
    WHERE cid = ?
    LIMIT 1
  ]], { cid })
end

local function deleteRefineryJob(cid)
  if not cid then return end
  MySQL.update.await('DELETE FROM oilrig_refinery_jobs WHERE cid = ?', { cid })
end

local function isRefineryJobComplete(job)
  if not job then return false end
  local now = os.time()
  return now >= (tonumber(job.started_at) or 0) + (tonumber(job.duration) or 0)
end

local function isNearRefinery(src)
  if not Config.Refinery or not Config.Refinery.Coords then return true end
  local ped = GetPlayerPed(src)
  if not ped or ped == 0 then return false end
  local p = GetEntityCoords(ped)
  local c = Config.Refinery.Coords
  local maxDist = (Config.Refinery.TargetDistance or 3.5) + 3.0
  return #(p - c) <= maxDist
end




-- ===== Refinery state callback =====
lib.callback.register('qbx_oilrig:server:getRefineryState', function(src)
  local player = getPlayer(src)
  if not player then return { job = nil } end
  local cid = getCID(player)
  if not cid then return { job = nil } end

  local job = getRefineryJob(cid)
  if not job then return { job = nil } end

  local now = os.time()
  local startAt = tonumber(job.started_at) or now
  local dur = tonumber(job.duration) or 1
  if dur < 1 then dur = 1 end

  local elapsed = now - startAt
  if elapsed < 0 then elapsed = 0 end
  local progress = math.floor((elapsed / dur) * 100 + 0.5)
  if progress < 0 then progress = 0 end
  if progress > 100 then progress = 100 end

  local remaining = dur - elapsed
  if remaining < 0 then remaining = 0 end

  return {
    job = {
      recipeKey = job.recipe_key,
      outItem = job.out_item,
      outTotal = tonumber(job.out_total) or 0,
      oilItem = job.oil_item,
      oilTotal = tonumber(job.oil_total) or 0,
      startedAt = startAt,
      duration = dur,
      progress = progress,
      remaining = remaining
    }
  }
end)


-- ===== Oil License purchase =====


-- ===== Admin command: give oil license =====
-- Требует стандартные права admin/god (как у админ-команд QBCore/QBX).
-- Доступ: стандартный ACE на команды.
-- Если у тебя есть доступ к /admin (group.admin), то команда будет работать без доп. настроек.
-- Пример:
-- /giveoillicense 12
-- /giveoillicense (без аргумента выдаст себе)
RegisterCommand('giveoillicense', function(source, args)
  local src = source
  if not (Config.License and Config.License.Enabled) then
    if src ~= 0 then notify(src, 'error', 'Лицензии отключены.') end
    return
  end

  local target = tonumber(args[1] or src) or src
  if target == 0 then
    -- консоль без id
    print('[qbx_oilrig] /giveoillicense <playerId>')
    return
  end

  issueOilLicense(target, src)
end, true)


-- /removeoillicense [playerId] (restricted=true)
RegisterCommand('removeoillicense', function(source, args)
  local src = source
  if not (Config.License and Config.License.Enabled) then
    if src ~= 0 then notify(src, 'error', 'Лицензии отключены.') end
    return
  end

  local target = tonumber(args[1] or src) or src
  if target == 0 then
    print('[qbx_oilrig] /removeoillicense <playerId>')
    return
  end

  revokeOilLicense(target, src)
end, true)

RegisterNetEvent('qbx_oilrig:server:buyOilLicense', function()
  local src = source
  if not Config.License or not Config.License.Enabled then
    notify(src, 'error', 'Лицензии отключены.')
    return
  end
  local player = getPlayer(src)
  if not player then return end
  local cid = getCID(player)
  if not cid then return end

  -- уже есть лицензия?
  local existing = MySQL.single.await('SELECT license_no, expires_at FROM oilrig_licenses WHERE cid = ? LIMIT 1', { cid })
  if existing then
    notify(src, 'error', 'У вас уже есть лицензия на добычу нефти.')
    return
  end

  local item = Config.License.Item or 'oillicense'
  local cnt = ox_inventory:Search(src, 'count', item) or 0
  if cnt and cnt > 0 then
    notify(src, 'error', 'У вас уже есть лицензия на добычу нефти.')
    return
  end

  local price = tonumber(Config.License.Price) or 0
  if price > 0 then
    if not bank_canAfford(src, price) then
      notify(src, 'error', 'Недостаточно средств на банковском счёте.')
      return
    end
    if not bank_remove(src, price, (Config.TransactionTitles and Config.TransactionTitles.buyLicense) or 'Oil License') then
      notify(src, 'error', 'Оплата не прошла. Проверьте баланс.')
      return
    end
  end

  issueOilLicense(src, src)
end)

-- ===== Refinery / Sales =====
RegisterNetEvent('qbx_oilrig:server:sellOil', function(amount)
  local src = source
  local a = math.floor(tonumber(amount) or 0)
  if a <= 0 then return end

  local oilItem = Config.OilItem or 'oil'
  local price = (Config.Refinery and Config.Refinery.SellPricePerUnit) or 0
  price = tonumber(price) or 0
  if price <= 0 then
    notify(src, 'error', 'Продажа нефти отключена (цена=0).')
    return
  end

  local have = ox_inventory:Search(src, 'count', oilItem) or 0
  dbg('sellOil src=%d item=%s have=%s amount=%s', src, tostring(oilItem), tostring(have), tostring(a))

  if have < a then
    notify(src, 'error', 'Недостаточно нефти для продажи.')
    return
  end

  local ok = ox_inventory:RemoveItem(src, oilItem, a)
  if not ok then
    notify(src, 'error', 'Не удалось списать нефть (инвентарь).')
    return
  end

  local payout = a * price
  bank_add(src, payout, 'oilrig_sell_oil')
  notify(src, 'success', ('Продано: %s шт. ($%s)'):format(a, payout))
end)


RegisterNetEvent('qbx_oilrig:server:claimRefinery', function()
  local src = source
  if not isNearRefinery(src) then
    notify(src, 'error', 'Вы слишком далеко от НПЗ.')
    return
  end

  local player = getPlayer(src)
  if not player then return end
  local cid = getCID(player)
  if not cid then return end

  local job = getRefineryJob(cid)
  if not job then
    notify(src, 'error', 'У вас нет активной переработки.')
    return
  end

  if not isRefineryJobComplete(job) then
    local now = os.time()
    local remaining = (tonumber(job.started_at) or now) + (tonumber(job.duration) or 0) - now
    if remaining < 0 then remaining = 0 end
    notify(src, 'error', ('Переработка ещё не завершена. Осталось: %d сек.'):format(remaining))
    return
  end

  local outItem = tostring(job.out_item or '')
  local outTotal = tonumber(job.out_total) or 0
  if outItem == '' or outTotal <= 0 then
    deleteRefineryJob(cid)
    notify(src, 'error', 'Задание переработки повреждено и было очищено.')
    TriggerClientEvent('qbx_oilrig:client:refineryJobUpdated', src)
    return
  end

  if not ox_inventory:CanCarryItem(src, outItem, outTotal) then
    notify(src, 'error', 'Недостаточно места в инвентаре для результата.')
    return
  end

  local okAdd = ox_inventory:AddItem(src, outItem, outTotal)
  if not okAdd then
    notify(src, 'error', 'Не удалось выдать результат (инвентарь).')
    return
  end

  deleteRefineryJob(cid)
  notify(src, 'success', ('Забрано: %d x %s'):format(outTotal, outItem))
  TriggerClientEvent('qbx_oilrig:client:refineryJobUpdated', src)
end)


RegisterNetEvent('qbx_oilrig:server:refineOil', function(recipeKey, crafts)
  local src = source
  if not isNearRefinery(src) then
    notify(src, 'error', 'Вы слишком далеко от НПЗ.')
    return
  end

  local key = tostring(recipeKey or '')
  local c = math.floor(tonumber(crafts) or 0)
  if c <= 0 or key == '' then return end

  local player = getPlayer(src)
  if not player then return end
  local cid = getCID(player)
  if not cid then return end

  local existing = getRefineryJob(cid)
  if existing then
    notify(src, 'error', 'У вас уже идёт переработка. Сначала заберите результат.')
    return
  end

  local oilItem = Config.OilItem or 'oil'
  local recipes = (Config.Refinery and Config.Refinery.Recipes) or {}
  local r = recipes[key]
  if not r then
    notify(src, 'error', 'Неизвестный рецепт переработки.')
    return
  end

  local needPer = math.floor(tonumber(r.oil) or 1)
  local outPer = math.floor(tonumber(r.out) or 1)
  local outItem = tostring(r.item or '')
  if needPer <= 0 or outPer <= 0 or outItem == '' then
    notify(src, 'error', 'Рецепт настроен неверно.')
    return
  end

  local needTotal = c * needPer
  local outTotal = c * outPer

  local have = ox_inventory:Search(src, 'count', oilItem) or 0
  dbg('refineOil START src=%d key=%s have=%s need=%s outItem=%s out=%s', src, key, tostring(have), tostring(needTotal), outItem, tostring(outTotal))

  if have < needTotal then
    notify(src, 'error', 'Недостаточно нефти для переработки.')
    return
  end

  local okRemove = ox_inventory:RemoveItem(src, oilItem, needTotal)
  if not okRemove then
    notify(src, 'error', 'Не удалось списать нефть (инвентарь).')
    return
  end

  local duration = (Config.Refinery and tonumber(Config.Refinery.ProcessDurationSeconds)) or 300
  if duration < 1 then duration = 1 end
  local now = os.time()

  MySQL.insert.await([[
    INSERT INTO oilrig_refinery_jobs (cid, recipe_key, out_item, out_total, oil_item, oil_total, started_at, duration)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  ]], { cid, key, outItem, outTotal, oilItem, needTotal, now, duration })

  notify(src, 'success', ('Переработка запущена: %s. Готово через %d сек.'):format(tostring(r.label or key), duration))
  TriggerClientEvent('qbx_oilrig:client:refineryJobUpdated', src)
end)

local function parseRigKey(rigKey)
  local x, y, z = rigKey:match('^oilrig:([%-%.%d]+):([%-%.%d]+):([%-%.%d]+)$')
  if not x then return nil end
  return vector3(tonumber(x), tonumber(y), tonumber(z))
end

local function stashIdFromRigKey(rigKey)
  local safe = rigKey:gsub('[^%w]', '_')
  return ('oilrig_%s'):format(safe)
end

ensureStash = function(rigKey)
  local stashId = stashIdFromRigKey(rigKey)
  if not ox_inventory:GetInventory(stashId, false) then
    ox_inventory:RegisterStash(stashId, Config.StashLabel or 'Oil Rig Stash', Config.StashSlots or 40, Config.StashMaxWeight or 200000, false)
    dbg('stash registered %s', stashId)
  end
  return stashId
end

local function ensureRigRegistry(rigKey, coords, heading)
  if not coords then coords = parseRigKey(rigKey) end
  if not coords then return end
  MySQL.insert.await([[
    INSERT IGNORE INTO oilrig_rigs (rig_key, x, y, z, heading, deposit_total, deposit_remaining, deposit_initialized)
    VALUES (?, ?, ?, ?, ?, ?, ?, 1)]], { rigKey, coords.x, coords.y, coords.z, heading or 0, ((Config.Deposit and Config.Deposit.DefaultTotal) or 15000), ((Config.Deposit and Config.Deposit.DefaultTotal) or 15000) })
end

local function ensureRigRow(rigKey, coords, heading)
  ensureRigRegistry(rigKey, coords, heading)
  MySQL.insert.await([[
    INSERT IGNORE INTO oilrig_ownership (rig_key, owner_cid)
    VALUES (?, NULL)
  ]], { rigKey })
end


local function selectWorkerRow(rigKey, workerCid)
  return MySQL.single.await('SELECT worker_cid, worker_name, perm_stash, perm_production, perm_repair FROM oilrig_workers WHERE rig_key = ? AND worker_cid = ? LIMIT 1', { rigKey, workerCid })
end

local function getWorkerPermsForCid(rigKey, cid)
  local row = selectWorkerRow(rigKey, cid)
  if not row then
    return false, { stash = false, production = false, repair = false }
  end
  return true, {
    stash = asInt01(row.perm_stash) == 1,
    production = asInt01(row.perm_production) == 1,
    repair = asInt01(row.perm_repair) == 1
  }
end

local function hasRigPermission(rigKey, cid, ownerCid, permKey)
  if ownerCid and cid and ownerCid == cid then return true end
  local isWorker, perms = getWorkerPermsForCid(rigKey, cid)
  if not isWorker then return false end
  if permKey == 'stash' then return perms.stash end
  if permKey == 'production' then return perms.production end
  if permKey == 'repair' then return perms.repair end
  return false
end


local function ensureParts(rigKey)
  for _, part in ipairs(Config.Parts) do
    local health = math.random(Config.InitialHealthMin or 65, Config.InitialHealthMax or 100)
    MySQL.insert.await([[
      INSERT IGNORE INTO oilrig_parts (rig_key, part_id, health)
      VALUES (?, ?, ?)
    ]], { rigKey, part.id, health })
  end
end

local function ensureProductionRow(rigKey)
  local exists = MySQL.single.await('SELECT id FROM oilrig_production WHERE rig_key = ? ORDER BY id DESC LIMIT 1', { rigKey })
  if exists then return end
  MySQL.insert.await([[
    INSERT INTO oilrig_production (rig_key, is_running, last_tick, remainder_milli, pending_oil, wear_milli, cycle_start)
    VALUES (?, 0, 0, 0, 0, 0, 0)
  ]], { rigKey })
  dbg('production row created rigKey=%s', rigKey)
end

local function selectProduction(rigKey)
  return MySQL.single.await([[
    SELECT id, is_running, last_tick, remainder_milli, pending_oil, wear_milli, cycle_start
    FROM oilrig_production
    WHERE rig_key = ?
    ORDER BY id DESC
    LIMIT 1
  ]], { rigKey })
end

local function calcRepairPrice(basePrice, health)
  local wear = (100 - health) / 100
  return math.floor(basePrice * (1.0 + wear * (Config.WearPriceMultiplier or 1.0)) + 0.5)
end

local function hasAnyBrokenPart(rigKey)
  local row = MySQL.single.await('SELECT 1 as x FROM oilrig_parts WHERE rig_key = ? AND health <= 0 LIMIT 1', { rigKey })
  return row ~= nil
end

-- ===== Production core =====
local function canCarryItemAmount(inventoryId, item, amount)
  if amount <= 0 then return 0 end
  if ox_inventory:CanCarryItem(inventoryId, item, amount) then return amount end
  local lo, hi, best = 0, amount, 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if mid > 0 and ox_inventory:CanCarryItem(inventoryId, item, mid) then best = mid; lo = mid + 1
    else hi = mid - 1 end
  end
  return best
end

local function applyWear(rigKey, elapsed, wearMilliRemainder)
  local hours = tonumber(Config.MaintenanceHours) or 12
  if hours <= 0 then return 0, wearMilliRemainder, false end
  local rate = 100000 / (hours * 3600)
  local add = math.floor(elapsed * rate + 0.5)
  local total = (wearMilliRemainder or 0) + add
  local wearPoints = math.floor(total / 1000)
  local rem = total % 1000
  if wearPoints <= 0 then return 0, rem, false end

  local parts = MySQL.query.await('SELECT part_id, health FROM oilrig_parts WHERE rig_key = ?', { rigKey }) or {}
  local anyBroken = false
  for _, p in ipairs(parts) do
    local h = tonumber(p.health) or 0
    h = h - wearPoints
    if h < 0 then h = 0 end
    if h == 0 then anyBroken = true end
    MySQL.update.await('UPDATE oilrig_parts SET health = ? WHERE rig_key = ? AND part_id = ?', { h, rigKey, p.part_id })
  end
  return wearPoints, rem, anyBroken
end

local function produceForRig(rigKey)
  ensureProductionRow(rigKey)
  ensureRigRow(rigKey)
  ensureParts(rigKey)
  ensureStash(rigKey)

  local row = selectProduction(rigKey)
  if not row or asInt01(row.is_running) ~= 1 then return end

  local now = os.time()
  local last = tonumber(row.last_tick) or 0
  local remainder = tonumber(row.remainder_milli) or 0
  local pending = tonumber(row.pending_oil) or 0
  local wearRem = tonumber(row.wear_milli) or 0

  if last <= 0 then
    MySQL.update.await('UPDATE oilrig_production SET last_tick = ? WHERE rig_key = ?', { now, rigKey })
    return
  end

  local elapsed = now - last
  if elapsed <= 0 then return end

  local _, newWearRem, anyBroken = applyWear(rigKey, elapsed, wearRem)
  if anyBroken and Config.StopProductionOnBreak then
    MySQL.update.await('UPDATE oilrig_production SET is_running = 0, last_tick = ?, wear_milli = ? WHERE rig_key = ?', { now, newWearRem, rigKey })
    dbg('production stopped by breakdown rigKey=%s', rigKey)
    return
  end

  local perHour = tonumber(Config.OilPerHour) or 500
  local produced_milli = math.floor((elapsed * perHour * 1000) / 3600)
  local total_milli = remainder + produced_milli
  local produced_items = math.floor(total_milli / 1000)
  remainder = total_milli % 1000

  local total_items = produced_items + pending
  local stashId = ensureStash(rigKey)

  local added = 0
  if total_items > 0 then

-- иссякаемое месторождение: ограничиваем добычу остатком
if Config.Deposit and Config.Deposit.Enabled then
  local rigRow = MySQL.single.await('SELECT deposit_remaining FROM oilrig_rigs WHERE rig_key = ? LIMIT 1', { rigKey })
  local remaining = tonumber(rigRow and rigRow.deposit_remaining) or 0
  if remaining <= 0 then
    -- месторождение пустое -> остановить добычу
    MySQL.update.await('UPDATE oilrig_production SET is_running = 0 WHERE rig_key = ?', { rigKey })
    dbg('production stopped (deposit empty) rigKey=%s', tostring(rigKey))
    return
  end
  if total_items > remaining then
    total_items = remaining
  end
end
local toAdd = canCarryItemAmount(stashId, Config.OilItem, total_items)
if toAdd <= 0 then
  -- stash переполнен: остановить добычу, чтобы не копить pending бесконечно
  MySQL.update.await('UPDATE oilrig_production SET is_running = 0, last_tick = ? WHERE rig_key = ?', { now, rigKey })
  dbg('production stopped (stash full) rigKey=%s stashId=%s pending=%d', tostring(rigKey), tostring(stashId), tonumber(total_items) or 0)
  return
end
if toAdd > 0 then
      local ok = ox_inventory:AddItem(stashId, Config.OilItem, toAdd)
      if not ok then
        MySQL.update.await('UPDATE oilrig_production SET is_running = 0, last_tick = ? WHERE rig_key = ?', { now, rigKey })
        dbg('production stopped (stash add failed) rigKey=%s stashId=%s', tostring(rigKey), tostring(stashId))
        return
      end
      if ok then
        added = toAdd
        total_items = total_items - toAdd
        -- списываем из месторождения ровно то, что реально добавили в stash
        if Config.Deposit and Config.Deposit.Enabled and added > 0 then
          MySQL.update.await('UPDATE oilrig_rigs SET deposit_remaining = GREATEST(deposit_remaining - ?, 0) WHERE rig_key = ?', { added, rigKey })
        end
      end
    end
    pending = total_items
  end

  MySQL.update.await([[
    UPDATE oilrig_production
    SET last_tick = ?, remainder_milli = ?, pending_oil = ?, wear_milli = ?
    WHERE rig_key = ?
  ]], { now, remainder, pending, newWearRem, rigKey })

  if Config.DebugProduction then
    dbg('tick rigKey=%s elapsed=%ds items=%d added=%d pending=%d rem=%d', rigKey, elapsed, produced_items, added, pending, remainder)
  else
    if added > 0 and Config.Debug then
      dbg('produced rigKey=%s +%d %s (pending=%d)', rigKey, added, tostring(Config.OilItem), pending)
    end
  end
end

CreateThread(function()
  while true do
    Wait((Config.ProductionTickSeconds or 10) * 1000)
    local rows = MySQL.query.await('SELECT DISTINCT rig_key FROM oilrig_production WHERE is_running = 1') or {}
    for _, r in ipairs(rows) do
      if r and r.rig_key then pcall(function() produceForRig(r.rig_key) end) end
    end
  end
end)

-- ===== Callbacks for menu =====
lib.callback.register('qbx_oilrig:server:getRigState', function(src, rigKey, coords)
  dbg('getRigState src=%d rigKey=%s', src, tostring(rigKey))

  pcall(function()
    if coords and coords.x then ensureRigRow(rigKey, vector3(coords.x, coords.y, coords.z), 0)
    else ensureRigRow(rigKey) end
    ensureProductionRow(rigKey)
    ensureParts(rigKey)
    ensureStash(rigKey)
  end)

  local player = getPlayer(src)
  if not player then return nil end
  local cid = getCID(player)
  if not cid then return nil end

  local own = MySQL.single.await('SELECT owner_cid FROM oilrig_ownership WHERE rig_key = ?', { rigKey })
  local ownerCid = own and own.owner_cid or nil

  local isOwner = ownerCid ~= nil and ownerCid == cid
  local isWorker, perms = getWorkerPermsForCid(rigKey, cid)
  if isOwner then isWorker = false end
  if not perms then perms = { stash = false, production = false, repair = false } end

  pcall(function() produceForRig(rigKey) end)

  local prod = selectProduction(rigKey)
  local isRunning = prod and asInt01(prod.is_running) == 1 or false
  local broken = hasAnyBrokenPart(rigKey)

  local progress = 0
  if isRunning and prod then
    local cycleStart = tonumber(prod.cycle_start) or 0
    if cycleStart <= 0 then cycleStart = tonumber(prod.last_tick) or os.time() end
    local now = os.time()
    local sec = (now - cycleStart) % 3600
    progress = math.floor((sec / 3600) * 100 + 0.5)
    if progress < 0 then progress = 0 end
    if progress > 100 then progress = 100 end
  end

  dbg('state rigKey=%s owner=%s isOwner=%s running=%s progress=%d prodRow=id=%s is=%s last=%s',
    rigKey, tostring(ownerCid), tostring(isOwner), tostring(isRunning), progress,
    prod and tostring(prod.id) or 'nil',
    prod and tostring(prod.is_running) or 'nil',
    prod and tostring(prod.last_tick) or 'nil'
  )

  
local rigRow = MySQL.single.await('SELECT deposit_total, deposit_remaining, depleted_until FROM oilrig_rigs WHERE rig_key = ? LIMIT 1', { rigKey })
local depositTotal = tonumber(rigRow and rigRow.deposit_total) or 0
local depositRemaining = tonumber(rigRow and rigRow.deposit_remaining) or 0
if (depositTotal <= 0) then
  depositTotal = (Config.Deposit and tonumber(Config.Deposit.DefaultTotal)) or 15000
end

  local depletedUntil = tonumber(rigRow and rigRow.depleted_until) or 0

  return {
    ownerCid = ownerCid,
    isOwner = isOwner,
    isWorker = isWorker,
    perms = perms,
    canStash = isOwner or (perms and perms.stash),
    canProduction = isOwner or (perms and perms.production),
    canRepair = isOwner or (perms and perms.repair),
    isRunning = isRunning,
    hasBrokenPart = broken,
    prodProgress = progress,
    depositTotal = depositTotal,
    depositRemaining = depositRemaining,
    depletedUntil = depletedUntil
  }

end)

lib.callback.register('qbx_oilrig:server:getEquipment', function(src, rigKey)
  ensureRigRow(rigKey)
  ensureParts(rigKey)

  local player = getPlayer(src)
  if not player then return nil end
  local cid = getCID(player)
  if not cid then return nil end

  local row = MySQL.single.await('SELECT owner_cid FROM oilrig_ownership WHERE rig_key = ?', { rigKey })
  local ownerCid = row and row.owner_cid or nil
  local isOwner = ownerCid ~= nil and ownerCid == cid

  local isWorker, perms = getWorkerPermsForCid(rigKey, cid)
  if isOwner then isWorker = false end
  if not perms then perms = { stash = false, production = false, repair = false } end
  local canRepair = isOwner or (isWorker and perms.repair)

  local partsRows = MySQL.query.await('SELECT part_id, health FROM oilrig_parts WHERE rig_key = ?', { rigKey }) or {}
  local healthMap = {}
  for _, r in ipairs(partsRows) do healthMap[r.part_id] = tonumber(r.health) or 0 end

  local parts = {}
  for _, p in ipairs(Config.Parts) do
    local h = healthMap[p.id] or math.random(Config.InitialHealthMin or 65, Config.InitialHealthMax or 100)
    if h < 0 then h = 0 end
    if h > 100 then h = 100 end
    parts[#parts+1] = { id = p.id, label = p.label, health = h, repairPrice = calcRepairPrice(p.price, h) }
  end

  return { isOwner = isOwner, canRepair = canRepair, parts = parts }
end)


-- ===== Blips callback =====
lib.callback.register('qbx_oilrig:server:getRigBlips', function(src)
  pcall(function()
    if not next(RigBlipCache) then loadRigBlipCache() end
  end)
  local list = {}
  for k, v in pairs(RigBlipCache) do
    list[#list+1] = { rigKey = k, x = v.x, y = v.y, z = v.z, ownerCid = v.ownerCid }
  end
  dbg('getRigBlips src=%d rigs=%d', src, #list)
  return list
end)


-- ===== Workers management (owner only) =====
lib.callback.register('qbx_oilrig:server:getWorkers', function(src, rigKey)
  local player = getPlayer(src)
  if not player then return nil end
  local cid = getCID(player)
  if not cid then return nil end

  local own = MySQL.single.await('SELECT owner_cid FROM oilrig_ownership WHERE rig_key = ?', { rigKey })
  if not own or own.owner_cid ~= cid then
    return nil
  end

  local rows = MySQL.query.await('SELECT worker_cid, worker_name, perm_stash, perm_production, perm_repair, added_at FROM oilrig_workers WHERE rig_key = ? ORDER BY added_at ASC', { rigKey }) or {}
  local list = {}
  for _, r in ipairs(rows) do
    list[#list+1] = {
      cid = r.worker_cid,
      name = r.worker_name,
      perms = {
        stash = asInt01(r.perm_stash) == 1,
        production = asInt01(r.perm_production) == 1,
        repair = asInt01(r.perm_repair) == 1
      },
      addedAt = tonumber(r.added_at) or 0
    }
  end
  return list
end)

lib.callback.register('qbx_oilrig:server:addWorker', function(src, rigKey, targetId)
  local player = getPlayer(src)
  if not player then return { ok = false, message = 'Player not found' } end
  local cid = getCID(player)
  if not cid then return { ok = false, message = 'CID not found' } end

  local own = MySQL.single.await('SELECT owner_cid FROM oilrig_ownership WHERE rig_key = ?', { rigKey })
  if not own or own.owner_cid ~= cid then
    return { ok = false, message = 'Только владелец может добавлять работников.' }
  end

  targetId = tonumber(targetId or 0) or 0
  if targetId <= 0 then
    return { ok = false, message = 'Укажи корректный Server ID.' }
  end
  if targetId == src then
    return { ok = false, message = 'Нельзя добавить самого себя.' }
  end

  local tPlayer = getPlayer(targetId)
  if not tPlayer then
    return { ok = false, message = 'Игрок не найден/не в сети.' }
  end
  local tCid = getCID(tPlayer)
  if not tCid then
    return { ok = false, message = 'CID работника не найден.' }
  end
  if tCid == cid then
    return { ok = false, message = 'Нельзя добавить самого себя.' }
  end

  local tName = getFullName(tPlayer)
  local now = os.time()

  MySQL.insert.await([[
    INSERT INTO oilrig_workers (rig_key, worker_cid, worker_name, perm_stash, perm_production, perm_repair, added_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON DUPLICATE KEY UPDATE worker_name = VALUES(worker_name)
  ]], { rigKey, tCid, tName, (Config.Workers and Config.Workers.DefaultPerms and (Config.Workers.DefaultPerms.stash and 1 or 0)) or 0, (Config.Workers and Config.Workers.DefaultPerms and (Config.Workers.DefaultPerms.production and 1 or 0)) or 0, (Config.Workers and Config.Workers.DefaultPerms and (Config.Workers.DefaultPerms.repair and 1 or 0)) or 1, now })

  notify(src, 'success', ('Работник добавлен: %s (по умолчанию: только ремонт)'):format(tName))
  notify(targetId, 'inform', ('Вас добавили работником на нефтевышку (%s). Доступ: ремонт.'):format(rigKey))

  return { ok = true, message = 'ok', workerCid = tCid }
end)

lib.callback.register('qbx_oilrig:server:updateWorkerPerms', function(src, rigKey, workerCid, perms)
  local player = getPlayer(src)
  if not player then return { ok = false, message = 'Player not found' } end
  local cid = getCID(player)
  if not cid then return { ok = false, message = 'CID not found' } end

  local own = MySQL.single.await('SELECT owner_cid FROM oilrig_ownership WHERE rig_key = ?', { rigKey })
  if not own or own.owner_cid ~= cid then
    return { ok = false, message = 'Только владелец может менять права.' }
  end

  if type(workerCid) ~= 'string' or workerCid == '' then
    return { ok = false, message = 'workerCid invalid' }
  end

  local s = perms and (perms.stash and 1 or 0) or 0
  local p = perms and (perms.production and 1 or 0) or 0
  local r = perms and (perms.repair and 1 or 0) or 0

  local affected = MySQL.update.await([[
    UPDATE oilrig_workers
    SET perm_stash = ?, perm_production = ?, perm_repair = ?
    WHERE rig_key = ? AND worker_cid = ?
  ]], { s, p, r, rigKey, workerCid })

  if (affected or 0) == 0 then
    return { ok = false, message = 'Работник не найден.' }
  end

  return { ok = true, message = 'ok' }
end)

lib.callback.register('qbx_oilrig:server:removeWorker', function(src, rigKey, workerCid)
  local player = getPlayer(src)
  if not player then return { ok = false, message = 'Player not found' } end
  local cid = getCID(player)
  if not cid then return { ok = false, message = 'CID not found' } end

  local own = MySQL.single.await('SELECT owner_cid FROM oilrig_ownership WHERE rig_key = ?', { rigKey })
  if not own or own.owner_cid ~= cid then
    return { ok = false, message = 'Только владелец может удалять работников.' }
  end

  local affected = MySQL.update.await('DELETE FROM oilrig_workers WHERE rig_key = ? AND worker_cid = ?', { rigKey, workerCid })
  if (affected or 0) == 0 then
    return { ok = false, message = 'Работник не найден.' }
  end

  return { ok = true, message = 'ok' }
end)

-- ===== Production control via events + ACK =====
RegisterNetEvent('qbx_oilrig:server:setProduction', function(rigKey, enable, reqId)
  local src = source
  dbg('setProduction EVENT src=%d rigKey=%s enable=%s reqId=%s', src, tostring(rigKey), tostring(enable), tostring(reqId))

  local function reply(ok, message, isRunning)
    TriggerClientEvent('qbx_oilrig:client:productionResult', src, reqId, ok, message, isRunning)
  end

  local ok, err = pcall(function()
    local player = getPlayer(src)
    if not player then reply(false, 'Player not found', false) return end
    local cid = getCID(player)
    if not cid then reply(false, 'CID not found', false) return end

    ensureRigRow(rigKey)
    ensureParts(rigKey)
    ensureProductionRow(rigKey)
    ensureStash(rigKey)

    local own = MySQL.single.await('SELECT owner_cid FROM oilrig_ownership WHERE rig_key = ?', { rigKey })
    local ownerCid = own and own.owner_cid or nil
    if not hasRigPermission(rigKey, cid, ownerCid, 'production') then
      reply(false, 'Нет доступа к управлению добычей.', false)
      return
    end

    if enable and hasAnyBrokenPart(rigKey) then
      reply(false, 'Нельзя запустить добычу: есть сломанные детали.', false)
      return
    end

    local now = os.time()
    
-- запрет запуска, если месторождение иссякло и на кулдауне
local depRow = MySQL.single.await('SELECT deposit_remaining, depleted_until FROM oilrig_rigs WHERE rig_key = ? LIMIT 1', { rigKey })
local depR = tonumber(depRow and depRow.deposit_remaining) or 0
local untilTs = tonumber(depRow and depRow.depleted_until) or 0
local now = os.time()
if depR <= 0 and untilTs > now then
  reply(false, 'Месторождение иссякло (кулдаун).', false)
  return
end
if enable then
      local affected = MySQL.update.await([[
        UPDATE oilrig_production
        SET is_running = 1, last_tick = ?, cycle_start = ?
        WHERE rig_key = ?
      ]], { now, now, rigKey })
      dbg('setProduction enable updated rows=%d', affected or 0)
      if (affected or 0) == 0 then
        MySQL.insert.await([[
          INSERT INTO oilrig_production (rig_key, is_running, last_tick, remainder_milli, pending_oil, wear_milli, cycle_start)
          VALUES (?, 1, ?, 0, 0, 0, ?)
        ]], { rigKey, now, now })
      end
    else
      local affected = MySQL.update.await('UPDATE oilrig_production SET is_running = 0 WHERE rig_key = ?', { rigKey })
      dbg('setProduction disable updated rows=%d', affected or 0)
    end

    local prod = selectProduction(rigKey)
    local running = prod and asInt01(prod.is_running) == 1 or false

    if enable and not running then
      dbg('VERIFY FAILED enable: prod=id=%s is=%s', prod and tostring(prod.id) or 'nil', prod and tostring(prod.is_running) or 'nil')
      reply(false, 'Сервер не смог включить добычу (is_running=0). Проверь oilrig_production.', false)
      return
    end
    if (not enable) and running then
      dbg('VERIFY FAILED disable: prod=id=%s is=%s', prod and tostring(prod.id) or 'nil', prod and tostring(prod.is_running) or 'nil')
      reply(false, 'Сервер не смог выключить добычу (is_running=1). Проверь oilrig_production.', true)
      return
    end

    reply(true, nil, running)

    if enable then
      local early = tonumber(Config.EarlyTickSeconds) or 0
      if early > 0 then
        SetTimeout(early * 1000, function()
          dbg('early tick rigKey=%s', rigKey)
          pcall(function() produceForRig(rigKey) end)
        end)
      end
    end
  end)

  if not ok then
    dbg('setProduction EVENT error: %s', tostring(err))
    reply(false, 'Ошибка сервера (см. консоль).', false)
  end
end)

-- ===== Inventory open =====
RegisterNetEvent('qbx_oilrig:server:openStash', function(rigKey)
  local src = source
  local player = getPlayer(src)
  if not player then return end
  local cid = getCID(player)
  if not cid then return end


local own = MySQL.single.await('SELECT owner_cid FROM oilrig_ownership WHERE rig_key = ?', { rigKey })
local ownerCid = own and own.owner_cid or nil
if not hasRigPermission(rigKey, cid, ownerCid, 'stash') then
  notify(src, 'error', 'Нет доступа к складу вышки.')
  return
end

  local coords = parseRigKey(rigKey)
  if coords then
    local pcoords = GetEntityCoords(GetPlayerPed(src))
    if #(pcoords - coords) > ((Config.MaxUseDistance or 6.0) + 2.0) then
      notify(src, 'error', 'Слишком далеко.')
      return
    end
  end

  local stashId = ensureStash(rigKey)
  local ok = pcall(function() exports.ox_inventory:forceOpenInventory(src, 'stash', stashId) end)
  if not ok then pcall(function() exports.ox_inventory:forceOpenInventory(src, 'stash', { id = stashId }) end) end
end)

-- ===== Buy/Sell/Repair =====
RegisterNetEvent('qbx_oilrig:server:buy', function(rigKey)
  local src = source
  local player = getPlayer(src)
  if not player then return end
  local cid = getCID(player)
  if not cid then return end

  ensureRigRow(rigKey); ensureParts(rigKey); ensureProductionRow(rigKey); ensureStash(rigKey)

  local row = MySQL.single.await('SELECT owner_cid FROM oilrig_ownership WHERE rig_key = ?', { rigKey })
  if row and row.owner_cid then notify(src, 'error', 'Установка уже куплена.') return end


-- одна вышка на игрока + проверка лицензии
if not hasOilLicense(src, cid) then
  notify(src, 'error', 'Нужна лицензия на добычу нефти.')
  return
end

local owned = MySQL.single.await('SELECT rig_key FROM oilrig_ownership WHERE owner_cid = ? LIMIT 1', { cid })
if owned and owned.rig_key and owned.rig_key ~= rigKey then
  notify(src, 'error', 'Вы уже владеете нефтевышкой. Можно иметь только одну.')
  return
end

-- месторождение: если иссякло и на кулдауне, покупка запрещена
local depRow = MySQL.single.await('SELECT deposit_total, deposit_remaining, depleted_until FROM oilrig_rigs WHERE rig_key = ? LIMIT 1', { rigKey })
local depT = tonumber(depRow and depRow.deposit_total) or 0
local depR = tonumber(depRow and depRow.deposit_remaining) or 0
local depletedUntil = tonumber(depRow and depRow.depleted_until) or 0
local now = os.time()
if depR <= 0 then
  if depletedUntil <= 0 then
    local cd = tonumber(Config.DepositCooldownSeconds) or (7*24*60*60)
    depletedUntil = now + cd
    MySQL.update.await('UPDATE oilrig_rigs SET depleted_until = ? WHERE rig_key = ?', { depletedUntil, rigKey })
  end
  if depletedUntil > now then
    notify(src, 'error', 'Месторождение иссякло. Вышка недоступна для покупки до восстановления.')
    return
  end
end

  if not bank_canAfford(src, Config.BuyPrice) then notify(src, 'error', 'Недостаточно средств на банковском счёте.') return end
  if not bank_remove(src, Config.BuyPrice, Config.TransactionTitles.buy) then notify(src, 'error', 'Оплата не прошла. Проверьте баланс.') return end

  local affected = MySQL.update.await('UPDATE oilrig_ownership SET owner_cid = ? WHERE rig_key = ? AND owner_cid IS NULL', { cid, rigKey })
  if affected == 0 then
    bank_add(src, Config.BuyPrice, (Config.TransactionTitles.buy .. ' Refund'))
    notify(src, 'error', 'Кто-то купил установку раньше. Деньги возвращены.')
    return
  end

  do
    local rigRow = MySQL.single.await('SELECT deposit_total, deposit_remaining, depleted_until FROM oilrig_rigs WHERE rig_key = ? LIMIT 1', { rigKey })
    local depT = tonumber(rigRow and rigRow.deposit_total) or 0
    local depR = tonumber(rigRow and rigRow.deposit_remaining) or 0
    if depT > 0 then
      notify(src, 'success', ('Вы купили насосную установку. Месторождение: %d / %d'):format(depR, depT))
    else
      notify(src, 'success', 'Вы купили насосную установку.')
    end
  end
  pcall(function()
    local row2 = MySQL.single.await('SELECT x,y,z FROM oilrig_rigs WHERE rig_key = ? LIMIT 1', { rigKey })
    if row2 then upsertRigBlipCache(rigKey, row2.x, row2.y, row2.z, cid) else upsertRigBlipCache(rigKey, 0, 0, 0, cid) end
    broadcastRigBlipUpdate(rigKey)
  end)
end)

RegisterNetEvent('qbx_oilrig:server:sell', function(rigKey)
  local src = source
  local player = getPlayer(src)
  if not player then return end
  local cid = getCID(player)
  if not cid then return end

  ensureProductionRow(rigKey)
  pcall(function() produceForRig(rigKey) end)

  local row = MySQL.single.await('SELECT owner_cid FROM oilrig_ownership WHERE rig_key = ?', { rigKey })
  local ownerCid = row and row.owner_cid or nil
  if not hasRigPermission(rigKey, cid, ownerCid, 'repair') then notify(src, 'error', 'Нет доступа к ремонту вышки.') return end

  MySQL.update.await('UPDATE oilrig_production SET is_running = 0 WHERE rig_key = ?', { rigKey })
  MySQL.update.await('UPDATE oilrig_ownership SET owner_cid = NULL WHERE rig_key = ? AND owner_cid = ?', { rigKey, cid })

  bank_add(src, Config.SellPrice, Config.TransactionTitles.sell)
  notify(src, 'success', 'Вы продали насосную установку.')
  pcall(function()
    local row2 = MySQL.single.await('SELECT x,y,z FROM oilrig_rigs WHERE rig_key = ? LIMIT 1', { rigKey })
    if row2 then upsertRigBlipCache(rigKey, row2.x, row2.y, row2.z, nil) else upsertRigBlipCache(rigKey, 0, 0, 0, nil) end
    broadcastRigBlipUpdate(rigKey)
  end)
end)

RegisterNetEvent('qbx_oilrig:server:repairPart', function(rigKey, partId)
  local src = source
  local player = getPlayer(src)
  if not player then return end
  local cid = getCID(player)
  if not cid then return end

  ensureRigRow(rigKey); ensureParts(rigKey)

  local row = MySQL.single.await('SELECT owner_cid FROM oilrig_ownership WHERE rig_key = ?', { rigKey })
  if not row or row.owner_cid ~= cid then notify(src, 'error', 'Вы не владелец этой установки.') return end

  local partCfg
  for _, p in ipairs(Config.Parts) do if p.id == partId then partCfg = p break end end
  if not partCfg then return end

  local partRow = MySQL.single.await('SELECT health FROM oilrig_parts WHERE rig_key = ? AND part_id = ?', { rigKey, partId })
  local health = partRow and tonumber(partRow.health) or 0
  if health < 0 then health = 0 end
  if health > 100 then health = 100 end

  local target = Config.RepairToHealth or 100
  if health >= target then notify(src, 'info', ('%s уже в отличном состоянии.'):format(partCfg.label)) return end

  local price = calcRepairPrice(partCfg.price, health)
  if not bank_canAfford(src, price) then notify(src, 'error', 'Недостаточно средств на банковском счёте.') return end
  if not bank_remove(src, price, Config.TransactionTitles.repair) then notify(src, 'error', 'Оплата не прошла. Проверьте баланс.') return end

  MySQL.update.await('UPDATE oilrig_parts SET health = ? WHERE rig_key = ? AND part_id = ?', { target, rigKey, partId })
  notify(src, 'success', ('Отремонтировано: %s ($%d)'):format(partCfg.label, price))
end)


-- ===== Admin/debug: reload blip cache and broadcast =====
RegisterCommand('oilrig_blips_reload', function(src)
  if src ~= 0 then
    notify(src, 'error', 'Команда доступна только из серверной консоли.')
    return
  end
  loadRigBlipCache()
  local list = {}
  for k, v in pairs(RigBlipCache) do
    list[#list+1] = { rigKey = k, x = v.x, y = v.y, z = v.z, ownerCid = v.ownerCid }
  end
  TriggerClientEvent('qbx_oilrig:client:rigBlipBulk', -1, list)
  dbg('oilrig_blips_reload broadcasted rigs=%d', #list)
end, true)
