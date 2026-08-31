- 2026-08-31 03:05 (real): **DocSpace and Gatus LANDED into `stacks/`** — moved
  from the scratchpad now that all ten suites are green and the image pins were
  clean, so one `update-images.sh` cycle covers both. Wired: 8 tmpfiles rules,
  2 Caddy routes, 1 blueprint entry (Gatus only), the `host-network-declared`
  entry for Gatus, a `mysqldump` branch for `docspace_db` in
  `backup-prepare.sh`, the encrypted fixture, and both `_overview` rows.
  Two auth decisions taken here, both following fleet precedent rather than the
  annexes' defaults:
  - **DocSpace gets NO forward auth.** It has real accounts (the portal owner
    that `docspace_init` creates through the wizard API) and desktop/mobile
    clients that a 302 would break — the same call as Immich, Kavita and
    audiobookshelf. Its row is corrected from OIDC to **SAML**, which is what
    it actually speaks and which is free self-hosted; the "Business plan for
    SSO" note was cloud pricing.
  - **Gatus gets forward auth, and it is the ONLY control.** Its own `security`
    block leaves the SPA, `/api/v1/config` and every uptime-history route on an
    UNPROTECTED router, so anyone reaching the port reads the fleet's
    availability data. Its OIDC must never be enabled either: it panics at
    startup if discovery fails, which would restart-loop the one service that
    has to stay up when others do not.
  `backup-prepare.sh` gains a second MySQL branch rather than a loop, and the
  comment says why the MariaDB rename (finding #35) does not apply: MySQL 8.4
  still ships `mysqldump`.
