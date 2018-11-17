local hotpatch_tools = require 'hotpatch.mod-tools'
hotpatch_tools.static_mod('hotpatch-gui', '1.0.0', [===[
--[[

Copyright 2018 Chrisgbk
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

]]
-- MIT License, https://opensource.org/licenses/MIT

local hotpatch_tools = require 'hotpatch.mod-tools'
local mod_gui = require 'mod-gui'

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
local loaded_mods = hotpatch_tools.loaded_mods
local installed_mods = hotpatch_tools.installed_mods

script.on_event(defines.events.on_player_joined_game, function(e)
    local player = game.players[e.player_index]
    local top = mod_gui.get_button_flow(player)
    local left = mod_gui.get_frame_flow(player)
    local center = player.gui.center
    
    local button = top.add{type = 'button', name = 'hotpatch-button', caption = 'HP', tooltip = 'Hotpatch'}
end)

script.on_event(defines.events.on_player_left_game, function(e)
    local player = game.players[e.player_index]
    local top = mod_gui.get_button_flow(player)
    local left = mod_gui.get_frame_flow(player)
    local center = player.gui.center
    
    local button = top['hotpatch-button']
    button.destroy()
    
    local menu = left['hotpatch-menu']
    if menu then 
        menu.destroy()
    end
    
    local main = center['hotpatch-main']
    if main then 
        main.destroy()
    end
end)

local on_gui_click_handlers
local on_gui_selection_state_changed_handlers

on_gui_click_handlers = {
    ['hotpatch-button'] = function(e)
        on_gui_click_handlers['hotpatch-menu-launch_GUI'](e)
        do return end
        local player = game.players[e.player_index]
        local top = mod_gui.get_button_flow(player)
        local left = mod_gui.get_frame_flow(player)
        local center = player.gui.center
        
        local menu = left['hotpatch-menu']
        if not menu then
            menu = left.add{type = 'frame', name = 'hotpatch-menu', direction = 'vertical'}
            menu.add{type = 'button', name = 'hotpatch-menu-launch_GUI', caption = 'Toggle IDE', tooltip = 'Open debugging GUI'}
            menu.add{type = 'button', name = 'hotpatch-menu-close', caption = 'Close Menu'}
            menu.style.visible = true
            return
        end
        menu.style.visible = not menu.style.visible
    end,
    ['hotpatch-menu-launch_GUI'] = function(e)
        local player = game.players[e.player_index]
        local top = mod_gui.get_button_flow(player)
        local left = mod_gui.get_frame_flow(player)
        local center = player.gui.center
        
        local main = center['hotpatch-main']
        if not main then
            main = center.add{type = 'frame', name = 'hotpatch-main', direction = 'vertical', caption = 'Hotpatch IDE'}
            local top_flow = main.add{type = 'flow', name = 'hotpatch-main-top', direction = 'horizontal'}
            top_flow.add{type = 'label', name = 'hotpatch-mod-label', caption = 'Choose mod'}
            local main_dropdown = top_flow.add{type = 'drop-down', name = 'hotpatch-mod-selector'}
            local main_table = main.add{type = 'table', name = 'hotpatch-main-table', column_count = 2}
            local files = main_table.add{type = 'scroll-pane', name = 'hotpatch-files', direction='vertical'}
            files.style.height = 600
            files.vertical_scroll_policy = 'always'
            files = files.add{type = 'table', name = 'hotpatch-files-table', column_count = 1}
            local code = main_table.add{type = 'text-box', name = 'hotpatch-code'}
            code.word_wrap = true
            files.style.width = 400
            files.style.cell_spacing = 0
            files.style.top_padding = 0
            files.style.bottom_padding = 0
            code.style.width = 600
            code.style.height = 600
            main.style.visible = false
        end
        
        local main_dropdown = main['hotpatch-main-top']['hotpatch-mod-selector']
        main_dropdown.clear_items()
        for k, v in ipairs(installed_mods) do
            main_dropdown.add_item(v.name)
        end
            
        main.style.visible = not main.style.visible
    end,
    ['hotpatch-menu-close'] = function(e)
        on_gui_click_handlers['hotpatch-button'](e)
    end,
    ['hotpatch-file'] = function(e)
        local player = game.players[e.player_index]
        local top = mod_gui.get_button_flow(player)
        local left = mod_gui.get_frame_flow(player)
        local center = player.gui.center
    
        local element = e.element
        local previous
        for k, v in pairs(center['hotpatch-main']['hotpatch-main-table']['hotpatch-files']['hotpatch-files-table'].children) do
            if table.compare(v.style.font_color or {}, {r=1.0, g=1.0, b=0.0, a=1.0}) then
                previous = v
                break
            end
        end
        if previous then
            previous.style.font_color = {r=1.0, g=1.0, b=1.0, a=1.0}
        end
        element.style.font_color = {r=1.0, g=1.0, b=0.0, a=1.0}
        local file = element.name:match('.-%.(.*)')
        local selected = center['hotpatch-main']['hotpatch-main-top']['hotpatch-mod-selector']
        local mod_name = selected.items[selected.selected_index]
        local code = center['hotpatch-main']['hotpatch-main-table']['hotpatch-code']
        local index = find_installed_mod(mod_name)
        if index then
            local mod = installed_mods[index]
            if file == 'control' then
                code.text = mod.code
            else
                code.text = mod.files[file]
            end
        end
    end,
}

script.on_event(defines.events.on_gui_click, function(e)
    local element = e.element
    if element.valid then
        local name = element.name:match('([^%.]*)%.?.-')
        local handler = on_gui_click_handlers[name]
        if handler then handler(e) end
    end
end)

on_gui_selection_state_changed_handlers = {
    ['hotpatch-mod-selector'] = function(e)
        local player = game.players[e.player_index]
        local top = mod_gui.get_button_flow(player)
        local left = mod_gui.get_frame_flow(player)
        local center = player.gui.center
        
        local element = e.element
        
        local name = element.items[element.selected_index]
        if name then
            local index = find_installed_mod(name)
            if index then
                local mod = installed_mods[index]
                local list = center['hotpatch-main']['hotpatch-main-table']['hotpatch-files']['hotpatch-files-table']
                list.clear()
                local file = list.add{type = 'label', caption = 'control', name = 'hotpatch-file.control'}
                file.style.bottom_padding = 0
                file.style.top_padding = 0
                for k, v in pairs(mod.files) do
                    file = list.add{type = 'label', caption = k, name = 'hotpatch-file.' .. k}
                    file.style.bottom_padding = 0
                    file.style.top_padding = 0
                end
                local code = center['hotpatch-main']['hotpatch-main-table']['hotpatch-code']
                code.text = ''
            end
        end
    end,
}

script.on_event(defines.events.on_gui_selection_state_changed, function(e)
    local element = e.element
    local handler = on_gui_selection_state_changed_handlers[element.name]
    if handler then handler(e) end
end)

]===])

return true