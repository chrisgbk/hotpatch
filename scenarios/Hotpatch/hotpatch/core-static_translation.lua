--[[

Copyright 2018 Chrisgbk
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

]]
-- MIT License, https://opensource.org/licenses/MIT

-- Hotpatch-MultiMod: a tool to load multiple scenarios side-by-side, with support for both static loading and dynamic loading, as well as run-time patching

local static_cfg = [[
[hotpatch]
log=@__1__:__2__] __3__
log-mod=@__1__:__2__ >__4__<] __3__
severe=SEVERE ERROR: __1__
error=ERROR: __1__
warning=WARNING: __1__
info=INFO: __1__
verbose=INFO: __1__
trace=TRACE: __1__

[hotpatch-info]
logging-enabled=Logging enabled
metatable-installed=_ENV metatable installed
complete=__1__ Complete!
on-init=initializing...
on-load=loading...
on-configuration-changed=mod configuration changed...
installing-included-mods=installing included mods...
loading-installed-mods=loading installed mods...
loading-libs=loading Factorio.data.core.lualib...
loading-library=loading library: __1__
uninstalling=Uninstalling mod...
installing=Installing version __1__...
installing-file=Installing file __1__...
script-shim=setting up mod script shim...
setting-env=setting up mod _ENV...
loading=loading...
unloading=unloading...
running=running...
must-be-admin=You must be an admin to run this command
remote-installing=installing remote interface

[hotpatch-trace]
nil-var-access=_ENV nil variable access: __1__
nil-var-assignment=_ENV variable assignment: __1__
event-registering=registering events...
on-tick-event-registered=registered on_tick event...
on-event-registered=registered event __1__...
on-nth-tick-event-registered=registered nth_tick event __1__...
on-tick-event-unregistered=unregistered on_tick event...
on-event-unregistered=unregistered event __1__...
on-nth-tick-event-unregistered=unregistered nth_tick event __1__...
event-running=running event __1__...
nth-tick-event-running=running nth_event __1__...
mod-on-init=running on_init...
mod-on-load=running on_load...
mod-on-configuration-changed=running on_configuration_changed...
adding-event=adding event __1__
adding-nth-tick-event=adding nth_tick event __1__
caching-event=caching event: __1__...
caching-nth-tick-event=caching nth_tick event: __1__...
event-processing=processing event __1__...
nth-tick-event-processing=processing nth_tick event __1__...
nth-tick-handler-added=added nth_tick handler: __1__
nth-tick-handler-removed=removed nth_tick handler: __1__
on-tick-handler-added=added on_tick handler
on-tick-handler-removed=removed on_tick handler
on-event-handler-added=added event handler: __1__
on-event-handler-removed=removed event handler: __1__
cached-load-require=loading cached require'd file: __1__...
load-require=loading require'd file: __1__...
load-core-lib=loading from Factorio.data.core.lualib: __1__...

[hotpatch-warning]
contains-comments=mod code contains comments!
contains-comments-no-lf=mod contains comments and no linefeed!
contains-comments-console=comments from console will comment out the entire code!
reset-events-not-running=tried to reset events for mod that isn't running!
remote-interface-exists=remote interface __1__ already exists, removing...
command-exists=command __1__ already exists, removing...
already-exists=mod already exists: __1__ __2__
reinstalling=reinstalling mod in-place: __1__ __2__
already-loaded=mod already loaded: __1__ __2__
reinitializing=reinitializing: __1__ __2__

[hotpatch-error]
invalid-API-access=Invalid API access: __1__
not-installed=mod not installed, cannot install file for mod that does not exist
compilation-failed=compilation failed for mod
execution-failed=execution failed for mod
path-not-found=path '__1__' not found
on-init-failed=on_init failed
on-load-failed=on_load failed
on-configuration-changed-failed=on_configuration_changed failed

[test-pluralization]
test=__1:(^1$)=singular;(^[2-9]$)=plural single digit;([1-2][0-9]$)=plural ends with double digit <30;(.*)=fallback case%; plural with embedded %;;__
]]

local function build_locale(ini)
    local t = {}
    local section = ''
    local temp

    -- line must end with a linefeed - single line file with no LF will fail
    if not ini:match('[\r\n]+$') then
        ini = ini .. '\n'
    end

    -- for each non-empty line do
    local key, value
    for l in ini:gmatch('[\r\n]*(.-)[\r\n]+') do
        -- header?
        temp = l:match('^%[(.-)%].*$')
        if temp then
            section = temp
            temp = nil
        else
            --key=value
            key, value = l:match('^(.-)=(.+)$')
            t[table.concat{section, '.', key}] = value
        end
    end
    return t
end

local static_locale = build_locale(static_cfg)

local function escape(s)
    return (s:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1'))
end

local function unescape(s)
    return (s:gsub('(%%)', ''))
end

local function static_translate(t, recursive)
    -- only translate tables
    if type(t) ~= 'table' then return t end
    -- only translate tables that have a string as the first item
    local k = t[1]
    if type(k) ~= 'string' then return t end

    -- make a copy, don't destroy the original table, after we copy we can translate in place
    if not recursive then
        t = table.deepcopy(t)
    end
    -- translate any arguments as well
    local v
    for i = 2, #t do
        v = t[i]
        if type(v) == 'table' then
            t[i] = static_translate(v, true)
        end
    end
    -- special case: whitespace token causes concatenation with that token
    -- slightly better than factorio, where only '' is supported
    if k:find('^%s*$') then table.remove(t, 1) return table.concat(t, k) end
    local pattern = static_locale[k]
    -- if not translatable return normal table ref; factorio does following instead:
    -- if not pattern then return 'Unknown key: ' .. k end
    -- by returning the table we pass off to factorio runtime translation, where available
    if not pattern then return t end
    -- substitution of parameters: use literal value of parameter n
    -- __n__
    local result = (pattern:gsub('__(%d+)__', function(s) return tostring(t[tonumber(s)+1]) end))

    -- re-substitution engine: match value of parameter n to provide additional translation; use for pluralization
    -- __n:(pattern-1)=substitution-1;(pattern-2)=substitution-2;...(pattern-i)=substitution-i;__
    for n, p in result:gmatch('__(%d+)(:.-;)__') do
        for x, y in p:gmatch('%((.-)%)=(.-[^%%]);') do
            if t[tonumber(n)+1]:match(x) then
                result = result:gsub(table.concat{'__', n, escape(p), '__'}, unescape(y))
                break
            end
        end
    end

    return result
end

return static_translate