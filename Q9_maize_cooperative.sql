-- =====================================================================
-- ICT371 Advanced Database | Question 9: Farmer Cooperative Maize Deliveries
-- Dialect: PostgreSQL (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Rates per kilogram: grade A = K5, grade B = K4, grade C = K3.
-- =====================================================================

-- (a) DATABASE AND SEED DATA ------------------------------------------
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

CREATE TABLE farmers (
    farmer_id     SERIAL       PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL        PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers (farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,          -- supplied by the trigger
    total_value  NUMERIC(12,2) NOT NULL,          -- supplied by the trigger
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE          PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Chanda Mwila'),
    ('F002', 'Mutale Banda'),
    ('F003', 'Natasha Phiri');     -- will have no unpaid deliveries

-- (b) FUNCTION ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_rate NUMERIC(10,2);
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    v_rate := CASE UPPER(TRIM(p_grade))
                  WHEN 'A' THEN 5.00
                  WHEN 'B' THEN 4.00
                  WHEN 'C' THEN 3.00
              END;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;

    RETURN v_rate;
END;
$$;

SELECT fn_maize_rate('A') AS rate_a, fn_maize_rate('B') AS rate_b, fn_maize_rate('C') AS rate_c;

-- (d) TRIGGER ----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_price_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (received %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;      -- any direct SQL follows the same pricing rule
END;
$$;

CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();

-- (c) PROCEDURE --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER, p_grade VARCHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_grade IS NULL OR UPPER(TRIM(p_grade)) NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid grade: %', p_grade;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (received %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date must not be NULL';
    END IF;

    -- Basic fields only; the trigger supplies unit_rate and total_value
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, UPPER(TRIM(p_grade)), p_weight, p_date, FALSE);
END;
$$;

-- (a) CONTINUED: SIX DELIVERIES (trigger already installed) ------------
-- Direct SQL inserts: rate and total are filled in by the trigger
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 100.00, CURRENT_DATE - 3, TRUE),
    (1, 'B',  80.00, CURRENT_DATE - 1, FALSE),
    (2, 'C', 150.00, CURRENT_DATE - 1, TRUE),
    (2, 'A',  60.00, CURRENT_DATE - 2, FALSE);
-- Through the procedure
CALL pr_receive_delivery(3, 'B', 120.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(1, 'C',  40.50, CURRENT_DATE - 1);
-- Farmer 3's delivery is then marked as paid so that farmer owes nothing
UPDATE deliveries SET is_paid = TRUE WHERE farmer_id = 3;

SELECT * FROM deliveries ORDER BY delivery_id;

-- Rejected calls:
-- CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);   -- unknown farmer
-- CALL pr_receive_delivery(1, 'D', 10, CURRENT_DATE);    -- unsupported grade
-- CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);    -- non-positive weight
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
-- VALUES (1, 'A', 0, CURRENT_DATE);                      -- trigger rejects direct SQL too

-- (e) VIEW -------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- (f) INDEX ------------------------------------------------------------
-- Justification: a farmer's deliveries between two dates = equality on
-- farmer_id plus a range on delivered_on. Equality column first, range
-- column second, gives direct access to one farmer's deliveries in date order.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = off;   -- only so the plan is visible on a tiny table
EXPLAIN
SELECT *
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) SCHEDULED JOB ----------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;      -- replaced, never accumulated
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);      -- rerun: same totals
SELECT * FROM daily_purchases;

-- CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_purchases_daily',
    '30 1 * * *',                                 -- every day at 01:30
    $job$CALL pr_refresh_purchases(CURRENT_DATE - 1)$job$
);
