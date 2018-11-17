--[[

Copyright 2018 Chrisgbk
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

]]
-- MIT License, https://opensource.org/licenses/MIT

local debug_mode = true
local compat_mode = false
local strict_mode = false

-- these represent the mods as packaged with the scenario
local initial_name = {}
local initial_version = {}
local initial_code = {}
local initial_files = {}

local function new_mod(name, version, code, files)
    local i = #initial_code + 1
    initial_name[i] = name
    initial_version[i] = version
    initial_code[i] = code
    initial_files[i] = {}
    if files then
        for k, v in pairs(files) do
            initial_files[i][k] = v
        end
    end
end

-- This is where the fun begins

local function debug_log(what)
    if debug_mode then 
        log(what)
    end
end

local event_names = {}
for k,v in pairs(defines.events) do
    event_names[v] = k
end

-- load all possible libraries
local loaded_libraries = {
    camera = require 'camera',
    flying_tags = require 'flying_tags',
    inspect = require 'inspect',
    math3d = require 'math3d',
    ['mod-gui'] = require 'mod-gui',
    noise = require 'noise',
    ['production-score'] = require 'production-score',
    ['silo-script'] = require 'silo-script',
    story = require 'story',
    util = require 'util',
}

-- loaded mods, these are always dynamically loaded, not saved to global
-- this holds a reference to the mods script object
local loaded_mods = {}
-- this holds a reference to the mods environment
local mod_env = {}

-- internal notification event
local internal_notify = script.generate_event_name()

-- TODO: use array part instead of hash part of tables for performance reasons

local function install_mod(mod_name, mod_version, mod_code, mod_files)
    debug_log('[HOTPATCH] installing mod: ' .. mod_name .. ' ' .. mod_version)
    global.mod_files[mod_name] = global.mod_files[mod_name] or {}
    global.mod_code[mod_name] = mod_code
    global.mod_version[mod_name] = mod_version
    -- mods private global table
    global.globals[mod_name] = global.globals[mod_name] or {}
    
    if mod_files then
        for k,v in pairs(mod_files) do
            debug_log('[HOTPATCH] installing mod file: ' .. k .. ' (' .. mod_name .. ')')
            local path = k
            path = path:gsub('/', '.')
            path = path:gsub('\\', '.')
            global.mod_files[mod_name][path] = v
        end
    end
end

--TODO: multiple mod support
--TODO: pretty much all of this routine, which is unused currently
-- This should unregister events and clear the globals
local function mod_reset(mod_name)
    local mod_global = global.globals[mod_name]
    for k, v in pairs(mod_global) do
        mod_global[k] = nil
    end
    mod_reset_events(mod_name)
end

local function mod_reset_events(mod_name)
    --TODO: deregister global event handlers that aren't needed anymore
    local mod_script = loaded_mods[mod_name]
    if mod_script then 
        mod_script.__events = {}
        mod_script.__ticks = {}
        mod_script.__on_init = nil
        mod_script.__on_load = nil
        mod_script.__on_configuration_changed = nil
    end
end

-- TODO: handle mod load failure cases
local function run_mod(mod_name)
    if global.mod_code[mod_name] then
        -- TODO: integrity check, verify each mods global table to detect guaranteed desync mods
        
        --de-register event handlers first
        mod_reset_events(mod_name)
        --unload currently loaded version, if any
        loaded_mods[mod_name] = nil
        
        --mods private script table/shim
        local mod_script = {}
        mod_script.__loaded_files = {}
        mod_script.__events = {}
        mod_script.__ticks = {}
        mod_script.__mod_name = mod_name
        mod_script.__notify = internal_notify

        mod_script.on_init = function(f)
            mod_script.__on_init = f
        end
        mod_script.on_load = function(f)
            mod_script.__on_load = f
        end
        mod_script.on_configuration_changed = function(f)
            mod_script.__on_configuration_changed = f
        end
        if not compat_mode then
            mod_script.on_event = function(event, f)
                debug_log('[HOTPATCH] caching event: ' .. event_names[event] .. ' (' .. mod_name .. ')')
                mod_script.__events[event] = f
            end
            mod_script.on_nth_tick = function(tick, f)
                debug_log('[HOTPATCH] caching nth_tick event: ' .. tick .. ' (' .. mod_name .. ')')
                mod_script.__ticks[tick] = f
            end
        else   
            mod_script.on_event = function(event, f)
                mod_script.__events[event] = f
                if mod_script.__loaded then
                    script.raise_event(mod_script.__notify, {mod=mod_name, event=event})
                end
            end
            mod_script.on_nth_tick = function(tick, f)
                mod_script.__ticks[tick] = f
                if mod_script.__loaded then
                    script.raise_event(mod_script.__notify, {mod=mod_name, event='on_nth_tick', nth_tick=tick})
                end
            end
        end
        mod_script.generate_event_name = function()
            return script.generate_event_name()
        end
        mod_script.get_event_handler = function(event)
            return mod_script.__events[event]
        end
        mod_script.raise_event = function(event, table)
            script.raise_event(event, table)
        end
        --TODO: replace these with mod-provided versions, so multi-mod aware softmods can easily detect other loaded softmods
        mod_script.get_event_order = function()
            return script.get_event_order()
        end
        mod_script.mod_name = function()
            return script.mod_name()
        end
        
        -- mods private env
        local env = {}
        env.script = mod_script
        env.global = global.globals[mod_name]
        env._G = env
        -- TODO: implement this in tandem with require
        env['package'] = package
        
        env.require = function(path)
            -- I blame Nexela for this
            path = path:gsub('/', '.')
            path = path:gsub('\\', '.')
            if mod_script.__base then
                path = mod_script.__base .. path
            end
            if mod_script.__loaded_files[path] then
                return mod_script.__loaded_files[path]
            else
                local oldbase = mod_script.__base
                mod_script.__base = path:match('.+%..+%.')
                if not mod_script.__base then
                     mod_script.__base = path:match('.+%.')
                end
                local file = global.mod_files[mod_name][path]
                if file then
                    debug_log('[HOTPATCH] loading require\'d file: ' .. path)
                    mod_script.__loaded_files[path] = load(global.mod_files[mod_name][path], 'hotpatch require ' .. path .. ' (' .. mod_name .. ')', 'bt', env)
                    mod_script.__loaded_files[path]()
                    mod_script.__base = oldbase
                    return mod_script.__loaded_files[path]
                end
                debug_log('[HOTPATCH] loading from Factorio.data.core.lualib: ' .. path)
                return package.loaded[path]
            end
        end
        
        env['assert'] = assert
        env['collectgarbage'] = collectgarbage
        env['error'] = error
        env['getmetatable'] = getmetatable
        env['ipairs'] = ipairs
        env['load'] = load
        env['loadstring'] = loadstring
        env['next'] = next
        env['pairs'] = pairs
        env['pcall'] = pcall
        env['print'] = print
        env['rawequal'] = rawequal
        env['rawlen'] = rawlen
        env['rawget'] = rawget
        env['rawset'] = rawset
        env['select'] = select
        env['setmetatable'] = setmetatable
        env['tonumber'] = tonumber
        env['tostring'] = tostring
        env['type'] = type
        env['xpcall'] = xpcall
        env['_VERSION'] = _VERSION
        env['module'] = module
        env['unpack'] = unpack
        env['table'] = table
        env['string'] = string
        env['bit32'] = bit32
        env['math'] = math
        env['debug'] = debug
        env['serpent'] = serpent
        env['log'] = log
        env['table_size'] = table_size
        env['remote'] = remote
        env['commands'] = commands
        env['settings'] = settings
        env['rcon'] = rcon
        env['defines'] = defines
        env['mod_gui'] = mod_gui
        env['util'] = util
        env['migrate_from_scenario'] = migrate_from_scenario
        env['migrate'] = migrate
        env['gui_update'] = gui_update
        env['update_players'] = update_players
        env['toggle_frame'] = toggle_frame
        env['migrations'] = migrations
        env['get_sprite_button'] = get_sprite_button
        env['get_tracked_items'] = get_tracked_items
        env['silo_script'] = silo_script
        env['game'] = game
        
        local mt = {}
        mt.__index = function(t, k)
            debug_log('[HOTPATCH] info: _ENV nil variable access: '  .. k .. ' (' .. mod_name .. ')')
            return nil
        end
        mt.__newindex = function(t, k, v)
            debug_log('[HOTPATCH] info: _ENV variable assignment: '  .. k .. ' (' .. mod_name .. ')')
            rawset(t,k,v)
        end
        -- Don't let mods break this
        mt.__metatable = {}
        setmetatable(env, mt)

        --load/run code
        debug_log('[HOTPATCH] loading mod: ' .. mod_name)
        local mod_code = load(global.mod_code[mod_name], 'hotpatch loader (' .. mod_name .. ')', 'bt', env)
        mod_env[mod_name] = env
        
        if strict_mode then
           env.global = {}
        end
        debug_log('[HOTPATCH] running mod: ' .. mod_name)
        mod_code()
        if compat_mode then
            mod_script.__loaded = true
        end
        if strict_mode then
            if env.global ~= {} then
                --TODO: error, mod touched global inappropriately during load
            end
           env.global = global.globals[mod_name]
        end
        loaded_mods[mod_name] = mod_script
        debug_log('[HOTPATCH] finished running mod: ' .. mod_name)
        
        --load complete, start notifying on event subscriptions
        if not compat_mode then
            mod_script.on_event = function(event, f)
                mod_script.__events[event] = f
                debug_log('[HOTPATCH] registering event: ' .. event_names[event])
                script.raise_event(mod_script.__notify, {mod=mod_script.__mod_name, event=event})
            end
            mod_script.on_nth_tick = function(tick, f)
                mod_script.__ticks[tick] = f
                debug_log('[HOTPATCH] registering nth_tick event: ' .. tick)
                script.raise_event(mod_script.__notify, {mod=script.__mod_name, event='on_nth_tick', nth_tick=tick})
            end
        end
    end
end

-- Note: might be able to optimize this a bit
-- event handlers to call into mods requested event handlers
local on_event = function(event)
    debug_log('[HOTPATCH] processing event: ' .. event_names[event.name])
    for k, v in pairs(loaded_mods) do
        local f = v.__events[event.name]
        if f then 
            debug_log('[HOTPATCH] running event: ' .. event_names[event.name] .. ' (' .. k .. ')')
            f(event)
        end
    end
end

local on_nth_tick = function(event)
    debug_log('[HOTPATCH] processing nth_tick: ' .. event.tick)
    for k, v in pairs(loaded_mods) do
        local f = v.__ticks[event.nth_tick]
        if f then 
            debug_log('[HOTPATCH] processing nth_tick: ' .. event.tick .. ' (' .. k .. ')')
            f(event)
        end
    end
end

local function mod_register_events(mod_name)
    local mod = loaded_mods[mod_name]
    debug_log('[HOTPATCH] registering events: ' .. mod_name)
    for k,v in pairs(mod.__events) do 
        debug_log('[HOTPATCH] registered event: ' .. event_names[k] .. ' (' .. mod_name .. ')')
        script.on_event(k, on_event)
    end
    for k,v in pairs(mod.__ticks) do 
        debug_log('[HOTPATCH] registered nth_tick event: ' .. k .. ' (' .. mod_name .. ')')
        script.on_nth_tick(k, on_nth_tick)
    end
end

local function mod_init(mod_name)
    debug_log('[HOTPATCH] running on_init: ' .. mod_name)
    local mod = loaded_mods[mod_name]
    if mod then
        if mod.__on_init then 
            mod.__on_init()
        end
        mod_register_events(mod_name)
    end
end

local function mod_load(mod_name)
    debug_log('[HOTPATCH] running on_load: ' .. mod_name)
    local mod = loaded_mods[mod_name]
    if mod then
        if mod.__on_load then 
            mod.__on_load()
        end
        mod_register_events(mod_name)
    end
end

local function mod_configuration_changed(mod_name, config)
    debug_log('[HOTPATCH] running on_configuration_changed: ' .. mod_name)
    local mod = loaded_mods[mod_name]
    if mod then
        if mod.__on_configuration_changed then 
            mod.__on_configuration_changed(config)
        end
    end
end

local function on_init()
    debug_log('[HOTPATCH] initializing...')
    global.mod_code = global.mod_code or {} --juuuuust in case
    global.mod_version = global.mod_version or {} --ditto
    global.globals = global.globals or {} --double ditto
    global.mod_files = global.mod_files or {} --triple ditto
    debug_log('[HOTPATCH] installing and loading included mods...')
    for k, v in pairs(initial_code) do
        local n = initial_name[k]
        install_mod(n, initial_version[k], v, initial_files[k])
        run_mod(n)
        mod_init(n)
    end
    debug_log('[HOTPATCH] installing and loading included mods... Complete!')
    debug_log('[HOTPATCH] initializing... Complete!')
end

local function on_load()
    debug_log('[HOTPATCH] loading...')
    debug_log('[HOTPATCH] loading included mods...')
    for k, v in pairs(global.mod_code) do
        run_mod(k)
        mod_load(k)
    end
    debug_log('[HOTPATCH] loading included mods... Complete!')
    debug_log('[HOTPATCH] loading... Complete!')
end

local function on_configuration_changed(config)
    debug_log('[HOTPATCH] configuration change...')
    for k, v in pairs(loaded_mods) do
        mod_configuration_changed(k)
    end
    debug_log('[HOTPATCH] configuration change... Complete!')
end

-- internal event subscription notification from mods
-- technically this wastes some cycles by continuously re-subscribing over and over, might fix one day
local function on_internal_notify(event)
    if event.name == 'on_nth_tick' then
        debug_log('[HOTPATCH] adding nth_tick: ' .. event.tick .. ' (' .. event.mod .. ')')
        script.on_nth_tick(event.nth_tick, on_nth_tick)
    else
        debug_log('[HOTPATCH] adding event: ' .. event_names[event.name] .. ' (' .. event.mod .. ')')
        script.on_event(event.event, on_event)
    end
end

script.on_init(on_init)
script.on_load(on_load)
script.on_configuration_changed(on_configuration_changed)
script.on_event(internal_notify, on_internal_notify)

-- mod update tools, WIP
-- these support multiple mods, as soon as the underlying code supports it

local remote_interface = {}

--IMPORTANT: WHEN COPY PASTING CODE TO CONSOLE THE CODE MUST HAVE SINGLE LINE COMMENTS REMOVED
-- FACTORIO CONSOLE STRIPS LINEFEEDS WHICH MAKES ALL THE CODE BECOME COMMENTED OUT
--TODO: gate these behind admin permissions; if (game.player and game.player.admin) should work for console commands?

remote_interface['install'] = function(mod_name, mod_version, mod_code, mod_files)
    -- this installs a new mod and runs on_init, then registers events
    -- Note that mods may expect that certain events haven't been called yet when their on_init is ran
    -- This may prevent them from functioning properly, without manually calling the events they expect
    -- examples: on_player_created
    local caller = game.player or _ENV
    if (caller == _ENV) or caller.admin then
        if global.mod_code[mod_name] then
            rcon.print('Error: mod already installed')
            caller.print('Error: mod already installed')
            return
        end
        install_mod(mod_name, mod_version, mod_code, mod_files)
        run_mod(mod_name)
        mod_init(mod_name)
    end
end

remote_interface['update'] = function(mod_name, mod_version, mod_code, mod_files)
    -- this updates an existing mod
    -- the current mods events are de-registered, the new code is installed, on_load is triggered, and then events are registered
    -- finally, the mod is informed of the update, so it can run migrations from the previous version
    -- TODO: validation
    local caller = game.player or _ENV
    if (caller == _ENV) or caller.admin then
        local old_version = global.mod_version[mod_name]
        mod_reset_events(mod_name)
        install_mod(mod_name, mod_version, mod_code, mod_files)
        run_mod(mod_name)
        mod_load(mod_name)

        -- The mod must do any migrations here
        -- TODO: notify all mods
        mod_configuration_changed(mod_name, {mod_changes = {mod_name={old_version=old_version, new_version=mod_version}}})
    end
end

--TODO: most of this function
remote_interface['clean'] = function(mod_name)
    -- Removes ALL mod data and reinitializes
    -- if the mod isnt designed for this, it will fail
    -- because it doesn't remove things like surfaces, etc
    local caller = game.player or _ENV
    if (caller == _ENV) or caller.admin then
        mod_reset(mod_name)
        run_mod(mod_name)
        mod_init(mod_name)
    end
end

remote.add_interface('hotpatch', remote_interface)

--[[

remote.call('hotpatch, 'install', 'test', '1.0.0', [===[ 
script.on_event(defines.events.on_player_changed_position, function(e) 
    game.print('changed position') 
end
]===]

local updated_code = ....
remote.call('hotpatch', 'update', 'test', '1.0.1', updated_code)


]]


return {
    new_mod = new_mod
}