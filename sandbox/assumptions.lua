-- Every place the sandbox guesses. Reports print this list under ASSUMPTIONS (spec section 11).
-- Add a line whenever a behaviour is chosen without evidence from the real game or the live fleet.
return {
  "TIMINGS: every entry in sandbox/timings.lua is unverified until calibrated against the live fleet (Task 25).",
  "In-game time is real time x72 (20-minute day); os.date is UTC.",
  "fs handle readAll() returns nil at end of file (tweaked.cc); unverified in game.",
  "textutils.serialise with compact=true is not implemented; the fleet never uses it.",
  "turtle.dig with a full inventory succeeds and the overflow is dropped on the ground (tests/stub_cc.lua refuses instead); unverified in game.",
  "turtle.refuel with a full tank still returns true and burns nothing (as tests/stub_cc.lua does).",
  "Digging gives the block itself as the drop, except stone, grass and deepslate (a small table).",
  "Turtle facing: 0 = north (-z), 1 = east (+x), 2 = south (+z), 3 = west (-x).",
  "Chunk loading: a turtle with the chunky upgrade loads 3x3 chunks around itself (radius 1, as loader_state.dat records); a computer in an unloaded chunk shuts down and boots from startup.lua when the chunk loads again. Unconfirmed in the world.",
  "Two turtles sharing one chunk identity (a copied loader) hold one ticket between them; the last placed wins.",
  "Wireless modems are all treated as the advanced kind: unlimited range, no dimension limit.",
  "gps.locate: four hosts at one height leave a mirror position and return nil; hosts reply with an {x,y,z} array; the reply channel is 50000 + id % 10000.",
}
