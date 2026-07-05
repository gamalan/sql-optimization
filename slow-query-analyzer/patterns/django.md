# Django ORM Slow Query Patterns

## Pattern Recognition

### Table → Model mapping

- `auth_user` → `User` (in `django.contrib.auth.models` or custom user model)
- `appname_modelname` → `ModelName` (Django auto-names: `<app>_<model>`)
- `app_label` → folder name under project root

### Model file detection

```bash
find . -name "models.py" -exec grep -l "class.*models.Model" {} \;
rg "class \w+\(models.Model\)" --type python
```

---

## Pattern 1: N+1 — Missing `select_related()` / `prefetch_related()`

**SQL Signature (multiple fingerprints, same shape):**

```sql
SELECT * FROM `app_post` WHERE `app_post`.`author_id` = ?
SELECT * FROM `app_comment` WHERE `app_comment`.`post_id` = ?
SELECT * FROM `auth_user` WHERE `auth_user`.`id` = ?
```

**ORM Cause:**

```python
# ❌ N+1: each post.author hits the DB
posts = Post.objects.all()
for post in posts:
    print(post.author.name)       # 1 query per post!
    for comment in post.comments.all():  # N queries per post!
        print(comment.body)
```

**Fix:**

```python
# ✅ select_related for FK / OneToOne (JOIN)
posts = Post.objects.select_related('author').all()

# ✅ prefetch_related for reverse FK / M2M (separate query + Python join)
posts = Post.objects.prefetch_related('comments').all()

# ✅ Both together
posts = Post.objects.select_related('author') \
                    .prefetch_related('comments', 'tags') \
                    .all()

# ✅ Prefetch with filtering (Prefetch object)
from django.db.models import Prefetch
posts = Post.objects.prefetch_related(
    Prefetch('comments', queryset=Comment.objects.filter(approved=True))
).all()
```

**Detection:**

- `SELECT * FROM auth_user WHERE id = ?` runs thousands of times
- High `COUNT_STAR` with low `avg_rows_sent` (usually 1)
- Multiple similar fingerprints clustered in time

**Severity:** 🔴 Critical

---

## Pattern 2: `values()` / `values_list()` Missing — Loading Full Objects

**SQL Signature:**

```sql
SELECT * FROM `app_post` WHERE `status` = ?
-- but only 'id' and 'title' are rendered in template
```

**ORM Cause:**

```python
# ❌ Full model instantiation for just id/title
posts = Post.objects.filter(status='published')
# Hydrates 50 columns × 10000 rows into Model instances
```

**Fix:**

```python
# ✅ values_list: returns tuples (fast, no model overhead)
ids_and_titles = Post.objects.filter(status='published') \
    .values_list('id', 'title')

# ✅ values: returns dicts
posts_dict = Post.objects.filter(status='published') \
    .values('id', 'title', 'created_at')

# ✅ only/defer: still returns model instances but lazy-loads
posts = Post.objects.filter(status='published') \
    .only('id', 'title')  # Load only these columns; others lazy
```

**Detection:**

- `SELECT *` on wide tables (many columns or TEXT/BLOB)
- `avg_rows_sent` large but HTML template only shows 2-3 fields

**Severity:** 🟡 Medium

---

## Pattern 3: Missing `iterator()` for Large Querysets

**SQL Signature:**

```sql
SELECT * FROM `app_eventlog` WHERE `created_at` > ?
-- millions of rows loaded into memory
```

**ORM Cause:**

```python
# ❌ Caches all rows in QuerySet._result_cache
for event in EventLog.objects.filter(created_at__gte=start_date):
    process(event)  # Memory explodes with millions of rows
```

**Fix:**

```python
# ✅ iterator(): server-side cursor, no caching
for event in EventLog.objects.filter(created_at__gte=start_date) \
    .iterator(chunk_size=2000):
    process(event)

# ✅ Or chunked processing
from django.core.paginator import Paginator
qs = EventLog.objects.filter(created_at__gte=start_date).order_by('id')
paginator = Paginator(qs, 2000)
for page_num in paginator.page_range:
    for event in paginator.page(page_num):
        process(event)
```

**Detection:**

- `SELECT` with no `LIMIT` on large tables
- High memory usage in app during query execution
- Table > 100K rows in stats

**Severity:** 🟠 High (memory risk)

---

## Pattern 4: `annotate()` + `distinct()` Mismatch

**SQL Signature:**

```sql
SELECT DISTINCT `app_post`.*, COUNT(`app_comment`.`id`) AS `comment_count`
FROM `app_post`
LEFT JOIN `app_comment` ON (`app_post`.`id` = `app_comment`.`post_id`)
GROUP BY `app_post`.`id`
```

**ORM Cause:**

```python
# ❌ Annotate + distinct often breaks when JOINs create duplicate rows
from django.db.models import Count
Post.objects.annotate(comment_count=Count('comments')).distinct()
```

**Fix:**

```python
# ✅ Use Subquery for complex annotations (Django 2.0+)
from django.db.models import OuterRef, Subquery, Count
posts = Post.objects.annotate(
    comment_count=Subquery(
        Comment.objects.filter(post_id=OuterRef('id'))
            .values('post_id')
            .annotate(count=Count('id'))
            .values('count')
    )
)
```

**Severity:** 🟡 Medium

---

## Pattern 5: OFFSET Pagination

**SQL Signature:**

```sql
SELECT * FROM `app_post` ORDER BY `id` DESC LIMIT 20 OFFSET 50000
```

**ORM Cause:**

```python
# ❌ Django's built-in pagination (OFFSET-based)
from django.core.paginator import Paginator
page = Paginator(Post.objects.all(), 20).page(2500)  # OFFSET 50000
```

**Fix:**

```python
# ✅ Keyset/cursor pagination (Django 3.2+ via third-party or manual)
# Using django-cursor-pagination or manual:
from django.db.models import Q

class PostPagination:
    def __init__(self, queryset, page_size=20):
        self.queryset = queryset.order_by('-id')
        self.page_size = page_size

    def page(self, cursor=None):
        qs = self.queryset
        if cursor:
            qs = qs.filter(id__lt=cursor)
        results = list(qs[:self.page_size + 1])
        has_next = len(results) > self.page_size
        next_cursor = results[-2].id if has_next else None
        return results[:self.page_size], next_cursor

# Or use: pip install django-keyset-pagination-plus
```

**Detection:**

- `LIMIT ? OFFSET ?` in fingerprint
- High `OFFSET` values
- `avg_rows_examined` much higher than `avg_rows_sent`

**Severity:** 🟡 Medium

---

## Pattern 6: `filter()` on Unindexed Fields

**SQL Signature:**

```sql
SELECT * FROM `app_order` WHERE `app_order`.`status` = ? AND `app_order`.`created_at` > ?
```

**ORM Cause:**

```python
# ❌ Querying on unindexed column combination
orders = Order.objects.filter(
    status='pending',
    created_at__gte=start_date
)
```

**Fix:**

```python
# ✅ Add index via migration
# migrations/000X_add_order_status_date_index.py
from django.db import migrations, models

class Migration(migrations.Migration):
    operations = [
        migrations.AddIndex(
            model_name='order',
            index=models.Index(
                fields=['status', '-created_at'],
                name='idx_order_status_date'
            ),
        ),
    ]
```

```sql
-- SQL equivalent
CREATE INDEX idx_order_status_date ON app_order (status, created_at DESC);
```

**Detection:**

- `type: ALL` in EXPLAIN
- `SUM_NO_INDEX_USED > 0` in Performance Schema

**Severity:** 🟠 High

---

## Pattern 7: `__in` on Large Lists

**SQL Signature:**

```sql
SELECT * FROM `app_user` WHERE `app_user`.`id` IN (?, ?, ?, ... [thousands])
```

**ORM Cause:**

```python
# ❌ Passing huge queryset to __in
user_ids = SomeModel.objects.values_list('user_id', flat=True)  # Millions
users = User.objects.filter(id__in=user_ids)  # Very large IN clause
```

**Fix:**

```python
# ✅ Use Exists subquery
from django.db.models import Exists, OuterRef
users = User.objects.filter(
    Exists(
        SomeModel.objects.filter(user_id=OuterRef('id'))
    )
)

# ✅ Or chunk the IN query
from itertools import islice
def chunks(iterable, size):
    iterator = iter(iterable)
    return iter(lambda: list(islice(iterator, size)), [])

for id_chunk in chunks(user_ids, 1000):
    for user in User.objects.filter(id__in=id_chunk):
        process(user)
```

**Severity:** 🟠 High

---

## Pattern 8: Date Function on Column

**SQL Signature:**

```sql
SELECT * FROM `app_post` WHERE DATE(`app_post`.`created_at`) = '2024-01-15'
```

**ORM Cause:**

```python
# ❌ __date lookup generates DATE() wrapper (can't use index)
posts = Post.objects.filter(created_at__date='2024-01-15')
# ❌ __year, __month, __day all generate function calls
posts = Post.objects.filter(created_at__year=2024)
```

**Fix:**

```python
# ✅ Range lookup (uses index)
from datetime import datetime, timedelta
start = datetime(2024, 1, 15)
end = start + timedelta(days=1)
posts = Post.objects.filter(created_at__gte=start, created_at__lt=end)

# ✅ For month/year: use custom range query
from calendar import monthrange
year, month = 2024, 1
_, last_day = monthrange(year, month)
posts = Post.objects.filter(
    created_at__gte=datetime(year, month, 1),
    created_at__lt=datetime(year, month + 1, 1) if month < 12
                  else datetime(year + 1, 1, 1)
)
```

**Severity:** 🟠 High

---

## Pattern 9: Missing `select_for_update()` Causing Race Conditions

Not a slow query per se, but causes lock contention:

```python
# ❌ Read → check → write (race condition + extra query)
product = Product.objects.get(id=product_id)
if product.stock > 0:
    product.stock -= 1
    product.save()  # Might overwrite another transaction's update

# ✅ Atomic with select_for_update
from django.db import transaction
with transaction.atomic():
    product = Product.objects.select_for_update().get(id=product_id)
    if product.stock > 0:
        product.stock -= 1
        product.save()
```

---

## Pattern 10: Missing `bulk_create()` / `bulk_update()`

**SQL Signature (many individual INSERTs):**

```sql
INSERT INTO `app_event` (...) VALUES (...)
INSERT INTO `app_event` (...) VALUES (...)
INSERT INTO `app_event` (...) VALUES (...)
-- ... hundreds of individual INSERTs
```

**ORM Cause:**

```python
# ❌ Individual saves in a loop
for data in batch:
    Event.objects.create(**data)  # 1 INSERT per iteration
```

**Fix:**

```python
# ✅ bulk_create
events = [Event(**data) for data in batch]
Event.objects.bulk_create(events, batch_size=1000)

# ✅ bulk_update (Django 2.2+)
Event.objects.bulk_update(events_to_update, ['status', 'processed_at'])
```

**Severity:** 🟡 Medium

---

## Django ORM Index Checklist

1. ☐ FK columns (Django auto-indexes these ✓, but check migration state)
2. ☐ `unique_together` → composite unique index
3. ☐ `index_together` → composite index (deprecated in 4.2, use `indexes`)
4. ☐ `Meta.indexes` — check for all WHERE + ORDER BY combos
5. ☐ Soft deletes: if using `is_deleted` field, index `['is_deleted', 'created_at']`
6. ☐ Date fields used in range queries: index `['-created_at']`
7. ☐ JSON fields: use `GeneratedField` (Django 5.0+) or `Func` expression indexes
8. ☐ Use `django-debug-toolbar` in dev to detect N+1 and query count
9. ☐ Use `nplusone` package to detect N+1 automatically
