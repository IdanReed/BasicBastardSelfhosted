# Caddy + the cloudflare-dns provider, for the DNS-01 wildcard cert.
#
# 🚨 EVERY input is pinned, because the artifact is the root, host-networked
# process that terminates TLS for ~40 vhosts and holds a Cloudflare API token.
# The xcaddy version argument is not optional: without it `xcaddy build` takes
# whatever is latest, so the binary copied over the pinned base need not match
# its tag. An unpinned plugin lands an unreviewed upstream release in root's
# TLS terminator the same way.
#
# .github/workflows/build-caddy.yml greps the LAST `FROM caddy:` line and the
# plugin version to build the published tag <caddy>-cf<plugin> — keep both
# lines in exactly this form. The composite tag exists because the binary is a
# function of both, and a plugin-only bump once republished a different binary
# under the same `2.11.2` tag, which a host already holding it never repulls.
#
# TO BUMP: change all three caddy occurrences together, or the plugin version,
# then update the compose pin and run ./tests/update-images.sh.
FROM caddy:2.11.2-builder AS builder
RUN xcaddy build v2.11.2 --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2.11.2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
