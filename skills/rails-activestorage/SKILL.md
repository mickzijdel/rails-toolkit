---
name: rails-activestorage
description: Use when handling file uploads, variants, direct uploads, and rich text attachments
---

# Rails ActiveStorage Patterns

## 1. Attachments Concern — Rich Text Introspection

Access all attachments from a model's rich text content and identify remote images/videos embedded in ActionText:

```ruby
# app/models/concerns/attachments.rb
module Attachments
  extend ActiveSupport::Concern

  # Variants used by ActionText embeds. Processed immediately on attachment to avoid
  # read replica issues (lazy variants would attempt writes on read replicas).
  #
  # Patched into ActionText::RichText in config/initializers/action_text.rb
  VARIANTS = {
    # The `n: -1` loader option bypasses GIF-incompatible intent filtering in
    # vipsthumbnail, preserving all frames in animated GIFs. Only `n` is accepted
    # as an override; the full parameter name `intent` doesn't work.
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

  def remote_videos
    @remote_videos ||= rich_text_record&.body&.attachables&.grep(ActionText::Attachables::RemoteVideo) || []
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

```ruby
class Card < ApplicationRecord
  include Attachments
  has_rich_text :description
end
```

---

## 2. Registering Variants on ActionText Embeds

Wire the `VARIANTS` above onto every rich-text embed by overriding the `:embeds` association:

```ruby
# config/initializers/action_text.rb
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

`process: :immediately` matters: lazy variant processing attempts writes, which raises on read replicas.

---

## 3. Storage Tracking for Quotas

Track storage usage per account/board for billing or quotas with a ledger: record attach/detach events via attachment callbacks, materialize totals asynchronously.

Tracked models include a `Storage::Tracked` concern that defines the trackable-record API the callbacks below rely on: `storage_tracked_record` (returns `self`) and `board_for_storage_tracking` (returns `board`; override in models where the board is derived differently).

```ruby
# app/models/storage/attachment_tracking.rb
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

# config/initializers/active_storage.rb
ActiveSupport.on_load(:active_storage_attachment) do
  include Storage::AttachmentTracking
end
```

---

## 4. N+1 Prevention with Attachment Preloading

Rails generates preloadable associations for every attachment; use the right names:

```ruby
Model.preload(:image_attachment)               # has_one_attached
Model.preload(:documents_attachments)          # has_many_attached
Model.preload(image_attachment: :blob)         # with blob data
Model.with_rich_text_description_and_embeds    # ActionText with embedded files

# Bundle into a named scope alongside the attachment declaration
module User::Avatar
  included do
    has_one_attached :avatar do |attachable|
      attachable.variant :thumb, resize_to_fill: [ 256, 256 ], process: :immediately
    end

    scope :with_avatars, -> { preload(:account, :avatar_attachment) }
  end
end
```

Fold these into the model's `preloaded` scope — see [[rails-performance]].

---

## 5. Avatar Upload with Validation

Content-type and dimension validation for user uploads:

```ruby
module User::Avatar
  extend ActiveSupport::Concern

  ALLOWED_AVATAR_CONTENT_TYPES = %w[ image/jpeg image/png image/gif image/webp ].freeze
  MAX_AVATAR_DIMENSIONS = { width: 4096, height: 4096 }.freeze

  included do
    has_one_attached :avatar do |attachable|
      attachable.variant :thumb, resize_to_fill: [ 256, 256 ], process: :immediately
    end

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

Configure multiple services in `storage.yml`, select via environment variable:

```yaml
local:
  service: Disk
  root: <%= Rails.root.join("storage", Rails.env, "files") %>

devminio:
  service: S3
  bucket: app-dev-activestorage
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
  secret_access_key: <%= ENV["S3_SECRET_ACCESS_KEY"] %>
  bucket: <%= ENV["S3_BUCKET"] %>
  endpoint: <%= ENV["S3_ENDPOINT"] %>
  force_path_style: <%= ENV["S3_FORCE_PATH_STYLE"] == "true" %>
  region: <%= ENV.fetch("S3_REGION", "us-east-1") %>
```

```ruby
# config/environments/production.rb
config.active_storage.service = ENV.fetch("ACTIVE_STORAGE_SERVICE", "local").to_sym
```

**Key S3 options:** `force_path_style: true` is required for MinIO and some S3-compatible services; `request_checksum_calculation: when_required` for FlashBlade compatibility; `endpoint` for any non-AWS service.

---

## 7. Direct Upload with Extended Expiry

Large uploads through Cloudflare (or similar proxies) fail because the proxy only forwards the upload once fully buffered — long after the default URL expiry.

```ruby
# lib/rails_ext/active_storage_blob_service_url_for_direct_upload_expiry.rb
module ActiveStorage
  mattr_accessor :service_urls_for_direct_uploads_expire_in, default: 48.hours
end

module ActiveStorageBlobServiceUrlForDirectUploadExpiry
  # Lengthens direct-upload URL expiry without touching download URL expiry.
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

Extend `DirectUploadsController` so direct uploads accept both browser sessions and bearer tokens:

```ruby
# config/initializers/active_storage.rb
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

---

## 9. Multi-Tenant Blob Isolation

Validate on attach that the blob's account matches the record's account, and that tracked blobs aren't reused across records:

```ruby
# config/initializers/active_storage_no_reuse.rb
ActiveSupport.on_load(:active_storage_attachment) do
  validate :blob_account_matches_record, on: :create
  validate :no_tracked_blob_reuse, on: :create

  private
    def blob_account_matches_record
      return unless record&.try(:account).present?
      return if whitelisted_for_cross_account?

      unless blob&.account_id == record.account.id
        errors.add(:blob_id, "blob account must match record account")
      end
    end

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

Render rich text for export by walking its attachables and handling each type:

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
has_one_attached :image
has_one_attached :avatar do |attachable|
  attachable.variant :thumb, resize_to_fill: [256, 256]
end
has_many_attached :documents
has_rich_text :description
```

### Variant Options

```ruby
{
  resize_to_limit: [800, 600],     # Fit within dimensions
  resize_to_fill: [256, 256],      # Crop to exact dimensions
  loader: { n: -1 },               # Preserve GIF animation
  process: :immediately            # Process on upload (not lazy; required on read replicas)
}
```

### Preloading

See Pattern 4: `:image_attachment` / `:documents_attachments` / `with_rich_text_*_and_embeds`.

### Storage Service Selection

`ACTIVE_STORAGE_SERVICE=s3` (or `local`, `devminio`).
