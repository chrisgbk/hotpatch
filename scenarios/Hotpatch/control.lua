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
_ENV.hotpatch_log_settings = global.hotpatch_log_settings or {
    level = 'trace',
    log_to_console_only = false,
    log_to_RCON = false,
    log_on_tick = false,
}

local hotpatch_tools = require 'hotpatch.core'
require 'hotpatch.plugin-remote_interface'
require 'hotpatch.plugin-commands'
require 'hotpatch.plugin-gui'

-- mod code goes here

require 'freeplay-static'

-- end of mod code