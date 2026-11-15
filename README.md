# go_game

A local Go application built with Godot 4: play against human-like KataGo opponents and review games with unlimited AI analysis.

- `PLAN.md` is the full build brief for the coding agent. Start there.
- `tools/README.md` lists the third-party downloads that live outside git.

## Layout

```
PLAN.md          build plan and KataGo protocol reference
engine/          KataGo binary, config and networks (binaries not in git)
tools/           Godot editor and other downloads (not in git)
docs/godot/      offline Godot documentation (not in git)
scripts/         GDScript source
tests/           headless tests
testdata/        SGF files for parser tests
```

## Prepared runtime (Linux sandbox)

The third-party inputs arrived under `local-assets/` (read-only, checksummed) and have
been prepared into the locations below. `local-assets/` itself is left untouched.

| Path | What |
|---|---|
| `runtime/godot-4.7.2/Godot_v4.7.2-stable_linux.x86_64` | the `godot` used for this project (4.7.2, matches `docs/godot/`) |
| `runtime/katago/katago` | KataGo v1.18.1, Eigen **CPU** backend (AVX2+FMA), plain ELF |
| `engine/models/main.bin.gz`, `engine/models/human.bin.gz` | the two networks |
| `testdata/*.sgf` | five upstream KataGo test fixtures for the SGF parser |
| `docs/Analysis_Engine.md` | KataGo 1.18.1 analysis protocol reference |
| `docs/licenses/` | KataGo + network licences, kept with the assets |

`runtime/` is gitignored. The VM also has an older `godot` (4.5.1) on `PATH`; the core
scripts happen to pass on both, but 4.7.2 above is the project's reference version.
There is no GPU here, so engine visit budgets used in tests must stay modest.

## Milestones

All nine milestones in `PLAN.md` are implemented. Each one is covered by a script
that can be re-run; the unit suite is the fast one, the `check_*` scripts drive the
real KataGo binary and are slower (CPU-only here).

| # | What | How to re-check it |
|---|---|---|
| 1 | Coords, board rules (capture, suicide, ko), test runner | `--script tests/run_tests.gd` |
| 2 | Game tree, SGF reader/writer, unknown properties preserved | `--script tests/run_tests.gd` (`test_sgf.gd` round-trips every `testdata/` file) |
| 3 | Board view, two-human play, load/save SGF, keyboard nav | `--script tests/smoke_ui.gd`, `--script tests/render_check.gd` |
| 4 | Engine process over pipes, settings dialog | `--script tests/check_engine.gd` |
| 5 | Human-like opponent, new-game dialog, scoring, auto-save | `--script tests/check_ai_game.gd` (30 real engine moves) |
| 6 | Full-game review, win-rate graph, mistakes list | `--script tests/check_review.gd` |
| 7 | Live analysis, candidate overlay, hover variations, ownership | `--script tests/check_live.gd` |
| 8 | Move tree view, variation editing, comments | `--script tests/check_variations.gd` |
| 9 | Per-OS engine paths, small-window layout, engine error messages, export presets | `--script tests/check_first_run.gd`, `check_window_layout.gd`, `check_engine_crash.gd` |

Run them with:

```
GODOT=runtime/godot-4.7.2/Godot_v4.7.2-stable_linux.x86_64
$GODOT --headless --import                 # once, after adding scripts
$GODOT --headless --script tests/run_tests.gd      # unit tests, no engine needed
$GODOT --headless --script tests/smoke_ui.gd       # builds the real UI, no engine
$GODOT --headless --quit-after 5           # the app itself starts clean
```

The engine-backed checks (`check_engine`, `check_ai_game`, `check_review`,
`check_live`) need `engine/` in place and take a few minutes each on CPU.

### Checking the drawing without eyes

`tests/render_check.gd` (board) and `tests/render_graph.gd` (win-rate graph) render a
known position, save a screenshot and print the exact pixel coordinates they used.
`tools/pixel_assert.py` then reads those coordinates back out of the log and inspects
the PNG, so the drawing is verified from outside the engine. Run them in one shell
command, in that order:

```
with-display $GODOT --path . --script tests/render_check.gd > /tmp/render.txt 2>&1
python3 tools/pixel_assert.py /tmp/render.txt /tmp/go_game_render.png
with-display $GODOT --path . --script tests/render_graph.gd > /tmp/graph.txt 2>&1
python3 tools/pixel_assert.py /tmp/graph.txt /tmp/go_game_graph.png
```

Each prints `pixel assertions: 11/11 ok`. The tool classifies a patch of pixels as
black / white / wood / other, and for the graph it checks the colour of the line and
the mistake dots at their predicted positions. A deliberately wrong coordinate
mapping makes it fail, which is how the check itself was validated.

## Running the app

On the Mac, `build/macos/go_game.app` is the exported app. It is rebuilt
automatically after every commit (`.githooks/post-commit`, enabled once with
`git config core.hooksPath .githooks`), or by hand with `tools/export_macos.sh`.
It bundles the networks and config; the KataGo binary comes from Homebrew.

```
with-display $GODOT --path .        # the window itself, on the virtual display
```

There is no screen here, so interactive play can only be driven by the scripted
checks above (`tests/smoke_ui.gd` presses real buttons and asserts on the results).

## Implementation notes

The file layout follows `PLAN.md` section 5 with two deliberate differences:

- There is no `scripts/ui/info_panel.gd`. The info panel (status, captures, result,
  engine status, graph, win-rate bar, player names, ownership estimate, clickable
  mistake list, comment box) is built and refreshed inside `scripts/ui/main.gd`,
  because it is interleaved with the layout and menu code that owns it. The node
  names are unchanged (`Column/Body/SideScroller/Side/...`), which is what
  `tests/smoke_ui.gd` asserts against.
- A few extra core files beyond the plan's list: `game_node.gd` (the tree node,
  split out of `game_tree.gd`), `game_flow.gd` (whose turn it is, mode switching,
  auto-save), `review.gd` (mistake classification over a whole game) and
  `scoring.gd` (area/territory scoring for the pass-end dialog).

Ko is the simple ko the plan asks for ("Simple ko only (no superko) is enough"),
not positional superko.

## Known limits of this sandbox

- No GPU: KataGo runs on its Eigen CPU backend, so the visit budgets in the checks
  are deliberately small (the 2000-visit live budget in `PLAN.md` is the default for
  real use, not for these runs).
- Windows and macOS export presets are written and validated as text, but their
  templates cannot be downloaded or built here, so those exports are untested.
- `OS.execute_with_pipe` was verified on Linux only.

