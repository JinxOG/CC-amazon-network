return dofile("sandbox/scenarios/_w3_capacity.lua")(10000000, tonumber(os.getenv("W3_CAP_DAYS") or "7"))
