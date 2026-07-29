# Song Wars — Design Spec (Phase 1: Platform + Points-Based Modes)

## Summary

A Kahoot-style multiplayer party game. One host creates a game and gets a
join code; players join from their phones, no accounts needed. Each round
has a prompt (e.g. "Best Country Song"), players submit a song matching it,
songs play back anonymously, everyone rates them on a sliding scale, and
scores accumulate into a leaderboard across rounds.

This spec covers the **core platform** plus the **Free-For-All** and
**Genre** game modes, which share one points-based scoring engine. A
**Tournament** (head-to-head bracket) mode is a genuinely different game
engine and is deferred to a follow-up spec that reuses this platform.

## Goals / Non-Goals

**Goals:** no-install, phone-browser party game; playable both in-person
(shared screen + phones) and fully remote; low friction to join and play.

**Non-goals for this phase:** Tournament/bracket mode, user accounts,
Spotify integration, real audio-content moderation beyond automated
filtering, native mobile apps.

## Architecture

A single Node.js server (WebSockets, e.g. `ws` or `socket.io`) is the sole
source of truth for game state, serving a plain responsive HTML/CSS/JS
frontend (no build step, mobile-first). Deployed to a free-tier host
(Render/Fly/Railway) so a join code works for anyone, anywhere. No
accounts — a game exists only in server memory for the session's duration,
identified by a short join code (like a Kahoot PIN).

Two client views, both served by the same app:

- **Display view** — the shared screen: round prompt, now-playing player
  (YouTube IFrame Player / SoundCloud Widget), live voting progress,
  reveal, and leaderboard. The host's Display also has game controls
  (start round, reveal, next round) **and a collapsible host panel**
  merged into the same page, since the host also plays and would
  otherwise have no way to submit/vote from a single screen.
- **Player view** — the phone controller: join screen (code + nickname),
  song search/submit, timestamp scrubber, voting slider, skip button.

Every device that wants to *hear* audio simply opens a Display view
locally — one TV in-person, or each remote player's own second tab. This
sidesteps cross-device audio sync entirely: nobody's audio is being
synced to anyone else's, each device just plays the current song
independently once told what it is.

## Host Settings (set at game creation)

- Mode: **Free-For-All** (no theme constraint, host sets number of
  rounds) or **Genre** (max 5 rounds; each round's genre is randomly
  selected by the server from a pool and revealed fresh — not chosen by
  the host in advance)
- Clip length per song (15s / 30s / 45s / 60s / full song)
- Submission time limit per round
- Skip-vote threshold (default: majority of active players)

## Round Flow

1. Host clicks "Start Round" — Display shows the round's prompt. In
   Genre mode, the server picks a genre at random from a pool and
   reveals it here (e.g. "Round 2: 80s Rock"); in Free-For-All it's just
   "anything goes."
2. Players search YouTube (or paste a SoundCloud link), preview, and drag
   a scrubber to pick a start point — defaulted to ~35–40% into the
   track as a naive "likely chorus" heuristic — then submit the song
   they think best fits the round's prompt before the timer expires.
3. Server shuffles submissions into an anonymized playback queue.
4. Display plays each song from its chosen timestamp for the configured
   clip length, or shorter if enough players tap "Skip" (skip-vote
   threshold reached cuts playback and jumps straight to voting). While
   a song plays, players can tap preset emoji reactions on their Player
   view; these appear as floating reactions drifting across the Display
   screen in real time (DJMAX Respect V–style), purely cosmetic and not
   stored or scored.
5. After each clip, everyone except its submitter rates it on the
   sliding scale (0–10) within a voting window.
6. Once every song in the round is rated, Display reveals each
   submitter's name next to their song and that round's scores, added
   to a running leaderboard.
7. Host advances to the next round, or ends the game to show final
   standings.

## Scoring

- Round score = average of all other players' ratings (0–10, one
  decimal). Averaging keeps it fair regardless of how many players are
  online for a given round.
- You cannot vote on your own submission.
- Final ranking = sum of round scores across the game.

## Song Sources

- **YouTube** — primary source. Server-side search proxy calls the
  YouTube Data API (keeps the API key off the client), restricted to the
  Music category (`videoCategoryId=10`) and a 30s–12min duration range to
  filter out non-song content. Playback via the YouTube IFrame Player API
  on Display views, using `start`/`end` params for the clip window.
- **SoundCloud** — secondary source, paste-link only (not free-text
  search). SoundCloud's search API now requires an approved client ID
  that isn't readily available; embedding a public track via a pasted
  URL through their oEmbed/Widget API doesn't require one.
- **Spotify — explicitly out of scope for this phase.** Full playback
  requires the Web Playback SDK, which means every listener would need
  to log into their own Spotify Premium account in-browser — exactly the
  friction YouTube was chosen to avoid. Spotify also removed the 30-second
  preview-clip API for most tracks in late 2024, closing off the
  no-login fallback that older projects relied on. Revisit only if the
  login/Premium tradeoff becomes worth it later.

Content filtering (category + duration) is best-effort, not real
moderation — voting is blind for everyone including the host, so nobody
pre-screens a submission before it plays. This is an accepted limitation,
not a gap to close in this phase.

## Components

- **Game server** — in-memory state per game code (players, current
  round, submissions, votes, skip-tally); runs the round state machine;
  broadcasts state deltas to connected clients, including relaying live
  reaction events during playback. Sole source of truth.
- **YouTube search proxy** — server-side endpoint applying the
  category/duration filter, keeps the API key server-side.
- **Display client** — big-screen view, playback, leaderboard, host
  controls, merged host player panel, floating-reaction overlay.
- **Player client** — phone view, join/search/submit/scrub/vote/skip UI,
  plus a preset emoji picker shown during playback.

## Error Handling

- **Disconnect/reconnect** — a player's browser stores a reconnect token
  in `localStorage`; dropping mid-game and returning before it ends
  rejoins them to their same slot. If the host disconnects, the game
  pauses until they return — no auto-transfer of host control in this
  phase.
- **Missed submission** — a player who doesn't submit before the timer
  expires is simply skipped for that round (no song, no score), not
  blocked from later rounds.
- **Unplayable video** (embed-disabled/region-locked, slipping past the
  search filter) — Display detects the IFrame Player's error event, and
  the server auto-advances to voting for that entry marked "unplayable,"
  excluded from scoring.
- **Minimum players** — at least 2 required to start a game (a lone
  player has nobody to rate their song).

## Testing

- **Unit tests** for the game state machine — round transitions, scoring
  math, skip-vote threshold logic — since this is pure logic decoupled
  from WebSocket transport, it's the highest-value automated coverage.
- **Manual multi-tab testing** for the live join/submit/vote/reveal flow
  and for actual YouTube/SoundCloud embed playback behavior, which is
  impractical to fully automate.

## Deferred to Phase 2

- **Tournament mode** — head-to-head bracket: songs face off 1v1,
  players vote per matchup, losers eliminated. A different game engine
  from the points-based scoring here; will reuse this platform's lobby,
  song search/submission, and playback infrastructure.
