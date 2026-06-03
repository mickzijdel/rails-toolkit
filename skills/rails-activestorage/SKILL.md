---
name: rails-activestorage
description: Use when handling file uploads, variants, direct uploads, and rich text attachments
---

# Rails ActiveStorage Patterns

## When to Use

- Adding file uploads to models
- Creating image variants (thumbnails, resizing)
- Working with rich text attachments (ActionText embeds)
- Managing file storage across environments
- Implementing direct uploads for large files
- Tracking storage usage for billing/quotas
- Preventing N+1 queries with attachments

---

## 1. Attachments Concern - Rich Text Introspection

### Problem
You need to access all attachments from a model's rich text content and identify remote images/videos embedded in ActionText.

### Solution
Use the `Attachments` concern which provides methods to introspect rich text embeds and identify remote media.

### Example
From `/app/models/concerns/attachments.rb`:

```ruby
module Attachments
  extend ActiveSupport::Concern

  # Variants used by ActionText embeds. Processed immediately on attachment to avoid
  # read replica issues (lazy variants would attempt writes on read replicas).
  #
  # Patched into ActionText::RichText in config/initializers/action_text.rb
  VARIANTS = {
    # vipsthumbnail used to create sized image variants has a intent setting to manage colors during
    # resize. By setting an invalid intent value the gif-incompatible intent filtering is skipped and
    # the gif can be rendered with all its frame intact.
    #
    # Only `n` is accepted as an override, using the full parameter name `intent` doesn't work.
    small: { loader: { n: -1 }, resize_to_limit: [ 800, 600 ] },
    large: { loader: { n: -1 }, resize_to_limit: [ 1024, 768 ] }
  }

  def attachments
    rich_text_record&.embeds || []
  end

  def has_attachments?
    attachments.any?
  end

  def remote_images
    @remote_images ||= rich_text_record&.body&.attachables&.grep(ActionText::Attachables::RemoteImage) || []
  end

  def has_remote_images?
    remote_images.any?
  end

  def remote_videos
    @remote_videos ||= rich_text_record&.body&.attachables&.grep(ActionText::Attachables::RemoteVideo) || []
  end

  def has_remote_videos?
    remote_videos.any?
  end

  private
    def rich_text_record
      @rich_text_record ||= begin
        association = self.class.reflect_on_all_associations(:has_one).find { it.klass == ActionText::RichText }
        public_send(association.name)
      end
    end
end
```

**Usage in models:**

```ruby
class Card < ApplicationRecord
  include Attachments
  has_rich_text :description
end

class Comment < ApplicationRecord
  include Attachments
  has_rich_text :body
end
```

---

## 2. Variant Definitions with GIF Support

### Problem
Image variants break animated GIFs because libvips' thumbnail function applies color intent filtering that's incompatible with GIF frames.

### Solution
Use the `loader: { n: -1 }` option to skip intent filtering and preserve all GIF frames during resizing.

### Example
From `/app/models/concerns/attachments.rb`:

```ruby
VARIANTS = {
  # The `n: -1` loader option bypasses GIF-incompatible intent filtering
  # This preserves all frames in animated GIFs
  small: { loader: { n: -1 }, resize_to_limit: [ 800, 600 ] },
  large: { loader: { n: -1 }, resize_to_limit: [ 1024, 768 ] }
}
```

**Registering variants on ActionText embeds:**

From `/config/initializers/action_text.rb`:

```ruby
module ActionText
  module Extensions
    module RichText
      extend ActiveSupport::Concern

      included do
        # This overrides the default :embeds association!
        has_many_attached :embeds do |attachable|
          ::Attachments::VARIANTS.each do |variant_name, variant_options|
            attachable.variant variant_name, **variant_options, process: :immediately
          end
        end
      end
    end
  end
end

ActiveSupport.on_load(:action_text_rich_text) do
  include ActionText::Extensions::RichText
end
```

**Key insight:** Using `process: :immediately` avoids read replica issues where lazy variant processing would attempt writes on read replicas.

---

## 3. Storage Tracking for Quotas

### Problem
You need to track storage usage per account/board for billing, quotas, or analytics without N+1 queries.

### Solution
Use the `Storage::Tracked` concern with a ledger-based approach that records attach/detach events and materializes totals asynchronously.

### Example
From `/app/models/concerns/storage/tracked.rb`:

```ruby
module Storage::Tracked
  extend ActiveSupport::Concern

  included do
    before_update :track_board_transfer, if: :board_transfer?
  end

  # Return self as the trackable record for storage entries
  def storage_tracked_record
    self
  end

  # Override in models where board is determined differently
  def board_for_storage_tracking
    board
  end

  # Total bytes for all attachments on this record
  def storage_bytes
    attachments_for_storage.sum { |a| a.blob.byte_size }
  end
end
```

**Attachment tracking hooks:**

From `/app/models/storage/attachment_tracking.rb`:

```ruby
module Storage::AttachmentTracking
  extend ActiveSupport::Concern

  included do
    before_destroy :snapshot_storage_context
    after_create_commit :record_storage_attach
    after_destroy_commit :record_storage_detach
  end

  private
    def record_storage_attach
      return unless storage_tracked_record

      Storage::Entry.record \
        account: storage_tracked_record.account,
        board: storage_tracked_record.board_for_storage_tracking,
        recordable: storage_tracked_record,
        blob: blob,
        delta: blob.byte_size,
        operation: "attach"
    end
end
```

**Registering the tracking module:**

From `/config/initializers/active_storage.rb`:

```ruby
ActiveSupport.on_load(:active_storage_attachment) do
  include Storage::AttachmentTracking
end
```

---

## 4. N+1 Prevention with Attachment Preloading

### Problem
Loading attachments for multiple records causes N+1 queries.

### Solution
Preload attachment associations using Rails' built-in `*_attachment` associations and `with_rich_text_*_and_embeds` scopes.

### Example
From `/app/models/card.rb`:

```ruby
class Card < ApplicationRecord
  has_one_attached :image
  has_rich_text :description

  # Preload avatar attachments for associated users
  scope :with_users, -> {
    preload(
      creator: [ :avatar_attachment, :account ],
      assignees: [ :avatar_attachment, :account ]
    )
  }

  # Comprehensive preloading for card lists
  scope :preloaded, -> {
    with_users.preload(
      :column, :tags, :steps, :closure, :goldness, :activity_spike,
      :image_attachment,
      board: [ :entropy, :columns ],
      not_now: [ :user ]
    ).with_rich_text_description_and_embeds
  }
end
```

From `/app/models/user/avatar.rb`:

```ruby
module User::Avatar
  included do
    has_one_attached :avatar do |attachable|
      attachable.variant :thumb, resize_to_fill: [ 256, 256 ], process: :immediately
    end

    scope :with_avatars, -> { preload(:account, :avatar_attachment) }
  end
end
```

**Key patterns:**
- Use `*_attachment` (singular) for `has_one_attached`
- Use `*_attachments` (plural) for `has_many_attached`
- Use `with_rich_text_*_and_embeds` for ActionText with embedded files

---

## 5. Avatar Upload with Validation

### Problem
You need to handle user avatar uploads with content type and dimension validation.

### Solution
Create a concern with allowed content types, dimension limits, and a thumbnail variant.

### Example
From `/app/models/user/avatar.rb`:

```ruby
module User::Avatar
  extend ActiveSupport::Concern

  ALLOWED_AVATAR_CONTENT_TYPES = %w[ image/jpeg image/png image/gif image/webp ].freeze
  MAX_AVATAR_DIMENSIONS = { width: 4096, height: 4096 }.freeze

  included do
    has_one_attached :avatar do |attachable|
      attachable.variant :thumb, resize_to_fill: [ 256, 256 ], process: :immediately
    end

    scope :with_avatars, -> { preload(:account, :avatar_attachment) }

    validate :avatar_content_type_allowed, :avatar_dimensions_allowed, if: :avatar_attached?
  end

  def avatar_attached?
    avatar.attached?
  end

  def avatar_thumbnail
    avatar.variable? ? avatar.variant(:thumb) : avatar
  end

  private
    def avatar_content_type_allowed
      if !ALLOWED_AVATAR_CONTENT_TYPES.include?(avatar.content_type)
        errors.add(:avatar, "must be a JPEG, PNG, GIF, or WebP image")
      end
    end

    def avatar_dimensions_allowed
      return unless avatar.blob.analyzed? || avatar.blob.analyze

      width = avatar.blob.metadata[:width]
      height = avatar.blob.metadata[:height]

      if width && width > MAX_AVATAR_DIMENSIONS[:width]
        errors.add(:avatar, "width must be less than #{MAX_AVATAR_DIMENSIONS[:width]}px")
      end

      if height && height > MAX_AVATAR_DIMENSIONS[:height]
        errors.add(:avatar, "height must be less than #{MAX_AVATAR_DIMENSIONS[:height]}px")
      end
    end
end
```

---

## 6. Service Configuration (Local vs S3)

### Problem
You need different storage backends for development (local disk) vs production (S3-compatible).

### Solution
Configure multiple services in `storage.yml` and select via environment variable.

### Example
From `/config/storage.oss.yml`:

```yaml
test:
  service: Disk
  root: <%= Rails.root.join("tmp/storage/files") %>

local:
  service: Disk
  root: <%= Rails.root.join("storage", Rails.env, "files") %>

devminio:
  service: S3
  bucket: fizzy-dev-activestorage
  endpoint: "http://minio.localhost:39000"
  force_path_style: true
  request_checksum_calculation: when_required
  response_checksum_validation: when_required
  region: us-east-1
  access_key_id: minioadmin
  secret_access_key: minioadmin

s3:
  service: S3
  access_key_id: <%= ENV["S3_ACCESS_KEY_ID"] %>
  bucket: <%= ENV["S3_BUCKET"] || "fizzy-#{Rails.env}-activestorage" %>
  endpoint: <%= ENV["S3_ENDPOINT"] %>
  force_path_style: <%= ENV["S3_FORCE_PATH_STYLE"] == "true" %>
  region: <%= ENV.fetch("S3_REGION", "us-east-1") %>
  request_checksum_calculation: <%= ENV.fetch("S3_REQUEST_CHECKSUM_CALCULATION", "when_supported") %>
  response_checksum_validation: <%= ENV.fetch("S3_RESPONSE_CHECKSUM_VALIDATION", "when_supported") %>
  secret_access_key: <%= ENV["S3_SECRET_ACCESS_KEY"] %>
```

**Environment-based service selection:**

From `/config/environments/production.rb`:

```ruby
# Select Active Storage service via env var; default to local disk.
if config.active_storage.service.blank?
  config.active_storage.service = ENV.fetch("ACTIVE_STORAGE_SERVICE", "local").to_sym
end
```

**Key S3 options:**
- `force_path_style: true` - Required for MinIO and some S3-compatible services
- `request_checksum_calculation: when_required` - For FlashBlade compatibility
- `endpoint` - Custom endpoint for non-AWS S3-compatible services

---

## 7. Direct Upload with Extended Expiry

### Problem
Large file uploads through Cloudflare (or similar proxies) fail because the upload URL expires before the file is fully buffered.

### Solution
Extend the direct upload URL expiry time to accommodate slow uploads.

### Example
From `/lib/rails_ext/active_storage_blob_service_url_for_direct_upload_expiry.rb`:

```ruby
module ActiveStorage
  mattr_accessor :service_urls_for_direct_uploads_expire_in, default: 48.hours
end

module ActiveStorageBlobServiceUrlForDirectUploadExpiry
  # Override default expires_in to accommodate long upload URL expiry
  # without having to lengthen download URL expiry.
  #
  # Accounts for Cloudflare only proxying slow client uploads once they're
  # fully buffered, long after the URL expired.
  #
  # 48 hours covers a 10GB upload at 0.5Mbps.
  def service_url_for_direct_upload(expires_in: ActiveStorage.service_urls_for_direct_uploads_expire_in)
    super
  end
end

ActiveSupport.on_load :active_storage_blob do
  prepend ::ActiveStorageBlobServiceUrlForDirectUploadExpiry
end
```

---

## 8. Direct Upload Authentication

### Problem
Direct uploads need authentication that works for both browser sessions and API tokens.

### Solution
Extend the DirectUploadsController with authentication that accepts both session-based auth and bearer tokens.

### Example
From `/config/initializers/active_storage.rb`:

```ruby
module ActiveStorageDirectUploadsControllerExtensions
  extend ActiveSupport::Concern

  included do
    include Authentication
    include Authorization
    skip_forgery_protection if: :authenticate_by_bearer_token
  end
end

Rails.application.config.to_prepare do
  ActiveStorage::DirectUploadsController.include ActiveStorageDirectUploadsControllerExtensions
end
```

**Test example:**

From `/test/controllers/active_storage/direct_uploads_controller_test.rb`:

```ruby
class ActiveStorage::DirectUploadsControllerTest < ActionDispatch::IntegrationTest
  test "create with valid access token" do
    post rails_direct_uploads_path,
      params: {
        blob: {
          filename: "screenshot.png",
          byte_size: 12345,
          checksum: "GQ5SqLsM7ylnji0Wgd9wNC==",
          content_type: "image/png"
        }
      },
      headers: { "Authorization" => "Bearer #{access_token.token}" },
      as: :json

    assert_response :success
    assert_includes response.parsed_body.keys, "direct_upload"
  end
end
```

---

## 9. Multi-Tenant Blob Isolation

### Problem
In a multi-tenant app, blobs must be isolated per account to prevent cross-tenant data access.

### Solution
Validate that blob's account_id matches the record's account_id on attachment.

### Example
From `/config/initializers/active_storage_no_reuse.rb`:

```ruby
ActiveSupport.on_load(:active_storage_attachment) do
  validate :blob_account_matches_record, on: :create
  validate :no_tracked_blob_reuse, on: :create

  private
    # Multi-tenant safety: blob must belong to same account as record
    def blob_account_matches_record
      return unless record&.try(:account).present?
      return if whitelisted_for_cross_account?

      unless blob&.account_id == record.account.id
        errors.add(:blob_id, "blob account must match record account")
      end
    end

    # Ledger integrity: blob can only have one tracked attachment
    def no_tracked_blob_reuse
      tracked_record = record&.try(:storage_tracked_record)
      return unless tracked_record.present?
      return if whitelisted_for_cross_account?

      existing = ActiveStorage::Attachment
        .where(blob_id: blob_id)
        .where(record_type: Storage::TRACKED_RECORD_TYPES)
        .where.not(id: id)
        .exists?

      if existing
        errors.add(:blob_id, "cannot reuse blob in tracked storage context")
      end
    end
end
```

---

## 10. Exporting Attachments from Rich Text

### Problem
You need to export cards with all their attachments, including those embedded in rich text content.

### Solution
Iterate through rich text attachables and handle different attachment types (blobs, remote images).

### Example
From `/app/models/card/exportable.rb`:

```ruby
module Card::Exportable
  def export_attachments
    collect_attachments.map do |attachment|
      { path: export_attachment_path(attachment.blob), blob: attachment.blob }
    end
  end

  private
    def export_html(rich_text)
      return "" if rich_text.blank?

      rich_text.body.render_attachments do |attachment|
        attachment_representation(attachment)
      end.to_html
    end

    def attachment_representation(attachment)
      case attachable = attachment.attachable
      when ActiveStorage::Blob
        path = export_attachment_path(attachable)
        if attachable.image?
          tag.img(src: path, alt: attachable.filename)
        else
          tag.a(attachable.filename, href: path)
        end
      when ActionText::Attachables::RemoteImage
        tag.img(src: attachable.url, alt: "Remote image")
      else
        attachment.to_html
      end
    end

    def collect_attachments
      attachments.to_a + comments.flat_map { |c| c.attachments.to_a }
    end
end
```

---

## Quick Reference

### Attachment Declarations

```ruby
# Single file
has_one_attached :image
has_one_attached :avatar do |attachable|
  attachable.variant :thumb, resize_to_fill: [256, 256]
end

# Multiple files
has_many_attached :documents

# Rich text with embeds
has_rich_text :description
```

### Preloading Patterns

```ruby
# Single attachment
Model.preload(:image_attachment)

# Multiple attachments
Model.preload(:documents_attachments)

# With blob data
Model.preload(image_attachment: :blob)

# Rich text with embeds
Model.with_rich_text_description_and_embeds

# Complex associations
Model.preload(user: [:avatar_attachment, :account])
```

### Variant Options

```ruby
{
  resize_to_limit: [800, 600],     # Fit within dimensions
  resize_to_fill: [256, 256],      # Crop to exact dimensions
  loader: { n: -1 },               # Preserve GIF animation
  process: :immediately            # Process on upload (not lazy)
}
```

### Storage Service Selection

```bash
# Environment variable
ACTIVE_STORAGE_SERVICE=s3  # or local, devminio
```
