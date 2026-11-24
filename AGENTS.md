# Auto Factory Planner

- Edit gameplay code in `mod/`. Factorio reads the version and dependencies from `mod/info.json`. Keep the mod ID stable for existing saves.
- For packaged changes, bump the three-part version and add a matching section to `CHANGELOG.md`. Keep upstream attribution and credits with the package.
- Run `python scripts/release.py check` and `python scripts/release.py build`. Use a copy of the affected save for runtime checks. Exercise Calculate plan and Create blueprint for generation changes.
- Keep saves, logs, generated blueprints and release archives outside Git. Preserve the original release tags.
