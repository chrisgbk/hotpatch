--[[--
Hotpatch Core: Module Object for Hotpatch-MultiMod: a tool to load multiple scenarios side-by-side,
with support for both static loading and dynamic loading, as well as run-time patching.
This module handles loading and running code, setting up environments, etc
@module hotpatch.core-mod_object
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

--[==[
-- internal mod object:
local mod_obj_template = {
    -- references to global table
    mod = mod
    name = mod_name,
    version = mod.version,
    files = mod.files,
    global = mod.global,
    -- 
    _ENV = {}, -- environment of the mod
    loaded = false,
    running = false,
    -- event handlers
    on_init = nil, -- called once after first install, or when specifically requested to be re-ran (good practice is to never request a re-run)
    on_load = nil, -- called every time the scenario loads from disk
    on_configuration_changed = nil, -- called every time the external mod configuration changes, OR when the hotpatch mod configuration changes
    on_tick = nil, -- cache the on-tick event handler, because it is ID 0, which causes it to be stored in the hash part, which causes a 50% increase in access time
    on_event = {}, -- list of on_event handlers registered
    on_nth_tick = {}, -- list of on_nth_tick handlers registered
    custom_events = {}, -- names for printing
    -- package handling
    loaded = {}, -- list of files loaded by require() that were installed into the virtual file system
    preload = {},
    searchers = {},
    -- 
    commands = {},
    interfaces = {},
}
--]==]

local function create_proxy_table(table)
    return setmetatable({}, {
        __index = table,
        __pairs = function(t) local function iter(t, k) local v; k, v = next(table, k); if v then return k, t[k] end; end; return iter, t, nil end
    })
end

local function create_readonly_proxy_table(table)
    return setmetatable({}, {
        __index = table,
        __newindex = function(t,k,v) end,
        __pairs = function(t) local function iter(t, k) local v; k, v = next(table, k); if v then return k, t[k] end; end; return iter, t, nil end
    })
end

local function generate_mod_obj(mod)
    local mod_name = mod.name
    local mod_obj = {
        -- references to global table
        mod = mod,
        name = mod_name,
        version = mod.version,
        files = mod.files,
        global = mod.global,
        -- 
        _ENV = {}, -- environment of the mod
        loaded = false,
        running = false,
        -- event handlers
        on_init = nil, -- called once after first install, or when specifically requested to be re-ran (good practice is to never request a re-run)
        on_load = nil, -- called every time the scenario loads from disk
        on_configuration_changed = nil, -- called every time the external mod configuration changes, OR when the hotpatch mod configuration changes
        on_tick = nil, -- cache the on-tick event handler, because it is ID 0, which causes it to be stored in the hash part, which causes a 50% increase in access time
        on_event = {}, -- list of on_event handlers registered
        on_nth_tick = {}, -- list of on_nth_tick handlers registered
        custom_events = {}, -- names for printing
        -- package handling
        loaded = {}, -- list of files loaded by require() that were installed into the virtual file system
        preload = {},
        searchers = {},
        -- 
        commands = {},
        interfaces = {},
    }

    hotpatch_log({'hotpatch-info.script-shim'}, mod_name)
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
                    for _, v in pairs(tick) do
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
                    if f then
                        register_on_tick(mod_name)
                    else    
                        unregister_on_tick(mod_name)
                    end
                end
            else
                mod_obj.on_event[event] = f
                if mod_obj.running then
                    if f then
                        register_event(mod_name, event)
                    else
                        unregister_event(mod_name, event)
                    end
                end
            end
        end
        mod_script.on_nth_tick = function(tick, f)
            if tick then
                if type(tick) == 'table' then
                    for _, v in pairs(tick) do
                        mod_script.on_nth_tick(v, f)
                    end
                    return
                end
                mod_obj.on_nth_tick[tick] = f
                if mod_obj.running then
                    if f then
                        register_nth_tick(mod_name, tick)
                    else
                        unregister_nth_tick(mod_name, tick)
                    end
                end
            else
                local mod_on_nth_tick = mod_obj.on_nth_tick
                mod_obj.on_nth_tick = {}
                if mod_obj.running then
                    for _, v in pairs(mod_on_nth_tick) do
                        unregister_nth_tick(mod_name, v)
                    end
                end
            end
        end
    end
    mod_script.generate_event_name = function()
        local n = script.generate_event_name()
        mod_obj.custom_events[n] = mod_name .. n
        return n
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

    hotpatch_log({'hotpatch-info.setting-env'}, mod_name)

    -- mods private env
    local env = mod_obj._ENV

    -- copy the current environment
    for k,v in pairs(_ENV) do
        env[k] = v
    end
    env._G = env

    -- mods private package
    local package = {}
    env.package = package

    package._current_path_in_package = nil
    package._current_package = mod

    local loaded = {}
    package.loaded = loaded

    local preload = {}
    package.preload = preload

    local searchers = {}
    package.searchers = searchers

    -- copy package.loaded
    for k,v in pairs(_ENV.package.loaded) do
        loaded[k] = v
    end
    loaded._G = env
    loaded.package = package

    local require

    -- first check if we preloaded this module
    searchers[1] = function(modulename)
        local r = preload[modulename]
        if r then
        return r
        end
    end

    -- then check other file systems, if another was specified
    searchers[2] = function(modulename)
        local fs, mn = modulename:match('^__(.-)__%.(.*)$')
        if not fs then
        return nil
        end

        local m = global.mods[fs]
        if not m then
        -- specified mod doesn't exist
        error('mod ' .. fs .. ' doesn\'t exist')
        end


            if m == mod then
                modulename = mn
            else
                package._current_package = m
                package._current_path_in_package = mn:match('^(.*)%.([^.]-)$')
            end

        local result = nil

            local f = m.files[mn]

            if f then
                local func, err = load(f, '[' .. mod_name .. '] ' .. modulename .. '.lua', 'bt', mod_obj._ENV)
                if func then
                    result = func
                    hotpatch_log({'hotpatch-trace.load-require', modulename .. '(2)'}, nil, 4)
                end
            else
                -- specified file doesn't exist
                error('mod ' .. fs .. ' doesn\'t contain file ' .. mn)
            end

        return result, modulename
    end

    -- then check if the current file system contains this module
    searchers[3] = function(modulename)
        local cp = package._current_package
        local cpp = package._current_path_in_package
        if not cp then 
        return nil 
        end
        modulename = ((cpp and (cpp .. '.')) or '') .. modulename
        local path, file = modulename:match('^(.*)%.([^.]-)$')
        if not file then
        file = modulename
        end
        if file == '' then
        file = path
        path = nil
        end

        package._current_path_in_package = path

        local result = nil
        local f = cp.files[modulename]
        if f then
        local func, err = load(f, '[' .. mod_name .. '] ' .. modulename .. '.lua', 'bt', mod_obj._ENV)
        if func then
            result = func
            hotpatch_log({'hotpatch-trace.load-require', modulename .. '(3)'}, nil, 4)
        end
        end
        if cp ~= mod then
        modulename = '__' .. cp.name .. '__.' .. modulename
        end
        return result, modulename
    end

        -- relative to base
    searchers[4] = function(modulename)
        local cp = package._current_package
        local cpp = package._current_path_in_package
        if not cp then 
        return nil 
        end
        local path, file = modulename:match('^(.*)%.([^.]-)$')
        if not file then
        file = modulename
        end
        if file == '' then
        file = path
        path = nil
        end

        package._current_path_in_package = path

        local result = nil
        local f = cp.files[modulename]
        if f then
        local func, err = load(f, '[' .. mod_name .. '] ' .. modulename .. '.lua', 'bt', mod_obj._ENV)
        if func then
            result = func
            hotpatch_log({'hotpatch-trace.load-require', modulename .. '(4)'}, nil, 4)
        end
        end
        if cp ~= mod then
        modulename = '__' .. cp.name .. '__.' .. modulename
        end
        return result, modulename
    end

    -- factorio library
    searchers[5] = function(modulename)
        local lib = _ENV.package.loaded[modulename]
        if lib then
            hotpatch_log({'hotpatch-trace.load-core-lib', modulename}, nil, 4)
            return function() return lib end
        end
    end

    require = function(modulename)
        --local file = modulename:match('%.?([^.]-)$')
        --local path = modulename:match('%.(.*)%.')
        --local mod = modulename:match('^__(.-)__%.')
        modulename = modulename:gsub('[/\\]', '.')
        -- loaded?

            local fs, mn = modulename:match('^__(.-)__%.(.*)$')

            if fs then
                local m = global.mods[fs]
                local r, p
                if m == mod then
                    r = loaded[mn]
                    p = mn                 
                else
                    r = loaded[modulename]    
                    p = modulename
                end
                if r then 
                        hotpatch_log({'hotpatch-trace.cached-load-require', modulename}, nil, 3)
                        hotpatch_log('Requested: ' .. modulename .. ' found: ' .. p);
                        return r 
                end
            end

        local cp = package._current_package
        if cp == mod then cp = nil end
        local cpp = package._current_path_in_package
        local r,path
        path = ((cp and ('__' .. cp.name .. '__.')) or '') .. ((cpp and (cpp .. '.')) or '') .. modulename
        r = loaded[path]    
        if r then 
            hotpatch_log({'hotpatch-trace.cached-load-require', path}, nil, 3)
            hotpatch_log('Requested: ' .. modulename .. ' found: ' .. path);
            return r 
        end

        cpp = nil
        path = ((cp and ('__' .. cp.name .. '__.')) or '') .. ((cpp and (cpp .. '.')) or '') .. modulename
        r = loaded[path]    
        if r then 
            hotpatch_log({'hotpatch-trace.cached-load-require', path}, nil, 3)
            hotpatch_log('Requested: ' .. modulename .. ' found: ' .. path);
            return r
        end

        -- not loaded, find it
        local old_package = package._current_package
        local old_path = package._current_path_in_package

        for i = 1, #package.searchers do
            local r,p = package.searchers[i](modulename)
            if r then
                p = p or modulename
                r = r() or true
                loaded[p] = r
                hotpatch_log('Requested: ' .. modulename .. ' found: ' .. p);

                package._current_path_in_package = old_path
                package._current_package = old_package
                return r
            end
        end
        hotpatch_log({'hotpatch-error.module-not-found', modulename}, nil, 3)
        error('module ' .. modulename .. ' not found')
    end

    env.require = require

    env.script = setmetatable({}, {
        __index = mod_script,
        __pairs = function(t) local function iter(t, k) local v; k, v = next(mod_script, k); if v then return k, t[k] end; end; return iter, t, nil end
    })
    env.global = mod.global

    env['remote'] = {
        add_interface = function(name, functions)
            if remote.interfaces[name] then
                hotpatch_log({'hotpatch-warning.remote-interface-exists', name}, mod_name)
                remote.remove_interface(name)
            end
                        hotpatch_log({'hotpatch-info.adding-remote', name}, mod_name)
            remote.add_interface(name, functions)
            mod_obj.interfaces[name] = true
        end,
        remove_interface = function(name)
            mod_obj.interfaces[name] = nil
                        hotpatch_log({'hotpatch-info.removing-remote', name}, mod_name)
            return remote.remove_interface(name)
        end,
        call = function(...)
            return remote.call(...)
        end,
        interfaces = setmetatable({}, {
            __index = function(_, k) return remote.interfaces[k] end,
            __pairs = function(t) local function iter(t, k) local v; k, v = next(remote.interfaces, k); if v then return k, t[k] end; end; return iter, t, nil end
        })
    }

    env['commands'] = {
        add_command = function(name, help, func)
            if commands.commands[name] then
                hotpatch_log({'hotpatch-warning.command-exists', name}, mod_name)
                commands.remove_command(name)
            end
            hotpatch_log({'hotpatch-info.adding-command', name}, mod_name)
            commands.add_command(name, help, func)
            mod_obj.commands[name] = true
        end,
        remove_command = function(name)
            mod_obj.commands[name] = nil
                        hotpatch_log({'hotpatch-info.removing-command', name}, mod_name)
            return commands.remove_command(name)
        end,
        commands = setmetatable({}, {
            __index = function(_, k) return commands.commands[k] end,
            __pairs = function(t) local function iter(t, k) local v; k, v = next(commands.commands, k); if v then return k, t[k] end; end; return iter, t, nil end
        }),
        game_commands = setmetatable({}, {
            __index = function(_, k) return commands.game_commands[k] end,
            __pairs = function(t) local function iter(t, k) local v; k, v = next(commands.game_commands, k); if v then return k, t[k] end; end; return iter, t, nil end
        })
    }

    env['load'] = function(l, s, m, e)
        return load(l, s, m, e or env)
    end
    env['loadstring'] = env['load']


    env['game'] = setmetatable({}, {
        __index = function(_, k) return game[k] end,
        __pairs = function(t) local function iter(t, k) local v; k, v = next(game, k); if v then return k, t[k] end; end; return iter, t, nil end
    })

    local mt = {}
        local umt

        env['setmetatable'] = function(t, metat)
            if t == env then
                umt = metat
                return t
            end
            return setmetatable(t, metat)
        end

    mt.__index = function(t, k)
        hotpatch_log({'hotpatch-trace.nil-var-access', k}, nil, 3)
                if umt then
                    local index = umt.__index

                    if type(index) == 'function' then
                        return index(t,k)
                    else
                        return index[k]
                    end

                end
    end
    mt.__newindex = function(t, k, v)
        hotpatch_log({'hotpatch-trace.nil-var-assignment', k}, nil, 3)
                if umt then
                    local newindex = umt.__newindex

                    if type(newindex) == 'function' then
                        return newindex(t,k,v)
                    else
                        newindex[k] = v
                        return
                    end

                end
        rawset(t,k,v)
    end

    mt.__metatable = umt
    setmetatable(env, mt)
    return mod_obj
end
return generate_mod_obj