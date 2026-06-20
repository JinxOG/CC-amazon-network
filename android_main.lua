-- android_main.lua
-- Entry point for a CC Android agent.
-- Requires: protocol.lua, android_base.lua on the Android's filesystem.

local base = require("android_base")

base.init()
base.runHeartbeat()
