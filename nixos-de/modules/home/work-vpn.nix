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
# WHY ocproxy and not a netns or a container. openconnect normally creates a
# tun device and rewrites the routing table — that is exactly the system-wide
# behaviour we do not want. --script-tun instead hands the tunnel's IP traffic
# to a helper over a UNIX socket, and ocproxy terminates it with lwIP in
# userspace. The kernel therefore never learns the VPN exists: no interface,
# no route, no resolv.conf edit, and not one sudo. The only way in is to
# deliberately connect to the forwarded port (or the SOCKS port); every other
# process on this machine is unaffected, and killing openconnect leaves zero
# residue. A network namespace would confine the VPN too, but needs root, a
# unit, per-netns DNS, and a real tun device — strictly more machinery for
# strictly less isolation.
#
# COST OF THE CHOICE, in the order it will bite:
#   1. lwIP speaks TCP only. RDP over TCP is fine, but the session must not
#      negotiate the RDP UDP transport — hence -multitransport in workrdp.
#   2. lwIP is single-threaded userspace. Comfortable at 1080p; 4K or
#      multi-monitor may hit a throughput ceiling. That is the signal to
#      switch to a network namespace, not to tune this.
#   3. ocproxy is a low-activity project (1.60). It is in nixpkgs and cached,
#      and openconnect 9.x still documents --script-tun, but the netns
#      approach is the escape hatch if it ever rots.
#
# WHY the hardcoded /run/secrets path: home-manager is standalone here (`hms`
# cannot see the NixOS config, so config.sops is unreachable), but sops-nix's
# defaultSymlinkPath makes /run/secrets deterministic — modules/nixos/
# work-vpn.nix always lands these secrets exactly here. Same reasoning as
# modules/home/ssh-identities.nix.
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

      # STEP 1 — SAML/SSO, in a Qt WebEngine window.
      #
      # This gateway answers the auth request with an <sso-v2-login> URL and a
      # form wanting a single sso-token, but WITHOUT an <sso-v2-browser-mode>
      # element. openconnect's SSO dispatch needs either that element set to
      # "external" or a registered webview callback, and its CLI never
      # registers one — so plain `openconnect` dies with "No SSO handler" here
      # no matter which flags it gets. openconnect-saml renders the IdP login,
      # collects the acSamlv2Token cookie, completes the exchange, and with
      # --auth-only prints HOST/COOKIE/FINGERPRINT and exits WITHOUT touching
      # openconnect, sudo, or the routing table.
      #
      # NO --user, ON PURPOSE. Passing it builds a Credentials object, and
      # openconnect-saml injects an auto-fill userscript into the IdP page
      # whenever credentials exist ("Initiating autologin"). Against Entra's
      # multi-step form that script keeps re-filling fields underneath you and
      # WIPES the MFA code as you type it. With no credentials the browser is
      # left alone and you drive the login yourself.
      #
      # The throwaway config is what makes that stick. Credentials are also
      # read from the persisted config (`if cfg.credentials: ... elif
      # args.user:`), and earlier runs SAVED them there — so dropping --user
      # alone would not have helped. A fresh config per run guarantees no
      # credentials, hence no autologin, and nothing is read from the keyring
      # either. Everything the tool needs is passed explicitly below, so there
      # is nothing worth persisting.
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

      # STEP 2 — the tunnel, unchanged. --cookie-on-stdin consumes the SSO
      # result, so this is still an unprivileged --script-tun process with no
      # tun device and no route changes.
      #
      # `exec ... < <(printf ...)` rather than `printf ... | openconnect`, and
      # the difference is load-bearing. In a pipeline openconnect is a CHILD
      # of this shell, so when `work` kills the pid it is supervising it kills
      # only the wrapper — openconnect and its ocproxy survive, get reparented
      # to init, and keep holding ports ${toString lport} and ${toString socksPort}. The next run then
      # fails with "can't set up listener on port ${toString socksPort}/tcp" and, worse,
      # any RDP client connects straight into the STALE tunnel. Process
      # substitution feeds the cookie over a pipe (never a temp file, unlike a
      # here-string) while leaving openconnect execable, so it REPLACES this
      # shell and becomes the pid `work` supervises — killable directly.
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

      # A UPN and a domain are ALTERNATIVE ways to name the same principal,
      # not companions: sending /u:user@corp.example.com together with
      # /d:CORP is the one combination the server rejects. So /d: is emitted
      # only for a bare sAMAccountName with a domain actually set — a UPN in
      # rdp_user, or an empty rdp_domain, means no /d: at all.
      args=(
        /v:127.0.0.1:${toString lport}
        /u:"$rdp_user"
      )
      if [[ "$rdp_user" != *@* && -n "$rdp_domain" ]]; then
        args+=( /d:"$rdp_domain" )
      fi

      # ---- HiDPI ----------------------------------------------------------
      # On a high-res monitor the remote desktop comes back the full pixel
      # size of the window with Windows still at 100% DPI, so everything is
      # microscopic. The fix is DPI SCALING, not bitmap scaling: these
      # settings ride in the Client Info PDU and make Windows itself render
      # larger, so text stays sharp. /smart-sizing would instead upscale a
      # finished image and look soft — it is the fallback, not the fix.
      #
      # Tunable per run without a rebuild, because the right number depends
      # on the monitor you are sitting at:
      #   WORK_RDP_SCALE=180 work      # bigger
      #   WORK_RDP_SCALE=100 work      # native, no scaling
      scale="''${WORK_RDP_SCALE:-140}"
      if [[ ! "$scale" =~ ^[0-9]+$ ]] || ((scale < 100 || scale > 500)); then
        echo "workrdp: WORK_RDP_SCALE must be an integer 100-500 (got '$scale')" >&2
        exit 1
      fi
      # Two factors, two different legal ranges — a spec detail, not a
      # preference: DesktopScaleFactor is any 100-500, but DeviceScaleFactor
      # accepts ONLY 100, 140 or 180, and Windows ignores the pair outright if
      # the device value is anything else. So snap it to the nearest legal
      # step rather than passing $scale through to both.
      if ((scale < 120)); then
        device=100
      elif ((scale < 160)); then
        device=140
      else
        device=180
      fi
      args+=( "/scale-desktop:$scale" "/scale-device:$device" )

      # ---- desktop size ---------------------------------------------------
      # Default: /dynamic-resolution, so the remote desktop follows the window
      # as you resize it. Set WORK_RDP_SIZE to pin a fixed resolution instead
      # (e.g. 2560x1440, or 80% of the local screen). The two are mutually
      # exclusive — dynamic resizing would immediately overwrite the size you
      # asked for — so this picks one or the other, never both.
      if [[ -n "''${WORK_RDP_SIZE:-}" ]]; then
        args+=( "/size:$WORK_RDP_SIZE" )
      else
        args+=( /dynamic-resolution )
      fi

      # /cert:tofu ALONE, deliberately. An earlier version also asserted
      # /cert:name:$rdp_host, which was wrong twice over: the workstation's
      # certificate is SELF-SIGNED, so validating its CN proves nothing (there
      # is no chain to anchor it to), and the CN does not even match the DNS
      # name — the host answers to EPIC104101.dhcp.epic.com while the cert
      # says EPIC104101.epic.com. Asserting the name only produced a wall of
      # NAME MISMATCH warnings before tofu accepted the certificate anyway.
      # tofu is the control that actually fits a self-signed cert: pin the
      # real fingerprint on first connect, complain if it ever changes.
      #
      # -multitransport — ocproxy carries TCP only. Left enabled, the session
      # negotiates the RDP UDP transport and then stalls on it.
      # /auth-pkg-list:!kerberos — the workstation is reachable only through
      # the tunnel and there is no KDC for the EPIC realm on this side of it,
      # so FreeRDP's default Kerberos-first attempt always fails ("Cannot find
      # KDC for realm") and costs several seconds before it falls back to
      # NTLM. Excluding it goes straight to what actually works.
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

      # FreeRDP puts the terminal into non-canonical mode for its NLA password
      # prompt and does not reliably restore it — the symptom is output that
      # stair-steps down the screen afterwards, because ONLCR is gone, and it
      # persists into later commands. Snapshot the terminal and put it back on
      # the way out. This is also why xfreerdp is NOT exec'd: exec would
      # replace this shell and the EXIT trap would never run.
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
      # PRE-FLIGHT. If a previous tunnel is still up, openconnect's ocproxy
      # cannot bind and reports "can't set up listener on port ${toString socksPort}/tcp" —
      # buried a hundred lines into the output. Worse, port ${toString lport} is still
      # served by the OLD tunnel, so the RDP client connects to a stale
      # session and everything looks almost-fine. Refuse up front instead.
      for port in ${toString lport} ${toString socksPort}; do
        if (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
          echo "work: 127.0.0.1:$port is already in use - a previous tunnel is still running." >&2
          echo "  Inspect:  ss -ltnp | grep -E '${toString lport}|${toString socksPort}'" >&2
          echo "  Clear it: pkill -f 'ocproxy -L ${toString lport}:'" >&2
          exit 1
        fi
      done

      # WHICH PROCESS OWNS THE TERMINAL is the whole design of this script,
      # because BOTH halves need to prompt on it:
      #   - workvpn asks for the SSO password (and, first run, a TOTP secret)
      #   - workrdp asks for the Windows password, because NLA happens in the
      #     client before the session starts
      #
      # An earlier version ran workvpn in the foreground and launched workrdp
      # with `setsid -f`. That detached the RDP client from the controlling
      # terminal, so FreeRDP's prompt hit `tcgetattr() failed with
      # Inappropriate ioctl for device`, cancelled itself, and the connection
      # died with ERRCONNECT_CONNECT_CANCELLED / "NLA begin failed" — after a
      # perfectly good tunnel had come up.
      #
      # So it is inverted: workvpn goes to the BACKGROUND and workrdp runs in
      # the foreground holding the TTY. This is safe only because job control
      # is off in a non-interactive script, which means `&` does NOT put
      # workvpn in a new process group — it shares ours, so it can still read
      # from the terminal for the SSO prompts rather than being stopped with
      # SIGTTIN. The two never contend: SSO finishes before the port opens,
      # and the port opening is what releases workrdp.
      # `< /dev/tty` is LOAD-BEARING, not decoration. With job control off,
      # bash redirects a background command's stdin to /dev/null before any
      # explicit redirection (POSIX). Backgrounding workvpn therefore silently
      # takes away the terminal its SSO password prompt needs — which only
      # shows up on a run where the keyring has not already cached the
      # password, i.e. not the run you test with. Reattach it explicitly.
      #
      # Probe by actually OPENING it: `[[ -r /dev/tty ]]` only asks about
      # permissions and still succeeds in a process with no controlling
      # terminal, where the redirect then fails and the job never starts.
      if (exec 3< /dev/tty) 2>/dev/null; then
        workvpn "$@" < /dev/tty &
      else
        # No controlling terminal (cron, a systemd unit, a pipe). Nothing to
        # reattach; the SSO step will have to be non-interactive.
        workvpn "$@" &
      fi
      vpn_pid=$!

      # 300s, not 180: the first step is an interactive SAML login in a
      # browser window, which can easily outlast a three-minute budget when
      # MFA involves reaching for a phone.
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

      # Closing the RDP window takes the tunnel down with it — leaving a
      # corporate VPN established after the session it existed for has ended
      # is exactly the kind of thing this design is meant to avoid.
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
