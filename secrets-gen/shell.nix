# Devshell for sops-gen: every generator dependency, hermetically.
# nixpkgs pinned from headscale-vps/flake.lock via tests/lib/sources.nix —
# same trick as tests/, and deliberately not a flake for the same reason
# (flakes only see git-tracked files).
#
#   nix-shell secrets-gen/shell.nix
{
  system ? builtins.currentSystem,
}:
let
  sources = import ../tests/lib/sources.nix { lockFile = ../headscale-vps/flake.lock; };
  pkgs = import sources.nixpkgs { inherit system; };
in
pkgs.mkShell {
  packages = with pkgs; [
    sops
    age
    openssl # rand, kdf (pbkdf2)
    yq-go # manifest parsing
    wireguard-tools # wg keypairs
    apacheHttpd # htpasswd (bcrypt)
    libargon2 # argon2id PHC
    openssh # ssh-keygen
    util-linux # uuidgen
    unixtools.xxd # hex->bin for pbkdf2
  ];
}
