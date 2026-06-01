-- gps_host.lua
-- Place on 4 computers at Y=255 with ender modems.
-- Each one needs its own X,Z coordinate set below.
-- Rename to startup.lua on each GPS host computer.

-- !! Set these to the actual coordinates of THIS computer !!
local X = 0
local Y = 255
local Z = 0

print(string.format("GPS Host running at %d, %d, %d", X, Y, Z))
shell.run("gps", "host", X, Y, Z)
