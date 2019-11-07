--[[--
Hotpatch Core for Hotpatch-MultiMod: a tool to load multiple scenarios side-by-side,
with support for both static loading and dynamic loading, as well as run-time patching.
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

local core_logging = require('core-logging')
_ENV.hotpatch_log = core_logging.log
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

local libraries = _ENV.hotpatch_libraries

local handler = require("event_handler")
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
--        global.mods = {}
--        global.mods[i] = {}
--        global.mods[i].name = ''
--        global.mods[i].version = ''
--        global.mods[i].code = ''
--        global.mods[i].files = {}
--        global.mods[i].global = {}
--]==]

-- loaded/running mods are represented with:
local generate_mod_obj = require 'core-mod_object'
local loaded_mods = {} -- this holds a reference to the mods internal object

--        loaded_mods[i] = mod_obj --see generate_mod_obj

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
local unregister_mod_events
local unload_mod

-- internal callbacks when a mod registers/removes events
local register_event
local register_nth_tick
local register_on_tick
local unregister_event
local unregister_nth_tick
local unregister_on_tick

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
    local mod_obj
    for i = 1, #loaded_mods do
        mod_obj = loaded_mods[i]
        if mod_obj.name == mod_name then
            return i
        end
    end
    return nil
end

uninstall_mod = function(mod_name)
    local index = find_installed_mod(mod_name)
    if not index then
        hotpatch_log('attempt to uninstall mod that isn\'t installed: ' .. mod_name)
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


    mod_file = mod_file:gsub('\\', '/')
    hotpatch_log({'hotpatch-info.installing-file', mod_file}, mod_name)
    mod_file = mod_file:gsub('/', '.')

    mod_file_code = mod_file_code:gsub('\t', '  ')
    mod.files[mod_file] = mod_file_code
end

install_mod = function(mod_name, mod_version, mod_code, mod_files)
    local index = find_installed_mod(mod_name)
    local mod = {}
    if index then
        hotpatch_log('attempt to install mod that is already installed, reinstalling: ' .. mod_name)
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
            hotpatch_log('attempt to load mod that is already loaded: ' .. mod_name)
            unload_mod(loaded_index)
        end

        hotpatch_log({'hotpatch-info.loading'}, mod_name)

        local mod_obj = generate_mod_obj(mod)
        local env = mod_obj._ENV

        --load/run code

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
        hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.loading'}}, mod_name)
        return true
    end
    return false
end

unload_mod = function(loaded_index)
    local mod_obj = loaded_mods[loaded_index]
    if not mod_obj then
        hotpatch_log({'hotpatch-info.invalid-index', loaded_index});
        return
    end
    local mod_name = mod_obj.name
    hotpatch_log({'hotpatch-info.unloading'}, mod_name)

    mod_obj.loaded = false
    mod_obj.running = false

    for k,v in pairs(mod_obj.on_event) do
        mod_obj.on_event[k] = nil
        unregister_event(mod_name, k)
    end
    for k,v in pairs(mod_obj.on_nth_tick) do
        mod_obj.on_nth_tick[k] = nil
        unregister_nth_tick(mod_name, k)
    end
    if mod_obj.on_tick then
        mod_obj.on_tick = nil
        unregister_on_tick(mod_name)
    end
    for k,v in pairs(mod_obj.commands) do
        commands.remove_command(k)
        hotpatch_log({'hotpatch-info.removed-command', k})
    end    
    for k,v in pairs(mod_obj.interfaces) do
        remote.remove_interface(k)
        hotpatch_log({'hotpatch-info.removed-interface', k})
    end

    table.remove(loaded_mods, loaded_index)
end


--TODO: pretty much all of this routine
-- This should unregister events and clear the globals
-- might refactor to remove?
reset_mod = function(loaded_index)
    local new_global = {}
    local mod_obj = loaded_mods[loaded_index]
    mod_obj.mod_env.global = new_global
    local install_index = find_installed_mod(mod_obj.name)
    local mod = global.mods[install_index]
    mod.global = new_global

    reset_mod_events(loaded_index)
end

reset_mod_events = function(loaded_index)
    --local loaded_index = find_loaded_mod(mod_name)
    local mod_obj = loaded_mods[loaded_index]

    if not mod_obj then
        --hotpatch_log({'hotpatch-warning.reset-events-not-running'}, mod_name)
    else
        mod_obj.on_event = {}
        mod_obj.on_nth_tick = {}
        mod_obj.on_init = nil
        mod_obj.on_load = nil
        mod_obj.on_configuration_changed = nil
        mod_obj.on_tick = nil
        register_all_events()
    end
end

local wrap_table
wrap_table = function(t, path)
    local mt = {    
        __wrapped = true,
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
            hotpatch_log({'hotpatch-info.global-unsafe', p}, nil, 3)
            rawset(t, k, v)
        end
    }
    return setmetatable({}, mt)
end


run_mod = function(loaded_index, init)
    local mod_obj = loaded_mods[loaded_index]
    if mod_obj then
        local mod_name = mod_obj.name
        local old_global =    mod_obj._ENV.global
        if init then
                --mod_obj._ENV.global = wrap_table(old_global)
        else
                --ignore changes made during control.lua processing if loading
                --mod_obj._ENV.global = wrap_table(table.deepcopy(old_global))
                mod_obj._ENV.global = table.deepcopy(old_global)
        end

        hotpatch_log({'hotpatch-info.running'}, mod_name)

        local success, result = xpcall(mod_obj.code, debug.traceback)
        if not success then
            hotpatch_log({'hotpatch-error.execution-failed'}, mod_name)
            hotpatch_log(result, mod_name)
            --local caller = (game and game.player) or console
            if game and game.player then
                game.player.print(result)
            end

            return false
        end

        mod_obj._ENV.global = old_global
        old_global = nil

        for k,v in pairs(mod_obj.custom_events) do
            custom_events[k] = v
        end

        mod_obj.running = true
        hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.running'}}, mod_name)

        --load complete, start notifying on event subscriptions
        if not compat_mode then
            mod_obj._ENV.script.on_event = function(event, f)
                if event == defines.events.on_tick then
                    mod_obj.on_tick = f
                    if f then
                        register_on_tick(mod_name)
                    else
                        unregister_on_tick(mod_name)
                    end
                else
                    mod_obj.on_event[event] = f
                    if f then
                        register_event(mod_name, event)
                    else
                        unregister_event(mod_name, event)
                    end
                end
            end
            mod_obj._ENV.script.on_nth_tick = function(tick, f)
                if tick then
                    if type(tick) == 'table' then
                        for _, v in pairs(tick) do
                            mod_obj._ENV.script.on_nth_tick(v, f)
                        end
                        return
                    end

                    mod_obj.on_nth_tick[tick] = f
                    if f then
                        register_nth_tick(mod_name, tick)
                    else
                        unregister_nth_tick(mod_name, tick)
                    end
                else
                    local mod_on_nth_tick = mod_obj.on_nth_tick
                    mod_obj.on_nth_tick = {}
                    for _, v in pairs(mod_on_nth_tick) do
                        unregister_nth_tick(mod_name, v)
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
    local mod_obj
    for i = 1, #loaded_mods do
        mod_obj = loaded_mods[i]
        f = mod_obj.on_event[event.name]
        if f then
            hotpatch_log({'hotpatch-trace.event-running', event_name}, mod_obj.name)
            f(event)
        end
    end
end

if core_logging.get_hotpatch_log_settings().hotpatch_log_on_tick then
    on_nth_tick = function(event)
        local tick = event.nth_tick
        local f
        hotpatch_log({'hotpatch-trace.nth-tick-event-processing', tick})
        local mod_obj
        for i = 1, #loaded_mods do
            mod_obj = loaded_mods[i]
            f = mod_obj.on_nth_tick[event.nth_tick]
            if f then
                hotpatch_log({'hotpatch-trace.nth-tick-event-running', tick}, mod_obj.name)
                f(event)
            end
        end
    end
else
    on_nth_tick = function(event)
        local tick = event.nth_tick
        local f
        local mod_obj
        for i = 1, #loaded_mods do
            mod_obj = loaded_mods[i]
            f = mod_obj.on_nth_tick[event.nth_tick]
            if f then
                f(event)
            end
        end
    end
end

register_all_events = function()
    --unregister all events

    script.on_event(defines.events, nil)
    if core_logging.get_hotpatch_log_settings().hotpatch_log_on_tick then
        script.on_event(defines.events.on_tick, on_tick)
    end
    script.on_nth_tick(nil, nil)
    --re-register all mod events
    for i = 1, #loaded_mods do
        register_mod_events(i)
    end
end

register_mod_events = function(loaded_index)

    local mod_obj = loaded_mods[loaded_index]
    local mod_name = mod_obj.name
    hotpatch_log({'hotpatch-trace.event-registering'}, mod_name)
    if mod_obj.on_tick then
        register_on_tick(mod_name)
    end
    for k,_ in pairs(mod_obj.on_event) do
        register_event(mod_name, k)
    end
    for k,_ in pairs(mod_obj.on_nth_tick) do
        register_nth_tick(mod_name, k)
    end
end

unregister_mod_events = function(loaded_index)

    local mod_obj = loaded_mods[loaded_index]
    local mod_name = mod_obj.name
    hotpatch_log({'hotpatch-trace.event-unregistering'}, mod_name)
    if mod_obj.on_tick then
        unregister_on_tick(mod_name)
    end
    for k,_ in pairs(mod_obj.on_event) do
        unregister_event(mod_name, k)
    end
    for k,_ in pairs(mod_obj.on_nth_tick) do
        unregister_nth_tick(mod_name, k)
    end
end

mod_on_init = function(loaded_index)
    local mod_obj = loaded_mods[loaded_index]

    if mod_obj then
        hotpatch_log({'hotpatch-trace.mod-on-init'}, mod_obj.name)
        if mod_obj.on_init then
            local success, result = xpcall(mod_obj.on_init, debug.traceback)
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
    local mod_obj = loaded_mods[loaded_index]

    if mod_obj then
        hotpatch_log({'hotpatch-trace.mod-on-load'}, mod_obj.name)
        if mod_obj.on_load then
            local old_global =    mod_obj._ENV.global
            --mod_obj._ENV.global = wrap_table(old_global)
            local success, result = xpcall(mod_obj.on_load, debug.traceback)
            if not success then
                hotpatch_log({'hotpatch-error.on-load-failed'}, mod_name)
                hotpatch_log(result, mod_name)
                return false
            end
            mod_obj._ENV.global = old_global

        end
        register_mod_events(loaded_index)
        return true
    end
    return false
end

mod_on_configuration_changed = function(loaded_index, config)
    local mod_obj = loaded_mods[loaded_index]

    if mod_obj then
        hotpatch_log({'hotpatch-trace.mod-on-configuration-changed'}, mod_obj.name)
        if mod_obj.on_configuration_changed then
            local success, result = xpcall(mod_obj.on_configuration_changed, debug.traceback, config)
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
    local mod_obj

    for i = 1, #loaded_mods do
        mod_obj = loaded_mods[i]
        local f = mod_obj.on_tick
        if f and mod_obj.name ~= mod_name then
            found_event = true
            break
        end
    end

    hotpatch_log({'hotpatch-trace.on-tick-event-registered'}, mod_name)
    if not found_event then
        hotpatch_log({'hotpatch-trace.on-tick-handler-added'})
        script.on_event(defines.events.on_tick, on_tick)
    end

end

unregister_on_tick = function(mod_name)
    local found_event
    local mod_obj

    for i = 1, #loaded_mods do
        mod_obj = loaded_mods[i]
        local f = mod_obj.on_tick
        if f and mod_obj.name ~= mod_name then
            found_event = true
            break
        end
    end

    hotpatch_log({'hotpatch-trace.on-tick-event-unregistered'}, mod_name)
    if not found_event then
        if not core_logging.get_hotpatch_log_settings().hotpatch_log_on_tick then
            hotpatch_log({'hotpatch-trace.on-tick-handler-removed'})
        end
        script.on_event(defines.events.on_tick, nil)
    end
end

register_nth_tick = function(mod_name, nth_tick)
    local found_event
    local mod_obj

    for i = 1, #loaded_mods do
        mod_obj = loaded_mods[i]
        local f = mod_obj.on_nth_tick[nth_tick]
        if f and mod_obj.name ~= mod_name then
            found_event = true
            break
        end
    end

    hotpatch_log({'hotpatch-trace.on-nth-tick-event-registered', nth_tick}, mod_name)
    if not found_event then
        hotpatch_log({'hotpatch-trace.nth-tick-handler-added', nth_tick})
        script.on_nth_tick(nth_tick, on_nth_tick)
    end     
end

unregister_nth_tick = function(mod_name, nth_tick)
    local found_event
    local mod_obj

    for i = 1, #loaded_mods do
        mod_obj = loaded_mods[i]
        local f = mod_obj.on_nth_tick[nth_tick]
        if f and mod_obj.name ~= mod_name then
            found_event = true
            break
        end
    end

    hotpatch_log({'hotpatch-trace.on-nth-tick-event-unregistered', nth_tick}, mod_name)
    if not found_event then
        hotpatch_log({'hotpatch-trace.nth-tick-handler-removed', nth_tick})
        script.on_nth_tick(nth_tick, nil)
    end
end

register_event = function(mod_name, event_name)
    local found_event
    local mod_obj

    for i = 1, #loaded_mods do
        mod_obj = loaded_mods[i]
        local f = mod_obj.on_event[event_name]
        if f and mod_obj.name ~= mod_name then 
            found_event = true
            break
        end
    end

    hotpatch_log({'hotpatch-trace.on-event-registered', (event_names[event_name] or event_name)}, mod_name)
    if not found_event then
        hotpatch_log({'hotpatch-trace.on-event-handler-added', (event_names[event_name] or event_name)})
        script.on_event(event_name, on_event)
    end
end

unregister_event = function(mod_name, event_name)
    local found_event
    local mod_obj

    for i = 1, #loaded_mods do
        mod_obj = loaded_mods[i]
        local f = mod_obj.on_event[event_name]
        if f and mod_obj.name ~= mod_name then 
            found_event = true
            break
        end
    end

    hotpatch_log({'hotpatch-trace.on-event-unregistered', (event_names[event_name] or event_name)}, mod_name)
    if not found_event then
        hotpatch_log({'hotpatch-trace.on-event-handler-removed', (event_names[event_name] or event_name)})
        script.on_event(event_name, nil)
    end
end

-- Core registration

on_init = function()
    -- Restore factorio locale handling
    core_logging.restore_logging()

    hotpatch_log({'hotpatch-info.on-init'})
    --juuuuust in case
    global.mods = global.mods or {}
    setmetatable(global.mods, {
        __index = function(t,k)
            local installed_index = find_installed_mod(k)
            if installed_index then
                return rawget(t, installed_index)
            end
        end
    })

    hotpatch_log({'hotpatch-info.installing-included-mods'})
    local mod
    for i = 1, #static_mods do
        mod = static_mods[i]
        install_mod(mod.name, mod.version, mod.code, mod.files)
    end
    hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.installing-included-mods'}})

        hotpatch_log({'hotpatch-info.loading-installed-mods'})
    -- load installed mods
    for i = 1, #global.mods do
        load_mod(i)
    end

    -- run mods which loaded successfully
    local failed_mods = {}

    for i = 1, #loaded_mods do
        if run_mod(i, true) then
            if not mod_on_init(i) then
                table.insert(failed_mods, i)
            end
        else
            table.insert(failed_mods, i)
        end
    end

    -- unload mods which failed to run
    for i = #failed_mods, 1, -1 do
        unload_mod(failed_mods[i])
    end

    hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.loading-installed-mods'}})
    hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.on-init'}})
end

on_load = function()
    local old_global = table.deepcopy(global)
    hotpatch_log({'hotpatch-info.on-load'})
    hotpatch_log({'hotpatch-info.loading-installed-mods'})

    if global.globals then
        -- TODO: create an actual migration that works for this and remove this check
        error('Upgrading from Hotpatch 1.0.X to 1.1.0 is not currently supported!')
    end

    setmetatable(global.mods, {
        __index = function(t,k)
            local installed_index = find_installed_mod(k)
            if installed_index then
                return rawget(t, installed_index)
            end
        end
    })

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
    for i = #failed_mods, 1, -1 do
        unload_mod(failed_mods[i])
    end

    hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.loading-installed-mods'}})
    hotpatch_log({'hotpatch-info.complete', {'hotpatch-info.on-load'}})


    local compare_table
    function compare_table(t1, t2, n, i)
        i = i or ''
        local is_same = true
        local n1 = n or 'T1'
        n1 = tostring(n1)
        local n2 = n or 'T2'
        n2 = tostring(n2)
        local out = {}
        local seen = {}
        for k,v in pairs(t1) do
            local v2 = t2[k]
            if (not v2) and type(v2) ~= 'boolean' then
                out[k] = i .. n2 .. '[' .. tostring(k) .. '] missing(R)'
                is_same = false
            else
                seen[k] = true
                local tt1 = type(v)
                local tt2 = type(v2)
                if tt1 ~= tt2 then
                    out[k] = i .. n2 .. '[' .. tostring(k) .. '] is different type'
                    is_same = false
                else
                if tt1 == 'table' then
                    local same
                    same, out[k] = compare_table(v, v2, k, i .. '    ')
                    if same then out[k] = nil else
                    is_same = false
                    end
                elseif v ~= v2 then

                    out[k] = i .. n2 .. '[' .. tostring(k) .. '] differs (' .. v .. ') (' .. v2 .. ')'
                    is_same = false
                end
                end
            end
        end
        for k,v in pairs(t2) do
            local v1 = t1[k]
            if (not v1) and type(v1) ~= 'boolean' then
                out[k] = i .. n1 .. '[' .. tostring(k) .. '] missing(L)'
                is_same = false
            end
        end
        return is_same, out
    end

    local same, diffs = compare_table(global,old_global)
    local print_diffs
    local out = ''
    function get_diffs(diff, i)
        i = i or ''
        for k,v in pairs(diff) do
            if type(v) == 'table' then
                out = out .. (i .. tostring(k)) .. '\n'
                print_diffs(v, i .. '    ')
            else
                out = out .. v
            end
        end
    end
    if not same then
        get_diffs(diffs)
        hotpatch_log(out)
        error('A mod loaded inside of hotpatch corrupted the global table during on_load, check the log')  
    end
    -- Workaround for factorio "bug" - factorio locale isn't available until on_load finishes running
    -- this should ideally be at the top of this event
    -- use our patched version for now
    core_logging.restore_logging()
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

if core_logging.get_hotpatch_log_settings().hotpatch_log_on_tick then
    on_tick = function(e)
        hotpatch_log({'hotpatch-trace.event-processing', 'on_tick'})
        local mod_obj
        local f
        for i = 1, #loaded_mods do
            mod_obj = loaded_mods[i]
            f = mod_obj.on_tick
            if f then
                hotpatch_log({'hotpatch-trace.event-running', 'on_tick'}, mod_obj.name)
                f(e)
            end
        end
    end
else
    on_tick = function(e)
        local mod_obj
        local f
        for i = 1, #loaded_mods do
            mod_obj = loaded_mods[i]
            f = mod_obj.on_tick
            if f then
                f(e)
            end
        end
    end
end


script.on_init(on_init)
script.on_load(on_load)
script.on_configuration_changed(on_configuration_changed)
if core_logging.get_hotpatch_log_settings().hotpatch_log_on_tick then
    script.on_event(defines.events.on_tick, on_tick)
end

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
    unregister_event = unregister_event,
    unregister_nth_tick = unregister_nth_tick,
    unregister_on_tick = unregister_on_tick,

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