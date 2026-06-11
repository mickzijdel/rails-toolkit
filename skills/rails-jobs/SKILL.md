---
name: rails-jobs
description: Use when writing background jobs with Solid Queue, including recurring jobs and context serialization
---

# Rails Background Jobs

## Pattern 1: Shallow Job Classes

The job is just a conduit for async execution; the logic lives in a model method.

```ruby
# app/jobs/webhook/delivery_job.rb
class Webhook::DeliveryJob < ApplicationJob
  queue_as :webhooks

  def perform(delivery)
    delivery.deliver
  end
end
```

```ruby
# app/models/webhook/delivery.rb
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

---

## Pattern 2: Account Context Serialization

In multi-tenant apps, a module prepended to `ActiveJob::Base` captures `Current.account` at enqueue time, serializes it as a GlobalID, and restores it around `perform` — every job gets tenant context with no manual passing. Full implementation: [[rails-multi-tenancy]] Pattern 5.

---

## Pattern 3: `*_later` / `*_now` Method Convention

`_later` suffix for methods that enqueue a job; `_now` suffix for the synchronous version when a class has both.

```ruby
# app/models/account/export.rb
class Account::Export < ApplicationRecord
  def build_later
    ExportAccountDataJob.perform_later(self)
  end

  def build
    processing!
    zipfile = generate_zip
    file.attach io: File.open(zipfile.path), filename: "export-#{id}.zip"
    mark_completed
    ExportMailer.completed(self).deliver_later
  rescue => e
    update!(status: :failed)
    raise
  end
end
```

```ruby
# Class-level batch enqueueing with perform_all_later
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
end
```

---

## Pattern 4: Recurring Jobs

Configure scheduled tasks in `config/recurring.yml` — `command:` for inline Ruby, `class:` for a job class.

```yaml
production: &production
  deliver_bundled_notifications:
    command: "Notification::Bundle.deliver_all_later"
    schedule: every 30 minutes

  delete_unused_tags:
    class: DeleteUnusedTagsJob
    schedule: every day at 04:02

  cleanup_magic_links:
    command: "MagicLink.cleanup"
    schedule: every 4 hours

  # Solid Queue maintenance — both tables need periodic clearing
  clear_solid_queue_finished_jobs:
    command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
    schedule: every hour at minute 12
  clear_solid_queue_recurring_executions:
    command: "SolidQueue::RecurringExecution.clear_in_batches"
    schedule: every hour at minute 52
```

---

## Pattern 5: SLO-Named Queues

Domain-named queues (`imports`, `exports`, `webhooks`, `backend`) multiply over time and answer none of the operational questions: how full is too full? When do we scale? When do we page someone?

Name queues after the latency promise they make — the maximum acceptable time a job sits in the queue. Every operational decision then falls out of comparing queue latency against the SLO in the queue's name. (Pattern from Nate Berkopec's *Sidekiq in Practice*, adopted at Gusto among others.)

```ruby
# Pick the queue by asking "how stale can this work be?"

# User is waiting on this (e.g. notification fan-out)
class NotifyRecipientsJob < ApplicationJob
  queue_as :within_30_seconds
end

# User expects it "soon" (e.g. export ready by email)
class ExportAccountDataJob < ApplicationJob
  queue_as :within_5_minutes
end

# Nobody is waiting (cleanup, rollups)
class DeleteUnusedTagsJob < ApplicationJob
  queue_as :within_1_hour
end
```

```yaml
# config/queue.yml
default: &default
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: within_30_seconds
      threads: 3
      processes: 2
      polling_interval: 0.1
    - queues: [ within_5_minutes, within_1_hour, solid_queue_recurring ]
      threads: 3
      processes: <%= Integer(ENV.fetch("JOB_CONCURRENCY") { Concurrent.physical_processor_count }) %>
      polling_interval: 1
```

**Key Points:**
- Ideally each worker pool listens to one queue (or one SLO tier), so a queue's latency is a true signal — not masked by workers borrowed from elsewhere.
- Autoscaling and alerting become trivial: scale when queue latency approaches the SLO in its name; page when it exceeds it.
- A handful of tiers is enough. Resist re-introducing per-domain queues; that's how queue sprawl starts. (Examples elsewhere in this skill show domain names like `:webhooks` from their source app — prefer SLO names in new code.)

---

## Pattern 6: Continuable Jobs

Long-running iterative jobs can timeout or fail midway. `ActiveJob::Continuable` gives cursor-based checkpointing so an interrupted job resumes where it left off.

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

`step :name` defines a resumable step; `step.cursor` is the last saved position (nil on first run); `step.advance! from:` saves progress.

---

## Pattern 7: Error Handling Concerns

Extract shared retry/rescue logic for jobs hitting the same external service:

```ruby
# app/jobs/concerns/smtp_delivery_error_handling.rb
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
        Sentry.capture_exception error, level: :info
      else
        raise
      end
    end

    # SMTP 5xx fatal errors - log specific ignorable ones, raise others
    rescue_from Net::SMTPFatalError do |error|
      case error.message
      when /\A550 5\.1\.1/, /\A552 5\.6\.0/, /\A555 5\.5\.4/
        Sentry.capture_exception error, level: :info
      else
        raise
      end
    end
  end
end

class Notification::Bundle::DeliverJob < ApplicationJob
  include SmtpDeliveryErrorHandling

  def perform(bundle)
    bundle.deliver
  end
end
```

---

## Pattern 8: Concurrency Limits

Solid Queue's `limits_concurrency` prevents duplicate concurrent execution for the same resource; the `key` lambda defines the scope.

```ruby
class Storage::MaterializeJob < ApplicationJob
  limits_concurrency to: 1, key: ->(owner) { owner }

  discard_on ActiveJob::DeserializationError

  def perform(owner)
    owner.materialize_storage
  end
end
```

Pair with `retry_on SomeAbortError, wait: 1.minute, attempts: 3` for jobs that should retry when they can't get a stable snapshot.

---

## Pattern 9: Generate Large Files in Jobs, Never in Controllers

A controller that builds a multi-megabyte CSV/zip/export and ships it with `send_data` hurts twice: the whole file is assembled in web-process memory (permanent RSS bloat — Ruby rarely returns freed memory to the OS), and the Puma thread is held for the entire client download. A few slow downloaders can starve the app of threads.

The controller only enqueues a job and responds immediately; the job generates the file and attaches it via Active Storage; the user downloads from storage, not from the app.

```ruby
# app/controllers/exports_controller.rb
def create
  export = Current.account.exports.create!
  export.build_later
  redirect_to export, notice: "Your export is being prepared."
end

def show
  if @export.completed?
    redirect_to rails_blob_url(@export.file, disposition: :attachment)
  end  # else the view shows "still preparing" (and can poll via Turbo)
end
```

The `Account::Export` model in Pattern 3 shows the job side: `build_later` enqueues, `build` generates the zip, attaches it, and emails a link.

**Key Points:**
- `send_data` of generated content is the smell; `send_file`/`redirect_to` for storage-served blobs is the cure.
- Applies to anything generated per-request and larger than a page of HTML: CSV admin exports, PDFs, zips.
- Bonus: generation can be retried, throttled (Pattern 8), and survives deploys.

---

## Quick Reference

| Pattern | When to Use |
|---------|-------------|
| Shallow Jobs | Always - keep logic in models |
| Account Context | Automatic — see [[rails-multi-tenancy]] |
| `*_later`/`*_now` | When model needs async operation |
| Recurring Jobs | Scheduled tasks in config/recurring.yml |
| SLO-Named Queues | Name queues by latency promise (`within_5_minutes`) |
| Continuable | Long-running iterative jobs |
| Error Concerns | Shared retry/rescue logic |
| Concurrency Limits | Prevent duplicate execution |
| Files via Jobs | Never `send_data` generated files from controllers |
