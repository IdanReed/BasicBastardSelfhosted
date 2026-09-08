# Grafana + the VictoriaLogs datasource, for a store with no Loki-compatible
# query API.
#
# 🚨 EVERY input is pinned, same argument as stacks/caddy/Dockerfile: the
# artifact is a function of BOTH, so the published tag is <grafana>-vl<plugin>
# and a plugin-only bump forces a compose-pin edit — which IS the deploy. A
# mutable tag once republished a different binary under the same name and the
# host, already holding it, never repulled.
#
# .github/workflows/build-grafana-vlogs.yml greps the LAST `FROM
# grafana/grafana:` line and the version out of the plugin URL — keep both
# lines in exactly this form.
#
# WHY THIS EXISTS AT ALL: the plugin has no offline install path that the
# no-runtime-downloads rule allows. Grafana's installer does os.Stat the
# "URL" before trying HTTP (pkg/plugins/repo/client.go), so a LOCAL zip
# installs with zero network — but that zip still has to reach the host, and
# a baked image is the only channel that is a `docker pull`.
#
# ⚠ NOT /var/lib/grafana/plugins: that path is the bind mount at runtime and
# would shadow anything baked in. GF_PATHS_PLUGINS points elsewhere, which is
# what grafana's own packaging/docker/custom/Dockerfile does.
#
# TO BUMP: change the FROM and the plugin version together (or either alone),
# then move the compose pin and run ./tests/update-images.sh.
FROM grafana/grafana:13.2.0
USER root
RUN mkdir -p /var/lib/grafana-plugins && chown -R grafana:0 /var/lib/grafana-plugins
ADD --chown=grafana:0 \
  https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions/0.31.0/download \
  /tmp/vl.zip
USER grafana
# The CLI, not an unzip: it is what sets the backend binary executable, and a
# non-executable backend logs "Could not start plugin backend" while Grafana
# still reports itself healthy.
RUN grafana cli --pluginUrl /tmp/vl.zip --pluginsDir /var/lib/grafana-plugins \
      plugins install victoriametrics-logs-datasource \
 && rm /tmp/vl.zip
ENV GF_PATHS_PLUGINS=/var/lib/grafana-plugins
