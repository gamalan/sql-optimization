# Lesson 3: Obfuscated Conditions

**Source:** [use-the-index-luke.com/sql/where-clause/obfuscation](https://use-the-index-luke.com/sql/where-clause/obfuscation)

---

## Summary

Developers often write WHERE clauses that look correct but prevent index
usage because the condition is "obfuscated" — wrapped in functions, type
conversions, math, or "smart" logic that the optimizer can't unravel.
These are the most common indexing anti-patterns.

---

## Lesson 3.1: Date Conditions

The most common obfuscation: using `DATE()`, `YEAR()`, `MONTH()`,
`EXTRACT()`, or `TO_CHAR()` on indexed date columns.

```sql
-- ✗ Function on column: NO INDEX
SELECT * FROM orders WHERE DATE(created_at) = '2024-01-15';
SELECT * FROM orders WHERE YEAR(created_at) = 2024;
SELECT * FROM orders WHERE MONTH(created_at) = 1;

-- ✓ Range condition: INDEX WORKS
SELECT * FROM orders
WHERE created_at >= '2024-01-15'
  AND created_at <  '2024-01-16';

SELECT * FROM orders
WHERE created_at >= '2024-01-01'
  AND created_at <  '2025-01-01';
```

### Framework-Specific Date Anti-Patterns

```ruby
# Rails: ❌
Order.where('DATE(created_at) = ?', date)

# Rails: ✓
Order.where(created_at: date.beginning_of_day..date.end_of_day)
```

```python
# Django: ❌
Order.objects.filter(created_at__date='2024-01-15')

# Django: ✓
import datetime
start = datetime.date(2024, 1, 15)
end = start + datetime.timedelta(days=1)
Order.objects.filter(created_at__gte=start, created_at__lt=end)
```

```php
// Laravel: ❌
Order::whereDate('created_at', '2024-01-15')

// Laravel: ✓
Order::where('created_at', '>=', '2024-01-15')
     ->where('created_at', '<', '2024-01-16')
```

---

## Lesson 3.2: Numeric Strings

Comparing a VARCHAR column to a numeric value causes implicit type
conversion, which prevents index usage (or worse, produces wrong results).

```sql
-- Table: phone_numbers VARCHAR
-- ✗ Implicit conversion: '123' → 123 — index not used (or used poorly)
SELECT * FROM users WHERE phone_number = 123456;

-- ✓ String comparison: index works
SELECT * FROM users WHERE phone_number = '123456';
```

**The fix:** Always use the correct type. If the column is VARCHAR, compare
with a string. Better yet: store numbers as numeric types, not VARCHAR.

### ORM Gotchas

```ruby
# Rails: ❌ if phone_number is VARCHAR
User.where(phone_number: 123456)  # Rails quotes it → OK in Rails
# But: User.where('phone_number = ?', 123456) → type mismatch!
```

---

## Lesson 3.3: Combining Columns

Searching on concatenated expressions prevents index usage on individual
columns.

```sql
-- ✗ Concatenation: no index on expression
SELECT * FROM employees
WHERE first_name || ' ' || last_name = 'John Smith';

-- ✓ Search individual columns: indexes work
SELECT * FROM employees
WHERE first_name = 'John'
  AND last_name = 'Smith';
```

The fix for "search full name" scenarios:

```sql
-- Option A: Search individual columns (preferred)
WHERE first_name = ? AND last_name = ?

-- Option B: Add a redundant WHERE clause with individual columns
WHERE first_name || ' ' || last_name = ?
  AND first_name = ?
  AND last_name = ?
-- The individual conditions use indexes; concat is just verification

-- Option C: Generated column + index
ALTER TABLE employees ADD COLUMN full_name
    GENERATED ALWAYS AS (CONCAT(first_name, ' ', last_name)) STORED;
CREATE INDEX idx_full_name ON employees (full_name);
```

---

## Lesson 3.4: Smart Logic — Conditional WHERE Clauses

The most destructive anti-pattern: building WHERE clauses dynamically with
"if-null" conditions that break index usage.

```sql
-- ✗ Smart Logic: makes index unusable
SELECT * FROM orders
WHERE (status = ? OR ? IS NULL)
  AND (customer_id = ? OR ? IS NULL);
-- Even with index on (status, customer_id), this triggers full scan!

-- ✓ Build query dynamically in application code
-- Python example:
conditions = []
params = []
if status:
    conditions.append("status = ?")
    params.append(status)
if customer_id:
    conditions.append("customer_id = ?")
    params.append(customer_id)
query = f"SELECT * FROM orders WHERE {' AND '.join(conditions)}"
```

**Why it breaks indexes:**

- The `OR ? IS NULL` makes the condition always true when the parameter is
  NULL
- The database can't know at plan time whether the parameter will be NULL
- Result: full table scan every time

**The fix:** Always build WHERE clauses dynamically in application code.
Most query builders and ORMs support this natively.

---

## Lesson 3.5: Math on Columns

```sql
-- ✗ Math on column: NO INDEX
SELECT * FROM products WHERE price * 1.2 > 100;

-- ✓ Move math to the comparison value: INDEX WORKS
SELECT * FROM products WHERE price > 100 / 1.2;

-- ✗ Math on column
SELECT * FROM events WHERE YEAR(date_col) = 2024;

-- ✓ Move math to value (if possible) — but this doesn't work for YEAR()
-- Use range instead:
SELECT * FROM events WHERE date_col >= '2024-01-01' AND date_col < '2025-01-01';
```

The rule: **databases don't solve equations.** If you wrap the column in
an expression, the index can't be used. Rewrite so the column stands alone.

---

## Key Takeaways

1. **Dates are the #1 obfuscation** — always use range conditions, never
   `DATE()`/`YEAR()`/`MONTH()` on indexed columns
2. **Match types** — comparing VARCHAR to INT breaks index usage
3. **Concatenation hides columns** — search individual columns, not
   concatenated expressions
4. **Smart logic is index poison** — build WHERE clauses dynamically in
   code, don't use `OR ? IS NULL`
5. **Math stays on the value side** — rewrite so the column is not wrapped
   in any expression
