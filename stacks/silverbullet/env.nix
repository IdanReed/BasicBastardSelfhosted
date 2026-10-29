# Values built at activation from other secrets, never stored twice — see
# nixos/modules/stack-env.nix. `secret` reads this stack's secrets.sops.json,
# `shared` reads secrets/shared.sops.json.
{ shared, ... }:
{
  # SilverBullet's own login, under forward auth: idan and his one password,
  # so the second lock asks for the same credential as Authentik.
  SB_USER = "idan:${shared "IDAN_INITIAL_PASSWORD"}";
}
