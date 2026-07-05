# Rails (ActiveRecord) Slow Query Patterns

## Pattern Recognition

### Table → Model mapping

- `users` → `User` (PascalCase singular, `app/models/user.rb`)
- `order_items` → `OrderItem`
- Join tables: `posts_tags` → `has_and_belongs_to_many :tags`

### Model file detection

```bash
find app/models -name "*.rb" -exec grep -l "class.*< ApplicationRecord" {} \;
rg "class \w+ < ApplicationRecord" app/models/ --type ruby
```

---

## Pattern 1: N+1 — Missing `includes()` / `eager_load()` / `preload()`

**SQL Signature (multiple fingerprints):**

```sql
SELECT "users".* FROM "users" WHERE "users"."id" = ?
SELECT "posts".* FROM "posts" WHERE "posts"."user_id" = ?
SELECT "comments".* FROM "comments" WHERE "comments"."post_id" = ?
```

**ORM Cause:**

```ruby
# ❌ N+1: each user.posts hits DB
@users = User.all
@users.each do |user|
  puts user.posts.count   # 1 query per user
end

# OR in controller
# app/controllers/users_controller.rb
def index
  @users = User.all  # Missing .includes(:posts)
end

# View: app/views/users/index.html.erb
# <% @users.each do |user| %>
#   <%= user.posts.count %>  ← N+1 here
# <% end %>
```

**Fix — Choosing the right method:**

```ruby
# ✅ includes: smart — chooses preload or eager_load based on usage
@users = User.includes(:posts).all

# ✅ preload: always separate queries (good for large, unqueried relations)
@users = User.preload(:posts, :comments).all

# ✅ eager_load: always LEFT JOIN (good when you filter/order by relation)
@users = User.eager_load(:posts).where(posts: { status: 'published' }).all

# ✅ strict_loading: raise error on N+1 (Rails 6.1+ — for development)
class User < ApplicationRecord
  has_many :posts
  strict_loading_by_default  # Raises ActiveRecord::StrictLoadingViolationError
end

# ✅ Bullet gem: auto-detect N+1 in logs (add to Gemfile)
# gem 'bullet', group: :development
# Auto-detects: missing eager loading, unused eager loading, counter cache
```

**Detection:**

- `SELECT "users".* FROM "users" WHERE "users"."id" = ?` runs many times
- `SELECT "posts".* FROM "posts" WHERE "posts"."user_id" = ?` similar
- Both in same request context, high COUNT_STAR with low avg_rows

**Severity:** 🔴 Critical

---

## Pattern 2: Missing Counter Cache

**SQL Signature:**

```sql
SELECT COUNT(*) FROM "posts" WHERE "posts"."user_id" = ?
SELECT COUNT(*) FROM "comments" WHERE "comments"."post_id" = ?
```

**ORM Cause:**

```ruby
# ❌ Count query on every page render
# View: <%= @user.posts.count %>
# View: <%= @user.posts.size %>  # .size without loaded relation = COUNT query

# Model
class User < ApplicationRecord
  has_many :posts  # No counter_cache
end
```

**Fix:**

```ruby
# ✅ Add counter cache column + update model
# Migration:
# add_column :users, :posts_count, :integer, default: 0, null: false
# User.reset_counters(existing_user.id, :posts)

# Model:
class Post < ApplicationRecord
  belongs_to :user, counter_cache: true  # Auto-updates users.posts_count
end

# View: now uses the cached column
# <%= @user.posts_count %>  # No query!
```

**Detection:**

- `SELECT COUNT(*)` on relation tables
- High frequency, low individual cost but adds up
- No `_count` column in parent table schema

**Severity:** 🟠 High (frequency-based)

---

## Pattern 3: `where` on Unindexed Columns

**SQL Signature:**

```sql
SELECT "orders".* FROM "orders" WHERE "orders"."status" = ? AND "orders"."created_at" > ?
```

**ORM Cause:**

```ruby
# ❌ No index on status + created_at
Order.where(status: 'pending')
     .where('created_at > ?', 7.days.ago)
```

**Fix:**

```ruby
# ✅ Migration
class AddIndexToOrdersStatusCreatedAt < ActiveRecord::Migration[7.0]
  def change
    add_index :orders, [:status, :created_at],
              name: 'idx_orders_status_created_at'
  end
end

# ✅ Use explain to verify
Order.where(status: 'pending').explain  # Check for index usage
```

**Severity:** 🟠 High

---

## Pattern 4: OFFSET Pagination

**SQL Signature:**

```sql
SELECT "posts".* FROM "posts" ORDER BY "posts"."id" DESC LIMIT 20 OFFSET 100000
```

**ORM Cause:**

```ruby
# ❌ Standard pagination (OFFSET-based)
# Gem: kaminari or will_paginate
@posts = Post.page(params[:page]).per(20)

# Bad: params[:page] = 5000 → OFFSET 100000
```

**Fix:**

```ruby
# ✅ Cursor pagination (for APIs / infinite scroll)
@posts = Post.where('id < ?', params[:cursor])
             .order(id: :desc)
             .limit(20)

# ✅ Or use a gem for cursor pagination
# gem 'order_query' or implement manual cursor
```

**Detection:**

- `LIMIT ? OFFSET ?` especially with large offset
- `avg_rows_examined >> avg_rows_sent`

**Severity:** 🟡 Medium

---

## Pattern 5: `pluck` Missing — Loading Full Objects for IDs

**SQL Signature:**

```sql
SELECT "users".* FROM "users" WHERE "users"."active" = TRUE
-- But only IDs are needed
```

**ORM Cause:**

```ruby
# ❌ Loading full User objects just for IDs
user_ids = User.where(active: true).map(&:id)
# SELECT * FROM users WHERE active = TRUE  -- loads all columns

user_ids = User.where(active: true).ids
# SELECT "users"."id" FROM "users" WHERE active = TRUE  -- better, but still
```

**Fix:**

```ruby
# ✅ pluck: returns array of values directly from DB
user_ids = User.where(active: true).pluck(:id)
# SELECT "users"."id" FROM "users" WHERE "users"."active" = TRUE

# ✅ pick: single value (Rails 6+)
latest_id = Order.order(created_at: :desc).pick(:id)
```

**Detection:**

- `SELECT *` where only IDs/one column is used downstream
- Wide tables loaded unnecessarily

**Severity:** 🟡 Medium

---

## Pattern 6: `find_each` / `find_in_batches` Missing

**SQL Signature:**

```sql
SELECT "orders".* FROM "orders"  -- Millions of rows, no batching
```

**ORM Cause:**

```ruby
# ❌ Loading all records into memory
Order.all.each do |order|     # Instantiates MILLIONS of AR objects
  order.process!
end

# Equally bad:
Order.where(status: 'pending').each { |o| o.process! }
```

**Fix:**

```ruby
# ✅ find_each: batch 1000, yield individually
Order.where(status: 'pending').find_each(batch_size: 1000) do |order|
  order.process!
end

# ✅ find_in_batches: batch 1000, yield array
Order.where(status: 'pending').find_in_batches(batch_size: 1000) do |batch|
  # batch is an array of 1000 orders
  batch.each(&:process!)
end

# ✅ in_batches: returns ActiveRecord::Batches::BatchEnumerator
Order.where(status: 'pending').in_batches(of: 1000) do |relation|
  # relation is scoped to this batch — use for bulk operations
  relation.update_all(status: 'processed')
end
```

**Detection:**

- No LIMIT on large table queries
- Process-intensive jobs using `.all.each`

**Severity:** 🟠 High (memory exhaustion)

---

## Pattern 7: `update_all` / `delete_all` Missing — Row-at-a-Time Updates

**SQL Signature (many individual UPDATEs):**

```sql
UPDATE "orders" SET "status" = ? WHERE "orders"."id" = ?
UPDATE "orders" SET "status" = ? WHERE "orders"."id" = ?
-- ... thousands of individual UPDATEs
```

**ORM Cause:**

```ruby
# ❌ Individual saves
Order.where(status: 'pending').each do |order|
  order.update(status: 'expired')  # 1 UPDATE + 1 SELECT per order
end
```

**Fix:**

```ruby
# ✅ Single bulk UPDATE (no callbacks, no validations! Know the trade-off)
Order.where(status: 'pending').update_all(
  status: 'expired',
  expired_at: Time.current
)
# UPDATE "orders" SET "status" = 'expired', "expired_at" = '...'
# WHERE "orders"."status" = 'pending'

# ✅ If you need callbacks, batch process with transaction
Order.where(status: 'pending').find_in_batches do |batch|
  Order.transaction do
    batch.each { |order| order.update!(status: 'expired') }
  end
end
```

**Detection:**

- Many identical UPDATEs with different IDs
- Looping `.each { |r| r.update(...) }` pattern

**Severity:** 🟠 High

---

## Pattern 8: `joins` When `includes` Would Be Better

**SQL Signature:**

```sql
SELECT "users".* FROM "users"
INNER JOIN "posts" ON "posts"."user_id" = "users"."id"
WHERE "posts"."status" = ?
-- but user.posts is accessed later → triggers N+1
```

**ORM Cause:**

```ruby
# ❌ joins for filtering but then lazy-loads the relation
@users = User.joins(:posts).where(posts: { status: 'published' })
# View: user.posts  ← N+1 because .joins doesn't preload!
```

**Fix:**

```ruby
# ✅ includes = filtering JOIN + eager loading
@users = User.includes(:posts).where(posts: { status: 'published' })
# Rails generates LEFT JOIN + loads posts association

# Or be explicit:
@users = User.joins(:posts).where(posts: { status: 'published' })
             .includes(:posts)  # Also preload!
```

**Detection:**

- `INNER JOIN` in fingerprint
- Subsequent queries same as N+1 pattern
- `.joins(...)` in controller but no `.includes(...)`

**Severity:** 🟡 Medium

---

## Pattern 9: Unscoped Queries

**SQL Signature:**

```sql
SELECT "posts".* FROM "posts" WHERE "posts"."deleted_at" IS NULL
-- default_scope automatically added, but .unscoped removes it
```

**ORM Cause:**

```ruby
class Post < ApplicationRecord
  default_scope { where(deleted_at: nil) }
end

# ❌ .unscoped bypasses all scopes, including soft-delete
Post.unscoped.all  # Returns deleted posts + no index usage on deleted_at

# ❌ default_scope itself is an anti-pattern (hidden behavior)
```

**Fix:**

```ruby
# ✅ Explicit scope instead of default_scope
class Post < ApplicationRecord
  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
end

# ✅ Use discard gem for soft deletes
# gem 'discard'
class Post < ApplicationRecord
  include Discard::Model  # Provides .kept, .discarded, .with_discarded
end
```

**Severity:** 🟡 Medium

---

## Pattern 10: `touch: true` Cascading Updates

**SQL Signature:**

```sql
UPDATE "posts" SET "updated_at" = ? WHERE "posts"."id" = ?
UPDATE "users" SET "updated_at" = ? WHERE "users"."id" = ?
-- Cascade: touching a comment touches its post, which touches its user
```

**ORM Cause:**

```ruby
# ❌ Unnecessary cascading touch
class Post < ApplicationRecord
  belongs_to :user, touch: true  # Touches user when post updates
end

class Comment < ApplicationRecord
  belongs_to :post, touch: true  # Touches post when comment added
  # This cascades: comment → post → user (3 UPDATEs for 1 comment)
end
```

**Fix:**

```ruby
# ✅ Remove touch when not needed
class Post < ApplicationRecord
  belongs_to :user  # No touch — user cache is invalidated differently
end

# ✅ Or use conditional touch
belongs_to :post, touch: true, if: :should_touch_parent?
```

**Severity:** 🟡 Medium (unless very high comment volume)

---

## Rails-Specific Tooling

### Bullet Gem (auto-detection)

```ruby
# Gemfile
group :development, :test do
  gem 'bullet'
end

# config/environments/development.rb
config.after_initialize do
  Bullet.enable = true
  Bullet.alert = true          # Browser popup
  Bullet.bullet_logger = true  # log/bullet.log
  Bullet.rails_logger = true   # Rails logger
  Bullet.add_footer = true     # HTML footer with details
end
```

### Query Log Analysis

```bash
# Find N+1 in logs
grep -c "SELECT.*FROM.*WHERE.*id" log/production.log | sort -rn

# Most repeated queries
grep "SELECT" log/production.log | sort | uniq -c | sort -rn | head -20
```

### Production N+1 Safety

```ruby
# config/environments/production.rb
config.active_record.strict_loading_by_default = false  # Don't enable globally

# Per-model or per-query in critical paths:
User.strict_loading.all  # Raises if N+1 would occur
```
