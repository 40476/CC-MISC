local lib = require("modemLib")

-- 1. Initialize
local parentTerm = term.current()
local w, h = parentTerm.getSize()
parentTerm.clear()
parentTerm.setCursorPos(1, 1)
print("Starting strict secure terminal wrapper...")

local modem = peripheral.find("modem")
if not modem then
    error("Security Fault: Modem missing!", 0)
end

lib.connect(peripheral.getName(modem))

local config = nil

while not config do
    parentTerm.clear()
    parentTerm.setCursorPos(1, 1)
    print("Fetching secure login settings from server...")
    
    local serverConfig = lib.getConfig()
    
    -- Verify we got a real table back from the server with actual data
    if serverConfig and type(serverConfig) == "table" then
        -- Case 1: The server returned the full raw config dump with .value fields
        if serverConfig.passwordProtection and serverConfig.passwordProtection.timeout then
            config = {
                enabled = serverConfig.passwordProtection.enabled.value,
                timeout = serverConfig.passwordProtection.timeout.value,
                password = serverConfig.passwordProtection.password.value
            }
            print("Server settings verified and loaded.")
        -- Case 2: The server returned the simplified config table
        elseif type(serverConfig.timeout) == "number" then
            config = {
                enabled = serverConfig.enabled,
                timeout = serverConfig.timeout,
                password = serverConfig.password
            }
            print("Server settings verified and loaded.")
        else
            print("Security Lockdown: Invalid config format received.")
            print("Retrying in 3 seconds...")
            os.sleep(3)
        end
    else
        print("Security Lockdown: Server unreachable or spoofed data received.")
        print("Retrying in 3 seconds...")
        os.sleep(3)
    end
end
 
os.sleep(1)
 
-- 3. State Variables
local isLocked = false
local enteredPass = ""
local wrongPass = false
 
-- Create a dedicated virtual window for the application
local appWin = window.create(parentTerm, 1, 1, w, h, true)
 
-- 4. Lock Screen Renderer
local function drawLockScreen()
    parentTerm.setBackgroundColor(colors.black)
    parentTerm.clear()
 
    local boxW, boxH = 26, 9
    local x = math.floor((w - boxW) / 2) + 1
    local y = math.floor((h - boxH) / 2) + 1
 
    -- Draw popup window body
    for i = 0, boxH - 1 do
        parentTerm.setCursorPos(x, y + i)
        parentTerm.setBackgroundColor(colors.gray)
        parentTerm.write(string.rep(" ", boxW))
    end
 
    -- Draw text
    parentTerm.setCursorPos(x + 4, y + 1)
    parentTerm.setTextColor(colors.white)
    parentTerm.write(" TERMINAL LOCKED ")
 
    parentTerm.setCursorPos(x + 2, y + 3)
    parentTerm.write("Password:")
 
    -- Draw password field
    parentTerm.setCursorPos(x + 2, y + 4)
    parentTerm.setBackgroundColor(colors.black)
    local passStr = string.rep("*", #enteredPass)
    parentTerm.write(passStr .. string.rep(" ", 22 - #enteredPass))
 
    -- Draw error message if needed
    if wrongPass then
        parentTerm.setCursorPos(x + 2, y + 6)
        parentTerm.setBackgroundColor(colors.gray)
        parentTerm.setTextColor(colors.red)
        parentTerm.write("Incorrect Password!")
    end
 
    parentTerm.setCursorPos(x + 2 + #enteredPass, y + 4)
    parentTerm.setCursorBlink(true)
end
 
-- 5. Application Coroutine Manager
local timeoutTimer = os.startTimer(config.timeout)
 
-- Start the terminal in an isolated coroutine
local co = coroutine.create(function()
    shell.run("terminal.lua")
end)
 
-- These events will be blocked from reaching the app while the terminal is locked
local blockedEvents = {
    key = true, key_up = true, char = true,
    mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true,
    terminate = true
}
 
term.redirect(appWin)
local ok, filter = coroutine.resume(co)
if not ok then
    term.redirect(parentTerm)
    error(filter)
end
 
-- Main Event Loop
while coroutine.status(co) ~= "dead" do
    local ev = { os.pullEventRaw() }
    local evType = ev[1]
 
    -- Update activity timer on physical inputs
    if blockedEvents[evType] and evType ~= "terminate" then
        if config.enabled and not isLocked then
            os.cancelTimer(timeoutTimer)
            timeoutTimer = os.startTimer(config.timeout)
        end
    elseif evType == "timer" and ev[2] == timeoutTimer then
        if config.enabled then
            isLocked = true
            appWin.setVisible(false) -- Hide the application window cleanly
            drawLockScreen()
        end
    end
 
    if isLocked then
        -- Handle lock screen inputs exclusively
        if evType == "char" then
            if #enteredPass < 22 then
                enteredPass = enteredPass .. ev[2]
                wrongPass = false
            end
            drawLockScreen()
        elseif evType == "key" then
            if ev[2] == keys.backspace and #enteredPass > 0 then
                enteredPass = enteredPass:sub(1, -2)
                wrongPass = false
                drawLockScreen()
            elseif ev[2] == keys.enter then
                if enteredPass == config.password then
                    isLocked = false
                    enteredPass = ""
                    wrongPass = false
                    
                    parentTerm.setCursorBlink(false)
                    appWin.setVisible(true)
                    appWin.redraw()
                    appWin.restoreCursor()
                    
                    os.cancelTimer(timeoutTimer)
                    timeoutTimer = os.startTimer(config.timeout)
                else
                    wrongPass = true
                    enteredPass = ""
                    drawLockScreen()
                end
            end
        end
        
        -- Forward only NON-UI events (modems, redstone, background timers) to the app
        if not blockedEvents[evType] then
            if filter == nil or filter == evType or evType == "terminate" then
                term.redirect(appWin)
                ok, filter = coroutine.resume(co, table.unpack(ev))
                if not ok then
                    term.redirect(parentTerm)
                    error(filter)
                end
            end
        end
    else
        -- Terminal is unlocked, forward ALL events normally
        if filter == nil or filter == evType or evType == "terminate" then
            term.redirect(appWin)
            ok, filter = coroutine.resume(co, table.unpack(ev))
            if not ok then
                term.redirect(parentTerm)
                error(filter)
            end
        end
    end
end
 
-- 6. Cleanup when closed
term.redirect(parentTerm)
parentTerm.clear()
parentTerm.setCursorPos(1, 1)