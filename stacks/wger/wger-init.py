# Headless first-run for Wger. Fed to `manage.py shell` on stdin, so the ORM
# and settings are already loaded.
#
# It exists because `wger bootstrap` loaddata's a users.json carrying username
# `admin`, is_staff true, is_superuser FALSE and the published `adminadmin`
# hash, with no env var to change any of it and no API path either (password
# changes need an authenticated allauth session).
#
# It also wires Authentik login: allauth's openid_connect provider app is
# loaded by WGER_SOCIAL_PROVIDERS (compose), but its client config has no env
# var, so the SocialApp row is written here. Social SIGNUP is closed
# (ALLOW_REGISTRATION=False closes allauth's social signup too), so login works
# only for an account that already exists with the Authentik email, and the
# roster below seeds those accounts. `admin` stays the password break-glass.
#
# Every mutation prints "wger-init: CHANGE: ...". A second run must print
# ZERO change lines.

import os
import sys

from allauth.account.models import EmailAddress
from allauth.socialaccount.models import SocialApp
from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.hashers import check_password
from django.contrib.sites.models import Site

# The provider_id is the callback path segment
# (/account/oidc/authentik/login/callback/).
SSO_PROVIDER_ID = "authentik"
SSO_CLIENT_ID = "wger"
# The Authentik application slug is wger-sso: "wger" is forward auth's.
SSO_SERVER_URL = (
    "https://auth.idanreed.com/application/o/wger-sso/.well-known/openid-configuration"
)

# (username, email, superuser) — the Authentik accounts (headscale-oidc.yaml);
# the email is what allauth matches on. superuser applies at creation only.
USERS = [
    ("idan",    "idan@idanreed.com",               True),
    ("alondra", "apcalondraperezcortez@gmail.com", False),
    ("cale",    "calethim@gmail.com",              False),
    ("zach",    "zach@hayzak.com",                 False),
    ("rylan",   "rylankasitz@gmail.com",           False),
    ("cameron", "camos3434@gmail.com",             False),
    ("justin",  "justindanita@gmail.com",          False),
]


def log(msg):
    print(f"wger-init: {msg}", flush=True)


def fatal(msg):
    print(f"wger-init: FATAL: {msg}", flush=True)
    sys.exit(1)


password = os.environ.get("WGER_ADMIN_PASSWORD", "").strip()
if not password:
    # Fail loudly rather than leaving `adminadmin` live. An unset value here
    # means the .env did not decrypt.
    fatal("WGER_ADMIN_PASSWORD is unset or empty")
if len(password) < 12:
    fatal("WGER_ADMIN_PASSWORD must be at least 12 characters")
if password == "adminadmin":
    fatal("WGER_ADMIN_PASSWORD is the published default")
sso_secret = os.environ.get("WGER_OIDC_CLIENT_SECRET", "").strip()
if not sso_secret:
    fatal("WGER_OIDC_CLIENT_SECRET is unset or empty")

User = get_user_model()
admin = User.objects.filter(username="admin").first()

if admin is None:
    # bootstrap did not run, which means the schema already existed when this
    # container first started. Create the account rather than assuming.
    admin = User.objects.create_superuser(
        username="admin", email="", password=password
    )
    log("CHANGE: created superuser admin")
else:
    changed = []

    # ⚠ Compare BEFORE setting: set_password() re-salts, so an unconditional
    # write would print a CHANGE line on every redeploy.
    if not check_password(password, admin.password):
        admin.set_password(password)
        changed.append("password")

    # The fixture leaves the account is_staff but NOT is_superuser, so it can
    # reach /django-admin/ and do almost nothing there.
    if not admin.is_superuser:
        admin.is_superuser = True
        changed.append("is_superuser")
    if not admin.is_staff:
        admin.is_staff = True
        changed.append("is_staff")

    if changed:
        admin.save()
        log(f"CHANGE: admin updated: {', '.join(changed)}")
    else:
        log("admin already provisioned")

# Post-condition: the published default must not authenticate. If a future
# upstream re-runs create_or_reset_admin on a non-fresh database, it surfaces
# here.
admin.refresh_from_db()
if check_password("adminadmin", admin.password):
    fatal("admin still accepts the published default password 'adminadmin'")

# Authentik provider app
# Discovery is lazy (fetched at login), so nothing here or at boot needs
# Authentik up. email_authentication lets a login whose Authentik email is
# verified (email-verified.yaml makes it so) sign in to the local account with
# that email; with signup closed it is the only way in.
desired_settings = {
    "server_url": SSO_SERVER_URL,
    "email_authentication": True,
    "oauth_pkce_enabled": True,
}
apps = list(
    SocialApp.objects.filter(provider="openid_connect", provider_id=SSO_PROVIDER_ID)
)
if len(apps) > 1:
    fatal(f"{len(apps)} SocialApps carry provider_id {SSO_PROVIDER_ID!r}; "
          f"delete the extras in /django-admin/")
if apps:
    app = apps[0]
    changed = []
    for field, value in (
        ("name", "Authentik"),
        ("client_id", SSO_CLIENT_ID),
        ("secret", sso_secret),
        ("settings", desired_settings),
    ):
        if getattr(app, field) != value:
            setattr(app, field, value)
            changed.append(field)
    if changed:
        app.save()
        # Field names only — one of them is the client secret.
        log(f"CHANGE: Authentik SocialApp updated: {', '.join(changed)}")
    else:
        log("Authentik SocialApp already configured")
else:
    app = SocialApp.objects.create(
        provider="openid_connect",
        provider_id=SSO_PROVIDER_ID,
        name="Authentik",
        client_id=SSO_CLIENT_ID,
        secret=sso_secret,
        settings=desired_settings,
    )
    log("CHANGE: created the Authentik SocialApp")

# With django.contrib.sites installed, allauth lists only apps linked to the
# current site; an unlinked app is configured and invisible on the login page.
try:
    site = Site.objects.get(pk=settings.SITE_ID)
except Site.DoesNotExist:
    fatal(f"no Site with SITE_ID={settings.SITE_ID}; the login page would "
          f"show no Authentik button")
if app.sites.filter(pk=site.pk).exists():
    log(f"Authentik SocialApp already on site {site.pk}")
else:
    app.sites.add(site)
    log(f"CHANGE: linked the Authentik SocialApp to site {site.pk}")

# Roster accounts
# SSO-only: an unusable password, so no second credential exists. An account
# that already carries the email is adopted as-is, password included. The
# address is recorded VERIFIED: allauth wipes the password of an account
# matched through an unverified address, and these are the operator's own.
for username, email, superuser in USERS:
    user = User.objects.filter(email__iexact=email).first()
    if user is None:
        if User.objects.filter(username__iexact=username).exists():
            log(f"WARN: username {username!r} belongs to an account without "
                f"{email}; not seeding it. Give that account this email for "
                f"Authentik to sign in to it.")
            continue
        user = User(
            username=username,
            email=email,
            is_staff=superuser,
            is_superuser=superuser,
        )
        user.set_unusable_password()
        user.save()
        log(f"CHANGE: created {'superuser' if superuser else 'user'} "
            f"{username} ({email}), Authentik login only")

    address = EmailAddress.objects.filter(user=user, email__iexact=email).first()
    if address is None:
        EmailAddress.objects.create(
            user=user,
            email=email,
            verified=True,
            primary=not EmailAddress.objects.filter(user=user, primary=True).exists(),
        )
        log(f"CHANGE: recorded {email} as verified for {user.username}")
    elif not address.verified:
        address.verified = True
        address.save(update_fields=["verified"])
        log(f"CHANGE: marked {email} verified for {user.username}")
    else:
        log(f"{user.username} ({email}) already provisioned")

log("done")
