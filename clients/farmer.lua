--[[
  CC:Tweaked Farmer Turtle
  Integrates natively with CC-MISC modems/inventories by pushing/pulling downwards.
  
  Instructions:
  1. Place the turtle in the recessed area on top of your modem/inventory block.
  2. Put some fuel in the inventory below (or in the turtle).
  3. Run the script. It will ask for your settings the first time it runs!
]]--

local modemLib = require("modemLib")

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
        print("You can change these later using the default 'set' command.")
        os.sleep(2)
    end
end

local function setupGPS()
    if settings.get("farmer.home_x") == nil then
        print("\n--- First Time GPS Setup ---")
        print("Please ensure the turtle is resting on its docking modem, facing the first crop.")
        print("Press Enter to begin auto-detection...")
        read()
        
        local x, y, z = gps.locate(5)
        if not x then
            error("Could not get GPS location! Please make sure GPS is working.")
        end
        settings.set("farmer.home_x", x)
        settings.set("farmer.home_y", y)
        settings.set("farmer.home_z", z)
        print("Home docked at: "..math.floor(x)..", "..math.floor(y)..", "..math.floor(z))
        
        print("Detecting forward direction...")
        if turtle.up() then
            if turtle.forward() then
                local nx, ny, nz = gps.locate(5)
                settings.set("farmer.home_dir_x", math.floor((nx - x) + 0.5))
                settings.set("farmer.home_dir_z", math.floor((nz - z) + 0.5))
                turtle.back()
                turtle.down()
                print("Forward direction registered!")
                settings.save()
            else
                turtle.down()
                error("Setup failed. Please clear the block in front of the turtle (1 block up) so it can test its direction!")
            end
        else
            error("Setup failed. Please clear the block directly above the turtle so it can move up!")
        end
    end
end

-- Global States
local myNetworkName = nil
local isRefueling = false
local posX, posY = 0, 0
local facing = 0 -- 0: +x (forward), 1: +y (right), 2: -x (back), 3: -y (left)

-- Forward declarations for mutual recursion handling
local checkFuel, goRefuelAndReturn

-- Movement wrappers to track position
local function turnRight()
    turtle.turnRight()
    facing = (facing + 1) % 4
end

local function turnLeft()
    turtle.turnLeft()
    facing = (facing - 1) % 4
    if facing < 0 then facing = facing + 4 end
end

local function turnToFacing(targetFacing)
    local diff = (targetFacing - facing) % 4
    if diff < 0 then diff = diff + 4 end
    
    if diff == 1 then turnRight()
    elseif diff == 2 then turnRight(); turnRight()
    elseif diff == 3 then turnLeft()
    end
end

local function moveForward()
    -- Mid-cycle fuel check: Ensure we have enough fuel to get home + a 5 block buffer
    if not isRefueling and turtle.getFuelLevel() ~= "unlimited" then
        local distToHome = math.abs(posX) + math.abs(posY)
        if turtle.getFuelLevel() <= (distToHome + 5) then
            isRefueling = true
            goRefuelAndReturn()
            isRefueling = false
        end
    end

    while not turtle.forward() do
        if turtle.getFuelLevel() == 0 then
            print("Out of fuel! Waiting...")
            os.sleep(5)
        else
            -- If blocked by an entity (like an Iron Golem), attack it
            local has_block, _ = turtle.inspect()
            if has_block then
                print("Blocked by a solid block. Check your farm dimensions.")
                os.sleep(2)
            else
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
end

-- Reusable grid navigation
local function navigateTo(targetX, targetY)
    -- Move X axis
    if posX < targetX then
        turnToFacing(0)
        while posX < targetX do moveForward() end
    elseif posX > targetX then
        turnToFacing(2)
        while posX > targetX do moveForward() end
    end

    -- Move Y axis
    if posY < targetY then
        turnToFacing(1)
        while posY < targetY do moveForward() end
    elseif posY > targetY then
        turnToFacing(3)
        while posY > targetY do moveForward() end
    end
end

-- Return the turtle to the exact starting block
local function returnHome()
    navigateTo(0, 0)
    turnToFacing(0)
end

-- Pauses current activity, goes home, refuels via network, and returns to exactly where it was
goRefuelAndReturn = function()
    print("\n[!] Fuel critically low mid-cycle! Pausing to refuel...")
    local savedX, savedY, savedFacing = posX, posY, facing
    
    returnHome()
    turtle.down() -- Land on the modem
    os.sleep(2)   -- Let it settle
    
    if peripheral.getType("bottom") == "modem" then
        modemLib.connect("bottom")
        myNetworkName = peripheral.call("bottom", "getNameLocal") or myNetworkName
    end
    
    checkFuel()
    
    print("[!] Resuming cycle from where we left off...")
    turtle.up()
    
    navigateTo(savedX, savedY)
    turnToFacing(savedFacing)
end

-- Uses GPS to recalculate internal position and align to the dock
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

    print("Attempting GPS recovery...")
    local cx, cy, cz = gps.locate(5)
    if not cx then
        print("Failed to get GPS location for recovery.")
        return false
    end
    
    if cx == hx and cy == hy and cz == hz then
        print("Turtle is already at home dock.")
        posX, posY, facing = 0, 0, 0
        return true
    end

    print("Calculating relative position...")
    -- Determine current facing
    local cfx, cfz
    local moved = false
    for i = 1, 4 do
        if turtle.forward() then
            local nx, ny, nz = gps.locate(5)
            cfx = math.floor((nx - cx) + 0.5)
            cfz = math.floor((nz - cz) + 0.5)
            turtle.back()
            
            -- Restore orientation visually
            for j = 1, i - 1 do turtle.turnLeft() end
            
            -- Calculate actual forward vector before the turns
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

    -- Calculate current relative position (mapping world coords to internal posX/posY)
    local hrx, hrz = -hfz, hfx -- Home Right Vector
    posX = math.floor((cx - hx) * hfx + (cz - hz) * hfz + 0.5)
    posY = math.floor((cx - hx) * hrx + (cz - hz) * hrz + 0.5)

    -- Map world facing to internal facing
    if cfx == hfx and cfz == hfz then facing = 0
    elseif cfx == hrx and cfz == hrz then facing = 1
    elseif cfx == -hfx and cfz == -hfz then facing = 2
    elseif cfx == -hrx and cfz == -hrz then facing = 3
    else
        print("Warning: Orientation doesn't match grid. Defaulting to 0.")
        facing = 0
    end

    print("State recovered: X="..posX..", Y="..posY..", Facing="..facing)

    -- Adjust Y level to the safe cruising height (hy + 1)
    local targetY = hy + 1
    while cy < targetY do
        if not turtle.up() then
            turtle.digUp()
            turtle.up()
        end
        cy = cy + 1
    end
    while cy > targetY do
        if not turtle.down() then
            turtle.digDown()
            turtle.down()
        end
        cy = cy - 1
    end

    -- Use the existing navigation system to fly home!
    print("Navigating back to dock...")
    isRefueling = true -- Temporarily suppress mid-cycle refueling checks during recovery
    returnHome()
    turtle.down() -- Land on the modem
    isRefueling = false
    
    return true
end

-- Automatically handles refueling by pulling from the modem/inventory below
checkFuel = function()
    if turtle.getFuelLevel() == "unlimited" then return end
    
    local farm_len = settings.get("farmer.length")
    local farm_wid = settings.get("farmer.width")
    local min_fuel = settings.get("farmer.min_fuel")
    local fuel_item_name = settings.get("farmer.fuel_item")

    local required_fuel = (farm_len * farm_wid) + farm_len + farm_wid + min_fuel
    
    if turtle.getFuelLevel() < required_fuel then
        print("Low fuel. Requesting " .. fuel_item_name .. " from storage...")
        -- Ask CC-MISC to push fuel into us
        modemLib.pushItems(false, myNetworkName, fuel_item_name, 64)
        os.sleep(0.5) -- Give network time to transfer
        
        for i = 1, 16 do
            local item = turtle.getItemDetail(i)
            if item and item.name == fuel_item_name then
                turtle.select(i)
                turtle.refuel()
            end
        end
        
        if turtle.getFuelLevel() < required_fuel then
            print("WARNING: Not enough fuel retrieved! Please check storage.")
        else
            print("Refueled! Current: " .. turtle.getFuelLevel())
        end
        
        -- Push remaining fuel back to storage
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

-- Dumps harvested crops while keeping exactly one stack of necessary seeds
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
                -- Keep one stack of each type of seed we find
                kept_slots[item.name] = true
                print("Slot " .. i .. ": Keeping stack of " .. item.name .. " for replanting")
            else
                -- Pull the rest from this slot into the CC-MISC storage
                print("Slot " .. i .. ": Dumping " .. item.count .. "x " .. item.name)
                modemLib.pullItems(false, myNetworkName, i, item.count)
                os.sleep(0.2) -- Small delay to prevent dropping requests on the network
            end
        end
    end
    turtle.select(1)
end

-- Checks the crop below, harvests if mature, and replants
local function harvestAndPlant()
    local has_block, data = turtle.inspectDown()
    if has_block then
        local is_mature = false
        
        -- Identify mature crops (vanilla wheat/carrots/potatoes are max age 7)
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

    -- Check if empty (either we just harvested it, or it was already empty)
    has_block, _ = turtle.inspectDown()
    if not has_block then
        -- Find a seed and plant it
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

-- Navigates the farm in a snake (boustrophedon) pattern
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

        -- Turn into the next row
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

-- Main Loop
local function main()
    print("Initializing Farmer Turtle...")
    
    -- Load and prompt for settings if they don't exist yet
    initSettings()
    
    -- Check if we are docked. If not, trigger GPS recovery!
    if peripheral.getType("bottom") ~= "modem" then
        print("Turtle is not docked on a modem! Attempting GPS recovery...")
        if not recoverPosition() then
            error("Recovery failed! Please place the turtle manually on the modem.")
        end
        os.sleep(2) -- Let it settle on the modem
    else
        -- If we booted up cleanly on the dock, zero out coordinates
        posX, posY, facing = 0, 0, 0
    end
    
    -- Connect to CC-MISC over wired modem on the bottom
    if peripheral.getType("bottom") == "modem" then
        modemLib.connect("bottom")
        print("Connected to CC-MISC wired modem.")
    else
        error("No wired modem found on the bottom! Please place the turtle on a wired modem.")
    end
    
    myNetworkName = peripheral.call("bottom", "getNameLocal")
    if not myNetworkName then
        error("Could not get local network name from modem. Is it connected to the storage network?")
    end
    print("My network name: " .. myNetworkName)

    -- Pre-flight fuel check. Ensures we have enough fuel for the first-time GPS alignment!
    checkFuel()

    -- Run auto-detect setup if the GPS was never registered
    setupGPS()

    while true do
        print("Checking fuel and organizing inventory...")
        checkFuel()
        dumpInventory()

        print("Starting farm cycle...")
        turtle.up() -- Move above the crops to avoid breaking immature ones
        moveForward() -- Step out of the recessed area and over the first crop
        
        doFarmCycle()
        
        print("Returning home...")
        returnHome() -- Automatically navigates back to the block above the recess
        
        turtle.down() -- Move back down into the recess to rest on the modem
        
        os.sleep(2) -- Short pause to ensure we're settled before reconnecting
        
        -- Re-establish connection to CC-MISC, as moving physically disconnects the modem!
        if peripheral.getType("bottom") == "modem" then
            modemLib.connect("bottom")
            myNetworkName = peripheral.call("bottom", "getNameLocal") or myNetworkName
        end
        
        print("Emptying harvest into storage system...")
        dumpInventory()
        
        local sleep_timer = settings.get("farmer.sleep_timer")
        print("Cycle complete. Sleeping for " .. (sleep_timer / 60) .. " minutes.")
        os.sleep(sleep_timer)
    end
end

main()