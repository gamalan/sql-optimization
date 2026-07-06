# SQLAlchemy ORM Slow Query Patterns

## Pattern Recognition

### Table → Model mapping

- `users` → `User` (PascalCase singular, `models/user.py` or `models.py`)
- `order_items` → `OrderItem`
- `__tablename__ = 'users'` in model definition

### Model file detection

```bash
find . -name "*.py" -exec grep -l "declarative_base\|Base = declarative_base\|class.*(Base)" {} \;
rg "class \w+\(Base\)" --type python
```

---

## Pattern 1: N+1 — Missing `joinedload()` / `selectinload()`

**SQL Signature (multiple fingerprints):**

```sql
SELECT * FROM users WHERE users.id = ?
SELECT * FROM posts WHERE posts.user_id = ?
SELECT * FROM comments WHERE comments.post_id = ?
```

**ORM Cause:**

```python
# ❌ N+1: lazy loading on each access
users = session.query(User).all()
# or: users = session.execute(select(User)).scalars().all()
for user in users:
    print(user.posts)  # 1 query per user!
```

**Fix:**

```python
from sqlalchemy.orm import joinedload, selectinload, subqueryload

# ✅ joinedload: LEFT OUTER JOIN — good for one-to-one, small one-to-many
users = session.query(User).options(joinedload(User.posts)).all()
# or 2.0 style:
users = session.execute(
    select(User).options(joinedload(User.posts))
).unique().scalars().all()

# ✅ selectinload: separate IN query — best for large collections (most cases)
users = session.execute(
    select(User).options(selectinload(User.posts).selectinload(Post.comments))
).unique().scalars().all()

# ✅ subqueryload: subquery approach (legacy, prefer selectinload)

# ✅ For complex filtering on the loaded relation
from sqlalchemy.orm import contains_eager
users = session.execute(
    select(User)
    .join(User.posts)
    .where(Post.status == 'published')
    .options(contains_eager(User.posts))
).unique().scalars().all()
```

**Detection:**

- Many `SELECT ... FROM posts WHERE posts.user_id = ?`
- Each returns 1-few rows, high frequency
- `lazy='select'` or `lazy=True` on relationship (the default!)

**Severity:** 🔴 Critical

---

## Pattern 2: Default Lazy Loading (Change Relationship Default)

**ORM Cause:**

```python
# ❌ Default: lazy='select' — every access hits DB
class User(Base):
    __tablename__ = 'users'
    id = Column(Integer, primary_key=True)
    posts = relationship("Post", back_populates="user")  # lazy='select' by default!
```

**Fix:**

```python
# ✅ Change default loading strategy per relationship
class User(Base):
    __tablename__ = 'users'
    id = Column(Integer, primary_key=True)
    posts = relationship("Post", lazy='selectin')  # Always use selectinload

# ✅ Or per-query override still works
users = session.execute(
    select(User).options(joinedload(User.posts))  # Overrides lazy='selectin'
).scalars().all()

# ✅ lazy='raise' (SQLAlchemy 1.4+) — raises error on lazy load (best for dev)
class User(Base):
    posts = relationship("Post", lazy='raise')
# Now accessing user.posts without eager loading raises InvalidRequestError
```

**Severity:** 🟠 High (architectural — affects every access)

---

## Pattern 3: `noload()` or `raiseload()` for Query Safety

```python
from sqlalchemy.orm import noload, raiseload

# ✅ raiseload: error if unloaded relation is accessed (dev safety net)
users = session.execute(
    select(User).options(raiseload('*'))  # Raidaload all relations
).scalars().all()

# ✅ Column-only query skips relationship loading entirely
users = session.execute(
    select(User.id, User.name, User.email)
).all()  # Returns Row tuples, not User objects
```

---

## Pattern 4: OFFSET Pagination

**SQL Signature:**

```sql
SELECT * FROM posts ORDER BY posts.id DESC LIMIT 20 OFFSET 50000
```

**ORM Cause:**

```python
# ❌ Standard OFFSET pagination
page = 2500
page_size = 20
posts = session.execute(
    select(Post)
    .order_by(Post.id.desc())
    .offset(page * page_size)
    .limit(page_size)
).scalars().all()
```

**Fix:**

```python
# ✅ Keyset pagination (cursor-based)
def get_posts(cursor=None, limit=20):
    stmt = select(Post).order_by(Post.id.desc()).limit(limit)
    if cursor:
        stmt = stmt.where(Post.id < cursor)
    return session.execute(stmt).scalars().all()

# ✅ SQLAlchemy 2.0 window function approach
from sqlalchemy import func
# Or use sqlakeyset library: pip install sqlakeyset
```

**Detection:**

- `LIMIT ? OFFSET ?` with large offset
- High `avg_rows_examined`

**Severity:** 🟡 Medium

---

## Pattern 5: Missing Index on Filter Columns

**SQL Signature:**

```sql
SELECT * FROM orders WHERE orders.status = ? AND orders.created_at > ?
```

**ORM Cause:**

```python
# ❌ No index in model definition
class Order(Base):
    __tablename__ = 'orders'
    id = Column(Integer, primary_key=True)
    status = Column(String(20))        # No Index
    created_at = Column(DateTime)      # No Index

# Query without index
orders = session.execute(
    select(Order).where(
        Order.status == 'pending',
        Order.created_at >= start_date
    )
).scalars().all()
```

**Fix:**

```python
# ✅ Define indexes in model
from sqlalchemy import Index

class Order(Base):
    __tablename__ = 'orders'
    __table_args__ = (
        Index('idx_orders_status_created', 'status', 'created_at'),
    )
    id = Column(Integer, primary_key=True)
    status = Column(String(20), index=True)  # Single column index
    created_at = Column(DateTime)

# ✅ Or via Alembic migration
# alembic revision --autogenerate -m "add orders index"
```

**Severity:** 🟠 High

---

## Pattern 6: Loading Full Objects When Only Columns Needed

**SQL Signature:**

```sql
SELECT * FROM posts WHERE posts.status = 'published'
-- But only id and title are needed
```

**ORM Cause:**

```python
# ❌ Full ORM loading
for post in session.execute(select(Post)).scalars():
    print(post.id, post.title)  # Only 2 columns used
```

**Fix:**

```python
# ✅ Column selection
stmt = select(Post.id, Post.title, Post.slug).where(Post.status == 'published')
for row in session.execute(stmt):
    print(row.id, row.title)  # Row tuples, no ORM overhead

# ✅ Or with_entities (legacy)
for row in session.query(Post.id, Post.title).filter(Post.status == 'published'):
    print(row.id, row.title)

# ✅ defer() — load model but defer expensive columns
posts = session.execute(
    select(Post).options(defer(Post.body), defer(Post.metadata_json))
).scalars().all()
# body and metadata_json only loaded if explicitly accessed
```

**Detection:**

- `SELECT *` on wide tables
- Only 2-3 columns used in downstream processing

**Severity:** 🟡 Medium

---

## Pattern 7: Missing `yield_per()` for Large Results

**SQL Signature:**

```sql
SELECT * FROM event_log WHERE event_log.created_at > ?
-- Millions of rows, all loaded into session identity map
```

**ORM Cause:**

```python
# ❌ All rows cached in session
events = session.execute(select(EventLog)).scalars().all()
for event in events:
    process(event)  # Memory: millions of objects
```

**Fix:**

```python
# ✅ yield_per: stream results in chunks (SQLAlchemy 1.4+)
for event in session.execute(
    select(EventLog)
    .where(EventLog.created_at >= start_date)
    .execution_options(yield_per=1000, stream_results=True)
).scalars():
    process(event)
    session.expunge(event)  # Remove from session to free memory

# ✅ Or use partitions (window function)
from sqlalchemy import func, text
# See: SQLAlchemy "Using the Session" docs for windowed range queries
```

**Detection:**

- No LIMIT on large tables
- High memory usage in process

**Severity:** 🟠 High

---

## Pattern 8: Missing `bulk_insert_mappings` / `bulk_update_mappings`

**SQL Signature:**

```sql
INSERT INTO events (...) VALUES (...)
INSERT INTO events (...) VALUES (...)
-- Hundreds of individual INSERTs
```

**ORM Cause:**

```python
# ❌ Individual inserts
for data in batch:
    session.add(EventLog(**data))
    session.flush()  # Individual INSERT + roundtrip
session.commit()     # But still executed one at a time during flush
```

**Fix:**

```python
# ✅ Bulk operations (SQLAlchemy 1.0+)
session.bulk_insert_mappings(EventLog, batch_data)  # Fast, no ORM events
session.commit()

# ✅ SQLAlchemy 2.0+ insertmanyvalues (auto-batched, with ORM events)
session.add_all([EventLog(**data) for data in batch_data])
session.commit()  # 2.0 uses executemany under the hood

# ✅ Bulk update
session.bulk_update_mappings(
    EventLog,
    [{'id': 1, 'status': 'processed'}, {'id': 2, 'status': 'processed'}]
)

# ✅ Core-level insert (fastest, no ORM)
from sqlalchemy import insert
stmt = insert(EventLog).values(batch_data)
session.execute(stmt)
session.commit()
```

**Severity:** 🟡 Medium

---

## Pattern 9: Session Management Issues

```python
# ❌ Session per request (Flask-SQLAlchemy default) — fine for most cases
# ❌ But: long-lived session accumulates dirty objects

# ❌ Global session = all queries share identity map, memory leak
session = Session()  # Global! Grows forever

# ✅ Scoped session (thread-local, Flask-SQLAlchemy default)
from sqlalchemy.orm import scoped_session, sessionmaker
session_factory = sessionmaker(bind=engine)
Session = scoped_session(session_factory)

# ✅ Context manager for every unit of work
with Session() as session:
    user = session.get(User, user_id)
    user.last_seen = datetime.utcnow()
    session.commit()
# Session auto-closed, memory freed

# ✅ session.rollback() on exceptions
with Session() as session:
    try:
        session.add(new_user)
        session.commit()
    except Exception:
        session.rollback()
        raise
```

---

## Pattern 10: `expire_on_commit=False` for Read-Heavy

```python
# Default: after commit, all objects are expired
# Next access → SELECT to refresh (extra queries!)

# ❌ N+1 after commit pattern:
with Session() as session:
    user = session.get(User, 1)
    session.commit()  # user is now expired
    print(user.name)  # SELECT FROM users WHERE id = 1 (extra query!)

# ✅ Disable expiration for read-heavy web requests
session = Session(expire_on_commit=False)

# ✅ Or refresh only what's needed:
user = session.get(User, 1, options=[joinedload(User.posts)])
session.commit()  # user and user.posts still valid
```

---

## SQLAlchemy-Specific Index Checklist

1. ☐ FK columns indexed (SQLAlchemy doesn't auto-index FKs)
2. ☐ `Index('idx_name', 'col1', 'col2')` in `__table_args__`
3. ☐ `index=True` on frequently filtered columns
4. ☐ Use Alembic for migration management
5. ☐ `echo=True` on engine for query logging in development
6. ☐ Use `sqlalchemy.ext.automap` or `sqlacodegen` to reflect existing DB
