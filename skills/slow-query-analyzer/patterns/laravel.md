# Laravel (Eloquent & Query Builder) Slow Query Patterns

## Pattern Recognition

### Table → Model mapping

- `users` → `App\Models\User` (PascalCase singular, `app/Models/`)
- `posts` → `App\Models\Post`
- `order_items` → `App\Models\OrderItem`
- Pivot tables: `post_tag` → `Post::belongsToMany(Tag::class)`

### Model file detection

```bash
# Find models
find app/Models -name "*.php" -exec grep -l "class.*extends Model" {} \;
rg "class \w+ extends Model" app/Models/ --type php
```

---

## Pattern 1: N+1 — Missing Eager Loading

**SQL Signature (multiple fingerprints, same shape):**

```sql
SELECT * FROM `posts` WHERE `posts`.`user_id` = ?
SELECT * FROM `posts` WHERE `posts`.`user_id` IN (?, ?, ?, ...)
SELECT * FROM `comments` WHERE `comments`.`post_id` = ?
```

**ORM Cause:**

```php
// ❌ Model: User.php
// ❌ Controller or View
$users = User::all();      // 1 query
foreach ($users as $user) {
    echo $user->posts;     // 1 query per user = N queries!
}
```

**Fix:**

```php
// ✅ Eager load with ->with()
$users = User::with('posts.comments')->get();

// ✅ Or set $with on the model (use carefully)
class User extends Model {
    protected $with = ['posts'];  // Always eager-load posts
}

// ✅ Lazy eager loading (when you already have a collection)
$users = User::all();
$users->load('posts.comments');
```

**Detection Heuristics:**

- Multiple fingerprints sharing table names
- High execution count with low avg_rows_sent (< 100)
- Fingerprints appear together in time (FIRST_SEEN clustered)
- `User` model has `hasMany('posts')` but controller doesn't call `->with('posts')`

**Severity:** 🔴 Critical — multiplies queries by N

---

## Pattern 2: N+1 — `whereHas` / `withCount` on Large Relations

**SQL Signature:**

```sql
SELECT * FROM `users` WHERE EXISTS (
    SELECT * FROM `orders` WHERE `users`.`id` = `orders`.`user_id`
) ORDER BY `users`.`created_at` DESC LIMIT 20
```

**ORM Cause:**

```php
// ❌ whereHas with unindexed foreign key
$users = User::whereHas('orders')->paginate(20);

// ❌ withCount on large relation
$users = User::withCount('orders')->paginate(20);
```

**Fix:**

```php
// ✅ Ensure index on orders.user_id first
// ✅ Use whereHas with column selection
$users = User::whereHas('orders', function ($q) {
    $q->select('id');  // Minimize subquery columns
})->paginate(20);
```

**Detection:**

- `EXISTS (SELECT * FROM` in fingerprint
- No index on the FK column used in the subquery
- `withCount` or `has` on an unindexed relation

**Severity:** 🟠 High

---

## Pattern 3: Full Table Scans on Large Tables

**SQL Signature:**

```sql
SELECT * FROM `posts` WHERE `status` = ? ORDER BY `created_at` DESC
SELECT * FROM `users` WHERE `role` = ?
```

**ORM Cause:**

```php
// ❌ No index on filtered column
Post::where('status', 'published')
    ->orderBy('created_at', 'desc')
    ->get();
```

**Fix:**

```php
// ✅ Add composite index (in migration)
Schema::table('posts', function (Blueprint $table) {
    $table->index(['status', 'created_at']);  // Composite index
});

// ✅ Or select only needed columns
Post::select('id', 'title', 'created_at')
    ->where('status', 'published')
    ->orderBy('created_at', 'desc')
    ->get();
```

**SQL Fix (approval required):**

```sql
CREATE INDEX idx_posts_status_created ON posts (status, created_at);
```

**Detection:**

- `type: ALL` in EXPLAIN
- `SUM_NO_INDEX_USED > 0` in Performance Schema
- `possible_keys: NULL` and large table (> 10K rows)

**Severity:** 🟠 High

---

## Pattern 4: `select *` on Wide Tables / BLOB Columns

**SQL Signature:**

```sql
SELECT * FROM `posts` WHERE ...  -- posts has body TEXT, metadata JSON
```

**ORM Cause:**

```php
// ❌ Loading all columns when only title is needed
Post::where('status', 'published')->get();

// Also bad: loading body TEXT column in list views
```

**Fix:**

```php
// ✅ Select only needed columns
Post::select('id', 'title', 'slug', 'status', 'created_at')
    ->where('status', 'published')
    ->get();

// ✅ Or set $hidden + $appends intelligently on model
class Post extends Model {
    protected $hidden = ['body', 'metadata'];  // Hidden from JSON, still loaded
}
```

**Detection:**

- `SELECT *` on tables with TEXT/BLOB/JSON columns
- High `avg_rows_sent` but page rendering only shows few attributes
- Large data transfer (check `SUM_ROWS_SENT * avg_row_length`)

**Severity:** 🟡 Medium

---

## Pattern 5: OFFSET Pagination vs Cursor Pagination

**SQL Signature:**

```sql
SELECT * FROM `posts` ORDER BY `id` DESC LIMIT 20 OFFSET 100000
```

**ORM Cause:**

```php
// ❌ Standard pagination — slow on high page numbers
Post::paginate(20);   // Uses LIMIT ... OFFSET ...

// Laravel's paginator: page 5000 → OFFSET 100000
```

**Fix:**

```php
// ✅ Cursor pagination (Laravel 8+)
Post::orderBy('id')->cursorPaginate(20);

// ✅ Manual cursor pagination
Post::where('id', '<', $lastSeenId)
    ->orderBy('id', 'desc')
    ->limit(20)
    ->get();
```

**Detection:**

- `LIMIT ? OFFSET ?` with large offset values
- High `avg_rows_examined` vs `avg_rows_sent`
- `type: range` or `type: index` but still high examined rows

**Severity:** 🟡 Medium (worsens with data growth)

---

## Pattern 6: Heavy `whereIn` with Large Arrays

**SQL Signature:**

```sql
SELECT * FROM `users` WHERE `id` IN (?, ?, ?, ?, ... [thousands of placeholders])
```

**ORM Cause:**

```php
// ❌ Passing a huge array to whereIn
$ids = OtherModel::pluck('user_id');  // Could be millions
$users = User::whereIn('id', $ids)->get();
```

**Fix:**

```php
// ✅ Use a database-level join instead
$users = User::whereIn('id', function ($query) {
    $query->select('user_id')
          ->from('other_table')
          ->where('status', 'active');
})->get();

// ✅ Or chunk processing
User::whereIn('id', $ids->chunk(1000))->each(function ($chunkedIds) {
    // Process 1000 at a time
});
```

**Detection:**

- `IN (?,?,?,?...)` with > 50 placeholders
- Query text length > 10KB (many placeholders)

**Severity:** 🟠 High (when > 1000 items)

---

## Pattern 7: Missing `chunk` on Large Collections

**SQL Signature:**

```sql
SELECT * FROM `orders` WHERE `created_at` > ?
```

**ORM Cause:**

```php
// ❌ Loading all orders into memory
Order::where('created_at', '>', $date)->get();  // Could be millions
```

**Fix:**

```php
// ✅ Chunk processing
Order::where('created_at', '>', $date)
     ->chunk(1000, function ($orders) {
        foreach ($orders as $order) {
            // Process in batches
        }
     });

// ✅ Or lazy collections (Laravel 8+)
Order::where('created_at', '>', $date)
     ->lazy()
     ->each(function ($order) {
        // Memory-efficient iteration
     });
```

**Severity:** 🟡 Medium (memory exhaustion risk)

---

## Pattern 8: Missing Composite Index for `orderBy` + `where`

**SQL Signature:**

```sql
SELECT * FROM `products` WHERE `category_id` = ? ORDER BY `price` ASC
```

**ORM Cause:**

```php
// ❌ Single-column index on category_id won't help ORDER BY
Product::where('category_id', 5)->orderBy('price')->get();
```

**Fix:**

```php
// ✅ Migration for composite index
Schema::table('products', function (Blueprint $table) {
    $table->index(['category_id', 'price']);
});
```

```sql
-- SQL equivalent
CREATE INDEX idx_products_category_price ON products (category_id, price);
```

**Detection:**

- `Extra: Using filesort` in EXPLAIN
- WHERE uses one column, ORDER BY uses another — no composite index exists

**Severity:** 🟠 High

---

## Pattern 9: Unnecessary `distinct()` or `groupBy()`

**SQL Signature:**

```sql
SELECT DISTINCT `users`.* FROM `users`
INNER JOIN `orders` ON `users`.`id` = `orders`.`user_id`
```

**ORM Cause:**

```php
// ❌ DISTINCT hides the real problem (cartesian product from JOIN)
$users = User::join('orders', 'users.id', '=', 'orders.user_id')
             ->distinct()
             ->get();
```

**Fix:**

```php
// ✅ Use whereIn or subquery instead
$userIds = Order::distinct()->pluck('user_id');
$users = User::whereIn('id', $userIds)->get();

// ✅ Or use a relation
$users = User::whereHas('orders')->get();
```

**Severity:** 🟡 Medium

---

## Pattern 10: Date Function on Indexed Column

**SQL Signature:**

```sql
SELECT * FROM `posts` WHERE DATE(`created_at`) = ?       -- Can't use index
SELECT * FROM `posts` WHERE YEAR(`created_at`) = ?       -- Can't use index
```

**ORM Cause:**

```php
// ❌ Using whereDate / whereYear (generates DATE() function)
Post::whereDate('created_at', '2024-01-15')->get();
Post::whereYear('created_at', 2024)->get();
```

**Fix:**

```php
// ✅ Range condition (uses index)
Post::where('created_at', '>=', '2024-01-15')
    ->where('created_at', '<', '2024-01-16')
    ->get();

Post::where('created_at', '>=', '2024-01-01')
    ->where('created_at', '<', '2025-01-01')
    ->get();
```

**Detection:**

- `DATE(` or `YEAR(` in fingerprint
- `type: ALL` in EXPLAIN despite index on the column

**Severity:** 🟠 High

---

## Pattern 11: JSON Column Queries Without Generated Columns (MySQL 8.0+)

**SQL Signature:**

```sql
SELECT * FROM `users` WHERE JSON_EXTRACT(`preferences`, '$.theme') = 'dark'
SELECT * FROM `users` WHERE `preferences`->>'$.theme' = 'dark'
```

**ORM Cause:**

```php
// ❌ Querying JSON column directly (no index possible)
User::where('preferences->theme', 'dark')->get();
```

**Fix:**

```php
// ✅ Migration: Add a generated column + index
Schema::table('users', function (Blueprint $table) {
    $table->string('pref_theme')
          ->virtualAs("JSON_UNQUOTE(JSON_EXTRACT(preferences, '$.theme'))");
    $table->index('pref_theme');
});

// Then query the generated column
User::where('pref_theme', 'dark')->get();
```

**Severity:** 🟡 Medium

---

## Laravel Index Checklist

When analyzing a slow query, check:

1. ☐ FK columns indexed (all `belongsTo` / `hasMany` keys)
2. ☐ Composite index for WHERE + ORDER BY
3. ☐ Composite index for WHERE + GROUP BY
4. ☐ Index for `whereHas` / `withCount` subquery column
5. ☐ Index for soft-delete column (`deleted_at`)
6. ☐ Index for polymorphic relations (`commentable_type`, `commentable_id`)
7. ☐ Index for tenant columns in multi-tenant apps
8. ☐ Generated columns for JSON queries
