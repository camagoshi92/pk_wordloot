fx_version 'cerulean'
game 'rdr3'

rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

lua54 'yes'

author 'Poker Studio'
description 'Loot persistente dai contenitori del mondo per VORP'
version '1.1.0'

shared_scripts {
    '@vorp_lib/import.lua',
    'config.lua'
}

client_scripts {
    'target.lua',
    'client.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua'
}

dependencies {
    '/onesync',
    'oxmysql',
    'vorp_core',
    'vorp_inventory',
    'vorp_lib',
    'pk_library'
}
