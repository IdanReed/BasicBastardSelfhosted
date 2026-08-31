# frozen_string_literal: true
#
# Headless first-run for Dawarich (annex §3).
#
# WHY THIS EXISTS AT ALL: db/seeds.rb creates demo@dawarich.app / safepassword
# — an ACTIVE ADMIN — guarded only by `User.none?`, and web-entrypoint.sh runs
# `rails db:seed` on every boot. There is no env var to change that email or
# password, no `users:create` rake task (lib/tasks/users.rake has exactly one
# task, `users:activate`), and POST /api/v1/auth/register creates a NON-admin
# user, so it cannot replace the seeded one. `rails runner` is the only route.
#
# WHY IT RENAMES RATHER THAN DELETES: User#destroy is soft (SoftDeletable
# overrides it and never calls super), while index_users_on_email is a plain
# UNIQUE index with no `deleted_at IS NULL` predicate — so a "deleted" demo row
# keeps holding demo@dawarich.app forever and no dependent: :destroy cascade
# ever fires. Renaming the seeded account in place sidesteps that entirely and
# leaves exactly one user behind.
#
# It runs from a throwaway container built on the SAME image, sharing the
# database over the compose network — no docker socket anywhere, which is the
# same reason decrypt-sops-envs lives on the host (CLAUDE.md).
#
# Every mutation logs "dawarich-init: CHANGE: ...". A second run — and every
# Arcane redeploy reruns this container — must log ZERO change lines.

DEMO_EMAIL = 'demo@dawarich.app'

def log(msg)
  $stdout.puts("dawarich-init: #{msg}")
  $stdout.flush
end

def fatal(msg)
  $stdout.puts("dawarich-init: FATAL: #{msg}")
  $stdout.flush
  exit 1
end

target   = ENV['DAWARICH_ADMIN_EMAIL'].to_s.strip.downcase
password = ENV['DAWARICH_ADMIN_PASSWORD'].to_s

# Fail loudly rather than leaving the seeded account live. An unset variable
# here means the .env did not decrypt, which is a condition worth a red
# container: silently doing nothing would leave a published-password admin on
# a location-history database.
fatal('DAWARICH_ADMIN_EMAIL is unset or empty') if target.empty?
fatal('DAWARICH_ADMIN_PASSWORD is unset or empty') if password.empty?
fatal("DAWARICH_ADMIN_EMAIL must not be #{DEMO_EMAIL}") if target == DEMO_EMAIL
# Devise :validatable enforces a 6-character minimum. This is stricter on
# purpose — the account owns every location this instance has ever recorded.
fatal('DAWARICH_ADMIN_PASSWORD must be at least 12 characters') if password.length < 12

admin = User.find_by(email: target)
demo  = User.find_by(email: DEMO_EMAIL)

if admin.nil? && demo
  # The normal first-boot path. `admin: true` is passed explicitly because the
  # column defaults to false; the seeded row already has it, but a later
  # upstream change to seeds.rb must not silently demote this account.
  demo.update!(email: target, password: password,
               password_confirmation: password, admin: true)
  log("CHANGE: renamed the seeded #{DEMO_EMAIL} account to #{target} " \
      'and reset its password')
elsif admin.nil?
  # No demo user and no admin: seeds.rb was skipped because some other user
  # already existed, or the database predates this script.
  User.create!(email: target, password: password,
               password_confirmation: password, admin: true)
  log("CHANGE: created admin #{target}")
else
  log("admin #{target} already exists")
  unless admin.admin?
    admin.update!(admin: true)
    log("CHANGE: promoted #{target} to admin")
  end
end

# Belt and braces: if a real admin already existed AND the demo account was
# also present (seeds.rb running against a database whose only users were
# soft-deleted, say), the branch above renamed nothing. Hard-delete it —
# Users::Destroy is the service that actually removes the row, unlike
# User#destroy.
leftover = User.find_by(email: DEMO_EMAIL)
if leftover
  Users::Destroy.new(leftover).call
  log("CHANGE: hard-deleted the leftover #{DEMO_EMAIL} account")
end

# The post-condition this whole script exists for. Asserted here as well as in
# the suite, because a future upstream change to either the seed guard or the
# soft-delete scope would otherwise fail silently.
fatal("#{DEMO_EMAIL} still resolves after cleanup") if User.find_by(email: DEMO_EMAIL)
fatal("admin #{target} does not exist after provisioning") unless User.find_by(email: target)

log('done')
