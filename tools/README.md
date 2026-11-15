# Third-party downloads

These files are not in git (see `.gitignore`). Copy the whole project folder to move them to another machine.

| File | Goes where | Source |
|---|---|---|
| `tools/Godot_v4.7.2-stable_win64.exe.zip` | unzip anywhere, run the editor | https://github.com/godotengine/godot/releases/tag/4.7.2-stable |
| `tools/Godot_v4.7.2-stable_macos.universal.zip` | unzip on the Mac | same |
| `tools/katago-v1.18.1-opencl-windows-x64.zip` | already unzipped into `engine/win/` | https://github.com/lightvector/KataGo/releases/tag/v1.18.1 |
| `tools/godot-docs-html-stable.zip` | already unzipped into `docs/godot/` | https://docs.godotengine.org (offline HTML build) |
| `engine/models/main.bin.gz` | used as is | `kata1-b18c384nbt-s9996604416-d4316597426.bin.gz` from https://katagotraining.org/networks/ |
| `engine/models/human.bin.gz` | used as is | `b18c384nbt-humanv0.bin.gz` from https://katagotraining.org/extra_networks/ |

On macOS, KataGo itself comes from Homebrew: `brew install katago`. Only the two model files need copying.

# Helper scripts in this folder

These are small tools, not part of the game. They are in git and need no downloads.

| Script | What it does |
|---|---|
| `pixel_assert.py` | Reads the `PIXEL col,row C x y` lines that `tests/render_check.gd` prints and checks the saved PNG really has a black stone, white stone or bare wood at each of those coordinates. Exits non-zero on a mismatch. Standard library only. |
| `make_analysis_cfg.py` | Writes `engine/analysis.cfg` with the keys the analysis engine needs, so the config is reproducible instead of hand-typed. |
| `board_measure.py` | Reports the board geometry (origin, cell size) it finds in a screenshot, for debugging the drawing when a pixel assertion fails. |
| `export_macos.sh` | Builds `build/macos/go_game.app` (release export, networks and config bundled in `Contents/Resources/engine/`, ad-hoc signed). Runs automatically after every commit through `.githooks/post-commit` (enable once per clone: `git config core.hooksPath .githooks`); log in `build/macos/export.log`. Needs the Godot 4.5.1 macOS export template and Homebrew's `katago`. |
| `match_levels.gd` | Plays two opponent levels against each other through the real engine and writes one CSV row per game plus a win-rate summary. `godot --headless --path . --script res://tools/match_levels.gd -- --a=rank_beginner --b=rank_20k --games=100 --size=9`. The first run is in `docs/match_beginner_vs_20k.csv`. |
| `spike_katago.gd`, `spike_process.gd`, `probe_paths.gd` | The throwaway spikes from milestone 4, kept as a record of how `OS.execute_with_pipe` behaves and how the engine paths are probed. |

Example, in one command so the image exists before it is read:

```
with-display godot --path . --script tests/render_check.gd > /tmp/render.txt 2>&1
python3 tools/pixel_assert.py /tmp/render.txt /tmp/go_game_render.png
```

