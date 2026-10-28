# frozen_string_literal: true
#
# Headless first-run for Dawarich. `rails runner` is the only route:
# db/seeds.rb creates demo@dawarich.app / safepassword as an ACTIVE ADMIN on
# every boot with an empty user table, there is no env var or rake task to
# change it, and /api/v1/auth/register only creates non-admins.
#
# It RENAMES rather than deletes because User#destroy is soft while
# index_users_on_email is a plain UNIQUE index — a "deleted" demo row would hold
# demo@dawarich.app forever.
#
# Every mutation logs "dawarich-init: CHANGE: ...". A second run — every
# redeploy reruns this container — must log ZERO change lines.

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

# Fail loudly: an unset variable means the .env did not decrypt, and doing
# nothing would leave a published-password admin on a location database.
fatal('DAWARICH_ADMIN_EMAIL is unset or empty') if target.empty?
fatal('DAWARICH_ADMIN_PASSWORD is unset or empty') if password.empty?
fatal("DAWARICH_ADMIN_EMAIL must not be #{DEMO_EMAIL}") if target == DEMO_EMAIL
# Stricter than Devise's 6-character minimum on purpose.
fatal('DAWARICH_ADMIN_PASSWORD must be at least 12 characters') if password.length < 12

admin = User.find_by(email: target)
demo  = User.find_by(email: DEMO_EMAIL)

if admin.nil? && demo
  # `admin: true` explicitly: the column defaults to false, and a later change
  # to seeds.rb must not silently demote this account.
  demo.update!(email: target, password: password,
               password_confirmation: password, admin: true)
  log("CHANGE: renamed the seeded #{DEMO_EMAIL} account to #{target} " \
      'and reset its password')
elsif admin.nil?
  # seeds.rb was skipped because another user existed, or the database
  # predates this script.
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

# If a real admin AND the demo account both existed, the branch above renamed
# nothing. Users::Destroy actually removes the row, unlike User#destroy.
leftover = User.find_by(email: DEMO_EMAIL)
if leftover
  Users::Destroy.new(leftover).call
  log("CHANGE: hard-deleted the leftover #{DEMO_EMAIL} account")
end

# The post-condition, asserted here as well as in the suite: an upstream change
# to the seed guard or the soft-delete scope would otherwise fail silently.
fatal("#{DEMO_EMAIL} still resolves after cleanup") if User.find_by(email: DEMO_EMAIL)
fatal("admin #{target} does not exist after provisioning") unless User.find_by(email: target)

log('done')
