# E-commerce Analytics & Revenue Forecasting

End-to-end analytics engineering project using the Olist Brazilian e-commerce dataset: PostgreSQL, SQL, Python, and Streamlit (dashboard milestone follows the data foundation).

## Current milestone: 1 — data foundation

- Docker Compose PostgreSQL 16
- Repeatable CSV ingestion into the `raw` schema
- Star-schema dimensions and order/order-item facts
- 12 documented business SQL questions in `sql/queries.sql`
- Input validation and unit tests

## Architecture

```text
Olist CSVs -> Python/pandas -> PostgreSQL raw schema
                              -> dim_customer / dim_product / dim_seller / dim_date
                              -> fact_orders / fact_order_items
                              -> SQL business analysis -> Streamlit (next milestone)
```

## 1. Prerequisites

- Docker Desktop with Docker Compose
- Python 3.11 or 3.12 recommended
- Olist public dataset CSVs downloaded from Kaggle: https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce

Put the extracted CSV files under `data/raw/`. Do not commit raw dataset files.

Required files:
- `olist_orders_dataset.csv`
- `olist_order_items_dataset.csv`
- `olist_customers_dataset.csv`
- `olist_products_dataset.csv`
- `olist_sellers_dataset.csv`
- `olist_order_payments_dataset.csv`
- `olist_order_reviews_dataset.csv`

Optional files:
- `product_category_name_translation.csv`
- `olist_geolocation_dataset.csv`

## 2. Start PostgreSQL

Copy `.env.example` to `.env`, then change the local password if desired.

PowerShell:
```powershell
Copy-Item .env.example .env
docker compose up -d postgres
docker compose ps
```

Linux/macOS:
```bash
cp .env.example .env
docker compose up -d postgres
docker compose ps
```

The default database is `olist_analytics` on `localhost:5432`. The sample credentials are for local development only.

## 3. Install Python dependencies

PowerShell:
```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
```

Linux/macOS:
```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt
```

## 4. Load the data and build the warehouse

```bash
python -m src.ingestion.load_data
```

The loader validates required CSV files, loads them in chunks to `raw.*`, then runs `sql/schema.sql` and `sql/transformations.sql`. Rerunning rebuilds the analytics dimensions/facts from the raw tables.

To load raw tables only:
```bash
python -m src.ingestion.load_data --skip-transform
```

If your CSVs are stored elsewhere:
```bash
python -m src.ingestion.load_data --data-dir /path/to/olist-csvs
```

## 5. Run the SQL analysis

Open `sql/queries.sql` in pgAdmin, DBeaver, or psql and run each query separately. Query 7 uses standard PostgreSQL syntax and can be run independently.

Example using psql inside the container:
```bash
docker compose exec postgres psql -U olist -d olist_analytics
```

## 6. Tests

```bash
pytest -q
```

The initial unit tests validate CSV mapping and clear errors for missing data. Database integration tests will be added with the next validation pass.

## Data definitions and caveats

- **Merchandise revenue** = sum of item `price`; freight is tracked separately.
- `fact_orders` has one row per order; `fact_order_items` has one row per order-item.
- Payments and reviews are aggregated to order level before joining, avoiding order revenue duplication.
- Repeat-customer analysis should use `customer_unique_id` (or the corresponding distinct customer entity) rather than treating each order-specific `customer_id` as a returning person. The warehouse retains both IDs for this reason.
- Forecasting will use time-based holdout/backtesting and report actual MAPE; under 15% is a target, not a guarantee.

## Roadmap

1. **Data foundation** — ingestion, warehouse schema, business SQL, tests.
2. RFM segmentation and Streamlit dashboard.
3. Forecasting, model evaluation, PDF insights report.
4. Public deployment, screenshots, CI, and final documentation.

## License

Dataset license and terms are governed by the dataset provider. Project code is intended for educational and portfolio use.
