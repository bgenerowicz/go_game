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
