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
--]==]

local function generate_mod_obj(mod)
    local mod_name = mod.name
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
        custom_events = {}
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
                    register_on_tick(mod_name)
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
                    for _, v in pairs(tick) do
                        mod_script.on_nth_tick(v, f)
                    end
                    return
                end
                mod_obj.on_nth_tick[tick] = f
                if mod_obj.running then
                    register_nth_tick(mod_name, tick)
                end
            else
                local mod_on_nth_tick = mod_obj.on_nth_tick
                mod_obj.on_nth_tick = {}
                if mod_obj.running then
                    for _, v in pairs(mod_on_nth_tick) do
                        register_nth_tick(mod_name, v)
                    end
                end
            end
        end
    end
    mod_script.generate_event_name = function()
        local n = script.generate_event_name()
        custom_events[n] = mod_name .. n
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

    -- TODO: add support for tracking which remote interfaces have been added to cleanup
    env['remote'] = {
        add_interface = function(name, functions)
            if remote.interfaces[name] then
                hotpatch_log({'hotpatch-warning.remote-interface-exists', name}, mod_name)
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
            __index = function(_, k) return remote.interfaces[k] end,
            __pairs = function(t) local function iter(t, k) local v; k, v = next(remote.interfaces, k); if v then return k, t[k] end; end; return iter, t, nil end
        })
    }

    -- TODO: add support for tracking which commands have been added to cleanup
    env['commands'] = {
        add_command = function(name, help, func)
            if commands.commands[name] then
                hotpatch_log({'hotpatch-warning.command-exists', name}, mod_name)
                commands.remove_command(name)
            end
            commands.add_command(name, help, func)
        end,
        remove_command = function(name)
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


    env.require = function(path)
        -- I blame Nexela for this
        path = path:gsub('/', '.')
        path = path:gsub('\\', '.')
        local alt_path = ''
        if env.package._current_path_in_package then
            alt_path = env.package._current_path_in_package .. path
        end
        if mod_obj.loaded_files[path] then
            hotpatch_log({'hotpatch-trace.cached-load-require', path}, mod_name)
            return mod_obj.loaded_files[path]
        elseif mod_obj.loaded_files[alt_path] then
            hotpatch_log({'hotpatch-trace.cached-load-require', alt_path}, mod_name)
            return mod_obj.loaded_files[alt_path]
        else
            local oldbase = env.package._current_path_in_package
            env.package._current_path_in_package = path:match('.+%..+%.')
            if not env.package._current_path_in_package then
                 env.package._current_path_in_package = path:match('.+%.')
            end
            local file = mod.files[path]
            if file then
                hotpatch_log({'hotpatch-trace.load-require', path}, mod_name)
                local code, err = load(file, '[' .. mod_name .. '] ' .. path .. '.lua', 'bt', env)
                if code then
                    local result = code()
                    mod_obj.loaded_files[path] = result or true
                    env.package._current_path_in_package = oldbase
                    return mod_obj.loaded_files[path]
                else
                    hotpatch_log(err, nil, 3)
                    error(err)
                end
            end
            file = mod.files[alt_path]
            if file then
                hotpatch_log({'hotpatch-trace.load-require', alt_path}, mod_name)
                local code, err = load(file, '[' .. mod_name .. '] ' .. alt_path .. '.lua', 'bt', env)
                if code then
                    local result = code()
                    mod_obj.loaded_files[alt_path] = result or true
                    env.package._current_path_in_package = oldbase
                    return mod_obj.loaded_files[alt_path]
                else
                    hotpatch_log(err, nil, 3)
                    error(err)
                end
            end

            hotpatch_log({'hotpatch-trace.load-core-lib', path}, mod_name)
            env.package._current_path_in_package = oldbase
            local lib = package.loaded[path]
            if not lib then
                hotpatch_log({'hotpatch-error.path-not-found', path}, mod_name, 3)
                error(path .. ' not found')
            end
            return lib
        end
    end

    env['load'] = function(l, s, m, e)
        return load(l, s, m, e or env)
    end
    env['loadstring'] = env['load']


    env['game'] = setmetatable({}, {
        __index = function(_, k) return game[k] end,
        __pairs = function(t) local function iter(t, k) local v; k, v = next(game, k); if v then return k, t[k] end; end; return iter, t, nil end
    })

    local mt = {}
    mt.__index = function(_, k)
        hotpatch_log({'hotpatch-trace.nil-var-access', k}, nil, 3)
        return nil
    end
    mt.__newindex = function(t, k, v)
        hotpatch_log({'hotpatch-trace.nil-var-assignment', k}, nil, 3)
        rawset(t,k,v)
    end
    -- Don't let mods break this
    -- TODO: support mods being able to set their own metatable
    mt.__metatable = false
    setmetatable(env, mt)
    return mod_obj
end
return generate_mod_obj