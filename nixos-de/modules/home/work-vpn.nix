# Work VPN + RDP, confined to a single process tree.
#
#   xfreerdp ──TCP──► 127.0.0.1:13389
#                          │  ocproxy (lwIP — a TCP/IP stack in userspace)
#                          ▼
#                     openconnect --script-tun    ← no tun device, no root
#                          │  TLS/DTLS
#                          ▼
#                     $gateway ──► $rdp_host:3389
#
# ocproxy, not a netns: --script-tun hands the tunnel's IP traffic to lwIP in
# userspace, so the kernel never learns the VPN exists — no interface, no route,
# no resolv.conf edit, no sudo, and zero residue when openconnect dies.
#
# COST, in the order it will bite:
#   1. lwIP is TCP-only — the session must not negotiate RDP's UDP transport
#      (hence -multitransport in workrdp).
#   2. lwIP is single-threaded. Fine at 1080p; a 4K/multi-monitor throughput
#      ceiling is the signal to move to a netns, not to tune this.
#   3. ocproxy is low-activity upstream (1.60); netns is the escape hatch.
#
# /run/secrets is hardcoded because home-manager is standalone here (`hms`
# cannot see config.sops) and sops-nix's defaultSymlinkPath makes it
# deterministic. Same reasoning as modules/home/ssh-identities.nix.
{ pkgs, lib, ... }:

let
  # Loopback-only, unprivileged, and clear of anything else on the desktop.
  lport = 13389;
  socksPort = 11080;

  # openconnect runs --script through `sh -c`, which is not guaranteed to
  # inherit writeShellApplication's PATH — reference the store path directly.
  ocproxy = "${pkgs.ocproxy}/bin/ocproxy";

  # Drives the SAML login the openconnect CLI structurally cannot do; see the
  # header of pkgs/openconnect-saml.nix for the full reasoning.
  openconnect-saml = pkgs.callPackage ../../pkgs/openconnect-saml.nix { };

  # Load exactly the parameters a given wrapper uses. Loading all five
  # everywhere would trip shellcheck's unused-variable check, which
  # writeShellApplication treats as a build failure.
  loadSecrets =
    names:
    ''
      _need() {
        local f="/run/secrets/workvpn/$1"
        if [[ ! -r "$f" ]]; then
          echo "work-vpn: cannot read $f" >&2
          echo "  The workvpn: block is missing from nixos-de/secrets.sops.yaml." >&2
          echo "  Copy the shape from secrets.sops.yaml.example, then:" >&2
          echo "    sopsedit nixos-de/secrets.sops.yaml   # fill in real values" >&2
          echo "    nrs                                   # apply the system half" >&2
          exit 1
        fi
        printf '%s' "$(<"$f")"
      }

    ''
    + lib.concatMapStrings (n: "${n}=$(_need ${n})\n") names;

  workvpn = pkgs.writeShellApplication {
    name = "workvpn";
    runtimeInputs = [
      pkgs.openconnect
      openconnect-saml
      pkgs.coreutils # mktemp
    ];
    text = ''
      ${loadSecrets [
        "gateway"
        "vpn_user"
        "authgroup"
        "rdp_host"
      ]}

      echo "workvpn: $vpn_user @ $gateway -> $rdp_host:3389 published on 127.0.0.1:${toString lport}"
      echo "workvpn: SOCKS5 on 127.0.0.1:${toString socksPort}. Ctrl-C disconnects."

      # STEP 1 — SAML/SSO in a Qt WebEngine window. The gateway sends no
      # <sso-v2-browser-mode>, so plain `openconnect` dies with "No SSO handler"
      # whatever flags it gets; --auth-only prints HOST/COOKIE/FINGERPRINT and
      # exits without touching openconnect, sudo, or the routing table.
      #
      # NO --user, ON PURPOSE: credentials make openconnect-saml inject an
      # autofill userscript that WIPES the MFA code as you type it into Entra's
      # multi-step form. A throwaway config per run is what makes that stick —
      # credentials are also read from the persisted config, which earlier runs
      # saved, so dropping --user alone would not have helped.
      saml_cfg="$(mktemp -d)"
      trap 'rm -rf "$saml_cfg"' EXIT

      # Pre-initialised because `eval` hides the assignment from both the
      # linter and `set -u`. (Do not start that comment line with the linter's
      # name — it gets parsed as a directive and fails the build.)
      HOST=""
      COOKIE=""
      FINGERPRINT=""
      # Values are shlex-quoted upstream, so eval is safe here.
      eval "$(OPENCONNECT_SAML_CONFIG="$saml_cfg/config.toml" openconnect-saml \
        --server "$gateway" \
        --authgroup "$authgroup" \
        --browser qt \
        --auth-only)"

      if [[ -z "$COOKIE" || -z "$HOST" ]]; then
        echo "workvpn: SSO produced no session cookie - not connecting." >&2
        exit 1
      fi

      # The SSO step is done, so drop the throwaway config now: `exec` below
      # replaces this shell and the EXIT trap would never run.
      rm -rf "$saml_cfg"
      trap - EXIT

      # STEP 2 — the tunnel. `exec ... < <(printf ...)` rather than a pipeline
      # is LOAD-BEARING: in a pipeline openconnect is a child, so `work` kills
      # only the wrapper and the orphaned tunnel keeps holding ports
      # ${toString lport}/${toString socksPort} — the next run fails to bind and any RDP client
      # connects into the STALE tunnel. Process substitution keeps openconnect
      # execable (and never writes the cookie to a temp file), so it becomes the
      # pid `work` supervises.
      #
      # Extra args land BEFORE the host so the auth step stays swappable, e.g.
      #   workvpn --csd-wrapper=${pkgs.openconnect}/libexec/openconnect/csd-wrapper.sh
      exec openconnect \
        --protocol=anyconnect \
        --cookie-on-stdin \
        --servercert "$FINGERPRINT" \
        --script-tun \
        --script "${ocproxy} -L ${toString lport}:$rdp_host:3389 -D ${toString socksPort}" \
        "$@" \
        "$HOST" \
        < <(printf '%s' "$COOKIE")
    '';
  };

  workrdp = pkgs.writeShellApplication {
    name = "workrdp";
    runtimeInputs = [
      pkgs.freerdp
      pkgs.coreutils # stty, for the terminal-state restore below
    ];
    text = ''
      ${loadSecrets [
        "rdp_user"
        "rdp_domain"
      ]}

      # A UPN and a domain are ALTERNATIVES, not companions — /u:user@corp
      # together with /d:CORP is the one combination the server rejects.
      args=(
        /v:127.0.0.1:${toString lport}
        /u:"$rdp_user"
      )
      if [[ "$rdp_user" != *@* && -n "$rdp_domain" ]]; then
        args+=( /d:"$rdp_domain" )
      fi

      # ---- HiDPI ----
      # DPI scaling, not bitmap scaling: these ride in the Client Info PDU and
      # make Windows render larger, so text stays sharp. /smart-sizing upscales
      # a finished image and looks soft — it is the fallback, not the fix.
      #   WORK_RDP_SCALE=180 work      # bigger
      #   WORK_RDP_SCALE=100 work      # native, no scaling
      scale="''${WORK_RDP_SCALE:-140}"
      if [[ ! "$scale" =~ ^[0-9]+$ ]] || ((scale < 100 || scale > 500)); then
        echo "workrdp: WORK_RDP_SCALE must be an integer 100-500 (got '$scale')" >&2
        exit 1
      fi
      # DesktopScaleFactor is any 100-500, but DeviceScaleFactor accepts ONLY
      # 100/140/180 and Windows ignores the pair outright otherwise.
      if ((scale < 120)); then
        device=100
      elif ((scale < 160)); then
        device=140
      else
        device=180
      fi
      args+=( "/scale-desktop:$scale" "/scale-device:$device" )

      # ---- Windows key ----
      # niri matches Mod+<key> before the focused window sees it, and no FreeRDP
      # client implements keyboard-shortcuts-inhibit (checked xfreerdp,
      # sdl-freerdp, wlfreerdp; xwayland-satellite does not proxy it either), so
      # there is nothing to toggle. Instead send Super from a key niri has no
      # bind for and remap it in FreeRDP. WORK_RDP_WINKEY: menu | ralt | none
      #
      # Scancodes in DECIMAL: xfreerdp rejects a remap token longer than 10
      # chars ("maximum is 999=999"), so the hex 0x015d=0x015b never parses and
      # the client never starts. 349=0x015d, 347=0x015b, 312=0x0138
      # (`xfreerdp /list:kbd-scancode`).
      winkey="''${WORK_RDP_WINKEY:-menu}"
      case "$winkey" in
        menu) args+=( /kbd:remap:349=347 ) ;; # Menu (0x015d)      -> LeftWin (0x015b)
        ralt) args+=( /kbd:remap:312=347 ) ;; # Right Alt (0x0138) -> LeftWin (0x015b)
        none) ;;
        *)
          echo "workrdp: WORK_RDP_WINKEY must be menu, ralt or none (got '$winkey')" >&2
          exit 1
          ;;
      esac

      # ---- desktop size ----
      # Mutually exclusive: dynamic resizing would immediately overwrite a
      # WORK_RDP_SIZE, so this picks one or the other, never both.
      if [[ -n "''${WORK_RDP_SIZE:-}" ]]; then
        args+=( "/size:$WORK_RDP_SIZE" )
      else
        args+=( /dynamic-resolution )
      fi

      # /cert:tofu ALONE: the workstation cert is SELF-SIGNED and its CN does
      # not match the DNS name either, so /cert:name asserts nothing and only
      # produces NAME MISMATCH noise. tofu pins the real fingerprint instead.
      # -multitransport — ocproxy is TCP-only; the UDP transport stalls.
      # !kerberos — no KDC reachable through the tunnel, so FreeRDP's default
      # Kerberos-first attempt burns seconds before falling back to NTLM.
      args+=(
        /auth-pkg-list:!kerberos
        /cert:tofu
        /clipboard
        +fonts
        /sound:sys:pulse
        /microphone:sys:pulse
        /network:auto
        -multitransport
      )

      # FreeRDP leaves the terminal non-canonical after its NLA prompt (output
      # stair-steps down the screen afterwards, and it persists into later
      # commands). This is also why xfreerdp is NOT exec'd — exec would replace
      # this shell and the EXIT trap would never run.
      if [[ -t 0 ]]; then
        tty_state="$(stty -g 2>/dev/null || true)"
        if [[ -n "$tty_state" ]]; then
          trap 'stty "$tty_state" 2>/dev/null || true' EXIT
        fi
      fi

      xfreerdp "''${args[@]}" "$@"
    '';
  };

  work = pkgs.writeShellApplication {
    name = "work";
    runtimeInputs = [
      workvpn
      workrdp
      pkgs.coreutils # sleep — don't rely on the inherited PATH having it
    ];
    text = ''
      # PRE-FLIGHT. A surviving tunnel still serves port ${toString lport}, so the RDP
      # client would connect to a stale session and everything looks
      # almost-fine; ocproxy's bind failure is buried in its output.
      for port in ${toString lport} ${toString socksPort}; do
        if (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
          echo "work: 127.0.0.1:$port is already in use - a previous tunnel is still running." >&2
          echo "  Inspect:  ss -ltnp | grep -E '${toString lport}|${toString socksPort}'" >&2
          echo "  Clear it: pkill -f 'ocproxy -L ${toString lport}:'" >&2
          exit 1
        fi
      done

      # BOTH halves prompt on the terminal (workvpn: SSO password; workrdp:
      # the Windows password, because NLA happens client-side), so workvpn is
      # BACKGROUNDED and workrdp holds the TTY. Detaching workrdp instead makes
      # FreeRDP's prompt hit `tcgetattr() failed` and cancel the connection.
      # Safe only because job control is off in a script: `&` leaves workvpn in
      # our process group, so it can still read the terminal. They never
      # contend — SSO finishes before the port opens.
      #
      # `< /dev/tty` is LOAD-BEARING: with job control off, bash redirects a
      # background command's stdin to /dev/null (POSIX), silently taking away
      # the terminal the SSO prompt needs — and only on a run where the keyring
      # has not cached the password, i.e. not the run you test with. Probe by
      # OPENING it; `[[ -r /dev/tty ]]` succeeds even with no controlling tty.
      if (exec 3< /dev/tty) 2>/dev/null; then
        workvpn "$@" < /dev/tty &
      else
        # No controlling terminal (cron, a systemd unit, a pipe). Nothing to
        # reattach; the SSO step will have to be non-interactive.
        workvpn "$@" &
      fi
      vpn_pid=$!

      # 300s: an interactive SAML login with phone-based MFA outlasts 180.
      connected=0
      for ((i = 0; i < 300; i++)); do
        if (exec 3<>/dev/tcp/127.0.0.1/${toString lport}) 2>/dev/null; then
          connected=1
          break
        fi
        # Don't keep waiting on a tunnel that has already given up.
        if ! kill -0 "$vpn_pid" 2>/dev/null; then
          echo "work: workvpn exited before the tunnel came up." >&2
          wait "$vpn_pid" || true
          exit 1
        fi
        sleep 1
      done

      if [[ "$connected" -ne 1 ]]; then
        echo "work: 127.0.0.1:${toString lport} never opened - giving up." >&2
        kill "$vpn_pid" 2>/dev/null || true
        exit 1
      fi

      # Foreground, with the TTY, so the NLA password prompt works.
      workrdp || true

      # Never leave a corporate VPN up after the session it existed for.
      echo "work: RDP session ended - closing the tunnel."
      kill "$vpn_pid" 2>/dev/null || true
      wait "$vpn_pid" 2>/dev/null || true
    '';
  };
in
{
  home.packages = [
    workvpn
    workrdp
    work
  ];
}
