-- Rebuild dimensions and facts from raw Olist CSV staging tables.
-- Safe to rerun after reloading raw data. Revenue is merchandise price;
-- freight is reported separately to avoid conflating sales and shipping.
BEGIN;

TRUNCATE TABLE fact_order_items, fact_orders, dim_date, dim_customer, dim_product, dim_seller
RESTART IDENTITY CASCADE;

INSERT INTO dim_customer (customer_id, customer_unique_id, zip_code_prefix, city, state)
SELECT DISTINCT ON (customer_id)
    customer_id::text,
    NULLIF(customer_unique_id::text, ''),
    NULLIF(customer_zip_code_prefix::text, ''),
    NULLIF(customer_city::text, ''),
    NULLIF(customer_state::text, '')
FROM raw.customers
WHERE customer_id IS NOT NULL
ORDER BY customer_id;

INSERT INTO dim_product (
    product_id, category_name, category_name_english, name_length,
    description_length, photos_qty, weight_g, length_cm, height_cm, width_cm
)
SELECT
    p.product_id::text,
    NULLIF(p.product_category_name::text, ''),
    NULLIF(t.product_category_name_english::text, ''),
    NULLIF(p.product_name_lenght::text, '')::integer,
    NULLIF(p.product_description_lenght::text, '')::integer,
    NULLIF(p.product_photos_qty::text, '')::integer,
    NULLIF(p.product_weight_g::text, '')::numeric,
    NULLIF(p.product_length_cm::text, '')::numeric,
    NULLIF(p.product_height_cm::text, '')::numeric,
    NULLIF(p.product_width_cm::text, '')::numeric
FROM raw.products p
LEFT JOIN raw.category_translation t
  ON p.product_category_name::text = t.product_category_name::text
WHERE p.product_id IS NOT NULL
ON CONFLICT (product_id) DO UPDATE SET
    category_name = EXCLUDED.category_name,
    category_name_english = EXCLUDED.category_name_english,
    name_length = EXCLUDED.name_length,
    description_length = EXCLUDED.description_length,
    photos_qty = EXCLUDED.photos_qty,
    weight_g = EXCLUDED.weight_g,
    length_cm = EXCLUDED.length_cm,
    height_cm = EXCLUDED.height_cm,
    width_cm = EXCLUDED.width_cm;

INSERT INTO dim_seller (seller_id, zip_code_prefix, city, state)
SELECT DISTINCT ON (seller_id)
    seller_id::text,
    NULLIF(seller_zip_code_prefix::text, ''),
    NULLIF(seller_city::text, ''),
    NULLIF(seller_state::text, '')
FROM raw.sellers
WHERE seller_id IS NOT NULL
ORDER BY seller_id;

WITH order_dates AS (
    SELECT DISTINCT (NULLIF(order_purchase_timestamp::text, '')::timestamp)::date AS d
    FROM raw.orders
    WHERE NULLIF(order_purchase_timestamp::text, '') IS NOT NULL
), bounds AS (
    SELECT MIN(d) AS min_date, MAX(d) AS max_date FROM order_dates
), calendar AS (
    SELECT gs::date AS d
    FROM bounds b
    CROSS JOIN LATERAL generate_series(b.min_date::timestamp, b.max_date::timestamp, interval '1 day') gs
    WHERE b.min_date IS NOT NULL
)
INSERT INTO dim_date (
    date_key, full_date, year, quarter, month, month_name, year_month,
    day_of_month, day_of_week, day_name, is_weekend
)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::integer,
    d,
    EXTRACT(YEAR FROM d)::smallint,
    EXTRACT(QUARTER FROM d)::smallint,
    EXTRACT(MONTH FROM d)::smallint,
    TO_CHAR(d, 'FMMonth'),
    TO_CHAR(d, 'YYYY-MM'),
    EXTRACT(DAY FROM d)::smallint,
    EXTRACT(ISODOW FROM d)::smallint,
    TO_CHAR(d, 'FMDay'),
    EXTRACT(ISODOW FROM d) IN (6, 7)
FROM calendar;

WITH items AS (
    SELECT
        order_id::text AS order_id,
        COUNT(*)::integer AS item_count,
        COALESCE(SUM(NULLIF(price::text, '')::numeric), 0) AS item_revenue,
        COALESCE(SUM(NULLIF(freight_value::text, '')::numeric), 0) AS freight_value
    FROM raw.order_items
    GROUP BY order_id
), payments AS (
    SELECT order_id::text AS order_id,
           COALESCE(SUM(NULLIF(payment_value::text, '')::numeric), 0) AS payment_value
    FROM raw.order_payments
    GROUP BY order_id
), reviews AS (
    SELECT order_id::text AS order_id,
           AVG(NULLIF(review_score::text, '')::numeric) AS review_score
    FROM raw.order_reviews
    WHERE order_id IS NOT NULL
    GROUP BY order_id
)
INSERT INTO fact_orders (
    order_id, customer_key, order_date_key, order_status,
    purchase_timestamp, approved_timestamp, delivered_carrier_date,
    delivered_customer_date, estimated_delivery_date,
    item_revenue, freight_value, payment_value, item_count, review_score
)
SELECT
    o.order_id::text,
    c.customer_key,
    TO_CHAR(NULLIF(o.order_purchase_timestamp::text, '')::timestamp::date, 'YYYYMMDD')::integer,
    COALESCE(NULLIF(o.order_status::text, ''), 'unknown'),
    NULLIF(o.order_purchase_timestamp::text, '')::timestamp,
    NULLIF(o.order_approved_at::text, '')::timestamp,
    NULLIF(o.order_delivered_carrier_date::text, '')::timestamp,
    NULLIF(o.order_delivered_customer_date::text, '')::timestamp,
    NULLIF(o.order_estimated_delivery_date::text, '')::timestamp,
    COALESCE(i.item_revenue, 0),
    COALESCE(i.freight_value, 0),
    COALESCE(p.payment_value, 0),
    COALESCE(i.item_count, 0),
    r.review_score
FROM raw.orders o
LEFT JOIN dim_customer c ON c.customer_id = o.customer_id::text
LEFT JOIN items i ON i.order_id = o.order_id::text
LEFT JOIN payments p ON p.order_id = o.order_id::text
LEFT JOIN reviews r ON r.order_id = o.order_id::text
WHERE o.order_id IS NOT NULL;

INSERT INTO fact_order_items (
    order_id, order_item_id, product_key, seller_key, shipping_limit_date, price, freight_value
)
SELECT
    i.order_id::text,
    NULLIF(i.order_item_id::text, '')::integer,
    p.product_key,
    s.seller_key,
    NULLIF(i.shipping_limit_date::text, '')::timestamp,
    COALESCE(NULLIF(i.price::text, '')::numeric, 0),
    COALESCE(NULLIF(i.freight_value::text, '')::numeric, 0)
FROM raw.order_items i
JOIN fact_orders o ON o.order_id = i.order_id::text
LEFT JOIN dim_product p ON p.product_id = i.product_id::text
LEFT JOIN dim_seller s ON s.seller_id = i.seller_id::text
WHERE i.order_id IS NOT NULL AND NULLIF(i.order_item_id::text, '') IS NOT NULL;

COMMIT;
