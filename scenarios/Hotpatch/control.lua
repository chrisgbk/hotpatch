--[[

Copyright 2018 Chrisgbk
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

]]
-- MIT License, https://opensource.org/licenses/MIT

-- Hotpatchable control.lua for scenarios
-- Supports multiple simultaneously loaded softmods
-- This is a WIP
-- Version 1.1 alpha
-- probably some performance improvements to be made

-- convenience object(rcon.print also prints to stdout when called from server console)
-- only usable from events
_ENV.console = {name = 'Console', admin = true, print = function(...) rcon.print(...) end, color = {1,1,1,1}}

-- Available options: 'disabled' 'severe' 'error' 'warning' 'info' 'verbose' 'trace'
_ENV.hotpatch_log_settings = global.hotpatch_log_settings or 
{
    level = 'trace',
    log_to_console_only = false, --uses print
    log_to_RCON = false, --only affects when log_to_console_only is in effect
    log_on_tick = false, --enable or disable logging of on_tick when tracing
}

-- changes load/run execution of mods
_ENV.hotpatch_settings = 
{
    compat_mode = false, -- enable some compatibility settings, which can help some mods load. In theory. Old and untested.
    strict_mode = false -- causes hotpatch to hard-stop on mods doing bad things. currently undefined what those bad things are
}

-- Libraries required at runtime. This list may need to be modified, as hotpatch must load
-- every library during startup. Some libraries are not compatible and must be loaded per-mod inside the mod.
-- This includes mod libraries, like __stdlib__/stdlib/misc/logger
-- 'util' is already required by hotpatch internally
_ENV.hotpatch_libraries = 
{
    'camera',
    'flying_tags',
    'kill-score',--require
    'math2d',
    'math3d',
    'mod-gui',--require
    --'noise',
    'production-score',--require
    'silo-script', --handler_lib
    'story',--require
    'story_2', --handler_lib
}

local hotpatch_tools = require 'hotpatch.core'
_ENV.hotpatch_tools = hotpatch_tools
require 'hotpatch.plugin-remote_interface'
require 'hotpatch.plugin-commands'
require 'hotpatch.plugin-gui'

-- mod code goes here

--require 'freeplay-static'

-- end of mod code