---
name: rails-jobs
description: Use when writing background jobs with Solid Queue, including recurring jobs and context serialization
---

# Rails Background Jobs

## When to Use
- Creating background jobs for async work
- Setting up recurring/scheduled jobs
- Handling multi-tenant context in jobs
- Building resumable long-running jobs

## Pattern 1: Shallow Job Classes

### Problem
Jobs should not contain business logic directly. Logic scattered across jobs becomes hard to test and maintain.

### Solution
Write thin job classes that delegate work to model methods. The job is just a conduit for async execution.

### Example

**Job class** - `app/jobs/webhook/delivery_job.rb`:
```ruby
class Webhook::DeliveryJob < ApplicationJob
  queue_as :webhooks

  def perform(delivery)
    delivery.deliver
  end
end
```

**Model with the logic** - `app/models/webhook/delivery.rb`:
```ruby
class Webhook::Delivery < ApplicationRecord
  after_create_commit :deliver_later

  def deliver_later
    Webhook::DeliveryJob.perform_later(self)
  end

  def deliver
    in_progress!
    self.request[:headers] = headers
    self.response = perform_request
    self.state = :completed
    save!
    webhook.delinquency_tracker.record_delivery_of(self)
  rescue
    errored!
    raise
  end
end
```

More examples:
- `app/jobs/notify_recipients_job.rb` calls `notifiable.notify_recipients`
- `app/jobs/push_notification_job.rb` calls `NotificationPusher.new(notification).push`
- `app/jobs/mention/create_job.rb` calls `record.create_mentions(mentioner:)`

---

## Pattern 2: Account Context Serialization

### Problem
In multi-tenant apps, jobs need access to the current account context that was active when they were enqueued.

### Solution
FizzyActiveJobExtensions (prepended to ActiveJob::Base) automatically captures `Current.account` when a job is created and restores it when the job runs.

### Example

**The extension** - `config/initializers/active_job.rb`:
```ruby
module FizzyActiveJobExtensions
  extend ActiveSupport::Concern

  prepended do
    attr_reader :account
    self.enqueue_after_transaction_commit = true
  end

  def initialize(...)
    super
    @account = Current.account
  end

  def serialize
    super.merge({ "account" => @account&.to_gid })
  end

  def deserialize(job_data)
    super
    if _account = job_data.fetch("account", nil)
      @account = GlobalID::Locator.locate(_account)
    end
  end

  def perform_now
    if account.present?
      Current.with_account(account) { super }
    else
      super
    end
  end
end

ActiveSupport.on_load(:active_job) do
  prepend FizzyActiveJobExtensions
end
```

This means any job automatically has tenant context - no manual passing required.

---

## Pattern 3: `*_later` / `*_now` Method Convention

### Problem
Models need both async (background) and sync versions of operations. Naming should clearly indicate which is which.

### Solution
Use `_later` suffix for methods that enqueue jobs. Use `_now` suffix when the same class has both async and sync versions of the same operation.

### Example

**From** `app/models/notification/bundle.rb`:
```ruby
class Notification::Bundle < ApplicationRecord
  class << self
    def deliver_all
      due.in_batches do |batch|
        jobs = batch.collect { DeliverJob.new(it) }
        ActiveJob.perform_all_later jobs
      end
    end

    def deliver_all_later
      DeliverAllJob.perform_later
    end
  end

  def deliver
    user.in_time_zone do
      Current.with_account(user.account) do
        processing!
        Notification::BundleMailer.notification(self).deliver if deliverable?
        delivered!
      end
    end
  end

  def deliver_later
    DeliverJob.perform_later(self)
  end
end
```

**From** `app/models/account/export.rb`:
```ruby
class Account::Export < ApplicationRecord
  def build_later
    ExportAccountDataJob.perform_later(self)
  end

  def build
    processing!
    zipfile = generate_zip
    file.attach io: File.open(zipfile.path), filename: "fizzy-export-#{id}.zip"
    mark_completed
    ExportMailer.completed(self).deliver_later
  rescue => e
    update!(status: :failed)
    raise
  end
end
```

The pattern from STYLE.md explicitly shows this with `relay_later` / `relay_now` naming for Event relaying.

---

## Pattern 4: Recurring Jobs

### Problem
Some tasks need to run on a schedule (cleanup, notifications, metrics).

### Solution
Configure recurring jobs in `config/recurring.yml`. Jobs can be defined as class names or Ruby commands.

### Example

**config/recurring.yml**:
```yaml
production: &production
  # Application functionality
  deliver_bundled_notifications:
    command: "Notification::Bundle.deliver_all_later"
    schedule: every 30 minutes

  # Cleanup tasks
  auto_postpone_all_due:
    command: "Card.auto_postpone_all_due"
    schedule: every hour at minute 50

  delete_unused_tags:
    class: DeleteUnusedTagsJob
    schedule: every day at 04:02

  cleanup_webhook_deliveries:
    command: "Webhook::Delivery.cleanup"
    schedule: every 4 hours at minute 51

  cleanup_magic_links:
    command: "MagicLink.cleanup"
    schedule: every 4 hours

  # Solid Queue maintenance
  clear_solid_queue_finished_jobs:
    command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
    schedule: every hour at minute 12
```

Use `command:` for simple class method calls, `class:` for job classes.

---

## Pattern 5: Queue Configuration

### Problem
Different job types have different priorities and resource needs.

### Solution
Assign jobs to named queues based on their characteristics. Configure workers to process specific queues.

### Example

**Queue assignments in jobs**:
```ruby
# Default queue (no declaration needed)
class NotifyRecipientsJob < ApplicationJob
  def perform(notifiable)
    notifiable.notify_recipients
  end
end

# Backend queue for heavier operations
class ExportAccountDataJob < ApplicationJob
  queue_as :backend
  # ...
end

# Webhooks queue for external HTTP calls
class Webhook::DeliveryJob < ApplicationJob
  queue_as :webhooks
  # ...
end
```

**Queue worker configuration** - `config/queue.yml`:
```yaml
default: &default
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: [ "default", "solid_queue_recurring", "backend", "webhooks" ]
      threads: 3
      processes: <%= Integer(ENV.fetch("JOB_CONCURRENCY") { Concurrent.physical_processor_count }) %>
      polling_interval: 0.1
```

---

## Pattern 6: Continuable Jobs

### Problem
Long-running jobs that iterate over large datasets can timeout or fail midway, losing all progress.

### Solution
Use `ActiveJob::Continuable` to create resumable jobs with cursor-based checkpointing.

### Example

**From** `app/jobs/event/webhook_dispatch_job.rb`:
```ruby
require "active_job/continuable"

class Event::WebhookDispatchJob < ApplicationJob
  include ActiveJob::Continuable

  queue_as :webhooks

  def perform(event)
    step :dispatch do |step|
      Webhook.active.triggered_by(event).find_each(start: step.cursor) do |webhook|
        webhook.trigger(event)
        step.advance! from: webhook.id
      end
    end
  end
end
```

Key points:
- `step :name` defines a resumable step
- `step.cursor` returns the last saved position (or nil on first run)
- `step.advance! from: id` saves progress after each iteration
- If the job is interrupted, it resumes from the last checkpoint

---

## Pattern 7: Error Handling Concerns

### Problem
Common error handling patterns (retries, discards) are repeated across jobs dealing with similar external services.

### Solution
Extract error handling into reusable concerns that jobs can include.

### Example

**From** `app/jobs/concerns/smtp_delivery_error_handling.rb`:
```ruby
module SmtpDeliveryErrorHandling
  extend ActiveSupport::Concern

  included do
    # Retry delivery to possibly-unavailable remote mailservers
    retry_on Net::OpenTimeout, Net::ReadTimeout, Socket::ResolutionError,
             wait: :polynomially_longer

    # SMTP 4xx errors are temporary - retry patiently
    retry_on Net::SMTPServerBusy, wait: :polynomially_longer

    # SMTP 50x syntax errors - some are ignorable
    rescue_from Net::SMTPSyntaxError do |error|
      case error.message
      when /\A501 5\.1\.3/
        Sentry.capture_exception error, level: :info if Fizzy.saas?
      else
        raise
      end
    end

    # SMTP 5xx fatal errors - log specific ones, raise others
    rescue_from Net::SMTPFatalError do |error|
      case error.message
      when /\A550 5\.1\.1/, /\A552 5\.6\.0/, /\A555 5\.5\.4/
        Sentry.capture_exception error, level: :info if Fizzy.saas?
      else
        raise
      end
    end
  end
end
```

**Usage in a job**:
```ruby
class Notification::Bundle::DeliverJob < ApplicationJob
  include SmtpDeliveryErrorHandling

  queue_as :backend

  def perform(bundle)
    bundle.deliver
  end
end
```

---

## Pattern 8: Concurrency Limits

### Problem
Some jobs should not run concurrently for the same resource (e.g., storage calculations).

### Solution
Use Solid Queue's `limits_concurrency` to prevent duplicate concurrent execution.

### Example

**From** `app/jobs/storage/materialize_job.rb`:
```ruby
class Storage::MaterializeJob < ApplicationJob
  queue_as :backend
  limits_concurrency to: 1, key: ->(owner) { owner }

  discard_on ActiveJob::DeserializationError

  def perform(owner)
    owner.materialize_storage
  end
end
```

**From** `app/jobs/storage/reconcile_job.rb`:
```ruby
class Storage::ReconcileJob < ApplicationJob
  class ReconcileAborted < StandardError; end

  queue_as :backend
  limits_concurrency to: 1, key: ->(owner) { owner }

  discard_on ActiveJob::DeserializationError
  retry_on ReconcileAborted, wait: 1.minute, attempts: 3

  def perform(owner)
    raise ReconcileAborted, "Could not get stable snapshot" unless owner.reconcile_storage
  end
end
```

The `key` lambda determines the concurrency scope - jobs with the same key won't run simultaneously.

---

## Quick Reference

| Pattern | When to Use |
|---------|-------------|
| Shallow Jobs | Always - keep logic in models |
| Account Context | Automatic via FizzyActiveJobExtensions |
| `*_later`/`*_now` | When model needs async operation |
| Recurring Jobs | Scheduled tasks in config/recurring.yml |
| Queue Assignment | Match job to appropriate queue |
| Continuable | Long-running iterative jobs |
| Error Concerns | Shared retry/rescue logic |
| Concurrency Limits | Prevent duplicate execution |
