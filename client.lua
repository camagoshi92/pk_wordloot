local RESOURCE_NAME = GetCurrentResourceName()
local Game = Import 'events'

local containersByHash = {}
local registeredEntities = {}
local nativeInteractionDebounce = {}
local awaitingRequest = nil
local activeSearch = nil
local requestSequence = 0
local hasNativeInteractionContainers = false

local function debugPrint(message, ...)
    if not Config.Debug then return end
    print(('[%s] %s'):format(RESOURCE_NAME, message:format(...)))
end

local function unsignedHash(value)
    value = tonumber(value) or 0
    if value < 0 then
        value = value + 4294967296
    end
    return value
end

for modelName, containerConfig in pairs(Config.Containers) do
    local modelHash = unsignedHash(GetHashKey(modelName))
    containersByHash[modelHash] = {
        name = modelName,
        hash = modelHash,
        config = containerConfig
    }

    if containerConfig.nativeInteraction == true then
        hasNativeInteractionContainers = true
    end
end

local function notifyLocal(messageKey)
    local configured = Config.Messages[messageKey]
    if not configured then return end

    local payload = {}
    for key, value in pairs(configured) do
        payload[key] = value
    end

    pcall(function()
        exports['pk_library']:Notify(payload)
    end)
end

local function getContainerFromEntity(entity)
    if type(entity) ~= 'number' or entity <= 0 or not DoesEntityExist(entity) then
        return nil
    end

    return containersByHash[unsignedHash(GetEntityModel(entity))]
end

local function matchesConfiguredLocation(container, entity)
    if not Config.Security.RequireConfiguredLocations then return true end
    if not container or not DoesEntityExist(entity) then return false end

    local locations = container.config.locations
    if type(locations) ~= 'table' or #locations == 0 then return false end

    local entityCoords = GetEntityCoords(entity)
    local tolerance = tonumber(Config.Security.ConfiguredLocationTolerance) or 1.0

    for _, location in ipairs(locations) do
        if location
            and type(location.x) == 'number'
            and type(location.y) == 'number'
            and type(location.z) == 'number'
            and #(entityCoords - vector3(location.x, location.y, location.z)) <= tolerance
        then
            return true
        end
    end

    return false
end

local function isNearEntity(entity, maxDistance)
    if not DoesEntityExist(entity) then return false end

    local playerCoords = GetEntityCoords(PlayerPedId())
    local entityCoords = GetEntityCoords(entity)
    return #(playerCoords - entityCoords) <= maxDistance
end

local function getPlayerCoordsPayload()
    local ped = PlayerPedId()
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end

    local coords = GetEntityCoords(ped)
    return { x = coords.x, y = coords.y, z = coords.z }
end

local function nextRequestId()
    requestSequence = requestSequence + 1
    return ('%s:%s'):format(GetGameTimer(), requestSequence)
end

local function requestSearch(entity, nativeInteraction)
    if awaitingRequest or activeSearch then return end

    local container = getContainerFromEntity(entity)
    if not container or not matchesConfiguredLocation(container, entity) then
        notifyLocal('invalidContainer')
        return
    end

    local distance = tonumber(container.config.distance) or 2.0
    if not isNearEntity(entity, distance + 0.15) then return end

    local entityCoords = GetEntityCoords(entity)
    local networkId = 0

    if NetworkGetEntityIsNetworked(entity) then
        networkId = NetworkGetNetworkIdFromEntity(entity)
    end

    local requestId = nextRequestId()
    awaitingRequest = {
        id = requestId,
        entity = entity,
        modelHash = container.hash,
        nativeInteraction = nativeInteraction == true
    }

    TriggerServerEvent('pk_wordloot:server:requestSearch', {
        requestId = requestId,
        modelHash = container.hash,
        networkId = networkId,
        nativeInteraction = nativeInteraction == true,
        coords = {
            x = entityCoords.x,
            y = entityCoords.y,
            z = entityCoords.z
        },
        playerCoords = getPlayerCoordsPayload()
    })

    CreateThread(function()
        Wait(tonumber(Config.Security.ClientRequestTimeoutMs) or 10000)

        if awaitingRequest and awaitingRequest.id == requestId then
            awaitingRequest = nil
            notifyLocal('requestFailed')
        end
    end)
end

if hasNativeInteractionContainers then
    local function handleNativeContainer(entity, eventName)
        if entity <= 0 or not DoesEntityExist(entity) then return end

        local modelHash = unsignedHash(GetEntityModel(entity))
        local container = containersByHash[modelHash]
        if not container or container.config.nativeInteraction ~= true then
            debugPrint('%s ignorato: modello non configurato %s, entity %s', eventName, modelHash, entity)
            return
        end

        local now = GetGameTimer()
        local previous = nativeInteractionDebounce[entity]
        local debounceMs = math.max(1000, tonumber(Config.NativeInteraction.DebounceMs) or 10000)
        if previous and now >= previous and (now - previous) < debounceMs then return end

        nativeInteractionDebounce[entity] = now
        debugPrint('%s riconosciuto: modello %s (%s)', eventName, container.name, modelHash)
        requestSearch(entity, true)
    end

    Game.Events:Register('EVENT_CONTAINER_INTERACTION', 0, function(data)
        if type(data) ~= 'table' then return end

        local initiator = tonumber(data[1]) or 0
        local entity = tonumber(data[2]) or 0
        local isContainerClosed = data[4] == true or tonumber(data[4]) == 1

        -- Il loot scatta solo quando il giocatore locale ha appena aperto/frugato
        -- il contenitore, non quando lo richiude.
        if initiator ~= PlayerPedId() or entity <= 0 or isContainerClosed then return end
        handleNativeContainer(entity, 'EVENT_CONTAINER_INTERACTION')
    end, true)

    if Config.NativeInteraction.ObjectInteractionFallback ~= false then
        Game.Events:Register('EVENT_OBJECT_INTERACTION', 0, function(data)
            if type(data) ~= 'table' then return end

            local initiator = tonumber(data[1]) or 0
            local entity = tonumber(data[2]) or 0
            local interactionState = tonumber(data[6]) or -1

            -- Nella struttura dell'evento il valore 1 indica il completamento.
            if initiator ~= PlayerPedId() or entity <= 0 or interactionState ~= 1 then return end
            handleNativeContainer(entity, 'EVENT_OBJECT_INTERACTION')
        end, true)
    end
end

local function loadAnimation(dictionary, timeoutMs)
    if type(dictionary) ~= 'string' or dictionary == '' then return false end

    RequestAnimDict(dictionary)
    local deadline = GetGameTimer() + timeoutMs

    while not HasAnimDictLoaded(dictionary) do
        if GetGameTimer() >= deadline then
            return false
        end
        Wait(25)
    end

    return true
end

local function clearSearchAnimation(animation)
    local ped = PlayerPedId()
    ClearPedTasks(ped)

    if animation and animation.dict then
        RemoveAnimDict(animation.dict)
    end
end

local function runSearch(session, entity)
    local ped = PlayerPedId()
    local animation = session.animation or {}
    local targetCoords = vector3(session.coords.x, session.coords.y, session.coords.z)

    TaskTurnPedToFaceCoord(ped, targetCoords.x, targetCoords.y, targetCoords.z, 350)
    Wait(350)

    if not activeSearch or activeSearch.token ~= session.token then return end

    if not loadAnimation(animation.dict, 5000) then
        TriggerServerEvent('pk_wordloot:server:cancelSearch', session.token)
        activeSearch = nil
        return
    end

    TaskPlayAnim(
        ped,
        animation.dict,
        animation.clip,
        tonumber(animation.blendIn) or 4.0,
        tonumber(animation.blendOut) or -4.0,
        -1,
        tonumber(animation.flag) or 1,
        0.0,
        false,
        false,
        false
    )

    activeSearch.phase = 'progress'

    CreateThread(function()
        while activeSearch and activeSearch.token == session.token and activeSearch.phase == 'progress' do
            Wait(250)

            local currentPed = PlayerPedId()
            local invalid = IsEntityDead(currentPed)
                or not DoesEntityExist(entity)
                or unsignedHash(GetEntityModel(entity)) ~= session.modelHash
                or #(GetEntityCoords(currentPed) - targetCoords) > (session.distance + 0.5)

            if invalid then
                activeSearch.clientCancelled = true
                pcall(function()
                    exports['pk_library']:CancelProgress()
                end)
                break
            end
        end
    end)

    local progressData = {
        label = session.progressLabel or Config.ProgressLabel,
        duration = session.duration
    }

    if Config.ProgressIcon then
        progressData.icon = Config.ProgressIcon
    end

    local ok, completed = pcall(function()
        return exports['pk_library']:Progress(progressData)
    end)

    clearSearchAnimation(animation)

    if not activeSearch or activeSearch.token ~= session.token then return end

    if not ok or completed ~= true or activeSearch.serverCancelled or activeSearch.clientCancelled then
        local token = activeSearch.token
        activeSearch = nil
        TriggerServerEvent('pk_wordloot:server:cancelSearch', token)
        return
    end

    activeSearch.phase = 'completing'
    TriggerServerEvent('pk_wordloot:server:completeSearch', session.token, getPlayerCoordsPayload())

    CreateThread(function()
        Wait(tonumber(Config.Security.ClientCompletionTimeoutMs) or 15000)

        if activeSearch and activeSearch.token == session.token and activeSearch.phase == 'completing' then
            activeSearch = nil
            notifyLocal('requestFailed')
        end
    end)
end

RegisterNetEvent('pk_wordloot:client:requestRejected', function(requestId)
    if awaitingRequest and awaitingRequest.id == requestId then
        awaitingRequest = nil
    end
end)

RegisterNetEvent('pk_wordloot:client:startSearch', function(session)
    if type(session) ~= 'table' or type(session.token) ~= 'string' then return end

    local request = awaitingRequest
    if not request or request.id ~= session.requestId then
        TriggerServerEvent('pk_wordloot:server:cancelSearch', session.token)
        return
    end

    awaitingRequest = nil

    local entity = request.entity
    local container = getContainerFromEntity(entity)
    if activeSearch
        or not container
        or container.hash ~= unsignedHash(session.modelHash)
        or not isNearEntity(entity, (tonumber(session.distance) or 2.0) + 0.25)
    then
        TriggerServerEvent('pk_wordloot:server:cancelSearch', session.token)
        return
    end

    activeSearch = {
        token = session.token,
        entity = entity,
        phase = 'starting'
    }

    if session.nativeInteraction == true then
        activeSearch.phase = 'completing'
        TriggerServerEvent('pk_wordloot:server:completeSearch', session.token, getPlayerCoordsPayload())

        CreateThread(function()
            Wait(tonumber(Config.Security.ClientCompletionTimeoutMs) or 15000)

            if activeSearch and activeSearch.token == session.token and activeSearch.phase == 'completing' then
                activeSearch = nil
                notifyLocal('requestFailed')
            end
        end)
        return
    end

    CreateThread(function()
        runSearch(session, entity)
    end)
end)

RegisterNetEvent('pk_wordloot:client:forceCancel', function(token)
    if not activeSearch or activeSearch.token ~= token then return end

    activeSearch.serverCancelled = true
    pcall(function()
        exports['pk_library']:CancelProgress()
    end)
end)

RegisterNetEvent('pk_wordloot:client:sessionEnded', function(token)
    if activeSearch and activeSearch.token == token then
        activeSearch = nil
    end
end)

local function removeEntityTarget(entity)
    Target.Remove(entity, Config.Target.Name)
    registeredEntities[entity] = nil
end

local function addEntityTarget(entity, container)
    local ok, err = Target.Add(entity, {
        name = Config.Target.Name,
        label = Config.TargetLabel,
        icon = Config.Target.Icon,
        distance = tonumber(container.config.distance) or 2.0,
        canInteract = function(targetEntity)
            if awaitingRequest or activeSearch then return false end
            if targetEntity ~= entity then return false end

            local current = getContainerFromEntity(targetEntity)
            if not current or not matchesConfiguredLocation(current, targetEntity) then return false end

            return isNearEntity(targetEntity, tonumber(current.config.distance) or 2.0)
        end,
        onSelect = function()
            -- Questo handler appartiene esclusivamente a `entity`: non usare
            -- un handle proveniente da un'altra voce vicina del target UI.
            requestSearch(entity)
        end
    })

    if ok then
        registeredEntities[entity] = container.hash
    else
        debugPrint('Impossibile registrare entity %s su %s: %s', entity, tostring(Config.Target.System), err)
    end
end

CreateThread(function()
    Wait(1000)

    while true do
        local interval = math.max(250, tonumber(Config.Target.ScanInterval) or 1250)
        Wait(interval)

        if Target.IsReady() then
            local playerCoords = GetEntityCoords(PlayerPedId())
            local scanRadius = math.max(3.0, tonumber(Config.Target.ScanRadius) or 15.0)
            local cleanupRadius = scanRadius + math.max(1.0, tonumber(Config.Target.CleanupPadding) or 5.0)
            local seen = {}

            for _, entity in ipairs(GetGamePool('CObject')) do
                if DoesEntityExist(entity) then
                    local container = getContainerFromEntity(entity)
                    if container
                        and container.config.nativeInteraction ~= true
                        and matchesConfiguredLocation(container, entity)
                    then
                        local distance = #(playerCoords - GetEntityCoords(entity))
                        if distance <= scanRadius then
                            seen[entity] = true

                            if registeredEntities[entity] ~= container.hash then
                                if registeredEntities[entity] then
                                    removeEntityTarget(entity)
                                end
                                addEntityTarget(entity, container)
                            end
                        end
                    end
                end
            end

            local stale = {}
            for entity, modelHash in pairs(registeredEntities) do
                local exists = DoesEntityExist(entity)
                local validModel = exists and unsignedHash(GetEntityModel(entity)) == modelHash
                local closeEnough = exists and #(playerCoords - GetEntityCoords(entity)) <= cleanupRadius

                if not seen[entity] and (not validModel or not closeEnough) then
                    stale[#stale + 1] = entity
                end
            end

            for _, entity in ipairs(stale) do
                removeEntityTarget(entity)
            end
        end
    end
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName == Target.Resource() then
        registeredEntities = {}
    end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName == Target.Resource() then
        registeredEntities = {}
        return
    end

    if resourceName ~= RESOURCE_NAME then return end

    if activeSearch then
        pcall(function()
            exports['pk_library']:CancelProgress()
        end)
        ClearPedTasks(PlayerPedId())
    end

    local entities = {}
    for entity in pairs(registeredEntities) do
        entities[#entities + 1] = entity
    end

    for _, entity in ipairs(entities) do
        removeEntityTarget(entity)
    end
end)
