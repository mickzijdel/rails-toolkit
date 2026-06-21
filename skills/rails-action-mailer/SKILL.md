---
name: rails-action-mailer
description: Use when writing Action Mailer mailers, email templates, previews, or delivery configuration. Covers shallow mailer design, deliver_later patterns, multi-part templates, previews, testing, and URL generation.
---

# Rails Action Mailer

## Pattern 1: Shallow Mailers

The mailer is a conduit for delivery; the decision of *what* to send and *when* lives in a
model method.

```ruby
# app/mailers/account_mailer.rb
class AccountMailer < ApplicationMailer
  def invitation(membership)
    @membership = membership
    @account = membership.account
    mail to: membership.email, subject: "You've been invited to #{@account.name}"
  end
end
```

```ruby
# app/models/membership.rb
class Membership < ApplicationRecord
  after_create_commit :send_invitation

  def send_invitation
    AccountMailer.invitation(self).deliver_later
  end
end
```

Don't put business logic in the mailer — it belongs in the model. The mailer builds the
message; the model decides when and to whom.

---

## Pattern 2: `deliver_later` Everywhere, `deliver_now` Sparingly

Prefer `deliver_later` for all mail — it enqueues a job and returns immediately, keeping the
web process responsive. Reserve `deliver_now` for cases where the caller genuinely needs to
know delivery succeeded before continuing (e.g. a CLI task asserting delivery in a test run).

```ruby
# Good — async
ConfirmationMailer.welcome(user).deliver_later

# Only for synchronous tests or scripts
ConfirmationMailer.welcome(user).deliver_now
```

For `deliver_later` with a delay or specific time:

```ruby
PasswordMailer.reset(user).deliver_later(wait: 5.minutes)
DigestMailer.weekly(account).deliver_later(wait_until: next_monday_9am)
```

See [[rails-jobs]] for the account-context serialization pattern — it applies to mailer jobs
the same way it applies to regular jobs.

---

## Pattern 3: Multi-Part Templates (HTML + Text)

Always ship both text and HTML parts. Rails pairs them automatically when both templates exist.

```
app/views/account_mailer/invitation.html.erb
app/views/account_mailer/invitation.text.erb
```

```erb
<%# invitation.html.erb %>
<h1>You've been invited to <%= @account.name %></h1>
<p>
  <%= @membership.inviter_name %> has invited you.
  <%= link_to "Accept invitation", accept_membership_url(@membership.token) %>
</p>
```

```erb
<%# invitation.text.erb %>
You've been invited to <%= @account.name %>

<%= @membership.inviter_name %> has invited you.

Accept: <%= accept_membership_url(@membership.token) %>
```

Keep the text template readable as plain text — no `strip_tags`, no HTML entities, no `<%=
link_to %>` (use the URL directly).

---

## Pattern 4: ApplicationMailer Defaults

Set defaults once in `ApplicationMailer`:

```ruby
# app/mailers/application_mailer.rb
class ApplicationMailer < ActionMailer::Base
  default from: Rails.application.credentials.dig(:mailer, :from)
  layout "mailer"
end
```

Per-mailer overrides are fine for a specific sender address (e.g. `"Support <support@example.com>"`).

---

## Pattern 5: URL Generation

Mailers execute outside a request context, so URL helpers need `default_url_options` configured:

```ruby
# config/environments/production.rb
config.action_mailer.default_url_options = { host: "example.com", protocol: "https" }

# config/environments/development.rb
config.action_mailer.default_url_options = { host: "localhost", port: 3000 }
```

Always use `_url` helpers (not `_path`) in mailers — a path without a host is meaningless in
an email client.

---

## Pattern 6: Mailer Previews

Write a preview for every mailer. It lets you see the rendered email in the browser at
`/rails/mailers` without sending anything.

```ruby
# test/mailers/previews/account_mailer_preview.rb
class AccountMailerPreview < ActionMailer::Preview
  def invitation
    membership = Membership.first
    AccountMailer.invitation(membership)
  end
end
```

Use real fixtures or `Membership.first` — previews don't need factory magic. If your preview
needs a specific record, create one in a migration-backed seed or use a fixture.

---

## Pattern 7: Testing

Use `ActionMailer::TestCase` and assert on the enqueued job when testing `deliver_later`:

```ruby
# test/mailers/account_mailer_test.rb
class AccountMailerTest < ActionMailer::TestCase
  test "invitation email" do
    membership = memberships(:pending)
    email = AccountMailer.invitation(membership)

    assert_emails 1 do
      email.deliver_now
    end

    assert_equal [membership.email], email.to
    assert_match membership.account.name, email.subject
    assert_match accept_membership_url(membership.token), email.body.encoded
  end
end
```

For `deliver_later`, assert the job was enqueued:

```ruby
test "invitation is enqueued after create" do
  assert_enqueued_email_with AccountMailer, :invitation do
    Membership.create!(email: "x@example.com", account: accounts(:one))
  end
end
```

---

## Pattern 8: Attachments — Prefer Storage URLs

Attach files only when the recipient's client must have the file inline (e.g. a PDF they
need without clicking). For everything else, link to the file in Active Storage:

```ruby
# Preferred — link to storage
def export_ready(export)
  @download_url = rails_blob_url(export.file, expires_in: 7.days)
  mail to: export.account.owner.email, subject: "Your export is ready"
end

# Only when attachment is required (e.g. calendar invite, PDF receipt)
def receipt(order)
  attachments["receipt-#{order.id}.pdf"] = PdfGenerator.render(order)
  mail to: order.email, subject: "Receipt for order ##{order.id}"
end
```

Direct attachments increase email size, hit spam filters harder, and can't be revoked. Storage
URLs expire on your schedule.

---

## Pattern 9: Delivery Configuration

```ruby
# config/environments/production.rb
config.action_mailer.delivery_method = :smtp
config.action_mailer.smtp_settings = {
  address: "smtp.postmarkapp.com",
  port: 587,
  user_name: Rails.application.credentials.dig(:smtp, :user),
  password: Rails.application.credentials.dig(:smtp, :password),
  authentication: :plain,
  enable_starttls_auto: true
}

# config/environments/development.rb
config.action_mailer.delivery_method = :letter_opener  # gem 'letter_opener', group: :development
# or :test to capture in ActionMailer::Base.deliveries
```

Never hard-code SMTP credentials — always read from `Rails.application.credentials` or
environment variables.

---

## Quick Reference

| Pattern | When to Use |
|---------|-------------|
| Shallow Mailer | Always — logic in models, not mailers |
| `deliver_later` | Default for all delivery |
| Multi-part templates | Always — HTML + text |
| ApplicationMailer defaults | Set `from:` and layout once |
| URL helpers | Always `_url` not `_path` |
| Previews | Write one per mailer |
| Testing | `assert_emails` / `assert_enqueued_email_with` |
| Storage URLs | Prefer over direct attachments |
| Credentials for SMTP | Never hard-code |
