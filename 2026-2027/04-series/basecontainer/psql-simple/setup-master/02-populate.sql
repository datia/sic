/**
 * 
 * ND, 2025
 * */

BEGIN;

-- extensions used by the schema or this script)
CREATE EXTENSION IF NOT EXISTS citext;

-- BEGIN helpers 
-- random choice
CREATE OR REPLACE FUNCTION retail._pick(arr anyarray) RETURNS anyelement
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT arr[1 + (random() * (array_length(arr,1)-1))::int]
$$;

-- === 1) STORES ===============================================================
WITH s(code, name, address, phone, tz) AS (
  VALUES
    ('ST-001','Chiado Store','Rua Garrett 50, Lisboa','+351210000001','Europe/Lisbon'),
    ('ST-002','Porto Store','Rua de Santa Catarina 400, Porto','+351220000002','Europe/Lisbon'),
    ('ST-003','Faro Store','Rua de Santo António 10, Faro','+351289000003','Europe/Lisbon')
)
INSERT INTO retail.stores (code, name, address, phone, timezone)
SELECT code, name, address, phone, tz FROM s
ON CONFLICT (code) DO NOTHING
RETURNING store_id, code;
-- END helpers 

-- PRODUCTS 
WITH p(sku, name, description) AS (
  SELECT
    'P' || to_char(i, 'FM0000') AS sku,
    CASE
      WHEN i<=4 THEN 'Basic Tee '||i
      WHEN i<=8 THEN 'Denim Jeans '||(i-4)
      ELSE 'Sneakers '||(i-8)
    END,
    CASE
      WHEN i<=4 THEN '100% cotton tee'
      WHEN i<=8 THEN 'Regular fit denim'
      ELSE 'Comfort sneakers'
    END
  FROM generate_series(1,12) AS g(i)
)
INSERT INTO retail.products (sku, name, description)
SELECT sku, name, description FROM p
ON CONFLICT (sku) DO NOTHING; -- WARNING This is for demonstration purposes only. Errors should not be ignored!!!!

-- PRICES (global default, no overlaps)
-- Effective from Jan 1, 2025 onward
WITH base AS (
  SELECT product_id,
         -- simple price bands
         CASE
           WHEN name ILIKE 'Basic Tee%' THEN 9.99
           WHEN name ILIKE 'Denim Jeans%' THEN 39.90
           ELSE 59.00
         END AS price
  FROM retail.products
)
INSERT INTO retail.prices (product_id, store_id, price, effective)
SELECT product_id, NULL, price, daterange('2025-01-01'::date, NULL, '[)')
FROM base
ON CONFLICT DO NOTHING;

-- store-specific overrides
INSERT INTO retail.prices (product_id, store_id, price, effective)
SELECT p.product_id, s.store_id, b.price * 0.95, daterange('2025-08-01', NULL, '[)')
FROM retail.products p
JOIN retail.stores s ON s.code = 'ST-002'
JOIN (SELECT product_id, price FROM retail.prices WHERE store_id IS NULL) b USING (product_id)
WHERE p.name ILIKE 'Basic Tee%'
ON CONFLICT DO NOTHING;

-- CUSTOMERS
WITH names AS (
  SELECT unnest(ARRAY[
    'Ana','Bruno','Carla','Diogo','Eva','Filipe','Gonçalo','Helena','Inês','João',
    'Kátia','Luís','Marta','Nuno','Olga','Paulo','Rita','Sara','Tiago','Vera',
    'Xavier','Yara','Zé','Beatriz','Clara','Duarte','Eduardo','Francisca','António','Eularinany',
    'Vitor','Jorge','Leonor','Matilde','Bruno','Óscar','Patrícia','Raquel','Sofia','Marcos',
    'Ivan','José','Wanda','Maria','Tymur','Zara','André','Bárbara','Catarina','Daniel'
  ]) AS first_name
),
cust AS (
  SELECT row_number() OVER () AS rn,
         first_name || ' ' || retail._pick(ARRAY['Silva','Santos','Ferreira','Pereira','Oliveira','Costa','Martins','Rocha','Ribeiro','Carvalho']) AS full_name
  FROM names
  LIMIT 50
)
INSERT INTO retail.customers (nif, name, address, phone, email)
SELECT
  '2' || to_char(rn, 'FM00000000') AS nif,
  full_name,
  'Rua '||retail._pick(ARRAY['das Flores','do Sol','do Norte','da Alegria','da Liberdade'])||', '||(10 + rn)::text||', '||retail._pick(ARRAY['Lisboa','Porto','Faro','Coimbra','Braga']),
  '+3519'||to_char(20000000 + rn, 'FM000000'),
  lower(replace(split_part(full_name,' ',1), 'í', 'i'))||'.'||lower(split_part(full_name,' ',2))||'@example.com'
FROM cust
ON CONFLICT (email) DO nothing;

-- INVENTORY (initial snapshot per store/product) 
-- Start each store with 100 units on hand, safety stock 10
INSERT INTO retail.inventory (store_id, product_id, qty_on_hand, safety_stock)
SELECT s.store_id, p.product_id, 100, 10
FROM retail.stores s
CROSS JOIN retail.products p
ON CONFLICT (store_id, product_id) DO NOTHING;

-- SALES (headers) 
-- Create ~60 sales spread across stores and the last 14 days
DROP TABLE IF EXISTS tmp_sales_stage;
CREATE TEMP TABLE tmp_sales_stage AS
SELECT
  gen_random_uuid()                      AS stage_key,
  s.store_id,
  (SELECT customer_id FROM retail.customers ORDER BY random() LIMIT 1) AS customer_id,
  (now()::date - ((random()*13)::int))::timestamptz
    + ((8 + (random()*12))::int || ' hours')::interval AS sale_datetime,
  CASE WHEN random() < 0.8 THEN 'STORE' ELSE 'ONLINE' END::retail.sale_channel AS channel
FROM retail.stores s,
     LATERAL generate_series(1, 20) g(n);  -- 3 stores * 20 = 60 sales

-- Insert headers with provisional totals (=0); sale_number will corrected later
DROP TABLE IF EXISTS tmp_sales_map;
with ins as (
INSERT INTO retail.sales (store_id, customer_id, channel, sale_datetime, sale_number,
                          currency, total_gross, total_discount, total_tax, total_net, status)
select 
  store_id, customer_id, channel, sale_datetime,
  ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY sale_datetime), -- placeholder; we’ll backfill sequential numbers per store
  'EUR', 0, 0, 0, 0, 'OPEN'::retail.sale_status
FROM tmp_sales_stage
--ON CONFLICT (store_id, sale_number) DO nothing
RETURNING sale_id, store_id, sale_datetime
)
 
select sale_id, store_id, sale_datetime into tmp_sales_map from ins;

-- Backfill sale_number as a per-store sequence (dense)
WITH nums AS (
  SELECT sale_id,
         ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY sale_datetime, sale_id) AS rn
  FROM tmp_sales_map
)
UPDATE retail.sales s
SET sale_number = n.rn
FROM nums n
WHERE s.sale_id = n.sale_id;

-- SALE ITEMS
-- For each sale, create 1..4 line items with random products & quantities
DROP TABLE IF EXISTS tmp_items_stage;
CREATE TEMP TABLE tmp_items_stage AS
SELECT
  sm.sale_id,
  p.product_id,
  1 + (random()*3)::int AS qty
FROM tmp_sales_map sm
JOIN LATERAL (
  SELECT product_id FROM retail.products ORDER BY random() LIMIT (1 + (random()*3)::int)
) p ON TRUE;

-- Attach current price per (store, product); fall back to global price
CREATE TEMP TABLE tmp_items_priced AS
SELECT
  t.sale_id,
  t.product_id,
  t.qty::numeric AS quantity,
  COALESCE(
    (SELECT price FROM retail.prices pr
      JOIN retail.sales s ON s.sale_id = t.sale_id
     WHERE pr.product_id = t.product_id
       AND (pr.store_id = s.store_id OR pr.store_id IS NULL)
       AND s.sale_datetime::date <@ pr.effective
     ORDER BY pr.store_id NULLS LAST, lower(pr.effective) DESC
     LIMIT 1),
    0.0
  ) AS unit_price,
  -- simple discount: 10% chance of €2 off per line
  CASE WHEN random() < 0.10 THEN 2.00 ELSE 0.00 END::numeric(12,2) AS discount_amount,
  -- simple VAT: 23%
  23.00::numeric(5,2) AS tax_rate_pct
FROM tmp_items_stage t;

-- Insert items
INSERT INTO retail.sale_items (sale_id, product_id, quantity, unit_price, discount_amount, tax_rate_pct, line_total)
SELECT
  sale_id, product_id, quantity, unit_price, discount_amount, tax_rate_pct,
  ROUND( (quantity*unit_price - discount_amount) * 1.23, 2 )--,
  --ROW_NUMBER() OVER (PARTITION BY sale_id ORDER BY product_id)
FROM tmp_items_priced;

--  Update SALES totals from items
WITH sums AS (
  SELECT
    si.sale_id,
    ROUND(SUM(si.quantity*si.unit_price), 2)                         AS gross,
    ROUND(SUM(si.discount_amount), 2)                                 AS discount,
    -- compute tax from net-before-tax * rate (approx since single VAT)
    ROUND(SUM( (si.quantity*si.unit_price - si.discount_amount) * (si.tax_rate_pct/100.0) ), 2) AS tax,
    ROUND(SUM(si.line_total), 2)                                      AS net
  FROM retail.sale_items si
  GROUP BY si.sale_id
)
UPDATE retail.sales s
SET total_gross    = sums.gross,
    total_discount = sums.discount,
    total_tax      = sums.tax,
    total_net      = sums.net,
    status         = 'PAID'
FROM sums
WHERE s.sale_id = sums.sale_id;

-- PAYMENTS (1 payment per sale, captured) 
INSERT INTO retail.payments (sale_id, method, amount, status, provider_ref)
SELECT s.sale_id,
       retail._pick(ARRAY['CASH'::retail.payment_method,'CARD','WALLET','TRANSFER']),
       s.total_net,
       'CAPTURED',
       'AUTH-'||lpad(sale_id::text,8,'0')
FROM retail.sales s;

-- STOCK MOVEMENTS for each sale item (negative qty) 
INSERT INTO retail.stock_movements (store_id, product_id, qty_delta, reason, ref_sale_id, created_at)
SELECT
  s.store_id,
  si.product_id,
  -si.quantity,
  'SALE',
  si.sale_id,
  s.sale_datetime
FROM retail.sale_items si
JOIN retail.sales s ON s.sale_id = si.sale_id;

-- Apply movements to INVENTORY 
-- Reduce on-hand by all SALE movements created above.
WITH deltas AS (
  SELECT store_id, product_id, SUM(qty_delta) AS delta
  FROM retail.stock_movements
  WHERE reason = 'SALE'
  GROUP BY store_id, product_id
)
UPDATE retail.inventory i
SET qty_on_hand = GREATEST(0, i.qty_on_hand + d.delta),
    updated_at  = now()
FROM deltas d
WHERE i.store_id = d.store_id AND i.product_id = d.product_id;

-- Cleanup helpers
DROP FUNCTION IF EXISTS retail._pick(anyarray);

COMMIT;