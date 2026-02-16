fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Marley'
description 'Qbox Oil Rig - Fix repair access for owner + workers (canRepair)'
version '0.8.9'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua'
}

client_scripts { 'client.lua' }

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server.lua'
}

dependencies {
  'ox_lib',
  'ox_target',
  'oxmysql',
  'ox_inventory',
  'qbx_core',
  'p_banking'
}
