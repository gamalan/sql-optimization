# GORM Slow Query Patterns

## Pattern Recognition

### Table → Model mapping

- `users` → `User` (PascalCase singular, `models/user.go`)
- `order_items` → `OrderItem`
- `gorm.Model` embedded → includes `ID`, `CreatedAt`, `UpdatedAt`, `DeletedAt`

### Model file detection

```bash
find . -name "*.go" -exec grep -l "gorm\.Model\|gorm:\"column:" {} \;
rg "gorm\.Model" --type go
```

---

## Pattern 1: N+1 — Missing `Preload()`

**SQL Signature (multiple fingerprints):**

```sql
SELECT * FROM `posts` WHERE `posts`.`user_id` = ?
SELECT * FROM `comments` WHERE `comments`.`post_id` = ?
```

**ORM Cause:**

```go
// ❌ N+1: lazy loading not automatic in GORM, but association access triggers queries
var users []User
db.Find(&users)  // 1 query
for _, user := range users {
    db.Model(&user).Association("Posts").Find(&user.Posts)  // N queries!
}
```

**Fix:**

```go
// ✅ Preload: eager loading
var users []User
db.Preload("Posts").Find(&users)

// ✅ Nested Preload
db.Preload("Posts.Comments").Find(&users)

// ✅ Preload with conditions
db.Preload("Posts", "status = ?", "published").Find(&users)

// ✅ Preload with custom query
db.Preload("Posts", func(db *gorm.DB) *gorm.DB {
    return db.Order("posts.created_at DESC").Limit(10)
}).Find(&users)

// ✅ Joins Preload (single query with LEFT JOIN)
db.Preload("Posts", func(db *gorm.DB) *gorm.DB {
    return db.Joins("LEFT JOIN ...")  // Under-the-hood optimization
}).Find(&users)
```

**Detection:**

- `SELECT * FROM posts WHERE posts.user_id = ?` repeated many times
- Association access without prior Preload

**Severity:** 🔴 Critical

---

## Pattern 2: Missing `Select()` — Loading All Columns

**SQL Signature:**

```sql
SELECT * FROM `posts` ...  -- Including TEXT body, JSON metadata
```

**ORM Cause:**

```go
// ❌ Loading all columns
var posts []Post
db.Find(&posts)  // SELECT * FROM posts
```

**Fix:**

```go
// ✅ Select specific columns
var posts []Post
db.Select("id", "title", "created_at").Find(&posts)

// ✅ Or define a dedicated struct for list views
type PostListItem struct {
    ID        uint
    Title     string
    CreatedAt time.Time
}
var items []PostListItem
db.Model(&Post{}).Select("id", "title", "created_at").Find(&items)
```

**Detection:**

- `SELECT *` on tables with large columns
- Only few columns used in response

**Severity:** 🟡 Medium

---

## Pattern 3: OFFSET Pagination

**SQL Signature:**

```sql
SELECT * FROM `posts` ORDER BY `id` DESC LIMIT 20 OFFSET 50000
```

**ORM Cause:**

```go
// ❌ Standard OFFSET pagination
var posts []Post
db.Order("id DESC").Offset(50000).Limit(20).Find(&posts)
```

**Fix:**

```go
// ✅ Cursor pagination
var posts []Post
db.Where("id < ?", cursor).Order("id DESC").Limit(20).Find(&posts)

// ✅ Or use a cursor pagination library
// github.com/pilagod/gorm-cursor-paginator
```

**Detection:**

- `LIMIT ? OFFSET ?` in fingerprint
- Large offset values cause high rows examined

**Severity:** 🟡 Medium

---

## Pattern 4: Missing Index on Filtered Columns

**SQL Signature:**

```sql
SELECT * FROM `orders` WHERE `orders`.`status` = ? AND `orders`.`created_at` > ?
```

**ORM Cause:**

```go
// ❌ No index in model
type Order struct {
    ID        uint      `gorm:"primaryKey"`
    Status    string    `gorm:"type:varchar(20)"`      // No index
    CreatedAt time.Time                                 // No index
}
```

**Fix:**

```go
// ✅ Add indexes via GORM tags
type Order struct {
    ID        uint      `gorm:"primaryKey"`
    Status    string    `gorm:"type:varchar(20);index:idx_orders_status_created,priority:1"`
    CreatedAt time.Time `gorm:"index:idx_orders_status_created,priority:2"`
}

// ✅ Or via AutoMigrate + manual index
db.Set("gorm:table_options", "ENGINE=InnoDB").AutoMigrate(&Order{})

// ✅ Or raw SQL in migration
db.Exec("CREATE INDEX idx_orders_status_created ON orders (status, created_at)")
```

**Severity:** 🟠 High

---

## Pattern 5: Missing `FindInBatches()` for Large Datasets

```go
// ❌ Loading all rows
var orders []Order
db.Where("status = ?", "pending").Find(&orders)
// For 1M orders: memory explosion

// ✅ FindInBatches: process in batches of 100
result := db.Where("status = ?", "pending").FindInBatches(&orders, 100, func(tx *gorm.DB, batch int) error {
    for _, order := range orders {
        process(order)
    }
    // Save progress
    tx.Save(&orders)
    return nil
})

// ✅ Rows() for streaming
rows, _ := db.Model(&Order{}).Where("status = ?", "pending").Rows()
defer rows.Close()
for rows.Next() {
    var order Order
    db.ScanRows(rows, &order)
    process(order)
}
```

**Severity:** 🟠 High (memory)

---

## Pattern 6: Missing `Clauses()` for Complex Queries

```go
// ❌ Composing complex queries without clause building
db.Where("status = ?", "pending")
  .Where("amount > ?", 100)
  .Or("priority = ?", "high")
// Generates: WHERE status = 'pending' AND amount > 100 OR priority = 'high'
// Likely not what you want! Operator precedence issue.

// ✅ Use Clauses for explicit grouping
import "gorm.io/gorm/clause"

db.Where("status = ?", "pending")
  .Where(
    clause.Or(
        clause.Gt{Column: "amount", Value: 100},
        clause.Eq{Column: "priority", Value: "high"},
    ),
  )
// Generates: WHERE status = 'pending' AND (amount > 100 OR priority = 'high')
```

---

## Pattern 7: Missing `RowsAffected` Check After Updates

```go
// ❌ No verification
db.Model(&Order{}).Where("id = ?", id).Update("status", "shipped")
// Did it actually update? Unknown.

// ✅ Check RowsAffected
result := db.Model(&Order{}).Where("id = ?", id).Update("status", "shipped")
if result.RowsAffected == 0 {
    return errors.New("order not found or already shipped")
}
```

---

## Pattern 8: GORM Query Logging for Debugging

```go
import "gorm.io/gorm/logger"

// Development: log slow queries
db, _ := gorm.Open(mysql.Open(dsn), &gorm.Config{
    Logger: logger.New(
        log.New(os.Stdout, "\r\n", log.LstdFlags),
        logger.Config{
            SlowThreshold: 200 * time.Millisecond,  // Log queries > 200ms
            LogLevel:      logger.Warn,              // Warn on slow queries
            Colorful:      true,
        },
    ),
})

// Production: log only errors
db.Logger = logger.Default.LogMode(logger.Error)
```

---

## GORM-Specific Index Checklist

1. ☐ FK columns have `index` tag (GORM doesn't auto-index)
2. ☐ Composite indexes defined via `index:idx_name,priority:N`
3. ☐ `AutoMigrate` creates indexes but doesn't remove old ones — check for stale indexes
4. ☐ Use `db.Debug()` to log SQL during development
5. ☐ `db.Statement.SQL.String()` to inspect generated SQL in tests
6. ☐ Use `gorm.DB` session pooling properly: one `*gorm.DB` instance, reuse
