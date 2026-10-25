Config = {}

Config.Debug = false

-- Cooldown predefinito: 8 ore.
Config.DefaultCooldown = 28800

Config.TargetLabel = 'Cerca nel contenitore'
Config.ProgressLabel = 'Ricerca nel contenitore...'
Config.ProgressIcon = nil -- Nome PNG di pk_library, senza estensione. nil usa l'icona predefinita.

Config.cooldown =28800
Config.searchDuration = 2000
Config.Target = {
    -- Sistema target usato per i contenitori senza nativeInteraction:
    --   'v-lib'     -> exports['v-lib']:addLocalEntity
    --   'ox_target' -> exports.ox_target:addLocalEntity
    --   'custom'    -> completa il provider custom in target.lua
    System = 'v-lib',
    Icon = 'fas fa-box-open', -- usata da ox_target
    -- I prop caricati vicino al giocatore vengono collegati al target come entita locali.
    ScanInterval = 1250,
    ScanRadius = 15.0,
    CleanupPadding = 5.0,
    Name = 'pk_wordloot_search'
}

Config.NativeInteraction = {
    -- Evita che EVENT_CONTAINER_INTERACTION ed EVENT_OBJECT_INTERACTION
    -- assegnino due volte il loot per la stessa apertura.
    DebounceMs = 10000,
    ObjectInteractionFallback = true
}

Config.Database = {
    -- Se true, crea automaticamente la tabella presente anche in sql/install.sql.
    AutoCreateTable = true,
    CleanupInterval = 1800 -- secondi
}

Config.Security = {
    PositionPrecision = 2,
    MaxCoordinateAbsolute = 10000.0,
    ServerDistanceTolerance = 0.75,
    EntityPositionTolerance = 0.75,
    ConfiguredLocationTolerance = 1.0,
    ClientPositionTolerance = 15.0, -- Fallback per ritardi OneSync, verificato contro la posizione server.
    RequestCooldownMs = 750,
    CompletionGraceMs = 150,
    SessionTimeoutSeconds = 20,
    ClientRequestTimeoutMs = 10000,
    ClientCompletionTimeoutMs = 15000,
    MaxRewardAmount = 1000,

    -- I prop statici della mappa spesso non hanno un network ID e quindi il server
    -- non puo leggerne direttamente modello e coordinate. Attivando questa opzione,
    -- il server accetta esclusivamente le coordinate elencate in `locations` sotto
    -- ogni modello. E la modalita raccomandata per la massima protezione anti-cheat.
    RequireConfiguredLocations = false
}

Config.Messages = {
    lootReceived = {
        type = 'success',
        title = 'Contenitore',
        message = 'Hai trovato: {loot}.',
        duration = 5000
    },
    nothingFound = {
        type = 'info',
        title = 'Contenitore',
        message = 'Non hai trovato alcun oggetto.',
        duration = 4500
    },
    searchCancelled = {
        type = 'warning',
        title = 'Ricerca annullata',
        message = 'La ricerca e stata annullata.',
        duration = 4000
    },
    inventoryFull = {
        type = 'error',
        title = 'Inventario pieno',
        message = 'Non puoi contenere l’intera ricompensa. Libera spazio e riprova.',
        duration = 5000
    },
    containerBusy = {
        type = 'warning',
        title = 'Contenitore occupato',
        message = 'Un altro giocatore sta gia cercando in questo contenitore.',
        duration = 4000
    },
    onCooldown = {
        type = 'info',
        title = 'Contenitore gia cercato',
        message = 'Sara nuovamente disponibile tra {time}.',
        duration = 5000
    },
    invalidContainer = {
        type = 'error',
        title = 'Contenitore non valido',
        message = 'Questo contenitore non puo essere cercato.',
        duration = 4000
    },
    serviceUnavailable = {
        type = 'error',
        title = 'Servizio non disponibile',
        message = 'La ricerca non e disponibile in questo momento. Riprova tra poco.',
        duration = 5000
    },
    requestFailed = {
        type = 'error',
        title = 'Ricerca non avviata',
        message = 'Nessuna risposta dal server. Riprova.',
        duration = 4000
    }
}

-- Metodo di estrazione:
-- ogni riga di `loot` viene valutata separatamente. Per ogni voce riuscita viene
-- estratta una quantita casuale compresa tra min e max. Possono quindi uscire piu
-- oggetti, uno solo oppure nessuno. Anche un risultato vuoto attiva il cooldown.
--
-- Campi supportati per ogni modello:
--   loot, searchDuration (ms), animation, distance, cooldown (secondi), locations.
--   nativeInteraction = true usa il prompt e l'animazione RANSACK originali del gioco;
--   il loot viene assegnato quando arriva EVENT_CONTAINER_INTERACTION.
local function nativeContainer(distance, loot)
    return {
        nativeInteraction = true,
        distance = distance,
        loot = loot,
        locations = {
            -- vector3(x, y, z),
        }
    }
end

local function drawerContainer()
    return nativeContainer(2.0, {
            { item = 'foglio_fascicolo', label = 'Foglio Fascicolo', min = 1, max = 3, chance = 45.0 },
            { item = 'matches', label = 'Fiammiferi', min = 1, max = 2, chance = 35.0 },
            { item = 'sigarette', label = 'Sigarette', min = 1, max = 2, chance = 30.0 },
            { item = 'bandage', label = 'Benda', min = 1, max = 1, chance = 12.0 }
    })
end

local function chestContainer()
    return nativeContainer(2.2, {
        { item = 'foglio_fascicolo', label = 'Foglio Fascicolo', min = 1, max = 3, chance = 35.0 },
        { item = 'matches', label = 'Fiammiferi', min = 1, max = 2, chance = 25.0 },
        { item = 'sigari', label = 'Sigari', min = 1, max = 2, chance = 20.0 },
        { item = 'bandage', label = 'Benda', min = 1, max = 2, chance = 18.0 },
        { item = 'ammo_revolver', label = 'Munizioni revolver', min = 2, max = 5, chance = 10.0 }
    })
end

local function cabinetContainer()
    return nativeContainer(2.1, {
        { item = 'foglio_fascicolo', label = 'Foglio Fascicolo', min = 1, max = 2, chance = 40.0 },
        { item = 'matches', label = 'Fiammiferi', min = 1, max = 2, chance = 30.0 },
        { item = 'sigarette', label = 'Sigarette', min = 1, max = 2, chance = 25.0 },
        { item = 'bandage', label = 'Benda', min = 1, max = 1, chance = 20.0 }
    })
end

local function wardrobeContainer()
    return nativeContainer(2.2, {
        { item = 'fibra', label = 'Fibra', min = 1, max = 3, chance = 50.0 },
        { item = 'foglio_fascicolo', label = 'Foglio Fascicolo', min = 1, max = 2, chance = 30.0 },
        { item = 'sigarette', label = 'Sigarette', min = 1, max = 2, chance = 20.0 },
        { item = 'bandage', label = 'Benda', min = 1, max = 1, chance = 15.0 }
    })
end

Config.Containers = {
    ['p_cratecover01x'] = {
        distance = 2.0,
        animation = {
            dict = 'script_common@shared_scenarios@kneel@rummage@male_a@idle_a',
            clip = 'idle_a',
            flag = 1,
            blendIn = 4.0,
            blendOut = -4.0
        },
        loot = {
            { item = 'wood', label = 'Legno', min = 1, max = 3, chance = 65.0 },
            { item = 'iron_ore', label = 'Minerale di ferro', min = 1, max = 2, chance = 28.0 },
            { item = 'coal', label = 'Carbone', min = 1, max = 2, chance = 20.0 }
        },
        locations = {
            -- vector3(x, y, z),
        }
    },

    ['p_crate08x'] = {
        distance = 2.1,
        animation = {
            dict = 'script_common@shared_scenarios@kneel@rummage@male_a@idle_a',
            clip = 'idle_b',
            flag = 1,
            blendIn = 4.0,
            blendOut = -4.0
        },
        loot = {
            { item = 'wood', label = 'Legno', min = 2, max = 4, chance = 70.0 },
            { item = 'iron_ore', label = 'Minerale di ferro', min = 1, max = 3, chance = 35.0 },
            { item = 'coal', label = 'Carbone', min = 1, max = 3, chance = 25.0 }
        },
        locations = {
            -- vector3(x, y, z),
        }
    },

    ['p_rubblebag01x'] = {
        distance = 1.8,
        animation = {
            dict = 'script_common@shared_scenarios@kneel@rummage@male_a@idle_a',
            clip = 'idle_c',
            flag = 1,
            blendIn = 4.0,
            blendOut = -4.0
        },
        loot = {
            { item = 'coal', label = 'Carbone', min = 1, max = 4, chance = 55.0 },
            { item = 'iron_ore', label = 'Minerale di ferro', min = 1, max = 2, chance = 22.0 },
            { item = 'wood', label = 'Legno', min = 1, max = 2, chance = 18.0 }
        },
        locations = {
            -- vector3(x, y, z),
        }
    },

    ['p_crate03x'] = {
        distance = 2.0,
        animation = {
            dict = 'script_common@shared_scenarios@kneel@rummage@male_a@idle_a',
            clip = 'idle_a',
            flag = 1,
            blendIn = 4.0,
            blendOut = -4.0
        },
        loot = {
            { item = 'wood', label = 'Legno', min = 1, max = 4, chance = 68.0 },
            { item = 'iron_ore', label = 'Minerale di ferro', min = 1, max = 2, chance = 30.0 },
            { item = 'coal', label = 'Carbone', min = 1, max = 2, chance = 22.0 }
        },
        locations = {
            -- vector3(x, y, z),
        }
    },

    ['p_cratecover04x'] = {
        distance = 2.0,
        animation = {
            dict = 'script_common@shared_scenarios@kneel@rummage@male_a@idle_a',
            clip = 'idle_b',
            flag = 1,
            blendIn = 4.0,
            blendOut = -4.0
        },
        loot = {
            { item = 'wood', label = 'Legno', min = 1, max = 3, chance = 62.0 },
            { item = 'iron_ore', label = 'Minerale di ferro', min = 1, max = 3, chance = 32.0 },
            { item = 'coal', label = 'Carbone', min = 1, max = 3, chance = 24.0 }
        },
        locations = {
            -- vector3(x, y, z),
        }
    },

    ['p_cratestack01x'] = {
        distance = 2.3,
        animation = {
            dict = 'script_common@shared_scenarios@kneel@rummage@male_a@idle_a',
            clip = 'idle_a',
            flag = 1,
            blendIn = 4.0,
            blendOut = -4.0
        },
        loot = {
            { item = 'wood', label = 'Legno', min = 2, max = 5, chance = 75.0 },
            { item = 'iron_ore', label = 'Minerale di ferro', min = 1, max = 3, chance = 38.0 },
            { item = 'coal', label = 'Carbone', min = 1, max = 3, chance = 28.0 }
        },
        locations = {
            -- vector3(x, y, z),
        }
    },

    ['p_cratestack02x'] = {
        distance = 2.3,
        animation = {
            dict = 'script_common@shared_scenarios@kneel@rummage@male_a@idle_a',
            clip = 'idle_c',
            flag = 1,
            blendIn = 4.0,
            blendOut = -4.0
        },
        loot = {
            { item = 'wood', label = 'Legno', min = 2, max = 5, chance = 72.0 },
            { item = 'iron_ore', label = 'Minerale di ferro', min = 1, max = 4, chance = 40.0 },
            { item = 'coal', label = 'Carbone', min = 1, max = 4, chance = 30.0 }
        },
        locations = {
            -- vector3(x, y, z),
        }
    },

    -- Questi modelli espongono gli scenari RANSACK_ATTACHED_* usati dal prompt
    -- nativo "Fruga nel cassetto" / "Comodino".
    ['p_nbmnightstand03x'] = drawerContainer(),
    ['p_nightstand03x'] = drawerContainer(),
    ['p_nightstand04x'] = drawerContainer(),
    ['p_nightstandsix01'] = drawerContainer(),
    ['p_nightstandwinter03x'] = drawerContainer(),

    -- Cassetti e cassettiere che usano lo stesso evento nativo di apertura.
    ['p_drawer01x'] = drawerContainer(),
    ['p_drawer02x'] = drawerContainer(),
    ['p_drawer03x'] = drawerContainer(),
    ['p_dresserval01x'] = drawerContainer(),
    ['p_dresser01x'] = drawerContainer(),
    ['p_dresser02x'] = drawerContainer(),
    ['p_dresser03x'] = drawerContainer(),

    -- Bauli e cofanetti.
    ['p_chest02x'] = chestContainer(),
    ['p_coffer01x'] = chestContainer(),
    ['p_chest_lg_01'] = chestContainer(),
    ['p_chest_med_01'] = chestContainer(),
    ['p_chest_sm_01'] = chestContainer(),
    ['p_trunk01x'] = chestContainer(),
    ['p_trunk02x'] = chestContainer(),
    ['s_footlocker06x'] = chestContainer(),

    -- Armadietti.
    ['p_cabinet02x'] = cabinetContainer(),
    ['p_cabinet03x'] = cabinetContainer(),
    ['p_cabinet04x'] = cabinetContainer(),

    -- Guardaroba.
    ['p_wardrobe01x'] = wardrobeContainer()
}

local function addNativeModels(models, builder)
    for _, modelName in ipairs(models) do
        if not Config.Containers[modelName] then
            Config.Containers[modelName] = builder()
        end
    end
end

-- Varianti effettive collegate agli scenari RANSACK_ATTACHED del gioco.
addNativeModels({
    'p_dresser04x', 'p_dresser05x', 'p_dresser06x', 'p_dresser07x',
    'p_dresser08x', 'p_dresser09x', 'p_dresser10x', 'p_dresser11x',
    'p_dressercombo01x', 'p_commode01x', 'p_commodini01x',
    'p_endtable01x', 'p_sidetable01x', 'p_sidetable02x', 'p_sidetable03x',
    'p_sidetable07x', 'p_sidetable09x', 'p_sidetable11x', 'p_tablebedside02x'
}, drawerContainer)

addNativeModels({
    'p_chest01x', 'p_chest03x', 'p_chest_lrg', 'p_chest_med',
    'p_coffer02x', 'p_coffer02x_mp',
    'p_lockbox_lrg', 'p_lockbox_med', 'p_lockbox_sml',
    'p_footlocker01x', 'p_footlocker07x', 'p_footlockeranim01x',
    's_footlocker01x', 's_footlocker02x', 's_footlocker03x',
    's_footlocker04x', 's_footlocker05x', 's_footlockermud02x',
    's_footlockersnow03x',
    'p_trunk02x_b', 'p_trunk03x', 'p_trunk03x_b', 'p_trunk04x',
    'p_trunk05ax', 'p_trunk05x', 'p_trunk06ax', 'p_trunk06x',
    'p_trunkvar01x'
}, chestContainer)

addNativeModels({
    'p_abe_cabinet01', 'p_adl_cabinet01x', 'p_cartcabinet01x',
    'p_cabinet01x', 'p_cabinet05x', 'p_cabinet06x', 'p_cabinet07x',
    'p_cabinet08x', 'p_cabinet09x', 'p_cabinet11x', 'p_cabinet13x',
    'p_cabinet15x', 'p_cabinetchina01x', 'p_cabinetchina03x',
    'p_cabinetchina04x', 'p_chinacabinet01x', 'p_cabinetdoctor01x',
    'p_cabinetdoctor02x', 'p_cabinetpostal01x', 'p_cornercabinet01x',
    'p_cornercabinet02x', 'p_cupboard01x', 'p_cupboard02bx',
    'p_cupboard02x', 'p_cupboard03x', 'p_cupboard04x', 'p_cupboard05x',
    'p_cupboard06x', 'p_cupboard07x', 'p_cupboardcorner01x',
    'p_cupboardfac01x', 'p_drmedcabinet01x', 'p_filecabinetdoctor01x',
    'p_guncabinet02x', 'p_hutch01x', 'p_hutch02x', 'p_hutch03x',
    'p_hutch04x', 'p_hutchwhite01x', 'p_nbmchinacabinet01x',
    'p_nbmchinacabinet02x', 'p_sterilecabinet01x'
}, cabinetContainer)

addNativeModels({
    'p_armoir02x', 'p_armoir03x', 'p_armoir04x', 'p_armoir05x',
    'p_armoir06x', 'p_armoir07bx', 'p_armoir07x', 'p_armoir08x',
    'p_armoireregal01', 'p_armoiroffice66x'
}, wardrobeContainer)

-- Scrivanie, scrittoi e banchi con cassetti RANSACK_ATTACHED.
addNativeModels({
    'p_bw_desk01x', 'p_desk01x', 'p_desk03x', 'p_desk04x',
    'p_desk07x', 'p_desk08x', 'p_desk09bx', 'p_desk09x',
    'p_desk10x', 'p_desk13x', 'p_desk14x', 'p_desk15x',
    'p_desk17x', 'p_desk18x', 'p_drdesk01x',
    'p_fandesk01x', 'p_fandesk02x', 'p_fandesk_off01x',
    'p_latchdesk01x', 'p_nbx_bank_desk02', 'p_trolleymaildesk_01x',
    'p_workbenchdesk01x', 'p_writingdesk01x', 's_desk01x'
}, cabinetContainer)
