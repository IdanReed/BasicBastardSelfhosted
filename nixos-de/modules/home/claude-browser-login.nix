{ pkgs, ... }:

# claude-browser-login — sign the Claude browser profile (the `browser` MCP, see
# home.nix) into Authentik as idan without a password, TOTP code or login token
# ever reaching a transcript.
#
#   claude-browser-login            mint an Authentik recovery link for idan on
#                                   the VPS, serve it as ONE 302 on loopback for
#                                   120 s, print only the loopback URL to open
#   claude-browser-login --revoke   delete idan's recovery tokens (a link is
#                                   valid for a year otherwise) and print how
#                                   many were removed
#
# A recovery link skips MFA by design (`ak create_recovery_key`); root on the
# VPS already implies that power. Allow-listed for the agent by exact command.
let
  claudeBrowserLogin = pkgs.writeShellApplication {
    name = "claude-browser-login";
    runtimeInputs = with pkgs; [
      openssh
      coreutils
      gnugrep
      python3
    ];
    text = ''
      # By IP, not the tailnet name: the VPS runs headscale, so its tailnet
      # name is gone exactly when a rebuilt Authentik needs a first login.
      vps="''${CLAUDE_LOGIN_VPS:-idan@128.140.6.222}"
      on_vps() {
        ssh -i /run/secrets/ssh/vps -o IdentitiesOnly=yes -o BatchMode=yes "$vps" "$1"
      }

      case "''${1:-}" in
        --revoke)
          on_vps "sudo docker exec authentik_server ak shell -c \"from authentik.core.models import Token, TokenIntents; q = Token.objects.filter(intent=TokenIntents.INTENT_RECOVERY, user__username='idan'); n = q.count(); q.delete(); print(f'deleted {n} recovery token(s) for idan')\""
          exit 0
          ;;
        "") ;;
        *)
          echo "usage: claude-browser-login [--revoke]" >&2
          exit 2
          ;;
      esac

      # The link never reaches stdout: it goes straight into the server's stdin.
      path=$(on_vps "sudo docker exec authentik_server ak create_recovery_key 1 idan" \
        | grep -o '/recovery/use-token/[^[:space:]]*' | head -1 || true)
      if [ -z "$path" ]; then
        echo "claude-browser-login: no recovery link in ak's output" >&2
        exit 1
      fi

      portfile=$(mktemp)
      # One request, one 302, then exit; killed after 120 s if never opened.
      printf 'https://auth.idanreed.com%s' "$path" | timeout 120 python3 -c '
      import http.server, sys
      location = sys.stdin.read()
      class Redirect(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              self.send_response(302)
              self.send_header("Location", location)
              self.end_headers()
          def log_message(self, *args):
              pass
      server = http.server.HTTPServer(("127.0.0.1", 0), Redirect)
      with open(sys.argv[1], "w") as f:
          f.write(str(server.server_address[1]))
      server.handle_request()
      ' "$portfile" >/dev/null 2>&1 &

      for _ in $(seq 50); do
        [ -s "$portfile" ] && break
        sleep 0.1
      done
      port=$(cat "$portfile")
      rm -f "$portfile"
      [ -n "$port" ] || { echo "claude-browser-login: redirect server did not start" >&2; exit 1; }
      echo "open http://127.0.0.1:$port/ in the Claude browser, then run: claude-browser-login --revoke"
    '';
  };
in
{
  home.packages = [ claudeBrowserLogin ];
}
