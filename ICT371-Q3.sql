-- ICT371 Question 3: Library Returns and Overdue Fines (PostgreSQL)
DROP VIEW IF EXISTS v_overdue_loans;
DROP TABLE IF EXISTS loan_audit, loans, overdue_summary, books CASCADE;

-- (a) Tables and constraints
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL CHECK (due_on >= borrowed_on),
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0)
);

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0.00
);

-- (b) Function: calculate fine at K2/day
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC(10,2) LANGUAGE plpgsql AS $$
DECLARE
    v_due     DATE;
    v_ret     DATE;
    v_eff_dt  DATE;
    v_days    INT;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan ID: %', p_loan_id;
    END IF;

    v_eff_dt := CASE WHEN v_ret IS NOT NULL THEN LEAST(p_as_of, v_ret) ELSE p_as_of END;
    v_days := GREATEST(0, v_eff_dt - v_due);
    RETURN (v_days * 2.00)::NUMERIC(10,2);
END;
$$;

-- (c) Procedure: return loan and record final fine
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date cannot be NULL.';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan ID: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % has already been returned on %.', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date (%) cannot be before borrowed date (%).', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger: audit changes to returned_on
CREATE OR REPLACE FUNCTION fn_trg_loan_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_returned_audit
AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION fn_trg_loan_audit();

-- (a) Seed data: 3 books and 6 loans (open overdue, on-time, returned)
INSERT INTO books (title) VALUES
('Database System Concepts'),
('Designing Data-Intensive Applications'),
('PostgreSQL Up and Running');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
(1, 'Kelvin Banda',   CURRENT_DATE - 20, CURRENT_DATE - 6,  NULL, 0.00), -- Open overdue
(1, 'Grace Zulu',     CURRENT_DATE - 5,  CURRENT_DATE + 5,  NULL, 0.00), -- Open on-time
(2, 'Peter Lungu',    CURRENT_DATE - 15, CURRENT_DATE - 3,  NULL, 0.00), -- Open overdue
(2, 'Mary Sakala',    CURRENT_DATE - 12, CURRENT_DATE - 2,  NULL, 0.00), -- Will return via proc
(3, 'Joseph Mulenga', CURRENT_DATE - 10, CURRENT_DATE - 3,  CURRENT_DATE - 3, 0.00), -- Returned on due date
(3, 'Ruth Kaunda',    CURRENT_DATE - 3,  CURRENT_DATE + 7,  NULL, 0.00); -- Open on-time

CALL pr_return_loan(4, CURRENT_DATE);

-- (e) View: currently unreturned and overdue
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title AS book_title, l.borrower_name, l.due_on, fn_loan_fine(l.loan_id, CURRENT_DATE) AS current_fine
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index & EXPLAIN
-- Justification: Partial index on book_id WHERE returned_on IS NULL keeps the index compact
-- and directly accelerates lookups for unreturned loans of a specific book.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN ANALYZE
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1 AND returned_on IS NULL;

-- (g) Scheduled job: daily overdue snapshot
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
      AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_overdue_summary', '10 0 * * *', $$CALL pr_refresh_overdue(CURRENT_DATE);$$);
