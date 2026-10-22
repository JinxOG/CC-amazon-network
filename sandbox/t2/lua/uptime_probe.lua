-- T2 probe: once a second, writes the computer's uptime (os.clock) and whether a block is in front of the turtle. A restart makes the
-- uptime go back to nearly zero; a turn makes the detect result change when only one side has a block.
while true do
  sleep(1)
  local f = fs.open("uptime.txt", "a")
  f.writeLine(string.format("%.2f %s", os.clock(), tostring(turtle.detect())))
  f.close()
end
