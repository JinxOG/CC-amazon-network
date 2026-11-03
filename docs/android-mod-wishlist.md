# CC Androids refresh: feature wish list from Turtle OS

Written 2026-11-02 by the Turtle OS spec owner, for the CC Androids refresh. The planned features are built-in
modems and ender modems, player-like chunk loading, armour, Point Blank and Immersive Vehicles support, and FE
power with charging docks.

**What androids will do for the fleet:**
- **guard:** protect job sites and the base;
- **driver:** Uber-style haulage in Immersive Vehicles;
- **rescue and replacement:** fetch stranded turtles, and put a new turtle in place of a dead one;
- **builder:** place blocks that have to face a certain way, alongside turtles.

**Priority tags:** **[MUST]** means the role can't work without it. **[SHOULD]** makes the role reliable.
**[NICE]** is later.

---

## Design rules for the whole API

These matter more than any single function.

1. **Events, not polling.** Every long action (move, drive, fly, dig, fight) returns a task id. When it ends it
   fires `android_task_done(taskId, ok, reason)`. Polling `currentTask()` in a loop wastes server time, and
   CC's yield rules make it lose events.
2. **Every failure says why.** Return `false, "reason"` with a fixed vocabulary, for example `no_path`,
   `blocked`, `out_of_power`, `out_of_reach`, `claimed`, `timed_out`, `cancelled`, `attacked`, `inventory_full`.
   Programs branch on the reason. A bare `false` forces guessing.
3. **Fast loops live in Java; Lua sets goals.** A CC program can't steer a car or aim a gun 20 times a second
   reliably: it yields, it shares time with other computers, and radio adds lag. Java runs the "drive to",
   "hover at" and "guard this area" loops. Lua chooses the goal, tunes the rules and reacts to events.
4. **Plain Lua tables, with positions as doubles.** Return the same shapes everywhere: `{x,y,z}`,
   `{x,y,z,yaw,pitch}`, `{dx,dy,dz}`.
5. **A cost on every scan.** Big scans cost FE and have a server-side budget per tick, so 150 units can't
   lag the server. A config file controls the limits.
6. **Programs can ask what this version supports.** `android.getApiVersion()` and `android.hasFeature("flight")`
   let one program run on servers with different versions or settings. That matters for ordinary players.

---

## 1. Identity and survival  [MUST, for rescue and replacement]

| Want | Why |
|---|---|
| A stable id: `android.getId()` returns a UUID that never changes. `getComputerId()` and `getLabel()` survive pickup, re-placing, server restart and chunk unload | Turtle OS knows every worker by name. A worker that comes back with a new name is lost. |
| Picking an android up keeps it whole: the item carries its id, label, inventory, energy and installed upgrades | Rescue, transport, storage |
| On boot, an `android_resumed` event says why it restarted: `server_restart`, `chunk_unloaded`, `picked_up`, `died`, `crashed`, and its last task | Our recovery layer handles each case differently |
| On death, the android drops as its own item with everything above (config option), rather than vanishing | A dead android can be rescued too |
| `getOwner()` and `getTeam()` | Guard rules, claims |
| Copied androids get their own identity and chunk loading | With the other chunk-loader mod, copied loaders shared one ticket and only the last-placed one held |

## 2. Power and docks  [MUST]

| Want | Why |
|---|---|
| `getEnergy()`, `getEnergyCapacity()`, `getEnergyUse()` (the current draw per tick) | Plan trips |
| `estimateEnergy(x,y,z [,mode])` gives the cost of a walk, flight or drive before starting | "Can I get there and back?" |
| `setLowPowerThreshold(n)`; events `android_low_power` and `android_charged` | No polling |
| **A dock block that is a peripheral:** `getDocked()` returns `{id,label,energy,capacity}`; `setChargeRate()`; events `dock_arrived(id)` and `dock_left(id)` | The base sees who is parked and their charge, with no need to ask each android |
| `sleep(seconds)` / low-power idle: AI and pathfinding stop and the android wakes on a radio message or event | 50+ parked androids must cost close to nothing |
| FE batteries in the inventory can charge the android in the field | Long rescue trips |

## 3. Chunk loading  [MUST]

| Want | Why |
|---|---|
| `setChunkLoading(radius)` with 0–2 chunks around the android; `getLoadedChunks()` | Replaces our chunk-loading partner turtles. One android can cover a group of miners |
| **No "owner offline" timeout** (config, default off) | The other mod's 7-day rule unloaded the base and took GPS down for four days |
| **A "worker" loading mode that runs machines but does NOT spawn mobs naturally** (config and per-android) | Force-loaded chunks with nobody around filled with zombified piglins |
| `isLoaded(x,z)` | Check before sending a worker |

## 4. Awareness: seeing the world  [MUST for drivers and guards, SHOULD for the others]

### Self
`getPose()` returns:
```
{x,y,z, yaw,pitch, vx,vy,vz, onGround, inWater, inLava, onFire, health, maxHealth,
 armor, dimension, riding = vehicleId|nil, task = {...}}
```
This replaces GPS. When the GPS towers lost power, every turtle went blind, but androids already know where
they are.

### Surroundings
| Want | Use |
|---|---|
| `scan(radius, filter)` returns blocks as `{dx,dy,dz,name,state,hardness,solid,passable,liquid,danger}` | Builder, rescue |
| **`getOccupancy(radius)`** returns a compact 3D grid around the android, one character per block: `#` solid, `.` air, `~` liquid, `!` danger (lava, fire, cactus, powder snow), `L` ladder or scaffold, `D` door | Cheap whole-area awareness for our own path planning, small enough to send over radio |
| `raycast(yaw,pitch,maxDist)` and `raycastTo(x,y,z)` return the first hit as `{kind="block"/"entity", name, id, distance, face, x,y,z}` | Line of sight, aiming, "is the road clear?" |
| **`lidar(yawFrom,yawTo,steps,pitch,maxDist)`** returns an array of distances, a fan of rays | Self-driving and obstacle avoidance in a single call |
| `getEntities(radius, filter)` returns `{id,type,name,x,y,z,vx,vy,vz,width,height,health,hostile,isPlayer,team,riding}` | Guards, drivers (pedestrians, other cars) |
| `canStandAt(x,y,z)`, `canReach(x,y,z)`, `fallHeight(x,z)` | Safe placement and recovery |
| `getEnvironment()` returns `{light,biome,dimension,raining,thunder,time,isDay}` | Mob danger, driving at night |

### Continuous awareness: subscriptions  [MUST for drivers and guards]
Instead of the program polling, the program describes what it cares about and Java watches every tick:
```
id = android.watch({ radius=16, entities={"hostile","player"}, blocks={"lava"}, ahead=8 })
-- events:
--   android_entity_entered(watchId, entity)    android_entity_left(watchId, entityId)
--   android_obstacle_ahead(watchId, distance, what)
--   android_danger(watchId, kind, x,y,z)       android_damaged(source, amount, attackerId)
android.unwatch(id)
```
For a vehicle, "ahead" uses the vehicle's width, height and speed, not the android's.

## 5. Movement and pathfinding  [MUST]

| Want | Why |
|---|---|
| `moveTo` returns a task id and fires `android_task_done` with a reason | See the design rules |
| **`findPath(x,y,z, opts)`** returns `{ok, waypoints, length, energy, reason}` **without moving** | Plan and check a trip before committing |
| `followPath(waypoints)` | Our server can route androids along known roads and taxiways, like the turtle lanes |
| Path options: `allowDig`, `allowPlace` (pillar up, bridge gaps), `allowSwim`, `maxFall`, `avoid={...}`, `maxDistance`, `timeout` | Rescue: dig into a one-block-high mine tunnel |
| **Climbing:** ladders, scaffolding, vines | High builds without flight |
| `getTask()` returns `{type, target, progress, eta, stuckFor}`; event `android_stuck(seconds)` | A stuck path gets reported instead of hanging |
| `lookAt(x,y,z)`, `setYaw(yaw)`, `crouch(bool)`, `jump()` | Precise facing |

### Flight upgrade  [SHOULD, the main thing builders need]
An FE-powered jetpack or hover module:
- `flyTo(x,y,z)`, `hover()`, `setAltitude(y)`, `land()`, `getFlightState()`;
- energy drain per second, both hovering and moving;
- a safe landing on low power (it lands itself and never just drops).

## 6. Hands, inventory and blocks  [MUST]

| Want | Why |
|---|---|
| **`placeBlock(x,y,z, slot, {facing=, half=, axis=, hit=})`**: placement with an explicit facing, no approach-angle trick | Builder. Today, facing depends on where the android stands |
| Place and break anywhere within player reach (about 4.5 blocks) **without walking** | Speed, and walls without moving |
| `breakBlock` returns the drops; **breaking a turtle or computer keeps its id and label** in the item | Rescue: a recovered turtle must keep its name |
| `pickUpTurtle(x,y,z)` and `placeTurtle(x,y,z, slot, facing)` as first-class calls | Rescue and replacement |
| **Bulk transfer:** `pushItems(x,y,z, fromSlot, count, toSlot)`, `pullItems(...)`, `pushAll(x,y,z)`. No going through the hand | Hauling: one hand-held item at a time is far too slow |
| `getItemDetail(slot)` with NBT, durability and the turtle id/label if it is a turtle | Know which spare is in which slot |
| A backpack upgrade for more slots | 9 slots is tight for hauling or building |
| **Upgrade slots that take CC and Advanced Peripherals add-ons** (Block Reader, Geo Scanner, Environment Detector), wrapped as `peripheral.wrap("back")` | Builder checks its own work; reuses mods people already have |
| `turnOn(x,y,z)` and `insertDisk(x,y,z,slot)` for computers and turtles | A replacement turtle can boot and register with nobody in-game |

## 7. Vehicles (Immersive Vehicles first; boats, minecarts and Valkyrien Skies later)  [MUST for drivers]

### Knowing the vehicle
`getVehicles(radius)` and `getVehicle(id)` return:
```
{id, type, name, owner, locked,
 size = {length,width,height}, wheelbase, turnRadius,
 seats = {{index, occupied, occupantId, isDriver}, ...},
 x,y,z, yaw,pitch,roll, vx,vy,vz, speed, maxSpeed,
 fuel, fuelCapacity, fuelType, engineOn, rpm, gear,
 health, damage, cargo = {slots, used}, lights, onGround, wheelsOnGround}
```

### Driving
| Want | Notes |
|---|---|
| `mount(vehicleId [,seat])`, `dismount()` | |
| Direct control: `setThrottle(-1..1)`, `setBrake(0..1)`, `setSteer(-1..1)`, `setGear(n)`, `engine(on)`, `lights(on)`, `horn()` | For our own experiments |
| **`driveTo(x,z, opts)` autopilot in Java**, with `maxSpeed`, `followRoads`, `avoidEntities`, `stopDistance`, `route={waypoints}` | Steering in Lua over radio can't be done safely. Events: `drive_arrived`, `drive_blocked(what)`, `drive_low_fuel`, `drive_collision(what, speed)` |
| `getClearance(direction)`: how far the **vehicle's footprint** can go before hitting something | Squeezing through gates and tunnels |
| `sweepAhead(distance)` returns obstacles in the vehicle's path, sized to its width and height | Self-driving |
| Cargo: `vehiclePush` / `vehiclePull` between the android or a chest and the vehicle | Haulage pickups and drops |
| `refuelVehicle(fromSlot)` | |
| Aircraft later: `setPitch`, `setRoll`, `setYawRate`, `getAltitude`, and an autopilot `flyVehicleTo` | Airship and plane plans |

## 8. Guards, combat and armour (Point Blank)  [SHOULD]

**Safety rules live in Java, not Lua.** A Lua bug must never be able to shoot a player.

| Want | Notes |
|---|---|
| `setTargetRules({hostileMobs=true, players=false, whitelist={...}, teams={...}, protectArea=box})` | Java checks these before every shot |
| **Line-of-fire check:** the android refuses to fire if a friendly player or android is on the ray | Built in, can't be turned off |
| `guardArea(box or polygon, opts)` as a Java loop; events `threat_detected(entity)`, `threat_cleared`, `guard_low_ammo`, `guard_retreating` | Lua only sets the area and the rules |
| `getWeapon()` returns `{type, ammo, magazine, reloadTime, range, damage}`; `aimAt(target)`, `fire()`, `reload()` | Direct control for experiments |
| `getArmor()` returns pieces, durability and protection; `setRetreatHealth(n)` | A guard comes home before it dies |

## 9. Radio  [MUST]

| Want | Why |
|---|---|
| The built-in modem and ender modem behave **exactly like a normal CC modem** (same channels, `modem_message`, rednet). They are wrapped by a side name, `peripheral.find("modem")` works, and they don't take a hand or upgrade slot | Our existing protocol works unchanged |
| A configurable range for the plain modem | |

## 10. Server safety and admin  [SHOULD]

| Want | Why |
|---|---|
| Respect land claims (FTB Chunks, Open Parties and Claims): any action in a claim the owner can't build in returns `false, "claimed"` | Ordinary servers have claims |
| Config: maximum androids per player, scan budget per tick, pathfinding budget per tick | 150 units on one server |
| Admin commands: `/androids list`, `/androids freeze all`, `/androids return all`, `/androids debug <id>` (draws the path, the scan area and the current task in the world) | Emergencies and debugging |

## 11. Testing hooks  [NICE, but cheap and very useful to us]

| Want | Why |
|---|---|
| A test-server-only command set: freeze or step an android, force a path failure, drain energy, fake damage, teleport | Our layer-2 test server can then test android roles the way the `t2control` mod tests turtles |
| An event log line for every task start, task end and reason | The log watcher can confirm android work from the live logs, as it does for turtles |

---

## If only ten things get built

1. Identity survives everything (id, label, contents), including turtles picked up by an android.
2. Every task ends with an event and a reason.
3. Chunk loading with no offline timeout and no natural mob spawning.
4. Energy readings, low-power events, and a dock peripheral.
5. `getPose()`, so no GPS is needed.
6. `watch()` subscriptions and `lidar()`.
7. `findPath()` that doesn't move, plus dig and climb options.
8. `placeBlock` with explicit facing, and bulk item transfer.
9. `driveTo` autopilot in Java, plus the vehicle info table with its size.
10. Guard safety rules enforced in Java.
