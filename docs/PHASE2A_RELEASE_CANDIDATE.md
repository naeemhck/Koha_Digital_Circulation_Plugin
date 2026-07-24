# Phase 2A release candidate

Artifact: `dist/JunaidZaidiLibrary-DigitalCirculation-v0.2.0-rc1.kpz`

- Internal plugin version: `0.2.0`
- Release suffix: `rc1` (artifact filename only)
- Schema version: `1`
- Minimum Koha version: `26.05.00.000`
- EbookContent dependency: `Koha::Plugin::Com::Ecombranding::EbookContent` `0.1.2`
- Size: `32185` bytes
- Members: `26`
- SHA-256: `262f33bbbc07ff21e02c9fd08cd366e5bf82e453c9089cc7de3375741930c359`

The package was assembled from sorted `MANIFEST` source entries with normalized forward-slash archive paths and a fixed entry timestamp. Package validation confirmed exact manifest membership, required Phase 2A runtime modules, root-level operational and configuration templates, one OpenAPI POST route (`/requests`), unique operation IDs, the closed request-body schema, documented headers/responses, read-only staff controls, and the absence of tests, diagnostics, nested packages, local paths, and literal credentials.

The preserved `v0.1.0` artifact is stale relative to Phase 2A source and is retained only as the previously produced package. It lacks the administrator configuration template, Phase 2A authorization/application/EbookContent runtime services, and packaged `POST /requests`.

Installation and live verification remain pending and must follow `PHASE2A_DEPLOYMENT_AND_VERIFICATION.md` on a controlled Koha 26.05 test instance.
