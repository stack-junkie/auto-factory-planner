# Auto Factory Planner

A community fork of DefGh’s Factorio mod. Choose products and target rates, review the production chain, then generate a blueprint or apply the plan through a factory controller. This fork improves belt routing, standalone plot sizing, and assembler counts when two ingredients share a feed.

Requires Factorio 2.1.23 or later in the 2.1 series. Space Age is optional. The mod keeps its original ID, `auto-factory-planner`, so existing drafts and saves can use it.

## Install on Windows

With Git and Python 3.9+ on PATH, run this from the repository root:

```powershell
python scripts/release.py install
```

The command builds the ZIP and installs it under `%APPDATA%\Factorio\mods`. Restart Factorio, open your draft and click **Calculate plan**. For a portable installation, pass `--mods-dir "D:\Factorio\mods"`. To build the ZIP in `dist/` without installing, use `python scripts/release.py build`.

## Development

Enable the repository hooks once per clone:

```powershell
git config core.hooksPath .githooks
```

Edit the installable files in `mod/`. For gameplay changes, bump the version in `mod/info.json`, describe the change under the same version in `CHANGELOG.md`, and stage new package files before building. The pre-commit hook checks the staged release metadata. The pre-push hook builds the package. GitHub Actions runs the checks on pushes and pull requests.

The five initial tags, `v0.3.41` through `v0.3.45`, are source snapshots recovered from release ZIPs. The files are at the root of those tags. Current development uses `mod/`.

[Player guide (English and Russian)](mod/README.md) · [Fork changelog](CHANGELOG.md) · [Original credits](mod/release/credits.txt) · [MIT license](LICENSE)
