-- Q2 University Fee Payments (PostgreSQL)

-- (a) Tables
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL,
    fee_due DECIMAL(12, 2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount DECIMAL(12, 2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount DECIMAL(12, 2) NOT NULL,
    logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INT NOT NULL DEFAULT 0,
    total_amount DECIMAL(14, 2) NOT NULL DEFAULT 0.00
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
('S1001', 'Mwansa Banda', 5000),
('S1002', 'Chanda Phiri', 3000),
('S1003', 'Natasha Zulu', 2500);

-- (b) Function
CREATE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS DECIMAL AS $$
DECLARE v_fee DECIMAL(12, 2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student % does not exist', p_student_id;
    END IF;
    RETURN v_fee - COALESCE((SELECT SUM(amount) FROM payments WHERE student_id = p_student_id), 0);
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure (the trigger writes the audit row, not the procedure)
CREATE PROCEDURE pr_receive_payment(p_student_id INT, p_amount DECIMAL, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance DECIMAL(12, 2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be greater than zero';
    END IF;
    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment is more than the balance of %', v_balance;
    END IF;
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- (d) Trigger
CREATE FUNCTION trg_payment_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payments_insert
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_payment_audit();

-- (a) Payments (student 3 has none, student 2 pays in full)
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 500, CURRENT_DATE - 1);

SELECT student_id, fn_fee_balance(student_id) FROM students;

-- these should fail
CALL pr_receive_payment(1, 0, CURRENT_DATE);
CALL pr_receive_payment(1, 99999, CURRENT_DATE);

-- (e) View
CREATE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name, s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances;

-- (f) Index (student first, then the date range)
CREATE INDEX idx_payments_student_date ON payments (student_id, paid_on);

EXPLAIN SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_collections', '0 1 * * *', 'CALL pr_refresh_collections(CURRENT_DATE - 1)');
