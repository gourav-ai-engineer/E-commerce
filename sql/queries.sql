-- Olist business questions. Execute after running transformations.sql.
-- Revenue definition: merchandise item price; freight is a separate metric.

-- 1. Monthly revenue and month-over-month growth.
WITH monthly AS (
    SELECT d.year_month, SUM(o.item_revenue) AS revenue
    FROM fact_orders o JOIN dim_date d ON d.date_key = o.order_date_key
    WHERE o.order_status NOT IN ('canceled', 'unavailable')
    GROUP BY d.year_month
)
SELECT year_month, revenue,
       LAG(revenue) OVER (ORDER BY year_month) AS previous_month_revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY year_month))
             / NULLIF(LAG(revenue) OVER (ORDER BY year_month), 0), 2) AS mom_growth_pct
FROM monthly ORDER BY year_month;

-- 2. Top 10 product categories by merchandise revenue.
SELECT COALESCE(p.category_name_english, p.category_name, 'unknown') AS category,
       SUM(i.price) AS revenue, COUNT(DISTINCT i.order_id) AS orders,
       SUM(i.price) / NULLIF(COUNT(DISTINCT i.order_id), 0) AS revenue_per_order
FROM fact_order_items i JOIN dim_product p USING (product_key)
GROUP BY 1 ORDER BY revenue DESC LIMIT 10;

-- 3. Average order value (AOV) by month.
SELECT d.year_month, SUM(o.item_revenue) / NULLIF(COUNT(*), 0) AS aov
FROM fact_orders o JOIN dim_date d ON d.date_key = o.order_date_key
WHERE o.order_status NOT IN ('canceled', 'unavailable')
GROUP BY d.year_month ORDER BY d.year_month;

-- 4. Repeat-customer rate using customer_unique_id as the person-level identifier.
WITH customer_orders AS (
    SELECT c.customer_unique_id, COUNT(DISTINCT o.order_id) AS orders
    FROM fact_orders o
    JOIN dim_customer c USING (customer_key)
    WHERE c.customer_unique_id IS NOT NULL
    GROUP BY c.customer_unique_id
)
SELECT COUNT(*) FILTER (WHERE orders >= 2)::numeric / NULLIF(COUNT(*), 0) AS repeat_customer_rate
FROM customer_orders;

-- 5. Delivery delay versus review score.
SELECT CASE WHEN delivered_customer_date IS NULL THEN 'not delivered'
            WHEN delivered_customer_date::date <= estimated_delivery_date::date THEN 'on time'
            ELSE 'late' END AS delivery_bucket,
       ROUND(AVG(review_score), 2) AS avg_review_score,
       COUNT(*) AS orders
FROM fact_orders
WHERE review_score IS NOT NULL
GROUP BY 1 ORDER BY orders DESC;

-- 6. Revenue by customer state.
SELECT c.state, SUM(o.item_revenue) AS revenue, COUNT(*) AS orders
FROM fact_orders o JOIN dim_customer c USING (customer_key)
GROUP BY c.state ORDER BY revenue DESC;

-- 7. Best-selling categories by month using a window function.
WITH category_month AS (
    SELECT d.year_month, COALESCE(p.category_name_english, p.category_name, 'unknown') AS category,
           SUM(i.price) AS revenue
    FROM fact_order_items i
    JOIN fact_orders o USING (order_id)
    JOIN dim_date d ON d.date_key = o.order_date_key
    JOIN dim_product p USING (product_key)
    GROUP BY d.year_month, 2
), ranked AS (
    SELECT *, DENSE_RANK() OVER (PARTITION BY year_month ORDER BY revenue DESC) AS category_rank
    FROM category_month
)
SELECT * FROM ranked WHERE category_rank <= 10
ORDER BY year_month, category_rank;

-- 8. Order status mix.
SELECT order_status, COUNT(*) AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS order_share_pct
FROM fact_orders GROUP BY order_status ORDER BY orders DESC;

-- 9. Seller revenue leaderboard.
SELECT s.seller_id, s.state, SUM(i.price) AS merchandise_revenue,
       COUNT(DISTINCT i.order_id) AS orders, COUNT(*) AS items
FROM fact_order_items i JOIN dim_seller s USING (seller_key)
GROUP BY s.seller_id, s.state
ORDER BY merchandise_revenue DESC LIMIT 20;

-- 10. Monthly freight as a share of item revenue.
SELECT d.year_month, SUM(o.freight_value) AS freight,
       SUM(o.item_revenue) AS item_revenue,
       ROUND(100.0 * SUM(o.freight_value) / NULLIF(SUM(o.item_revenue), 0), 2) AS freight_to_revenue_pct
FROM fact_orders o JOIN dim_date d ON d.date_key = o.order_date_key
GROUP BY d.year_month ORDER BY d.year_month;

-- 11. Purchase-to-delivery duration in days.
SELECT d.year_month,
       ROUND(AVG(EXTRACT(EPOCH FROM (o.delivered_customer_date - o.purchase_timestamp)) / 86400.0)::numeric, 2)
         AS avg_purchase_to_delivery_days
FROM fact_orders o JOIN dim_date d ON d.date_key = o.order_date_key
WHERE o.delivered_customer_date IS NOT NULL
GROUP BY d.year_month ORDER BY d.year_month;

-- 12. Customer lifetime value proxy and order frequency.
SELECT c.customer_unique_id, COUNT(*) AS orders,
       SUM(o.item_revenue) AS lifetime_merchandise_revenue,
       MAX(o.purchase_timestamp)::date AS most_recent_order
FROM fact_orders o JOIN dim_customer c USING (customer_key)
WHERE c.customer_unique_id IS NOT NULL
GROUP BY c.customer_unique_id
ORDER BY lifetime_merchandise_revenue DESC LIMIT 50;
