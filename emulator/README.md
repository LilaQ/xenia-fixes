# Emulator source fixes and builds

Version-specific Xenia Canary/Edge source patches, build helpers and config templates. See [`build-inputs.json`](build-inputs.json) for pinned revisions and named build recipes. [`patches/`](patches/) contains both aggregate patches and development variants; never apply every patch in that directory together. In particular, the Rivals complete aggregate is applied alone to its documented base revision.

[`files/`](files/) contains additional source files and narrow configuration overrides. [`config-templates/`](config-templates/) contains game configurations. [`tools/`](tools/) and [`tests/`](tests/) retain their existing relative layout. Building or running these tools is separate from installing a game TOML. Older test/diagnostic variants are retained as source, not recommended configurations for every title.

The [pixel-fetch residency project](pixel-fetch-residency/) has its own pinned binary builders and tests. Original emulator binaries, game inputs and capture outputs must remain local and untracked.

These changes cover renderer synchronization, geometry/readback, texture upload/pacing, microphone support, title-module loading and build portability. Use the named recipe and matching game/config; improvements for one title are not automatically safe for all other titles.
