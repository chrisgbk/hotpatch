--[[

Copyright 2018 Chrisgbk
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

]]
-- MIT License, https://opensource.org/licenses/MIT

local hotpatch_tools = require 'hotpatch.mod-tools'

--load private API
-- mod installation/uninstallation support functions
-- These take a mod NAME as a first argument
local install_mod = hotpatch_tools.install_mod
local find_installed_mod = hotpatch_tools.find_installed_mod
local install_mod_file = hotpatch_tools.install_mod_file
local uninstall_mod = hotpatch_tools.uninstall_mod

-- mod interaction functions
-- These take a LOADED INDEX as a first argument, except load_mod, which takes an INSTALLED INDEX
local load_mod = hotpatch_tools.load_mod
local find_loaded_mod = hotpatch_tools.find_loaded_mod
local run_mod = hotpatch_tools.run_mod
local reset_mod = hotpatch_tools.reset_mod
local reset_mod_events = hotpatch_tools.reset_mod_events
local register_mod_events = hotpatch_tools.register_mod_events
local unload_mod = hotpatch_tools.unload_mod

-- internal callbacks when a mod registers events
local register_event = hotpatch_tools.register_event
local register_nth_tick = hotpatch_tools.register_nth_tick
local register_on_tick = hotpatch_tools.register_on_tick

-- mod bootstrap functions
-- These take a LOADED INDEX as a first argument
local mod_on_init = hotpatch_tools.mod_on_init
local mod_on_load = hotpatch_tools.mod_on_load
local mod_on_configuration_changed = hotpatch_tools.mod_on_configuration_changed

local console = hotpatch_tools.console
local debug_log = hotpatch_tools.debug_log

local commands = {}

return commands