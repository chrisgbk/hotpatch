-- This is the Factorio Freeplay scenario
-- This code, and the freeplay locale files in the zip file, is the property of Wube
-- As this is part of the base mod, the developers have given permission for modders to use/adapt the assets therein, for modding Factorio
-- Any other use would require licensing/permission from Wube

local hotpatch_tools = require 'hotpatch.core'

hotpatch_tools.static_mod('freeplay', '0.17.71', [===[
local handler = require("event_handler")
handler.add_lib(require("freeplay"))
handler.add_lib(require("silo-script"))

]===],
{
['freeplay'] = [===[
local util = require("util")

local created_items = function()
  return
  {
    ["iron-plate"] = 8,
    ["wood"] = 1,
    ["pistol"] = 1,
    ["firearm-magazine"] = 10,
    ["burner-mining-drill"] = 1,
    ["stone-furnace"] = 1
  }
end

local respawn_items = function()
  return
  {
    ["pistol"] = 1,
    ["firearm-magazine"] = 10
  }
end

local on_player_created = function(event)
  local player = game.players[event.player_index]
  util.insert_safe(player, global.created_items)

  local r = global.chart_distance or 200
  player.force.chart(player.surface, {{player.position.x - r, player.position.y - r}, {player.position.x + r, player.position.y + r}})

  if not global.skip_intro then
    if game.is_multiplayer() then
      player.print({"msg-intro"})
    else
      game.show_message_dialog{text = {"msg-intro"}}
    end
  end
end

local on_player_respawned = function(event)
  local player = game.players[event.player_index]
  util.insert_safe(player, global.respawn_items)
end

local freeplay = {}

freeplay.events =
{
  [defines.events.on_player_created] = on_player_created,
  [defines.events.on_player_respawned] = on_player_respawned,
}

freeplay.on_configuration_changed = function(event)
  global.created_items = global.created_items or created_items()
  global.respawn_items = global.respawn_items or respawn_items()
end

freeplay.on_init = function()
  global.created_items = created_items()
  global.respawn_items = respawn_items()
end

freeplay.add_remote_interface = function()
  remote.add_interface("freeplay",
  {
    get_created_items = function()
      return global.created_items
    end,
    set_created_items = function(map)
      global.created_items = map or error("Remote call parameter to freeplay set created items can't be nil.")
    end,
    get_respawn_items = function()
      return global.respawn_items
    end,
    set_respawn_items = function(map)
      global.respawn_items = map or error("Remote call parameter to freeplay set respawn items can't be nil.")
    end,
    set_skip_intro = function(bool)
      global.skip_intro = bool
    end,
    set_chart_distance = function(value)
      global.chart_distance = tonumber(value) or error("Remote call parameter to freeplay set chart distance must be a number")
    end
  })
end

return freeplay

]===],
['event_handler'] = [===[

local libraries = {}

local setup_ran = false

local register_events = function()

  --Sometimes, in special cases, on_init and on_load can be run at the same time. Only register events once in this case.
  if setup_ran then return end
  setup_ran = true

  local all_events = {}
  local on_nth_tick = {}

  for lib_name, lib in pairs (libraries) do

    if lib.events then
      for k, handler in pairs (lib.events) do
        all_events[k] = all_events[k] or {}
        all_events[k][lib_name] = handler
      end
    end

    if lib.on_nth_tick then
      for n, handler in pairs (lib.on_nth_tick) do
        on_nth_tick[n] = on_nth_tick[n] or {}
        on_nth_tick[n][lib_name] = handler
      end
    end

    if lib.add_remote_interface then
      lib.add_remote_interface()
    end

    if lib.add_commands then
      lib.add_commands()
    end

  end

  for event, handlers in pairs (all_events) do
    local action = function(event)
      for k, handler in pairs (handlers) do
        handler(event)
      end
    end
    script.on_event(event, action)
  end

  for n, handlers in pairs (on_nth_tick) do
    local action = function(event)
      for k, handler in pairs (handlers) do
        handler(event)
      end
    end
    script.on_nth_tick(n, action)
  end

end

script.on_init(function()
  register_events()
  for k, lib in pairs (libraries) do
    if lib.on_init then
      lib.on_init()
    end
  end
end)

script.on_load(function()
  register_events()
  for k, lib in pairs (libraries) do
    if lib.on_load then
      lib.on_load()
    end
  end
end)

script.on_configuration_changed(function(data)
  for k, lib in pairs (libraries) do
    if lib.on_configuration_changed then
      lib.on_configuration_changed(data)
    end
  end
end)

local handler = {}

handler.add_lib = function(lib)
  for k, current in pairs (libraries) do
    if current == lib then
      error("Trying to register same lib twice")
    end
  end
  table.insert(libraries, lib)
end

handler.add_libraries = function(libs)
  for k, lib in pairs (libs) do
    handler.add_lib(lib)
  end
end

return handler
]===]

})