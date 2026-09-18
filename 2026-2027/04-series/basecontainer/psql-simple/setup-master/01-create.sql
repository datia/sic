/**
 * 
 * ND, 2025-2026
 * */
 CREATE SCHEMA IF NOT EXISTS retail;

-- Sales channel and status enums
DO $$ BEGIN
  CREATE TYPE retail.sale_channel AS ENUM ('STORE','ONLINE');
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE 'retail.sale_channel Already exists, skipping'; END $$;

DO $$ BEGIN
  CREATE TYPE retail.sale_status AS ENUM ('OPEN','PAID','CANCELLED','REFUNDED');
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE 'retail.sale_status Already exists, skipping'; END $$;

DO $$ BEGIN
  CREATE TYPE retail.payment_method AS ENUM ('CASH','CARD','WALLET','TRANSFER','OTHER');
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE 'retail.payment_method Already exists, skipping'; END $$;


DO $$ BEGIN
  CREATE TYPE retail.payment_status AS ENUM ('AUTHORIZED','CAPTURED','VOIDED','FAILED','REFUNDED','PARTIALLY_REFUNDED');
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE 'retail.payment_status Already exists, skipping'; END $$;

CREATE TABLE IF NOT EXISTS retail.customers (
  customer_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nif              varchar(16) UNIQUE,               
  name             TEXT NOT NULL,
  address          TEXT,
  phone            varchar(20),
  email            TEXT UNIQUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE retail.customers IS 'Customers from all channels.';
COMMENT ON COLUMN retail.customers.nif IS 'National/tax id.';
COMMENT ON COLUMN retail.customers.name IS 'Customer name ';
COMMENT ON COLUMN retail.customers.address IS 'Customer postal address.';
COMMENT ON COLUMN retail.customers.phone IS 'Customer phone.';

CREATE TABLE IF NOT EXISTS retail.stores (
  store_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code             TEXT        NOT NULL UNIQUE,      -- 
  name             TEXT        NOT NULL,
  address          TEXT,
  phone            TEXT,
  timezone         TEXT        NOT NULL DEFAULT 'Europe/Lisbon',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE retail.stores IS 'Physical store catalog.';
COMMENT ON COLUMN retail.stores.store_id IS 'Human code (e.g. ST-001). This can depend on the implementation.';

CREATE TABLE IF NOT EXISTS retail.products (
  product_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sku              TEXT        NOT NULL UNIQUE,
  name             TEXT        NOT NULL,
  description      TEXT,
  is_active        BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE retail.products IS 'Products master.';

CREATE TABLE IF NOT EXISTS retail.sales (
  sale_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  store_id         BIGINT      NOT NULL REFERENCES retail.stores(store_id),
  customer_id      BIGINT          NULL REFERENCES retail.customers(customer_id),
  channel          retail.sale_channel NOT NULL,
  sale_datetime    TIMESTAMPTZ NOT NULL DEFAULT now(),
  sale_number      BIGINT      NOT NULL,
  currency         CHAR(3)     NOT NULL DEFAULT 'EUR',
  total_gross      NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_discount   NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_tax        NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_net        NUMERIC(12,2) NOT NULL DEFAULT 0,
  status           retail.sale_status NOT NULL DEFAULT 'OPEN',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (store_id, sale_number)
);

COMMENT ON TABLE retail.sales IS 'Sales header';
COMMENT ON COLUMN retail.sales.total_gross IS 'totals are stored for auditing and performance';
COMMENT ON COLUMN retail.sales.total_discount IS 'totals are stored for auditing and performance';
COMMENT ON COLUMN retail.sales.total_tax IS 'totals are stored for auditing and performance';
COMMENT ON COLUMN retail.sales.sale_datetime IS 'Date/time of sale.';

-- Line items
CREATE TABLE IF NOT EXISTS retail.sale_items (
  sale_item_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sale_id          BIGINT      NOT NULL REFERENCES retail.sales(sale_id) ON DELETE CASCADE,
  product_id       BIGINT      NOT NULL REFERENCES retail.products(product_id),
  quantity         NUMERIC(12,3) NOT NULL CHECK (quantity > 0),
  unit_price       NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
  discount_amount  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  tax_rate_pct     NUMERIC(5,2)  NOT NULL DEFAULT 0 CHECK (tax_rate_pct >= 0),
  line_total       NUMERIC(12,2) NOT NULL, 
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);


CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON retail.sale_items(sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_items_product ON retail.sale_items(product_id);

COMMENT ON TABLE retail.sale_items IS 'Per-product line items for a sale.';
COMMENT ON COLUMN retail.sale_items.line_total IS 'quantity*unit_price - discount) + tax';


CREATE TABLE IF NOT EXISTS retail.prices (
  price_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id       BIGINT      NOT NULL REFERENCES retail.products(product_id),
  store_id         BIGINT          NULL REFERENCES retail.stores(store_id),
  price            NUMERIC(12,2) NOT NULL CHECK (price >= 0),
  effective        DATERANGE     NOT NULL,
  CHECK (lower(effective) < upper(effective))
);

-- Prevent overlapping price ranges per (product, store)
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE UNIQUE INDEX IF NOT EXISTS ux_prices_product_store_effective
  ON retail.prices (product_id, store_id, effective)
  WHERE TRUE;

CREATE INDEX IF NOT EXISTS idx_prices_lookup
  ON retail.prices (product_id, store_id, effective);

COMMENT ON TABLE retail.prices IS 'Time-aware prices; use current_date and effective to pick today’s price.';
COMMENT ON COLUMN retail.prices.store_id IS 'Store-specific price overrides are supported; NULL store_id means "global/default'; 


CREATE TABLE IF NOT EXISTS retail.inventory (
  store_id         BIGINT  NOT NULL REFERENCES retail.stores(store_id),
  product_id       BIGINT  NOT NULL REFERENCES retail.products(product_id),
  qty_on_hand      NUMERIC(12,3) NOT NULL DEFAULT 0,
  safety_stock     NUMERIC(12,3) NOT NULL DEFAULT 0,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, product_id)
);

COMMENT ON TABLE retail.inventory IS 'Current stock per store/product with last update timestamp.';


CREATE TABLE IF NOT EXISTS retail.stock_movements (
  movement_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  store_id         BIGINT  NOT NULL REFERENCES retail.stores(store_id),
  product_id       BIGINT  NOT NULL REFERENCES retail.products(product_id),
  qty_delta        NUMERIC(12,3) NOT NULL,  -- 
  reason           TEXT    NOT NULL,        -- e.g., SALE, RECEIPT, RETURN, ADJUSTMENT
  ref_sale_id      BIGINT      NULL REFERENCES retail.sales(sale_id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stock_movements_lookup
  ON retail.stock_movements(store_id, product_id, created_at);

COMMENT ON TABLE retail.stock_movements IS 'Immutable ledger of quantity changes by reason. It represents stock movements (to reconcile inventory and enable audit trails)';
COMMENT ON column retail.stock_movements.qty_delta IS 'positive for receipts/returns, negative for sales/shrinkage';
COMMENT ON column retail.stock_movements.reason IS 'The reason for the movement. Free text, application dependent.';


CREATE TABLE IF NOT EXISTS retail.payments (
  payment_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sale_id          BIGINT      NOT NULL REFERENCES retail.sales(sale_id) ON DELETE CASCADE,
  method           retail.payment_method NOT NULL,
  amount           NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
  status           retail.payment_status NOT NULL DEFAULT 'CAPTURED',
  provider_ref     TEXT,        -- PSP reference / auth code
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payments_sale ON retail.payments(sale_id);

COMMENT ON TABLE retail.payments IS 'Payment records (authorization/capture/refund lifecycle).';

-- === Helpful Indexes for Common Access Paths ==================================

CREATE INDEX IF NOT EXISTS idx_sales_store_datetime ON retail.sales(store_id, sale_datetime DESC);
CREATE INDEX IF NOT EXISTS idx_sales_customer_datetime ON retail.sales(customer_id, sale_datetime DESC);
CREATE INDEX IF NOT EXISTS idx_products_active ON retail.products(is_active) WHERE is_active = TRUE;

-- Triggers: updated_at maintenance 

CREATE OR REPLACE FUNCTION retail.touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_touch_customers ON retail.customers;
CREATE TRIGGER trg_touch_customers
BEFORE UPDATE ON retail.customers
FOR EACH ROW EXECUTE FUNCTION retail.touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_stores ON retail.stores;
CREATE TRIGGER trg_touch_stores
BEFORE UPDATE ON retail.stores
FOR EACH ROW EXECUTE FUNCTION retail.touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_products ON retail.products;
CREATE TRIGGER trg_touch_products
BEFORE UPDATE ON retail.products
FOR EACH ROW EXECUTE FUNCTION retail.touch_updated_at();

DROP TRIGGER IF EXISTS trg_touch_sales ON retail.sales;
CREATE TRIGGER trg_touch_sales
BEFORE UPDATE ON retail.sales
FOR EACH ROW EXECUTE FUNCTION retail.touch_updated_at();

-- Views: current price & stock 

CREATE OR REPLACE VIEW retail.v_current_price AS
SELECT p.product_id,
       pr.store_id,
       (SELECT pr2.price
          FROM retail.prices pr2
         WHERE pr2.product_id = p.product_id
           AND (pr2.store_id = pr.store_id OR (pr2.store_id IS NULL AND pr.store_id IS NULL))
           AND CURRENT_DATE <@ pr2.effective
         ORDER BY lower(pr2.effective) DESC
         LIMIT 1) AS price_today, now()::date as today
       
FROM retail.products p
LEFT JOIN (SELECT DISTINCT product_id, store_id FROM retail.prices) pr
  ON pr.product_id = p.product_id;

CREATE OR REPLACE VIEW retail.v_stock AS
SELECT i.store_id, i.product_id, i.qty_on_hand, i.safety_stock, i.updated_at
FROM retail.inventory i;


COMMENT ON SCHEMA retail IS
 'SICSales: Retail operational schema, for demonstration purposes.';
