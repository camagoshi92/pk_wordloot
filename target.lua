-- Ponte verso il sistema target scelto in Config.Target.System.
-- Ogni provider riceve la stessa opzione:
--   option.name        nome univoco dell'opzione (Config.Target.Name)
--   option.label       testo mostrato (Config.TargetLabel)
--   option.icon        icona (Config.Target.Icon), usata da ox_target
--   option.distance    distanza massima del modello
--   option.canInteract function(entity) -> boolean
--   option.onSelect    function() che avvia la ricerca
Target = {}

local providers = {}

providers['v-lib'] = {
    resource = 'v-lib',
    add = function(entity, option)
        exports['v-lib']:addLocalEntity(entity, {
            name = option.name,
            label = option.label,
            distance = option.distance,
            canInteract = option.canInteract,
            onSelect = option.onSelect
        })
    end,
    remove = function(entity, name)
        exports['v-lib']:removeLocalEntity(entity, name)
    end
}

providers['ox_target'] = {
    resource = 'ox_target',
    add = function(entity, option)
        exports.ox_target:addLocalEntity(entity, {
            {
                name = option.name,
                label = option.label,
                icon = option.icon,
                distance = option.distance,
                canInteract = option.canInteract,
                onSelect = option.onSelect
            }
        })
    end,
    remove = function(entity, name)
        exports.ox_target:removeLocalEntity(entity, name)
    end
}

-- Provider personalizzato: imposta Config.Target.System = 'custom' e completa
-- add/remove con le funzioni del tuo target. Se il target e una risorsa,
-- metti il suo nome in `resource`: i prop vengono registrati solo quando e avviata
-- e la registrazione riparte da zero se viene riavviata.
providers['custom'] = {
    resource = nil,
    add = function(entity, option)
        -- exports['mio_target']:addEntity(entity, {
        --     label = option.label,
        --     distance = option.distance,
        --     canInteract = option.canInteract,
        --     action = option.onSelect
        -- })
    end,
    remove = function(entity, name)
        -- exports['mio_target']:removeEntity(entity, name)
    end
}

local provider = providers[Config.Target.System]

if not provider then
    print(('[%s] Config.Target.System "%s" non valido: usa v-lib, ox_target oppure custom.')
        :format(GetCurrentResourceName(), tostring(Config.Target.System)))
end

function Target.Resource()
    return provider and provider.resource or nil
end

function Target.IsReady()
    if not provider then return false end
    if not provider.resource then return true end
    return GetResourceState(provider.resource) == 'started'
end

function Target.Add(entity, option)
    if not provider then return false, 'provider non configurato' end
    return pcall(provider.add, entity, option)
end

function Target.Remove(entity, name)
    if not provider or not Target.IsReady() then return end
    pcall(provider.remove, entity, name)
end
