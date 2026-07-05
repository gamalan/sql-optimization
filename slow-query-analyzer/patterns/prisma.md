# Prisma Client Slow Query Patterns

## Pattern Recognition

### Table → Model mapping

- `User` → `user` table (PascalCase model → lowercase table, auto-mapped or `@@map`)
- `OrderItem` → `order_item` table
- Schema file: `prisma/schema.prisma`

### Model file detection

```bash
find . -name "schema.prisma" -exec grep -l "datasource db" {} \;
rg "model \w+" prisma/schema.prisma
```

---

## Pattern 1: N+1 — Missing `include`

**SQL Signature (multiple fingerprints):**

```sql
SELECT * FROM "Post" WHERE "Post"."authorId" = ?
SELECT * FROM "Comment" WHERE "Comment"."postId" = ?
SELECT * FROM "User" WHERE "User"."id" = ?
```

**ORM Cause:**

```typescript
// ❌ N+1: each post.author triggers a separate query
const posts = await prisma.post.findMany();
for (const post of posts) {
  console.log(post.author.name);  // ❌ relation not loaded!
  // Prisma < 5 silently returns undefined!
  // Prisma 5+ throws if not included
}
```

**Fix:**

```typescript
// ✅ include: eager-load relations
const posts = await prisma.post.findMany({
  include: {
    author: true,           // Load author
    comments: {             // Load comments with their author
      include: { author: true }
    },
  },
});

// ✅ Nested include
const users = await prisma.user.findMany({
  include: {
    posts: {
      include: {
        comments: {
          include: { author: true },
        },
      },
    },
  },
});
```

**Detection:**

- Many `SELECT * FROM "Related" WHERE "Related"."parentId" = ?`
- High COUNT_STAR with low avg_rows
- Queries clustered in time (same request context)

**Severity:** 🔴 Critical

---

## Pattern 2: Missing `select` — Loading All Columns

**SQL Signature:**

```sql
SELECT * FROM "Post" ...  -- Post has content TEXT, metadata JSON
```

**ORM Cause:**

```typescript
// ❌ Loading all columns
const posts = await prisma.post.findMany();
// Returns: { id, title, slug, content, metadata, authorId, createdAt, ... }
// But only id and title are displayed in the list
```

**Fix:**

```typescript
// ✅ select: choose specific columns
const posts = await prisma.post.findMany({
  select: {
    id: true,
    title: true,
    slug: true,
    createdAt: true,
    author: {
      select: { id: true, name: true },  // Nested select!
    },
  },
});

// ✅ Or use include with a separate select for the current model
const posts = await prisma.post.findMany({
  select: {
    id: true,
    title: true,
  },
});
```

**Detection:**

- `SELECT *` in fingerprint on tables with large TEXT/BLOB columns
- Many rows but only few columns used in UI

**Severity:** 🟡 Medium

---

## Pattern 3: Large `where` with `in` on Array

**SQL Signature:**

```sql
SELECT * FROM "User" WHERE "User"."id" IN (?, ?, ?, ... [thousands])
```

**ORM Cause:**

```typescript
// ❌ Passing huge array to 'in' filter
const ids = await prisma.otherModel.findMany({
  select: { userId: true },
});
const userIds = ids.map(i => i.userId);  // Could be millions
const users = await prisma.user.findMany({
  where: { id: { in: userIds } },
});
```

**Fix:**

```typescript
// ✅ Use relational filtering instead
const users = await prisma.user.findMany({
  where: {
    otherModels: {
      some: { status: 'active' },  // Prisma generates subquery
    },
  },
});

// ✅ Or paginate the IN query
const batches = chunk(userIds, 1000);
for (const batch of batches) {
  const users = await prisma.user.findMany({
    where: { id: { in: batch } },
  });
}
```

**Severity:** 🟠 High

---

## Pattern 4: OFFSET Pagination vs Cursor

**SQL Signature:**

```sql
SELECT * FROM "Post" ORDER BY "Post"."id" DESC LIMIT 20 OFFSET 50000
```

**ORM Cause:**

```typescript
// ❌ OFFSET pagination
const posts = await prisma.post.findMany({
  skip: 100000,
  take: 20,
  orderBy: { id: 'desc' },
});
```

**Fix:**

```typescript
// ✅ Cursor-based pagination (Prisma native)
const posts = await prisma.post.findMany({
  take: 20,
  cursor: { id: lastSeenId },
  skip: 1,  // Skip the cursor itself
  orderBy: { id: 'desc' },
});

// ✅ With pagination metadata
const result = await prisma.post.findMany({
  take: 20,
  cursor: cursor ? { id: cursor } : undefined,
  skip: cursor ? 1 : 0,
  orderBy: { id: 'desc' },
});
const nextCursor = result.length === 20 ? result[19].id : null;
```

**Detection:**

- `LIMIT ? OFFSET ?` with large offset
- High rows_examined vs rows_sent

**Severity:** 🟡 Medium

---

## Pattern 5: Unindexed Foreign Keys

**SQL Signature:**

```sql
SELECT * FROM "Post" WHERE "Post"."authorId" = ?
```

**ORM Cause:**

```prisma
// ❌ Missing @@index on FK column
model Post {
  id        Int      @id @default(autoincrement())
  title     String
  authorId  Int
  author    User     @relation(fields: [authorId], references: [id])
  // Missing: @@index([authorId])
}
```

**Fix:**

```prisma
// ✅ Add index on FK in schema.prisma
model Post {
  id        Int      @id @default(autoincrement())
  title     String
  authorId  Int
  author    User     @relation(fields: [authorId], references: [id])

  @@index([authorId])  // Index for WHERE authorId = ?
}

// ✅ Composite index for common queries
model Post {
  // ...
  @@index([authorId, status, createdAt])  // For: where author + filter + sort
}
```

```bash
# After schema change
npx prisma db push   # or npx prisma migrate dev
```

**Severity:** 🟠 High

---

## Pattern 6: Missing `_count` — Separate COUNT Queries

**SQL Signature:**

```sql
SELECT COUNT(*) FROM "Post" WHERE "Post"."authorId" = ?
-- Runs for each author in a list
```

**ORM Cause:**

```typescript
// ❌ Separate count queries for each item
const authors = await prisma.user.findMany();
for (const author of authors) {
  const count = await prisma.post.count({
    where: { authorId: author.id },
  });
  // N+1 COUNT queries!
}
```

**Fix:**

```typescript
// ✅ Include _count in the query
const authors = await prisma.user.findMany({
  include: {
    _count: {
      select: { posts: true },
    },
  },
});
// authors[0]._count.posts → number

// ✅ Or use groupBy
const result = await prisma.post.groupBy({
  by: ['authorId'],
  _count: { id: true },
});
```

**Severity:** 🟡 Medium (frequency × cheap query = adds up)

---

## Pattern 7: Missing `$transaction` — Waterfall Queries

**SQL Signature (sequential, not batched):**

```sql
SELECT * FROM "User" WHERE "id" = ?
SELECT * FROM "Profile" WHERE "userId" = ?
SELECT * FROM "Settings" WHERE "userId" = ?
-- Sequential instead of parallel
```

**ORM Cause:**

```typescript
// ❌ Waterfall: each awaits independently
const user = await prisma.user.findUnique({ where: { id } });
const profile = await prisma.profile.findUnique({ where: { userId: id } });
const settings = await prisma.settings.findUnique({ where: { userId: id } });
// 3 sequential DB roundtrips
```

**Fix:**

```typescript
// ✅ $transaction for parallel reads
const [user, profile, settings] = await prisma.$transaction([
  prisma.user.findUnique({ where: { id } }),
  prisma.profile.findUnique({ where: { userId: id } }),
  prisma.settings.findUnique({ where: { userId: id } }),
]);

// ✅ Or use interactive transactions for read-write
const result = await prisma.$transaction(async (tx) => {
  const user = await tx.user.findUnique({ where: { id } });
  const updated = await tx.user.update({
    where: { id },
    data: { lastLogin: new Date() },
  });
  return updated;
});
```

**Severity:** 🟡 Medium

---

## Pattern 8: Missing Index on `orderBy` Fields

**SQL Signature:**

```sql
SELECT * FROM "Post" ORDER BY "Post"."createdAt" DESC LIMIT 20
-- No index on createdAt → filesort
```

**ORM Cause:**

```prisma
// ❌ No index on frequently sorted column
model Post {
  id        Int      @id
  title     String
  createdAt DateTime @default(now())
  // Missing index
}
```

**Fix:**

```prisma
// ✅ Add index for sort-heavy queries
model Post {
  id        Int      @id
  title     String
  createdAt DateTime @default(now())

  @@index([createdAt(sort: Desc)])  // Index for ORDER BY createdAt DESC
}

// ✅ Composite: WHERE status = ? ORDER BY createdAt
model Post {
  // ...
  @@index([status, createdAt(sort: Desc)])
}
```

**Severity:** 🟡 Medium

---

## Pattern 9: `findMany` Without `take` on Large Tables

```typescript
// ❌ Loading millions of rows
const allPosts = await prisma.post.findMany();  // Everything in memory!

// ❌ Even with where — could still be millions
const pendingOrders = await prisma.order.findMany({
  where: { status: 'pending' },
});

// ✅ Always paginate or limit
const recentPosts = await prisma.post.findMany({
  where: { status: 'published' },
  take: 100,
  orderBy: { createdAt: 'desc' },
});
```

**Severity:** 🔴 Critical (memory exhaustion)

---

## Pattern 10: Logging Configuration for Debugging

```typescript
// Enable query logging in development
const prisma = new PrismaClient({
  log: [
    { level: 'query', emit: 'event' },
    { level: 'warn', emit: 'stdout' },
  ],
});

// Slow query detection
prisma.$on('query', (e) => {
  if (e.duration > 500) {
    console.warn(`SLOW QUERY (${e.duration}ms):`, e.query, e.params);
  }
});

// Or use prisma.$use middleware
prisma.$use(async (params, next) => {
  const before = Date.now();
  const result = await next(params);
  const after = Date.now();
  if (after - before > 500) {
    console.warn(`Slow query [${after - before}ms]: ${params.model}.${params.action}`);
  }
  return result;
});
```

---

## Prisma-Specific Index Checklist

1. ☐ `@@index` on all FK columns (Prisma doesn't auto-index FKs)
2. ☐ `@@index` on `orderBy` columns
3. ☐ `@@index` on composite WHERE conditions
4. ☐ `@@unique` for uniqueness constraints (creates index automatically)
5. ☐ Check `npx prisma db pull` to see current DB indexes
6. ☐ Use `npx prisma studio` to visually inspect data relationships
7. ☐ Enable `relationLoadStrategy: "query"` (default) or `"join"` based on needs
