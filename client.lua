local CurrentRig = {
  entity = nil,
  rigKey = nil,
  lastView = 'main',
  menuAutoThread = nil,
  menuAutoThreadStop = false,
  menuOpen = false,
  openContext = nil
}

local PendingProd = {} -- reqId -> { resolve=function, timer=int }

local function dbg(msg, ...)
  if not Config.Debug then return end
  print(('[qbx_oilrig][client] ' .. msg):format(...))
end

local function rigKeyFromCoords(coords)
  local x = math.floor(coords.x * 10 + 0.5) / 10
  local y = math.floor(coords.y * 10 + 0.5) / 10
  local z = math.floor(coords.z * 10 + 0.5) / 10
  return ('oilrig:%.1f:%.1f:%.1f'):format(x, y, z)
end

local function getDistToEntity(ent)
  local p = GetEntityCoords(cache.ped)
  local e = GetEntityCoords(ent)
  return #(p - e)
end

local function colorSchemeByHealth(h)
  -- ox_lib поддерживает ограниченный набор схем для progress (например: red/yellow/green).
  -- Раньше было lime/orange -> в UI падало в дефолт (поэтому всё было зелёным).
  if h <= 35 then return 'red' end
  if h <= 84 then return 'yellow' end
  return 'green'
end

local function healthToHexColor(h)
  -- плавный градиент: красный (0) -> зелёный (100)
  local t = (tonumber(h) or 0) / 100.0
  if t < 0 then t = 0 end
  if t > 1 then t = 1 end
  local r = math.floor(255 * (1.0 - t) + 0.5)
  local g = math.floor(255 * t + 0.5)
  return string.format('#%02X%02X%02X', r, g, 0)
end

local function safeHideContext()
  if lib and lib.hideContext then pcall(function() lib.hideContext() end)
  elseif lib and lib.closeContext then pcall(function() lib.closeContext() end)
  end
end

local function startMenuAutoRefresh(rigKey)
  if not Config.MenuAutoRefreshSeconds or Config.MenuAutoRefreshSeconds <= 0 then return end
  if CurrentRig.menuAutoThread then return end

  CurrentRig.menuAutoThreadStop = false
  CurrentRig.menuAutoThread = CreateThread(function()
    dbg('menu auto refresh thread started (%ds)', Config.MenuAutoRefreshSeconds)
    while not CurrentRig.menuAutoThreadStop do
      Wait((Config.MenuAutoRefreshSeconds or 5) * 1000)
      if CurrentRig.menuAutoThreadStop then break end
      if not CurrentRig.menuOpen then break end
      if not CurrentRig.entity or not DoesEntityExist(CurrentRig.entity) then break end
      if getDistToEntity(CurrentRig.entity) > (Config.MaxUseDistance + 2.0) then break end
      TriggerEvent('qbx_oilrig:client:refresh', rigKey)
    end
    dbg('menu auto refresh thread stopped')
    CurrentRig.menuAutoThread = nil
  end)
end

local function stopMenuAutoRefresh()
  CurrentRig.menuAutoThreadStop = true
end

-- === Production request via event ACK (no ox_lib callback dependency) ===
RegisterNetEvent('qbx_oilrig:client:productionResult', function(reqId, ok, message, isRunning)
  local p = PendingProd[reqId]
  if not p then
    dbg('productionResult unknown reqId=%s', tostring(reqId))
    return
  end
  PendingProd[reqId] = nil
  if p.timer then pcall(function() ClearTimeout(p.timer) end) end
  p.resolve({ ok = ok, message = message, isRunning = isRunning })
end)

local function awaitProductionResult(reqId)
  local promise = promise.new()

  local timeout = tonumber(Config.ProductionRequestTimeout) or 8000
  local t = SetTimeout(timeout, function()
    if PendingProd[reqId] then
      PendingProd[reqId] = nil
      promise:resolve(nil)
    end
  end)

  PendingProd[reqId] = {
    resolve = function(res) promise:resolve(res) end,
    timer = t
  }

  return Citizen.Await(promise)
end

local function setProduction(entity, rigKey, enable)
  CurrentRig.entity = entity
  CurrentRig.rigKey = rigKey
  CurrentRig.lastView = 'main'
safeHideContext()

  lib.progressCircle({
    duration = 900,
    label = enable and 'Запуск добычи...' or 'Остановка добычи...',
    position = 'bottom',
    useWhileDead = false,
    canCancel = false,
    disable = { move = true, car = true, combat = true },
  })

  local reqId = tostring(GetGameTimer()) .. ':' .. tostring(math.random(1000, 9999))
  dbg('setProduction event -> server rigKey=%s enable=%s reqId=%s', rigKey, tostring(enable), reqId)
  TriggerServerEvent('qbx_oilrig:server:setProduction', rigKey, enable, reqId)

  local res = awaitProductionResult(reqId)
  if not res then
    lib.notify({ type = 'error', description = 'Нет ответа от сервера (setProduction ACK).' })
    return
  end

  if not res.ok then
    lib.notify({ type = 'error', description = res.message or 'Не удалось изменить состояние добычи.' })
    dbg('setProduction failed: %s', tostring(res.message))
  else
    lib.notify({ type = 'success', description = enable and 'Добыча запущена.' or 'Добыча остановлена.' })
  end

  Wait(150)
  TriggerEvent('qbx_oilrig:client:refresh', rigKey)
end

local function openEquipmentMenu(entity, rigKey)
  if not entity or not DoesEntityExist(entity) then return end
  if getDistToEntity(entity) > Config.MaxUseDistance then
    lib.notify({ type = 'error', description = 'Слишком далеко.' })
    return
  end

  dbg('openEquipmentMenu rigKey=%s', rigKey)

  local data = lib.callback.await('qbx_oilrig:server:getEquipment', false, rigKey)
  if not data then
    lib.notify({ type = 'error', description = 'Не удалось получить данные по оборудованию.' })
    return
  end
  if (not data.isOwner) and (not data.canRepair) then
    lib.notify({ type = 'error', description = 'Нет доступа к ремонту вышки.' })
    return
  end

  local options = {}

  for _, part in ipairs(data.parts) do
    local health = tonumber(part.health) or 0
    if health < 0 then health = 0 end
    if health > 100 then health = 100 end

    local scheme = colorSchemeByHealth(health)

    local hex = healthToHexColor(health)

    options[#options+1] = {
      title = part.label,
      description = ('Состояние: %d%% • Ремонт: $%d'):format(health, tonumber(part.repairPrice) or 0),
      icon = 'wrench',
      iconColor = hex,
      progress = health,
      progressColor = hex,
      colorScheme = scheme,
      onSelect = function()
        CurrentRig.entity = entity
        CurrentRig.rigKey = rigKey
        CurrentRig.lastView = 'equipment'
local ok = lib.progressCircle({
          duration = (Config.RepairTime or 5) * 1000,
          label = ('Ремонт: %s'):format(part.label),
          position = 'bottom',
          useWhileDead = false,
          canCancel = true,
          disable = { move = true, car = true, combat = true },
        })
        if ok then
          dbg('repairPart -> server rigKey=%s part=%s', rigKey, part.id)
          TriggerServerEvent('qbx_oilrig:server:repairPart', rigKey, part.id)
        end
      end
    }
  end

  options[#options+1] = {
    title = 'Вернуться в главное меню',
    description = 'Назад к действиям с вышкой.',
    icon = 'arrow-left',
    iconColor = 'gray',
    onSelect = function()
      CurrentRig.lastView = 'main'
TriggerEvent('qbx_oilrig:client:refresh', rigKey)
    end
  }

  CurrentRig.entity = entity
  CurrentRig.rigKey = rigKey
  CurrentRig.lastView = 'equipment'
lib.registerContext({
    id = 'qbx_oilrig_equipment',
    title = 'Оборудование',
    options = options,
    onExit = function()
      dbg('context exit equipment')
      CurrentRig.menuOpen = false
      CurrentRig.openContext = nil
      stopMenuAutoRefresh()
    end
  })
  CurrentRig.menuOpen = true
  CurrentRig.openContext = 'equipment'
lib.showContext('qbx_oilrig_equipment')
end


local function openWorkerEditMenu(entity, rigKey, worker)
  if not worker then return end
  stopMenuAutoRefresh()

  local perms = worker.perms or { stash = false, production = false, repair = false }

  local function setPerms(newPerms)
    local res = lib.callback.await('qbx_oilrig:server:updateWorkerPerms', false, rigKey, worker.cid, newPerms)
    if not res or not res.ok then
      lib.notify({ type = 'error', description = (res and res.message) or 'Ошибка обновления прав.' })
      return perms
    end
    return newPerms
  end

  local function yesno(v) return v and 'Да' or 'Нет' end

  local options = {
    {
      title = ('Склад: %s'):format(yesno(perms.stash)),
      description = 'Доступ к инвентарю вышки (stash).',
      icon = 'box-open',
      iconColor = '#D0D4DB',
      onSelect = function()
        perms = setPerms({ stash = not perms.stash, production = perms.production, repair = perms.repair })
        openWorkerEditMenu(entity, rigKey, { cid = worker.cid, name = worker.name, perms = perms })
      end
    },
    {
      title = ('Добыча: %s'):format(yesno(perms.production)),
      description = 'Разрешить запуск/остановку добычи.',
      icon = 'play',
      iconColor = '#D0D4DB',
      onSelect = function()
        perms = setPerms({ stash = perms.stash, production = not perms.production, repair = perms.repair })
        openWorkerEditMenu(entity, rigKey, { cid = worker.cid, name = worker.name, perms = perms })
      end
    },
    {
      title = ('Ремонт: %s'):format(yesno(perms.repair)),
      description = 'Разрешить ремонт оборудования.',
      icon = 'wrench',
      iconColor = '#D0D4DB',
      onSelect = function()
        perms = setPerms({ stash = perms.stash, production = perms.production, repair = not perms.repair })
        openWorkerEditMenu(entity, rigKey, { cid = worker.cid, name = worker.name, perms = perms })
      end
    },
    {
      title = 'Пресет: только ремонт',
      description = 'Склад: Нет • Добыча: Нет • Ремонт: Да',
      icon = 'screwdriver-wrench',
      iconColor = '#D0D4DB',
      onSelect = function()
        perms = setPerms({ stash = false, production = false, repair = true })
        openWorkerEditMenu(entity, rigKey, { cid = worker.cid, name = worker.name, perms = perms })
      end
    },
    {
      title = 'Пресет: всё',
      description = 'Склад: Да • Добыча: Да • Ремонт: Да',
      icon = 'user-shield',
      iconColor = '#D0D4DB',
      onSelect = function()
        perms = setPerms({ stash = true, production = true, repair = true })
        openWorkerEditMenu(entity, rigKey, { cid = worker.cid, name = worker.name, perms = perms })
      end
    },
    {
      title = 'Удалить работника',
      description = 'Убрать доступ к этой вышке.',
      icon = 'user-xmark',
      iconColor = 'red',
      onSelect = function()
        local res = lib.callback.await('qbx_oilrig:server:removeWorker', false, rigKey, worker.cid)
        if not res or not res.ok then
          lib.notify({ type = 'error', description = (res and res.message) or 'Ошибка удаления.' })
          return
        end
        lib.notify({ type = 'success', description = 'Работник удалён.' })
        Wait(150)
        openWorkersMenu(entity, rigKey)
      end
    },
    {
      title = 'Назад',
      description = 'Вернуться к списку работников.',
      icon = 'arrow-left',
      iconColor = 'gray',
      onSelect = function()
        openWorkersMenu(entity, rigKey)
      end
    }
  }

  CurrentRig.entity = entity
  CurrentRig.rigKey = rigKey
  CurrentRig.lastView = 'workers'

  lib.registerContext({
    id = 'qbx_oilrig_worker_edit',
    title = ('Работник: %s'):format(worker.name or worker.cid),
    options = options,
    onExit = function()
      dbg('context exit worker_edit')
      CurrentRig.menuOpen = false
      CurrentRig.openContext = nil
      stopMenuAutoRefresh()
    end
  })
  CurrentRig.menuOpen = true
  CurrentRig.openContext = 'worker_edit'
  lib.showContext('qbx_oilrig_worker_edit')
end

function openWorkersMenu(entity, rigKey)
  if not entity or not DoesEntityExist(entity) then return end
  if getDistToEntity(entity) > Config.MaxUseDistance then
    lib.notify({ type = 'error', description = 'Слишком далеко.' })
    return
  end

  stopMenuAutoRefresh()

  local list = lib.callback.await('qbx_oilrig:server:getWorkers', false, rigKey)
  if not list then
    lib.notify({ type = 'error', description = 'Нет доступа к списку работников.' })
    return
  end

  local options = {}

  options[#options+1] = {
    title = 'Добавить работника',
    description = 'Выдать доступ игроку (по Server ID).',
    icon = 'user-plus',
    iconColor = '#D0D4DB',
    onSelect = function()
      local input = lib.inputDialog('Добавить работника', {
        { type = 'number', label = 'Server ID', description = 'ID игрока (таб/консоль)', required = true, min = 1 }
      })
      if not input then return end
      local targetId = tonumber(input[1] or 0) or 0
      if targetId <= 0 then return end

      local res = lib.callback.await('qbx_oilrig:server:addWorker', false, rigKey, targetId)
      if not res or not res.ok then
        lib.notify({ type = 'error', description = (res and res.message) or 'Ошибка добавления.' })
        return
      end
      lib.notify({ type = 'success', description = 'Работник добавлен. Настрой права в списке.' })
      Wait(150)
      openWorkersMenu(entity, rigKey)
    end
  }

  for _, w in ipairs(list) do
    local p = w.perms or {}
    local desc = ('Склад: %s • Добыча: %s • Ремонт: %s'):format(p.stash and 'Да' or 'Нет', p.production and 'Да' or 'Нет', p.repair and 'Да' or 'Нет')
    options[#options+1] = {
      title = w.name or w.cid,
      description = desc,
      icon = 'user',
      iconColor = '#D0D4DB',
      onSelect = function()
        openWorkerEditMenu(entity, rigKey, w)
      end
    }
  end

  options[#options+1] = {
    title = 'Вернуться в главное меню',
    description = 'Назад к действиям с вышкой.',
    icon = 'arrow-left',
    iconColor = 'gray',
    onSelect = function()
      CurrentRig.lastView = 'main'
      TriggerEvent('qbx_oilrig:client:refresh', rigKey)
    end
  }

  CurrentRig.entity = entity
  CurrentRig.rigKey = rigKey
  CurrentRig.lastView = 'workers'

  lib.registerContext({
    id = 'qbx_oilrig_workers',
    title = 'Работники',
    options = options,
    onExit = function()
      dbg('context exit workers')
      CurrentRig.menuOpen = false
      CurrentRig.openContext = nil
      stopMenuAutoRefresh()
    end
  })
  CurrentRig.menuOpen = true
  CurrentRig.openContext = 'workers'
  lib.showContext('qbx_oilrig_workers')
end


local function buildAndShowRigMenu(entity, rigKey, state)
  local options = {}

  dbg('build menu rigKey=%s owner=%s isOwner=%s running=%s progress=%s',
    rigKey, tostring(state.ownerCid), tostring(state.isOwner), tostring(state.isRunning), tostring(state.prodProgress))



-- Месторождение (иссякаемое)
if state.depositTotal and tonumber(state.depositTotal) and tonumber(state.depositTotal) > 0 then
  local depT = tonumber(state.depositTotal) or 0
  local depR = tonumber(state.depositRemaining) or 0
  local pct = math.floor(((depR / depT) * 100) + 0.5)
  if pct < 0 then pct = 0 end
  if pct > 100 then pct = 100 end
  options[#options+1] = {
    title = 'Месторождение',
    description = ('Осталось: %d / %d'):format(depR, depT),
    icon = 'oil-well',
    iconColor = '#D0D4DB',
    progress = pct,
    readOnly = true,
    disabled = true
  }
end
  if not state.ownerCid then
    local depLine = ''
    if state.depositTotal and tonumber(state.depositTotal) and tonumber(state.depositTotal) > 0 then
      depLine = ('\nМесторождение: %d / %d'):format(tonumber(state.depositRemaining) or 0, tonumber(state.depositTotal) or 0)
    end

    local depleted = ((state.depositRemaining ~= nil and tonumber(state.depositRemaining) or 0) <= 0)
      and ((state.depletedUntil ~= nil and tonumber(state.depletedUntil) or 0) > 0)

    local desc = 'Оплата идёт с банковского счёта.' .. depLine
    if depleted then
      desc = desc .. '\nМесторождение иссякло (кулдаун).'
    end

    options[#options+1] = {
      title = ('Купить насосную установку ($%d)'):format(Config.BuyPrice),
      description = desc,
      icon = 'shopping-cart',
      disabled = depleted,
      iconColor = '#D0D4DB',
      onSelect = function()
        if depleted then return end
        TriggerServerEvent('qbx_oilrig:server:buy', rigKey)
        safeHideContext()
        Wait(200)
        TriggerEvent('qbx_oilrig:client:refresh', rigKey)
      end
    }

  else
    if state.isOwner then
      if state.isRunning then
        options[#options+1] = {
          title = 'Добыча запущена',
          description = ('Прогресс часа: %d%% • %d/час • Ресурс: %s'):format(state.prodProgress or 0, Config.OilPerHour or 500, Config.OilItem or 'item'),
          icon = 'industry',
          iconColor = 'green',
          progress = state.prodProgress or 0,
          colorScheme = 'green',
          disabled = true
        }

        options[#options+1] = {
          title = 'Остановить добычу',
          description = 'Поставить добычу на паузу.',
          icon = 'pause',
          iconColor = 'red',
          onSelect = function()
            setProduction(entity, rigKey, false)
          end
        }
      else
        options[#options+1] = {
          title = 'Запустить добычу',
          description = ('Запустить добычу (%d/час). Ресурс: %s'):format(Config.OilPerHour or 500, Config.OilItem or 'item'),
          icon = 'play',
          iconColor = 'green',
          onSelect = function()
            setProduction(entity, rigKey, true)
          end
        }
      end
      options[#options+1] = {
        title = 'Работники',
        description = 'Добавить работников и настроить права (склад/добыча/ремонт).',
        icon = 'users-gear',
        iconColor = '#D0D4DB',
        onSelect = function()
          openWorkersMenu(entity, rigKey)
        end
      }

      options[#options+1] = {
        title = 'Инвентарь вышки',
        description = 'Открыть склад вышки (ox_inventory).',
        icon = 'box-open',
        iconColor = '#D0D4DB',
        onSelect = function()
          -- Меню должно закрыться и не открываться снова, пока игрок сам не откроет его через target
          CurrentRig.menuOpen = false
          CurrentRig.openContext = nil
          stopMenuAutoRefresh()
          safeHideContext()
          Wait(50)
          TriggerServerEvent('qbx_oilrig:server:openStash', rigKey)
        end
      }

      options[#options+1] = {
        title = ('Продать насосную установку ($%d)'):format(Config.SellPrice),
        description = 'Деньги поступят на банковский счёт.',
        icon = 'hand-holding-dollar',
        iconColor = '#D0D4DB',
        onSelect = function()
          TriggerServerEvent('qbx_oilrig:server:sell', rigKey)
          safeHideContext()
          Wait(200)
          TriggerEvent('qbx_oilrig:client:refresh', rigKey)
        end
      }


      if state.hasBrokenPart then
        options[#options+1] = {
          title = 'Вышка требует ремонта',
          description = 'Одна или несколько деталей сломаны. Почините оборудование.',
          icon = 'triangle-exclamation',
          iconColor = 'orange',
          onSelect = function()
            openEquipmentMenu(entity, rigKey)
          end
        }
      end

      options[#options+1] = {
        title = 'Оборудование',
        description = 'Детали и их состояние. Нажмите деталь, чтобы выполнить ремонт.',
        icon = 'toolbox',
        iconColor = '#D0D4DB',
        onSelect = function()
          openEquipmentMenu(entity, rigKey)
        end
      }
    else
      -- не владелец: показываем либо 'занята', либо доступ работника (если выдан)
      local canStash = state.canStash == true
      local canProd = state.canProduction == true
      local canRepair = state.canRepair == true

      if canProd then
        if state.isRunning then
          options[#options+1] = {
            title = 'Добыча запущена',
            description = ('Прогресс часа: %d%% • %d/час • Ресурс: %s'):format(state.prodProgress or 0, Config.OilPerHour or 500, Config.OilItem or 'item'),
            icon = 'industry',
            iconColor = 'green',
            progress = state.prodProgress or 0,
            colorScheme = 'green',
            disabled = true
          }
          options[#options+1] = {
            title = 'Остановить добычу',
            description = 'Поставить добычу на паузу.',
            icon = 'pause',
            iconColor = 'red',
            onSelect = function()
              setProduction(entity, rigKey, false)
            end
          }
        else
          options[#options+1] = {
            title = 'Запустить добычу',
            description = ('Запустить добычу (%d/час). Ресурс: %s'):format(Config.OilPerHour or 500, Config.OilItem or 'item'),
            icon = 'play',
            iconColor = 'green',
            onSelect = function()
              setProduction(entity, rigKey, true)
            end
          }
        end
      end

      if canStash then
        options[#options+1] = {
          title = 'Инвентарь вышки',
          description = 'Открыть склад вышки (ox_inventory).',
          icon = 'box-open',
          iconColor = '#D0D4DB',
          onSelect = function()
            CurrentRig.menuOpen = false
            CurrentRig.openContext = nil
            stopMenuAutoRefresh()
            safeHideContext()
            Wait(50)
            TriggerServerEvent('qbx_oilrig:server:openStash', rigKey)
          end
        }
      end

      if canRepair then
        if state.hasBrokenPart then
          options[#options+1] = {
            title = 'Вышка требует ремонта',
            description = 'Одна или несколько деталей сломаны. Почините оборудование.',
            icon = 'triangle-exclamation',
            iconColor = 'orange',
            onSelect = function()
              openEquipmentMenu(entity, rigKey)
            end
          }
        end
        options[#options+1] = {
          title = 'Оборудование',
          description = 'Детали и их состояние. Нажмите деталь, чтобы выполнить ремонт.',
          icon = 'toolbox',
          iconColor = '#D0D4DB',
          onSelect = function()
            openEquipmentMenu(entity, rigKey)
          end
        }
      end

      if (not canStash) and (not canProd) and (not canRepair) then
        options[#options+1] = {
          title = 'Насосная установка занята',
          description = 'Эта вышка уже куплена другим владельцем.',
          icon = 'lock',
          iconColor = 'red'
        }
      end
    end
  end

  CurrentRig.entity = entity
  CurrentRig.rigKey = rigKey
  CurrentRig.lastView = 'main'
lib.registerContext({
    id = 'qbx_oilrig_main',
    title = 'Нефтяная вышка',
    options = options,
    onExit = function()
      dbg('context exit main')
      CurrentRig.menuOpen = false
      CurrentRig.openContext = nil
      stopMenuAutoRefresh()
    end
  })
  CurrentRig.menuOpen = true
  CurrentRig.openContext = 'main'
lib.showContext('qbx_oilrig_main')

  if state.isRunning then startMenuAutoRefresh(rigKey) else stopMenuAutoRefresh() end
end

local function openRigMenu(entity, rigKeyOverride)
  if not DoesEntityExist(entity) then return end
  if getDistToEntity(entity) > Config.MaxUseDistance then
    lib.notify({ type = 'error', description = 'Слишком далеко.' })
    return
  end

  local coords = GetEntityCoords(entity)
  local rigKey = rigKeyOverride or rigKeyFromCoords(coords)

  CurrentRig.entity = entity
  CurrentRig.rigKey = rigKey
  CurrentRig.lastView = 'main'
dbg('openRigMenu coords=%.2f %.2f %.2f rigKey=%s', coords.x, coords.y, coords.z, rigKey)

  local state = lib.callback.await('qbx_oilrig:server:getRigState', false, rigKey, coords)
  if not state then
    lib.notify({ type = 'error', description = 'Не удалось получить состояние вышки. Проверь oxmysql/базу.' })
    return
  end

  buildAndShowRigMenu(entity, rigKey, state)
end

RegisterNetEvent('qbx_oilrig:client:refresh', function(rigKey)
  if not CurrentRig.menuOpen then
    dbg('refresh skipped (menu closed)')
    return
  end
  if not CurrentRig.entity or not DoesEntityExist(CurrentRig.entity) then return end
  if getDistToEntity(CurrentRig.entity) > (Config.MaxUseDistance + 2.0) then return end

  rigKey = rigKey or CurrentRig.rigKey
  if not rigKey then rigKey = rigKeyFromCoords(GetEntityCoords(CurrentRig.entity)) end

  dbg('refresh rigKey=%s lastView=%s', rigKey, tostring(CurrentRig.lastView))

  if CurrentRig.lastView == 'equipment' then
    openEquipmentMenu(CurrentRig.entity, rigKey)
  elseif CurrentRig.lastView == 'workers' or CurrentRig.lastView == 'worker_edit' then
    openWorkersMenu(CurrentRig.entity, rigKey)
  else
    openRigMenu(CurrentRig.entity, rigKey)
  end
end)

-- ========= Scan command =========
local function enumerateObjects()
  return coroutine.wrap(function()
    local handle, entity = FindFirstObject()
    if not handle or handle == -1 then return end
    local success = true
    while success do
      coroutine.yield(entity)
      success, entity = FindNextObject(handle)
    end
    EndFindObject(handle)
  end)
end

RegisterCommand('oilrig_scan', function(_, args)
  local radius = tonumber(args[1]) or Config.ScanDefaultRadius or 200.0
  local pcoords = GetEntityCoords(cache.ped)
  local model = Config.TargetModel
  local rigs = {}

  dbg('scan start radius=%.1f', radius)

  for obj in enumerateObjects() do
    if DoesEntityExist(obj) and GetEntityModel(obj) == model then
      local c = GetEntityCoords(obj)
      if #(pcoords - c) <= radius then
        rigs[#rigs+1] = { x = c.x, y = c.y, z = c.z, h = GetEntityHeading(obj), rigKey = rigKeyFromCoords(c) }
      end
    end
  end

  dbg('scan found %d rigs', #rigs)
  if #rigs == 0 then
    lib.notify({ type = 'info', description = 'Вышек рядом не найдено.' })
    return
  end

  TriggerServerEvent('qbx_oilrig:server:registerRigs', rigs)
  lib.notify({ type = 'success', description = ('Найдено и отправлено: %d вышек.'):format(#rigs) })
end, false)

CreateThread(function()
  exports.ox_target:addModel(Config.TargetModel, {
    {
      name = 'qbx_oilrig_use',
      label = 'Использовать',
      icon = 'fa-solid fa-oil-well',
      distance = Config.MaxUseDistance,
      onSelect = function(data)
        openRigMenu(data.entity, nil)
      end
    }
  })
end)


-- ===== Map blips =====
local RigBlips = {} -- rigKey -> blipId
local refineryTargetCreated = false
local RefineryState = { menuOpen = false, refreshStop = false, job = nil }

local function removeRigBlip(rigKey)
  local b = RigBlips[rigKey]
  if b and DoesBlipExist(b) then
    RemoveBlip(b)
  end
  RigBlips[rigKey] = nil
end

local function setBlipName(blip, name)
  BeginTextCommandSetBlipName('STRING')
  AddTextComponentString(name)
  EndTextCommandSetBlipName(blip)
end

local function ensureRigBlip(entry)
  if not Config.Blips or not Config.Blips.Enabled then return end
  if not entry or not entry.rigKey then return end

  local rigKey = entry.rigKey
  local owned = entry.ownerCid ~= nil and entry.ownerCid ~= ''
local style = owned and (Config.Blips.Owned or {}) or (Config.Blips.ForSale or {})
  local sprite = tonumber(style.sprite) or 361
  local color = tonumber(style.color) or (owned and 1 or 2)
  local scale = tonumber(style.scale) or 0.75
  local label = style.label or (owned and 'Нефтяная вышка (куплена)' or 'Нефтяная вышка (в продаже)')

  removeRigBlip(rigKey)

  local blip = AddBlipForCoord(tonumber(entry.x) or 0.0, tonumber(entry.y) or 0.0, tonumber(entry.z) or 0.0)
  SetBlipSprite(blip, sprite)
  SetBlipColour(blip, color)
  SetBlipScale(blip, scale)
  -- 3 = Visible on Map but not Radar (no minimap icons)
  SetBlipDisplay(blip, 3)
  SetBlipAsShortRange(blip, (Config.Blips.ShortRange == true))
  setBlipName(blip, label)

  RigBlips[rigKey] = blip
end

RegisterNetEvent('qbx_oilrig:client:rigBlipBulk', function(list)
  dbg('rigBlipBulk count=%s', tostring(type(list) == 'table' and #list or 'nil'))
  if type(list) ~= 'table' then return end
  for _, entry in ipairs(list) do
    ensureRigBlip(entry)
  end
end)

RegisterNetEvent('qbx_oilrig:client:rigBlipUpdate', function(rigKey, x, y, z, ownerCid)
  dbg('rigBlipUpdate rigKey=%s owner=%s', tostring(rigKey), tostring(ownerCid))
  ensureRigBlip({ rigKey = rigKey, x = x, y = y, z = z, ownerCid = ownerCid })
end)

local function loadRigBlips()
  if not Config.Blips or not Config.Blips.Enabled then return end
  local list = lib.callback.await('qbx_oilrig:server:getRigBlips', false)
  if type(list) ~= 'table' then
    dbg('getRigBlips returned nil')
    return
  end
  for _, entry in ipairs(list) do
    ensureRigBlip(entry)
  end
end

AddEventHandler('onClientResourceStart', function(res)
  if res ~= GetCurrentResourceName() then return end
  CreateThread(function()
    Wait(1200)
    pcall(loadRigBlips)
    Wait(400)
    pcall(startRefineryTargetLoop)
  end)
end)

-- manual reload
RegisterCommand('oilrig_blips', function()
  pcall(loadRigBlips)
  lib.notify({ type = 'info', description = 'Блипы нефтевышек обновлены.' })
end, false)


-- ===== Refinery / Sales =====
local function buildAndShowRefineryMenu(state, fromTick)
  if not Config.Refinery or not Config.Refinery.Enabled then
    lib.notify({ type = 'error', description = 'Переработка отключена конфигом.' })
    return
  end

  local oilItem = Config.OilItem or 'oil'
local oilCount = exports.ox_inventory:GetItemCount(oilItem) or 0

  local job = state and state.job or nil
  RefineryState.job = job

  -- локальный прогресс (без сервера)
  if job then
    resetLocalJobBaseline(job) -- если пришло состояние с сервера, обновим baseline
    updateLocalJobProgress(job)
  end

  dbg('buildRefineryMenu oilItem=%s oilCount=%s job=%s', tostring(oilItem), tostring(oilCount), tostring(job ~= nil))

  local options = {}

  if job then
    options[#options+1] = {
      title = ('Переработка: %s'):format(tostring(job.recipeKey or '')),
      description = ('Прогресс: %d%% | Осталось: %s'):format(job.progress or 0, formatSeconds(job.remaining or 0)),
      icon = 'hourglass-half',
      iconColor = 'yellow',
      progress = job.progress or 0,
      readOnly = true,
      disabled = true
    }

    if (job.progress or 0) >= 100 then
      options[#options+1] = {
        title = 'Забрать результат',
        description = ('Получить: %s x%s'):format(tostring(job.outItem or ''), tostring(job.outTotal or 0)),
        icon = 'box-open',
        iconColor = 'green',
        onSelect = function()
          TriggerServerEvent('qbx_oilrig:server:claimRefinery')
        end
      }
    else
      options[#options+1] = {
        title = 'Забрать результат',
        description = 'Доступно после завершения переработки.',
        icon = 'box-open',
        iconColor = 'grey',
        disabled = true
      }
    end
  else
    options[#options+1] = {
      title = 'Продать нефть',
      description = ('Цена: $%s за 1'):format(tostring(Config.Refinery.SellPricePerUnit or 0)),
      icon = 'hand-holding-dollar',
      iconColor = 'green',
      onSelect = function()
        oilCount = exports.ox_inventory:GetItemCount(oilItem) or 0
        if oilCount <= 0 then
          lib.notify({ type = 'error', description = 'У вас нет нефти для продажи.' })
          return
        end

        local input = lib.inputDialog('Продажа нефти', {
          { type = 'slider', label = 'Количество', min = 1, max = oilCount, step = 1, default = oilCount, icon = 'droplet' },
        }, { allowCancel = true, size = 'sm' })

        if not input then return end
        local amount = tonumber(input[1]) or 0
        if amount <= 0 then return end
        TriggerServerEvent('qbx_oilrig:server:sellOil', amount)
      end
    }

    local recipes = (Config.Refinery and Config.Refinery.Recipes) or {}
    for key, r in pairs(recipes) do
      options[#options+1] = {
        title = ('Переработать в %s'):format(r.label or key),
        description = ('Нужно нефти: %s за %s'):format(tostring(r.oil or 1), tostring(r.out or 1)),
        icon = 'industry',
        iconColor = 'blue',
        onSelect = function()
          oilCount = exports.ox_inventory:GetItemCount(oilItem) or 0
          local need = tonumber(r.oil) or 1
          local craftable = math.floor(oilCount / need)

          if craftable <= 0 then
            lib.notify({ type = 'error', description = 'Недостаточно нефти для переработки.' })
            return
          end

          local input = lib.inputDialog(('Переработка: %s'):format(r.label or key), {
            { type = 'slider', label = 'Количество крафта', min = 1, max = craftable, step = 1, default = craftable, icon = 'gears' },
          }, { allowCancel = true, size = 'sm' })

          if not input then return end
          local crafts = tonumber(input[1]) or 0
          if crafts <= 0 then return end
          TriggerServerEvent('qbx_oilrig:server:refineOil', key, crafts)
        end
      }
    end
  end

  lib.registerContext({
    id = 'qbx_oilrig_refinery',
    title = 'НПЗ / Продажа нефти',
    options = options,
    onExit = function()
      dbg('context exit refinery')
      RefineryState.menuOpen = false
      RefineryState.refreshStop = true
    end
  })
  RefineryState.menuOpen = true
  RefineryState.refreshStop = false
  lib.showContext('qbx_oilrig_refinery')

  if job and not fromTick then
    CreateThread(function()
      while RefineryState.menuOpen and not RefineryState.refreshStop and RefineryState.job do
        Wait(1000)
        if not RefineryState.menuOpen or RefineryState.refreshStop then break end
        updateLocalJobProgress(RefineryState.job)
        buildAndShowRefineryMenu({ job = RefineryState.job }, true)
      end
    end)
  end
end

local function openRefineryMenu()
  local state = lib.callback.await('qbx_oilrig:server:getRefineryState', false)
  buildAndShowRefineryMenu(state or { job = nil }, false)
end

local function resolveRefineryCoords(c)
  if not c then return nil end
  local x, y, z = c.x, c.y, c.z
  if Config.Refinery and Config.Refinery.UseGroundZ then
    local probe = (Config.Refinery.GroundProbeHeight or 100.0)
    local ok, gz = GetGroundZFor_3dCoord(x, y, z + probe, false)
    if ok and gz and gz > 0.0 then
      z = gz + 0.05
    end
  end
  return vec3(x, y, z)
end


local licenseTargetCreated = false

local function openLicenseMenu()
  if not Config.License or not Config.License.Enabled then
    lib.notify({ type = 'error', description = 'Лицензии отключены.' })
    return
  end

  lib.registerContext({
    id = 'qbx_oilrig_license',
    title = 'Лицензия на добычу нефти',
    options = {
      {
        title = ('Купить лицензию ($%d)'):format(tonumber(Config.License.Price) or 0),
        description = 'Оплата идёт с банковского счёта.',
        icon = Config.License.Icon or 'id-card',
        iconColor = Config.License.IconColor or 'yellow',
        onSelect = function()
          TriggerServerEvent('qbx_oilrig:server:buyOilLicense')
        end
      }
    }
  })
  lib.showContext('qbx_oilrig_license')
end

local function setupLicenseTarget()
  if licenseTargetCreated then return end
  if not Config.License or not Config.License.Enabled then return end
  if not exports.ox_target then return end

  local c = Config.License.Coords
  if not c then return end
  local radius = Config.License.TargetRadius or 1.8
  local dist = Config.License.TargetDistance or 2.5

  exports.ox_target:addSphereZone({
    coords = vec3(c.x, c.y, c.z),
    radius = radius,
    debug = Config.DebugTarget or false,
    options = {
      {
        name = 'qbx_oilrig_license',
        icon = 'fa-solid fa-id-card',
        label = 'Лицензия на добычу нефти',
        distance = dist,
        onSelect = function()
          openLicenseMenu()
        end
      }
    }
  })

  licenseTargetCreated = true
  dbg('license target created at %.2f %.2f %.2f (radius=%.2f dist=%.2f)', c.x, c.y, c.z, radius, dist)
end

local function setupRefineryTarget()
  if refineryTargetCreated then return true end
  if not Config.Refinery or not Config.Refinery.Enabled then return false end

  if GetResourceState('ox_target') ~= 'started' then
    if Config.Debug then dbg('refinery target: ox_target not started yet') end
    return false
  end

  local c = resolveRefineryCoords(Config.Refinery.Coords)
  if not c then return false end

  local radius = Config.Refinery.TargetRadius or 3.0
  local dist = Config.Refinery.TargetDistance or 3.5

  exports.ox_target:addSphereZone({
    coords = c,
    radius = radius,
    debug = Config.Debug == true,
    options = {
      {
        name = 'qbx_oilrig_refinery',
        icon = 'fa-solid fa-industry',
        label = 'Продажа / переработка нефти',
        distance = dist,
        onSelect = function()
          openRefineryMenu()
        end
      }
    }
  })

  refineryTargetCreated = true

  -- лог всегда, чтобы было видно что зона создана
  print(('[qbx_oilrig][client] refinery target created at %.2f %.2f %.2f (radius=%.2f dist=%.2f)'):format(c.x, c.y, c.z, radius, dist))
  return true
end

function startRefineryTargetLoop()
  if refineryTargetCreated then return end
  if not Config.Refinery or not Config.Refinery.Enabled then return end

  CreateThread(function()
    local retryEvery = (Config.Refinery.TargetRetrySeconds or 2.0) * 1000
    local maxTry = tonumber(Config.Refinery.TargetRetryMax) or 30
    for i = 1, maxTry do
      if setupRefineryTarget() then return end
      Wait(retryEvery)
    end
    print('[qbx_oilrig][client] refinery target NOT created (timeout). Check coords / ox_target / Config.Refinery.Enabled.')
  end)
end

-- manual test (без target)
RegisterCommand('oilrig_refinery', function()
  openRefineryMenu()
end, false)



function formatSeconds(sec)
  sec = tonumber(sec) or 0
  if sec < 0 then sec = 0 end
  local m = math.floor(sec / 60)
  local s = sec % 60
  return string.format('%02d:%02d', m, s)
end


RegisterNetEvent('qbx_oilrig:client:refineryJobUpdated', function()
  dbg('refineryJobUpdated')
  if RefineryState and RefineryState.menuOpen then
    local state = lib.callback.await('qbx_oilrig:server:getRefineryState', false)
    buildAndShowRefineryMenu(state or { job = nil }, false)
  end
end)


-- ===== Local timer helpers (client has no global os.*) =====
function updateLocalJobProgress(job)
  if not job then return end
  local dur = tonumber(job.duration) or 1
  if dur < 1 then dur = 1 end

  -- baseline setup from server snapshot
  if job._fetchAtMs == nil then
    job._fetchAtMs = GetGameTimer()
    -- prefer remaining from server; fallback from progress
    local rem = tonumber(job.remaining)
    if rem == nil then
      local p = tonumber(job.progress) or 0
      rem = dur - (dur * (p / 100.0))
    end
    if rem < 0 then rem = 0 end
    job._remainingAtFetch = rem
  end

  local deltaSec = (GetGameTimer() - (job._fetchAtMs or GetGameTimer())) / 1000.0
  local remaining = (job._remainingAtFetch or 0) - deltaSec
  if remaining < 0 then remaining = 0 end

  local progress = math.floor(((dur - remaining) / dur) * 100 + 0.5)
  if progress < 0 then progress = 0 end
  if progress > 100 then progress = 100 end

  job.progress = progress
  job.remaining = math.floor(remaining + 0.5)
end

function resetLocalJobBaseline(job)
  if not job then return end
  job._fetchAtMs = GetGameTimer()
  local rem = tonumber(job.remaining) or 0
  if rem < 0 then rem = 0 end
  job._remainingAtFetch = rem
end

-- ===== ox_inventory tooltip metadata labels (required on newer ox_inventory) =====
CreateThread(function()
  Wait(750)
  if GetResourceState('ox_inventory') ~= 'started' then return end
  -- Sets which metadata keys should be shown in the tooltip.
  -- Docs: exports.ox_inventory:displayMetadata(...)
  pcall(function()
    exports.ox_inventory:displayMetadata({
      license_no   = 'Номер лицензии',
      first_name   = 'Имя',
      last_name    = 'Фамилия',
      full_name    = 'Владелец',
      issued_date  = 'Выдана',
      expires_date = 'Действует до'
    })
  end)
end)

