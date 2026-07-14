import psycopg2
import psycopg2.pool

from config import PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD

db_pool = psycopg2.pool.SimpleConnectionPool(
    1, 10,
    host=PGHOST,
    port=PGPORT,
    dbname=PGDATABASE,
    user=PGUSER,
    password=PGPASSWORD,
)


def db_execute(query, params=(), fetch=None, commit=False):
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(query, params)
            result = None
            if fetch == "one":
                result = cur.fetchone()
            elif fetch == "all":
                result = cur.fetchall()
            if commit:
                conn.commit()
            return result
    finally:
        db_pool.putconn(conn)
