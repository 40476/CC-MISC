--[[
  CC:Tweaked Farmer Turtle (Enhanced Edition)
  Integrates natively with CC-MISC modems/inventories.
  Features: Disk persistence, auto-tilling, infinite GPS retry, obstacle avoidance limits, and 100% crash-proof pcall wrapping.
]]--

local modemLib = require("modemLib")

local STATE_FILE = "farmer_state.dat"

-- Global States
local myNetworkName = nil
local isRefueling = false
local posX, posY = 0, 0
local facing = 0 -- 0: +x (forward), 1: +y (right), 2: -x (back), 3: -y (left)

-- Forward declarations
local checkFuel, goRefuelAndReturn, moveForward

-- Save internal position state to disk
local function saveState()
    local data = {
        posX = posX,
        posY = posY,
        facing = facing
    }
    local file = fs.open(STATE_FILE, "w")
    if file then
        file.write(textutils.serialize(data))
        file.close()
    end
end

-- Load internal position state from disk
local function loadState()
    if fs.exists(STATE_FILE) then
        local file = fs.open(STATE_FILE, "r")
        if file then
            local content = file.readAll()
            file.close()
            local data = textutils.unserialize(content)
            if data then
                posX = data.posX or 0
                posY = data.posY or 0
                facing = data.facing or 0
                return true
            end
        end
    end
    return false
end

-- Initialize or load settings interactively
local function initSettings()
    settings.load()
    local updated = false

    if settings.get("farmer.length") == nil then
        settings.define("farmer.length", { description = "How many blocks long each row is", type = "number" })
        print("Enter farm length (default: 10):")
        local s = read()
        if s == "" then s = "10" end
        settings.set("farmer.length", tonumber(s) or 10)
        updated = true
    end

    if settings.get("farmer.width") == nil then
        settings.define("farmer.width", { description = "How many rows total", type = "number" })
        print("Enter farm width (default: 5):")
        local s = read()
        if s == "" then s = "5" end
        settings.set("farmer.width", tonumber(s) or 5)
        updated = true
    end

    if settings.get("farmer.start_right") == nil then
        settings.define("farmer.start_right", { description = "Start by turning right? (true/false)", type = "boolean" })
        print("Start by turning right? (true/false, default: true):")
        local s = read()
        if s == "" or s:lower() == "true" then 
            settings.set("farmer.start_right", true)
        else
            settings.set("farmer.start_right", false)
        end
        updated = true
    end

    if settings.get("farmer.sleep_timer") == nil then
        settings.define("farmer.sleep_timer", { description = "Time to wait between harvests in seconds", type = "number" })
        print("Enter sleep timer in seconds (default: 600):")
        local s = read()
        if s == "" then s = "600" end
        settings.set("farmer.sleep_timer", tonumber(s) or 600)
        updated = true
    end

    if settings.get("farmer.min_fuel") == nil then
        settings.define("farmer.min_fuel", { description = "Extra buffer fuel to maintain", type = "number" })
        print("Enter minimum fuel buffer (default: 100):")
        local s = read()
        if s == "" then s = "100" end
        settings.set("farmer.min_fuel", tonumber(s) or 100)
        updated = true
    end

    if settings.get("farmer.fuel_item") == nil then
        settings.define("farmer.fuel_item", { description = "Item to request from CC-MISC for fuel", type = "string" })
        print("Enter fuel item ID (default: minecraft:coal):")
        local s = read()
        if s == "" then s = "minecraft:coal" end
        settings.set("farmer.fuel_item", s)
        updated = true
    end

    if updated then
        settings.save()
        print("Settings saved successfully!")
        os.sleep(2)
    end
end

-- GPS setup that retries forever if GPS is not found
local function setupGPS()
    if settings.get("farmer.home_x") == nil then
        print("\n--- First Time GPS Setup ---")
        print("Please ensure the turtle is resting on its docking modem, facing the first crop.")
        print("Press Enter to begin auto-detection...")
        read()
        
        local x, y, z
        print("Waiting for GPS signal...")
        while not x do
            x, y, z = gps.locate(5)
            if not x then
                print("GPS not found. Retrying in 5 seconds...")
                os.sleep(5)
            end
        end

        settings.set("farmer.home_x", x)
        settings.set("farmer.home_y", y)
        settings.set("farmer.home_z", z)
        print("Home docked at: "..math.floor(x)..", "..math.floor(y)..", "..math.floor(z))
        
        print("Detecting forward direction...")
        while true do
            if turtle.up() then
                if turtle.forward() then
                    local nx, ny, nz
                    while not nx do
                        nx, ny, nz = gps.locate(5)
                        if not nx then os.sleep(2) end
                    end
                    settings.set("farmer.home_dir_x", math.floor((nx - x) + 0.5))
                    settings.set("farmer.home_dir_z", math.floor((nz - z) + 0.5))
                    turtle.back()
                    turtle.down()
                    print("Forward direction registered!")
                    settings.save()
                    break
                else
                    turtle.down()
                    print("Blocked forward! Please clear the block in front (1 block up). Retrying in 3s...")
                    os.sleep(3)
                end
            else
                print("Blocked above! Please clear the block above turtle. Retrying in 3s...")
                os.sleep(3)
            end
        end
    end
end

-- Movement wrappers with tracking and persistence
local function turnRight()
    turtle.turnRight()
    facing = (facing + 1) % 4
    saveState()
end

local function turnLeft()
    turtle.turnLeft()
    facing = (facing - 1) % 4
    if facing < 0 then facing = facing + 4 end
    saveState()
end

local function turnToFacing(targetFacing)
    local diff = (targetFacing - facing) % 4
    if diff < 0 then diff = diff + 4 end
    
    if diff == 1 then turnRight()
    elseif diff == 2 then turnRight(); turnRight()
    elseif diff == 3 then turnLeft()
    end
end

-- Move forward with obstacle avoidance limit and alternate routing
moveForward = function()
    -- Mid-cycle fuel check
    if not isRefueling and turtle.getFuelLevel() ~= "unlimited" then
        local distToHome = math.abs(posX) + math.abs(posY)
        if turtle.getFuelLevel() <= (distToHome + 5) then
            isRefueling = true
            goRefuelAndReturn()
            isRefueling = false
        end
    end

    local max_detour_attempts = 5
    local attempts = 0

    while not turtle.forward() do
        if turtle.getFuelLevel() == 0 then
            print("Out of fuel! Waiting...")
            os.sleep(5)
        else
            local has_block, _ = turtle.inspect()
            if has_block then
                attempts = attempts + 1
                if attempts > max_detour_attempts then
                    print("Exceeded max detour attempts ("..max_detour_attempts.."). Trying alternate route maneuver...")
                    turnRight()
                    turnRight()
                    turtle.forward()
                    turnRight()
                    attempts = 0
                else
                    print("Obstacle encountered. Detour attempt " .. attempts .. "/" .. max_detour_attempts)
                    turnRight()
                    if turtle.forward() then
                        turnLeft()
                        if turtle.forward() then
                            turnLeft()
                            turtle.forward()
                            turnRight()
                        else
                            turnRight()
                            turtle.back()
                        end
                    else
                        turnLeft()
                    end
                end
                os.sleep(1)
            else
                -- Entity in the way (e.g. mob/animal)
                turtle.attack()
                os.sleep(0.5)
            end
        end
    end
    
    if facing == 0 then posX = posX + 1
    elseif facing == 1 then posY = posY + 1
    elseif facing == 2 then posX = posX - 1
    elseif facing == 3 then posY = posY - 1
    end
    saveState()
end

-- Reusable grid navigation
local function navigateTo(targetX, targetY)
    if posX < targetX then
        turnToFacing(0)
        while posX < targetX do moveForward() end
    elseif posX > targetX then
        turnToFacing(2)
        while posX > targetX do moveForward() end
    end

    if posY < targetY then
        turnToFacing(1)
        while posY < targetY do moveForward() end
    elseif posY > targetY then
        turnToFacing(3)
        while posY > targetY do moveForward() end
    end
end

local function returnHome()
    navigateTo(0, 0)
    turnToFacing(0)
    saveState()
end

goRefuelAndReturn = function()
    print("\n[!] Fuel critically low! Pausing to refuel...")
    local savedX, savedY, savedFacing = posX, posY, facing
    
    returnHome()
    turtle.down()
    os.sleep(2)
    
    if peripheral.getType("bottom") == "modem" then
        modemLib.connect("bottom")
        myNetworkName = peripheral.call("bottom", "getNameLocal") or myNetworkName
    end
    
    checkFuel()
    
    print("[!] Resuming cycle...")
    turtle.up()
    navigateTo(savedX, savedY)
    turnToFacing(savedFacing)
end

-- Position recovery with infinite GPS retry
local function recoverPosition()
    local hx = settings.get("farmer.home_x")
    local hy = settings.get("farmer.home_y")
    local hz = settings.get("farmer.home_z")
    local hfx = settings.get("farmer.home_dir_x")
    local hfz = settings.get("farmer.home_dir_z")

    if not (hx and hy and hz and hfx and hfz) then
        print("Home coordinates not set. Cannot auto-recover.")
        return false
    end

    print("Attempting GPS recovery (will retry infinitely until GPS found)...")
    local cx, cy, cz
    while not cx do
        cx, cy, cz = gps.locate(5)
        if not cx then
            print("GPS signal not found. Retrying in 5 seconds...")
            os.sleep(5)
        end
    end
    
    if cx == hx and cy == hy and cz == hz then
        print("Turtle is at home dock.")
        posX, posY, facing = 0, 0, 0
        saveState()
        return true
    end

    print("Calculating orientation...")
    local cfx, cfz
    local moved = false
    for i = 1, 4 do
        if turtle.forward() then
            local nx, ny, nz
            while not nx do
                nx, ny, nz = gps.locate(5)
                if not nx then os.sleep(2) end
            end
            cfx = math.floor((nx - cx) + 0.5)
            cfz = math.floor((nz - cz) + 0.5)
            turtle.back()
            
            for j = 1, i - 1 do turtle.turnLeft() end
            for j = 1, i - 1 do
                local tmp = cfx
                cfx = cfz
                cfz = -tmp
            end
            moved = true
            break
        else
            turtle.turnRight()
        end
    end

    if not moved then
        print("Turtle is stuck and cannot move to determine facing!")
        return false
    end

    local hrx, hrz = -hfz, hfx
    posX = math.floor((cx - hx) * hfx + (cz - hz) * hfz + 0.5)
    posY = math.floor((cx - hx) * hrx + (cz - hz) * hrz + 0.5)

    if cfx == hfx and cfz == hfz then facing = 0
    elseif cfx == hrx and cfz == hrz then facing = 1
    elseif cfx == -hfx and cfz == -hfz then facing = 2
    elseif cfx == -hrx and cfz == -hrz then facing = 3
    else
        facing = 0
    end

    saveState()
    print("State recovered: X="..posX..", Y="..posY..", Facing="..facing)

    local targetY = hy + 1
    while cy < targetY do
        if not turtle.up() then turtle.digUp(); turtle.up() end
        cy = cy + 1
    end
    while cy > targetY do
        if not turtle.down() then turtle.digDown(); turtle.down() end
        cy = cy - 1
    end

    isRefueling = true
    returnHome()
    turtle.down()
    isRefueling = false
    return true
end

checkFuel = function()
    if turtle.getFuelLevel() == "unlimited" then return end
    
    local farm_len = settings.get("farmer.length")
    local farm_wid = settings.get("farmer.width")
    local min_fuel = settings.get("farmer.min_fuel")
    local fuel_item_name = settings.get("farmer.fuel_item")

    local required_fuel = (farm_len * farm_wid) + farm_len + farm_wid + min_fuel
    
    if turtle.getFuelLevel() < required_fuel then
        print("Low fuel. Requesting " .. fuel_item_name .. " from storage...")
        modemLib.pushItems(false, myNetworkName, fuel_item_name, 64)
        os.sleep(0.5)
        
        for i = 1, 16 do
            local item = turtle.getItemDetail(i)
            if item and item.name == fuel_item_name then
                turtle.select(i)
                turtle.refuel()
            end
        end
        
        for i = 1, 16 do
            local item = turtle.getItemDetail(i)
            if item and item.name == fuel_item_name then
                modemLib.pullItems(false, myNetworkName, i, item.count)
                os.sleep(0.2)
            end
        end
    end
    turtle.select(1)
end

local function dumpInventory()
    local valid_seeds = {
        ["minecraft:wheat_seeds"] = true,
        ["minecraft:carrot"] = true,
        ["minecraft:potato"] = true,
        ["minecraft:beetroot_seeds"] = true
    }
    local kept_slots = {}

    print("Checking inventory for items to dump...")
    for i = 1, 16 do
        local item = turtle.getItemDetail(i)
        if item then
            if valid_seeds[item.name] and not kept_slots[item.name] then
                kept_slots[item.name] = true
            else
                modemLib.pullItems(false, myNetworkName, i, item.count)
                os.sleep(0.2)
            end
        end
    end
    turtle.select(1)
end

-- Auto-till dirt and harvest/plant crops
local function harvestAndPlant()
    local has_block, data = turtle.inspectDown()
    
    -- Auto-till if block below is standard dirt
    if has_block and data.name == "minecraft:dirt" then
        print("Found un-tilled dirt. Equipping hoe and tilling...")
        for i = 1, 16 do
            local item = turtle.getItemDetail(i)
            if item and item.name:find("hoe") then
                turtle.select(i)
                turtle.equipLeft()
                break
            end
        end
        turtle.placeDown()
        has_block, data = turtle.inspectDown()
    end

    if has_block then
        local is_mature = false
        if data.state and data.state.age then
            local age = data.state.age
            if (data.name:find("wheat") or data.name:find("carrots") or data.name:find("potatoes")) and age == 7 then
                is_mature = true
            elseif data.name:find("beetroots") and age == 3 then
                is_mature = true
            end
        end

        if is_mature then
            turtle.digDown()
        end
    end

    has_block, _ = turtle.inspectDown()
    if not has_block then
        for i = 1, 16 do
            local item = turtle.getItemDetail(i)
            if item and (item.name:find("seeds") or item.name:find("carrot") or item.name:find("potato")) then
                turtle.select(i)
                turtle.placeDown()
                break
            end
        end
    end
end

-- Farm cycle visiting every spot including the back-most edge
local function doFarmCycle()
    local turnRightNext = settings.get("farmer.start_right")
    local farm_width = settings.get("farmer.width")
    local farm_length = settings.get("farmer.length")

    for row = 1, farm_width do
        for col = 1, farm_length do
            harvestAndPlant()
            if col < farm_length then
                moveForward()
            end
        end

        if row < farm_width then
            if turnRightNext then
                turnRight()
                moveForward()
                turnRight()
            else
                turnLeft()
                moveForward()
                turnLeft()
            end
            turnRightNext = not turnRightNext
        end
    end
end

-- Main function
local function main()
    print("Initializing Farmer Turtle...")
    
    initSettings()
    
    if loadState() then
        print("Loaded previous position from disk: X="..posX..", Y="..posY)
    end

    if peripheral.getType("bottom") ~= "modem" then
        print("Turtle not docked! Attempting GPS recovery...")
        if not recoverPosition() then
            error("Recovery failed!")
        end
        os.sleep(2)
    else
        posX, posY, facing = 0, 0, 0
        saveState()
    end
    
    if peripheral.getType("bottom") == "modem" then
        modemLib.connect("bottom")
    else
        error("No wired modem found on bottom!")
    end
    
    myNetworkName = peripheral.call("bottom", "getNameLocal")
    if not myNetworkName then
        error("Could not get local network name from modem.")
    end
    print("Connected to network: " .. myNetworkName)

    checkFuel()
    setupGPS()

    while true do
        print("Checking fuel and organizing inventory...")
        checkFuel()
        dumpInventory()

        print("Starting farm cycle...")
        turtle.up()
        moveForward()
        
        doFarmCycle()
        
        print("Returning home...")
        returnHome()
        turtle.down()
        
        os.sleep(2)
        
        if peripheral.getType("bottom") == "modem" then
            modemLib.connect("bottom")
            myNetworkName = peripheral.call("bottom", "getNameLocal") or myNetworkName
        end
        
        print("Emptying harvest into storage...")
        dumpInventory()
        
        local sleep_timer = settings.get("farmer.sleep_timer")
        print("Cycle complete. Sleeping for " .. (sleep_timer / 60) .. " minutes.")
        os.sleep(sleep_timer)
    end
end

-- Bulletproof pcall wrapper that never exits the program on errors
while true do
    local ok, err = pcall(main)
    if not ok then
        print("\n[ERROR CAUGHT]: " .. tostring(err))
        print("The program encountered an error. Restarting in 10 seconds...")
        os.sleep(10)
    end
end