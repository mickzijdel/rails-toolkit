---
name: rails-mailers
description: Use when writing, configuring, or testing ActionMailer mailers — layouts, previews, deliver_later vs deliver_now, i18n subjects, attachments, bounce handling, and local dev delivery. Triggers on "mailer", "send an email", "ActionMailer", "email template", "deliver_later", "mailer preview", "bounce".
---

# Rails Mailers

## Pattern 1: Shallow Mailers, `deliver_later` from a Commit Hook

Mailers stay thin — they just render and pass data. The decision to send lives on the model, triggered `after_create_commit`/`after_update_commit` so the email never fires for a record that then rolls back:

```ruby
# app/models/invitation.rb
class Invitation < ApplicationRecord
  after_create_commit :deliver_later

  def deliver_later
    InvitationMailer.invite(self).deliver_later
  end
end
```

```ruby
# app/mailers/invitation_mailer.rb
class InvitationMailer < ApplicationMailer
  def invite(invitation)
    @invitation = invitation
    mail to: invitation.email_address, subject: t(".subject", account: invitation.account.name)
  end
end
```

`deliver_later` is the default everywhere — it enqueues an `ActionMailer::MailDeliveryJob` (or your custom `delivery_job`, see Pattern 6) instead of opening an SMTP connection on the request thread. Reach for `deliver_now` only in a Rake task, console, or a job that's already async.

---

## Pattern 2: Multipart Templates + Layout

Ship both an HTML and a text version — some clients/spam filters still expect it, and the text part is the natural degrade for widgets that don't render HTML:

```
app/views/layouts/mailer.html.erb
app/views/layouts/mailer.text.erb
app/views/invitation_mailer/invite.html.erb
app/views/invitation_mailer/invite.text.erb
```

`mail to:` renders both templates automatically when both files exist; no `format.html { ... }` block needed. Keep the text template a genuine plain-text version, not a stripped HTML dump — it's what shows in notification previews and low-bandwidth clients.

For HTML styling, inline CSS with `premailer-rails` (gem) rather than hand-inlining `style=` attributes — most mail clients strip `<style>` blocks:

```ruby
# Gemfile
gem "premailer-rails"
```

It hooks into the mailer pipeline automatically once required; no per-mailer opt-in.

---

## Pattern 3: i18n Subjects, Never English Literals

Subjects (and any user-facing copy) go through the locale files, keyed by mailer/action — `t(".subject")` inside a mailer action resolves to `<mailer_name>.<action_name>.subject`:

```yaml
# config/locales/en.yml
en:
  invitation_mailer:
    invite:
      subject: "You're invited to join %{account}"
  password_reset_mailer:
    reset:
      subject: "Reset your password"
```

```ruby
def invite(invitation)
  @invitation = invitation
  mail to: invitation.email_address, subject: t(".subject", account: invitation.account.name)
end
```

This is the same lookup mechanism `t("action_mailer.invitation_mailer.invite.subject")` would use — the leading-dot shorthand just infers the mailer/action scope, matching the leading-dot convention for views.

---

## Pattern 4: Previews Instead of Sending Real Email to Iterate

`ActionMailer::Base::Preview` subclasses under `test/mailers/previews/` render at `/rails/mailers` in development — no SMTP round-trip, no waiting on a real inbox:

```ruby
# test/mailers/previews/invitation_mailer_preview.rb
class InvitationMailerPreview < ActionMailer::Preview
  def invite
    InvitationMailer.invite(Invitation.first || Invitation.new(
      email_address: "preview@example.com",
      account: Account.first
    ))
  end
end
```

Use real (or realistic fixture) data, not `Struct.new` stand-ins — the preview is also how you catch broken interpolations and missing associations before a real send. `config.action_mailer.preview_paths` defaults to `test/mailers/previews`; only touch it if previews live elsewhere.

---

## Pattern 5: Local Delivery Without a Real SMTP Server

`letter_opener` intercepts development mail and opens it as a browser tab instead of sending it — closer to a real render (fonts, images, layout) than the `/rails/mailers` preview list:

```ruby
# Gemfile
group :development do
  gem "letter_opener"
end
```

```ruby
# config/environments/development.rb
config.action_mailer.delivery_method = :letter_opener
config.action_mailer.perform_deliveries = true
config.action_mailer.default_url_options = { host: "localhost", port: 3000 }
```

`default_url_options` is required in every non-test environment — mailer views have no request to infer a host from, so any `url_for`/`_url` helper (as opposed to `_path`) raises without it. Set the real host per environment (`config/environments/production.rb`) from an env var, not a hardcoded string, so staging and production don't collide.

---

## Pattern 6: Delivery Errors Are Job Errors

Because `deliver_later` runs inside ActiveJob, transient SMTP failures (timeouts, temporary 4xx) are retried the same way as any other job — reuse the retry/rescue concern rather than writing mailer-specific error handling. See [[rails-jobs]] Pattern 7 for the full `SmtpDeliveryErrorHandling` concern; include it on a custom delivery job if you need it project-wide:

```ruby
# config/application.rb
config.action_mailer.delivery_job = "ApplicationMailDeliveryJob"
```

```ruby
# app/jobs/application_mail_delivery_job.rb
class ApplicationMailDeliveryJob < ActionMailer::MailDeliveryJob
  include SmtpDeliveryErrorHandling
end
```

---

## Pattern 7: Skip Sends to Suppressed Addresses

Providers (Postmark, SES, SendGrid) report bounces and complaints via webhook. Record the suppression on the recipient and check it before every send, so a bouncing address doesn't keep getting hammered (and doesn't tank sender reputation):

```ruby
# app/models/email_address/suppression.rb — set by the provider webhook controller
class Identity < ApplicationRecord
  def deliverable?
    !email_bounced_at? && !email_complained_at?
  end
end
```

```ruby
# app/models/invitation.rb
def deliver_later
  return unless account.owner.deliverable?
  InvitationMailer.invite(self).deliver_later
end
```

The webhook controller itself is thin — verify the provider's signature, then `update!(email_bounced_at: Time.current)` on a hard bounce or spam complaint. Treat soft bounces as transient (already covered by Pattern 6's retry) rather than suppressing on the first one.

---

## Pattern 8: Testing

`ActionMailer::TestHelper` (included by default in mailer/integration tests) asserts against the enqueued job or the delivered message without a real send — `test` delivery method collects into `ActionMailer::Base.deliveries` (Minitest/RSpec via `assert_emails`/`have_enqueued_mail`):

```ruby
# test/mailers/invitation_mailer_test.rb
class InvitationMailerTest < ActionMailer::TestCase
  test "invite" do
    invitation = invitations(:pending)

    email = InvitationMailer.invite(invitation)

    assert_emails 1 do
      email.deliver_now
    end
    assert_equal [invitation.email_address], email.to
    assert_match invitation.account.name, email.subject
    assert_match invitation.account.name, email.body.encoded
  end
end
```

To test that a model action *enqueues* the mailer without asserting on rendered content, use `assert_enqueued_email_with`:

```ruby
test "invitation delivers on create" do
  assert_enqueued_email_with InvitationMailer, :invite do
    Invitation.create! email_address: "new@example.com", account: accounts(:acme)
  end
end
```

Prefer `email.body.encoded` for multipart assertions over `email.html_part.body` — it degrades gracefully for text-only mailers.

---

## Pattern 9: Attachments — File vs. Active Storage Blob

Raw file attachments load the whole thing into the job's memory; for anything already in Active Storage, attach the blob's bytes directly instead of round-tripping through a tempfile:

```ruby
# Raw file
attachments["report.pdf"] = File.read(Rails.root.join("tmp/report.pdf"))

# Active Storage blob
attachments[export.file.filename.to_s] = export.file.download
```

Inline images (e.g. a logo in the HTML layout) go through `attachments.inline`, referenced with `image_tag`:

```ruby
attachments.inline["logo.png"] = File.read(Rails.root.join("app/assets/images/logo.png"))
```

```erb
<%= image_tag attachments.inline["logo.png"].url %>
```

---

## Quick Reference

| Pattern | When to Use |
|---------|-------------|
| Shallow Mailers | Always — trigger from `after_*_commit`, not inline in the controller |
| Multipart + Layout | Every mailer — text part is not optional |
| i18n Subjects | Always — `t(".subject")`, never a literal string |
| Previews | Iterating on a template without sending real mail |
| letter_opener | Local dev delivery — closer to real render than `/rails/mailers` |
| Delivery Job Errors | Reuse [[rails-jobs]] Pattern 7's retry/rescue concern |
| Suppression Check | Before every send, once bounce/complaint webhooks exist |
| `assert_emails` / `assert_enqueued_email_with` | Testing content vs. testing that a send was triggered |
| Blob Attachments | Attaching an existing Active Storage file — skip the tempfile round-trip |
