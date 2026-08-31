# Caddy + the cloudflare-dns provider, for the DNS-01 wildcard cert.
#
# EVERY input here is pinned, because the artifact is the root, host-networked
# process that terminates TLS for ~40 vhosts and holds a Cloudflare API token:
#
#   caddy:2.11.2-builder / caddy:2.11.2  the base images (also read by
#                                        .github/workflows/build-caddy.yml,
#                                        which greps the LAST `FROM caddy:`
#                                        line for the published tag — keep it
#                                        last and keep the form exact).
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
#                                        review and no diff.
#
# TO BUMP (checked 2026-08-31, plugin v0.2.4 = master @ a8737d0, 2026-03-23):
#   caddy:      https://github.com/caddyserver/caddy/releases — change all
#               three occurrences (both FROMs and the xcaddy argument) and run
#               ./tests/update-images.sh, since stacks/caddy/compose.yaml pins
#               the published tag to match.
#   plugin:     https://github.com/caddy-dns/cloudflare/tags — read the diff
#               before bumping; it is four files.
FROM caddy:2.11.2-builder AS builder
RUN xcaddy build v2.11.2 --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2.11.2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
