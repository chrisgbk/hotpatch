--[[

Copyright 2018 Chrisgbk
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

]]

-- This scenario contains a scenario locale, but it's unavailable until control.lua finishes loading
-- ie: calls to log{...} will fail right now, but will work in events
-- Rseding91 said he fixed it for 0.17 (https://forums.factorio.com/viewtopic.php?f=23&t=60767)
-- Nope, still broken in 0.17
-- Also, locale isn't loaded from an existing save until on_init finishes
-- That means locales aren't available in control.lua processing or on_load, only on_init and every other event????
-- I'll make it work myself in 0.16 and 0.17 ¯\_(ツ)_/¯

local hotpatch_log_levels = {['disabled'] = -1, ['severe'] = 1, ['error'] = 2, ['warning'] = 3, ['info'] = 4, ['verbose'] = 5, ['trace'] = 6}

local hotpatch_log_level
local hotpatch_log_to_console_only
local hotpatch_log_to_RCON
local hotpatch_log_on_tick 

local function get_hotpatch_log_settings()
    return
    {
        hotpatch_log_level = hotpatch_log_level,
        hotpatch_log_to_console_only = hotpatch_log_to_console_only,
        hotpatch_log_to_RCON = hotpatch_log_to_RCON,
        hotpatch_log_on_tick = hotpatch_log_on_tick
    }
end

local function set_hotpatch_log_settings(settings)
    hotpatch_log_level = (tonumber(settings.level) or hotpatch_log_levels[settings.level]) or 0
    hotpatch_log_to_console_only = settings.log_to_console_only
    hotpatch_log_to_RCON = settings.log_to_RCON
    if hotpatch_log_on_tick ~= settings.log_on_tick then
        --TODO: handle run time log setting changes
    end
    hotpatch_log_on_tick = settings.log_on_tick
    global.hotpatch_log_settings = get_hotpatch_log_settings()
end
set_hotpatch_log_settings(global.hotpatch_log_settings or _ENV.hotpatch_log_settings or {})

local static_translate = require 'core-static_translation'

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

-- help log to make it support our translation efforts during control.lua processing and
-- any unknown keys are passed to Factorio to translate

local hide_log = load([===[
    local real_log = log; local static_translate = select(1, ...); local log = function(...); if select('#', ...) == 1 then real_log(static_translate(...)) else local t = table.pack(...); table.insert(t, 1, '\t'); real_log(static_translate(t)) end end return log
]===], '[HOTPATCH')
local hidden_log = hide_log(static_translate)

-- logs localized data
local function hotpatch_log(message, mod_name, stack_level)
    if hotpatch_log_level > -1 then
        if not stack_level then stack_level = 2 end
        local di = debug.getinfo(stack_level)
        local name = di.name
        if name and name:match('pcall') then
            di = debug.getinfo(stack_level + 1) 
        end
        local line = di.currentline
        local file = (di.source:gsub('%@.*[/\\]currently%-playing[/\\]', ''))

        local class = 'hotpatch.info'
        local log_type = (mod_name and 'hotpatch.log-mod') or 'hotpatch.log'
        local severity
        if type(message) == 'table' then
            severity = message[1]:match('.-%-([^%-]*)%.')
            if not severity then
                severity = message[1]:match('.-%-.-%-(.*)%.')
                if not severity then
                    severity = 'always'
                end
            end
            class = table.concat{'hotpatch', '.', severity}
        else
            severity = 'always'
        end
        local level = ((severity == 'always') and 0) or hotpatch_log_levels[severity]
        if hotpatch_log_level >= level then
            if hotpatch_log_to_console_only then
                if hotpatch_log_to_RCON then
                    rcon.print{log_type, file, line, {class, message}, mod_name}
                end
                print{log_type, file, line, {class, message}, mod_name}

            else
                hidden_log{log_type, file, line, {class, message}, mod_name}
            end
        end
    end
end

local function restore_logging()
    hidden = load([===[
        return function(...) log(...) end
    ]===], '[HOTPATCH')
    hidden_log = hidden()
end

return setmetatable({
    log = hotpatch_log, 
    set_hotpatch_log_settings = set_hotpatch_log_settings,
    get_hotpatch_log_settings = get_hotpatch_log_settings,
    restore_logging = restore_logging
}, {
    __call = function(...) return hotpatch_log(...) end
})