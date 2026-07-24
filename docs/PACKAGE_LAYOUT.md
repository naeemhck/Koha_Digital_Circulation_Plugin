# Package layout

Koha 26.05 `Koha::Plugins::Base::get_template` passes a relative filename through `Module::Bundled::Files::mbf_path`. Therefore the operational and configuration templates resolve at the plugin bundle root:

`Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/tool.tt`

`Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/configure.tt`

The KPZ has `Koha/` as its only top-level directory and contains `DigitalCirculation.pm`, root-level `tool.tt` and `configure.tt`, `openapi.json`, controllers, repositories, services, and `static/css` and `static/js`. There is no repository-name wrapper directory and no duplicate template under the obsolete `templates/` path.

The REST namespace is `jzl-digital-circulation`. Staff assets use extensionless logical identifiers under `/api/v1/contrib/jzl-digital-circulation/assets/{asset}`:

- `jzl-digital-circulation-js` → packaged `static/js/jzl-digital-circulation.js`
- `jzl-digital-circulation-css` → packaged `static/css/jzl-digital-circulation.css`

Extension-bearing URLs ending in `.js` or `.css` are not used because Mojolicious treats those suffixes as response formats and never reaches `Assets#serve`. This is an internal RC correction, not a public API compatibility surface.

The Phase 2A release candidate is `dist/JunaidZaidiLibrary-DigitalCirculation-v0.2.0-rc1.kpz`. Its internal plugin version is `0.2.0`; `rc1` is an artifact filename suffix and does not alter plugin metadata or schema version 1.
