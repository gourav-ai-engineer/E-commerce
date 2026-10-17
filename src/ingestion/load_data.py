"""Load Olist CSV files into PostgreSQL raw staging tables, then build the warehouse."""
from __future__ import annotations

import argparse
import logging
import os
from pathlib import Path
from typing import Iterable

import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DATA_DIR = ROOT / "data" / "raw"
LOG = logging.getLogger("ecommerce.ingestion")

# Filename -> raw schema table name. Translation/geolocation files are optional.
CSV_TABLES = {
    "olist_orders_dataset.csv": "orders",
    "olist_order_items_dataset.csv": "order_items",
    "olist_order_payments_dataset.csv": "order_payments",
    "olist_order_reviews_dataset.csv": "order_reviews",
    "olist_customers_dataset.csv": "customers",
    "olist_products_dataset.csv": "products",
    "olist_sellers_dataset.csv": "sellers",
    "product_category_name_translation.csv": "category_translation",
    "olist_geolocation_dataset.csv": "geolocation",
}
REQUIRED_FILES = {
    "olist_orders_dataset.csv",
    "olist_order_items_dataset.csv",
    "olist_customers_dataset.csv",
    "olist_products_dataset.csv",
    "olist_sellers_dataset.csv",
    "olist_order_payments_dataset.csv",
    "olist_order_reviews_dataset.csv",
}


def database_url() -> URL:
    """Build a SQLAlchemy URL safely from environment variables."""
    return URL.create(
        "postgresql+psycopg",
        username=os.getenv("POSTGRES_USER", "olist"),
        password=os.getenv("POSTGRES_PASSWORD", "change_me_local"),
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=int(os.getenv("POSTGRES_PORT", "5432")),
        database=os.getenv("POSTGRES_DB", "olist_analytics"),
    )


def validate_data_dir(data_dir: Path) -> list[Path]:
    """Return supported CSV paths or raise an actionable validation error."""
    if not data_dir.is_dir():
        raise FileNotFoundError(
            f"CSV directory not found: {data_dir}. Download the Olist dataset and place CSVs there."
        )
    missing = sorted(name for name in REQUIRED_FILES if not (data_dir / name).is_file())
    if missing:
        raise FileNotFoundError(
            "Missing required Olist CSV files: " + ", ".join(missing)
            + f". Expected them in {data_dir}"
        )
    return [data_dir / name for name in CSV_TABLES if (data_dir / name).is_file()]


def load_csvs(data_dir: Path, engine, chunksize: int = 20_000) -> dict[str, int]:
    """Load CSVs into raw schema in chunks; replacing staging tables on each run."""
    paths = validate_data_dir(data_dir)
    counts: dict[str, int] = {}
    with engine.begin() as connection:
        connection.execute(text("CREATE SCHEMA IF NOT EXISTS raw"))
    for path in paths:
        table = CSV_TABLES[path.name]
        LOG.info("Loading %s -> raw.%s", path.name, table)
        rows = 0
        # pandas parses numeric columns where possible and leaves timestamp strings intact;
        # SQL transformations explicitly cast timestamps and numeric values.
        for chunk_number, chunk in enumerate(pd.read_csv(path, chunksize=chunksize, low_memory=False)):
            chunk.columns = [str(column).strip().lower() for column in chunk.columns]
            chunk.to_sql(
                table,
                engine,
                schema="raw",
                if_exists="replace" if chunk_number == 0 else "append",
                index=False,
                method="multi",
                chunksize=1_000,
            )
            rows += len(chunk)
        counts[table] = rows
        LOG.info("Loaded %s rows into raw.%s", rows, table)
    return counts


def run_sql_file(engine, path: Path) -> None:
    """Execute a SQL file containing statements supported by psycopg."""
    sql = path.read_text(encoding="utf-8")
    # psycopg's driver-level execution supports multiple statements in one execute call.
    raw_connection = engine.raw_connection()
    try:
        cursor = raw_connection.cursor()
        try:
            cursor.execute(sql)
            raw_connection.commit()
        finally:
            cursor.close()
    except Exception:
        raw_connection.rollback()
        raise
    finally:
        raw_connection.close()


def main(argv: Iterable[str] | None = None) -> int:
    load_dotenv(ROOT / ".env")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    parser.add_argument("--skip-transform", action="store_true", help="Only load raw CSV staging tables")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    schema_file = ROOT / "sql" / "schema.sql"
    transformations_file = ROOT / "sql" / "transformations.sql"
    engine = create_engine(database_url(), pool_pre_ping=True)
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
        LOG.info("Database connection successful")
        run_sql_file(engine, schema_file)
        counts = load_csvs(args.data_dir, engine)
        if not args.skip_transform:
            run_sql_file(engine, transformations_file)
            LOG.info("Warehouse transformations completed")
        for table, count in counts.items():
            LOG.info("raw.%-22s %s rows", table, count)
    finally:
        engine.dispose()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
