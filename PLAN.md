# Local Go app in Godot: build plan for an offline coding agent

This document is the complete brief. You (the coding agent) have no internet access.
Everything you need to know about the engine protocol is in section 4. Do not guess
at APIs that are not described here; check the offline Godot docs in `docs/godot/`
if they are present, or write a tiny test script and run it headless.

## 1. What we are building

A desktop Go (baduk/weiqi) application made with **Godot 4 and GDScript** that:

1. Lets one human play against a **human-like AI opponent** at a selectable rank (20 kyu to 9 dan).
2. Provides **unlimited AI review** of any game, in the style of online-go.com (OGS):
   - win-rate and score graph over the whole game, clickable, with mistakes marked
   - candidate moves drawn on the board with win rate and points lost, variation shown on hover
   - territory/ownership overlay and a score estimate at any position
   - SGF load/save and a move tree with side variations
3. Runs on **Windows (RTX 2060)** and **macOS (Apple M4)** from the same project.

The AI is **KataGo**, run as a child process in its JSON **analysis engine** mode.
One KataGo process serves both the opponent and the review. Two networks are loaded:
a strong main network (for analysis) and the human-imitation network (for the opponent's moves).

### Non-goals for version 1
Online play, time controls/clocks, two engines playing each other, manual dead-stone
marking, board sizes other than 9/13/19, sound, localisation, mobile.

## 2. Files the human puts in place before you start

These are downloaded on another machine and copied over. Paths are relative to the project root.

| Path | What |
|---|---|
| `engine/win/katago.exe` (+ DLLs) | KataGo Windows build (OpenCL build of v1.18.1, or CUDA build of v1.18.2) |
| `engine/analysis_example.cfg` | Copied from the KataGo zip, unmodified |
| `engine/models/main.bin.gz` | A `kata1-b18c384nbt-...` network, renamed |
| `engine/models/human.bin.gz` | `b18c384nbt-humanv0.bin.gz`, renamed |
| `docs/godot/` | Offline Godot documentation (optional but strongly recommended) |
| `tools/` | Godot 4.7.2 editor zips for Windows and macOS; unzip one and use that executable as `godot` |
| `testdata/*.sgf` | A few real game records (some from OGS) for testing the SGF parser |

On macOS KataGo is installed with Homebrew and lives at `/opt/homebrew/bin/katago`.
**The KataGo executable path, both model paths and the config path must be user-editable
settings** stored in `user://settings.json`, with per-OS defaults (`OS.get_name()`).

If any of these files are missing, stop and tell the human instead of inventing a substitute.
Milestones 1 to 3 do not need KataGo at all.

## 3. Ground rules for you

- Godot **4.x, GDScript only**, static typing everywhere (`var x: int`, typed function signatures). No C#, no GDExtension, no addons.
- Find the installed version with `godot --version` and only use APIs that exist in it. `OS.execute_with_pipe` requires 4.3 or newer; if the version is older, stop and say so.
- Godot 4 syntax, not Godot 3: `@export`, `@onready`, `signal_name.connect(callable)`, `await`, `FileAccess.open(...)`, `JSON.parse_string(...)`, `Callable.call_deferred()`. No `yield`, no `connect("x", self, "y")`, no `File.new()`.
- Keep **game logic free of Node/scene dependencies** (plain `RefCounted` classes) so it can be unit-tested headless.
- Build UI layouts **in code or with small `.tscn` files you write as text**; the human will not click around in the editor for you.
- Work through the milestones in section 7 in order. After each one: run the tests, run the project headless once to check for script errors (`godot --headless --quit-after 5`), then commit (`git init` at the start).
- Never touch scene tree nodes from a background thread. Threads hand data to the main thread with `call_deferred` or a mutex-protected queue drained in `_process`.

## 4. KataGo analysis engine reference

### 4.1 Starting it

```
katago analysis -config engine/analysis.cfg -model engine/models/main.bin.gz -human-model engine/models/human.bin.gz
```

Create `engine/analysis.cfg` by copying `engine/analysis_example.cfg` and setting (add the key if absent, replace it if present):

```
reportAnalysisWinratesAs = BLACK
ignorePreRootHistory = false
numAnalysisThreads = 2
numSearchThreadsPerAnalysisThread = 8
nnMaxBatchSize = 16
logToStderr = false
```

With `reportAnalysisWinratesAs = BLACK`, every `winrate` and `scoreLead` is from Black's point of view
(winrate 0.7 = Black 70%, scoreLead -3.5 = White ahead by 3.5). The whole app uses this convention.

Startup takes several seconds (longer the first time on OpenCL, which tunes itself; this can take minutes).
The engine is ready when it answers a `query_version` request.

### 4.2 Protocol

- One JSON object per line on stdin; one JSON object per line on stdout. Never send multi-line JSON.
- Asynchronous: responses arrive in any order, matched by `id`. A query with several `analyzeTurns` gives one response per turn.
- Startup chatter goes to stderr. Drain stderr continuously or the child may block.

### 4.3 Query

```json
{"id":"q17","moves":[["B","Q16"],["W","D4"],["B","pass"]],"initialStones":[["B","D16"]],
 "rules":"japanese","komi":6.5,"boardXSize":19,"boardYSize":19,
 "analyzeTurns":[0,1,2,3],"maxVisits":200,
 "includeOwnership":true,"includePolicy":true,
 "reportDuringSearchEvery":0.5,"priority":0,
 "overrideSettings":{"humanSLProfile":"rank_5k"}}
```

- `id`, `moves`, `rules`, `boardXSize`, `boardYSize` are required. `moves` may be `[]`.
- `initialStones`: handicap/setup stones. `initialPlayer` (`"B"`/`"W"`): who moves at turn 0 when needed.
- `rules`: `"japanese"`, `"chinese"`, `"korean"`, `"aga"`, `"new-zealand"`, `"tromp-taylor"`.
- `analyzeTurns`: turn 0 is the position before any move; turn N is after N moves. Default: last turn only.
- `reportDuringSearchEvery`: seconds between partial results (`"isDuringSearch": true`). The final result always has `"isDuringSearch": false`.
- `priority`: higher runs first. Use this so interactive queries jump ahead of a background full-game review.
- `humanSLProfile` **must be inside `overrideSettings`**; on the outer object it is silently ignored.
- `analysisPVLen`: max length of each variation (use 15).

### 4.4 Move coordinates

GTP style: column letter then row number. Columns are `A B C D E F G H J K L M N O P Q R S T` (**the letter I is skipped**).
Row 1 is the **bottom** row. Pass is `"pass"`.

Internal convention for this app: `x` 0..size-1 from the left, `y` 0..size-1 from the **top**.
`gtp = LETTERS[x] + str(size - y)`.

### 4.5 Response

```json
{"id":"q17","turnNumber":2,"isDuringSearch":false,
 "rootInfo":{"winrate":0.52,"scoreLead":0.8,"visits":200,"currentPlayer":"W", "...":"..."},
 "moveInfos":[{"move":"D16","order":0,"visits":90,"winrate":0.52,"scoreLead":0.8,
               "prior":0.31,"humanPrior":0.22,"pv":["D16","Q4","R14"]}, "..."],
 "ownership":[ ... size*size floats ... ],
 "policy":[ ... size*size+1 floats ... ],
 "humanPolicy":[ ... size*size+1 floats ... ]}
```

- `moveInfos`: sorted candidates; `order` 0 is the engine's best. `pv` is the expected continuation starting with `move`.
- `ownership`: row-major from the **top-left** (index `y*size + x`), values -1..1. With our config, +1 = Black owns the point, -1 = White.
- `policy` / `humanPolicy`: same layout plus one final entry for pass. Illegal points are `-1`. The rest sum to 1. `humanPolicy` only appears when the human model is loaded and `includePolicy` is true.
- Errors: `{"error":"...","id":"..."}`. Warnings: `{"warning":"...","field":"...","id":"..."}` (analysis still proceeds). Log both.

### 4.6 Control actions

```json
{"id":"v1","action":"query_version"}
{"id":"t1","action":"terminate","terminateId":"q17"}
{"id":"t2","action":"terminate_all"}
```

Terminated queries still send a final response (`isDuringSearch:false`, possibly with `"noResults":true`).

### 4.7 Human-like profiles

`humanSLProfile` values: `rank_20k` ... `rank_1k`, `rank_1d` ... `rank_9d` (modern style),
`preaz_20k` ... `preaz_9d` (pre-AlphaGo style), `proyear_1800` ... `proyear_2023` (professional of that year).

## 5. Architecture

```
project.godot
engine/                      (KataGo files, not code)
scripts/
  core/
    board.gd                 Board: grid, legality, captures, ko        (RefCounted)
    game_tree.gd             GameNode + GameTree: moves, variations     (RefCounted)
    sgf.gd                   SGF parse / serialise                      (RefCounted, static funcs)
    coords.gd                x,y <-> GTP <-> SGF conversions            (static funcs)
  engine/
    katago_process.gd        child process, reader threads, line I/O    (Node, autoload "KataGo")
    analysis_service.gd      builds queries, caches results per node    (Node, autoload "Analysis")
    ai_player.gd             picks the opponent's move                  (RefCounted)
  ui/
    main.gd / main.tscn      layout, menus, mode switching
    board_view.gd            draws board, stones, overlays; emits clicks (Control, custom _draw)
    graph_view.gd            win-rate/score graph                        (Control, custom _draw)
    tree_view.gd             move tree                                   (Control, custom _draw)
    new_game_dialog.gd, settings_dialog.gd, info_panel.gd
  settings.gd                load/save user://settings.json             (autoload "Settings")
tests/
  run_tests.gd               extends SceneTree; runs all test_*.gd, exits non-zero on failure
  test_board.gd, test_sgf.gd, test_coords.gd, test_game_tree.gd
testdata/
```

### 5.1 Core data model

- `Board`: `size: int`, `grid: PackedByteArray` (0 empty, 1 black, 2 white), `ko_point: Vector2i`, capture counts.
  - `play(x, y, color) -> bool` : rejects occupied points, suicide and simple ko; removes captured groups.
  - `is_legal(x, y, color) -> bool`, `duplicate_board() -> Board`.
  - Simple ko only (no superko) is enough.
- `GameNode`: `parent`, `children: Array[GameNode]`, `move` (color + Vector2i, or pass, or none for root),
  `setup_black/white` stones, `comment`, `analysis: Dictionary` (cached engine result, see 5.3).
- `GameTree`: `root`, `current`, metadata (`size`, `komi`, `rules`, `handicap`, player names, result).
  - `play_move()` adds a child or follows an existing identical child; `go_to(node)`; `main_line()`;
    `moves_to(node)` returns the move list from the root for engine queries;
    `board_at(node)` replays moves to build a `Board` (cache it per node).
- SGF: support `GM FF SZ KM RU HA AB AW PB PW BR WR RE DT C B W` and nested variations `( ... )`.
  SGF coords are two letters `a`..`s`, column then row, origin top-left, **no skipped letter**; `B[]` or `B[tt]` on 19x19 is a pass.
  Handle escaped `\]` in comments. Unknown properties must be preserved and written back unchanged.

### 5.2 Engine process (`katago_process.gd`)

- Start with `OS.execute_with_pipe(path, args)` which returns a Dictionary with `stdio` (FileAccess), `stderr` (FileAccess) and `pid`.
- One `Thread` loops on `stdio.get_line()` and pushes each non-empty line into a `Mutex`-guarded array.
  A second `Thread` drains `stderr` into a log buffer (show the last lines in the settings dialog for troubleshooting).
- `_process` pops lines, parses JSON, emits `response_received(dict)`.
- `send(dict)`: `stdio.store_line(JSON.stringify(dict))` then `stdio.flush()`.
- Signals: `engine_ready`, `engine_failed(message)`, `response_received(dict)`.
- On `_exit_tree`/quit: `terminate_all`, close pipes, `OS.kill(pid)`, `wait_to_finish()` on threads.
- Detect a dead engine with `OS.is_process_running(pid)` and offer a restart button.
- **Verify the pipe behaviour first** with a 30-line throwaway script that starts KataGo, sends `query_version` and prints the reply, before building anything on top of it.

### 5.3 Analysis service

- `request(node, visits, opts) -> id`; results are stored in `node.analysis`:
  `{visits, winrate, score_lead, moves: [{move, visits, winrate, score_lead, prior, pv}], ownership}`
  and announced with `analysis_updated(node)`. Keep the result with the most visits; never overwrite with fewer.
- **Full review**: one query listing every turn of the main line in `analyzeTurns`, `maxVisits` from settings (default 200), `includeOwnership: true`, `priority: 0`. Emits progress (turns done / total).
- **Live analysis** of the current position: `maxVisits` 2000, `reportDuringSearchEvery: 0.3`, `priority: 10`. When the current node changes, `terminate` the previous live query.
- For a node in a side variation, send its own move list with the default single turn.

### 5.4 Opponent move selection (`ai_player.gd`)

1. Send the position with `maxVisits: 40`, `includePolicy: true`, `priority: 20`, `overrideSettings: {"humanSLProfile": <profile>}`.
2. If `moveInfos[0].move == "pass"` and the previous move was also a pass or the move number is past `size*size/2`: pass.
3. Otherwise take `humanPolicy`, drop the pass entry and illegal (`-1`) entries, drop entries below 2% of the largest entry (removes absurd outliers), renormalise, and **sample one move at random according to those probabilities**.
4. Resign if the engine side's win rate is below 3% and it is behind by 25+ points after move 100 (setting to disable).
5. Wait at least 0.5 s before playing so the move does not feel instant.

Do not pick the search's best move: that would play at full strength. The human policy sample is what makes it human-like.

## 6. Feature specifications

### 6.1 Play mode
- New game dialog: board size (9/13/19; note next to 9 and 13 that the human model is most accurate on 19), human colour (black/white/random), opponent rank (20k..9d), style (modern/pre-AI), handicap 0..9 with standard star-point placement, komi (default 6.5; 0.5 with handicap), rules (Japanese default, Chinese).
- Click to play, ghost stone on hover, last-move marker, captures count, pass / undo (takes back a full move pair) / resign buttons.
- **No analysis output is visible during a game** unless the user ticks "show hints".
- Two consecutive passes end the game: request ownership at 500 visits, show the ownership overlay and report the result as the engine's `scoreLead` rounded to the nearest 0.5 ("B+3.5 (engine estimate)"). Write it to `RE`.
- Auto-save every finished or abandoned game to `user://games/YYYY-MM-DD_HHMM.sgf`.

### 6.2 Review mode
- Entered from a finished game or by loading an SGF (File > Open, and drag-and-drop onto the window via `get_window().files_dropped`).
- Navigation: left/right = one move, up/down = switch variation, Home/End, mouse wheel over the board, click on the graph or tree.
- Clicking the board in review mode adds a variation move.
- **Graph** (`graph_view.gd`): x = move number, win-rate line (Black %, 0..100, 50% midline) and score-lead line on a second scale; vertical cursor at the current move; dots on mistakes; shows progress while the review is still running.
- **Mistake classification** for the move that leads from turn t to t+1, using Black-perspective score:
  `loss = (score[t] - score[t+1]) * (1 if mover is Black else -1)`.
  2..5 = inaccuracy (yellow), 5..10 = mistake (orange), 10+ = blunder (red). Thresholds are settings.
  Side panel lists the top mistakes per player; clicking one jumps to it.
- **Candidate moves**: up to 8 `moveInfos` with at least 1% of root visits, drawn as circles on their points. Best move blue, others shaded green to red by points lost versus the best. Text inside: win rate for the player to move, and points lost. Hovering a candidate draws its `pv` as numbered semi-transparent stones. The move actually played in the game is ringed.
- **Ownership overlay** (toggle): small squares on each point, black or white, alpha = |ownership|. Show "Black +x.x" score estimate.
- **Info panel**: win rate bar, score lead, visits, player names, comment box (edits the SGF `C` property).
- **Move tree** (`tree_view.gd`): main line horizontal, variations branch below; current node highlighted; scrollable.
- Toggles for: live analysis on/off, candidates, ownership, move numbers, coordinates.

### 6.3 Settings
Engine path, model paths, config path, review visits, live visits, mistake thresholds, board colours,
engine status and last 50 stderr lines, "restart engine" button.

## 7. Milestones

Each milestone ends with the listed check passing. Do not start the next one until it does.

1. **Project skeleton + coords + board rules.** `project.godot`, folders, test runner.
   Check: `godot --headless --script tests/run_tests.gd` passes tests for coordinate round-trips (including the skipped I), single and multi-stone capture, suicide rejection, ko rejection and ko release after a move elsewhere, capture-that-is-not-suicide.
2. **Game tree + SGF.**
   Check: every file in `testdata/` parses, re-serialises and re-parses to an identical tree; variations, passes, handicap stones and escaped comments are covered by tests.
3. **Board view + local two-human play.** Resizable board drawing, star points, coordinates, click-to-play, undo, pass, load/save SGF, keyboard navigation.
   Check: project runs with no script errors; a human can play out and reload a game.
4. **Engine process.** Pipe spike first (section 5.2), then `katago_process.gd` and the settings dialog.
   Check: a headless script starts KataGo, gets a `query_version` reply, analyses an empty 19x19 board at 50 visits, prints the best move and exits cleanly with no orphaned `katago` process.
5. **Human-like opponent.** `ai_player.gd`, new game dialog, play mode, end-of-game scoring, auto-save.
   Check: a headless script plays 30 moves of engine-vs-engine at `rank_10k` with every move legal according to `Board`; a human can play a full game in the UI.
6. **Review: full-game analysis + graph + mistakes list.**
   Check: loading a test SGF produces a result for every turn, the graph renders, and clicking it navigates.
7. **Review: candidates, hover variations, ownership overlay, live analysis.**
   Check: changing position cancels the old live query (confirm by logging ids) and overlays update without stutter.
8. **Move tree view + variation editing + comments.**
   Check: add a variation in review, save, reload, and the variation is intact.
9. **Polish + macOS.** Per-OS default paths, window layout at small sizes, error messages when the engine is missing or crashes, export presets for Windows and macOS.
   Check: fresh `user://` folder on each OS gives a working first run or a clear message saying which path to set.

## 8. Known pitfalls

- `FileAccess.get_line()` on a pipe **blocks**; that is why reading lives on its own thread. Closing the pipe / killing the process is how the thread is released on shutdown.
- If the engine never answers, look at stderr first: wrong model path, wrong config key and missing GPU drivers all report there.
- JSON numbers come back as `float` in GDScript; cast `turnNumber` and `visits` with `int()`.
- `JSON.stringify` of a large `analyzeTurns` query is fine, but must stay on one line (do not pass an indent argument).
- Custom-drawn controls need `queue_redraw()` after state changes and must recompute geometry from `size` in `_draw`, so resizing works.
- The GTP letter set skips `I`; SGF does not. Keep all conversions in `coords.gd` and nowhere else.
- Row order: engine arrays and SGF both start at the **top**; GTP row numbers start at the **bottom**.
- On macOS a sandboxed exported app cannot launch Homebrew binaries; disable the app sandbox in the export preset.
- If `OS.execute_with_pipe` proves unreliable on one platform, the fallback is a 40-line Python script that relays KataGo's stdin/stdout over a local TCP socket, with Godot using `StreamPeerTCP`. Only do this if the spike in milestone 4 fails, and tell the human first.
