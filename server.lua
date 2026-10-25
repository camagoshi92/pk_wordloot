local RESOURCE_NAME = GetCurrentResourceName()
local TABLE_NAME = 'pk_wordloot_containers'

local Core = exports.vorp_core:GetCore()

local containersByHash = {}
local containerStates = {}
local locksByContainer = {}
local sessionsByPlayer = {}
local lastRequestAt = {}
local itemDefinitions = {}
local databaseReady = false
local tokenSequence = 0

local function debugPrint(message, ...)
    if not Config.Debug then return end
    print(('[%s] %s'):format(RESOURCE_NAME, message:format(...)))
end

local function logError(message, ...)
    print(('^1[%s] %s^7'):format(RESOURCE_NAME, message:format(...)))
end

local function unsignedHash(value)
    value = tonumber(value) or 0
    if value < 0 then
        value = value + 4294967296
    end
    return value
end

local function clampInteger(value, minimum, maximum)
    value = math.floor(tonumber(value) or minimum)
    return math.max(minimum, math.min(maximum, value))
end

local function isFiniteNumber(value)
    if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
        return false
    end

    local maximum = tonumber(Config.Security.MaxCoordinateAbsolute) or 10000.0
    return math.abs(value) <= maximum
end

local function distanceBetween(first, second)
    local dx = first.x - second.x
    local dy = first.y - second.y
    local dz = first.z - second.z
    return math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
end

local function roundCoordinate(value)
    local precision = clampInteger(Config.Security.PositionPrecision, 0, 3)
    local factor = 10 ^ precision

    if value >= 0 then
        return math.floor((value * factor) + 0.5) / factor
    end

    return math.ceil((value * factor) - 0.5) / factor
end

local function canonicalCoords(coords)
    return {
        x = roundCoordinate(coords.x),
        y = roundCoordinate(coords.y),
        z = roundCoordinate(coords.z)
    }
end

local function makeContainerId(modelName, coords)
    local precision = clampInteger(Config.Security.PositionPrecision, 0, 3)
    local format = '%s:%.' .. precision .. 'f:%.' .. precision .. 'f:%.' .. precision .. 'f'
    return format:format(modelName, coords.x, coords.y, coords.z)
end

local function elapsedMilliseconds(startedAt)
    local elapsed = GetGameTimer() - startedAt
    if elapsed < 0 then
        elapsed = elapsed + 4294967296
    end
    return elapsed
end

local function formatRemaining(seconds)
    seconds = math.max(0, math.ceil(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60

    if hours > 0 then
        return ('%dh %02dm'):format(hours, minutes)
    end

    if minutes > 0 then
        return ('%dm %02ds'):format(minutes, secs)
    end

    return ('%ds'):format(secs)
end

local function interpolate(text, replacements)
    return tostring(text or ''):gsub('{([%w_]+)}', function(key)
        local replacement = replacements and replacements[key]
        return replacement ~= nil and tostring(replacement) or ('{' .. key .. '}')
    end)
end

local function notifyPlayer(playerId, messageKey, replacements)
    local configured = Config.Messages[messageKey]
    if not configured then return end

    local payload = {}
    for key, value in pairs(configured) do
        payload[key] = value
    end

    payload.title = interpolate(payload.title, replacements)
    payload.message = interpolate(payload.message or payload.description, replacements)

    local ok, err = pcall(function()
        exports['pk_library']:Notify(playerId, payload)
    end)

    if not ok then
        logError('Notifica pk_library fallita: %s', err)
    end
end

local function buildContainerIndex()
    for modelName, containerConfig in pairs(Config.Containers) do
        local modelHash = unsignedHash(joaat(modelName))
        local duration = clampInteger(containerConfig.searchDuration, 1000, 600000)
        local distance = math.max(0.5, math.min(20.0, tonumber(containerConfig.distance) or 2.0))
        local cooldown = clampInteger(containerConfig.cooldown or Config.DefaultCooldown, 1, 31536000)

        containersByHash[modelHash] = {
            name = modelName,
            hash = modelHash,
            duration = duration,
            distance = distance,
            cooldown = cooldown,
            nativeInteraction = containerConfig.nativeInteraction == true,
            animation = containerConfig.animation or {},
            loot = type(containerConfig.loot) == 'table' and containerConfig.loot or {},
            locations = type(containerConfig.locations) == 'table' and containerConfig.locations or {}
        }
    end
end

buildContainerIndex()

local function decodeMetadata(value)
    if type(value) == 'table' then return value end
    if type(value) ~= 'string' or value == '' then return {} end

    local ok, decoded = pcall(json.decode, value)
    return ok and type(decoded) == 'table' and decoded or {}
end

local function getItemDefinition(itemName)
    if itemDefinitions[itemName] then
        return itemDefinitions[itemName]
    end

    local rawDefinition = nil
    local exportOk = pcall(function()
        rawDefinition = exports.vorp_inventory:getItemDB(itemName)
    end)

    if not exportOk or type(rawDefinition) ~= 'table' then
        local queryOk, row = pcall(function()
            return MySQL.single.await(
                'SELECT item, label, `limit`, weight, metadata FROM items WHERE item = ? LIMIT 1',
                { itemName }
            )
        end)

        if queryOk then
            rawDefinition = row
        end
    end

    if type(rawDefinition) ~= 'table' then
        return nil
    end

    local metadata = decodeMetadata(rawDefinition.metadata)
    local definition = {
        name = tostring(rawDefinition.name or rawDefinition.item or itemName),
        label = tostring(rawDefinition.label or itemName),
        limit = tonumber(rawDefinition.limit) or -1,
        weight = tonumber(metadata.weight) or tonumber(rawDefinition.weight) or 0,
        metadata = metadata
    }

    itemDefinitions[itemName] = definition
    return definition
end

local function sanitizePendingLoot(rawLoot)
    if type(rawLoot) ~= 'table' then return nil end

    local maximum = clampInteger(Config.Security.MaxRewardAmount, 1, 100000)
    local aggregated = {}

    for _, reward in pairs(rawLoot) do
        if type(reward) == 'table' and type(reward.item) == 'string' then
            local amount = clampInteger(reward.amount, 0, maximum)
            if amount > 0 and getItemDefinition(reward.item) then
                aggregated[reward.item] = math.min(maximum, (aggregated[reward.item] or 0) + amount)
            end
        end
    end

    local sanitized = {}
    for itemName, amount in pairs(aggregated) do
        sanitized[#sanitized + 1] = { item = itemName, amount = amount }
    end

    table.sort(sanitized, function(first, second)
        return first.item < second.item
    end)

    return #sanitized > 0 and sanitized or nil
end

local function createDatabaseTable()
    MySQL.query.await(([=[
        CREATE TABLE IF NOT EXISTS `%s` (
            `container_id` VARCHAR(191) NOT NULL,
            `model` VARCHAR(64) NOT NULL,
            `x` DECIMAL(12,3) NOT NULL,
            `y` DECIMAL(12,3) NOT NULL,
            `z` DECIMAL(12,3) NOT NULL,
            `cooldown_until` BIGINT UNSIGNED NOT NULL DEFAULT 0,
            `pending_loot` LONGTEXT NULL,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`container_id`),
            KEY `idx_pk_wordloot_cooldown` (`cooldown_until`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]=]):format(TABLE_NAME))
end

local function deleteExpiredDatabaseRows(now)
    MySQL.update.await(
        ('DELETE FROM `%s` WHERE `cooldown_until` <= ? AND (`pending_loot` IS NULL OR `pending_loot` = \'\')'):format(TABLE_NAME),
        { now }
    )
end

local function loadContainerStates()
    local now = os.time()
    deleteExpiredDatabaseRows(now)

    local rows = MySQL.query.await(
        ('SELECT `container_id`, `model`, `x`, `y`, `z`, `cooldown_until`, `pending_loot` FROM `%s`'):format(TABLE_NAME)
    ) or {}

    for _, row in ipairs(rows) do
        local pendingLoot = nil
        local hadStoredPendingLoot = type(row.pending_loot) == 'string' and row.pending_loot ~= ''
        if hadStoredPendingLoot then
            local ok, decoded = pcall(json.decode, row.pending_loot)
            if ok then
                pendingLoot = sanitizePendingLoot(decoded)
            else
                logError('JSON loot non valido per %s: %s', tostring(row.container_id), tostring(decoded))
            end
        end

        if hadStoredPendingLoot and not pendingLoot then
            MySQL.update.await(
                ('UPDATE `%s` SET `pending_loot` = NULL WHERE `container_id` = ?'):format(TABLE_NAME),
                { row.container_id }
            )
        end

        local cooldownUntil = tonumber(row.cooldown_until) or 0
        if cooldownUntil > now or pendingLoot then
            containerStates[row.container_id] = {
                id = row.container_id,
                modelName = row.model,
                coords = {
                    x = tonumber(row.x) or 0.0,
                    y = tonumber(row.y) or 0.0,
                    z = tonumber(row.z) or 0.0
                },
                cooldownUntil = cooldownUntil,
                pendingLoot = pendingLoot
            }
        end
    end

    debugPrint('Caricati %d stati persistenti.', #rows)
end

local function persistPendingLoot(state, rewards)
    local encoded = json.encode(rewards)
    local ok, result = pcall(function()
        return MySQL.update.await(([[
            INSERT INTO `%s`
                (`container_id`, `model`, `x`, `y`, `z`, `cooldown_until`, `pending_loot`)
            VALUES (?, ?, ?, ?, ?, 0, ?)
            ON DUPLICATE KEY UPDATE
                `model` = VALUES(`model`),
                `x` = VALUES(`x`),
                `y` = VALUES(`y`),
                `z` = VALUES(`z`),
                `cooldown_until` = 0,
                `pending_loot` = VALUES(`pending_loot`)
        ]]):format(TABLE_NAME), {
            state.id,
            state.modelName,
            state.coords.x,
            state.coords.y,
            state.coords.z,
            encoded
        })
    end)

    if not ok then
        logError('Salvataggio loot pendente fallito per %s: %s', state.id, result)
        return false
    end

    state.cooldownUntil = 0
    state.pendingLoot = rewards
    containerStates[state.id] = state
    return true
end

local function persistCooldown(state, expiresAt)
    local ok, result = pcall(function()
        return MySQL.update.await(([[
            INSERT INTO `%s`
                (`container_id`, `model`, `x`, `y`, `z`, `cooldown_until`, `pending_loot`)
            VALUES (?, ?, ?, ?, ?, ?, NULL)
            ON DUPLICATE KEY UPDATE
                `model` = VALUES(`model`),
                `x` = VALUES(`x`),
                `y` = VALUES(`y`),
                `z` = VALUES(`z`),
                `cooldown_until` = VALUES(`cooldown_until`),
                `pending_loot` = NULL
        ]]):format(TABLE_NAME), {
            state.id,
            state.modelName,
            state.coords.x,
            state.coords.y,
            state.coords.z,
            expiresAt
        })
    end)

    if not ok then
        logError('Salvataggio cooldown fallito per %s: %s', state.id, result)
        return false
    end

    state.cooldownUntil = expiresAt
    state.pendingLoot = nil
    containerStates[state.id] = state
    return true
end

local function closestConfiguredLocation(container, coords)
    local closest = nil
    local closestDistance = nil

    for _, location in ipairs(container.locations) do
        if location and isFiniteNumber(location.x) and isFiniteNumber(location.y) and isFiniteNumber(location.z) then
            local candidate = { x = location.x, y = location.y, z = location.z }
            local distance = distanceBetween(coords, candidate)
            if not closestDistance or distance < closestDistance then
                closest = candidate
                closestDistance = distance
            end
        end
    end

    local tolerance = tonumber(Config.Security.ConfiguredLocationTolerance) or 1.0
    if closest and closestDistance <= tolerance then
        return closest
    end

    return nil
end

local function getPlayerCoords(playerId)
    local ped = GetPlayerPed(playerId)
    if not ped or ped <= 0 or not DoesEntityExist(ped) then return nil end

    local coords = GetEntityCoords(ped)
    if not coords or not isFiniteNumber(coords.x) or not isFiniteNumber(coords.y) or not isFiniteNumber(coords.z) then
        return nil
    end

    local clean = { x = coords.x, y = coords.y, z = coords.z }
    if math.abs(clean.x) + math.abs(clean.y) + math.abs(clean.z) <= 0.001 then return nil end
    return clean, ped
end

local function cleanClientCoords(rawCoords)
    if type(rawCoords) ~= 'table'
        or not isFiniteNumber(rawCoords.x)
        or not isFiniteNumber(rawCoords.y)
        or not isFiniteNumber(rawCoords.z)
    then
        return nil
    end

    local maximum = tonumber(Config.Security.MaxCoordinateAbsolute) or 10000.0
    if math.abs(rawCoords.x) > maximum
        or math.abs(rawCoords.y) > maximum
        or math.abs(rawCoords.z) > maximum
    then
        return nil
    end

    return { x = rawCoords.x + 0.0, y = rawCoords.y + 0.0, z = rawCoords.z + 0.0 }
end

local function isPlayerNearTarget(playerId, targetCoords, allowedDistance, rawClientCoords)
    local serverCoords = getPlayerCoords(playerId)
    local serverDistance = serverCoords and distanceBetween(serverCoords, targetCoords) or nil
    if serverDistance and serverDistance <= allowedDistance then return true end

    local clientCoords = cleanClientCoords(rawClientCoords)
    if not clientCoords or distanceBetween(clientCoords, targetCoords) > allowedDistance then
        return false
    end

    local tolerance = tonumber(Config.Security.ClientPositionTolerance) or 15.0
    if serverCoords and distanceBetween(serverCoords, clientCoords) > tolerance then
        return false
    end

    return true
end

local function resolveContainerRequest(playerId, request)
    if type(request) ~= 'table'
        or type(request.modelHash) ~= 'number'
        or type(request.coords) ~= 'table'
        or not isFiniteNumber(request.coords.x)
        or not isFiniteNumber(request.coords.y)
        or not isFiniteNumber(request.coords.z)
    then
        return nil
    end

    local modelHash = unsignedHash(request.modelHash)
    local container = containersByHash[modelHash]
    if not container then return nil end

    local coords = {
        x = request.coords.x,
        y = request.coords.y,
        z = request.coords.z
    }

    local networkId = math.floor(tonumber(request.networkId) or 0)
    if networkId < 0 or networkId > 65535 then return nil end

    if networkId > 0 then
        local entity = NetworkGetEntityFromNetworkId(networkId)
        if entity and entity > 0 and DoesEntityExist(entity) then
            if unsignedHash(GetEntityModel(entity)) ~= modelHash then return nil end

            local entityCoords = GetEntityCoords(entity)
            local verifiedCoords = { x = entityCoords.x, y = entityCoords.y, z = entityCoords.z }
            if distanceBetween(coords, verifiedCoords) > (tonumber(Config.Security.EntityPositionTolerance) or 0.75) then
                return nil
            end

            if GetEntityRoutingBucket(entity) ~= GetPlayerRoutingBucket(playerId) then
                return nil
            end

            coords = verifiedCoords
        else
            -- I prop statici della mappa possono avere un networkId solo lato
            -- client. In tal caso prosegui come prop statico e valida coordinate
            -- configurate (se richieste) e distanza giocatore.
            networkId = 0
        end
    end

    local configuredLocation = closestConfiguredLocation(container, coords)
    if Config.Security.RequireConfiguredLocations and not configuredLocation then
        return nil
    end

    if configuredLocation then
        coords = configuredLocation
    end

    coords = canonicalCoords(coords)

    local allowedDistance = container.distance + (tonumber(Config.Security.ServerDistanceTolerance) or 0.75)
    if not isPlayerNearTarget(playerId, coords, allowedDistance, request.playerCoords) then
        return nil
    end

    return {
        id = makeContainerId(container.name, coords),
        modelName = container.name,
        modelHash = container.hash,
        coords = coords,
        networkId = networkId,
        nativeInteraction = request.nativeInteraction == true and container.nativeInteraction == true,
        config = container
    }
end

local function validateActivePosition(session, clientCoords)
    local allowedDistance = session.container.config.distance
        + (tonumber(Config.Security.ServerDistanceTolerance) or 0.75)

    if not isPlayerNearTarget(session.playerId, session.container.coords, allowedDistance, clientCoords) then
        return false
    end

    if session.container.networkId > 0 then
        local entity = NetworkGetEntityFromNetworkId(session.container.networkId)
        if not entity or entity <= 0 or not DoesEntityExist(entity) then return false end
        if unsignedHash(GetEntityModel(entity)) ~= session.container.modelHash then return false end
        if GetEntityRoutingBucket(entity) ~= GetPlayerRoutingBucket(session.playerId) then return false end

        local entityCoords = GetEntityCoords(entity)
        local currentCoords = { x = entityCoords.x, y = entityCoords.y, z = entityCoords.z }
        if distanceBetween(currentCoords, session.container.coords)
            > (tonumber(Config.Security.EntityPositionTolerance) or 0.75)
        then
            return false
        end
    end

    return true
end

local function releaseSession(session)
    if not session then return end

    if sessionsByPlayer[session.playerId] == session then
        sessionsByPlayer[session.playerId] = nil
    end

    local lock = locksByContainer[session.container.id]
    if lock and lock.token == session.token then
        locksByContainer[session.container.id] = nil
    end

    TriggerClientEvent('pk_wordloot:client:sessionEnded', session.playerId, session.token)
end

local function rejectRequest(playerId, requestId, messageKey, replacements)
    TriggerClientEvent('pk_wordloot:client:requestRejected', playerId, requestId)
    notifyPlayer(playerId, messageKey, replacements)
end

local function rollLoot(container)
    local aggregated = {}
    local order = {}
    local maximum = clampInteger(Config.Security.MaxRewardAmount, 1, 100000)

    for _, entry in ipairs(container.loot) do
        if type(entry) == 'table' and type(entry.item) == 'string' and getItemDefinition(entry.item) then
            local chance = math.max(0.0, math.min(100.0, tonumber(entry.chance) or 0.0))
            local minimum = clampInteger(entry.min, 1, maximum)
            local maximumForEntry = clampInteger(entry.max, minimum, maximum)
            local passed = math.random(1, 1000000) <= math.floor(chance * 10000)

            if passed then
                local amount = math.random(minimum, maximumForEntry)
                if not aggregated[entry.item] then
                    aggregated[entry.item] = {
                        item = entry.item,
                        amount = 0,
                        configuredLabel = entry.label
                    }
                    order[#order + 1] = entry.item
                end

                aggregated[entry.item].amount = math.min(
                    maximum,
                    aggregated[entry.item].amount + amount
                )
            end
        end
    end

    local rewards = {}
    for _, itemName in ipairs(order) do
        rewards[#rewards + 1] = aggregated[itemName]
    end
    return rewards
end

local function canCarryAll(playerId, rewards)
    local user = Core.getUser(playerId)
    local character = user and user.getUsedCharacter
    if not character then return false end

    local okItems, inventoryItems = pcall(function()
        return exports.vorp_inventory:getUserInventoryItems(playerId)
    end)
    local okWeapons, inventoryWeapons = pcall(function()
        return exports.vorp_inventory:getUserInventoryWeapons(playerId)
    end)

    if not okItems or type(inventoryItems) ~= 'table' or not okWeapons or type(inventoryWeapons) ~= 'table' then
        return false
    end

    local usedWeight = 0.0
    local itemCounts = {}

    for _, item in pairs(inventoryItems) do
        local count = math.max(0, tonumber(item.count) or 0)
        local weight = math.max(0.0, tonumber(item.weight) or 0.0)
        usedWeight = usedWeight + (count * weight)

        if type(item.name) == 'string' then
            itemCounts[item.name] = (itemCounts[item.name] or 0) + count
        end
    end

    for _, weapon in pairs(inventoryWeapons) do
        usedWeight = usedWeight + math.max(0.0, tonumber(weapon.weight) or 0.0)
    end

    local rewardWeight = 0.0
    for _, reward in ipairs(rewards) do
        local definition = getItemDefinition(reward.item)
        if not definition then return false end

        local exportOk, canCarry = pcall(function()
            return exports.vorp_inventory:canCarryItem(playerId, reward.item, reward.amount)
        end)
        if not exportOk or canCarry ~= true then return false end

        if definition.limit ~= -1
            and ((itemCounts[reward.item] or 0) + reward.amount) > definition.limit
        then
            return false
        end

        rewardWeight = rewardWeight + (math.max(0.0, definition.weight) * reward.amount)
    end

    local capacity = tonumber(character.invCapacity)
    if not capacity then return false end
    if capacity ~= -1 and (usedWeight + rewardWeight) > (capacity + 0.0001) then
        return false
    end

    return true
end

local function addAllRewards(playerId, rewards)
    local added = {}

    for _, reward in ipairs(rewards) do
        local ok, result = pcall(function()
            return exports.vorp_inventory:addItem(playerId, reward.item, reward.amount, nil)
        end)

        if not ok or result ~= true then
            return false, added
        end

        added[#added + 1] = reward
    end

    return true, added
end

local function rollbackRewards(playerId, rewards)
    local allRolledBack = true

    for index = #rewards, 1, -1 do
        local reward = rewards[index]
        local definition = getItemDefinition(reward.item)
        local metadata = definition and definition.metadata or {}
        local ok, result = pcall(function()
            return exports.vorp_inventory:subItem(playerId, reward.item, reward.amount, metadata)
        end)

        if not ok or result ~= true then
            allRolledBack = false
            logError(
                'Rollback FALLITO: player=%s item=%s quantita=%s',
                playerId,
                reward.item,
                reward.amount
            )
        end
    end

    return allRolledBack
end

local function rewardSummary(rewards)
    local parts = {}

    for _, reward in ipairs(rewards) do
        local definition = getItemDefinition(reward.item)
        local label = reward.configuredLabel or (definition and definition.label) or reward.item
        parts[#parts + 1] = ('%dx %s'):format(reward.amount, label)
    end

    return table.concat(parts, ', ')
end

RegisterNetEvent('pk_wordloot:server:requestSearch', function(request)
    local playerId = source
    local requestId = type(request) == 'table' and tostring(request.requestId or '') or ''
    if #requestId > 96 then requestId = '' end

    if not databaseReady then
        rejectRequest(playerId, requestId, 'serviceUnavailable')
        return
    end

    local nowTimer = GetGameTimer()
    local previousRequest = lastRequestAt[playerId]
    local requestCooldown = clampInteger(Config.Security.RequestCooldownMs, 0, 10000)
    if previousRequest and elapsedMilliseconds(previousRequest) < requestCooldown then
        rejectRequest(playerId, requestId, 'containerBusy')
        return
    end
    lastRequestAt[playerId] = nowTimer

    if sessionsByPlayer[playerId] then
        rejectRequest(playerId, requestId, 'containerBusy')
        return
    end

    local container = resolveContainerRequest(playerId, request)
    if not container then
        rejectRequest(playerId, requestId, 'invalidContainer')
        return
    end

    local state = containerStates[container.id]
    local now = os.time()
    if state and state.cooldownUntil and state.cooldownUntil > now then
        rejectRequest(playerId, requestId, 'onCooldown', {
            time = formatRemaining(state.cooldownUntil - now)
        })
        return
    end

    local currentLock = locksByContainer[container.id]
    if currentLock and currentLock.deadline > now then
        rejectRequest(playerId, requestId, 'containerBusy')
        return
    end

    if currentLock then
        local staleSession = sessionsByPlayer[currentLock.playerId]
        if staleSession and staleSession.token == currentLock.token then
            releaseSession(staleSession)
        else
            locksByContainer[container.id] = nil
        end
    end

    tokenSequence = tokenSequence + 1
    local token = ('%s:%s:%s:%s'):format(playerId, GetGameTimer(), tokenSequence, math.random(100000, 999999))
    local timeout = clampInteger(Config.Security.SessionTimeoutSeconds, 5, 300)
    local requiredDuration = container.nativeInteraction and 0 or container.config.duration
    local session = {
        playerId = playerId,
        token = token,
        requestId = requestId,
        container = container,
        startedAt = GetGameTimer(),
        requiredDuration = requiredDuration,
        deadline = now + math.ceil(requiredDuration / 1000) + timeout,
        completing = false
    }

    sessionsByPlayer[playerId] = session
    locksByContainer[container.id] = {
        playerId = playerId,
        token = token,
        deadline = session.deadline
    }

    TriggerClientEvent('pk_wordloot:client:startSearch', playerId, {
        requestId = requestId,
        token = token,
        modelHash = container.modelHash,
        coords = container.coords,
        duration = requiredDuration,
        distance = container.config.distance,
        nativeInteraction = container.nativeInteraction,
        animation = container.config.animation,
        progressLabel = Config.ProgressLabel
    })
end)

RegisterNetEvent('pk_wordloot:server:cancelSearch', function(token)
    local playerId = source
    local session = sessionsByPlayer[playerId]
    if not session or type(token) ~= 'string' or #token > 128 or session.token ~= token then return end
    if session.completing then return end

    releaseSession(session)
    notifyPlayer(playerId, 'searchCancelled')
end)

RegisterNetEvent('pk_wordloot:server:completeSearch', function(token, clientCoords)
    local playerId = source
    local ok, errorMessage = xpcall(function()
        local session = sessionsByPlayer[playerId]
        if not session or type(token) ~= 'string' or #token > 128 or session.token ~= token then return end
        if session.completing then return end

        local grace = clampInteger(Config.Security.CompletionGraceMs, 0, 1000)
        if elapsedMilliseconds(session.startedAt) + grace < session.requiredDuration then
            TriggerClientEvent('pk_wordloot:client:forceCancel', playerId, session.token)
            releaseSession(session)
            notifyPlayer(playerId, 'searchCancelled')
            return
        end

        if os.time() > session.deadline or not validateActivePosition(session, clientCoords) then
            TriggerClientEvent('pk_wordloot:client:forceCancel', playerId, session.token)
            releaseSession(session)
            notifyPlayer(playerId, 'searchCancelled')
            return
        end

        session.completing = true

        local state = containerStates[session.container.id] or {
            id = session.container.id,
            modelName = session.container.modelName,
            coords = session.container.coords,
            cooldownUntil = 0,
            pendingLoot = nil
        }

        local now = os.time()
        if state.cooldownUntil and state.cooldownUntil > now then
            releaseSession(session)
            notifyPlayer(playerId, 'onCooldown', {
                time = formatRemaining(state.cooldownUntil - now)
            })
            return
        end

        local rewards = state.pendingLoot
        if not rewards then
            rewards = rollLoot(session.container.config)

            if #rewards > 0 and not persistPendingLoot(state, rewards) then
                releaseSession(session)
                notifyPlayer(playerId, 'serviceUnavailable')
                return
            end
        end

        if #rewards == 0 then
            local expiresAt = os.time() + session.container.config.cooldown
            if not persistCooldown(state, expiresAt) then
                releaseSession(session)
                notifyPlayer(playerId, 'serviceUnavailable')
                return
            end

            releaseSession(session)
            notifyPlayer(playerId, 'nothingFound')
            return
        end

        if not canCarryAll(playerId, rewards) then
            releaseSession(session)
            notifyPlayer(playerId, 'inventoryFull')
            return
        end

        local addedAll, addedRewards = addAllRewards(playerId, rewards)
        if not addedAll then
            rollbackRewards(playerId, addedRewards)
            releaseSession(session)
            notifyPlayer(playerId, 'inventoryFull')
            return
        end

        local expiresAt = os.time() + session.container.config.cooldown
        if not persistCooldown(state, expiresAt) then
            rollbackRewards(playerId, addedRewards)
            releaseSession(session)
            notifyPlayer(playerId, 'serviceUnavailable')
            return
        end

        releaseSession(session)
        notifyPlayer(playerId, 'lootReceived', {
            loot = rewardSummary(rewards)
        })
    end, debug.traceback)

    if not ok then
        logError('Errore durante il completamento per player %s: %s', playerId, errorMessage)

        local failedSession = sessionsByPlayer[playerId]
        if failedSession and failedSession.token == token then
            releaseSession(failedSession)
            notifyPlayer(playerId, 'serviceUnavailable')
        end
    end
end)

AddEventHandler('playerDropped', function()
    local playerId = source
    local session = sessionsByPlayer[playerId]
    if session then
        releaseSession(session)
    end
    lastRequestAt[playerId] = nil
end)

CreateThread(function()
    while true do
        Wait(1000)
        local now = os.time()
        local expired = {}

        for playerId, session in pairs(sessionsByPlayer) do
            if not session.completing and session.deadline <= now then
                expired[#expired + 1] = { playerId = playerId, session = session }
            end
        end

        for _, entry in ipairs(expired) do
            local session = entry.session
            TriggerClientEvent('pk_wordloot:client:forceCancel', entry.playerId, session.token)
            releaseSession(session)
            notifyPlayer(entry.playerId, 'searchCancelled')
        end
    end
end)

CreateThread(function()
    while true do
        local interval = math.max(60, tonumber(Config.Database.CleanupInterval) or 1800)
        Wait(interval * 1000)

        if databaseReady then
            local now = os.time()
            local ok, err = pcall(function()
                deleteExpiredDatabaseRows(now)
            end)

            if not ok then
                logError('Pulizia cooldown fallita: %s', err)
            end

            for containerId, state in pairs(containerStates) do
                if (not state.pendingLoot) and (tonumber(state.cooldownUntil) or 0) <= now then
                    containerStates[containerId] = nil
                end
            end
        end
    end
end)

MySQL.ready(function()
    local ok, err = pcall(function()
        if Config.Database.AutoCreateTable then
            createDatabaseTable()
        end

        loadContainerStates()

        for _, container in pairs(containersByHash) do
            for _, lootEntry in ipairs(container.loot) do
                if type(lootEntry) == 'table'
                    and type(lootEntry.item) == 'string'
                    and not getItemDefinition(lootEntry.item)
                then
                    logError(
                        'Item configurato inesistente in vorp_inventory: %s (modello %s)',
                        lootEntry.item,
                        container.name
                    )
                end
            end
        end
    end)

    if not ok then
        logError('Inizializzazione database fallita: %s', err)
        return
    end

    math.randomseed(os.time() + GetGameTimer())
    math.random()
    math.random()
    math.random()

    databaseReady = true
    print(('^2[%s] Avviato: cooldown persistenti e loot server-side pronti.^7'):format(RESOURCE_NAME))
end)
