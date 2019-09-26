--[[--
    Summary. A description
    @module hotpatch.core
    @author Chrisgbk
]]
--[[

Copyright 2018 Chrisgbk
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

]]
-- MIT License, https://opensource.org/licenses/MIT

-- Hotpatch-MultiMod: a tool to load multiple scenarios side-by-side, with support for both static loading and dynamic loading, as well as run-time patching

-- TODO: create a plugin system for internal plugins, instead of mixing with mods

log('Hotpatch runtime initializing...')
local util = require 'util'

local compat_mode = false -- enable some compatibility settings, which can help some mods load
local strict_mode = false -- causes hotpatch to hard-stop on mods doing bad things

local console = _ENV.console

-- mapping of events to names for logging
local event_names = {}
for k,v in pairs(defines.events) do
    event_names[v] = k
end

local custom_events = {}

_ENV.hotpatch_log = require('core-logging').log
local hotpatch_log = hotpatch_log

hotpatch_log({'hotpatch-info.logging-enabled'})

-- track _ENV accesses
setmetatable(_ENV, {
    __index = function(_, k)
        hotpatch_log({'hotpatch-trace.nil-var-access', k}, nil, 3)
        return nil
    end,
    __newindex = function(t, k, v)
        hotpatch_log({'hotpatch-trace.nil-var-assignment', k}, nil, 3)
        rawset(t,k,v)
    end,
    __metatable = false
})

hotpatch_log({'hotpatch-info.metatable-installed'})

-- this is for the core factorio libraries; hotpatch MUST load these now, as they cannot be dynamically loaded due to factorio limitation
local loaded_libraries = {}

-- load all possible libraries
hotpatch_log({'hotpatch-info.loading-libs'})

local libraries = {
    'camera',
    'flying_tags',
    'math3d',
    'mod-gui',
    'noise',
    'production-score',
    'silo-script',
    'story',
    'util',
}

for k, v in pairs(libraries) do
    hotpatch_log({'hotpatch-info.loading-library', v})
    loaded_libraries[k] = require(v)
end

hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.loading-libs'}})

-- these represent the mods as statically packaged with the scenario
local static_mods = {}
--[==[
    static_mods[i] = {}
    static_mods[i].name = ''
    static_mods[i].version = ''
    static_mods[i].code = ''
    static_mods[i].files = {}
--]==]

--[==[
-- installed mods are represented with:
--      global.mods = {}
--      global.mods[i] = {}
--      global.mods[i].name = ''
--      global.mods[i].version = ''
--      global.mods[i].code = ''
--      global.mods[i].files = {}
--      global.mods[i].global = {}
--]==]

-- loaded/running mods are represented with:
local generate_mod_obj = require 'core-mod_object'
local loaded_mods = {} -- this holds a reference to the mods internal object
--      loaded_mods[i] = mod_obj --see generate_mod_obj

-- mod installation/uninstallation support functions
-- These take a mod NAME as a first argument
local install_mod
local find_installed_mod
local install_mod_file
local uninstall_mod

-- mod interaction functions
-- These take a LOADED INDEX as a first argument, except load_mod, which takes an INSTALLED INDEX
local load_mod
local find_loaded_mod
local run_mod
local reset_mod
local reset_mod_events
local register_mod_events
local unload_mod

-- internal callbacks when a mod registers/removes events
local register_event
local register_nth_tick
local register_on_tick

-- mod bootstrap functions
-- These take a LOADED INDEX as a first argument
local mod_on_init
local mod_on_load
local mod_on_configuration_changed

-- local event handler to proxy to mods, these call the mods events
local on_event
local on_nth_tick

local register_all_events

-- core handlers
local on_init -- installs static mods, loads, runs, and calls mod_on_init
local on_load -- loads, runs, and calls mod_on_load
local on_configuration_changed -- calls mod_on_configuration_changed

-- this is dual-purpose, handles core needs and mod on_tick
local on_tick

-- this installs a new mod statically, only installed during on_init
-- Installed mod will still be updatable
local function static_mod(name, version, code, files)
    local mod = {}
    mod.name = name
    mod.version = version
    mod.code = code
    mod.files = {}
    if files then
        for k, v in pairs(files) do
            mod.files[k] = v
        end
    end
    table.insert(static_mods, mod)
end

find_installed_mod = function(mod_name)
    local mod
    local mods = global.mods
    for i = 1, #mods do
        mod = mods[i]
        if mod.name == mod_name then
            return i
        end
    end
    return nil
end

find_loaded_mod = function(mod_name)
    local mod
    for i = 1, #loaded_mods do
        mod = loaded_mods[i]
        if mod.name == mod_name then
            return i
        end
    end
    return nil
end

uninstall_mod = function(mod_name)
    local index = find_installed_mod(mod_name)
    if not index then
        -- TODO: notify that mod doesn't exist
        return
    end
    local loaded_index = find_loaded_mod(mod_name)

    if loaded_index then
        unload_mod(loaded_index)
    end


    hotpatch_log({'hotpatch-info.uninstalling', mod_name})

    table.remove(global.mods, index)
end

install_mod_file = function(mod_name, mod_file, mod_file_code)
    local index = find_installed_mod(mod_name)
    if not index then
        hotpatch_log({'hotpatch-error.not-installed'})
        return
    end
    local mod = global.mods[index]

    hotpatch_log({'hotpatch-info.installing-file', mod_file}, mod_name)

    mod_file = mod_file:gsub('/', '.')
    mod_file = mod_file:gsub('\\', '.')
    mod_file_code = mod_file_code:gsub('\t', '  ')
    mod.files[mod_file] = mod_file_code
end

install_mod = function(mod_name, mod_version, mod_code, mod_files)
    local index = find_installed_mod(mod_name)
    local mod = {}
    if index then
        -- TODO: notify about installing over top of existing mod
        mod = global.mods[index]
    else
        --next free index
        table.insert(global.mods, mod)
    end
    hotpatch_log({'hotpatch-info.installing', mod_version}, mod_name)
    if mod_code:find('--', 1, true) then

        hotpatch_log({'hotpatch-warning.contains-comments'}, mod_name)
        if not mod_code:find("\n", 1, true) then
            hotpatch_log({'hotpatch-warning.contains-comments-no-lf'}, mod_name)
        end
        hotpatch_log({'hotpatch-warning.contains-comments-console'}, mod_name)
    end

    mod_code = mod_code:gsub('\t', '  ')

    mod.name = mod_name
    mod.files = mod.files or {}
    mod.code = mod_code
    mod.version = mod_version
    mod.global = mod.global or {}

    if mod_files then
        for k,v in pairs(mod_files) do
            install_mod_file(mod_name, k, v)
        end
    end
end

load_mod = function(installed_index)
    local mod = global.mods[installed_index]
    local mod_name = mod.name
    if mod.code then
        local loaded_index = find_loaded_mod(mod_name)
        if loaded_index then
            --TODO notify that mod was already loaded
            unload_mod(loaded_index)
        end

        local mod_obj = generate_mod_obj(mod)
        local env = mod_obj.env

        --load/run code
        hotpatch_log({'hotpatch-info.loading'}, mod_name)

        local mod_code, message = load(mod.code, '[' .. mod_name .. '] control.lua', 'bt', env)
        if not mod_code then
            hotpatch_log({'hotpatch-error.compilation-failed'}, mod_name)
            if game and game.player then
                game.player.print(message)
            end
            hotpatch_log(message, mod_name)
            return false
        end

        mod_obj.code = mod_code
        mod_obj.loaded = true
        table.insert(loaded_mods, mod_obj)
        return true
    end
    return false
end

unload_mod = function(loaded_index)
    local mod = loaded_mods[loaded_index]
    if not mod then
        hotpatch_log('Invalid mod index: ' .. loaded_index);
        return
    end
    local mod_name = mod.name
    -- TODO
    -- stop mod running, unregister handlers from being called
    hotpatch_log({'hotpatch-info.unloading'}, mod_name)
    

    -- TODO:
    mod.loaded = false
    mod.running = false
    
    for k,v in pairs(mod.on_event) do
        mod.on_event[k] = nil
        register_event(mod_name, k)
    end
    for k,v in pairs(mod.on_nth_tick) do
        mod.on_nth_tick[k] = nil
        register_nth_tick(mod_name, k)
    end
    if mod.on_tick then
        mod.on_tick = nil
        register_on_tick(mod_name)
    end
    
    table.remove(loaded_mods, loaded_index)
end


--TODO: pretty much all of this routine
-- This should unregister events and clear the globals
reset_mod = function(loaded_index)
    local new_global = {}
    local mod = loaded_mods[loaded_index]
    mod.mod_env.global = new_global
    local install_index = find_installed_mod(mod.name)
    mod = global.mods[install_index]
    mod.global = new_global

    reset_mod_events(loaded_index)
end

reset_mod_events = function(loaded_index)
    --local loaded_index = find_loaded_mod(mod_name)
    local loaded_mod = loaded_mods[loaded_index]

    if not loaded_mod then
        --hotpatch_log({'hotpatch-warning.reset-events-not-running'}, mod_name)
    else
        loaded_mod.on_event = {}
        loaded_mod.on_nth_tick = {}
        loaded_mod.on_init = nil
        loaded_mod.on_load = nil
        loaded_mod.on_configuration_changed = nil
        loaded_mod.on_tick = nil
        register_all_events()
    end
end

local wrap_table
wrap_table = function(t, path)
    local mt = {
        __index = function(_, k)
        local v = rawget(t, k)
            if type(v) == 'table' then
                if not v.__self then
                    local p = (path or 'global') .. '[' .. tostring(k) .. ']'
                    return wrap_table(v, p)
                end
            end
            return v
        end,
        __newindex = function(_, k, v)
            local k_type = type(k)
            local wrap = ((k_type == 'string') and '"') or ''
            local p = (path or 'global') .. '[' .. wrap .. tostring(k) .. wrap .. ']'
            hotpatch_log('Assignment to global table when none was expected: '.. p, nil, 3)
            rawset(t, k, v)
        end
    }
    return setmetatable({}, mt)
end


run_mod = function(loaded_index)
    local mod = loaded_mods[loaded_index]
    if mod then
        local mod_name = mod.name
        local old_global =  mod.env.global
        mod.env.global = wrap_table(old_global)
        
        hotpatch_log({'hotpatch-info.running'}, mod_name)

        local success, result = xpcall(mod.code, debug.traceback)
        if not success then
            hotpatch_log({'hotpatch-error.execution-failed'}, mod_name)
            hotpatch_log(result, mod_name)
            --local caller = (game and game.player) or console
            if game and game.player then
                game.player.print(result)
            end

            return false
        end

        mod.env.global = old_global
        old_global = nil
        
        for k,v in pairs(mod.custom_events) do
            custom_events[k] = var-access
        end

        mod.running = true
        hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.running'}}, mod_name)

        --load complete, start notifying on event subscriptions
        if not compat_mode then
            mod.env.script.on_event = function(event, f)
                if event == defines.events.on_tick then
                    mod.on_tick = f
                    register_on_tick(mod_name)
                else
                    mod.on_event[event] = f
                    register_event(mod_name, event)
                end
            end
            mod.env.script.on_nth_tick = function(tick, f)
                if tick then
                    if type(tick) == 'table' then
                        for _, v in pairs(tick) do
                            mod.env.script.on_nth_tick(v, f)
                        end
                        return
                    end
                    mod.on_nth_tick[tick] = f
                    register_nth_tick(mod_name, tick)
                else
                    local mod_on_nth_tick = mod.on_nth_tick
                    mod.on_nth_tick = {}
                    for _, v in pairs(mod_on_nth_tick) do
                        register_nth_tick(mod_name, v)
                    end
                end
            end
        end
        return true
    end
    return false
end

-- Note: might be able to optimize this a bit
-- event handlers to call into mods requested event handlers
on_event = function(event)
    local event_name = (event_names[event.name] or event.name)
    local f
    hotpatch_log({'hotpatch-trace.event-processing', event_name})
    local mod
    for i = 1, #loaded_mods do
        mod = loaded_mods[i]
        f = mod.on_event[event.name]
        if f then
            hotpatch_log({'hotpatch-trace.event-running', event_name}, mod.name)
            f(event)
        end
    end
end

if hotpatch_log_on_tick then
    on_nth_tick = function(event)
        local tick = event.nth_tick
        local f
        hotpatch_log({'hotpatch-trace.nth-tick-event-processing', tick})
        local mod
        for i = 1, #loaded_mods do
            mod = loaded_mods[i]
            f = mod.on_nth_tick[event.nth_tick]
            if f then
                hotpatch_log({'hotpatch-trace.nth-tick-event-running', tick}, mod.name)
                f(event)
            end
        end
    end
else
    on_nth_tick = function(event)
        local tick = event.nth_tick
        local f
        local mod
        for i = 1, #loaded_mods do
            mod = loaded_mods[i]
            f = mod.on_nth_tick[event.nth_tick]
            if f then
                hotpatch_log({'hotpatch-trace.nth-tick-event-running', tick}, mod.name)
                f(event)
            end
        end
    end
end

register_all_events = function()
    --unregister all events
    script.on_event(defines.events, nil)
    script.on_nth_tick(nil, nil)
    --re-register all mod events
    for i = 1, #loaded_mods do
        register_mod_events(i)
    end
end

cull_mod_events = function(loaded_index)
    --
    local mod
    local found_events = {}
    
    --unregister all events
    script.on_event(defines.events, nil)
    script.on_nth_tick(nil, nil)
    
    for i = 1, #loaded_mods do
        mod = loaded_mods[i]
        for k,v in pairs(mod.on_nth_tick) do
            found_events[k] = true
        end
    end
    for k,_ in pairs(found_events) do
        --hotpatch_log({'hotpatch-trace.on-nth-tick-event-registered', k}, mod_name)
        -- TODO: keep track of what events are registered and say which were removed.
        script.on_nth_tick(k, on_nth_tick)
    end 
        
end

register_mod_events = function(loaded_index)

    local mod = loaded_mods[loaded_index]
    local mod_name = mod.name
    hotpatch_log({'hotpatch-trace.event-registering'}, mod_name)
    if mod.on_tick then
        hotpatch_log({'hotpatch-trace.on-tick-event-registered'}, mod_name)
        script.on_event(defines.events.on_tick, on_tick)
    end
    for k,_ in pairs(mod.on_event) do
        local event_name = (event_names[k] or k)
        hotpatch_log({'hotpatch-trace.on-event-registered', event_name}, mod_name)
        script.on_event(k, on_event)
    end
    for k,_ in pairs(mod.on_nth_tick) do
        hotpatch_log({'hotpatch-trace.on-nth-tick-event-registered', k}, mod_name)
        script.on_nth_tick(k, on_nth_tick)
    end
end

unregister_mod_events = function(loaded_index)

    local mod = loaded_mods[loaded_index]
    local mod_name = mod.name
    hotpatch_log({'hotpatch-trace.event-unregistering'}, mod_name)
    if mod.on_tick then
        hotpatch_log({'hotpatch-trace.on-tick-event-unregistered'}, mod_name)
        script.on_event(defines.events.on_tick, on_tick)
    end
    for k,_ in pairs(mod.on_event) do
        local event_name = (event_names[k] or k)
        hotpatch_log({'hotpatch-trace.on-event-unregistered', event_name}, mod_name)
        script.on_event(k, on_event)
    end
    for k,_ in pairs(mod.on_nth_tick) do
        hotpatch_log({'hotpatch-trace.on-nth-tick-event-unregistered', k}, mod_name)
        script.on_nth_tick(k, on_nth_tick)
    end
end

mod_on_init = function(loaded_index)
    local mod = loaded_mods[loaded_index]

    if mod then
        hotpatch_log({'hotpatch-trace.mod-on-init'}, mod.name)
        if mod.on_init then
            local success, result = xpcall(mod.on_init, debug.traceback)
            if not success then
                hotpatch_log({'hotpatch-error.on-init-failed'}, mod_name)
                hotpatch_log(result, mod_name)
                return false
            end
        end
        register_mod_events(loaded_index)
        return true
    end
    return false
end

mod_on_load = function(loaded_index)
    local mod = loaded_mods[loaded_index]

    if mod then
        hotpatch_log({'hotpatch-trace.mod-on-load'}, mod.name)
        if mod.on_load then
            local old_global =  mod.env.global
            mod.env.global = wrap_table(table.deepcopy(old_global))
            local success, result = xpcall(mod.on_load, debug.traceback)
            if not success then
                hotpatch_log({'hotpatch-error.on-load-failed'}, mod_name)
                hotpatch_log(result, mod_name)
                return false
            end
            mod.env.global = old_global

        end
        register_mod_events(loaded_index)
        return true
    end
    return false
end

mod_on_configuration_changed = function(loaded_index, config)
    local mod = loaded_mods[loaded_index]

    if mod then
        hotpatch_log({'hotpatch-trace.mod-on-configuration-changed'}, mod.name)
        if mod.on_configuration_changed then
            local success, result = xpcall(mod.on_configuration_changed, debug.traceback, config)
            if not success then
                hotpatch_log({'hotpatch-error.on-configuration-changed-failed'}, mod_name)
                hotpatch_log(result, mod_name)
                return false
            end
        end
        return true
    end
    return false
end

-- callbacks from mods to tell hotpatch when to enable handlers

register_on_tick = function(mod_name)
    local found_event
    --
    local mod
    for i = 1, #loaded_mods do
        mod = loaded_mods[i]
        local f = mod.on_tick
        if f then
            found_event = true
            break
        end
    end
    local index = find_loaded_mod(mod_name) or mod_name
    mod = loaded_mods[index] or mod_name
    if not mod then
        --error
        hotpatch_log('cannot find mod ' .. index .. ' ' .. 'mod_name')
        return
    end
    mod_name = mod.name
    if mod.on_tick then
        hotpatch_log({'hotpatch-trace.on-tick-event-registered'}, mod_name)
        found_event = true
    else
        hotpatch_log({'hotpatch-trace.on-tick-event-unregistered'}, mod_name)
    end
    if not found_event then
        hotpatch_log({'hotpatch-trace.on-tick-handler-added'})
    else
        if not mod.on_tick then
            hotpatch_log({'hotpatch-trace.on-tick-handler-removed'})
        end
    end
end

register_nth_tick = function(mod_name, nth_tick)
    local found_event
    --
    local mod
    for i = 1, #loaded_mods do
        mod = loaded_mods[i]
        local f = mod.on_nth_tick[nth_tick]
        if f then
            found_event = true
            break
        end
    end
    local index = find_loaded_mod(mod_name) or mod_name
    mod = loaded_mods[index] or mod_name
    if not mod then
        --error
        hotpatch_log('cannot find mod ' .. index .. ' ' .. 'mod_name')
        return
    end
    mod_name = mod.name
    if mod.on_nth_tick[nth_tick] then
        hotpatch_log({'hotpatch-trace.on-nth-tick-event-registered', nth_tick}, mod_name)
        found_event = true
    else
        hotpatch_log({'hotpatch-trace.on-nth-tick-event-unregistered', nth_tick}, mod_name)
    end
    if not found_event then
        hotpatch_log({'hotpatch-trace.nth-tick-handler-added', nth_tick})
        script.on_nth_tick(nth_tick, on_nth_tick)
    else
        if not mod.on_nth_tick[nth_tick] then
            hotpatch_log({'hotpatch-trace.nth-tick-handler-removed', nth_tick})
            script.on_nth_tick(nth_tick, nil)
        end
    end
end

register_event = function(mod_name, event_name)
    local found_event
    local mod
    for i = 1, #loaded_mods do
        mod = loaded_mods[i]
        local f = mod.on_event[event_name]
        if f then found_event = true break end
    end
    local index = find_loaded_mod(mod_name) or mod_name
    mod = loaded_mods[index] or mod_name
    if not mod then
        --error
        hotpatch_log('cannot find mod ' .. index .. ' ' .. mod_name)
        return
    end
    mod_name = mod.name
    if mod.on_event[event_name] then
        hotpatch_log({'hotpatch-trace.on-event-registered', (event_names[event_name] or event_name)}, mod_name)
    else
        hotpatch_log({'hotpatch-trace.on-event-unregistered', (event_names[event_name] or event_name)}, mod_name)
    end
    if not found_event then
        if script.get_event_handler(event_name) then
            -- handler already installed
            -- is this branch even possible to get to?
            return
        else
           hotpatch_log({'hotpatch-trace.on-event-handler-added', (event_names[event_name] or event_name)})
           script.on_event(event_name, on_event)
        end
    else
        if not mod.on_event[event_name] then
            hotpatch_log({'hotpatch-trace.on-event-handler-removed', (event_names[event_name] or event_name)})
            script.on_event(event_name, nil)
        end
    end
end

-- Core registration

on_init = function()
    -- Restore factorio locale handling
    hidden = load([===[
        return function(...) log(...) end
    ]===], '[HOTPATCH')
    hidden_log = hidden()
    
    hotpatch_log({'hotpatch-info.on-init'})
    --juuuuust in case
    global.mods = global.mods or {}

    hotpatch_log({'hotpatch-info.installing-included-mods'})
    local mod
    for i = 1, #static_mods do
        mod = static_mods[i]
        install_mod(mod.name, mod.version, mod.code, mod.files)
    end
    -- TODO: fix mod error loading behaviours
    for i = 1, #global.mods do
        load_mod(i)
    end

    for i = 1, #loaded_mods do
        run_mod(i)
        mod_on_init(i)
    end
    hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.installing-included-mods'}})
    hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.on-init'}})
end

on_load = function()
    hotpatch_log({'hotpatch-info.on-load'})
    hotpatch_log({'hotpatch-info.loading-installed-mods'})

    if global.globals then
        -- TODO: create an actual migration that works for this and remove this check
        error('Upgrading from Hotpatch 1.0.X to 1.1.0 is not currently supported!')
    end

    -- load installed mods
    for i = 1, #global.mods do
        load_mod(i)
    end

    -- run mods which loaded successfully
    local failed_mods = {}
    
    for i = 1, #loaded_mods do
        if run_mod(i) then
            if not mod_on_load(i) then
                table.insert(failed_mods, i)
            end
        else
            table.insert(failed_mods, i)
        end
    end   
    
    -- unload mods which failed to run
    for i = 1, #failed_mods do
        unload_mod(failed_mods[i])
    end

    hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.loading-installed-mods'}})
    hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.on-load'}})
    
    -- Workaround for factorio "bug" - factorio locale isn't available until on_load finishes running
    -- this should ideally be at the top of this event
    -- use our patched version for now
    hidden = load([===[
        return function(...) log(...) end
    ]===], '[HOTPATCH')
    hidden_log = hidden()
end

on_configuration_changed = function(config)
    hotpatch_log({'hotpatch-info.on-configuration-changed'})
    local failed_mods = {}
    for i = 1, #loaded_mods do
        if not mod_on_configuration_changed(i, config) then
            table.insert(failed_mods, i)
        end
    end

    for i = 1, #failed_mods do
        unload_mod(failed_mods[i])
    end
    hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.on-configuration-changed'}})
end

if hotpatch_log_on_tick then
    on_tick = function(e)
        hotpatch_log({'hotpatch-trace.event-processing', 'on_tick'})
        local mod
        local f
        for i = 1, #loaded_mods do
            mod = loaded_mods[i]
            f = mod.on_tick
            if f then
                hotpatch_log({'hotpatch-trace.event-running', 'on_tick'}, mod.name)
                f(e)
            end
        end
    end
else
    on_tick = function(e)
        local mod
        local f
        for i = 1, #loaded_mods do
            mod = loaded_mods[i]
            f = mod.on_tick
            if f then
                f(e)
            end
        end
    end
end


script.on_init(on_init)
script.on_load(on_load)
script.on_configuration_changed(on_configuration_changed)
script.on_event(defines.events.on_tick, on_tick)

--private API, don't use this
local mod_tools_internal = setmetatable({
    -- mod installation/uninstallation support functions
    -- These take a mod NAME as a first argument
    install_mod = install_mod,
    find_installed_mod = find_installed_mod,
    install_mod_file = install_mod_file,
    uninstall_mod = uninstall_mod,

    -- mod interaction functions
    -- These take a LOADED INDEX as a first argument, except load_mod, which takes an INSTALLED INDEX
    load_mod = load_mod,
    find_loaded_mod = find_loaded_mod,
    run_mod = run_mod,
    reset_mod = reset_mod,
    reset_mod_events = reset_mod_events,
    register_mod_events = register_mod_events,
    unload_mod = unload_mod,

    -- internal callbacks when a mod registers events
    register_event = register_event,
    register_nth_tick = register_nth_tick,
    register_on_tick = register_on_tick,

    -- mod bootstrap functions
    -- These take a LOADED INDEX as a first argument
    mod_on_init = mod_on_init,
    mod_on_load = mod_on_load,
    mod_on_configuration_changed = mod_on_configuration_changed,

    static_mods = static_mods,
    console = console,
    hotpatch_log = hotpatch_log,
    loaded_mods = loaded_mods,
    loaded_libraries = loaded_libraries,
    installed_mods = setmetatable({}, {
        __index = function(_, k)
            return global.mods[k]
        end,
        __newindex = function(_, __, ___)
        -- do nothing
        end,
        __len = function(_)
            return #global.mods
        end,
        __pairs = function(t) local function iter(_, k) local v; v = global.mods[k+1]; if v then return k+1, v end; end; return iter, t, 0 end,
        __ipairs = function(t) local function iter(_, k) local v; v = global.mods[k+1]; if v then return k+1, v end; end; return iter, t, 0 end,
        __metatable = false,
    })
},{
    __index = function(_, k)
        hotpatch_log({'hotpatch-error.invalid-API-access', k}, nil, 3)
    end,
    __newindex = function(_, __, ___)
        -- do nothing
    end,
    -- Don't let mods muck around
    __metatable = false,
})

--public API
local mod_tools = setmetatable({
    -- most code should use static_mod
    static_mod = static_mod, -- (name, version, code, files)
},{
    __index = mod_tools_internal,
    __newindex = function(_, __, ___)
        -- do nothing, read-only table
    end,
    -- Don't let mods muck around
    __metatable = false,
})

return mod_tools