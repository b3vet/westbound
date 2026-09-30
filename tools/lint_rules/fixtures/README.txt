Seeded-violation fixtures for `tools/lint --self-test`. This directory is a
mini repo (src/, assets/, tests/ are resolved relative to it). Every line that
must trigger carries `expect: WBxxx[, WByyy]`; everything else must stay clean.
The .gdignore keeps Godot from importing these deliberately broken files, and
tools/lint skips .gdignore'd directories when linting the real repo.
