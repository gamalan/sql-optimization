# Entity Framework Core Slow Query Patterns

## Pattern Recognition

### Table → Model mapping

- `Users` → `User` (DbSet<User> in DbContext)
- `OrderItems` → `OrderItem`
- Can be customized via `[Table("table_name")]` or `modelBuilder.ToTable()`

### Context file detection

```bash
find . -name "*.cs" -exec grep -l "DbContext\|: DbContext" {} \;
rg "class \w+ : DbContext" --type csharp
```

---

## Pattern 1: N+1 — Missing `.Include()` / `.ThenInclude()`

**SQL Signature (multiple fingerprints):**

```sql
SELECT * FROM [Posts] WHERE [Posts].[UserId] = ?
SELECT * FROM [Comments] WHERE [Comments].[PostId] = ?
```

**ORM Cause:**

```csharp
// ❌ N+1: lazy loading (if enabled) or explicit Load()
var users = await context.Users.ToListAsync();
foreach (var user in users) {
    Console.WriteLine(user.Posts.Count);  // 1 query per user if lazy loading ON
    // or: await context.Entry(user).Collection(u => u.Posts).LoadAsync();
}
```

**Fix:**

```csharp
// ✅ Include: eager loading
var users = await context.Users
    .Include(u => u.Posts)
    .ToListAsync();

// ✅ ThenInclude: nested relations
var users = await context.Users
    .Include(u => u.Posts)
        .ThenInclude(p => p.Comments)
            .ThenInclude(c => c.Author)
    .ToListAsync();

// ✅ Include with filter (EF Core 5.0+)
var users = await context.Users
    .Include(u => u.Posts.Where(p => p.Status == "published"))
    .ToListAsync();

// ✅ Split query: avoid cartesian explosion (EF Core 5.0+)
var users = await context.Users
    .Include(u => u.Posts)
        .ThenInclude(p => p.Comments)
    .AsSplitQuery()  // Multiple queries instead of one giant JOIN
    .ToListAsync();

// ❌ Disable lazy loading entirely (recommended)
// In DbContext:
// ChangeTracker.LazyLoadingEnabled = false;
```

**Detection:**

- Many `SELECT ... FROM Posts WHERE UserId = ?`
- Lazy loading proxies enabled + missing `.Include()`
- `AsSplitQuery()` NOT used on wide JOINs

**Severity:** 🔴 Critical

---

## Pattern 2: Cartographic Explosion from Multiple Includes

**SQL Signature:**

```sql
SELECT [u].*, [p].*, [c].*, [t].*
FROM [Users] AS [u]
LEFT JOIN [Posts] AS [p] ON [u].[Id] = [p].[UserId]
LEFT JOIN [Comments] AS [c] ON [p].[Id] = [c].[PostId]
LEFT JOIN [Tags] AS [t] ON [p].[Id] = [t].[PostId]
-- Result set: rows = users × posts × comments × tags (explosion!)
```

**ORM Cause:**

```csharp
// ❌ Single query with many JOINs = cartesian product
var users = await context.Users
    .Include(u => u.Posts)
        .ThenInclude(p => p.Comments)
    .Include(u => u.Posts)
        .ThenInclude(p => p.Tags)
    .ToListAsync();  // Huge result set, client-side dedup in memory
```

**Fix:**

```csharp
// ✅ AsSplitQuery: separate query per collection (EF Core 5.0+)
var users = await context.Users
    .Include(u => u.Posts)
        .ThenInclude(p => p.Comments)
    .Include(u => u.Posts)
        .ThenInclude(p => p.Tags)
    .AsSplitQuery()
    .ToListAsync();

// ✅ Or configure globally (EF Core 7+):
// optionsBuilder.UseSqlServer(connStr, o => o.UseQuerySplittingBehavior(QuerySplittingBehavior.SplitQuery));
```

**Detection:**

- Multiple LEFT JOINs in single query
- Huge rows_examined (cartesian product)
- Large data transfer (all JOIN columns × all rows)

**Severity:** 🔴 Critical

---

## Pattern 3: Client-Side Evaluation / Missing `.Select()`

**ORM Cause:**

```csharp
// ❌ Client evaluation: EF fetches ALL rows then filters in memory
var activeUsers = context.Users
    .ToList()  // FETCHES EVERYTHING
    .Where(u => SomeComplexCSharpMethod(u) == true)  // C# function, not SQL
    .ToList();

// ❌ No .Select() = loads all columns
var names = context.Users
    .ToList()  // SELECT * FROM Users
    .Select(u => u.Name);  // Done in memory
```

**Fix:**

```csharp
// ✅ .Select() BEFORE .ToList() — SQL-side evaluation
var names = context.Users
    .Where(u => u.IsActive)
    .Select(u => u.Name)  // SELECT Name FROM Users WHERE IsActive = 1
    .ToListAsync();

// ✅ Projection (select specific columns)
var summaries = context.Users
    .Select(u => new {
        u.Id,
        u.Name,
        PostCount = u.Posts.Count
    })
    .ToListAsync();
```

**Detection:**

- `.ToList()` called before `.Where()` or `.Select()`
- `SELECT *` when only few columns needed
- Warning CS8625 or EF Core client evaluation warning

**Severity:** 🟠 High

---

## Pattern 4: `AsNoTracking()` Missing for Read-Only Queries

**ORM Cause:**

```csharp
// ❌ All entities tracked by ChangeTracker → memory overhead + slower
var users = context.Users
    .Include(u => u.Posts)
    .ToList();  // Every entity tracked!
```

**Fix:**

```csharp
// ✅ AsNoTracking: no change tracking overhead (read-only queries)
var users = context.Users
    .AsNoTracking()
    .Include(u => u.Posts)
    .ToListAsync();

// ✅ Or set globally for read-only contexts
// In DbContext constructor:
// ChangeTracker.QueryTrackingBehavior = QueryTrackingBehavior.NoTracking;
```

**Detection:**

- Read queries without `.AsNoTracking()`
- ChangeTracker entries growing unbounded
- Memory pressure in read-heavy endpoints

**Severity:** 🟡 Medium (memory + speed)

---

## Pattern 5: OFFSET Pagination

```csharp
// ❌ Standard OFFSET — slow on high page numbers
var posts = await context.Posts
    .OrderByDescending(p => p.Id)
    .Skip(50000)
    .Take(20)
    .ToListAsync();

// ✅ Keyset pagination
var posts = await context.Posts
    .Where(p => p.Id < lastSeenId)
    .OrderByDescending(p => p.Id)
    .Take(20)
    .ToListAsync();
```

**Severity:** 🟡 Medium

---

## Pattern 6: Missing Indexes

```csharp
// ❌ No index defined in model
public class Order {
    public int Id { get; set; }
    public string Status { get; set; }
    public DateTime CreatedAt { get; set; }
}

// ✅ Index via data annotation
[Index(nameof(Status), nameof(CreatedAt))]
public class Order { ... }

// ✅ Or via Fluent API in OnModelCreating
protected override void OnModelCreating(ModelBuilder modelBuilder) {
    modelBuilder.Entity<Order>()
        .HasIndex(o => new { o.Status, o.CreatedAt })
        .HasDatabaseName("IX_Orders_Status_CreatedAt");
}

// ✅ Generate migration:
// dotnet ef migrations add AddOrderIndexes
// dotnet ef database update
```

**Severity:** 🟠 High

---

## Pattern 7: `Count()` Instead of `Any()` for Existence Checks

```csharp
// ❌ COUNT(*) is slower than EXISTS
if (await context.Orders.CountAsync(o => o.UserId == userId) > 0) { }

// ✅ Any() generates EXISTS (much faster)
if (await context.Orders.AnyAsync(o => o.UserId == userId)) { }
```

---

## Pattern 8: Missing `ExecuteUpdate` / `ExecuteDelete` (EF Core 7+)

```csharp
// ❌ Load then delete (SELECT + DELETE per entity)
var oldLogs = await context.Logs
    .Where(l => l.CreatedAt < cutoff)
    .ToListAsync();         // SELECT * INTO MEMORY
context.Logs.RemoveRange(oldLogs);  // DELETE per entity
await context.SaveChangesAsync();

// ✅ ExecuteDelete: single SQL statement, no loading
await context.Logs
    .Where(l => l.CreatedAt < cutoff)
    .ExecuteDeleteAsync();  // DELETE FROM Logs WHERE CreatedAt < @cutoff

// ✅ ExecuteUpdate: bulk update without loading
await context.Orders
    .Where(o => o.Status == "pending" && o.CreatedAt < cutoff)
    .ExecuteUpdateAsync(
        s => s.SetProperty(o => o.Status, "expired")
              .SetProperty(o => o.ExpiredAt, DateTime.UtcNow)
    );
```

**Severity:** 🟠 High (when processing many rows)

---

## Pattern 9: EF Core Query Logging for Slow Query Detection

```csharp
// In development: log slow queries
optionsBuilder
    .UseSqlServer(connectionString)
    .LogTo(Console.WriteLine, LogLevel.Information)
    .EnableSensitiveDataLogging()  // Log parameter values (DEV ONLY)
    .EnableDetailedErrors();

// Tag queries for identification in logs
var users = await context.Users
    .TagWith("Controller:UserController, Action:Index")
    .TagWith("Source:WebApp")
    .ToListAsync();
// SQL: -- Controller:UserController, Action:Index
// SQL: -- Source:WebApp
// SQL: SELECT * FROM Users
```

---

## EF Core-Specific Index Checklist

1. ☐ FK columns: EF Core indexes FK shadow properties, but check model config
2. ☐ Composite indexes via `[Index(nameof(Col1), nameof(Col2))]` or Fluent API
3. ☐ `AsNoTracking()` on all read-only queries
4. ☐ `AsSplitQuery()` when including multiple collections
5. ☐ `ExecuteUpdate` / `ExecuteDelete` (EF Core 7+) for bulk operations
6. ☐ `TagWith()` for query attribution in logs and SQL Profiler
