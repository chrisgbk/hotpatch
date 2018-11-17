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

_ENV.debug_settings = {
    level = 'info',
    log_to_console_only = false,
    log_to_RCON = false,
    log_on_tick = false,
}

local hotpatch_tools = require 'hotpatch.mod-tools'
require 'hotpatch.remote-interface'
require 'hotpatch.commands'
require 'hotpatch.gui'

-- mod code goes here

-- Single-file test
--[[
hotpatch_tools.static_mod('test', '1.0.0', [===[
    script.on_init(function()
        log('test')
    end)
]===])
--]]

-- Multi-file test
--[[
local files = {}

files['testfolder.anothertest.test'] = [===[
    script.on_event(defines.events.on_player_changed_position, function(e) game.print('position changed') end)
]===]

files['testfolder.test'] = [===[
    require 'anothertest.test'
]===]

files['test'] = [===[
    require 'testfolder.test' 
]===]

hotpatch_tools.static_mod('require-test', '1.0.0', [===[
    require 'test'
]===], files)
--]]

-- end of mod code

hotpatch_tools.restore_log()