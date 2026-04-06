local common = require("common")

---@class modules.passwordProtection
local passwordProtection = {
  id = "passwordProtection",
  version = "1.0.0",
  config = {
    enabled = {
      type = "boolean",
      description = "Enable password protection for the terminal",
      default = true
    },
    timeout = {
      type = "number",
      description = "Inactivity timeout in seconds before password prompt appears",
      default = 300 -- 5 minutes
    },
    password = {
      type = "string",
      description = "Password to unlock the terminal",
      default = ""
    }
  },
  dependencies = {
    logger = { min = "1.1", optional = true }
  },
  init = function(loaded, config)
    local log = loaded.logger
    
    local passwordLogger = setmetatable({}, {
      __index = function() return function() end end
    })
    if log then
      passwordLogger = log.interface.logger("passwordProtection", "main")
    end
    
    ---@type boolean
    local isActive = false
    ---@type number
    local lastActivityTime = os.epoch("utc")
    ---@type boolean
    local isLocked = false
    ---@type function
    local activityCallback = nil
    
    ---@param password string
    ---@return boolean
    local function verifyPassword(password)
      return password == config.passwordProtection.password.value
    end
    
    ---@return boolean
    local function isTimeoutExceeded()
      local currentTime = os.epoch("utc")
      local timeoutMs = config.passwordProtection.timeout.value * 1000
      return (currentTime - lastActivityTime) > timeoutMs
    end
    
    ---@param force boolean
    local function lock(force)
      if force or (config.passwordProtection.enabled.value and isTimeoutExceeded()) then
        isLocked = true
        passwordLogger:info("Terminal locked due to inactivity")
        return true
      end
      return false
    end
    
    ---@param password string
    ---@return boolean
    local function unlock(password)
      if verifyPassword(password) then
        isLocked = false
        lastActivityTime = os.epoch("utc")
        passwordLogger:info("Terminal unlocked")
        return true
      end
      passwordLogger:warn("Failed unlock attempt")
      return false
    end
    
    ---@param callback function
    local function setActivityCallback(callback)
      activityCallback = callback
    end
    
    ---@return boolean
    local function getLockStatus()
      return isLocked
    end
    
    ---@return number
    local function getTimeUntilLock()
      local currentTime = os.epoch("utc")
      local timeoutMs = config.passwordProtection.timeout.value * 1000
      local timeLeft = timeoutMs - (currentTime - lastActivityTime)
      return math.max(0, timeLeft / 1000) -- Return in seconds
    end
    
    ---@param name string
    ---@param value any
    local function updateConfig(name, value)
      if config.passwordProtection[name] then
        config.passwordProtection[name].value = value
        passwordLogger:info("Config updated: %s = %s", name, tostring(value))
      end
    end
    
    ---@return table
    local function getConfig()
      return {
        enabled = config.passwordProtection.enabled.value,
        timeout = config.passwordProtection.timeout.value,
        password = config.passwordProtection.password.value
      }
    end
    
    ---@param event table
    local function handleEvent(event)
      if event[1] == "key" or event[1] == "char" or event[1] == "mouse_click" or event[1] == "mouse_scroll" then
        lastActivityTime = os.epoch("utc")
        if activityCallback then
          activityCallback()
        end
      end
    end
    
    ---@return table
    return {
      ---@param force boolean
      lock = lock,
      ---@param password string
      unlock = unlock,
      getLockStatus = getLockStatus,
      getTimeUntilLock = getTimeUntilLock,
      setActivityCallback = setActivityCallback,
      updateConfig = updateConfig,
      getConfig = getConfig,
      getPasswordConfig = getConfig,
      handleEvent = handleEvent,
      ---@return boolean
      isActive = function() return isActive end,
      ---@param active boolean
      setActive = function(active) 
        isActive = active 
        if active then
          lastActivityTime = os.epoch("utc")
        end
      end
    }
  end
}

return passwordProtection