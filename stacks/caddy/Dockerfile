# Caddy + the cloudflare-dns provider, for the DNS-01 wildcard cert.
#
# EVERY input here is pinned, because the artifact is the root, host-networked
# process that terminates TLS for ~40 vhosts and holds a Cloudflare API token:
#
#   caddy:2.11.2-builder / caddy:2.11.2  the base images (also read by
#                                        .github/workflows/build-caddy.yml,
#                                        which greps the LAST `FROM caddy:`
#                                        line for half the published tag — keep
#                                        it last and keep the form exact).
#   v2.11.2                              the Caddy version xcaddy COMPILES.
#                                        Without it `xcaddy build` takes
#                                        whatever is latest at build time, so
#                                        the binary copied over the 2.11.2 one
#                                        below need not have been 2.11.2 at
#                                        all — the tag said one thing and the
#                                        binary was another.
#   @v0.2.4                              the DNS plugin. Unpinned, this
#                                        resolved to the module's latest tag
#                                        on every rebuild: a compromised or
#                                        merely broken upstream release lands
#                                        in root's TLS terminator with no
#                                        review and no diff. build-caddy.yml
#                                        greps this line too — the published
#                                        tag is <caddy>-cf<plugin>, because the
#                                        binary is a function of BOTH and a
#                                        plugin-only bump used to republish a
#                                        DIFFERENT binary under the same
#                                        `2.11.2` tag (which the host, already
#                                        holding it, never repulls).
#
# ⚠ NEXT REBUILD: stacks/caddy/compose.yaml still pins the bare `2.11.2` that
#   the old scheme published. That image stays in GHCR and keeps working, but
#   the workflow no longer writes that tag — the first rebuild after this
#   change must move the compose pin to the composite tag (2.11.2-cf0.2.4) and
#   the matching SUBSTITUTES entry in tests/update-images.sh with it.
#
# TO BUMP (checked 2026-08-31, plugin v0.2.4 = master @ a8737d0, 2026-03-23):
#   caddy:      https://github.com/caddyserver/caddy/releases — change all
#               three occurrences (both FROMs and the xcaddy argument) and run
#               ./tests/update-images.sh, since stacks/caddy/compose.yaml pins
#               the published tag to match.
#   plugin:     https://github.com/caddy-dns/cloudflare/tags — read the diff
#               before bumping; it is four files. A plugin-only bump moves the
#               published tag too, so it needs the same compose-pin edit as a
#               caddy bump — that is the point of the composite tag.
FROM caddy:2.11.2-builder AS builder
RUN xcaddy build v2.11.2 --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2.11.2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
