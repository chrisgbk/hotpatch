--[[

Copyright 2018 Chrisgbk
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

]]
-- MIT License, https://opensource.org/licenses/MIT

-- Hotpatch-MultiMod: a tool to load multiple scenarios side-by-side, with support for both static loading and dynamic loading, as well as run-time patching

log('Hotpatch runtime initializing...')
local util = require 'util'

-- configuration options; these should be exposed via API one day
local debug_mode = true
local debug_log_to_console_only = false
local debug_log_to_RCON = true --only affects when log_to_console_only is in effect
local compat_mode = false -- enable some compatibility settings, which can help some mods load
local strict_mode = false -- causes hotpatch to hard-stop on mods doing bad things

-- convenience object(rcon.print also prints to stdout when called from server console)
local console = {name = 'Console', admin = true, print = function(...) rcon.print(...) end, color = {1,1,1,1}}

-- these represent the mods as statically packaged with the scenario
local static_mods = {}
--      static_mods[i] = {}
--      static_mods[i].name = ''
--      static_mods[i].version = ''
--      static_mods[i].code = ''
--      static_mods[i].files = {}

-- installed mods are represented with:
--      global.mods = {}
--      global.mods[i] = {}
--      global.mods[i].name = ''
--      global.mods[i].version = ''
--      global.mods[i].code = ''
--      global.mods[i].files = {}
--      global.mods[i].global = {}

-- loaded/running mods are represented with:
local loaded_mods = {} -- this holds a reference to the mods internal object
--      loaded_mods[i] = mod_obj_template

-- internal mod object:
local mod_obj_template = {
    name = '', -- name of the current mod
    version = '',
    env = {}, -- environment of the mod
    loaded = false,
    running = false,
    on_init = nil, -- called once after first install, or when specifically requested to be re-ran (good practice is to never request a re-run)
    on_load = nil, -- called every time the scenario loads from disk
    on_configuration_changed = nil, -- called every time the external mod configuration changes, OR when the hotpatch mod configuration changes
    on_tick = nil, -- cache the on-tick event handler, because it is ID 0, which causes it to be stored in the hash part, which causes a 50% increase in access time
    on_event = {}, -- list of on_event handlers registered
    on_nth_tick = {}, -- list of on_nth_tick handlers registered
    loaded_files = {}, -- list of files loaded by require() that were installed into the virtual file system
}

-- this is for the core factorio libraries; hotpatch MUST load these now, as they cannot be dynamically loaded due to factorio limitation
local loaded_libraries = {} 

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

-- internal callbacks when a mod registers events
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

-- mapping of events to names for logging
local event_names = {}
for k,v in pairs(defines.events) do
    event_names[v] = k
end

-- This scenario contains an embedded locale, but it's unavailable until this file finishes loading
-- Rseding91 doesn't want to fix it (https://forums.factorio.com/viewtopic.php?f=23&t=60767)
-- I'll make it work myself ¯\_(ツ)_/¯
local static_cfg = [[
[hotpatch]
core-error=[HOTPATCH@__1__:__2__] ERROR: __3__
mod-error=[HOTPATCH@__1__:__2__][__4__] ERROR: __3__
core-warning=[HOTPATCH@__1__:__2__] WARNING: __3__
mod-warning=[HOTPATCH@__1__:__2__][__4__] WARNING: __3__
core-info=[HOTPATCH@__1__:__2__] INFO: __3__
mod-info=[HOTPATCH@__1__:__2__][__4__] INFO: __3__

[hotpatch-info]
runtime-init=Hotpatch runtime initializing...
logging-enabled=Logging enabled
metatable-installed=_ENV metatable installed
complete=__1__ Complete!
nil-var-access=_ENV nil variable access: __1__
nil-var-assignment=_ENV variable assignment: __1__
must-be-admin=You must be an admin to run this command
remote-installing=installing remote interface

[hotpatch-core-info]
on-init=initializing...
on-load=loading...
on-configuration-changed=mod configuration changed...
installing-included-mods=installing included mods...
loading-installed-mods=loading installed mods...
loading-libs=loading Factorio.data.core.lualib...
loading-library=loading library: __1__
event-processing=processing event __1__...
nth-tick-event-processing=processing nth_tick event __1__...
nth-tick-handler-added=adding nth_tick handler: __1__
nth-tick-handler-removed=adding nth_tick handler: __1__
on-tick-handler-added=adding nth_tick handler: __1__
on-tick-handler-removed=adding nth_tick handler: __1__
on-event-handler-added=adding nth_tick handler: __1__
on-event-handler-removed=adding nth_tick handler: __1__

[hotpatch-mod-info]
uninstalling=Uninstalling mod...
installing=Installing version __1__...
installing-file=Installing file __1__...
script-shim=setting up mod script shim...
caching-event=caching event: __1__...
caching-nth-tick-event=caching nth_tick event: __1__...
setting-env=setting up mod _ENV...
cached-load-require=loading cached require'd file: __1__...
load-require=loading require'd file: __1__...
load-core-lib=loading from Factorio.data.core.lualib: __1__...
loading=loading...
unloading=unloading...
running=running...
event-registering=registering events...
tick-event-registered=registered on_tick event...
event-registered=registered event __1__...
nth-tick-event-registered=registered nth_tick event __1__...
event-running=running event __1__...
nth-tick-event-running=running nth_event __1__...
on-init=running on_init...
on-load=running on_load...
on-configuration-changed=running on_configuration_changed...
adding-event=adding event __1__
adding-nth-tick-event=adding nth_tick event __1__

[hotpatch-warning]

[hotpatch-core-warning]
invalid-API-access=Invalid API access: __1__

[hotpatch-mod-warning]
contains-comments=mod code contains comments!
contains-comments-no-lf=mod contains comments and no linefeed!
contains-comments-console=comments from console will comment out the entire code!
reset-events-not-running=tried to reset events for mod that isn't running!
remote-interface-exists=remote interface __1__ already exists, removing...
command-exists=command __1__ already exists, removing...
already-loaded=mod already loaded
reinitializing=reinitializing...
already-exists=mod already exists
reinstalling=reinstalling mod in-place

[hotpatch-error]

[hotpatch-core-error]
not-installed=mod not installed, cannot install file for mod that does not exist

[hotpatch-mod-error]
compilation-failed=compilation failed for mod
execution-failed=execution failed for mod
]]

local function build_locale(ini)
    local t = {}
    local section = ''
    local temp
    -- for each non-empty line do
    -- line must end with a linefeed - single line file with no LF will fail
    for l in string.gmatch(ini, '\r*\n*(.-)\r*\n+') do
        -- header?
        temp = string.match(l, '^%[(.-)%]$')
        if temp then
            section = temp
            temp = nil
        else
            --key=value
            local key, value = string.match(l, '^(.-)=(.+)$')
            t[table.concat{section, '.', key}] = value
        end
    end
    return t
end

local static_locale = build_locale(static_cfg)

local function static_translate(t)
    -- only translate tables
    if type(t) ~= 'table' then return t end
    -- only translate tables that have a string as the first item
    local k = t[1]
    if type(k) ~= 'string' then return t end
    local v
    -- make a copy, don't destroy the original table
    t = table.deepcopy(t)
    -- translate any arguments as well
    for i = 2, #t do
        v = t[i]
        if type(v) == 'table' then
            t[i] = static_translate(v)
        end
    end
    -- special case: whitespace token causes concatenation with that token
    -- slightly better than factorio, where only '' is supported
    if k:find('^%s*$') then table.remove(t, 1) return table.concat(t, k) end
    local pattern = static_locale[k]
    -- if not translatable return normal table ref
    --if not pattern then return t end
    if not pattern then return t end
    -- substitution of parameters
    return (pattern:gsub('__(%d)__', function(s) return tostring(t[tonumber(s)+1]) end))
end

-- override print to make it support our translation efforts
-- still doesn't support Factorio locales, because devs don't patch it like I do
-- this means unknown keys will be printed as 'table: 0x...'
local real_print = print
local print = function(...)
    if select('#', ...) == 1 then
        real_print(static_translate(...))
    else
        local t = table.pack(...)
        table.insert(t, 1, '\t')
        real_print(static_translate(t))
    end
end

-- override log to make it support our translation efforts
-- any unknown keys are passed to Factorio to translate
-- after this file finishes loading, the old log is restored with the restore_log() function, to allow for run-time locale-only mods that override our static locale
local real_log = log
local log = function(...)
    if select('#', ...) == 1 then
        real_log(static_translate(...))
    else
        local t = table.pack(...)
        table.insert(t, 1, '\t')
        real_log(static_translate(t))
    end
end

-- logs localized data
local function debug_log(message, mod_name, level)
    if debug_mode then 
        if not level then level = 2 end
        local di = debug.getinfo(level)
        local line = di.currentline
        local file = (di.source:gsub('%@.*/', ''))
        local class = 'hotpatch.core-info'
		if type(message) == 'table' then
            local severity = message[1]:match('.-%-([^%-]*)%.')
            if not severity then
                severity = message[1]:match('.-%-.-%-(.*)%.')
            end
            class = table.concat{'hotpatch', '.', ((mod_name and 'mod') or 'core'), '-', severity}
        end
		--TODO: support multiple log levels
        if debug_log_to_console_only then
            if debug_log_to_RCON then
                rcon.print{class, file, line, message, mod_name}
            end
            print{class, file, line, message, mod_name}

        else
            log{class, file, line, message, mod_name}
        end
    end
end

debug_log({'hotpatch-info.logging-enabled'})

-- track _ENV accesses
setmetatable(_ENV, {
	__index = function(t, k)
		debug_log({'hotpatch-info.nil-var-access', k}, nil, 3)
		return nil
	end,
	__newindex = function(t, k, v)
		debug_log({'hotpatch-info.nil-var-assignment', k}, nil, 3)
		rawset(t,k,v)
	end,
	__metatable = false
})

debug_log({'hotpatch-info.metatable-installed'})

-- load all possible libraries
debug_log({'hotpatch-core-info.loading-libs'})

local libraries = {
    'camera',
    'flying_tags',
    'inspect',
    'math3d',
    'mod-gui',
    'noise',
    'production-score',
    'silo-script',
    'story',
    'util',
}

for k, v in pairs(libraries) do
    debug_log({'hotpatch-core-info.loading-library', v})
	loaded_libraries[k] = require(v)
end

debug_log({'hotpatch-info.complete', {'hotpatch-core-info.loading-libs'}})

find_installed_mod = function(mod_name)
    for k, v in pairs(global.mods) do
        if v.name == mod_name then
            return k
        end
    end
    return nil
end

find_loaded_mod = function(mod_name)
    for k, v in pairs(loaded_mods) do
        if v.name == mod_name then
            return k
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
        

    debug_log({'hotpatch-mod-info.uninstalling', mod_name})
    
    table.remove(global.mods, index)
end

install_mod_file = function(mod_name, mod_file, mod_file_code)
    local index = find_installed_mod(mod_name)
    if not index then
        debug_log({'hotpatch-core-error.not-installed'})
        return
    end
    local mod = global.mods[index]
    
    debug_log({'hotpatch-mod-info.installing-file', mod_file}, mod_name)

    mod_file = mod_file:gsub('/', '.')
    mod_file = mod_file:gsub('\\', '.')
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
    debug_log({'hotpatch-mod-info.installing', mod_version}, mod_name)
    if mod_code:find('--', 1, true) then

        debug_log({'hotpatch-mod-warning.contains-comments'}, mod_name)
        if not mod_code:find("\n", 1, true) then
            debug_log({'hotpatch-mod-warning.contains-comments-no-lf'}, mod_name)
        end
        debug_log({'hotpatch-mod-warning.contains-comments-console'}, mod_name)
    end

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
        -- TODO: integrity check, verify each mods global table to detect guaranteed desync mods
        local loaded_index = find_loaded_mod(mod_name)
        if loaded_index then
            --TODO notify that mod was already loaded
            unload_mod(loaded_index)
        end
        
        local mod_obj = {
            name = mod_name, -- name of the current mod
            version = mod.version,
            env = {}, -- environment of the mod
            loaded = false,
            running = false,
            on_init = nil, -- called once after first install, or when specifically requested to be re-ran (good practice is to never request a re-run)
            on_load = nil, -- called every time the scenario loads from disk
            on_configuration_changed = nil, -- called every time the external mod configuration changes, OR when the hotpatch mod configuration changes
            on_tick = nil, -- cache the on-tick event handler, because it is ID 0, which causes it to be stored in the hash part, which causes a 50% increase in access time
            on_event = {}, -- list of on_event handlers registered
            on_nth_tick = {}, -- list of on_nth_tick handlers registered
            loaded_files = {}, -- list of files loaded by require() that were installed into the virtual file system
        }
        
        debug_log({'hotpatch-mod-info.script-shim'}, mod_name)
        --mods private script table/shim
        local mod_script = {}

        mod_script.on_init = function(f)
            mod_obj.on_init = f
        end
        mod_script.on_load = function(f)
            mod_obj.on_load = f
        end
        mod_script.on_configuration_changed = function(f)
            mod_obj.on_configuration_changed = f
        end
        if not compat_mode then
            mod_script.on_event = function(event, f)
                if event == defines.events.on_tick then
                    mod_obj.on_tick = f
                else
                    mod_obj.on_event[event] = f
                end
            end
            mod_script.on_nth_tick = function(tick, f)
                if tick then
                    if type(tick) == 'table' then
                        for k, v in pairs(tick) do
                            mod_script.on_nth_tick(v, f)
                        end
                        return
                    end
                    mod_obj.on_nth_tick[tick] = f
                else
                    mod_obj.on_nth_tick = {}
                end
            end
        else   
            mod_script.on_event = function(event, f)
                if event == defines.events.on_tick then
                    mod_obj.on_tick = f
                    if mod_obj.running then
                        register_on_tick(mod_name, event)
                    end
                else
                    mod_obj.on_event[event] = f
                    if mod_obj.running then
                        register_event(mod_name, event)
                    end
                end
            end
            mod_script.on_nth_tick = function(tick, f)
                if tick then
                    if type(tick) == 'table' then
                        for k, v in pairs(tick) do
                            mod_script.on_nth_tick(v, f)
                        end
                        return
                    end
                    mod_obj.on_nth_tick[tick] = f
                    if mod_obj.running then
                        register_nth_tick(mod_name, tick)
                    end
                else
                    local on_nth_tick = mod_obj.on_nth_tick
                    mod_obj.on_nth_tick = {}
                    if mod_obj.running then
                        for k, v in pairs(on_nth_tick) do
                            register_nth_tick(mod_name, tick)
                        end
                    end
                end
            end
        end
        mod_script.generate_event_name = function()
            return script.generate_event_name()
        end
        mod_script.get_event_handler = function(event)
            return mod_obj.on_event[event]
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
        
        debug_log({'hotpatch-mod-info.setting-env'}, mod_name)
        -- mods private env
        local env = mod_obj.env
        -- mods private package
        local pack = {}
        -- mods private package.loaded
        local loaded = {}
        -- copy the current environment
		for k,v in pairs(_ENV) do
			env[k] = v
		end
        -- copy package.loaded
        for k,v in pairs(_ENV.package.loaded) do
			loaded[k] = v
		end
        loaded._G = env
        
        -- so many ways to escape sandboxes...
        
        for k,v in pairs(_ENV.package) do
			pack[k] = v
		end
        pack.loaded = loaded
        env.package = pack
        loaded.package = pack
        
        env.script = mod_script
        env.global = mod.global
        env._G = env
        
        env['remote'] = {
            add_interface = function(name, functions)
                if remote.interfaces[name] then
                    debug_log({'hotpatch-mod-warning.remote-interface-exists', name}, mod_name)
                    remote.remove_interface(name)
                end
                remote.add_interface(name, functions)
            end,
            remove_interface = function(name)
                return remote.remove_interface(name)
            end,
            call = function(...)
                return remote.call(...)
            end,
            interfaces = setmetatable({}, {
                __index = function(t, k) return remote.interfaces[k] end,
                __pairs = function(t) local function iter(t, k) local v; k, v = next(remote.interfaces, k); if v then return k, t[k] end; end; return iter, t, nil end
            })
        }
        env['commands'] = {
            add_command = function(name, help, func)
                if commands.commands[name] then
                    debug_log({'hotpatch-mod-warning.command-exists', name}, mod_name)
                    commands.remove_command(name)
                end
                commands.add_command(name, help, func)
            end,
            remove_command = function(name)
                return commands.remove_command(name)
            end,
            commands = setmetatable({}, {
                __index = function(t, k) return commands.commands[k] end,
                __pairs = function(t) local function iter(t, k) local v; k, v = next(commands.commands, k); if v then return k, t[k] end; end; return iter, t, nil end
            }),
            game_commands = setmetatable({}, {
                __index = function(t, k) return commands.game_commands[k] end,
                __pairs = function(t) local function iter(t, k) local v; k, v = next(commands.game_commands, k); if v then return k, t[k] end; end; return iter, t, nil end
            })
        }
        
        
        env.require = function(path)
            -- I blame Nexela for this
            path = path:gsub('/', '.')
            path = path:gsub('\\', '.')
            if env.package._current_path_in_package then
                path = env.package._current_path_in_package .. path
            end
            if mod_obj.loaded_files[path] then
                debug_log({'hotpatch-mod-info.cached-load-require', path}, mod_name)
                return mod_obj.loaded_files[path]
            else
                local oldbase = env.package._current_path_in_package
                env.package._current_path_in_package = path:match('.+%..+%.')
                if not env.package._current_path_in_package then
                     env.package._current_path_in_package = path:match('.+%.')
                end
                local file = global.mods[installed_index].files[path]
                if file then
                    debug_log({'hotpatch-mod-info.load-require', path}, mod_name)
                    mod_obj.loaded_files[path] = load(file, 'hotpatch require ' .. path .. ' (' .. mod_name .. ')', 'bt', env)
                    mod_obj.loaded_files[path]()
                    env.package._current_path_in_package = oldbase
                    return mod_obj.loaded_files[path]
                end
                debug_log({'hotpatch-mod-info.load-core-lib', path}, mod_name)
                return package.loaded[path]
            end
        end
        
        env['load'] = function(l, s, m, e)
            return load(l, s, m, e or env)
        end
        env['loadstring'] = env['load']
        
        
        env['game'] = setmetatable({}, {
            __index = function(t, k) return game[k] end,
            __pairs = function(t) local function iter(t, k) local v; k, v = next(game, k); if v then return k, t[k] end; end; return iter, t, nil end
        })
        
        local mt = {}
        mt.__index = function(t, k)
            debug_log({'hotpatch-info.nil-var-access', k}, mod_name, 3)
            return nil
        end
        mt.__newindex = function(t, k, v)
            debug_log({'hotpatch-info.nil-var-assignment', k}, mod_name, 3)
            rawset(t,k,v)
        end
        -- Don't let mods break this
        mt.__metatable = false
        setmetatable(env, mt)

        --load/run code
        debug_log({'hotpatch-mod-info.loading'}, mod_name)
        
        local mod_code, message = load(mod.code, 'hotpatch loader (' .. mod_name .. ')', 'bt', env)
        if not mod_code then
            debug_log({'hotpatch-mod-error.compilation-failed'}, mod_name)
            if game and game.player then
                game.player.print({'hotpatch-mod-error.compilation-failed', mod_name})
                game.player.print(message)
            end
            debug_log(message, mod_name)
            return
        end

        mod_obj.code = mod_code
        mod_obj.loaded = true
        table.insert(loaded_mods, mod_obj)
    end
end

unload_mod = function(loaded_index)
    local mod = loaded_mods[loaded_index]
    if not mod then
        --TODO notify that mod isn't loaded
        return
    end
    local mod_name = mod.name
    -- TODO
    -- stop mod running, unregister handlers from being called
    debug_log({'hotpatch-mod-info.unloading'}, mod_name)
    -- TODO:
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
    --local mod_global = global.mod_global[mod_name]
    --for k, v in pairs(mod_global) do
    --    mod_global[k] = nil
    --end

    reset_mod_events(loaded_index)
end

reset_mod_events = function(loaded_index)
    local loaded_index = find_loaded_mod(mod_name)
    
    if not loaded_index then
        debug_log({'hotpatch-mod-warning.reset-events-not-running'}, mod_name)
    else 
        local loaded_mod = loaded_mods[loaded_index]
        loaded_mod.on_event = {}
        loaded_mod.on_nth_tick = {}
        loaded_mod.on_init = nil
        loaded_mod.on_load = nil
        loaded_mod.on_configuration_changed = nil
        loaded_mod.on_tick = nil
        register_all_events()
    end
end

run_mod = function(loaded_index)
    local mod = loaded_mods[loaded_index]
    local mod_name = mod.name
    if mod then
        local old_global = mod.env.global
        if strict_mode then
           mod.env.global = {}
        end
        debug_log({'hotpatch-mod-info.running'}, mod_name)
        
        local success, result = xpcall(mod.code, debug.traceback)
        if not success then
            debug_log({'hotpatch-mod-error.execution-failed'}, mod_name)
            debug_log(result, mod_name)
            --local caller = (game and game.player) or console
            if game and game.player then
                game.player.print({'hotpatch-mod-error.execution-failed'})
                game.player.print(result)
            end
            unload_mod(loaded_index)
            
            return
        end
        
        
        mod.running = true
            
        if strict_mode then
            if mod.env.global ~= {} then
                --TODO: error, mod touched global inappropriately during load
            end
           mod.env.global = old_global
        end

        debug_log({'hotpatch-info.complete', {'hotpatch-mod-info.running'}}, mod_name)
        
        --load complete, start notifying on event subscriptions
        if not compat_mode then
            mod.env.script.on_event = function(event, f)
                if event == defines.events.on_tick then
                    mod.on_tick = f
                    register_on_tick(mod_name, event)
                else
                    mod.on_event[event] = f
                    register_event(mod_name, event)
                end
            end
            mod.env.script.on_nth_tick = function(tick, f)
                if tick then
                    if type(tick) == 'table' then
                        for k, v in pairs(tick) do
                            mod_script.on_nth_tick(v, f)
                        end
                        return
                    end
                    mod.on_nth_tick[tick] = f
                    register_nth_tick(mod_name, tick)
                else
                    local on_nth_tick = mod.on_nth_tick
                    mod.on_nth_tick = {}
                    for k, v in pairs(on_nth_tick) do
                        register_nth_tick(mod_name, tick)
                    end
                end
            end
        end
    end
end

-- Note: might be able to optimize this a bit
-- event handlers to call into mods requested event handlers
on_event = function(event)
    local event_name = (event_names[event.name] or event.name)
    debug_log({'hotpatch-core-info.event-processing', event_name})
    for k, v in pairs(loaded_mods) do
        local f = v.on_event[event.name]
        if f then 
            debug_log({'hotpatch-mod-info.event-running', event_name}, v.name)
            f(event)
        end
    end
end

on_nth_tick = function(event)
    local tick = event.nth_tick
    debug_log({'hotpatch-core-info.nth-tick-event-processing', tick})
    for k, v in pairs(loaded_mods) do
        local f = v.on_nth_tick[event.nth_tick]
        if f then 
            debug_log({'hotpatch-mod-info.nth-tick-event-running', tick}, v.name)
            f(event)
        end
    end
end

local register_all_events = function()
    --unregister all events
    script.on_event(defines.events, nil)
    script.on_nth_tick(nil, nil)
    --re-register all mod events
    for k, v in pairs(loaded_mods) do
        register_mod_events(k)
    end
end

register_mod_events = function(loaded_index)

    local mod = loaded_mods[loaded_index]
    local mod_name = mod.name
    debug_log({'hotpatch-mod-info.event-registering'}, mod_name)
    if mod.on_tick then
        debug_log({'hotpatch-mod-info.tick-event-registered'}, mod_name)
        script.on_event(defines.events.on_tick, on_tick)
    end
    for k,v in pairs(mod.on_event) do 
        local event_name = (event_names[k] or k)
        debug_log({'hotpatch-mod-info.event-registered', event_name}, mod_name)
        script.on_event(k, on_event)
    end
    for k,v in pairs(mod.on_nth_tick) do 
        debug_log({'hotpatch-mod-info.nth-tick-event-registered', k}, mod_name)
        script.on_nth_tick(k, on_nth_tick)
    end
end

mod_on_init = function(loaded_index)
    local mod = loaded_mods[loaded_index]
    
    if mod then
        debug_log({'hotpatch-mod-info.on-init'}, mod.name)
        if mod.on_init then 
            mod.on_init()
        end
        register_mod_events(loaded_index)
    end
end

mod_on_load = function(loaded_index)
    local mod = loaded_mods[loaded_index]
    
    if mod then
        debug_log({'hotpatch-mod-info.on-load'}, mod.name)
        if mod.on_load then 
            mod.on_load()
        end
        register_mod_events(loaded_index)
    end
end

mod_on_configuration_changed = function(loaded_index, config)
    local mod = loaded_mods[loaded_index]
    
    if mod then
        debug_log({'hotpatch-mod-info.on-configuration-changed'}, mod.name)
        if mod.on_configuration_changed then 
            mod.on_configuration_changed(config)
        end
    end
end

-- callbacks from mods to tell hotpatch when to enable handlers

register_on_tick = function(mod_name)
    local found_event
    --
    for k, v in pairs(loaded_mods) do
        local f = v.on_tick
        if f then 
            found_event = true 
            break 
        end
    end
    debug_log({'hotpatch-mod-info.on-tick-event-registered'}, mod_name)
    if found_event then
        debug_log({'hotpatch-core-info.on-tick-handler-added'})
    else
        debug_log({'hotpatch-core-info.on-tick-handler-removed'})
    end
end

register_nth_tick = function(mod_name, nth_tick)
    local found_event
    --
    for k, v in pairs(loaded_mods) do
        local f = v.on_nth_tick[nth_tick]
        if f then 
            found_event = true 
            break 
        end
    end
    debug_log({'hotpatch-mod-info.nth-tick-event-registered', nth_tick}, mod_name)
    if found_event then
        debug_log({'hotpatch-core-info.nth-tick-handler-added', nth_tick})
        script.on_nth_tick(event.nth_tick, on_nth_tick)
    else
        debug_log({'hotpatch-core-info.nth-tick-handler-removed', nth_tick})
        script.on_nth_tick(event.nth_tick, nil)
    end
end

register_event = function(mod_name, event_name)
    local found_event
    for k, v in pairs(loaded_mods) do
        local f = v.on_event[event_name]
        if f then found_event = true break end
    end
    debug_log({'hotpatch-mod-info.on-event-registered', nth_tick}, mod_name)
    if found_event then
        if script.get_event_handler(event_name) then
            -- handler already installed
            return
        else
           debug_log({'hotpatch-core-info.on-event-handler-added', (event_names[event_name] or event_name)})
           script.on_event(event.event, on_event)
        end
    else
        debug_log({'hotpatch-core-info.on-event-handler-added', (event_names[event_name] or event_name)})
        script.on_event(event.event, nil)
    end
end

-- Core registration

on_init = function()
    debug_log({'hotpatch-core-info.on-init'})
    --juuuuust in case
    global.mods = global.mods or {}
    
    debug_log({'hotpatch-core-info.installing-included-mods'})
    local mod
    for i = 1, #static_mods do
        mod = static_mods[i]
        install_mod(mod.name, mod.version, mod.code, mod.files)
    end
    
    for i = 1, #global.mods do
        load_mod(i)
    end
    
    for i = 1, #loaded_mods do
        run_mod(i)
        mod_on_init(i)
    end
    debug_log({'hotpatch-info.complete', {'hotpatch-core-info.installing-included-mods'}})
    debug_log({'hotpatch-info.complete', {'hotpatch-core-info.on-init'}})
end

on_load = function()
    debug_log({'hotpatch-core-info.on-load'})
    debug_log({'hotpatch-core-info.loading-installed-mods'})
    
    if global.globals then
        error('Upgrading from Hotpatch 1.0.X to 1.1.0 is not currently supported!')
        
        -- untested migration: use a tick to do the migration
        script.on_event(defines.events.on_tick, function(e)
            global.mods = {}
            local mod
            for k, v in pairs(global.mod_version) do
                mod = {}
                mod.name = k
                mod.version = v
                mod.code = global.mod_code[k]
                mod.files = global.mod_files[k]
                mod.global = global.globals[k]
                table.insert(global.mods, mod)
            end
            global.mod_version = nil
            global.mod_code = nil
            global.mod_files = nil
            global.globals = nil
            
            on_load() -- jump back into loading
            on_tick(e) -- need to test if factorio auto calls this or not after assigning the handler
            script.on_event(defines.events.on_tick, on_tick) -- restore old on_tick handler
        end)
        return
    end
    
    -- load installed mods
    for i = 1, #global.mods do
        load_mod(i)
    end
    
    -- run mods which loaded successfully
    for i = 1, #loaded_mods do
        run_mod(i)
        mod_on_load(i)
    end
    
    debug_log({'hotpatch-info.complete', {'hotpatch-core-info.loading-installed-mods'}})
    debug_log({'hotpatch-info.complete', {'hotpatch-core-info.on-load'}})
end

on_configuration_changed = function(config)
    debug_log({'hotpatch-core-info.on-configuration-changed'})
    for i = 1, #loaded_mods do
        mod_on_configuration_changed(i)
    end
    debug_log({'hotpatch-info.complete', {'hotpatch-core-info.on-configuration-changed'}})
end

on_tick = function(e)
    --local event_name = 'on_tick'
    --debug_log({'hotpatch-core-info.event-processing', event_name})
    local mod
    for i = 1, #loaded_mods do
        mod = loaded_mods[i]
        local f = mod.on_tick
        if f then 
            --debug_log({'hotpatch-mod-info.event-running', 'on_tick'}, mod.name)
            f(e)
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
    
    console = console,
    debug_log = debug_log,
},{
    __index = function(t, k)
        debug_log({'hotpatch-core-warning.invalid-API-access', k}, nil, 3)
    end,
    __newindex = function(t, k, v)
        -- do nothing
    end,
    -- Don't let mods muck around
    __metatable = false,
})

--public API
local mod_tools = setmetatable({
    -- most code should use new_mod
    static_mod = static_mod, -- (name, version, code, files)
    set_debug_mode = function(enabled)
        debug_mode = enabled
    end,
    restore_log = function()
        log = real_log
    end,
},{
    __index = mod_tools_internal,
    __newindex = function(t, k, v)
        -- do nothing, read-only table
    end,
    -- Don't let mods muck around
    __metatable = false,
})


return mod_tools