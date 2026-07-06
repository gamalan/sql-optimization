# Lesson 4: Testing & Scalability

**Source:** [use-the-index-luke.com/sql/testing-scalability](https://use-the-index-luke.com/sql/testing-scalability)

---

## Summary

Sloppy indexing works fine on small development databases and bites back at
production scale. This lesson covers why you must test with realistic data
volumes, how system load affects response time, and the relationship
between response time and throughput.

---

## Lesson 4.1: Data Volume Effects

### The Logarithmic-vs-Linear Trap

| Rows | Index Scan (log n) | Full Table Scan (linear) |
|-----:|:---:|:---:|
| 1,000 | 0.1ms | 1ms |
| 100,000 | 0.2ms | 100ms |
| 10,000,000 | 0.3ms | 10,000ms |
| 100,000,000 | 0.5ms | 100,000ms |

On a development database with 1,000 rows, a missing index query runs in
1ms — "fast enough." On production with 10M rows, the same query takes 10
seconds. The execution plan is identical; only the data volume changed.

**Why it fools developers:**

- Dev: 1ms → "No index needed, it's fast"
- Staging (100K rows): 100ms → "Hmm, a bit slow but OK"
- Production: 10 seconds → "Why is the database so slow?!"

### The fix

Always test with production-scale data. Use tools like:

- `mysqlslap` for load generation
- Cloned production data (anonymized) in staging
- `sysbench` for standardized benchmarks
- EXPLAIN with `rows` estimate — multiply by realistic production row
  counts

---

## Lesson 4.2: System Load Effects

### Concurrency Degrades Response Time

A query that takes 10ms with zero concurrent load may take 100ms+ under
production concurrency. Causes:

1. **Resource contention** — CPU, memory, disk I/O shared across
   connections
2. **Lock contention** — row locks, gap locks, metadata locks
3. **Buffer pool thrashing** — hot data evicted by competing queries
4. **Connection overhead** — each connection consumes memory and CPU

### Testing at Load

```bash
# Generate concurrent load for testing
sysbench /usr/share/sysbench/oltp_read_write.lua \
    --mysql-host=staging-db \
    --mysql-db=testdb \
    --tables=10 --table-size=1000000 \
    --threads=50 --time=300 \
    run
```

---

## Lesson 4.3: Response Time vs Throughput

Two different performance dimensions:

| Metric | What It Measures | Unit |
|--------|-----------------|------|
| **Response time** | How long one query takes | ms |
| **Throughput** | How many queries per second | queries/sec |

### The Latency (Network) Factor

Network round-trips dominate response time far more than data volume:

```
1 query returning 1000 rows in one network trip:  ~5ms
1000 queries returning 1 row each:                ~5000ms (1000 × 5ms)

Same data, same database work — but 1000× more network trips.
```

### N+1 Amplifies This

The ORM N+1 anti-pattern is catastrophic for response time precisely
because of network round-trips:

```
1 query + 500 child queries = 501 network round-trips
1 JOIN query                 = 1 network round-trip

The database does the SAME index lookups either way.
The difference is entirely in the network latency multiplication.
```

### Horizontal Scalability

You can scale throughput horizontally (add more replicas for reads). You
cannot scale response time horizontally — a single slow query is a single
slow query, regardless of how many replicas you have.

---

## Key Takeaways

1. **Test with production-scale data** — 1ms in dev means nothing at scale
2. **Index scans scale logarithmically; full scans scale linearly** — the
   gap widens exponentially with data growth
3. **Concurrency matters** — test under realistic load, not single-user
4. **Network trips dominate response time** — one JOIN beats N+1
   individual queries every time
5. **Scale reads horizontally, optimize writes vertically** — replicas help
   throughput, not individual query speed
