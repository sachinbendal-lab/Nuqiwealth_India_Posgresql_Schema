-- Schema-wise stored procedures
-- Source: Procedure\partner\
CREATE SCHEMA IF NOT EXISTS "partner";

-- File: partner.sp_partner_add_client_init.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_add_client_init(
    p_partner_id    VARCHAR,
    p_name          VARCHAR,
    p_date_of_birth VARCHAR,
    p_mobile        VARCHAR,
    p_email         VARCHAR DEFAULT NULL,
    p_notes         VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_dob         TIMESTAMP;
    v_now         TIMESTAMP := NOW();
    v_cutoff      TIMESTAMP;
    v_mobile      TEXT;
    v_email       TEXT;
    v_user_id     TEXT;
    v_user_email  TEXT;
    v_dob_year    INT;
    v_dob_month   INT;
    v_dob_day     INT;
BEGIN
    IF p_name IS NULL OR regexp_replace(p_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') = '' THEN
        RAISE EXCEPTION 'Client name is required.' USING HINT = '422';
    END IF;
    IF p_date_of_birth IS NULL OR p_date_of_birth = '' THEN
        RAISE EXCEPTION 'Date of birth is required.' USING HINT = '422';
    END IF;
    IF p_date_of_birth !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        RAISE EXCEPTION 'Invalid date of birth format. Expected YYYY-MM-DD.' USING HINT = '422';
    END IF;
    -- JS: new Date('YYYY-MM-DD') (UTC midnight; impossible days roll over,
    -- e.g. 1990-02-30 → 1990-03-02; month 13 → Invalid Date)
    -- Inline JS new Date(YYYY-MM-DD): month out of 1-12 = Invalid Date (NULL), day overflow rolls
    v_dob_year  := split_part(p_date_of_birth, '-', 1)::INT;
    v_dob_month := split_part(p_date_of_birth, '-', 2)::INT;
    v_dob_day   := split_part(p_date_of_birth, '-', 3)::INT;
    IF v_dob_month < 1 OR v_dob_month > 12 THEN
        v_dob := NULL;   -- Invalid Date
    ELSE
        v_dob := make_timestamp(v_dob_year, v_dob_month, 1, 0, 0, 0)
                 + make_interval(days => v_dob_day - 1);
    END IF;
    -- JS: ageCutoff = new Date(); ageCutoff.setFullYear(year - 18)
    --     (same month/day/time; 29 Feb rolls to 1 Mar)
    v_cutoff := make_timestamp(EXTRACT(YEAR FROM v_now)::INT - 18, EXTRACT(MONTH FROM v_now)::INT, 1, 0, 0, 0)
                + (v_now - date_trunc('month', v_now));
    IF v_dob IS NULL OR v_dob > v_cutoff THEN
        RAISE EXCEPTION 'Client must be at least 18 years old.' USING HINT = '422';
    END IF;
    IF p_mobile IS NULL OR p_mobile = '' THEN
        RAISE EXCEPTION 'Mobile number is required.' USING HINT = '422';
    END IF;
    v_mobile := regexp_replace(p_mobile, '[^0-9]', '', 'g');   -- JS \D = anything but 0-9
    IF v_mobile !~ '^[0-9]{10}$' THEN
        RAISE EXCEPTION 'Invalid mobile number. Expected 10 digits.' USING HINT = '422';
    END IF;

    IF EXISTS (SELECT 1 FROM "referral".partner_client
               WHERE partner_id = p_partner_id AND mobile = v_mobile) THEN
        RAISE EXCEPTION 'A client with this mobile number already exists.' USING HINT = '409';
    END IF;

    SELECT id, email INTO v_user_id, v_user_email
    FROM "user"."user"
    WHERE phone_number = v_mobile OR phone_number = '+91' || v_mobile
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No Nuqi Wealth account found with this mobile number. The client must register on Nuqi Wealth first.'
            USING HINT = '422';
    END IF;

    -- JS: email ? email.trim().toLowerCase() : null
    --     ('' / NULL → null; whitespace-only → '' which is falsy, so no check)
    v_email := CASE WHEN p_email IS NULL OR p_email = '' THEN NULL ELSE LOWER(regexp_replace(p_email, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')) END;
    IF v_email <> '' AND (v_user_email IS NULL OR v_user_email = '' OR v_email <> LOWER(v_user_email)) THEN
        RAISE EXCEPTION 'This email does not match the Nuqi Wealth account registered with this mobile number.'
            USING HINT = '422';
    END IF;

    IF EXISTS (SELECT 1 FROM "referral".partner_client WHERE linked_user_id = v_user_id) THEN
        RAISE EXCEPTION 'This client is already linked to a partner.' USING HINT = '409';
    END IF;

    OPEN p_cursor FOR
    SELECT
        p_partner_id                                                     AS partner_id,
        v_user_id                                                        AS wealth_user_id,
        v_user_email                                                     AS wealth_email,
        regexp_replace(p_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')                                            AS name,
        p_date_of_birth                                                  AS date_of_birth,
        v_mobile                                                         AS mobile,
        v_email                                                          AS email,
        NULLIF(regexp_replace(p_notes, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), '')                               AS notes;
END;
$$;

-- File: partner.sp_partner_auth_find_by_identifier.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_auth_find_by_identifier(
    p_identifier VARCHAR,
    p_purpose    VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_clean   TEXT := LOWER(regexp_replace(COALESCE(p_identifier, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));   -- identifier.trim().toLowerCase()
    v_p       "referral".partner_user%ROWTYPE;
    v_channel TEXT;
    v_hash    TEXT;
BEGIN
    IF p_purpose NOT IN ('login', 'send_login_otp', 'verify_login_otp', 'forgot_password', 'reset_password') THEN
        RAISE EXCEPTION 'Invalid purpose.';
    END IF;

    -- Node: `!identifier` — only a missing/empty value is rejected here;
    -- whitespace-only falls through to the lookup (→ not found).
    IF COALESCE(p_identifier, '') = '' THEN
        RAISE EXCEPTION '%', CASE
            WHEN p_purpose = 'login'            THEN 'Email/mobile and password are required.'
            WHEN p_purpose = 'verify_login_otp' THEN 'Email/mobile and OTP are required.'
            WHEN p_purpose = 'reset_password'   THEN 'Email/mobile, OTP, and new password are required.'
            ELSE 'Email or mobile is required.' END;
    END IF;

    SELECT * INTO v_p
    FROM "referral".partner_user
    WHERE LOWER(email) = v_clean OR mobile = regexp_replace(p_identifier, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')   -- MySQL ci collation
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION '%', CASE
            WHEN p_purpose = 'login' THEN 'Invalid credentials.'
            WHEN p_purpose IN ('send_login_otp', 'forgot_password') THEN 'No account found with this email/mobile.'
            ELSE 'Account not found.' END;
    END IF;

    IF p_purpose IN ('login', 'send_login_otp', 'verify_login_otp') THEN
        v_channel := CASE WHEN v_p.email IS NOT NULL AND v_clean = LOWER(v_p.email)
                          THEN 'email' ELSE 'mobile' END;
    ELSE
        v_channel := CASE WHEN v_clean ~ E'^[^\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF@]+@[^\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF@]+\\.[^\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF@]+$'
                          THEN 'email' ELSE 'mobile' END;
    END IF;
    v_hash := CASE WHEN v_channel = 'email' THEN v_p.email_otp_hash ELSE v_p.mobile_otp_hash END;

    IF p_purpose = 'login' AND v_p.password_hash IS NULL THEN
        RAISE EXCEPTION 'Invalid credentials.';
    END IF;

    IF p_purpose IN ('send_login_otp', 'forgot_password') THEN
        IF v_p.password_hash IS NULL THEN
            RAISE EXCEPTION 'Please complete your registration first.';
        END IF;
        IF v_channel = 'email' AND v_p.email IS NULL THEN
            RAISE EXCEPTION 'No email on file for this account.';
        END IF;
        IF v_channel = 'mobile' AND v_p.mobile IS NULL THEN
            RAISE EXCEPTION 'No mobile number on file for this account.';
        END IF;
    END IF;

    IF p_purpose = 'verify_login_otp' AND v_hash IS NULL THEN
        RAISE EXCEPTION 'No OTP requested. Please send an OTP first.';
    END IF;
    IF p_purpose = 'reset_password' AND v_hash IS NULL THEN
        RAISE EXCEPTION 'No OTP requested. Please request a new OTP.';
    END IF;

    OPEN p_cursor FOR
    SELECT v_p.id                              AS id,
           v_p.email                           AS email,
           v_p.mobile                          AS mobile,
           COALESCE(NULLIF(v_p.mobile_prefix, ''), '+91') AS mobile_prefix,   -- mobile_prefix || "+91"
           v_p.full_name                       AS full_name,
           v_p.password_hash                   AS password_hash,
           v_p.status                          AS partner_status,
           v_p.onboarding_step                 AS onboarding_step,
           v_channel                           AS otp_channel,
           CASE WHEN v_channel = 'email' THEN v_p.email ELSE v_p.mobile END AS otp_key,
           v_hash                              AS otp_hash;
END;
$$;

-- File: partner.sp_partner_auth_forgot_password.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_auth_forgot_password(
    p_partner_id VARCHAR,
    p_channel    VARCHAR,
    p_otp_hash   VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_channel NOT IN ('email', 'mobile') THEN
        RAISE EXCEPTION 'p_channel must be email or mobile.';
    END IF;

    UPDATE "referral".partner_user SET
        email_otp_hash  = CASE WHEN p_channel = 'email'  THEN p_otp_hash ELSE email_otp_hash END,
        mobile_otp_hash = CASE WHEN p_channel = 'mobile' THEN p_otp_hash ELSE mobile_otp_hash END,
        updated_at      = NOW()
    WHERE id = p_partner_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No account found with this email/mobile.';
    END IF;

    OPEN p_cursor FOR
    SELECT id, email, mobile, email_otp_hash, mobile_otp_hash
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_auth_get_session_partner.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_auth_get_session_partner(
    p_partner_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "referral".partner_user WHERE id = p_partner_id) THEN
        RAISE EXCEPTION 'Your account no longer exists. Please contact support.'
            USING HINT = 'ACCOUNT_NOT_FOUND';
    END IF;

    OPEN p_cursor FOR
    SELECT * FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_auth_login.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_auth_login(
    p_partner_id VARCHAR,
    p_new_token  VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "referral".partner_user
    SET token = p_new_token, updated_at = NOW()
    WHERE id = p_partner_id AND password_hash IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid credentials.';
    END IF;

    OPEN p_cursor FOR
    SELECT token, status AS partner_status, full_name, email, mobile,
           COALESCE(NULLIF(mobile_prefix, ''), '+91') AS mobile_prefix, onboarding_step
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_auth_reset_password.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_auth_reset_password(
    p_partner_id        VARCHAR,
    p_channel           VARCHAR,
    p_new_password_hash VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_channel NOT IN ('email', 'mobile') THEN
        RAISE EXCEPTION 'p_channel must be email or mobile.';
    END IF;
    IF COALESCE(p_new_password_hash, '') = '' THEN
        RAISE EXCEPTION 'Email/mobile, OTP, and new password are required.';
    END IF;

    UPDATE "referral".partner_user SET
        password_hash   = p_new_password_hash,
        email_otp_hash  = CASE WHEN p_channel = 'email'  THEN NULL ELSE email_otp_hash END,
        mobile_otp_hash = CASE WHEN p_channel = 'mobile' THEN NULL ELSE mobile_otp_hash END,
        updated_at      = NOW()
    WHERE id = p_partner_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account not found.';
    END IF;

    OPEN p_cursor FOR
    SELECT TRUE AS password_reset, id
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_auth_send_login_otp.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_auth_send_login_otp(
    p_partner_id VARCHAR,
    p_channel    VARCHAR,
    p_otp_hash   VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_channel NOT IN ('email', 'mobile') THEN
        RAISE EXCEPTION 'p_channel must be email or mobile.';
    END IF;

    UPDATE "referral".partner_user SET
        email_otp_hash  = CASE WHEN p_channel = 'email'  THEN p_otp_hash ELSE email_otp_hash END,
        mobile_otp_hash = CASE WHEN p_channel = 'mobile' THEN p_otp_hash ELSE mobile_otp_hash END,
        updated_at      = NOW()
    WHERE id = p_partner_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No account found with this email/mobile.';
    END IF;

    OPEN p_cursor FOR
    SELECT id, email, mobile, email_otp_hash, mobile_otp_hash
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_auth_verify_login_otp.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_auth_verify_login_otp(
    p_partner_id VARCHAR,
    p_channel    VARCHAR,
    p_new_token  VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_channel NOT IN ('email', 'mobile') THEN
        RAISE EXCEPTION 'p_channel must be email or mobile.';
    END IF;

    UPDATE "referral".partner_user SET
        email_otp_hash  = CASE WHEN p_channel = 'email'  THEN NULL ELSE email_otp_hash END,
        mobile_otp_hash = CASE WHEN p_channel = 'mobile' THEN NULL ELSE mobile_otp_hash END,
        token           = p_new_token,
        updated_at      = NOW()
    WHERE id = p_partner_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account not found.';
    END IF;

    OPEN p_cursor FOR
    SELECT token, status AS partner_status, full_name, email, mobile,
           COALESCE(NULLIF(mobile_prefix, ''), '+91') AS mobile_prefix, onboarding_step
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_commission_generate_invoice.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_commission_generate_invoice(
    p_partner_id VARCHAR,
    p_apply_gst  BOOLEAN DEFAULT FALSE,
    p_period     VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_apply_gst   BOOLEAN := COALESCE(p_apply_gst, FALSE);
    v_start       TIMESTAMP;
    v_end         TIMESTAMP;
    v_commission  NUMERIC;
    v_comm_f      DOUBLE PRECISION;
    v_gst_f       DOUBLE PRECISION;
    v_gst         NUMERIC;
    v_total       NUMERIC;
    v_count       INT;
    v_number      TEXT;
    v_new_id      TEXT;
    v_cyc_current TIMESTAMP;
    v_cyc_match   TEXT[];
    v_cyc_year    INT;
    v_cyc_month   INT;
BEGIN
    IF p_partner_id IS NULL THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;

    -- 1. Billing cycle — fn_pcm_cycle_start inlined
    v_cyc_current := DATE_TRUNC('month', NOW());
    IF p_period IS NULL OR p_period = '' THEN
        v_start := v_cyc_current;
    ELSE
        v_cyc_match := regexp_match(p_period, '^([0-9]{4})-([0-9]{2})$');
        IF v_cyc_match IS NULL THEN
            RAISE EXCEPTION 'Invalid or future period. Use YYYY-MM.';
        END IF;
        v_cyc_year  := v_cyc_match[1]::INT;
        v_cyc_month := v_cyc_match[2]::INT;
        IF v_cyc_month < 1 OR v_cyc_month > 12 THEN
            RAISE EXCEPTION 'Invalid or future period. Use YYYY-MM.';
        END IF;
        IF v_cyc_year BETWEEN 0 AND 99 THEN
            v_cyc_year := v_cyc_year + 1900;
        END IF;
        v_start := MAKE_TIMESTAMP(v_cyc_year, v_cyc_month, 1, 0, 0, 0);
        IF v_start > v_cyc_current THEN
            RAISE EXCEPTION 'Invalid or future period. Use YYYY-MM.';
        END IF;
    END IF;
    v_end   := v_start + INTERVAL '1 month' - INTERVAL '1 millisecond';

    -- 2. Block duplicate invoice for this cycle
    IF EXISTS (
        SELECT 1 FROM "referral".partner_invoice
        WHERE partner_id = p_partner_id AND cycle_start = v_start
    ) THEN
        RAISE EXCEPTION 'Invoice already generated for this billing cycle.';
    END IF;

    -- 3. Block if no commission
    SELECT COALESCE(SUM(commission_amount), 0) INTO v_commission
    FROM "referral".partner_commission_ledger
    WHERE partner_id = p_partner_id
      AND created_at BETWEEN v_start AND v_end;

    IF v_commission <= 0 THEN
        RAISE EXCEPTION 'No commission earned in this billing cycle.';
    END IF;

    -- 4. Amounts — JS float maths, exactly as Node:
    --    gstAmount   = apply_gst ? Math.round(commissionAmount * 0.18 * 100) / 100 : 0
    --    totalAmount = Math.round((commissionAmount + gstAmount) * 100) / 100
    --    (Math.round(v) = floor(v + 0.5); products done in double precision)
    v_comm_f := v_commission::DOUBLE PRECISION;
    v_gst_f  := CASE WHEN v_apply_gst
                     THEN floor(v_comm_f * 0.18::DOUBLE PRECISION * 100::DOUBLE PRECISION + 0.5::DOUBLE PRECISION)
                          / 100::DOUBLE PRECISION
                     ELSE 0 END;
    v_gst    := v_gst_f::NUMERIC;
    v_total  := (floor((v_comm_f + v_gst_f) * 100::DOUBLE PRECISION + 0.5::DOUBLE PRECISION)
                 / 100::DOUBLE PRECISION)::NUMERIC;

    -- 5. Invoice number
    SELECT COUNT(*) INTO v_count
    FROM "referral".partner_invoice WHERE partner_id = p_partner_id;

    v_number := 'INV-' || TO_CHAR(v_start, 'YYYYMM') || '-' || LPAD((v_count + 1)::TEXT, 4, '0');
    v_new_id := 'c' || replace(gen_random_uuid()::text, '-', '');

    INSERT INTO "referral".partner_invoice
        (id, partner_id, invoice_number, cycle_start, cycle_end, commission_amount,
         gst_applied, gst_amount, total_amount, status, created_at)
    VALUES
        (v_new_id, p_partner_id, v_number, v_start, v_end, v_commission,
         v_apply_gst, v_gst, v_total, 'pending', NOW());

    OPEN p_cursor FOR
    SELECT
        i.id, i.partner_id, i.invoice_number, i.cycle_start, i.cycle_end,
        i.commission_amount, i.gst_applied, i.gst_amount, i.total_amount,
        i.status, i.paid_at, i.created_at,
        p.full_name AS partner_full_name,
        p.email     AS partner_email
    FROM "referral".partner_invoice i
    LEFT JOIN "referral".partner_user p ON p.id = i.partner_id
    WHERE i.id = v_new_id;
END;
$$;

-- File: partner.sp_partner_commission_get_current_cycle.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_commission_get_current_cycle(
    p_partner_id VARCHAR,
    p_period     VARCHAR DEFAULT NULL,
    INOUT p_summary refcursor DEFAULT 'summary_cursor',
    INOUT p_entries refcursor DEFAULT 'entries_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_start       TIMESTAMP;
    v_end         TIMESTAMP;
    v_total       NUMERIC;
    v_cyc_current TIMESTAMP;
    v_cyc_match   TEXT[];
    v_cyc_year    INT;
    v_cyc_month   INT;
BEGIN
    IF p_partner_id IS NULL THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;

    -- Billing cycle (cycleForPeriod / cycleForNow) — fn_pcm_cycle_start inlined
    v_cyc_current := DATE_TRUNC('month', NOW());
    IF p_period IS NULL OR p_period = '' THEN
        v_start := v_cyc_current;
    ELSE
        v_cyc_match := regexp_match(p_period, '^([0-9]{4})-([0-9]{2})$');
        IF v_cyc_match IS NULL THEN
            RAISE EXCEPTION 'Invalid or future period. Use YYYY-MM.';
        END IF;
        v_cyc_year  := v_cyc_match[1]::INT;
        v_cyc_month := v_cyc_match[2]::INT;
        IF v_cyc_month < 1 OR v_cyc_month > 12 THEN
            RAISE EXCEPTION 'Invalid or future period. Use YYYY-MM.';
        END IF;
        IF v_cyc_year BETWEEN 0 AND 99 THEN
            v_cyc_year := v_cyc_year + 1900;
        END IF;
        v_start := MAKE_TIMESTAMP(v_cyc_year, v_cyc_month, 1, 0, 0, 0);
        IF v_start > v_cyc_current THEN
            RAISE EXCEPTION 'Invalid or future period. Use YYYY-MM.';
        END IF;
    END IF;
    v_end   := v_start + INTERVAL '1 month' - INTERVAL '1 millisecond';

    SELECT COALESCE(SUM(commission_amount), 0) INTO v_total
    FROM "referral".partner_commission_ledger
    WHERE partner_id = p_partner_id
      AND created_at BETWEEN v_start AND v_end;

    OPEN p_summary FOR
    SELECT
        v_start                 AS cycle_start,
        v_end                   AS cycle_end,
        v_total                 AS commission_amount,
        (v_total > 0)           AS has_commission,
        (inv.id IS NOT NULL)    AS invoice_generated,
        inv.id                  AS invoice_id,
        inv.invoice_number,
        inv.commission_amount   AS invoice_commission_amount,
        inv.gst_applied,
        inv.gst_amount,
        inv.total_amount,
        inv.status              AS invoice_status,
        inv.paid_at,
        inv.created_at          AS invoice_created_at
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (
        SELECT * FROM "referral".partner_invoice
        WHERE partner_id = p_partner_id AND cycle_start = v_start
        ORDER BY created_at
        LIMIT 1
    ) inv ON TRUE;

    OPEN p_entries FOR
    SELECT
        COALESCE(pc.name, '-')  AS client_name,
        l.transaction_type,
        l.transaction_amount,
        l.commission_rate,
        l.commission_amount,
        l.created_at            AS date
    FROM "referral".partner_commission_ledger l
    LEFT JOIN "referral".partner_client pc ON pc.id = l.client_id
    WHERE l.partner_id = p_partner_id
      AND l.created_at BETWEEN v_start AND v_end
    ORDER BY l.created_at DESC;
END;
$$;

-- File: partner.sp_partner_commission_get_invoice_for_download.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_commission_get_invoice_for_download(
    p_partner_id VARCHAR,
    p_invoice_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_partner_id IS NULL THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM "referral".partner_invoice
        WHERE id = p_invoice_id AND partner_id = p_partner_id
    ) THEN
        RAISE EXCEPTION 'Invoice not found';
    END IF;

    OPEN p_cursor FOR
    SELECT
        i.id, i.partner_id, i.invoice_number, i.cycle_start, i.cycle_end,
        i.commission_amount, i.gst_applied, i.gst_amount, i.total_amount,
        i.status, i.paid_at, i.created_at,
        p.full_name AS partner_full_name,
        p.email     AS partner_email,
        p.mobile    AS partner_mobile
    FROM "referral".partner_invoice i
    LEFT JOIN "referral".partner_user p ON p.id = i.partner_id
    WHERE i.id = p_invoice_id AND i.partner_id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_commission_get_invoices.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_commission_get_invoices(
    p_partner_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_partner_id IS NULL THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;

    OPEN p_cursor FOR
    SELECT
        id, partner_id, invoice_number, cycle_start, cycle_end,
        commission_amount, gst_applied, gst_amount, total_amount,
        status, paid_at, created_at
    FROM "referral".partner_invoice
    WHERE partner_id = p_partner_id
    ORDER BY created_at DESC;
END;
$$;

-- File: partner.sp_partner_get_act_as_token.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_act_as_token(
    p_partner_id VARCHAR,
    p_client_id  VARCHAR,
    p_redirect   VARCHAR DEFAULT '/mutual-funds',
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    -- JS: const { redirect = "/mutual-funds" } = req.body — the default applies
    -- only when redirect is missing (omit the argument → DEFAULT). An explicit
    -- null is NOT in the allowed list → 400, same as Node.
    v_redirect TEXT := p_redirect;
    v_linked   TEXT;
    v_name     TEXT;
BEGIN
    IF v_redirect IS NULL OR v_redirect NOT IN ('/mutual-funds', '/curated-baskets', '/portfolio', '/dashboard') THEN
        RAISE EXCEPTION 'Invalid redirect destination.' USING HINT = '400';
    END IF;

    SELECT linked_user_id, name INTO v_linked, v_name
    FROM "referral".partner_client
    WHERE id = p_client_id AND partner_id = p_partner_id
      AND status IN ('active', 'kyc_pending');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Active client not found.' USING HINT = '404';
    END IF;
    IF v_linked IS NULL OR v_linked = '' THEN
        RAISE EXCEPTION 'Client does not have a linked Nuqi Wealth account.' USING HINT = '400';
    END IF;

    OPEN p_cursor FOR
    SELECT p_client_id AS client_id, v_name AS name, v_linked AS wealth_user_id,
           p_partner_id AS partner_id, v_redirect AS redirect;
END;
$$;

-- File: partner.sp_partner_get_client_cep_orders.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_client_cep_orders(
    p_partner_id VARCHAR,
    p_client_id  VARCHAR,
    p_page       INT DEFAULT 1,
    p_limit      INT DEFAULT 20,
    INOUT p_orders     refcursor DEFAULT 'orders_cursor',
    INOUT p_children   refcursor DEFAULT 'children_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page   INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit  INT := LEAST(COALESCE(NULLIF(p_limit, 0), 20), 100);
    v_linked TEXT;
    v_total  INT;
    v_ids    TEXT[];
BEGIN
    SELECT linked_user_id INTO v_linked
    FROM "referral".partner_client
    WHERE id = p_client_id AND partner_id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client not found' USING HINT = '404';
    END IF;
    IF v_linked IS NULL OR v_linked = '' THEN
        RAISE EXCEPTION 'Client account not yet linked.' USING HINT = '400';
    END IF;

    SELECT COUNT(*) INTO v_total
    FROM "trade"."transaction"
    WHERE user_ref_id = v_linked AND cep_ref_id IS NOT NULL AND parent_transaction_id IS NULL;

    SELECT ARRAY_AGG(id ORDER BY created_at DESC, id) INTO v_ids
    FROM (SELECT id, created_at FROM "trade"."transaction"
          WHERE user_ref_id = v_linked AND cep_ref_id IS NOT NULL AND parent_transaction_id IS NULL
          ORDER BY created_at DESC, id
          LIMIT v_limit OFFSET (v_page - 1) * v_limit) pg;

    OPEN p_orders FOR
    SELECT
        p.id,
        p.cep_ref_id,
        CASE p.transaction_type::TEXT WHEN 'BUY' THEN 'BUY' WHEN 'SELL' THEN 'EXIT'
             ELSE p.transaction_type::TEXT END                        AS action,
        COALESCE((SELECT SUM(COALESCE(c.average_price, 0)::DOUBLE PRECISION * c.filled_quantity::DOUBLE PRECISION)
                  FROM "trade"."transaction" c WHERE c.parent_transaction_id = p.id), 0) AS amount,
        LOWER(COALESCE(p.status::TEXT, ''))                           AS status,
        p.created_at                                                  AS date,
        (SELECT COUNT(*) FROM "trade"."transaction" c WHERE c.parent_transaction_id = p.id)::INT AS stocks_count
    FROM "trade"."transaction" p
    WHERE p.id = ANY(COALESCE(v_ids, '{}'))
    ORDER BY p.created_at DESC, p.id;

    OPEN p_children FOR
    SELECT
        c.parent_transaction_id                                       AS parent_id,
        c.id,
        COALESCE(NULLIF(c.trading_symbol, ''), c.scripcode)           AS stock_name,
        c.transaction_type::TEXT                                      AS action,
        c.filled_quantity::DOUBLE PRECISION                           AS quantity,
        COALESCE(c.average_price, 0)::DOUBLE PRECISION                AS price,
        COALESCE(c.average_price, 0)::DOUBLE PRECISION * c.filled_quantity::DOUBLE PRECISION AS amount,
        LOWER(COALESCE(c.status::TEXT, ''))                           AS status
    FROM "trade"."transaction" c
    WHERE c.parent_transaction_id = ANY(COALESCE(v_ids, '{}'))
    ORDER BY c.parent_transaction_id, c.created_at, c.id;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_get_client_detail.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_client_detail(
    p_partner_id VARCHAR,
    p_client_id  VARCHAR,
    INOUT p_client           refcursor DEFAULT 'client_cursor',
    INOUT p_portfolio_mf     refcursor DEFAULT 'portfolio_mf_cursor',
    INOUT p_portfolio_ceps   refcursor DEFAULT 'portfolio_ceps_cursor',
    INOUT p_portfolio_totals refcursor DEFAULT 'portfolio_totals_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_user_id TEXT;
BEGIN
    SELECT u.id INTO v_user_id
    FROM "referral".partner_client pc
    LEFT JOIN "user"."user" u ON u.id = pc.linked_user_id
    WHERE pc.id = p_client_id AND pc.partner_id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client not found' USING HINT = '404';
    END IF;

    OPEN p_client FOR
    WITH b AS (
        SELECT pc.*, u.id AS user_id, u.email AS user_email, u.phone_number,
               u.is_risk_verified,
               CASE WHEN k.status = 'auto_approved' THEN 'APPROVED' ELSE NULLIF(k.status, '') END AS kyc_status,
               k."panNumber" AS pan, k."verifiedAt" AS verified_at,
               bk.status::TEXT AS bank_kyc_status, bk."bankName" AS bank_name,
               urp.total_score, urp.is_active AS risk_active, g.risk_level,
               us.subscription_status::TEXT AS subscription_status,
               us.transaction_status::TEXT  AS sub_txn_status,
               us.plan_name, us.start_date, us.end_date,
               mo.onboarding_status, mo.current_step,
               (mo.step1_completed::INT + mo.step2_completed::INT + mo.step3_completed::INT +
                mo.step4_completed::INT + mo.step5_completed::INT + mo.step6_completed::INT +
                mo.step7_completed::INT) AS steps_completed,
               mu.client_code, mu.ucc_status, mu.fatca_status, mu.client_auth_status
        FROM "referral".partner_client pc
        LEFT JOIN "user"."user" u ON u.id = pc.linked_user_id
        LEFT JOIN LATERAL (SELECT status, "panNumber", "verifiedAt" FROM "kyc".kyc WHERE "userId" = u.id LIMIT 1) k ON TRUE
        LEFT JOIN LATERAL (SELECT status, "bankName" FROM "kyc".bankkyc WHERE user_ref = u.id LIMIT 1) bk ON TRUE
        LEFT JOIN LATERAL (SELECT total_score, is_active, risk_profile_id FROM "catalog".userriskprofile WHERE user_id = u.id LIMIT 1) urp ON TRUE
        LEFT JOIN "catalog".riskprofilescoregrid g ON g.id = urp.risk_profile_id
        LEFT JOIN LATERAL (
            SELECT subscription_status, transaction_status, plan_name, start_date, end_date
            FROM "payments".usersubscription
            WHERE user_ref_id = u.id AND subscription_status = 'ACTIVE'
            ORDER BY created_at DESC LIMIT 1
        ) us ON TRUE
        LEFT JOIN LATERAL (SELECT * FROM "trade".nse_mf_onboarding WHERE user_ref_id = u.id LIMIT 1) mo ON TRUE
        LEFT JOIN LATERAL (SELECT client_code, ucc_status, fatca_status, client_auth_status FROM "trade".nse_mf_ucc WHERE user_ref_id = u.id LIMIT 1) mu ON TRUE
        WHERE pc.id = p_client_id AND pc.partner_id = p_partner_id
    ),
    d AS (
        SELECT b.*,
            COALESCE(b.user_id IS NOT NULL AND b.kyc_status = 'APPROVED', FALSE)     AS kyc_done,
            (b.bank_kyc_status = 'APPROVED') IS TRUE                                 AS bank_done,
            (COALESCE(b.is_risk_verified, FALSE) OR COALESCE(b.risk_active, FALSE))  AS risk_done,
            (b.subscription_status = 'ACTIVE'
             OR (b.sub_txn_status = 'SUCCESS' AND b.end_date > NOW())) IS TRUE       AS sub_done,
            b.onboarding_status IN ('COMPLETED', 'SUBMITTED') IS TRUE                AS mf_done,
            (b.ucc_status IN ('REGISTERED', 'REG_SUCCESS', 'APPROVED')
             AND b.fatca_status IN ('SUBMITTED', 'REG_SUCCESS', 'APPROVED')
             AND b.client_auth_status = 'AUTHORIZED') IS TRUE                        AS ucc_done
        FROM b
    )
    SELECT
        d.id, d.name,
        COALESCE(NULLIF(d.email, ''),  NULLIF(d.user_email, ''))   AS email,
        COALESCE(NULLIF(d.mobile, ''), NULLIF(d.phone_number, '')) AS mobile,
        NULLIF(d.date_of_birth, '')                                AS date_of_birth,
        CASE WHEN d.user_id IS NOT NULL AND d.status IN ('active', 'kyc_pending')
             THEN CASE WHEN d.kyc_done THEN 'active' ELSE 'kyc_pending' END
             ELSE d.status END                                     AS status,
        d.kyc_status,
        d.kyc_done                                                 AS kyc_verified,
        d.linked_user_id, d.notes, d.source, d.created_at,
        CASE
            WHEN NOT d.kyc_done  THEN 'kyc_pending'
            WHEN NOT d.bank_done THEN 'bank_kyc_pending'
            WHEN NOT d.risk_done THEN 'risk_pending'
            WHEN NOT d.sub_done  THEN 'plan_pending'
            WHEN NOT d.mf_done   THEN 'mf_onboarding_pending'
            ELSE 'fully_onboarded'
        END                                                        AS current_phase,
        d.kyc_done,
        CASE WHEN NULLIF(d.pan, '') IS NOT NULL THEN '*****' || RIGHT(d.pan, 5) END AS kyc_pan,
        d.verified_at                                              AS kyc_verified_at,
        d.bank_kyc_status, d.bank_done                             AS bank_kyc_done,
        NULLIF(d.bank_name, '')                                    AS bank_name,       -- JS: x || null
        d.risk_done, NULLIF(d.risk_level, '')                      AS risk_level,
        NULLIF(d.total_score, 0)                                   AS risk_score,
        d.subscription_status, d.sub_done                          AS subscription_done,
        NULLIF(d.plan_name, '')                                    AS plan_name,
        d.start_date AS subscription_start_date, d.end_date AS subscription_end_date,
        NULLIF(d.onboarding_status, '')                            AS mf_onboarding_status,
        d.mf_done                                                  AS mf_onboarding_done,
        NULLIF(d.current_step, 0)                                  AS mf_current_step,
        7                                                          AS mf_total_steps,
        COALESCE(d.steps_completed, 0)                             AS mf_steps_completed,
        NULLIF(d.ucc_status, '')         AS ucc_status,
        NULLIF(d.fatca_status, '')       AS fatca_status,
        NULLIF(d.client_auth_status, '') AS client_auth_status,
        d.ucc_done,
        NULLIF(d.client_code, '')        AS client_code
    FROM d;

    -- JS: key = o.scheme_code || "unknown"; rows come out in JS object key
    -- order (integer-like keys first, numerically), see fn_pc_js_key_index.
    OPEN p_portfolio_mf FOR
    SELECT x.scheme_code, x.invested_amount
    FROM (
        SELECT COALESCE(NULLIF(o.scheme_code, ''), 'unknown') AS scheme_code,
               SUM(COALESCE(NULLIF(
        substring(regexp_replace(o.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')
          FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::DOUBLE PRECISION,
        0::DOUBLE PRECISION), 0::DOUBLE PRECISION))                   AS invested_amount,
               MIN(o.created_at)                              AS first_seen
        FROM "trade".nse_mf_order o
        WHERE v_user_id IS NOT NULL
          AND o.user_ref_id  = v_user_id
          AND o.trade_type   IN ('LUMPSUM', 'SIP')
          AND o.order_status IN ('COMPLETED', 'ALLOTMENT_DONE', 'SUCCESS')
        GROUP BY COALESCE(NULLIF(o.scheme_code, ''), 'unknown')
    ) x
    ORDER BY (CASE WHEN x.scheme_code ~ '^(0|[1-9][0-9]{0,9})$' AND x.scheme_code::NUMERIC < 4294967295 THEN x.scheme_code::NUMERIC END) IS NULL, CASE WHEN x.scheme_code ~ '^(0|[1-9][0-9]{0,9})$' AND x.scheme_code::NUMERIC < 4294967295 THEN x.scheme_code::NUMERIC END, x.first_seen;

    -- JS: key = t.cep_ref_id || t.id; the FIRST transaction of a key sets
    -- name = cepNameMap[cep_ref_id] || description || cep_ref_id || "CEP Basket"
    -- (fallback_name below = everything after the Market lookup).
    OPEN p_portfolio_ceps FOR
    SELECT x.basket_key, x.cep_ref_id, x.fallback_name, x.invested_amount
    FROM (
        SELECT
            COALESCE(NULLIF(p.cep_ref_id, ''), p.id)                   AS basket_key,
            (ARRAY_AGG(NULLIF(p.cep_ref_id, '') ORDER BY p.created_at, p.id))[1] AS cep_ref_id,
            (ARRAY_AGG(COALESCE(NULLIF(p.description, ''), NULLIF(p.cep_ref_id, ''), 'CEP Basket')
                       ORDER BY p.created_at, p.id))[1]                AS fallback_name,
            COALESCE(SUM((SELECT SUM(COALESCE(c.average_price, 0)::DOUBLE PRECISION * c.filled_quantity::DOUBLE PRECISION)
                          FROM "trade"."transaction" c
                          WHERE c.parent_transaction_id = p.id)), 0)   AS invested_amount,
            MIN(p.created_at)                                          AS first_seen
        FROM "trade"."transaction" p
        WHERE v_user_id IS NOT NULL
          AND p.user_ref_id           = v_user_id
          AND p.asset                 = 'CEP'
          AND p.status                = 'COMPLETED'
          AND p.transaction_type      = 'BUY'
          AND p.parent_transaction_id IS NULL
        GROUP BY COALESCE(NULLIF(p.cep_ref_id, ''), p.id)
    ) x
    ORDER BY (CASE WHEN x.basket_key ~ '^(0|[1-9][0-9]{0,9})$' AND x.basket_key::NUMERIC < 4294967295 THEN x.basket_key::NUMERIC END) IS NULL, CASE WHEN x.basket_key ~ '^(0|[1-9][0-9]{0,9})$' AND x.basket_key::NUMERIC < 4294967295 THEN x.basket_key::NUMERIC END, x.first_seen;

    OPEN p_portfolio_totals FOR
    SELECT mf AS total_mf_aum, cep AS total_ceps_aum, mf + cep AS total_aum
    FROM (SELECT CASE WHEN v_user_id IS NULL THEN 0 ELSE (SELECT COALESCE(SUM(COALESCE(NULLIF(
        substring(regexp_replace(o.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')
          FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::DOUBLE PRECISION,
        0::DOUBLE PRECISION), 0::DOUBLE PRECISION)), 0)
             FROM "trade".nse_mf_order o
             WHERE o.user_ref_id = v_user_id
               AND o.order_status IN ('COMPLETED', 'ALLOTMENT_DONE', 'SUCCESS')
               AND o.trade_type   IN ('LUMPSUM', 'SIP')) END AS mf,
                 CASE WHEN v_user_id IS NULL THEN 0 ELSE (SELECT COALESCE(SUM(COALESCE(c.average_price, 0)::DOUBLE PRECISION * c.filled_quantity::DOUBLE PRECISION), 0)
             FROM "trade"."transaction" p
             JOIN "trade"."transaction" c ON c.parent_transaction_id = p.id
             WHERE p.user_ref_id           = v_user_id
               AND p.asset                 = 'CEP'
               AND p.transaction_type      = 'BUY'
               AND p.status                = 'COMPLETED'
               AND p.parent_transaction_id IS NULL) END AS cep) x;
END;
$$;

-- File: partner.sp_partner_get_client_mf_holdings.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_client_mf_holdings(
    p_partner_id VARCHAR,
    p_client_id  VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor',
    INOUT p_total  refcursor DEFAULT 'total_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_linked TEXT;
BEGIN
    SELECT linked_user_id INTO v_linked
    FROM "referral".partner_client
    WHERE id = p_client_id AND partner_id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client not found' USING HINT = '404';
    END IF;
    IF v_linked IS NULL OR v_linked = '' THEN
        RAISE EXCEPTION 'Client account not yet linked.' USING HINT = '400';
    END IF;

    -- JS: key = o.scheme_code || "unknown" (returned as scheme_code);
    -- folio = folio_no of the first order of that key; rows in JS
    -- object key order (integer-like keys first, numerically).
    OPEN p_cursor FOR
    SELECT x.scheme_code, x.folio_number, x.units, x.invested_value, x.current_value
    FROM (
        SELECT
            COALESCE(NULLIF(o.scheme_code, ''), 'unknown')             AS scheme_code,
            (ARRAY_AGG(o.folio_no ORDER BY o.created_at, o.id))[1]     AS folio_number,
            NULL::DOUBLE PRECISION                                     AS units,
            SUM(COALESCE(NULLIF(
        substring(regexp_replace(o.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')
          FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::DOUBLE PRECISION,
        0::DOUBLE PRECISION), 0::DOUBLE PRECISION))                               AS invested_value,
            SUM(COALESCE(NULLIF(
        substring(regexp_replace(o.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')
          FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::DOUBLE PRECISION,
        0::DOUBLE PRECISION), 0::DOUBLE PRECISION))                               AS current_value,
            MIN(o.created_at)                                          AS first_seen
        FROM "trade".nse_mf_order o
        WHERE o.user_ref_id  = v_linked
          AND o.trade_type   IN ('LUMPSUM', 'SIP')
          AND o.order_status IN ('COMPLETED', 'ALLOTMENT_DONE', 'SUCCESS')
        GROUP BY COALESCE(NULLIF(o.scheme_code, ''), 'unknown')
    ) x
    ORDER BY (CASE WHEN x.scheme_code ~ '^(0|[1-9][0-9]{0,9})$' AND x.scheme_code::NUMERIC < 4294967295 THEN x.scheme_code::NUMERIC END) IS NULL, CASE WHEN x.scheme_code ~ '^(0|[1-9][0-9]{0,9})$' AND x.scheme_code::NUMERIC < 4294967295 THEN x.scheme_code::NUMERIC END, x.first_seen;

    OPEN p_total FOR
    SELECT (SELECT COALESCE(SUM(COALESCE(NULLIF(
        substring(regexp_replace(o.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')
          FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::DOUBLE PRECISION,
        0::DOUBLE PRECISION), 0::DOUBLE PRECISION)), 0)
             FROM "trade".nse_mf_order o
             WHERE o.user_ref_id = v_linked
               AND o.order_status IN ('COMPLETED', 'ALLOTMENT_DONE', 'SUCCESS')
               AND o.trade_type   IN ('LUMPSUM', 'SIP')) AS total_value;
END;
$$;

-- File: partner.sp_partner_get_client_mf_orders.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_client_mf_orders(
    p_partner_id VARCHAR,
    p_client_id  VARCHAR,
    p_page       INT     DEFAULT 1,
    p_limit      INT     DEFAULT 20,
    p_type       VARCHAR DEFAULT NULL,
    p_status     VARCHAR DEFAULT NULL,
    INOUT p_cursor     refcursor DEFAULT 'result_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page   INT  := COALESCE(NULLIF(p_page, 0), 1);
    v_limit  INT  := LEAST(COALESCE(NULLIF(p_limit, 0), 20), 100);
    v_type   TEXT := UPPER(NULLIF(p_type, ''));
    v_status TEXT := UPPER(NULLIF(p_status, ''));
    v_linked TEXT;
    v_total  INT;
BEGIN
    SELECT linked_user_id INTO v_linked
    FROM "referral".partner_client
    WHERE id = p_client_id AND partner_id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client not found' USING HINT = '404';
    END IF;
    IF v_linked IS NULL OR v_linked = '' THEN
        RAISE EXCEPTION 'Client account not yet linked.' USING HINT = '400';
    END IF;

    SELECT COUNT(*) INTO v_total
    FROM "trade".nse_mf_order
    WHERE user_ref_id = v_linked
      AND (v_type   IS NULL OR trade_type   = v_type)
      AND (v_status IS NULL OR order_status = v_status);

    OPEN p_cursor FOR
    SELECT
        o.id,
        o.trade_type                                     AS type,
        o.scheme_code,
        o.amc_code,
        COALESCE(NULLIF(
        substring(regexp_replace(o.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')
          FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::DOUBLE PRECISION,
        0::DOUBLE PRECISION), 0::DOUBLE PRECISION)                          AS amount,
        NULL::NUMERIC                                    AS units,
        NULL::NUMERIC                                    AS nav,
        o.nse_order_id,
        o.nse_status,
        o.folio_no                                       AS folio_number,
        LOWER(COALESCE(NULLIF(o.order_status, ''), NULLIF(o.nse_status, ''), 'pending')) AS status,
        o.frequency_type                                 AS frequency,
        o.start_date,
        o.end_date,
        o.created_at                                     AS date
    FROM "trade".nse_mf_order o
    WHERE o.user_ref_id = v_linked
      AND (v_type   IS NULL OR o.trade_type   = v_type)
      AND (v_status IS NULL OR o.order_status = v_status)
    ORDER BY o.created_at DESC, o.id
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_get_client_sip_registrations.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_client_sip_registrations(
    p_partner_id VARCHAR,
    p_client_id  VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_linked TEXT;
BEGIN
    SELECT linked_user_id INTO v_linked
    FROM "referral".partner_client
    WHERE id = p_client_id AND partner_id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client not found' USING HINT = '404';
    END IF;
    IF v_linked IS NULL OR v_linked = '' THEN
        RAISE EXCEPTION 'Client account not yet linked.' USING HINT = '400';
    END IF;

    OPEN p_cursor FOR
    SELECT
        s.id,
        s.scheme_code,
        COALESCE(NULLIF(
        substring(regexp_replace(s.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')
          FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::DOUBLE PRECISION,
        0::DOUBLE PRECISION), 0::DOUBLE PRECISION)                                             AS amount,
        COALESCE(NULLIF(s.frequency_type, ''), 'MONTHLY')                   AS frequency,
        s.start_date,
        s.end_date,
        (SELECT CASE
    WHEN t IS NULL OR t = '' THEN 0::NUMERIC
    WHEN t ~* '^[+-]?0x[0-9a-f]+' THEN
        (CASE WHEN left(t,1)='-' THEN -1 ELSE 1 END)::NUMERIC *
        (('x'||substring(t FROM '(?i)0x([0-9a-f]+)'))::bit(64)::bigint)::NUMERIC
    WHEN t ~ '^[+-]?[0-9]' THEN
        (CASE WHEN left(t,1)='-' THEN -1 ELSE 1 END)::NUMERIC *
        substring(t FROM '^[+-]?([0-9]+)')::NUMERIC
    ELSE 0::NUMERIC
 END
 FROM (SELECT regexp_replace(s.installment_no, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS t) _jpi)                                     AS installments_total,  -- parseInt(x) || 0
        s.nse_order_id,
        s.sip_mandate_id                                                    AS mandate_id,
        COALESCE(NULLIF(m.bank_status, ''), NULLIF(m.mandate_status, ''))   AS mandate_status,
        LOWER(COALESCE(NULLIF(s.order_status, ''), NULLIF(s.nse_status, ''), 'pending')) AS status
    FROM "trade".nse_mf_order s
    LEFT JOIN LATERAL (
        SELECT bank_status, mandate_status
        FROM "trade".nse_mf_mandate
        WHERE user_ref_id = v_linked
          AND NULLIF(s.sip_mandate_id, '') IS NOT NULL
          AND reg_id = s.sip_mandate_id
        ORDER BY created_at DESC
        LIMIT 1
    ) m ON TRUE
    WHERE s.user_ref_id = v_linked AND s.trade_type = 'SIP'
    ORDER BY s.created_at DESC, s.id;
END;
$$;

-- File: partner.sp_partner_get_client_transactions.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_client_transactions(
    p_partner_id VARCHAR,
    p_client_id  VARCHAR,
    p_page       INT DEFAULT 1,
    p_limit      INT DEFAULT 20,
    INOUT p_cursor     refcursor DEFAULT 'result_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page   INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit  INT := COALESCE(NULLIF(p_limit, 0), 20);
    v_linked TEXT;
    v_total  INT := 0;
BEGIN
    SELECT linked_user_id INTO v_linked
    FROM "referral".partner_client
    WHERE id = p_client_id AND partner_id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client not found' USING HINT = '404';
    END IF;
    v_linked := NULLIF(v_linked, '');

    IF v_linked IS NOT NULL THEN
        SELECT COUNT(*) INTO v_total FROM "trade"."transaction" WHERE user_ref_id = v_linked;
    END IF;

    OPEN p_cursor FOR
    SELECT
        t.id,
        t.transaction_type::TEXT                         AS type,
        COALESCE(NULLIF(t.trading_symbol, ''), t.scripcode) AS fund_name,
        -- JS float maths: Number(avg || 0) * Number(qty)
        CASE WHEN t.asset = 'CEP'
             THEN (SELECT COALESCE(SUM(COALESCE(c.average_price, 0)::DOUBLE PRECISION * c.filled_quantity::DOUBLE PRECISION), 0)
                   FROM "trade"."transaction" c WHERE c.parent_transaction_id = t.id)
             ELSE COALESCE(t.average_price, 0)::DOUBLE PRECISION * t.quantity::DOUBLE PRECISION
        END                                              AS amount,
        t.quantity::DOUBLE PRECISION                     AS quantity,
        COALESCE(t.average_price, 0)::DOUBLE PRECISION   AS price,
        t.asset                                          AS asset_type,
        t.status::TEXT                                   AS status,
        t.created_at                                     AS date
    FROM "trade"."transaction" t
    WHERE v_linked IS NOT NULL AND t.user_ref_id = v_linked
    ORDER BY t.created_at DESC, t.id
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_get_clients.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_clients(
    p_partner_id VARCHAR,
    p_page       INT     DEFAULT 1,
    p_limit      INT     DEFAULT 20,
    p_search     VARCHAR DEFAULT NULL,
    p_status     VARCHAR DEFAULT NULL,
    p_product    VARCHAR DEFAULT NULL,
    p_sort_by    VARCHAR DEFAULT NULL,
    p_sort_dir   VARCHAR DEFAULT NULL,
    p_phase      VARCHAR DEFAULT NULL,
    INOUT p_staging    refcursor DEFAULT 'staging_cursor',
    INOUT p_summary    refcursor DEFAULT 'summary_cursor',
    INOUT p_clients    refcursor DEFAULT 'clients_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page     INT     := COALESCE(NULLIF(p_page, 0), 1);
    v_limit    INT     := COALESCE(NULLIF(p_limit, 0), 20);
    v_search   TEXT    := NULLIF(p_search, '');
    v_status   TEXT    := NULLIF(p_status, '');
    v_phase    TEXT    := NULLIF(p_phase, '');
    v_product  TEXT    := NULLIF(p_product, '');
    v_asc      BOOLEAN := COALESCE(p_sort_dir = 'asc', FALSE);
    v_key      TEXT    := CASE WHEN p_sort_by IN ('name', 'status', 'aum') THEN p_sort_by ELSE 'created_at' END;
    v_live     BOOLEAN;
    v_total    INT;
BEGIN
    v_live := (v_key = 'aum' OR v_status IN ('active', 'kyc_pending') OR v_phase IS NOT NULL) IS TRUE;

    OPEN p_staging FOR
    SELECT id, email, phone_number, phone_prefix, is_email_verified,
           is_phone_verified, created_at, 'staging'::TEXT AS current_phase
    FROM "user".registerstagging
    WHERE referring_partner_id = p_partner_id
    ORDER BY created_at DESC;

    OPEN p_summary FOR
    SELECT
        (SELECT COUNT(*) FROM "user".registerstagging WHERE referring_partner_id = p_partner_id)::INT AS staging,
        COUNT(*) FILTER (WHERE current_phase = 'kyc_pending')::INT           AS kyc_pending,
        COUNT(*) FILTER (WHERE current_phase = 'bank_kyc_pending')::INT      AS bank_kyc_pending,
        COUNT(*) FILTER (WHERE current_phase = 'risk_pending')::INT          AS risk_pending,
        COUNT(*) FILTER (WHERE current_phase = 'plan_pending')::INT          AS plan_pending,
        COUNT(*) FILTER (WHERE current_phase = 'mf_onboarding_pending')::INT AS mf_onboarding_pending,
        COUNT(*) FILTER (WHERE current_phase = 'fully_onboarded')::INT       AS fully_onboarded,
        COUNT(*)::INT                                                        AS total_onboarded
    FROM (
        WITH pcd_base AS (
            SELECT
                pc.id, pc.name, pc.email AS pc_email, pc.mobile AS pc_mobile,
                pc.pan_number, pc.date_of_birth, pc.status AS raw_status,
                pc.linked_user_id, pc.created_at,
                u.id    AS user_id,
                u.email AS user_email,
                u.phone_number,
                CASE WHEN k.status = 'auto_approved' THEN 'APPROVED' ELSE NULLIF(k.status, '') END AS kyc_status,
                bk.status::TEXT AS bank_kyc_status,
                (COALESCE(u.is_bank_kyc_verified, FALSE) OR bk.status::TEXT = 'APPROVED') IS TRUE AS bank_kyc_done,
                (COALESCE(u.is_risk_verified, FALSE) OR COALESCE(urp.is_active, FALSE))          AS risk_done,
                g.risk_level,
                us.subscription_status::TEXT AS subscription_status,
                (us.subscription_status::TEXT = 'ACTIVE'
                 OR (us.transaction_status::TEXT = 'SUCCESS' AND us.end_date > NOW())) IS TRUE AS subscription_done,
                us.plan_name,
                mo.onboarding_status,
                NULLIF(mo.current_step, 0) AS mf_current_step,
                mu.ucc_status, mu.fatca_status, mu.client_auth_status
            FROM "referral".partner_client pc
            LEFT JOIN "user"."user" u ON u.id = pc.linked_user_id
            LEFT JOIN LATERAL (SELECT status FROM "kyc".kyc WHERE "userId" = u.id LIMIT 1) k ON TRUE
            LEFT JOIN LATERAL (SELECT status FROM "kyc".bankkyc WHERE user_ref = u.id LIMIT 1) bk ON TRUE
            LEFT JOIN LATERAL (SELECT is_active, risk_profile_id FROM "catalog".userriskprofile WHERE user_id = u.id LIMIT 1) urp ON TRUE
            LEFT JOIN "catalog".riskprofilescoregrid g ON g.id = urp.risk_profile_id
            LEFT JOIN LATERAL (
                SELECT subscription_status, transaction_status, plan_name, end_date
                FROM "payments".usersubscription
                WHERE user_ref_id = u.id AND subscription_status = 'ACTIVE'
                ORDER BY created_at DESC
                LIMIT 1
            ) us ON TRUE
            LEFT JOIN LATERAL (SELECT onboarding_status, current_step FROM "trade".nse_mf_onboarding WHERE user_ref_id = u.id LIMIT 1) mo ON TRUE
            LEFT JOIN LATERAL (SELECT ucc_status, fatca_status, client_auth_status FROM "trade".nse_mf_ucc WHERE user_ref_id = u.id LIMIT 1) mu ON TRUE
            WHERE pc.partner_id = p_partner_id
              AND (NULL::TEXT IS NULL
                   OR strpos(LOWER(pc.name),       LOWER(NULL::TEXT)) > 0
                   OR strpos(LOWER(pc.email),      LOWER(NULL::TEXT)) > 0
                   OR strpos(LOWER(pc.mobile),     LOWER(NULL::TEXT)) > 0
                   OR strpos(LOWER(pc.pan_number), LOWER(NULL::TEXT)) > 0)
              AND (NULL::TEXT IS DISTINCT FROM 'CEPS' OR EXISTS (
                    SELECT 1 FROM "trade"."transaction" t
                    WHERE t.user_ref_id = u.id AND t.asset = 'CEP'
                      AND t.transaction_type = 'BUY' AND t.parent_transaction_id IS NULL))
              AND (NULL::TEXT IS DISTINCT FROM 'MF' OR EXISTS (
                    SELECT 1 FROM "trade".nse_mf_order o
                    WHERE o.user_ref_id = u.id AND o.trade_type IN ('LUMPSUM', 'SIP')))
        ),
        pcd_derived AS (
            SELECT b.*,
                COALESCE(b.user_id IS NOT NULL AND b.kyc_status = 'APPROVED', FALSE) AS kyc_done,
                b.onboarding_status IN ('COMPLETED', 'SUBMITTED') IS TRUE AS mf_done,
                (b.ucc_status IN ('REGISTERED', 'REG_SUCCESS', 'APPROVED')
                 AND b.fatca_status IN ('SUBMITTED', 'REG_SUCCESS', 'APPROVED')
                 AND b.client_auth_status = 'AUTHORIZED') IS TRUE AS ucc_done
            FROM pcd_base b
        ),
        pcd_final AS (
            SELECT d.*,
                CASE
                    WHEN NOT d.kyc_done           THEN 'kyc_pending'
                    WHEN NOT d.bank_kyc_done      THEN 'bank_kyc_pending'
                    WHEN NOT d.risk_done          THEN 'risk_pending'
                    WHEN NOT d.subscription_done  THEN 'plan_pending'
                    WHEN NOT d.mf_done            THEN 'mf_onboarding_pending'
                    ELSE 'fully_onboarded'
                END AS phase,
                CASE
                    WHEN d.user_id IS NOT NULL AND d.raw_status IN ('active', 'kyc_pending')
                        THEN CASE WHEN d.kyc_done THEN 'active' ELSE 'kyc_pending' END
                    ELSE d.raw_status
                END AS eff_status
            FROM pcd_derived d
        )
        SELECT
            f.id                                                               AS client_id,
            f.name,
            COALESCE(NULLIF(f.pc_email, ''),  NULLIF(f.user_email, ''))       AS email,
            COALESCE(NULLIF(f.pc_mobile, ''), NULLIF(f.phone_number, ''))     AS mobile,
            NULLIF(f.date_of_birth, '')                                        AS date_of_birth,
            f.raw_status,
            f.eff_status                                                       AS status,
            f.linked_user_id,
            (f.user_id IS NOT NULL)                                            AS user_exists,
            f.created_at,
            f.phase                                                            AS current_phase,
            f.kyc_status, f.kyc_done, f.bank_kyc_status, f.bank_kyc_done,
            f.risk_done, NULLIF(f.risk_level, '')                              AS risk_level,
            f.subscription_status, f.subscription_done,
            NULLIF(f.plan_name, '')                                            AS plan_name,
            NULLIF(f.onboarding_status, '')                                    AS mf_onboarding_status,
            f.mf_done                                                          AS mf_onboarding_done,
            f.mf_current_step,
            NULLIF(f.ucc_status, '')         AS ucc_status,
            NULLIF(f.fatca_status, '')       AS fatca_status,
            NULLIF(f.client_auth_status, '') AS client_auth_status,
            f.ucc_done
        FROM pcd_final f
        WHERE (NULL::TEXT IS NULL
               OR (NULL::TEXT IN ('active', 'kyc_pending')     AND f.eff_status = NULL::TEXT)
               OR (NULL::TEXT NOT IN ('active', 'kyc_pending') AND f.raw_status = NULL::TEXT))
          AND (NULL::TEXT IS NULL OR f.phase = NULL::TEXT)
    ) _pcd_summary;

    IF v_status = 'staging' THEN
        OPEN p_clients FOR
        SELECT * FROM (
        WITH pcd_base AS (
            SELECT
                pc.id, pc.name, pc.email AS pc_email, pc.mobile AS pc_mobile,
                pc.pan_number, pc.date_of_birth, pc.status AS raw_status,
                pc.linked_user_id, pc.created_at,
                u.id    AS user_id,
                u.email AS user_email,
                u.phone_number,
                CASE WHEN k.status = 'auto_approved' THEN 'APPROVED' ELSE NULLIF(k.status, '') END AS kyc_status,
                bk.status::TEXT AS bank_kyc_status,
                (COALESCE(u.is_bank_kyc_verified, FALSE) OR bk.status::TEXT = 'APPROVED') IS TRUE AS bank_kyc_done,
                (COALESCE(u.is_risk_verified, FALSE) OR COALESCE(urp.is_active, FALSE))          AS risk_done,
                g.risk_level,
                us.subscription_status::TEXT AS subscription_status,
                (us.subscription_status::TEXT = 'ACTIVE'
                 OR (us.transaction_status::TEXT = 'SUCCESS' AND us.end_date > NOW())) IS TRUE AS subscription_done,
                us.plan_name,
                mo.onboarding_status,
                NULLIF(mo.current_step, 0) AS mf_current_step,
                mu.ucc_status, mu.fatca_status, mu.client_auth_status
            FROM "referral".partner_client pc
            LEFT JOIN "user"."user" u ON u.id = pc.linked_user_id
            LEFT JOIN LATERAL (SELECT status FROM "kyc".kyc WHERE "userId" = u.id LIMIT 1) k ON TRUE
            LEFT JOIN LATERAL (SELECT status FROM "kyc".bankkyc WHERE user_ref = u.id LIMIT 1) bk ON TRUE
            LEFT JOIN LATERAL (SELECT is_active, risk_profile_id FROM "catalog".userriskprofile WHERE user_id = u.id LIMIT 1) urp ON TRUE
            LEFT JOIN "catalog".riskprofilescoregrid g ON g.id = urp.risk_profile_id
            LEFT JOIN LATERAL (
                SELECT subscription_status, transaction_status, plan_name, end_date
                FROM "payments".usersubscription
                WHERE user_ref_id = u.id AND subscription_status = 'ACTIVE'
                ORDER BY created_at DESC
                LIMIT 1
            ) us ON TRUE
            LEFT JOIN LATERAL (SELECT onboarding_status, current_step FROM "trade".nse_mf_onboarding WHERE user_ref_id = u.id LIMIT 1) mo ON TRUE
            LEFT JOIN LATERAL (SELECT ucc_status, fatca_status, client_auth_status FROM "trade".nse_mf_ucc WHERE user_ref_id = u.id LIMIT 1) mu ON TRUE
            WHERE pc.partner_id = p_partner_id
              AND (NULL::TEXT IS NULL
                   OR strpos(LOWER(pc.name),       LOWER(NULL::TEXT)) > 0
                   OR strpos(LOWER(pc.email),      LOWER(NULL::TEXT)) > 0
                   OR strpos(LOWER(pc.mobile),     LOWER(NULL::TEXT)) > 0
                   OR strpos(LOWER(pc.pan_number), LOWER(NULL::TEXT)) > 0)
              AND (NULL::TEXT IS DISTINCT FROM 'CEPS' OR EXISTS (
                    SELECT 1 FROM "trade"."transaction" t
                    WHERE t.user_ref_id = u.id AND t.asset = 'CEP'
                      AND t.transaction_type = 'BUY' AND t.parent_transaction_id IS NULL))
              AND (NULL::TEXT IS DISTINCT FROM 'MF' OR EXISTS (
                    SELECT 1 FROM "trade".nse_mf_order o
                    WHERE o.user_ref_id = u.id AND o.trade_type IN ('LUMPSUM', 'SIP')))
        ),
        pcd_derived AS (
            SELECT b.*,
                COALESCE(b.user_id IS NOT NULL AND b.kyc_status = 'APPROVED', FALSE) AS kyc_done,
                b.onboarding_status IN ('COMPLETED', 'SUBMITTED') IS TRUE AS mf_done,
                (b.ucc_status IN ('REGISTERED', 'REG_SUCCESS', 'APPROVED')
                 AND b.fatca_status IN ('SUBMITTED', 'REG_SUCCESS', 'APPROVED')
                 AND b.client_auth_status = 'AUTHORIZED') IS TRUE AS ucc_done
            FROM pcd_base b
        ),
        pcd_final AS (
            SELECT d.*,
                CASE
                    WHEN NOT d.kyc_done           THEN 'kyc_pending'
                    WHEN NOT d.bank_kyc_done      THEN 'bank_kyc_pending'
                    WHEN NOT d.risk_done          THEN 'risk_pending'
                    WHEN NOT d.subscription_done  THEN 'plan_pending'
                    WHEN NOT d.mf_done            THEN 'mf_onboarding_pending'
                    ELSE 'fully_onboarded'
                END AS phase,
                CASE
                    WHEN d.user_id IS NOT NULL AND d.raw_status IN ('active', 'kyc_pending')
                        THEN CASE WHEN d.kyc_done THEN 'active' ELSE 'kyc_pending' END
                    ELSE d.raw_status
                END AS eff_status
            FROM pcd_derived d
        )
        SELECT
            f.id                                                               AS client_id,
            f.name,
            COALESCE(NULLIF(f.pc_email, ''),  NULLIF(f.user_email, ''))       AS email,
            COALESCE(NULLIF(f.pc_mobile, ''), NULLIF(f.phone_number, ''))     AS mobile,
            NULLIF(f.date_of_birth, '')                                        AS date_of_birth,
            f.raw_status,
            f.eff_status                                                       AS status,
            f.linked_user_id,
            (f.user_id IS NOT NULL)                                            AS user_exists,
            f.created_at,
            f.phase                                                            AS current_phase,
            f.kyc_status, f.kyc_done, f.bank_kyc_status, f.bank_kyc_done,
            f.risk_done, NULLIF(f.risk_level, '')                              AS risk_level,
            f.subscription_status, f.subscription_done,
            NULLIF(f.plan_name, '')                                            AS plan_name,
            NULLIF(f.onboarding_status, '')                                    AS mf_onboarding_status,
            f.mf_done                                                          AS mf_onboarding_done,
            f.mf_current_step,
            NULLIF(f.ucc_status, '')         AS ucc_status,
            NULLIF(f.fatca_status, '')       AS fatca_status,
            NULLIF(f.client_auth_status, '') AS client_auth_status,
            f.ucc_done
        FROM pcd_final f
        WHERE (NULL::TEXT IS NULL
               OR (NULL::TEXT IN ('active', 'kyc_pending')     AND f.eff_status = NULL::TEXT)
               OR (NULL::TEXT NOT IN ('active', 'kyc_pending') AND f.raw_status = NULL::TEXT))
          AND (NULL::TEXT IS NULL OR f.phase = NULL::TEXT)
    ) _pcd_stage WHERE FALSE;
        OPEN p_pagination FOR
        SELECT 1 AS page, v_limit AS "limit", 0 AS total, 0 AS total_pages;
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_total
    FROM (
        WITH pcd_base AS (
            SELECT
                pc.id, pc.name, pc.email AS pc_email, pc.mobile AS pc_mobile,
                pc.pan_number, pc.date_of_birth, pc.status AS raw_status,
                pc.linked_user_id, pc.created_at,
                u.id    AS user_id,
                u.email AS user_email,
                u.phone_number,
                CASE WHEN k.status = 'auto_approved' THEN 'APPROVED' ELSE NULLIF(k.status, '') END AS kyc_status,
                bk.status::TEXT AS bank_kyc_status,
                (COALESCE(u.is_bank_kyc_verified, FALSE) OR bk.status::TEXT = 'APPROVED') IS TRUE AS bank_kyc_done,
                (COALESCE(u.is_risk_verified, FALSE) OR COALESCE(urp.is_active, FALSE))          AS risk_done,
                g.risk_level,
                us.subscription_status::TEXT AS subscription_status,
                (us.subscription_status::TEXT = 'ACTIVE'
                 OR (us.transaction_status::TEXT = 'SUCCESS' AND us.end_date > NOW())) IS TRUE AS subscription_done,
                us.plan_name,
                mo.onboarding_status,
                NULLIF(mo.current_step, 0) AS mf_current_step,
                mu.ucc_status, mu.fatca_status, mu.client_auth_status
            FROM "referral".partner_client pc
            LEFT JOIN "user"."user" u ON u.id = pc.linked_user_id
            LEFT JOIN LATERAL (SELECT status FROM "kyc".kyc WHERE "userId" = u.id LIMIT 1) k ON TRUE
            LEFT JOIN LATERAL (SELECT status FROM "kyc".bankkyc WHERE user_ref = u.id LIMIT 1) bk ON TRUE
            LEFT JOIN LATERAL (SELECT is_active, risk_profile_id FROM "catalog".userriskprofile WHERE user_id = u.id LIMIT 1) urp ON TRUE
            LEFT JOIN "catalog".riskprofilescoregrid g ON g.id = urp.risk_profile_id
            LEFT JOIN LATERAL (
                SELECT subscription_status, transaction_status, plan_name, end_date
                FROM "payments".usersubscription
                WHERE user_ref_id = u.id AND subscription_status = 'ACTIVE'
                ORDER BY created_at DESC
                LIMIT 1
            ) us ON TRUE
            LEFT JOIN LATERAL (SELECT onboarding_status, current_step FROM "trade".nse_mf_onboarding WHERE user_ref_id = u.id LIMIT 1) mo ON TRUE
            LEFT JOIN LATERAL (SELECT ucc_status, fatca_status, client_auth_status FROM "trade".nse_mf_ucc WHERE user_ref_id = u.id LIMIT 1) mu ON TRUE
            WHERE pc.partner_id = p_partner_id
              AND (v_search IS NULL
                   OR strpos(LOWER(pc.name),       LOWER(v_search)) > 0
                   OR strpos(LOWER(pc.email),      LOWER(v_search)) > 0
                   OR strpos(LOWER(pc.mobile),     LOWER(v_search)) > 0
                   OR strpos(LOWER(pc.pan_number), LOWER(v_search)) > 0)
              AND (v_product IS DISTINCT FROM 'CEPS' OR EXISTS (
                    SELECT 1 FROM "trade"."transaction" t
                    WHERE t.user_ref_id = u.id AND t.asset = 'CEP'
                      AND t.transaction_type = 'BUY' AND t.parent_transaction_id IS NULL))
              AND (v_product IS DISTINCT FROM 'MF' OR EXISTS (
                    SELECT 1 FROM "trade".nse_mf_order o
                    WHERE o.user_ref_id = u.id AND o.trade_type IN ('LUMPSUM', 'SIP')))
        ),
        pcd_derived AS (
            SELECT b.*,
                COALESCE(b.user_id IS NOT NULL AND b.kyc_status = 'APPROVED', FALSE) AS kyc_done,
                b.onboarding_status IN ('COMPLETED', 'SUBMITTED') IS TRUE AS mf_done,
                (b.ucc_status IN ('REGISTERED', 'REG_SUCCESS', 'APPROVED')
                 AND b.fatca_status IN ('SUBMITTED', 'REG_SUCCESS', 'APPROVED')
                 AND b.client_auth_status = 'AUTHORIZED') IS TRUE AS ucc_done
            FROM pcd_base b
        ),
        pcd_final AS (
            SELECT d.*,
                CASE
                    WHEN NOT d.kyc_done           THEN 'kyc_pending'
                    WHEN NOT d.bank_kyc_done      THEN 'bank_kyc_pending'
                    WHEN NOT d.risk_done          THEN 'risk_pending'
                    WHEN NOT d.subscription_done  THEN 'plan_pending'
                    WHEN NOT d.mf_done            THEN 'mf_onboarding_pending'
                    ELSE 'fully_onboarded'
                END AS phase,
                CASE
                    WHEN d.user_id IS NOT NULL AND d.raw_status IN ('active', 'kyc_pending')
                        THEN CASE WHEN d.kyc_done THEN 'active' ELSE 'kyc_pending' END
                    ELSE d.raw_status
                END AS eff_status
            FROM pcd_derived d
        )
        SELECT
            f.id                                                               AS client_id,
            f.name,
            COALESCE(NULLIF(f.pc_email, ''),  NULLIF(f.user_email, ''))       AS email,
            COALESCE(NULLIF(f.pc_mobile, ''), NULLIF(f.phone_number, ''))     AS mobile,
            NULLIF(f.date_of_birth, '')                                        AS date_of_birth,
            f.raw_status,
            f.eff_status                                                       AS status,
            f.linked_user_id,
            (f.user_id IS NOT NULL)                                            AS user_exists,
            f.created_at,
            f.phase                                                            AS current_phase,
            f.kyc_status, f.kyc_done, f.bank_kyc_status, f.bank_kyc_done,
            f.risk_done, NULLIF(f.risk_level, '')                              AS risk_level,
            f.subscription_status, f.subscription_done,
            NULLIF(f.plan_name, '')                                            AS plan_name,
            NULLIF(f.onboarding_status, '')                                    AS mf_onboarding_status,
            f.mf_done                                                          AS mf_onboarding_done,
            f.mf_current_step,
            NULLIF(f.ucc_status, '')         AS ucc_status,
            NULLIF(f.fatca_status, '')       AS fatca_status,
            NULLIF(f.client_auth_status, '') AS client_auth_status,
            f.ucc_done
        FROM pcd_final f
        WHERE (v_status IS NULL
               OR (v_status IN ('active', 'kyc_pending')     AND f.eff_status = v_status)
               OR (v_status NOT IN ('active', 'kyc_pending') AND f.raw_status = v_status))
          AND (v_phase IS NULL OR f.phase = v_phase)
    ) _pcd_count;

    OPEN p_clients FOR
    SELECT * FROM (
        SELECT
            d.client_id AS id, d.name, d.email, d.mobile, d.date_of_birth,
            d.status,
            d.raw_status                            AS stored_status,
            CASE WHEN d.user_exists
                 THEN (SELECT COALESCE(SUM(COALESCE(NULLIF(
        substring(regexp_replace(o.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')
          FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::DOUBLE PRECISION,
        0::DOUBLE PRECISION), 0::DOUBLE PRECISION)), 0)
             FROM "trade".nse_mf_order o
             WHERE o.user_ref_id = d.linked_user_id
               AND o.order_status IN ('COMPLETED', 'ALLOTMENT_DONE', 'SUCCESS')
               AND o.trade_type   IN ('LUMPSUM', 'SIP'))
                      +
                      (SELECT COALESCE(SUM(COALESCE(c.average_price, 0)::DOUBLE PRECISION * c.filled_quantity::DOUBLE PRECISION), 0)
             FROM "trade"."transaction" p
             JOIN "trade"."transaction" c ON c.parent_transaction_id = p.id
             WHERE p.user_ref_id           = d.linked_user_id
               AND p.asset                 = 'CEP'
               AND p.transaction_type      = 'BUY'
               AND p.status                = 'COMPLETED'
               AND p.parent_transaction_id IS NULL)
                 ELSE 0 END                         AS aum,
            d.linked_user_id,
            d.kyc_done                              AS kyc_verified,
            d.created_at,
            d.created_at                            AS date_added,
            d.current_phase,
            d.kyc_status, d.kyc_done,
            d.bank_kyc_status, d.bank_kyc_done,
            d.risk_done, d.risk_level,
            d.subscription_status, d.subscription_done, d.plan_name,
            d.mf_onboarding_status, d.mf_onboarding_done, d.mf_current_step,
            7                                       AS mf_total_steps,
            d.ucc_status, d.fatca_status, d.client_auth_status, d.ucc_done
        FROM (
        WITH pcd_base AS (
            SELECT
                pc.id, pc.name, pc.email AS pc_email, pc.mobile AS pc_mobile,
                pc.pan_number, pc.date_of_birth, pc.status AS raw_status,
                pc.linked_user_id, pc.created_at,
                u.id    AS user_id,
                u.email AS user_email,
                u.phone_number,
                CASE WHEN k.status = 'auto_approved' THEN 'APPROVED' ELSE NULLIF(k.status, '') END AS kyc_status,
                bk.status::TEXT AS bank_kyc_status,
                (COALESCE(u.is_bank_kyc_verified, FALSE) OR bk.status::TEXT = 'APPROVED') IS TRUE AS bank_kyc_done,
                (COALESCE(u.is_risk_verified, FALSE) OR COALESCE(urp.is_active, FALSE))          AS risk_done,
                g.risk_level,
                us.subscription_status::TEXT AS subscription_status,
                (us.subscription_status::TEXT = 'ACTIVE'
                 OR (us.transaction_status::TEXT = 'SUCCESS' AND us.end_date > NOW())) IS TRUE AS subscription_done,
                us.plan_name,
                mo.onboarding_status,
                NULLIF(mo.current_step, 0) AS mf_current_step,
                mu.ucc_status, mu.fatca_status, mu.client_auth_status
            FROM "referral".partner_client pc
            LEFT JOIN "user"."user" u ON u.id = pc.linked_user_id
            LEFT JOIN LATERAL (SELECT status FROM "kyc".kyc WHERE "userId" = u.id LIMIT 1) k ON TRUE
            LEFT JOIN LATERAL (SELECT status FROM "kyc".bankkyc WHERE user_ref = u.id LIMIT 1) bk ON TRUE
            LEFT JOIN LATERAL (SELECT is_active, risk_profile_id FROM "catalog".userriskprofile WHERE user_id = u.id LIMIT 1) urp ON TRUE
            LEFT JOIN "catalog".riskprofilescoregrid g ON g.id = urp.risk_profile_id
            LEFT JOIN LATERAL (
                SELECT subscription_status, transaction_status, plan_name, end_date
                FROM "payments".usersubscription
                WHERE user_ref_id = u.id AND subscription_status = 'ACTIVE'
                ORDER BY created_at DESC
                LIMIT 1
            ) us ON TRUE
            LEFT JOIN LATERAL (SELECT onboarding_status, current_step FROM "trade".nse_mf_onboarding WHERE user_ref_id = u.id LIMIT 1) mo ON TRUE
            LEFT JOIN LATERAL (SELECT ucc_status, fatca_status, client_auth_status FROM "trade".nse_mf_ucc WHERE user_ref_id = u.id LIMIT 1) mu ON TRUE
            WHERE pc.partner_id = p_partner_id
              AND (v_search IS NULL
                   OR strpos(LOWER(pc.name),       LOWER(v_search)) > 0
                   OR strpos(LOWER(pc.email),      LOWER(v_search)) > 0
                   OR strpos(LOWER(pc.mobile),     LOWER(v_search)) > 0
                   OR strpos(LOWER(pc.pan_number), LOWER(v_search)) > 0)
              AND (v_product IS DISTINCT FROM 'CEPS' OR EXISTS (
                    SELECT 1 FROM "trade"."transaction" t
                    WHERE t.user_ref_id = u.id AND t.asset = 'CEP'
                      AND t.transaction_type = 'BUY' AND t.parent_transaction_id IS NULL))
              AND (v_product IS DISTINCT FROM 'MF' OR EXISTS (
                    SELECT 1 FROM "trade".nse_mf_order o
                    WHERE o.user_ref_id = u.id AND o.trade_type IN ('LUMPSUM', 'SIP')))
        ),
        pcd_derived AS (
            SELECT b.*,
                COALESCE(b.user_id IS NOT NULL AND b.kyc_status = 'APPROVED', FALSE) AS kyc_done,
                b.onboarding_status IN ('COMPLETED', 'SUBMITTED') IS TRUE AS mf_done,
                (b.ucc_status IN ('REGISTERED', 'REG_SUCCESS', 'APPROVED')
                 AND b.fatca_status IN ('SUBMITTED', 'REG_SUCCESS', 'APPROVED')
                 AND b.client_auth_status = 'AUTHORIZED') IS TRUE AS ucc_done
            FROM pcd_base b
        ),
        pcd_final AS (
            SELECT d.*,
                CASE
                    WHEN NOT d.kyc_done           THEN 'kyc_pending'
                    WHEN NOT d.bank_kyc_done      THEN 'bank_kyc_pending'
                    WHEN NOT d.risk_done          THEN 'risk_pending'
                    WHEN NOT d.subscription_done  THEN 'plan_pending'
                    WHEN NOT d.mf_done            THEN 'mf_onboarding_pending'
                    ELSE 'fully_onboarded'
                END AS phase,
                CASE
                    WHEN d.user_id IS NOT NULL AND d.raw_status IN ('active', 'kyc_pending')
                        THEN CASE WHEN d.kyc_done THEN 'active' ELSE 'kyc_pending' END
                    ELSE d.raw_status
                END AS eff_status
            FROM pcd_derived d
        )
        SELECT
            f.id                                                               AS client_id,
            f.name,
            COALESCE(NULLIF(f.pc_email, ''),  NULLIF(f.user_email, ''))       AS email,
            COALESCE(NULLIF(f.pc_mobile, ''), NULLIF(f.phone_number, ''))     AS mobile,
            NULLIF(f.date_of_birth, '')                                        AS date_of_birth,
            f.raw_status,
            f.eff_status                                                       AS status,
            f.linked_user_id,
            (f.user_id IS NOT NULL)                                            AS user_exists,
            f.created_at,
            f.phase                                                            AS current_phase,
            f.kyc_status, f.kyc_done, f.bank_kyc_status, f.bank_kyc_done,
            f.risk_done, NULLIF(f.risk_level, '')                              AS risk_level,
            f.subscription_status, f.subscription_done,
            NULLIF(f.plan_name, '')                                            AS plan_name,
            NULLIF(f.onboarding_status, '')                                    AS mf_onboarding_status,
            f.mf_done                                                          AS mf_onboarding_done,
            f.mf_current_step,
            NULLIF(f.ucc_status, '')         AS ucc_status,
            NULLIF(f.fatca_status, '')       AS fatca_status,
            NULLIF(f.client_auth_status, '') AS client_auth_status,
            f.ucc_done
        FROM pcd_final f
        WHERE (v_status IS NULL
               OR (v_status IN ('active', 'kyc_pending')     AND f.eff_status = v_status)
               OR (v_status NOT IN ('active', 'kyc_pending') AND f.raw_status = v_status))
          AND (v_phase IS NULL OR f.phase = v_phase)
    ) d
    ) x
    ORDER BY
        CASE WHEN v_key = 'aum' AND v_asc     THEN x.aum END ASC,
        CASE WHEN v_key = 'aum' AND NOT v_asc THEN x.aum END DESC,
        CASE WHEN v_key = 'name' AND v_asc     THEN x.name END ASC,
        CASE WHEN v_key = 'name' AND NOT v_asc THEN x.name END DESC,
        CASE WHEN v_key = 'status' AND v_asc     THEN CASE WHEN v_live THEN x.status ELSE x.stored_status END END ASC,
        CASE WHEN v_key = 'status' AND NOT v_asc THEN CASE WHEN v_live THEN x.status ELSE x.stored_status END END DESC,
        CASE WHEN v_key = 'created_at' AND v_asc     THEN x.created_at END ASC,
        CASE WHEN v_key = 'created_at' AND NOT v_asc THEN x.created_at END DESC,
        x.id
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_get_dashboard.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_dashboard(
    p_partner_id            VARCHAR,
    INOUT p_stats_cursor    refcursor DEFAULT 'stats_cursor',
    INOUT p_activity_cursor refcursor DEFAULT 'activity_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_now             TIMESTAMP := NOW();
    v_first_of_month  TIMESTAMP := DATE_TRUNC('month', v_now);
    v_first_of_lmonth TIMESTAMP := DATE_TRUNC('month', v_now) - INTERVAL '1 month';
    v_last_of_lmonth  TIMESTAMP := DATE_TRUNC('month', v_now) - INTERVAL '1 millisecond';
    v_first_of_year   TIMESTAMP := DATE_TRUNC('year', v_now);
BEGIN
    OPEN p_stats_cursor FOR
    WITH linked AS (
        SELECT DISTINCT linked_user_id
        FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL
    )
    SELECT
        COALESCE((SELECT NULLIF(full_name, '') FROM "referral".partner_user WHERE id = p_partner_id), 'Partner') AS partner_name,
        (SELECT COUNT(*) FROM "referral".partner_client WHERE partner_id = p_partner_id)::INT AS client_count,
        (SELECT COUNT(*) FROM "referral".partner_client
          WHERE partner_id = p_partner_id AND created_at >= v_first_of_month)::INT          AS new_clients_this_month,
        (SELECT COALESCE(SUM(
            (SELECT COALESCE(SUM(COALESCE(NULLIF(
        substring(regexp_replace(o.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')
          FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::DOUBLE PRECISION,
        0::DOUBLE PRECISION), 0::DOUBLE PRECISION)), 0)
             FROM "trade".nse_mf_order o
             WHERE o.user_ref_id = l.linked_user_id
               AND o.order_status IN ('COMPLETED', 'ALLOTMENT_DONE', 'SUCCESS')
               AND o.trade_type   IN ('LUMPSUM', 'SIP'))
            +
            (SELECT COALESCE(SUM(COALESCE(c.average_price, 0)::DOUBLE PRECISION * c.filled_quantity::DOUBLE PRECISION), 0)
             FROM "trade"."transaction" p
             JOIN "trade"."transaction" c ON c.parent_transaction_id = p.id
             WHERE p.user_ref_id           = l.linked_user_id
               AND p.asset                 = 'CEP'
               AND p.transaction_type      = 'BUY'
               AND p.status                = 'COMPLETED'
               AND p.parent_transaction_id IS NULL)
        ), 0)
           FROM linked l)                                                                   AS total_aum,
        (SELECT COALESCE(SUM(commission_amount), 0) FROM "referral".partner_commission_ledger
          WHERE partner_id = p_partner_id AND created_at >= v_first_of_year)                AS ytd_commission,
        (SELECT COALESCE(SUM(commission_amount), 0) FROM "referral".partner_commission_ledger
          WHERE partner_id = p_partner_id AND created_at >= v_first_of_month)               AS monthly_commission,
        (SELECT COALESCE(SUM(commission_amount), 0) FROM "referral".partner_commission_ledger
          WHERE partner_id = p_partner_id
            AND created_at >= v_first_of_lmonth AND created_at <= v_last_of_lmonth)         AS last_month_commission;

    OPEN p_activity_cursor FOR
    WITH client_map AS (   -- linked_user_id -> one client (Node's userClientMap)
        SELECT DISTINCT ON (linked_user_id) linked_user_id, id, name
        FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL
        ORDER BY linked_user_id, created_at DESC
    ),
    events AS (
        (SELECT 1 AS src, 'new_client'::TEXT AS type, pc.id AS client_id,
                pc.name::TEXT AS source_user, pc.created_at AS date
         FROM "referral".partner_client pc
         WHERE pc.partner_id = p_partner_id
         ORDER BY pc.created_at DESC
         LIMIT 10)
        UNION ALL
        SELECT 2, 'transaction', cm.id, cm.name || ' — ' || mf.trade_type, mf.created_at
        FROM (SELECT o.user_ref_id, o.trade_type, o.created_at
              FROM "trade".nse_mf_order o
              WHERE o.user_ref_id IN (SELECT linked_user_id FROM client_map)
              ORDER BY o.created_at DESC
              LIMIT 5) mf
        JOIN client_map cm ON cm.linked_user_id = mf.user_ref_id
        UNION ALL
        SELECT 3, 'transaction', cm.id, cm.name || ' — CEPS ' || t.transaction_type::TEXT, t.created_at
        FROM (SELECT x.user_ref_id, x.transaction_type, x.created_at
              FROM "trade"."transaction" x
              WHERE x.user_ref_id IN (SELECT linked_user_id FROM client_map)
                AND x.asset = 'CEP' AND x.parent_transaction_id IS NULL
              ORDER BY x.created_at DESC
              LIMIT 5) t
        JOIN client_map cm ON cm.linked_user_id = t.user_ref_id
    )
    SELECT type, client_id, source_user, date
    FROM events
    ORDER BY date DESC, src
    LIMIT 15;
END;
$$;

-- File: partner.sp_partner_get_dashboard_legacy_user.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_dashboard_legacy_user(
    p_user_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT COALESCE(
        (SELECT regexp_replace(COALESCE(NULLIF(first_name, ''), '') || ' ' || COALESCE(NULLIF(last_name, ''), ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')
         FROM "user"."user" WHERE id = p_user_id),
        '') AS name;
END;
$$;

-- File: partner.sp_partner_get_transaction_detail.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_transaction_detail(
    p_partner_id VARCHAR,
    p_id         VARCHAR,
    p_source     VARCHAR DEFAULT NULL,
    INOUT p_detail   refcursor DEFAULT 'detail_cursor',
    INOUT p_children refcursor DEFAULT 'children_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    -- 1. MF order
    IF p_source IS NULL OR p_source = '' OR p_source = 'nse_mf' THEN
        IF EXISTS (
            SELECT 1 FROM "trade".nse_mf_order o
            JOIN "referral".partner_client pc
              ON pc.linked_user_id = o.user_ref_id AND pc.partner_id = p_partner_id
            WHERE o.id = p_id
        ) THEN
            OPEN p_detail FOR
            SELECT
                o.id,
                'nse_mf'::TEXT                                          AS source,
                'MF'::TEXT                                              AS asset_type,
                o.trade_type::TEXT                                      AS sub_type,
                pc.client_id,
                pc.client_name,
                NULL::TEXT                                              AS fund_name,
                COALESCE(NULLIF(o.scheme_code, ''), 'Mutual Fund')::TEXT AS scheme_name,
                o.scheme_code::TEXT                                     AS scheme_code,
                o.amc_code::TEXT                                        AS amc_code,
                o.folio_no::TEXT                                        AS folio_number,
                COALESCE(substring(regexp_replace(o.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::NUMERIC, 0) AS amount,
                NULL::NUMERIC                                           AS units,
                NULL::NUMERIC                                           AS nav,
                o.nse_order_id::TEXT                                    AS nse_order_id,
                o.nse_status::TEXT                                      AS nse_status,
                o.nse_remark                                            AS nse_remark,
                o.order_status::TEXT                                    AS order_status,
                LOWER(COALESCE(NULLIF(o.order_status, ''), NULLIF(o.nse_status, ''), 'pending')) AS status,
                o.created_at,
                o.updated_at,
                NULL::TEXT                                              AS cep_ref_id,
                o.frequency_type::TEXT                                  AS sip_frequency,
                o.start_date::TEXT                                      AS sip_start_date,
                o.end_date::TEXT                                        AS sip_end_date,
                o.sip_mandate_id::TEXT                                  AS mandate_id,
                (SELECT COALESCE(NULLIF(md.bank_status, ''), NULLIF(md.mandate_status, ''))
                   FROM "trade".nse_mf_mandate md
                  WHERE o.sip_mandate_id IS NOT NULL AND o.sip_mandate_id <> ''
                    AND md.user_ref_id = o.user_ref_id AND md.reg_id = o.sip_mandate_id
                  ORDER BY md.created_at LIMIT 1)::TEXT                 AS mandate_status
            FROM "trade".nse_mf_order o
            JOIN LATERAL (
                SELECT id AS client_id, name AS client_name
                FROM "referral".partner_client
                WHERE linked_user_id = o.user_ref_id AND partner_id = p_partner_id
                ORDER BY created_at DESC LIMIT 1
            ) pc ON TRUE
            WHERE o.id = p_id;

            -- MF has no child orders
            OPEN p_children FOR
            SELECT NULL::TEXT AS id WHERE FALSE;
            RETURN;
        END IF;
    END IF;

    -- 2. trade.transaction (CEP basket or equity)
    IF p_source IS NULL OR p_source = '' OR p_source = 'transaction' THEN
        IF EXISTS (
            SELECT 1 FROM "trade"."transaction" t
            JOIN "referral".partner_client pc
              ON pc.linked_user_id = t.user_ref_id AND pc.partner_id = p_partner_id
            WHERE t.id = p_id
        ) THEN
            OPEN p_detail FOR
            SELECT
                t.id,
                'transaction'::TEXT                                     AS source,
                CASE WHEN COALESCE(t.cep_ref_id, '') <> '' THEN 'CEPS' ELSE 'EQUITY' END AS asset_type,
                CASE WHEN COALESCE(t.cep_ref_id, '') <> ''
                     THEN CASE t.transaction_type::TEXT WHEN 'SELL' THEN 'EXIT' ELSE t.transaction_type::TEXT END
                     ELSE t.transaction_type::TEXT END                  AS sub_type,
                pc.client_id,
                pc.client_name,
                COALESCE(NULLIF(t.cep_ref_id, ''), NULLIF(t.trading_symbol, ''), NULLIF(t.scripcode, ''), '—')::TEXT AS fund_name,
                NULL::TEXT                                              AS scheme_name,
                NULL::TEXT                                              AS scheme_code,
                NULL::TEXT                                              AS amc_code,
                NULL::TEXT                                              AS folio_number,
                CASE WHEN COALESCE(t.cep_ref_id, '') <> ''
                     THEN COALESCE((SELECT SUM(COALESCE(s.average_price, 0) * COALESCE(s.filled_quantity, 0))
                                    FROM "trade"."transaction" s WHERE s.parent_transaction_id = t.id), 0)
                     ELSE COALESCE(t.quantity, 0) * COALESCE(t.average_price, 0) END AS amount,
                CASE WHEN COALESCE(t.cep_ref_id, '') <> '' THEN NULL ELSE NULLIF(t.quantity, 0) END      AS units,
                CASE WHEN COALESCE(t.cep_ref_id, '') <> '' THEN NULL ELSE NULLIF(t.average_price, 0) END AS nav,
                NULL::TEXT                                              AS nse_order_id,
                NULL::TEXT                                              AS nse_status,
                NULL::TEXT                                              AS nse_remark,
                t.status::TEXT                                          AS order_status,
                LOWER(COALESCE(t.status::TEXT, ''))                     AS status,
                t.created_at,
                t.updated_at,
                t.cep_ref_id::TEXT                                      AS cep_ref_id,
                NULL::TEXT AS sip_frequency, NULL::TEXT AS sip_start_date, NULL::TEXT AS sip_end_date,
                NULL::TEXT AS mandate_id,    NULL::TEXT AS mandate_status
            FROM "trade"."transaction" t
            JOIN LATERAL (
                SELECT id AS client_id, name AS client_name
                FROM "referral".partner_client
                WHERE linked_user_id = t.user_ref_id AND partner_id = p_partner_id
                ORDER BY created_at DESC LIMIT 1
            ) pc ON TRUE
            WHERE t.id = p_id;

            OPEN p_children FOR
            SELECT
                s.id,
                COALESCE(NULLIF(s.trading_symbol, ''), s.scripcode)                         AS stock_name,
                s.transaction_type::TEXT                                                    AS action,
                COALESCE(s.filled_quantity, 0)                       AS quantity,
                COALESCE(s.average_price, 0)                                                AS price,
                COALESCE(s.average_price, 0) * COALESCE(s.filled_quantity, 0) AS amount,
                LOWER(COALESCE(s.status::TEXT, ''))                                         AS status,
                s.created_at                                                                AS date
            FROM "trade"."transaction" s
            WHERE s.parent_transaction_id = p_id
            ORDER BY s.created_at, s.id;
            RETURN;
        END IF;
    END IF;

    RAISE EXCEPTION 'Transaction not found.';
END;
$$;

-- File: partner.sp_partner_get_unified_transactions.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_get_unified_transactions(
    p_partner_id  VARCHAR,
    p_page        INT       DEFAULT 1,
    p_limit       INT       DEFAULT 20,
    p_asset_type  VARCHAR   DEFAULT NULL,
    p_sub_type    VARCHAR   DEFAULT NULL,
    p_status      VARCHAR   DEFAULT NULL,
    p_client_id   VARCHAR   DEFAULT NULL,
    p_from        VARCHAR   DEFAULT NULL,
    p_to          VARCHAR   DEFAULT NULL,
    p_sort_by     VARCHAR   DEFAULT 'date',
    p_sort_dir    VARCHAR   DEFAULT 'desc',
    INOUT p_rows      refcursor DEFAULT 'rows_cursor',
    INOUT p_summary   refcursor DEFAULT 'summary_cursor',
    INOUT p_by_type   refcursor DEFAULT 'by_type_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    -- Node: query params are checked for truthiness, so '' = not given
    v_asset         TEXT := NULLIF(p_asset_type, '');
    v_client        TEXT := NULLIF(p_client_id, '');
    v_page          INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit         INT := LEAST(COALESCE(NULLIF(p_limit, 0), 20), 100);
    v_skip          INT;
    v_user_ids      TEXT[];
    v_include_ceps  BOOLEAN;
    v_include_mf    BOOLEAN;
    v_sub           TEXT := UPPER(NULLIF(p_sub_type, ''));
    v_txn_type      TEXT;
    v_mf_type       TEXT;
    v_status        TEXT := UPPER(NULLIF(p_status, ''));
    v_from          TIMESTAMP;
    v_to            TIMESTAMP;
    -- Node: sort_by defaults to 'date'; dir is asc only when sort_dir = 'asc'
    v_sort          TEXT := COALESCE(p_sort_by, 'date');
    v_dir           TEXT := CASE WHEN p_sort_dir = 'asc' THEN 'asc' ELSE 'desc' END;
    v_total_ceps    INT := 0;
    v_total_mf      INT := 0;
    v_total         INT := 0;
    -- inlined fn_js_parse_date locals
    _pd_s      TEXT;
    _pd_m      TEXT[];
    _pd_y      INT; _pd_mo INT; _pd_d INT;
    _pd_hh     INT; _pd_mi  INT; _pd_ss NUMERIC;
    _pd_tz     TEXT;
    _pd_base   TIMESTAMP;
    _pd_result TIMESTAMP(3);
BEGIN
    v_skip := (v_page - 1) * v_limit;
    v_include_ceps := (v_asset IS NULL OR v_asset = 'CEPS');
    v_include_mf   := (v_asset IS NULL OR v_asset = 'MF');

    -- Partner's linked clients (one row per linked user)
    SELECT ARRAY_AGG(linked_user_id) INTO v_user_ids
    FROM "referral".partner_client
    WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL;

    -- Filter to one client (must be this partner's linked client)
    IF v_client IS NOT NULL THEN
        SELECT ARRAY[linked_user_id] INTO v_user_ids
        FROM "referral".partner_client
        WHERE id = v_client AND partner_id = p_partner_id AND linked_user_id IS NOT NULL;
    END IF;

    -- sub_type mapping ("EXIT" is a UI label for SELL)
    IF v_sub IS NOT NULL THEN
        IF v_sub IN ('BUY', 'SELL', 'EXIT') THEN
            v_txn_type   := CASE WHEN v_sub = 'EXIT' THEN 'SELL' ELSE v_sub END;
            v_include_mf := FALSE;
        ELSIF v_sub IN ('LUMPSUM', 'SIP', 'REDEMPTION', 'SWITCH') THEN
            v_mf_type      := v_sub;
            v_include_ceps := FALSE;
        END IF;
    END IF;

    IF v_user_ids IS NOT NULL AND (v_include_ceps OR v_include_mf) THEN
        -- Same failures as Prisma at the count() step → Node's 500
        IF p_from IS NOT NULL AND p_from <> '' THEN
            -- inline fn_js_parse_date(p_from) → v_from
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_from, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_from := _pd_result;
            IF v_from IS NULL THEN RAISE EXCEPTION 'Internal server error.'; END IF;
        END IF;
        IF p_to IS NOT NULL AND p_to <> '' THEN
            -- inline fn_js_parse_date(p_to) → v_to
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_to, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_to := _pd_result;
            IF v_to IS NULL THEN RAISE EXCEPTION 'Internal server error.'; END IF;
        END IF;
        IF v_include_ceps AND v_status IS NOT NULL AND v_status NOT IN (
            'PENDING', 'COMPLETED', 'CANCELLED', 'EXPIRED', 'IMPEDED', 'REVAMPED',
            'PARTIALLY_FILLED', 'FAILED', 'REFUNDED', 'REVERSED',
            'REVERSAL_FAILED', 'REVERSAL_PENDING', 'REVERSAL_COMPLETED', 'REVERSAL_CANCEL'
        ) THEN
            RAISE EXCEPTION 'Internal server error.';   -- status is not a TransactionStatus enum value
        END IF;

        IF v_include_ceps THEN
            SELECT COUNT(*) INTO v_total_ceps
            FROM "trade"."transaction" t
            WHERE t.user_ref_id = ANY(v_user_ids)
              AND t.parent_transaction_id IS NULL
              AND t.cep_ref_id IS NOT NULL
              AND (v_txn_type IS NULL OR t.transaction_type::TEXT = v_txn_type)
              AND (v_status   IS NULL OR t.status::TEXT = v_status)
              AND (v_from     IS NULL OR t.created_at >= v_from)
              AND (v_to       IS NULL OR t.created_at <= v_to);
        END IF;
        IF v_include_mf THEN
            SELECT COUNT(*) INTO v_total_mf
            FROM "trade".nse_mf_order o
            WHERE o.user_ref_id = ANY(v_user_ids)
              AND (v_mf_type IS NULL OR UPPER(o.trade_type)   = v_mf_type)   -- MySQL compares case-insensitively
              AND (v_status  IS NULL OR UPPER(o.order_status) = v_status)
              AND (v_from    IS NULL OR o.created_at >= v_from)
              AND (v_to      IS NULL OR o.created_at <= v_to);
        END IF;
    END IF;
    v_total := v_total_ceps + v_total_mf;

    -- Merge the newest (skip+limit) rows of each source, sort, slice
    DROP TABLE IF EXISTS tmp_unified_page;
    CREATE TEMP TABLE tmp_unified_page ON COMMIT DROP AS
    WITH cm AS (
        SELECT DISTINCT ON (linked_user_id) id AS client_id, linked_user_id, name AS client_name
        FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL
        ORDER BY linked_user_id, created_at DESC
    ),
    ceps AS (
        SELECT * FROM (
            SELECT
                t.id,
                'transaction'::TEXT                                         AS source,
                'CEPS'::TEXT                                                AS asset_type,
                CASE t.transaction_type::TEXT WHEN 'SELL' THEN 'EXIT' ELSE t.transaction_type::TEXT END AS sub_type,
                cm.client_id,
                COALESCE(cm.client_name, 'Unknown')                         AS client_name,
                COALESCE(NULLIF(t.description, ''), NULLIF(t.cep_ref_id, ''), '—') AS fund_name,
                NULL::TEXT                                                  AS scheme_name,
                NULL::TEXT                                                  AS scheme_code,
                t.cep_ref_id,
                COALESCE((SELECT SUM(COALESCE(s.average_price, 0) * COALESCE(s.filled_quantity, 0))
                          FROM "trade"."transaction" s WHERE s.parent_transaction_id = t.id), 0) AS amount,
                NULLIF(t.quantity, 0)                                       AS units,
                LOWER(COALESCE(t.status::TEXT, ''))                         AS status,
                NULL::TEXT                                                  AS nse_order_id,
                t.created_at                                                AS date,
                0                                                           AS src_ord,
                ROW_NUMBER() OVER (ORDER BY t.created_at DESC, t.id)        AS src_rn
            FROM "trade"."transaction" t
            LEFT JOIN cm ON cm.linked_user_id = t.user_ref_id
            WHERE v_include_ceps
              AND t.user_ref_id = ANY(v_user_ids)
              AND t.parent_transaction_id IS NULL
              AND t.cep_ref_id IS NOT NULL
              AND (v_txn_type IS NULL OR t.transaction_type::TEXT = v_txn_type)
              AND (v_status   IS NULL OR t.status::TEXT = v_status)
              AND (v_from     IS NULL OR t.created_at >= v_from)
              AND (v_to       IS NULL OR t.created_at <= v_to)
        ) x WHERE src_rn <= v_skip + v_limit
    ),
    mf AS (
        SELECT * FROM (
            SELECT
                o.id,
                'nse_mf'::TEXT                                              AS source,
                'MF'::TEXT                                                  AS asset_type,
                COALESCE(NULLIF(o.trade_type, ''), 'LUMPSUM')               AS sub_type,
                cm.client_id,
                COALESCE(cm.client_name, 'Unknown')                         AS client_name,
                NULL::TEXT                                                  AS fund_name,
                COALESCE(NULLIF(o.scheme_code, ''), 'Mutual Fund')          AS scheme_name,
                o.scheme_code::TEXT                                         AS scheme_code,
                NULL::VARCHAR                                               AS cep_ref_id,
                COALESCE(substring(regexp_replace(o.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::NUMERIC, 0) AS amount,
                NULL::NUMERIC                                               AS units,
                LOWER(COALESCE(NULLIF(o.order_status, ''), NULLIF(o.nse_status, ''), 'pending')) AS status,
                o.nse_order_id::TEXT                                        AS nse_order_id,
                o.created_at                                                AS date,
                1                                                           AS src_ord,
                ROW_NUMBER() OVER (ORDER BY o.created_at DESC, o.id)        AS src_rn
            FROM "trade".nse_mf_order o
            LEFT JOIN cm ON cm.linked_user_id = o.user_ref_id
            WHERE v_include_mf
              AND o.user_ref_id = ANY(v_user_ids)
              AND (v_mf_type IS NULL OR UPPER(o.trade_type)   = v_mf_type)
              AND (v_status  IS NULL OR UPPER(o.order_status) = v_status)
              AND (v_from    IS NULL OR o.created_at >= v_from)
              AND (v_to      IS NULL OR o.created_at <= v_to)
        ) x WHERE src_rn <= v_skip + v_limit
    ),
    merged AS (
        SELECT * FROM ceps UNION ALL SELECT * FROM mf
    ),
    ordered AS (
        SELECT m.*,
               ROW_NUMBER() OVER (ORDER BY
                   CASE WHEN v_sort = 'amount'      AND v_dir = 'asc'  THEN m.amount END ASC,
                   CASE WHEN v_sort = 'amount'      AND v_dir = 'desc' THEN m.amount END DESC,
                   CASE WHEN v_sort = 'client_name' AND v_dir = 'asc'  THEN m.client_name END ASC,
                   CASE WHEN v_sort = 'client_name' AND v_dir = 'desc' THEN m.client_name END DESC,
                   CASE WHEN v_sort NOT IN ('amount', 'client_name') AND v_dir = 'asc'  THEN m.date END ASC,
                   CASE WHEN v_sort NOT IN ('amount', 'client_name') AND v_dir = 'desc' THEN m.date END DESC,
                   m.src_ord, m.src_rn
               ) AS pos
        FROM merged m
    )
    SELECT * FROM ordered WHERE pos > v_skip AND pos <= v_skip + v_limit;

    OPEN p_rows FOR
        SELECT id, source, asset_type, sub_type, client_id, client_name, fund_name, scheme_name,
               scheme_code, cep_ref_id, amount, units, status, nse_order_id, date
        FROM tmp_unified_page ORDER BY pos;

    OPEN p_summary FOR
        SELECT v_page                                            AS page,
               v_limit                                           AS "limit",
               v_total                                           AS total,
               CEIL(v_total::NUMERIC / v_limit)::INT             AS total_pages,
               v_total                                           AS total_count,
               COALESCE((SELECT SUM(amount) FROM tmp_unified_page), 0) AS total_amount;

    OPEN p_by_type FOR
        SELECT asset_type, COUNT(*) AS count, SUM(amount) AS amount
        FROM tmp_unified_page GROUP BY asset_type ORDER BY MIN(pos);
END;
$$;

-- File: partner.sp_partner_onb_admin_approve.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onb_admin_approve(
    p_id           VARCHAR,
    p_admin_id     VARCHAR DEFAULT NULL,
    p_admin_email  VARCHAR DEFAULT NULL,
    p_admin_role   VARCHAR DEFAULT NULL,
    p_reviewed_by  VARCHAR DEFAULT NULL,   -- only for the Checker-approve applier path
    INOUT p_result        refcursor DEFAULT 'result_cursor',
    INOUT p_notifications refcursor DEFAULT 'notifications_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_partner     "referral".partner_user%ROWTYPE;
    v_has_admin   BOOLEAN := (p_admin_id IS NOT NULL OR p_admin_email IS NOT NULL);
    v_reviewed_by TEXT;
    v_code        TEXT;
    v_request_id  TEXT;
    v_notif_ids   INT[] := ARRAY[]::INT[];
    v_attempt     INT;
    -- for inline fn_pob_is_maker_only
    v_menu        JSONB;
    v_role        TEXT;
    v_profiles    JSONB;
    v_is_maker    BOOLEAN := FALSE;
    -- for inline fn_pob_admin_name / fn_js_trim
    v_admin_name  TEXT;
    v_ws_re       CONSTANT TEXT := E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$';
BEGIN
    SELECT * INTO v_partner FROM "referral".partner_user WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Application not found.'; END IF;
    IF v_partner.status <> 'UNDER_REVIEW' THEN
        RAISE EXCEPTION 'Only UNDER_REVIEW applications can be approved.';
    END IF;

    -- ── Inline fn_pob_is_maker_only('partner-onboarding') ───────
    v_is_maker := FALSE;
    IF p_admin_id IS NOT NULL THEN
        BEGIN
            SELECT CASE WHEN menu_access IS NULL OR jsonb_typeof(menu_access) = 'null'
                        THEN NULL ELSE menu_access END,
                   role::TEXT
            INTO v_menu, v_role
            FROM "ops".operations_user WHERE id = p_admin_id;
            IF NOT (v_menu IS NULL AND COALESCE(v_role, p_admin_role) IN ('SUPER_ADMIN', 'DEVELOPER')) THEN
                v_profiles := v_menu -> 'partner-onboarding' -> 'profiles';
                v_is_maker := COALESCE(v_profiles ? 'Maker' AND NOT (v_profiles ? 'Checker'), FALSE);
            END IF;
        EXCEPTION WHEN OTHERS THEN v_is_maker := FALSE;
        END;
    END IF;

    -- ── Maker-only: stage for Checker approval ──────────────────
    IF v_has_admin AND v_is_maker THEN
        v_request_id := 'c' || replace(gen_random_uuid()::text, '-', '');
        INSERT INTO "ops".approvalrequest
            (id, module, "actionType", "entityType", "entityId", payload, status,
             "requestedBy", "requestedByEmail", "createdAt")
        VALUES
            (v_request_id, 'partner-onboarding', 'PARTNER_ONBOARDING_APPROVE', 'PartnerUser', p_id,
             '{}'::jsonb, 'PENDING', p_admin_id, p_admin_email, NOW());

        -- Inline fn_pob_write_audit (failure → WARNING, not error)
        BEGIN
            INSERT INTO "ops".audit_logs
                (module, "actionType", "entityType", "entityId", "statusBefore", "statusAfter",
                 "actionReason", "adminEmail", "adminName", success, metadata, "createdAt")
            VALUES ('Partner Onboarding', 'Submitted for Approval', 'ApprovalRequest',
                    p_id, v_partner.status::TEXT, 'APPROVED',
                    'Field: Application Status — Approve',
                    p_admin_email, p_admin_email,
                    TRUE, jsonb_build_object('module', 'partner-onboarding',
                                             'actionType', 'PARTNER_ONBOARDING_APPROVE',
                                             'requestId', v_request_id, 'targetUserId', p_id), NOW());
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[ApprovalAudit] failed: %', SQLERRM;
        END;

        -- Inline fn_pob_notify_checkers('partner-onboarding', '/partner-onboarding')
        WITH _ins AS (
            INSERT INTO "ops".adminnotification
                (title, message, type, priority, is_read, admin_email, metadata, "createdAt", "updatedAt")
            SELECT 'Action Requires Review',
                   'Wants to approve partner application for '
                       || COALESCE(NULLIF(v_partner.full_name, ''), v_partner.email)
                       || ' (' || COALESCE(v_partner.email, '') || ')',
                   'APPROVAL_REQUEST', 'HIGH', FALSE, ou.email,
                   to_jsonb(jsonb_strip_nulls(jsonb_build_object(
                       'requestId',        v_request_id,
                       'module',           'partner-onboarding',
                       'route',            '/partner-onboarding',
                       'targetUserId',     p_id,
                       'requestedByEmail', p_admin_email
                   ))::TEXT),
                   NOW(), NOW()
            FROM "ops".operations_user ou
            WHERE ou.is_active = TRUE
              AND ou.email IS DISTINCT FROM p_admin_email
              AND (
                    ((ou.menu_access IS NULL OR jsonb_typeof(ou.menu_access) = 'null')
                      AND ou.role::TEXT IN ('SUPER_ADMIN', 'DEVELOPER'))
                 OR ((ou.menu_access -> 'partner-onboarding' -> 'enabled') IS DISTINCT FROM 'false'::jsonb
                      AND COALESCE(ou.menu_access -> 'partner-onboarding' -> 'profiles' ? 'Checker', FALSE))
              )
            RETURNING id
        )
        SELECT COALESCE(ARRAY_AGG(id), ARRAY[]::INT[]) INTO v_notif_ids FROM _ins;

        OPEN p_result FOR
        SELECT TRUE AS pending, 'Submitted for approval.' AS message, p_id AS id,
               v_partner.status AS status, NULL::TIMESTAMP AS reviewed_at, v_request_id AS request_id,
               v_partner.email AS email, v_partner.mobile AS mobile,
               v_partner.mobile_prefix AS mobile_prefix, v_partner.full_name AS full_name;
        OPEN p_notifications FOR
        SELECT * FROM "ops".adminnotification WHERE id = ANY(v_notif_ids) ORDER BY id;
        RETURN;
    END IF;

    -- ── Direct apply ────────────────────────────────────────────
    v_reviewed_by := COALESCE(NULLIF(p_reviewed_by, ''), NULLIF(p_admin_email, ''), NULLIF(p_admin_id, ''), 'admin');

    -- Permanent referral code — generated once, never regenerated.
    IF NULLIF(v_partner.referral_code, '') IS NULL THEN
        FOR v_attempt IN 1..5 LOOP
            v_code := UPPER(SUBSTRING(replace(gen_random_uuid()::text, '-', ''), 1, 10));
            EXIT WHEN NOT EXISTS (SELECT 1 FROM "referral".partner_user WHERE referral_code = v_code);
            v_code := NULL;
        END LOOP;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'Failed to generate a unique partner referral code after 5 attempts.';
        END IF;
    END IF;

    UPDATE "referral".partner_user SET
        status        = 'APPROVED',
        reviewed_at   = NOW(),
        reviewed_by   = v_reviewed_by,
        referral_code = COALESCE(v_code, referral_code),
        updated_at    = NOW()
    WHERE id = p_id;

    IF v_has_admin THEN
        -- Inline fn_pob_admin_name
        SELECT NULLIF(regexp_replace(CONCAT_WS(' ', NULLIF(first_name, ''), NULLIF(last_name, '')),
                                     v_ws_re, '', 'g'), '')
        INTO v_admin_name FROM "ops".operations_user WHERE id = p_admin_id;

        -- Inline fn_pob_write_audit
        BEGIN
            INSERT INTO "ops".audit_logs
                (module, "actionType", "entityType", "entityId", "statusBefore", "statusAfter",
                 "actionReason", "adminEmail", "adminName", success, metadata, "createdAt")
            VALUES ('Partner Onboarding', 'Application Approved', 'PartnerUser',
                    p_id, v_partner.status::TEXT, 'APPROVED',
                    'Field: Application Status — Approve',
                    p_admin_email, COALESCE(v_admin_name, p_admin_email),
                    TRUE, jsonb_build_object('module', 'partner-onboarding',
                                             'actionType', 'PARTNER_ONBOARDING_APPROVE',
                                             'direct', TRUE, 'targetUserId', p_id), NOW());
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[ApprovalAudit] failed: %', SQLERRM;
        END;
    END IF;

    OPEN p_result FOR
    SELECT FALSE AS pending, 'Application approved.' AS message, pu.id, pu.status, pu.reviewed_at,
           NULL::TEXT AS request_id, pu.referral_code,
           v_partner.email AS email, v_partner.mobile AS mobile,
           v_partner.mobile_prefix AS mobile_prefix, v_partner.full_name AS full_name
    FROM "referral".partner_user pu WHERE pu.id = p_id;
    OPEN p_notifications FOR
    SELECT * FROM "ops".adminnotification WHERE FALSE;
END;
$$;

-- File: partner.sp_partner_onb_admin_create.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onb_admin_create(
    p_full_name                VARCHAR,
    p_email                    VARCHAR,
    p_mobile                   VARCHAR,
    p_password_hash            VARCHAR,
    p_password_length          INT,
    p_account_type             VARCHAR,
    p_company_type             VARCHAR,
    p_date_of_birth            VARCHAR,
    p_firm_name                VARCHAR,
    p_entity_type              VARCHAR,
    p_sebi_registration_number VARCHAR,
    p_arn_number               VARCHAR,
    p_pan_number               VARCHAR,
    p_aadhaar_number           VARCHAR,
    p_address_line1            VARCHAR,
    p_address_line2            VARCHAR,
    p_city                     VARCHAR,
    p_state                    VARCHAR,
    p_pin_code                 VARCHAR,
    p_has_pan_image            BOOLEAN,
    p_has_aadhaar_front        BOOLEAN,
    p_has_aadhaar_back         BOOLEAN,
    p_has_bank_doc             BOOLEAN,
    p_bank_name                VARCHAR,
    p_bank_account_number      VARCHAR,
    p_bank_account_holder_name VARCHAR,
    p_ifsc_code                VARCHAR,
    p_gst_number               VARCHAR,
    p_doc_type                 VARCHAR,
    p_mobile_prefix            VARCHAR DEFAULT '+91',
    p_admin_id                 VARCHAR DEFAULT NULL,
    p_admin_email              VARCHAR DEFAULT NULL,
    p_admin_role               VARCHAR DEFAULT NULL,
    p_docs                     JSONB   DEFAULT '[]'::jsonb,
    p_partner_id               VARCHAR DEFAULT NULL,
    p_from_approval            BOOLEAN DEFAULT FALSE,
    p_age                      INT     DEFAULT NULL,
    INOUT p_result        refcursor DEFAULT 'result_cursor',
    INOUT p_notifications refcursor DEFAULT 'notifications_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_has_admin  BOOLEAN := (p_admin_id IS NOT NULL OR p_admin_email IS NOT NULL);
    v_ws_re      CONSTANT TEXT := E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$';
    v_email      TEXT := LOWER(regexp_replace(p_email, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));
    v_mobile     TEXT := regexp_replace(p_mobile, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
    v_dob        TIMESTAMP;
    v_age        INT;
    v_pan        TEXT;
    v_aadhaar    TEXT;
    v_account    TEXT;
    v_ifsc       TEXT;
    v_gst        TEXT;
    v_doc_type   TEXT;
    v_id         TEXT;
    v_request_id TEXT;
    v_pending    TEXT;
    v_data       JSONB;
    v_notif_ids  INT[] := ARRAY[]::INT[];
    -- for inline fn_pob_is_maker_only
    v_menu       JSONB;
    v_role       TEXT;
    v_profiles   JSONB;
    v_is_maker   BOOLEAN := FALSE;
    -- for inline fn_pob_admin_name
    v_admin_name TEXT;
    -- for inline fn_js_parse_date
    v_dob_s      TEXT;
    v_dob_m      TEXT[];
    v_dob_y      INT;
    v_dob_mo     INT;
    v_dob_d      INT;
    v_dob_hh     INT;
    v_dob_mi     INT;
    v_dob_ss     NUMERIC;
    v_dob_tz     TEXT;
    v_dob_base   TIMESTAMP;
BEGIN
    IF NOT p_from_approval THEN
        -- ── Basic validation ────────────────────────────────────
        IF NULLIF(regexp_replace(p_full_name, v_ws_re, '', 'g'), '') IS NULL THEN RAISE EXCEPTION 'Full name is required.'; END IF;
        IF NULLIF(v_email, '') IS NULL THEN RAISE EXCEPTION 'Email is required.'; END IF;
        IF NULLIF(v_mobile, '') IS NULL THEN RAISE EXCEPTION 'Mobile is required.'; END IF;
        IF p_password_length IS NULL OR p_password_length = 0 THEN RAISE EXCEPTION 'Password is required.'; END IF;
        IF p_password_length < 8 THEN RAISE EXCEPTION 'Password must be at least 8 characters.'; END IF;
        IF regexp_replace(p_email, v_ws_re, '', 'g') !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' THEN RAISE EXCEPTION 'Invalid email address.'; END IF;
        IF v_mobile !~ '^[6-9]\d{9}$' THEN
            RAISE EXCEPTION 'Invalid mobile number. Must be 10 digits starting with 6–9.';
        END IF;

        IF p_account_type IS NULL OR p_account_type NOT IN ('INDIVIDUAL', 'Company', 'LLP', 'PARTNERSHIP', 'SOLE_PROPRIETORSHIP') THEN
            RAISE EXCEPTION 'Valid account type is required.';
        END IF;
        IF p_account_type <> 'INDIVIDUAL' AND NULLIF(p_company_type, '') IS NULL THEN
            RAISE EXCEPTION 'Business category is required for non-individual accounts.';
        END IF;
        IF NULLIF(p_company_type, '') IS NOT NULL AND p_company_type NOT IN
           ('MUTUAL_FUNDS', 'LOAN_AGGREGATOR', 'DSA_LOANS', 'INSURANCE', 'FMCG',
            'INDUSTRIAL_GOODS', 'FINANCIAL_SERVICES', 'MARKETING_AGENCY') THEN
            RAISE EXCEPTION 'Invalid business category.';
        END IF;
    END IF;

    -- ── Inline fn_js_parse_date(p_date_of_birth) ───────────────
    -- JS `new Date(str)`: YYYY, YYYY-MM, YYYY-MM-DD[T...], M/D/YYYY; NULL = Invalid Date.
    v_dob := NULL;
    IF NULLIF(p_date_of_birth, '') IS NOT NULL THEN
        v_dob_s := regexp_replace(p_date_of_birth, v_ws_re, '', 'g');
        v_dob_hh := 0; v_dob_mi := 0; v_dob_ss := 0; v_dob_tz := NULL; v_dob_mo := 0;
        IF v_dob_s IS NOT NULL AND v_dob_s <> '' THEN
            IF v_dob_s ~ '^\d{4}$' THEN
                v_dob := make_timestamp(v_dob_s::INT, 1, 1, 0, 0, 0);
            ELSE
                v_dob_m := regexp_match(v_dob_s, '^(\d{4})-(\d{2})$');
                IF v_dob_m IS NOT NULL THEN
                    v_dob_y := v_dob_m[1]::INT; v_dob_mo := v_dob_m[2]::INT;
                    IF v_dob_mo >= 1 AND v_dob_mo <= 12 THEN
                        v_dob := make_timestamp(v_dob_y, v_dob_mo, 1, 0, 0, 0);
                    END IF;
                ELSE
                    v_dob_m := regexp_match(v_dob_s,
                        '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF v_dob_m IS NOT NULL THEN
                        v_dob_y := v_dob_m[1]::INT; v_dob_mo := v_dob_m[2]::INT; v_dob_d := v_dob_m[3]::INT;
                        IF v_dob_m[4] IS NOT NULL THEN
                            v_dob_hh := v_dob_m[4]::INT; v_dob_mi := v_dob_m[5]::INT;
                            v_dob_ss := COALESCE(v_dob_m[6]::NUMERIC, 0); v_dob_tz := v_dob_m[7];
                            IF v_dob_hh > 24 OR v_dob_mi > 59 OR v_dob_ss >= 60 THEN
                                v_dob_mo := 0;
                            END IF;
                        END IF;
                    ELSE
                        v_dob_m := regexp_match(v_dob_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF v_dob_m IS NOT NULL THEN
                            v_dob_mo := v_dob_m[1]::INT; v_dob_d := v_dob_m[2]::INT; v_dob_y := v_dob_m[3]::INT;
                        END IF;
                    END IF;
                    IF v_dob_mo >= 1 AND v_dob_mo <= 12 AND v_dob_d >= 1 AND v_dob_d <= 31 THEN
                        v_dob_base := make_timestamp(v_dob_y, v_dob_mo, 1, 0, 0, 0)
                                    + make_interval(days => v_dob_d - 1)
                                    + make_interval(hours => v_dob_hh, mins => v_dob_mi, secs => v_dob_ss);
                        IF v_dob_tz IS NOT NULL AND v_dob_tz <> 'Z' THEN
                            v_dob_tz := replace(v_dob_tz, ':', '');
                            v_dob_base := v_dob_base
                                - (CASE WHEN left(v_dob_tz, 1) = '-' THEN -1 ELSE 1 END)
                                * make_interval(hours => substr(v_dob_tz, 2, 2)::INT,
                                                mins  => substr(v_dob_tz, 4, 2)::INT);
                        END IF;
                        v_dob := v_dob_base::TIMESTAMP(3);
                    END IF;
                END IF;
            END IF;
        END IF;

        IF v_dob IS NULL THEN RAISE EXCEPTION 'Invalid date of birth.'; END IF;

        IF p_from_approval THEN
            v_age := p_age;
        ELSE
            v_age := EXTRACT(YEAR FROM NOW())::INT - EXTRACT(YEAR FROM v_dob)::INT;
            IF EXTRACT(MONTH FROM NOW()) < EXTRACT(MONTH FROM v_dob)
               OR (EXTRACT(MONTH FROM NOW()) = EXTRACT(MONTH FROM v_dob)
                   AND EXTRACT(DAY FROM NOW()) < EXTRACT(DAY FROM v_dob)) THEN
                v_age := v_age - 1;
            END IF;
            IF v_age < 18 THEN
                RAISE EXCEPTION 'Partner must be at least 18 years old.';
            END IF;
        END IF;
    ELSIF p_from_approval THEN
        v_age := p_age;
    END IF;

    v_pan      := UPPER(regexp_replace(p_pan_number, v_ws_re, '', 'g'));
    v_aadhaar  := REGEXP_REPLACE(COALESCE(p_aadhaar_number, ''), '\s', '', 'g');
    v_account  := REGEXP_REPLACE(COALESCE(p_bank_account_number, ''), '\D', '', 'g');
    v_ifsc     := UPPER(regexp_replace(COALESCE(p_ifsc_code, ''), v_ws_re, '', 'g'));
    v_gst      := UPPER(NULLIF(regexp_replace(p_gst_number, v_ws_re, '', 'g'), ''));
    v_doc_type := REPLACE(UPPER(COALESCE(NULLIF(p_doc_type, ''), 'CANCELLED_CHEQUE')), '-', '_');

    IF NOT p_from_approval THEN
        IF p_account_type <> 'INDIVIDUAL' THEN
            IF NULLIF(regexp_replace(p_firm_name, v_ws_re, '', 'g'), '') IS NULL THEN RAISE EXCEPTION 'Firm name is required for non-individual accounts.'; END IF;
            IF NULLIF(regexp_replace(p_entity_type, v_ws_re, '', 'g'), '') IS NULL THEN RAISE EXCEPTION 'Entity type is required for non-individual accounts.'; END IF;
        END IF;

        IF NULLIF(p_pan_number, '') IS NULL THEN RAISE EXCEPTION 'PAN number is required.'; END IF;
        IF v_pan !~ '^[A-Z]{5}[0-9]{4}[A-Z]{1}$' THEN RAISE EXCEPTION 'Invalid PAN number format. Expected: ABCDE1234F'; END IF;

        IF NULLIF(p_aadhaar_number, '') IS NULL THEN RAISE EXCEPTION 'Aadhaar number is required.'; END IF;
        IF v_aadhaar !~ '^\d{12}$' THEN RAISE EXCEPTION 'Aadhaar must be exactly 12 digits.'; END IF;

        IF NULLIF(regexp_replace(p_address_line1, v_ws_re, '', 'g'), '') IS NULL THEN RAISE EXCEPTION 'Address Line 1 is required.'; END IF;
        IF NULLIF(regexp_replace(p_city, v_ws_re, '', 'g'), '') IS NULL THEN RAISE EXCEPTION 'City is required.'; END IF;
        IF NULLIF(regexp_replace(p_state, v_ws_re, '', 'g'), '') IS NULL THEN RAISE EXCEPTION 'State is required.'; END IF;
        IF p_pin_code IS NULL OR p_pin_code !~ '^\d{6}$' THEN RAISE EXCEPTION 'Pin code must be exactly 6 digits.'; END IF;

        IF NOT COALESCE(p_has_pan_image, FALSE)     THEN RAISE EXCEPTION 'PAN card image is required.'; END IF;
        IF NOT COALESCE(p_has_aadhaar_front, FALSE) THEN RAISE EXCEPTION 'Aadhaar front image is required.'; END IF;
        IF NOT COALESCE(p_has_aadhaar_back, FALSE)  THEN RAISE EXCEPTION 'Aadhaar back image is required.'; END IF;
        IF NOT COALESCE(p_has_bank_doc, FALSE)      THEN RAISE EXCEPTION 'Bank verification document is required.'; END IF;

        IF NULLIF(regexp_replace(p_bank_name, v_ws_re, '', 'g'), '') IS NULL THEN RAISE EXCEPTION 'Bank name is required.'; END IF;
        IF v_account = '' OR LENGTH(v_account) < 9 OR LENGTH(v_account) > 18 THEN
            RAISE EXCEPTION 'Bank account number must be 9–18 digits.';
        END IF;
        IF NULLIF(regexp_replace(p_bank_account_holder_name, v_ws_re, '', 'g'), '') IS NULL THEN RAISE EXCEPTION 'Name as per bank is required.'; END IF;
        IF v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' THEN RAISE EXCEPTION 'Invalid IFSC code. Expected format: ABCD0123456'; END IF;
        IF v_gst IS NOT NULL AND v_gst !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$' THEN
            RAISE EXCEPTION 'Invalid GST number format.';
        END IF;
        IF v_doc_type NOT IN ('CANCELLED_CHEQUE', 'BANK_STATEMENT', 'PASSBOOK') THEN
            RAISE EXCEPTION 'doc_type must be CANCELLED_CHEQUE, BANK_STATEMENT, or PASSBOOK.';
        END IF;
    END IF;

    -- ── Duplicate check (both paths) ────────────────────────────
    IF EXISTS (SELECT 1 FROM "referral".partner_user WHERE LOWER(email) = v_email) THEN
        RAISE EXCEPTION 'A partner with this email already exists.';
    END IF;
    IF EXISTS (SELECT 1 FROM "referral".partner_user WHERE mobile = v_mobile) THEN
        RAISE EXCEPTION 'A partner with this mobile already exists.';
    END IF;

    -- partnerData exactly as Node builds it
    v_data := jsonb_build_object(
        'full_name',                regexp_replace(p_full_name, v_ws_re, '', 'g'),
        'email',                    v_email,
        'mobile',                   v_mobile,
        'mobile_prefix',            p_mobile_prefix,
        'password_hash',            p_password_hash,
        'account_type',             p_account_type,
        'company_type',             CASE WHEN p_account_type <> 'INDIVIDUAL' THEN NULLIF(p_company_type, '') END,
        'date_of_birth',            to_char(v_dob, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
        'age',                      v_age,
        'firm_name',                NULLIF(regexp_replace(p_firm_name, v_ws_re, '', 'g'), ''),
        'entity_type',              NULLIF(regexp_replace(p_entity_type, v_ws_re, '', 'g'), ''),
        'sebi_registration_number', NULLIF(regexp_replace(p_sebi_registration_number, v_ws_re, '', 'g'), ''),
        'arn_number',               NULLIF(regexp_replace(p_arn_number, v_ws_re, '', 'g'), ''),
        'pan_number',               v_pan,
        'aadhaar_number',           v_aadhaar,
        'address_line1',            regexp_replace(p_address_line1, v_ws_re, '', 'g'),
        'address_line2',            NULLIF(regexp_replace(p_address_line2, v_ws_re, '', 'g'), ''),
        'city',                     regexp_replace(p_city, v_ws_re, '', 'g'),
        'state',                    regexp_replace(p_state, v_ws_re, '', 'g'),
        'pin_code',                 p_pin_code,
        'bank_name',                regexp_replace(p_bank_name, v_ws_re, '', 'g'),
        'bank_account_number',      v_account,
        'bank_account_holder_name', regexp_replace(p_bank_account_holder_name, v_ws_re, '', 'g'),
        'ifsc_code',                v_ifsc,
        'gst_number',               v_gst,
        'bank_verification_doc_type', v_doc_type
    );

    -- ── Inline fn_pob_is_maker_only('partner-onboarding') ───────
    v_is_maker := FALSE;
    IF p_admin_id IS NOT NULL THEN
        BEGIN
            SELECT CASE WHEN menu_access IS NULL OR jsonb_typeof(menu_access) = 'null'
                        THEN NULL ELSE menu_access END,
                   role::TEXT
            INTO v_menu, v_role
            FROM "ops".operations_user WHERE id = p_admin_id;
            IF NOT (v_menu IS NULL AND COALESCE(v_role, p_admin_role) IN ('SUPER_ADMIN', 'DEVELOPER')) THEN
                v_profiles := v_menu -> 'partner-onboarding' -> 'profiles';
                v_is_maker := COALESCE(v_profiles ? 'Maker' AND NOT (v_profiles ? 'Checker'), FALSE);
            END IF;
        EXCEPTION WHEN OTHERS THEN v_is_maker := FALSE;
        END;
    END IF;

    -- ── Maker-only: stage instead of creating ──────────────────
    IF v_has_admin AND v_is_maker THEN
        v_id         := COALESCE(p_partner_id, gen_random_uuid()::text);
        v_pending    := '_pending/' || v_id;
        v_request_id := 'c' || replace(gen_random_uuid()::text, '-', '');

        INSERT INTO "ops".approvalrequest
            (id, module, "actionType", "entityType", "entityId", payload, status,
             "requestedBy", "requestedByEmail", "createdAt")
        VALUES
            (v_request_id, 'partner-onboarding', 'PARTNER_ONBOARDING_CREATE', 'PartnerUser', v_id,
             jsonb_build_object('partnerData', v_data, 'docs', COALESCE(p_docs, '[]'::jsonb), 'pendingDir', v_pending),
             'PENDING', p_admin_id, p_admin_email, NOW());

        -- Inline fn_pob_write_audit
        BEGIN
            INSERT INTO "ops".audit_logs
                (module, "actionType", "entityType", "entityId", "statusBefore", "statusAfter",
                 "actionReason", "adminEmail", "adminName", success, metadata, "createdAt")
            VALUES ('Partner Onboarding', 'Submitted for Approval', 'ApprovalRequest',
                    v_id, NULL, 'UNDER_REVIEW',
                    'New partner created: ' || regexp_replace(p_full_name, v_ws_re, '', 'g') || ' (' || v_email || ')',
                    p_admin_email, p_admin_email,
                    TRUE, jsonb_build_object('module', 'partner-onboarding',
                                             'actionType', 'PARTNER_ONBOARDING_CREATE',
                                             'requestId', v_request_id), NOW());
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[ApprovalAudit] failed: %', SQLERRM;
        END;

        -- Inline fn_pob_notify_checkers('partner-onboarding', '/partner-onboarding')
        WITH _ins AS (
            INSERT INTO "ops".adminnotification
                (title, message, type, priority, is_read, admin_email, metadata, "createdAt", "updatedAt")
            SELECT 'Action Requires Review',
                   'Wants to add partner ' || regexp_replace(p_full_name, v_ws_re, '', 'g')
                       || ' (' || v_email || ', ' || v_mobile || ')',
                   'APPROVAL_REQUEST', 'HIGH', FALSE, ou.email,
                   to_jsonb(jsonb_strip_nulls(jsonb_build_object(
                       'requestId',        v_request_id,
                       'module',           'partner-onboarding',
                       'route',            '/partner-onboarding',
                       'targetUserId',     NULL::TEXT,
                       'requestedByEmail', p_admin_email
                   ))::TEXT),
                   NOW(), NOW()
            FROM "ops".operations_user ou
            WHERE ou.is_active = TRUE
              AND ou.email IS DISTINCT FROM p_admin_email
              AND (
                    ((ou.menu_access IS NULL OR jsonb_typeof(ou.menu_access) = 'null')
                      AND ou.role::TEXT IN ('SUPER_ADMIN', 'DEVELOPER'))
                 OR ((ou.menu_access -> 'partner-onboarding' -> 'enabled') IS DISTINCT FROM 'false'::jsonb
                      AND COALESCE(ou.menu_access -> 'partner-onboarding' -> 'profiles' ? 'Checker', FALSE))
              )
            RETURNING id
        )
        SELECT COALESCE(ARRAY_AGG(id), ARRAY[]::INT[]) INTO v_notif_ids FROM _ins;

        OPEN p_result FOR
        SELECT TRUE AS pending, 'Submitted for approval.' AS message, v_id AS id,
               regexp_replace(p_full_name, v_ws_re, '', 'g') AS full_name,
               v_email AS email, v_mobile AS mobile,
               NULL::TEXT AS status, v_request_id AS request_id, v_pending AS pending_dir;
        OPEN p_notifications FOR
        SELECT * FROM "ops".adminnotification WHERE id = ANY(v_notif_ids) ORDER BY id;
        RETURN;
    END IF;

    -- ── Create partner record ───────────────────────────────────
    v_id := COALESCE(p_partner_id, 'c' || replace(gen_random_uuid()::text, '-', ''));

    INSERT INTO "referral".partner_user
        (id, full_name, email, mobile, mobile_prefix, password_hash,
         account_type, company_type, date_of_birth, age,
         firm_name, entity_type, sebi_registration_number, arn_number,
         pan_number, aadhaar_number, address_line1, address_line2, city, state, pin_code,
         bank_name, bank_account_number, bank_account_holder_name, ifsc_code, gst_number,
         bank_verification_doc_type,
         email_verified, mobile_verified, agreement_accepted, agreement_accepted_at,
         agreement_pdf_version, onboarding_step, status, submitted_at, created_at, updated_at)
    VALUES
        (v_id, v_data->>'full_name', v_email, v_mobile, p_mobile_prefix, p_password_hash,
         p_account_type::partner_account_type, (v_data->>'company_type')::partner_company_type, v_dob, v_age,
         v_data->>'firm_name', v_data->>'entity_type', v_data->>'sebi_registration_number', v_data->>'arn_number',
         v_pan, v_aadhaar, v_data->>'address_line1', v_data->>'address_line2', v_data->>'city', v_data->>'state', p_pin_code,
         v_data->>'bank_name', v_account, v_data->>'bank_account_holder_name', v_ifsc, v_gst,
         v_doc_type,
         TRUE, TRUE, TRUE, NOW(),
         'v1', 6, 'UNDER_REVIEW', NOW(), NOW(), NOW());

    IF v_has_admin THEN
        -- Inline fn_pob_admin_name
        SELECT NULLIF(regexp_replace(CONCAT_WS(' ', NULLIF(first_name, ''), NULLIF(last_name, '')),
                                     v_ws_re, '', 'g'), '')
        INTO v_admin_name FROM "ops".operations_user WHERE id = p_admin_id;

        -- Inline fn_pob_write_audit
        BEGIN
            INSERT INTO "ops".audit_logs
                (module, "actionType", "entityType", "entityId", "statusBefore", "statusAfter",
                 "actionReason", "adminEmail", "adminName", success, metadata, "createdAt")
            VALUES ('Partner Onboarding', 'Partner Created', 'PartnerUser',
                    v_id, NULL, 'UNDER_REVIEW',
                    'New partner created: ' || regexp_replace(p_full_name, v_ws_re, '', 'g') || ' (' || v_email || ')',
                    p_admin_email, COALESCE(v_admin_name, p_admin_email),
                    TRUE, jsonb_build_object('module', 'partner-onboarding',
                                             'actionType', 'PARTNER_ONBOARDING_CREATE',
                                             'direct', TRUE, 'targetUserId', v_id), NOW());
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[ApprovalAudit] failed: %', SQLERRM;
        END;
    END IF;

    OPEN p_result FOR
    SELECT FALSE AS pending, 'Partner submitted for review successfully.' AS message, id, full_name,
           email, mobile, status, NULL::TEXT AS request_id, NULL::TEXT AS pending_dir
    FROM "referral".partner_user WHERE id = v_id;
    OPEN p_notifications FOR
    SELECT * FROM "ops".adminnotification WHERE FALSE;
END;
$$;

-- File: partner.sp_partner_onb_admin_detail.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onb_admin_detail(
    p_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "referral".partner_user WHERE id = p_id) THEN
        RAISE EXCEPTION 'Application not found.';
    END IF;

    OPEN p_cursor FOR
    SELECT
        id, email, mobile, mobile_prefix, full_name, account_type, company_type,
        date_of_birth, age, onboarding_step,
        firm_name, sebi_registration_number, arn_number, entity_type,
        pan_number, pan_image_url, aadhaar_number, aadhaar_front_url, aadhaar_back_url,
        address_line1, address_line2, city, state, pin_code,
        bank_name, bank_account_number, bank_account_holder_name, ifsc_code, gst_number,
        bank_verification_doc_type, bank_verification_doc_url,
        signature_url,
        agreement_accepted, agreement_accepted_at, agreement_pdf_version,
        status, submitted_at, reviewed_at, reviewed_by, rejection_reason, created_at
    FROM "referral".partner_user
    WHERE id = p_id;
END;
$$;

-- File: partner.sp_partner_onb_admin_list.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onb_admin_list(
    p_page          INT     DEFAULT 1,
    p_limit         INT     DEFAULT 20,
    p_status        VARCHAR DEFAULT NULL,
    p_search        VARCHAR DEFAULT NULL,
    p_search_field  VARCHAR DEFAULT NULL,
    INOUT p_data       refcursor DEFAULT 'data_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page   INT := GREATEST(1, COALESCE(NULLIF(p_page, 0), 1));
    v_limit  INT := LEAST(100, GREATEST(1, COALESCE(NULLIF(p_limit, 0), 20)));
    v_terms  TEXT[];
    v_fields TEXT[];
    v_total  INT;
    -- inline fn_js_trim whitespace regex (JS String.prototype.trim Unicode set)
    v_ws_re  CONSTANT TEXT := E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$';
BEGIN
    -- Unknown status: Prisma rejects the enum value and Node answers 500 'Internal server error.'
    IF NULLIF(p_status, '') IS NOT NULL
       AND NOT (p_status = ANY (enum_range(NULL::partner_status)::TEXT[])) THEN
        RAISE EXCEPTION 'Internal server error.';
    END IF;

    -- Split terms (JS-trimmed, blanks dropped) and fields (JS-trimmed, kept positional)
    IF p_search IS NOT NULL AND regexp_replace(p_search, v_ws_re, '', 'g') <> '' THEN
        SELECT ARRAY_AGG(t ORDER BY ord) INTO v_terms
        FROM (
            SELECT regexp_replace(x, v_ws_re, '', 'g') AS t, ord
            FROM unnest(string_to_array(p_search, ',')) WITH ORDINALITY AS u(x, ord)
        ) s WHERE t <> '';

        IF p_search_field IS NOT NULL AND p_search_field <> '' THEN
            SELECT ARRAY_AGG(regexp_replace(x, v_ws_re, '', 'g') ORDER BY ord) INTO v_fields
            FROM unnest(string_to_array(p_search_field, ',')) WITH ORDINALITY AS u(x, ord);
        END IF;
    END IF;

    -- Inline fn_pob_list_ids for COUNT
    SELECT COUNT(*) INTO v_total
    FROM "referral".partner_user pu
    WHERE (CASE WHEN p_status IS NOT NULL AND p_status <> ''
                THEN pu.status::TEXT = p_status
                ELSE pu.status::TEXT IN ('UNDER_REVIEW', 'APPROVED', 'REJECTED', 'SUBMITTED') END)
      AND NOT EXISTS (
            SELECT 1
            FROM unnest(COALESCE(v_terms, ARRAY[]::TEXT[])) WITH ORDINALITY AS t(term, i)
            CROSS JOIN LATERAL (
                SELECT '%' || t.term || '%' AS pat,
                       COALESCE(v_fields[t.i], '') AS fld
            ) q
            WHERE NOT COALESCE(CASE q.fld
                    WHEN 'name'   THEN pu.full_name ILIKE q.pat
                    WHEN 'email'  THEN pu.email     ILIKE q.pat
                    WHEN 'mobile' THEN pu.mobile    ILIKE q.pat
                    ELSE (pu.full_name ILIKE q.pat OR pu.email ILIKE q.pat OR pu.mobile ILIKE q.pat)
                  END, FALSE)
      );

    -- Inline fn_pob_list_ids for paginated data
    OPEN p_data FOR
    SELECT pu.id, pu.full_name, pu.email, pu.mobile, pu.account_type, pu.company_type,
           pu.status, pu.submitted_at, pu.reviewed_at, pu.reviewed_by, pu.referral_code
    FROM "referral".partner_user pu
    WHERE (CASE WHEN p_status IS NOT NULL AND p_status <> ''
                THEN pu.status::TEXT = p_status
                ELSE pu.status::TEXT IN ('UNDER_REVIEW', 'APPROVED', 'REJECTED', 'SUBMITTED') END)
      AND NOT EXISTS (
            SELECT 1
            FROM unnest(COALESCE(v_terms, ARRAY[]::TEXT[])) WITH ORDINALITY AS t(term, i)
            CROSS JOIN LATERAL (
                SELECT '%' || t.term || '%' AS pat,
                       COALESCE(v_fields[t.i], '') AS fld
            ) q
            WHERE NOT COALESCE(CASE q.fld
                    WHEN 'name'   THEN pu.full_name ILIKE q.pat
                    WHEN 'email'  THEN pu.email     ILIKE q.pat
                    WHEN 'mobile' THEN pu.mobile    ILIKE q.pat
                    ELSE (pu.full_name ILIKE q.pat OR pu.email ILIKE q.pat OR pu.mobile ILIKE q.pat)
                  END, FALSE)
      )
    ORDER BY pu.submitted_at DESC NULLS LAST, pu.id
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_total AS total, v_page AS page, v_limit AS "limit",
           CEIL(v_total::NUMERIC / v_limit)::INT AS "totalPages";
END;
$$;

-- File: partner.sp_partner_onb_admin_reject.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onb_admin_reject(
    p_id               VARCHAR,
    p_rejection_reason TEXT,
    p_admin_id         VARCHAR DEFAULT NULL,
    p_admin_email      VARCHAR DEFAULT NULL,
    p_admin_role       VARCHAR DEFAULT NULL,
    p_reviewed_by      VARCHAR DEFAULT NULL,   -- only for the Checker-approve applier path
    INOUT p_result        refcursor DEFAULT 'result_cursor',
    INOUT p_notifications refcursor DEFAULT 'notifications_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_partner     "referral".partner_user%ROWTYPE;
    v_has_admin   BOOLEAN := (p_admin_id IS NOT NULL OR p_admin_email IS NOT NULL);
    v_ws_re       CONSTANT TEXT := E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$';
    v_reason      TEXT := regexp_replace(p_rejection_reason, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
    v_reviewed_by TEXT;
    v_request_id  TEXT;
    v_notif_ids   INT[] := ARRAY[]::INT[];
    -- for inline fn_pob_is_maker_only
    v_menu        JSONB;
    v_role        TEXT;
    v_profiles    JSONB;
    v_is_maker    BOOLEAN := FALSE;
    -- for inline fn_pob_admin_name
    v_admin_name  TEXT;
BEGIN
    IF v_reason IS NULL OR v_reason = '' THEN
        RAISE EXCEPTION 'A rejection reason is required.';
    END IF;

    SELECT * INTO v_partner FROM "referral".partner_user WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Application not found.'; END IF;
    IF v_partner.status <> 'UNDER_REVIEW' THEN
        RAISE EXCEPTION 'Only UNDER_REVIEW applications can be rejected.';
    END IF;

    -- ── Inline fn_pob_is_maker_only('partner-onboarding') ───────
    v_is_maker := FALSE;
    IF p_admin_id IS NOT NULL THEN
        BEGIN
            SELECT CASE WHEN menu_access IS NULL OR jsonb_typeof(menu_access) = 'null'
                        THEN NULL ELSE menu_access END,
                   role::TEXT
            INTO v_menu, v_role
            FROM "ops".operations_user WHERE id = p_admin_id;
            IF NOT (v_menu IS NULL AND COALESCE(v_role, p_admin_role) IN ('SUPER_ADMIN', 'DEVELOPER')) THEN
                v_profiles := v_menu -> 'partner-onboarding' -> 'profiles';
                v_is_maker := COALESCE(v_profiles ? 'Maker' AND NOT (v_profiles ? 'Checker'), FALSE);
            END IF;
        EXCEPTION WHEN OTHERS THEN v_is_maker := FALSE;
        END;
    END IF;

    -- ── Maker-only: stage for Checker approval ──────────────────
    IF v_has_admin AND v_is_maker THEN
        v_request_id := 'c' || replace(gen_random_uuid()::text, '-', '');
        INSERT INTO "ops".approvalrequest
            (id, module, "actionType", "entityType", "entityId", payload, status,
             "requestedBy", "requestedByEmail", "createdAt")
        VALUES
            (v_request_id, 'partner-onboarding', 'PARTNER_ONBOARDING_REJECT', 'PartnerUser', p_id,
             jsonb_build_object('rejection_reason', v_reason), 'PENDING', p_admin_id, p_admin_email, NOW());

        -- Inline fn_pob_write_audit
        BEGIN
            INSERT INTO "ops".audit_logs
                (module, "actionType", "entityType", "entityId", "statusBefore", "statusAfter",
                 "actionReason", "adminEmail", "adminName", success, metadata, "createdAt")
            VALUES ('Partner Onboarding', 'Submitted for Approval', 'ApprovalRequest',
                    p_id, v_partner.status::TEXT, 'REJECTED',
                    'Field: Application Status — Reject (' || v_reason || ')',
                    p_admin_email, p_admin_email,
                    TRUE, jsonb_build_object('module', 'partner-onboarding',
                                             'actionType', 'PARTNER_ONBOARDING_REJECT',
                                             'requestId', v_request_id, 'targetUserId', p_id), NOW());
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[ApprovalAudit] failed: %', SQLERRM;
        END;

        -- Inline fn_pob_notify_checkers('partner-onboarding', '/partner-onboarding')
        WITH _ins AS (
            INSERT INTO "ops".adminnotification
                (title, message, type, priority, is_read, admin_email, metadata, "createdAt", "updatedAt")
            SELECT 'Action Requires Review',
                   'Wants to reject partner application for '
                       || COALESCE(NULLIF(v_partner.full_name, ''), v_partner.email)
                       || ' (' || COALESCE(v_partner.email, '') || ') — ' || v_reason,
                   'APPROVAL_REQUEST', 'HIGH', FALSE, ou.email,
                   to_jsonb(jsonb_strip_nulls(jsonb_build_object(
                       'requestId',        v_request_id,
                       'module',           'partner-onboarding',
                       'route',            '/partner-onboarding',
                       'targetUserId',     p_id,
                       'requestedByEmail', p_admin_email
                   ))::TEXT),
                   NOW(), NOW()
            FROM "ops".operations_user ou
            WHERE ou.is_active = TRUE
              AND ou.email IS DISTINCT FROM p_admin_email
              AND (
                    ((ou.menu_access IS NULL OR jsonb_typeof(ou.menu_access) = 'null')
                      AND ou.role::TEXT IN ('SUPER_ADMIN', 'DEVELOPER'))
                 OR ((ou.menu_access -> 'partner-onboarding' -> 'enabled') IS DISTINCT FROM 'false'::jsonb
                      AND COALESCE(ou.menu_access -> 'partner-onboarding' -> 'profiles' ? 'Checker', FALSE))
              )
            RETURNING id
        )
        SELECT COALESCE(ARRAY_AGG(id), ARRAY[]::INT[]) INTO v_notif_ids FROM _ins;

        OPEN p_result FOR
        SELECT TRUE AS pending, 'Submitted for approval.' AS message, p_id AS id,
               v_partner.status AS status, NULL::TEXT AS rejection_reason, v_request_id AS request_id,
               v_partner.email AS email, v_partner.mobile AS mobile,
               v_partner.mobile_prefix AS mobile_prefix, v_partner.full_name AS full_name;
        OPEN p_notifications FOR
        SELECT * FROM "ops".adminnotification WHERE id = ANY(v_notif_ids) ORDER BY id;
        RETURN;
    END IF;

    -- ── Direct apply ────────────────────────────────────────────
    v_reviewed_by := COALESCE(NULLIF(p_reviewed_by, ''), NULLIF(p_admin_email, ''), NULLIF(p_admin_id, ''), 'admin');

    UPDATE "referral".partner_user SET
        status           = 'REJECTED',
        rejection_reason = v_reason,
        reviewed_at      = NOW(),
        reviewed_by      = v_reviewed_by,
        updated_at       = NOW()
    WHERE id = p_id;

    IF v_has_admin THEN
        -- Inline fn_pob_admin_name
        SELECT NULLIF(regexp_replace(CONCAT_WS(' ', NULLIF(first_name, ''), NULLIF(last_name, '')),
                                     v_ws_re, '', 'g'), '')
        INTO v_admin_name FROM "ops".operations_user WHERE id = p_admin_id;

        -- Inline fn_pob_write_audit
        BEGIN
            INSERT INTO "ops".audit_logs
                (module, "actionType", "entityType", "entityId", "statusBefore", "statusAfter",
                 "actionReason", "adminEmail", "adminName", success, metadata, "createdAt")
            VALUES ('Partner Onboarding', 'Application Rejected', 'PartnerUser',
                    p_id, v_partner.status::TEXT, 'REJECTED',
                    'Field: Application Status — Reject (' || v_reason || ')',
                    p_admin_email, COALESCE(v_admin_name, p_admin_email),
                    TRUE, jsonb_build_object('module', 'partner-onboarding',
                                             'actionType', 'PARTNER_ONBOARDING_REJECT',
                                             'direct', TRUE, 'targetUserId', p_id), NOW());
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[ApprovalAudit] failed: %', SQLERRM;
        END;
    END IF;

    OPEN p_result FOR
    SELECT FALSE AS pending, 'Application rejected.' AS message, pu.id, pu.status, pu.rejection_reason,
           NULL::TEXT AS request_id,
           v_partner.email AS email, v_partner.mobile AS mobile,
           v_partner.mobile_prefix AS mobile_prefix, v_partner.full_name AS full_name
    FROM "referral".partner_user pu WHERE pu.id = p_id;
    OPEN p_notifications FOR
    SELECT * FROM "ops".adminnotification WHERE FALSE;
END;
$$;

-- File: partner.sp_partner_onb_admin_set_doc_urls.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onb_admin_set_doc_urls(
    p_partner_id                VARCHAR,
    p_pan_image_url             VARCHAR,
    p_aadhaar_front_url         VARCHAR,
    p_aadhaar_back_url          VARCHAR,
    p_bank_verification_doc_url VARCHAR,
    p_signature_url             VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "referral".partner_user SET
        pan_image_url             = p_pan_image_url,
        aadhaar_front_url         = p_aadhaar_front_url,
        aadhaar_back_url          = p_aadhaar_back_url,
        bank_verification_doc_url = p_bank_verification_doc_url,
        signature_url             = p_signature_url,
        updated_at                = NOW()
    WHERE id = p_partner_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'Partner not found.'; END IF;

    OPEN p_cursor FOR
    SELECT id, pan_image_url, aadhaar_front_url, aadhaar_back_url,
           bank_verification_doc_url, signature_url
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_onb_admin_stats.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onb_admin_stats(
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT
        COUNT(*) FILTER (WHERE status = 'UNDER_REVIEW')                                        AS under_review,
        COUNT(*) FILTER (WHERE status = 'APPROVED')                                            AS approved,
        COUNT(*) FILTER (WHERE status = 'REJECTED')                                            AS rejected,
        COUNT(*) FILTER (WHERE status IN ('UNDER_REVIEW', 'APPROVED', 'REJECTED', 'SUBMITTED')) AS total
    FROM "referral".partner_user;
END;
$$;

-- File: partner.sp_partner_onboarding_get_profile.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onboarding_get_profile(
    p_partner_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "referral".partner_user WHERE id = p_partner_id) THEN
        RAISE EXCEPTION 'Partner not found.';
    END IF;

    OPEN p_cursor FOR
    SELECT
        id, email, mobile, mobile_prefix, full_name,
        email_verified, mobile_verified,
        account_type, company_type, date_of_birth, age,
        firm_name, sebi_registration_number, arn_number, entity_type,
        pan_number, pan_image_url, aadhaar_number,
        aadhaar_front_url, aadhaar_back_url,
        address_line1, address_line2, city, state, pin_code,
        bank_name, bank_account_number, bank_account_holder_name,
        ifsc_code, gst_number,
        bank_verification_doc_type, bank_verification_doc_url,
        signature_url, onboarding_step, status, created_at
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_onboarding_resubmit.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onboarding_resubmit(
    p_partner_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    SELECT status::TEXT INTO v_status
    FROM "referral".partner_user WHERE id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Partner not found.';
    END IF;

    IF v_status <> 'REJECTED' THEN
        RAISE EXCEPTION 'Only rejected applications can be resubmitted.';
    END IF;

    UPDATE "referral".partner_user SET
        status                = 'ONBOARDING',
        onboarding_step       = 0,
        rejection_reason      = NULL,
        reviewed_at           = NULL,
        reviewed_by           = NULL,
        submitted_at          = NULL,
        agreement_accepted    = FALSE,
        agreement_accepted_at = NULL,
        updated_at            = NOW()
    WHERE id = p_partner_id;

    OPEN p_cursor FOR
    SELECT id, status AS partner_status, onboarding_step
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_onboarding_save_address_proof.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onboarding_save_address_proof(
    p_partner_id        VARCHAR,
    p_pan_number        VARCHAR,
    p_aadhaar_number    VARCHAR,
    p_address_line1     VARCHAR,
    p_address_line2     VARCHAR,
    p_city              VARCHAR,
    p_state             VARCHAR,
    p_pin_code          VARCHAR,
    p_pan_image_url     VARCHAR DEFAULT NULL,
    p_aadhaar_front_url VARCHAR DEFAULT NULL,
    p_aadhaar_back_url  VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_pan    TEXT;
    v_aad    TEXT;
    v_step   INT;
    v_pan_u  TEXT;
    v_aad_f  TEXT;
    v_aad_b  TEXT;
BEGIN
    IF COALESCE(p_pan_number, '') = '' THEN
        RAISE EXCEPTION 'PAN number is required.';
    END IF;
    v_pan := UPPER(regexp_replace(p_pan_number, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));
    IF v_pan !~ '^[A-Z]{5}[0-9]{4}[A-Z]$' THEN
        RAISE EXCEPTION 'Invalid PAN number format. Expected: ABCDE1234F';
    END IF;

    IF COALESCE(p_aadhaar_number, '') = '' THEN
        RAISE EXCEPTION 'Aadhaar number is required.';
    END IF;
    v_aad := REGEXP_REPLACE(p_aadhaar_number, E'[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]', '', 'g');   -- JS /\s/g
    IF v_aad !~ '^[0-9]{12}$' THEN
        RAISE EXCEPTION 'Aadhaar must be exactly 12 digits.';
    END IF;

    IF COALESCE(regexp_replace(p_address_line1, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), '') = '' THEN RAISE EXCEPTION 'Address Line 1 is required.'; END IF;
    IF COALESCE(regexp_replace(p_city, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), '') = ''          THEN RAISE EXCEPTION 'City is required.'; END IF;
    IF COALESCE(regexp_replace(p_state, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), '') = ''         THEN RAISE EXCEPTION 'State is required.'; END IF;
    IF COALESCE(p_pin_code, '') = ''            THEN RAISE EXCEPTION 'Pin code is required.'; END IF;
    IF p_pin_code !~ '^[0-9]{6}$' THEN
        RAISE EXCEPTION 'Pin code must be exactly 6 digits.';
    END IF;

    SELECT onboarding_step,
           COALESCE(NULLIF(p_pan_image_url, ''),     NULLIF(pan_image_url, '')),      -- JS a || b || null
           COALESCE(NULLIF(p_aadhaar_front_url, ''), NULLIF(aadhaar_front_url, '')),
           COALESCE(NULLIF(p_aadhaar_back_url, ''),  NULLIF(aadhaar_back_url, ''))
    INTO v_step, v_pan_u, v_aad_f, v_aad_b
    FROM "referral".partner_user WHERE id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Partner not found.';
    END IF;

    IF v_pan_u IS NULL THEN RAISE EXCEPTION 'PAN card image is required.'; END IF;
    IF v_aad_f IS NULL THEN RAISE EXCEPTION 'Aadhaar front image is required.'; END IF;
    IF v_aad_b IS NULL THEN RAISE EXCEPTION 'Aadhaar back image is required.'; END IF;

    UPDATE "referral".partner_user SET
        pan_number        = v_pan,
        pan_image_url     = v_pan_u,
        aadhaar_number    = v_aad,
        aadhaar_front_url = v_aad_f,
        aadhaar_back_url  = v_aad_b,
        address_line1     = regexp_replace(p_address_line1, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'),
        address_line2     = NULLIF(regexp_replace(p_address_line2, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), ''),
        city              = regexp_replace(p_city, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'),
        state             = regexp_replace(p_state, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'),
        pin_code          = p_pin_code,
        onboarding_step   = GREATEST(v_step, 2),
        status            = 'ONBOARDING',
        updated_at        = NOW()
    WHERE id = p_partner_id;

    OPEN p_cursor FOR
    SELECT pan_number, pan_image_url, aadhaar_number, aadhaar_front_url, aadhaar_back_url,
           address_line1, address_line2, city, state, pin_code, onboarding_step
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_onboarding_save_bank_details.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onboarding_save_bank_details(
    p_partner_id               VARCHAR,
    p_bank_name                VARCHAR,
    p_bank_account_number      VARCHAR,
    p_bank_account_holder_name VARCHAR,
    p_ifsc_code                VARCHAR,
    p_gst_number               VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_account TEXT := REGEXP_REPLACE(COALESCE(p_bank_account_number, ''), '[^0-9]', '', 'g');
    v_ifsc    TEXT;
    v_gst     TEXT;
    v_step    INT;
BEGIN
    IF COALESCE(regexp_replace(p_bank_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), '') = '' THEN
        RAISE EXCEPTION 'Bank name is required.';
    END IF;

    IF v_account = '' THEN
        RAISE EXCEPTION 'Bank account number is required.';
    END IF;
    IF LENGTH(v_account) < 9 OR LENGTH(v_account) > 18 THEN
        RAISE EXCEPTION 'Account number must be 9–18 digits.';
    END IF;

    IF COALESCE(regexp_replace(p_bank_account_holder_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), '') = '' THEN
        RAISE EXCEPTION 'Name as per bank is required.';
    END IF;
    IF regexp_replace(p_bank_account_holder_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') !~ (E'^[A-Za-z\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF.''"-]+$') THEN
        RAISE EXCEPTION 'Name as per bank contains invalid characters.';
    END IF;

    IF COALESCE(regexp_replace(p_ifsc_code, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), '') = '' THEN
        RAISE EXCEPTION 'IFSC code is required.';
    END IF;
    v_ifsc := UPPER(regexp_replace(p_ifsc_code, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));
    IF v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' THEN
        RAISE EXCEPTION 'Invalid IFSC code. Expected format: ABCD0123456';
    END IF;

    IF COALESCE(regexp_replace(p_gst_number, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), '') <> '' THEN
        v_gst := UPPER(regexp_replace(p_gst_number, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));
        IF v_gst !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' THEN
            RAISE EXCEPTION 'Invalid GST number format. Expected: 27ABCDE1234F1Z5';
        END IF;
    END IF;

    SELECT onboarding_step INTO v_step
    FROM "referral".partner_user WHERE id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Partner not found.';
    END IF;

    UPDATE "referral".partner_user SET
        bank_name                = regexp_replace(p_bank_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'),
        bank_account_number      = v_account,
        bank_account_holder_name = regexp_replace(p_bank_account_holder_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'),
        ifsc_code                = v_ifsc,
        gst_number               = v_gst,
        onboarding_step          = GREATEST(v_step, 3),
        status                   = 'ONBOARDING',
        updated_at               = NOW()
    WHERE id = p_partner_id;

    OPEN p_cursor FOR
    SELECT bank_name, bank_account_number, bank_account_holder_name,
           ifsc_code, gst_number, onboarding_step
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_onboarding_save_bank_verification.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onboarding_save_bank_verification(
    p_partner_id VARCHAR,
    p_doc_type   VARCHAR,
    p_doc_url    VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_type TEXT := UPPER(REPLACE(COALESCE(p_doc_type, ''), '-', '_'));
    v_step INT;
    v_url  TEXT;
BEGIN
    IF v_type NOT IN ('CANCELLED_CHEQUE', 'BANK_STATEMENT', 'PASSBOOK') THEN
        RAISE EXCEPTION 'doc_type must be CANCELLED_CHEQUE, BANK_STATEMENT, or PASSBOOK.';
    END IF;

    SELECT onboarding_step, COALESCE(NULLIF(p_doc_url, ''), NULLIF(bank_verification_doc_url, ''))
    INTO v_step, v_url
    FROM "referral".partner_user WHERE id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Partner not found.';
    END IF;

    IF v_url IS NULL THEN
        RAISE EXCEPTION 'Verification document is required.';
    END IF;

    UPDATE "referral".partner_user SET
        bank_verification_doc_type = v_type,
        bank_verification_doc_url  = v_url,
        onboarding_step            = GREATEST(v_step, 4),
        status                     = 'ONBOARDING',
        updated_at                 = NOW()
    WHERE id = p_partner_id;

    OPEN p_cursor FOR
    SELECT bank_verification_doc_type AS doc_type,
           bank_verification_doc_url  AS doc_url,
           onboarding_step
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_onboarding_save_business.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onboarding_save_business(
    p_partner_id               VARCHAR,
    p_firm_name                VARCHAR,
    p_entity_type              VARCHAR,
    p_sebi_registration_number VARCHAR DEFAULT NULL,
    p_arn_number               VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_account_type TEXT;
    v_step         INT;
BEGIN
    SELECT account_type::TEXT, onboarding_step INTO v_account_type, v_step
    FROM "referral".partner_user WHERE id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Partner not found.';
    END IF;

    IF v_account_type = 'INDIVIDUAL' THEN
        RAISE EXCEPTION 'Business details not required for individual accounts.';
    END IF;
    IF COALESCE(regexp_replace(p_firm_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), '') = '' THEN
        RAISE EXCEPTION 'Firm name is required.';
    END IF;
    IF COALESCE(regexp_replace(p_entity_type, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), '') = '' THEN
        RAISE EXCEPTION 'Entity type is required.';
    END IF;

    UPDATE "referral".partner_user SET
        firm_name                = regexp_replace(p_firm_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'),
        sebi_registration_number = NULLIF(regexp_replace(p_sebi_registration_number, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), ''),
        arn_number               = NULLIF(regexp_replace(p_arn_number, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), ''),
        entity_type              = regexp_replace(p_entity_type, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'),
        onboarding_step          = GREATEST(v_step, 2),
        updated_at               = NOW()
    WHERE id = p_partner_id;

    OPEN p_cursor FOR
    SELECT firm_name, sebi_registration_number, arn_number, entity_type, onboarding_step
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_onboarding_save_personal.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onboarding_save_personal(
    p_partner_id    VARCHAR,
    p_account_type  VARCHAR,
    p_company_type  VARCHAR DEFAULT NULL,
    p_name          VARCHAR DEFAULT NULL,
    p_date_of_birth VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_step    INT;
    v_company TEXT := NULLIF(p_company_type, '');
    v_dob     TIMESTAMP(3);
    v_today   TIMESTAMP(3);
    v_age     INT;
    -- date-parse locals (inlined fn_js_parse_date)
    v_raw_dob  TEXT;
    v_dob_yr   INT;
    v_dob_mo   INT;
    v_dob_dy   INT;
    v_dob_hr   INT;
    v_dob_mi   INT;
    v_dob_sc   INT;
    v_dob_tz   INTERVAL;
    v_dob_sign INT;
    v_dob_tzo  TEXT;
BEGIN
    SELECT onboarding_step INTO v_step
    FROM "referral".partner_user WHERE id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Partner not found.';
    END IF;

    IF COALESCE(p_account_type, '') = '' THEN
        RAISE EXCEPTION 'Account type is required.';
    END IF;
    IF p_account_type NOT IN ('INDIVIDUAL', 'LLP', 'Company', 'PARTNERSHIP', 'SOLE_PROPRIETORSHIP') THEN
        RAISE EXCEPTION 'Invalid account type.';
    END IF;
    IF p_account_type <> 'INDIVIDUAL' AND v_company IS NULL THEN
        RAISE EXCEPTION 'Business category is required for non-individual accounts.';
    END IF;
    IF v_company IS NOT NULL AND v_company NOT IN (
        'MUTUAL_FUNDS', 'LOAN_AGGREGATOR', 'DSA_LOANS', 'INSURANCE',
        'FMCG', 'INDUSTRIAL_GOODS', 'FINANCIAL_SERVICES', 'MARKETING_AGENCY'
    ) THEN
        RAISE EXCEPTION 'Invalid business category.';
    END IF;

    IF COALESCE(p_date_of_birth, '') <> '' THEN
        -- inlined fn_js_parse_date: mirrors JS new Date(p_date_of_birth) semantics
        v_raw_dob := regexp_replace(p_date_of_birth, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
        IF v_raw_dob IS NULL OR v_raw_dob = '' THEN
            v_dob := NULL;
        ELSIF v_raw_dob ~ '^[0-9]{4}$' THEN
            -- YYYY → YYYY-01-01
            v_dob := make_timestamp(v_raw_dob::INT, 1, 1, 0, 0, 0);
        ELSIF v_raw_dob ~ '^[0-9]{4}-[0-9]{1,2}$' THEN
            -- YYYY-MM → YYYY-MM-01
            v_dob_yr := split_part(v_raw_dob, '-', 1)::INT;
            v_dob_mo := split_part(v_raw_dob, '-', 2)::INT;
            IF v_dob_mo BETWEEN 1 AND 12 THEN
                v_dob := make_timestamp(v_dob_yr, v_dob_mo, 1, 0, 0, 0);
            ELSE
                v_dob := NULL;
            END IF;
        ELSIF v_raw_dob ~ '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}$' THEN
            -- M/D/YYYY → month-first (JS new Date() behaviour)
            v_dob_mo := split_part(v_raw_dob, '/', 1)::INT;
            v_dob_dy := split_part(v_raw_dob, '/', 2)::INT;
            v_dob_yr := split_part(v_raw_dob, '/', 3)::INT;
            IF v_dob_mo BETWEEN 1 AND 12 AND v_dob_dy BETWEEN 1 AND 31 THEN
                -- day overflow rolls into next month
                v_dob := make_timestamp(v_dob_yr, v_dob_mo, 1, 0, 0, 0)
                       + make_interval(days := v_dob_dy - 1);
            ELSE
                v_dob := NULL;
            END IF;
        ELSIF v_raw_dob ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2})?([Zz]|[+-][0-9]{2}:[0-9]{2})?)?$' THEN
            -- YYYY-MM-DD[THH:MI[:SS][Z|±HH:MM]]
            v_dob_yr := substring(v_raw_dob, 1, 4)::INT;
            v_dob_mo := substring(v_raw_dob, 6, 2)::INT;
            v_dob_dy := substring(v_raw_dob, 9, 2)::INT;
            v_dob_hr := 0; v_dob_mi := 0; v_dob_sc := 0;
            v_dob_tz := '0 seconds'::INTERVAL;
            IF v_dob_mo BETWEEN 1 AND 12 AND v_dob_dy BETWEEN 1 AND 31 THEN
                IF length(v_raw_dob) > 10 THEN
                    v_dob_hr := substring(v_raw_dob, 12, 2)::INT;
                    v_dob_mi := substring(v_raw_dob, 15, 2)::INT;
                    v_dob_sc := CASE WHEN v_raw_dob ~ 'T[0-9]{2}:[0-9]{2}:[0-9]{2}'
                                     THEN substring(v_raw_dob, 18, 2)::INT ELSE 0 END;
                    v_dob_tzo := substring(v_raw_dob, '[Zz]|[+-][0-9]{2}:[0-9]{2}$');
                    IF v_dob_tzo IS NOT NULL AND upper(v_dob_tzo) <> 'Z' THEN
                        v_dob_sign := CASE WHEN left(v_dob_tzo, 1) = '+' THEN -1 ELSE 1 END;
                        v_dob_tz := make_interval(
                            hours := split_part(substring(v_dob_tzo, 2), ':', 1)::INT * v_dob_sign,
                            mins  := split_part(substring(v_dob_tzo, 2), ':', 2)::INT * v_dob_sign
                        );
                    END IF;
                END IF;
                v_dob := make_timestamp(v_dob_yr, v_dob_mo, 1, v_dob_hr, v_dob_mi, v_dob_sc)
                       + make_interval(days := v_dob_dy - 1)
                       + v_dob_tz;
            ELSE
                v_dob := NULL;
            END IF;
        ELSE
            v_dob := NULL;
        END IF;
        IF v_dob IS NULL THEN
            RAISE EXCEPTION 'Invalid date of birth.';
        END IF;
        -- Node: years diff, minus 1 if birthday not reached yet (UTC server)
        v_today := NOW();
        v_age := EXTRACT(YEAR FROM v_today)::INT - EXTRACT(YEAR FROM v_dob)::INT;
        IF EXTRACT(MONTH FROM v_today) < EXTRACT(MONTH FROM v_dob)
           OR (EXTRACT(MONTH FROM v_today) = EXTRACT(MONTH FROM v_dob)
               AND EXTRACT(DAY FROM v_today) < EXTRACT(DAY FROM v_dob)) THEN
            v_age := v_age - 1;
        END IF;
        IF v_age < 18 THEN
            RAISE EXCEPTION 'You must be at least 18 years old.';
        END IF;
    END IF;

    UPDATE "referral".partner_user SET
        account_type    = p_account_type::partner_account_type,
        company_type    = CASE WHEN p_account_type <> 'INDIVIDUAL'
                               THEN v_company::partner_company_type END,
        full_name       = COALESCE(NULLIF(regexp_replace(p_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), ''), full_name),
        date_of_birth   = COALESCE(v_dob, date_of_birth),
        age             = COALESCE(NULLIF(v_age, 0), age),   -- Node: if (calculatedAge)
        onboarding_step = GREATEST(v_step, 1),
        status          = 'ONBOARDING',
        updated_at      = NOW()
    WHERE id = p_partner_id;

    OPEN p_cursor FOR
    SELECT id, full_name, email, mobile, age, date_of_birth,
           account_type, company_type, onboarding_step
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_onboarding_save_signature.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onboarding_save_signature(
    p_partner_id    VARCHAR,
    p_signature_url VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "referral".partner_user SET
        signature_url   = COALESCE(NULLIF(p_signature_url, ''), signature_url),
        onboarding_step = GREATEST(onboarding_step, 5),
        status          = 'ONBOARDING',
        updated_at      = NOW()
    WHERE id = p_partner_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Partner not found.';
    END IF;

    OPEN p_cursor FOR
    SELECT signature_url, onboarding_step
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_onboarding_submit_agreement.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_onboarding_submit_agreement(
    p_partner_id         VARCHAR,
    p_agreement_accepted JSONB,     -- raw JSON value from req.body (Node: JSON.stringify(agreement_accepted ?? null))
    p_pdf_version        VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    -- Node: `agreement_accepted !== true` → only the JSON boolean true passes
    IF p_agreement_accepted IS DISTINCT FROM 'true'::JSONB THEN
        RAISE EXCEPTION 'You must accept the Partner Agreement to proceed.';
    END IF;

    SELECT status::TEXT INTO v_status
    FROM "referral".partner_user WHERE id = p_partner_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Partner not found.';
    END IF;

    IF v_status IN ('UNDER_REVIEW', 'APPROVED') THEN
        RAISE EXCEPTION 'Application already submitted.';
    END IF;

    UPDATE "referral".partner_user SET
        agreement_accepted    = TRUE,
        agreement_accepted_at = NOW(),
        agreement_pdf_version = COALESCE(NULLIF(p_pdf_version, ''), 'v1'),
        onboarding_step       = GREATEST(onboarding_step, 6),
        status                = 'UNDER_REVIEW',
        submitted_at          = NOW(),
        updated_at            = NOW()
    WHERE id = p_partner_id;

    OPEN p_cursor FOR
    SELECT onboarding_step, status AS partner_status,
           agreement_accepted, agreement_pdf_version, submitted_at
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_report_cep_execution_status.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_report_cep_execution_status(
    p_partner_id VARCHAR,
    p_page       INT       DEFAULT 1,
    p_limit      INT       DEFAULT 20,
    p_status     VARCHAR   DEFAULT NULL,
    p_from       VARCHAR   DEFAULT NULL,
    p_to         VARCHAR   DEFAULT NULL,
    p_export     BOOLEAN   DEFAULT FALSE,
    INOUT p_rows       refcursor DEFAULT 'rows_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page   INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit  INT := COALESCE(NULLIF(p_limit, 0), 20);
    v_from   TIMESTAMP;
    v_to     TIMESTAMP;
    v_status TEXT := UPPER(NULLIF(p_status, ''));
    v_users  TEXT[];
    v_total  INT;
    -- inlined fn_js_parse_date locals
    _pd_s      TEXT;
    _pd_m      TEXT[];
    _pd_y      INT; _pd_mo INT; _pd_d INT;
    _pd_hh     INT; _pd_mi  INT; _pd_ss NUMERIC;
    _pd_tz     TEXT;
    _pd_base   TIMESTAMP;
    _pd_result TIMESTAMP(3);
BEGIN
    IF v_status IS NOT NULL AND v_status NOT IN (
        'PENDING', 'COMPLETED', 'CANCELLED', 'EXPIRED', 'IMPEDED', 'REVAMPED',
        'PARTIALLY_FILLED', 'FAILED', 'REFUNDED', 'REVERSED',
        'REVERSAL_FAILED', 'REVERSAL_PENDING', 'REVERSAL_COMPLETED', 'REVERSAL_CANCEL'
    ) THEN
        RAISE EXCEPTION 'Invalid status. Valid values: PENDING, COMPLETED, CANCELLED, EXPIRED, IMPEDED, REVAMPED, PARTIALLY_FILLED, FAILED, REFUNDED, REVERSED, REVERSAL_FAILED, REVERSAL_PENDING, REVERSAL_COMPLETED, REVERSAL_CANCEL';
    END IF;

    SELECT ARRAY_AGG(linked_user_id) INTO v_users
    FROM "referral".partner_client
    WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL;

    IF v_users IS NOT NULL THEN
        IF p_from IS NOT NULL AND p_from <> '' THEN
            -- inline fn_js_parse_date(p_from) -> v_from
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_from, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_from := _pd_result;
            IF v_from IS NULL THEN RAISE EXCEPTION 'Failed to fetch CEP execution status report'; END IF;
        END IF;
        IF p_to IS NOT NULL AND p_to <> '' THEN
            -- inline fn_js_parse_date(p_to) -> v_to
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_to, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_to := _pd_result;
            IF v_to IS NULL THEN RAISE EXCEPTION 'Failed to fetch CEP execution status report'; END IF;
            v_to := date_trunc('day', v_to) + INTERVAL '1 day' - INTERVAL '1 millisecond';
        END IF;
    END IF;

    SELECT COUNT(*) INTO v_total
    FROM "trade"."transaction"
    WHERE user_ref_id = ANY(v_users) AND UPPER(asset) = 'CEP' AND parent_transaction_id IS NULL
      AND (v_status IS NULL OR status::TEXT = v_status)
      AND (v_from   IS NULL OR created_at >= v_from)
      AND (v_to     IS NULL OR created_at <= v_to);

    OPEN p_rows FOR
    SELECT
        t.id                                                             AS transaction_id,
        NULLIF(u.email, '')                                              AS login_id,   -- u.email || null
        COALESCE(cm.name, '-')                                           AS client_name,
        CASE WHEN COALESCE(NULLIF(t.provider, ''), 'ZERODHA') = 'ZERODHA'
             THEN z.zerodha_user_id
             ELSE NULLIF(t.broker_client_id, '') END                     AS client_id,
        NULLIF(u.phone_number, '')                                       AS mobile,
        COALESCE(NULLIF(t.description, ''), '-')                         AS basket_name,
        t.cep_ref_id,
        t.transaction_type::TEXT                                         AS action,
        t.created_at                                                     AS order_date,
        t.status::TEXT                                                   AS status,
        COALESCE(c.order_count, 0)                                       AS order_count,
        CASE WHEN t.transaction_type = 'BUY'  THEN COALESCE(c.order_count, 0) ELSE 0 END AS buy_count,
        CASE WHEN t.transaction_type = 'SELL' THEN COALESCE(c.order_count, 0) ELSE 0 END AS sell_count,
        COALESCE(c.executed_count, 0)                                    AS executed_order_count,
        COALESCE(NULLIF(t.provider, ''), 'ZERODHA')                      AS broker_name,
        (floor((COALESCE(c.order_value, 0))::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC AS total_order_value,
        (floor((COALESCE(c.filled_value, 0))::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC AS filled_value,
        -- Math.round((filled / ordered) * 10000) / 100
        CASE WHEN COALESCE(c.ordered_qty, 0) > 0
             THEN (floor(c.filled_qty::DOUBLE PRECISION / c.ordered_qty::DOUBLE PRECISION * 10000 + 0.5) / 100)::NUMERIC
             ELSE 0 END                                                  AS fill_percentage
    FROM "trade"."transaction" t
    LEFT JOIN LATERAL (
        SELECT COUNT(*)                                                         AS order_count,
               COUNT(*) FILTER (WHERE COALESCE(s.filled_quantity, 0) > 0)       AS executed_count,
               SUM(COALESCE(s.quantity, 0))                                     AS ordered_qty,
               SUM(COALESCE(s.filled_quantity, 0))                              AS filled_qty,
               SUM(COALESCE(s.quantity, 0) * COALESCE(s.average_price, 0))      AS order_value,
               SUM(COALESCE(s.filled_quantity, 0) * COALESCE(s.average_price, 0)) AS filled_value
        FROM "trade"."transaction" s WHERE s.parent_transaction_id = t.id
    ) c ON TRUE
    LEFT JOIN LATERAL (
        SELECT name FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id = t.user_ref_id
        ORDER BY created_at DESC LIMIT 1
    ) cm ON TRUE
    LEFT JOIN "user"."user" u ON u.id = t.user_ref_id
    LEFT JOIN LATERAL (
        SELECT zerodha_user_id FROM "trade".zerodha
        WHERE user_ref_id = t.user_ref_id ORDER BY updated_at DESC LIMIT 1
    ) z ON TRUE
    WHERE t.user_ref_id = ANY(v_users) AND UPPER(t.asset) = 'CEP' AND t.parent_transaction_id IS NULL
      AND (v_status IS NULL OR t.status::TEXT = v_status)
      AND (v_from   IS NULL OR t.created_at >= v_from)
      AND (v_to     IS NULL OR t.created_at <= v_to)
    ORDER BY t.created_at DESC, t.id
    LIMIT CASE WHEN p_export THEN NULL ELSE v_limit END
    OFFSET CASE WHEN p_export THEN 0 ELSE (v_page - 1) * v_limit END;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_report_cep_pnl.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_report_cep_pnl(
    p_partner_id VARCHAR,
    p_page       INT       DEFAULT 1,
    p_limit      INT       DEFAULT 20,
    p_from       VARCHAR   DEFAULT NULL,
    p_to         VARCHAR   DEFAULT NULL,
    p_export     BOOLEAN   DEFAULT FALSE,
    INOUT p_rows       refcursor DEFAULT 'rows_cursor',
    INOUT p_positions  refcursor DEFAULT 'positions_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page  INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit INT := COALESCE(NULLIF(p_limit, 0), 20);
    v_from  TIMESTAMP;
    v_to    TIMESTAMP;
    v_now   TIMESTAMP := NOW();
    v_users TEXT[];
    v_total INT;
    -- inlined fn_js_parse_date locals
    _pd_s      TEXT;
    _pd_m      TEXT[];
    _pd_y      INT; _pd_mo INT; _pd_d INT;
    _pd_hh     INT; _pd_mi  INT; _pd_ss NUMERIC;
    _pd_tz     TEXT;
    _pd_base   TIMESTAMP;
    _pd_result TIMESTAMP(3);
BEGIN
    SELECT ARRAY_AGG(linked_user_id) INTO v_users
    FROM "referral".partner_client
    WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL;

    IF v_users IS NOT NULL THEN
        IF p_from IS NOT NULL AND p_from <> '' THEN
            -- inline fn_js_parse_date(p_from) -> v_from
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_from, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_from := _pd_result;
            IF v_from IS NULL THEN RAISE EXCEPTION 'Failed to fetch CEP PnL report'; END IF;
        END IF;
        IF p_to IS NOT NULL AND p_to <> '' THEN
            -- inline fn_js_parse_date(p_to) -> v_to
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_to, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_to := _pd_result;
            IF v_to IS NULL THEN RAISE EXCEPTION 'Failed to fetch CEP PnL report'; END IF;
            v_to := date_trunc('day', v_to) + INTERVAL '1 day' - INTERVAL '1 millisecond';
        END IF;
    END IF;

    -- Parent baskets in scope, with their amount / qty
    DROP TABLE IF EXISTS tmp_cep_parents;
    CREATE TEMP TABLE tmp_cep_parents ON COMMIT DROP AS
    SELECT
        t.id, t.user_ref_id, COALESCE(t.cep_ref_id, '') AS cep_key, t.cep_ref_id,
        t.transaction_type::TEXT AS ttype, t.description, t.provider, t.created_at,
        COALESCE((SELECT SUM(COALESCE(s.average_price, 0) * COALESCE(s.filled_quantity, 0))
                  FROM "trade"."transaction" s WHERE s.parent_transaction_id = t.id), 0) AS amount,
        COALESCE((SELECT SUM(COALESCE(s.filled_quantity, 0))
                  FROM "trade"."transaction" s WHERE s.parent_transaction_id = t.id), 0) AS qty
    FROM "trade"."transaction" t
    WHERE t.user_ref_id = ANY(v_users)
      AND UPPER(t.asset) = 'CEP' AND t.parent_transaction_id IS NULL AND t.status = 'COMPLETED'
      AND (v_from IS NULL OR t.created_at >= v_from)
      AND (v_to   IS NULL OR t.created_at <= v_to);

    -- Per-stock positions: JS skips `!sc || isNaN(Number(sc))` and qty <= 0
    DROP TABLE IF EXISTS tmp_cep_positions;
    CREATE TEMP TABLE tmp_cep_positions ON COMMIT DROP AS
    SELECT
        p.user_ref_id, p.cep_key, s.scripcode AS scripcode,
        SUM(CASE WHEN p.ttype = 'BUY'  THEN COALESCE(s.filled_quantity, 0) ELSE 0 END) AS buy_qty,
        SUM(CASE WHEN p.ttype = 'SELL' THEN COALESCE(s.filled_quantity, 0) ELSE 0 END) AS sell_qty,
        SUM(CASE WHEN p.ttype = 'BUY'  THEN COALESCE(s.filled_quantity, 0) * COALESCE(s.average_price, 0) ELSE 0 END) AS buy_cost
    FROM tmp_cep_parents p
    JOIN "trade"."transaction" s ON s.parent_transaction_id = p.id
    WHERE COALESCE(s.scripcode, '') <> ''
      AND regexp_replace(s.scripcode, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') ~ '^([+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?|[+-]?Infinity|0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+)?$'
      AND COALESCE(s.filled_quantity, 0) > 0
      AND p.ttype IN ('BUY', 'SELL')
    GROUP BY p.user_ref_id, p.cep_key, s.scripcode;

    DROP TABLE IF EXISTS tmp_cep_pnl;
    CREATE TEMP TABLE tmp_cep_pnl ON COMMIT DROP AS
    WITH h AS (
        SELECT
            user_ref_id, cep_key,
            MAX(cep_ref_id)                                                          AS cep_ref_id,
            (ARRAY_AGG(description ORDER BY created_at, id))[1]                      AS description,
            (ARRAY_AGG(provider ORDER BY created_at, id) FILTER (WHERE COALESCE(provider, '') <> ''))[1] AS provider,
            SUM(CASE WHEN ttype = 'BUY'  THEN amount ELSE 0 END)                     AS total_invested,
            SUM(CASE WHEN ttype = 'SELL' THEN amount ELSE 0 END)                     AS total_exit_value,
            SUM(CASE WHEN ttype = 'BUY'  THEN qty    ELSE 0 END)                     AS purchased_qty,
            SUM(CASE WHEN ttype = 'SELL' THEN qty    ELSE 0 END)                     AS sold_qty,
            COUNT(*)                                                                 AS transaction_count,
            MIN(created_at) FILTER (WHERE ttype = 'BUY')                             AS first_purchase_date,
            MAX(created_at)                                                          AS last_activity_date,
            (ARRAY_AGG(id ORDER BY created_at DESC, id))[1]                          AS transaction_id,
            MIN(created_at)                                                          AS first_seen
        FROM tmp_cep_parents
        GROUP BY user_ref_id, cep_key
    ),
    op AS (
        SELECT user_ref_id, cep_key,
               BOOL_OR(buy_qty - sell_qty > 0) AS has_open,
               SUM(CASE WHEN buy_qty - sell_qty > 0
                        THEN (buy_qty - sell_qty) * CASE WHEN buy_qty > 0 THEN buy_cost / buy_qty ELSE 0 END
                        ELSE 0 END)            AS open_cost
        FROM tmp_cep_positions GROUP BY user_ref_id, cep_key
    ),
    r AS (
        SELECT h.*,
               COALESCE(op.has_open, FALSE) AS has_open,
               COALESCE(op.open_cost, 0)    AS open_cost,
               CASE WHEN h.sold_qty > 0
                    THEN (floor((h.total_exit_value
                               - (CASE WHEN h.purchased_qty > 0 THEN h.total_invested / h.purchased_qty ELSE 0 END) * h.sold_qty)::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC
               END AS realized_pnl,
               EXTRACT(EPOCH FROM (v_now - h.first_purchase_date)) / (365.25 * 86400) AS years
        FROM h LEFT JOIN op ON op.user_ref_id = h.user_ref_id AND op.cep_key = h.cep_key
    )
    SELECT
        r.transaction_id,
        r.user_ref_id,
        COALESCE(cm.name, '-')                                      AS client_name,
        NULLIF(r.cep_ref_id, '')                                    AS cep_ref_id,
        COALESCE(NULLIF(r.description, ''), '-')                    AS basket_name,
        (floor((r.total_invested)::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC AS total_invested,
        r.total_exit_value,
        r.purchased_qty,
        r.sold_qty,
        r.realized_pnl,
        r.has_open,
        r.open_cost,
        NULL::NUMERIC                                               AS current_value,
        NULL::NUMERIC                                               AS total_portfolio_value,
        NULL::NUMERIC                                               AS unrealized_pnl,
        CASE WHEN NOT r.has_open THEN r.realized_pnl END            AS net_pnl,
        CASE WHEN NOT r.has_open AND r.realized_pnl IS NOT NULL AND r.total_invested > 0
             THEN (floor((r.realized_pnl / r.total_invested * 100)::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC END AS overall_returns_pct,
        CASE WHEN NOT r.has_open AND r.total_invested > 0 AND r.first_purchase_date IS NOT NULL
                  AND r.years >= 0.01 AND r.total_exit_value > 0
             THEN (floor((((POWER((r.total_exit_value / r.total_invested)::DOUBLE PRECISION, 1 / r.years) - 1) * 100)::NUMERIC)::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC
        END                                                         AS cagr_pct,
        r.transaction_count,
        r.first_purchase_date,
        r.last_activity_date,
        u.phone_number                                              AS mobile_phone,
        COALESCE(r.provider, 'ZERODHA')                             AS broker_name,
        rk.risk_level                                               AS risk_profile,
        fs.amount                                                   AS fees_amount,
        fs.start_date                                               AS fees_start_date,
        fs.end_date                                                 AS fees_end_date,
        ROW_NUMBER() OVER (ORDER BY r.first_seen, r.user_ref_id, r.cep_key) AS pos
    FROM r
    LEFT JOIN LATERAL (
        SELECT name FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id = r.user_ref_id
        ORDER BY created_at DESC LIMIT 1
    ) cm ON TRUE
    LEFT JOIN "user"."user" u ON u.id = r.user_ref_id
    LEFT JOIN LATERAL (
        SELECT g.risk_level FROM "catalog".userriskprofile urp
        JOIN "catalog".riskprofilescoregrid g ON g.id = urp.risk_profile_id
        WHERE urp.user_id = r.user_ref_id
        ORDER BY urp.updated_at DESC LIMIT 1
    ) rk ON TRUE
    LEFT JOIN LATERAL (
        SELECT us.amount, us.start_date, us.end_date FROM "payments".usersubscription us
        WHERE us.user_ref_id = r.user_ref_id AND us.transaction_status = 'SUCCESS'
        ORDER BY us.start_date DESC LIMIT 1
    ) fs ON TRUE;

    -- total_portfolio_value: only final when none of the client's baskets is open
    UPDATE tmp_cep_pnl t SET total_portfolio_value = 0
    WHERE NOT EXISTS (SELECT 1 FROM tmp_cep_pnl x WHERE x.user_ref_id = t.user_ref_id AND x.has_open);

    SELECT COUNT(*) INTO v_total FROM tmp_cep_pnl;

    OPEN p_rows FOR
    SELECT * FROM tmp_cep_pnl
    WHERE p_export OR (pos > (v_page - 1) * v_limit AND pos <= v_page * v_limit)
    ORDER BY pos;

    -- ALL positions (not only the page): Node needs every basket of a
    -- client to compute total_portfolio_value = Σ current_value per client.
    OPEN p_positions FOR
    SELECT p.user_ref_id, NULLIF(p.cep_key, '') AS cep_ref_id, p.scripcode,
           p.buy_qty, p.sell_qty, p.buy_cost, p.buy_qty - p.sell_qty AS net_qty,
           CASE WHEN p.buy_qty > 0 THEN p.buy_cost / p.buy_qty ELSE 0 END AS avg_buy_price
    FROM tmp_cep_positions p
    ORDER BY p.user_ref_id, p.cep_key, p.scripcode;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_report_ceps_rebalance.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_report_ceps_rebalance(
    p_partner_id VARCHAR,
    p_page       INT       DEFAULT 1,
    p_limit      INT       DEFAULT 20,
    p_from       VARCHAR   DEFAULT NULL,
    p_to         VARCHAR   DEFAULT NULL,
    p_export     BOOLEAN   DEFAULT FALSE,
    INOUT p_rows       refcursor DEFAULT 'rows_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page  INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit INT := COALESCE(NULLIF(p_limit, 0), 20);
    v_from  TIMESTAMP;
    v_to    TIMESTAMP;
    v_users TEXT[];
    v_total INT;
    -- inlined fn_js_parse_date locals
    _pd_s      TEXT;
    _pd_m      TEXT[];
    _pd_y      INT; _pd_mo INT; _pd_d INT;
    _pd_hh     INT; _pd_mi  INT; _pd_ss NUMERIC;
    _pd_tz     TEXT;
    _pd_base   TIMESTAMP;
    _pd_result TIMESTAMP(3);
BEGIN
    SELECT ARRAY_AGG(linked_user_id) INTO v_users
    FROM "referral".partner_client
    WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL;

    IF v_users IS NOT NULL THEN
        IF p_from IS NOT NULL AND p_from <> '' THEN
            -- inline fn_js_parse_date(p_from) -> v_from
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_from, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_from := _pd_result;
            IF v_from IS NULL THEN RAISE EXCEPTION 'Failed to fetch CEPS rebalance report'; END IF;
        END IF;
        IF p_to IS NOT NULL AND p_to <> '' THEN
            -- inline fn_js_parse_date(p_to) -> v_to
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_to, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_to := _pd_result;
            IF v_to IS NULL THEN RAISE EXCEPTION 'Failed to fetch CEPS rebalance report'; END IF;
            v_to := date_trunc('day', v_to) + INTERVAL '1 day' - INTERVAL '1 millisecond';
        END IF;
    END IF;

    SELECT COUNT(*) INTO v_total
    FROM "trade"."transaction"
    WHERE user_ref_id = ANY(v_users) AND UPPER(asset) = 'CEP' AND parent_transaction_id IS NULL
      AND (v_from IS NULL OR created_at >= v_from)
      AND (v_to   IS NULL OR created_at <= v_to);

    OPEN p_rows FOR
    SELECT
        t.id,
        COALESCE(cm.name, '-')                                           AS client_name,
        COALESCE(NULLIF(t.description, ''), '-')                         AS basket_name,
        t.cep_ref_id,
        t.transaction_type::TEXT                                         AS action,
        COALESCE((SELECT SUM(COALESCE(s.average_price, 0) * COALESCE(s.filled_quantity, 0))
                  FROM "trade"."transaction" s WHERE s.parent_transaction_id = t.id), 0) AS amount,
        t.created_at                                                     AS date,
        COALESCE(LOWER(t.status::TEXT), '-')                             AS status
    FROM "trade"."transaction" t
    LEFT JOIN LATERAL (
        SELECT name FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id = t.user_ref_id
        ORDER BY created_at DESC LIMIT 1
    ) cm ON TRUE
    WHERE t.user_ref_id = ANY(v_users) AND UPPER(t.asset) = 'CEP' AND t.parent_transaction_id IS NULL
      AND (v_from IS NULL OR t.created_at >= v_from)
      AND (v_to   IS NULL OR t.created_at <= v_to)
    ORDER BY t.created_at DESC, t.id
    LIMIT CASE WHEN p_export THEN NULL ELSE v_limit END
    OFFSET CASE WHEN p_export THEN 0 ELSE (v_page - 1) * v_limit END;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_report_client_aum.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_report_client_aum(
    p_partner_id VARCHAR,
    p_page       INT     DEFAULT 1,
    p_limit      INT     DEFAULT 20,
    p_sort_by    VARCHAR DEFAULT NULL,
    p_sort_dir   VARCHAR DEFAULT NULL,
    p_export     BOOLEAN DEFAULT FALSE,
    INOUT p_rows       refcursor DEFAULT 'rows_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page  INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit INT := COALESCE(NULLIF(p_limit, 0), 20);
    v_total INT;
BEGIN
    SELECT COUNT(*) INTO v_total FROM "referral".partner_client WHERE partner_id = p_partner_id;

    OPEN p_rows FOR
    WITH c AS (
        SELECT id, name, linked_user_id, created_at,
               ROW_NUMBER() OVER (ORDER BY created_at DESC, id) AS base_rn
        FROM "referral".partner_client
        WHERE partner_id = p_partner_id
    ),
    mf AS (
        SELECT user_ref_id,
               SUM(COALESCE(substring(regexp_replace(amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::NUMERIC, 0)) AS amt
        FROM "trade".nse_mf_order
        WHERE user_ref_id IN (SELECT linked_user_id FROM c WHERE linked_user_id IS NOT NULL)
          -- MySQL string comparisons are case-insensitive
          AND UPPER(order_status) IN ('ALLOTTED', 'COMPLETED', 'ALLOTMENT_DONE', 'SUCCESS')
          AND UPPER(trade_type)   IN ('LUMPSUM', 'SIP')
        GROUP BY user_ref_id
    ),
    cep AS (
        SELECT t.user_ref_id,
               SUM(COALESCE(s.average_price, 0) * COALESCE(s.filled_quantity, 0)) AS amt
        FROM "trade"."transaction" t
        JOIN "trade"."transaction" s ON s.parent_transaction_id = t.id
        WHERE t.user_ref_id IN (SELECT linked_user_id FROM c WHERE linked_user_id IS NOT NULL)
          AND UPPER(t.asset) = 'CEP' AND t.transaction_type = 'BUY' AND t.status = 'COMPLETED'
          AND t.parent_transaction_id IS NULL
        GROUP BY t.user_ref_id
    ),
    r AS (
        SELECT c.id AS client_id, c.name AS client_name,
               COALESCE(mf.amt, 0)                       AS mf_aum,
               COALESCE(cep.amt, 0)                      AS ceps_aum,
               COALESCE(mf.amt, 0) + COALESCE(cep.amt, 0) AS total_aum,
               c.base_rn
        FROM c
        LEFT JOIN mf  ON mf.user_ref_id  = c.linked_user_id
        LEFT JOIN cep ON cep.user_ref_id = c.linked_user_id
    )
    SELECT client_id, client_name, mf_aum, ceps_aum, total_aum
    FROM r
    ORDER BY
        CASE WHEN p_sort_by = 'total_aum'   AND p_sort_dir =  'asc' THEN total_aum END ASC,
        CASE WHEN p_sort_by = 'total_aum'   AND COALESCE(p_sort_dir, '') <> 'asc' THEN total_aum END DESC,
        CASE WHEN p_sort_by = 'mf_aum'      AND p_sort_dir =  'asc' THEN mf_aum END ASC,
        CASE WHEN p_sort_by = 'mf_aum'      AND COALESCE(p_sort_dir, '') <> 'asc' THEN mf_aum END DESC,
        CASE WHEN p_sort_by = 'ceps_aum'    AND p_sort_dir =  'asc' THEN ceps_aum END ASC,
        CASE WHEN p_sort_by = 'ceps_aum'    AND COALESCE(p_sort_dir, '') <> 'asc' THEN ceps_aum END DESC,
        CASE WHEN p_sort_by = 'client_name' AND p_sort_dir =  'asc' THEN client_name END ASC,
        CASE WHEN p_sort_by = 'client_name' AND COALESCE(p_sort_dir, '') <> 'asc' THEN client_name END DESC,
        base_rn
    LIMIT CASE WHEN p_export THEN NULL ELSE v_limit END
    OFFSET CASE WHEN p_export THEN 0 ELSE (v_page - 1) * v_limit END;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_report_client_holding.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_report_client_holding(
    p_partner_id VARCHAR,
    p_asset_type VARCHAR DEFAULT NULL,
    INOUT p_mf       refcursor DEFAULT 'mf_cursor',
    INOUT p_zerodha  refcursor DEFAULT 'zerodha_cursor',
    INOUT p_txns     refcursor DEFAULT 'txns_cursor',
    INOUT p_cep_buys refcursor DEFAULT 'cep_buys_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_asset   TEXT := UPPER(NULLIF(p_asset_type, ''));
    v_need_mf BOOLEAN;
    v_need_he BOOLEAN;
    v_users   TEXT[];
BEGIN
    IF v_asset IS NOT NULL AND v_asset NOT IN ('MF', 'CEP', 'EQUITY', 'ETF') THEN
        RAISE EXCEPTION 'Invalid asset_type. Allowed values: MF, CEP, EQUITY, ETF';
    END IF;
    v_need_mf := (v_asset IS NULL OR v_asset = 'MF');
    v_need_he := (v_asset IS NULL OR v_asset IN ('EQUITY', 'ETF', 'CEP'));

    SELECT ARRAY_AGG(linked_user_id) INTO v_users
    FROM "referral".partner_client
    WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL;

    OPEN p_mf FOR
    WITH g AS (
        SELECT
            t.user_ref_id,
            COALESCE(NULLIF(t.trading_symbol, ''), t.scripcode)                                       AS symbol,
            SUM(CASE WHEN t.transaction_type = 'BUY'  THEN COALESCE(t.quantity, 0) ELSE 0 END)        AS buy_qty,
            SUM(CASE WHEN t.transaction_type = 'BUY'  THEN COALESCE(t.quantity, 0) * COALESCE(t.average_price, 0) ELSE 0 END) AS buy_amt,
            SUM(CASE WHEN t.transaction_type = 'SELL' THEN COALESCE(t.quantity, 0) ELSE 0 END)        AS sell_qty,
            MIN(t.created_at)                                                                         AS first_at
        FROM "trade"."transaction" t
        WHERE v_need_mf
          AND t.user_ref_id = ANY(v_users)
          AND t.status::TEXT IN ('COMPLETED', 'REVAMPED')
          AND t.transaction_type::TEXT IN ('BUY', 'SELL')
          AND UPPER(t.asset) = 'MF'          -- MySQL: case-insensitive
        GROUP BY t.user_ref_id, COALESCE(NULLIF(t.trading_symbol, ''), t.scripcode)
    ),
    p AS (
        SELECT g.*, buy_qty - sell_qty AS net_qty,
               CASE WHEN buy_qty > 0 THEN buy_amt / buy_qty ELSE 0 END AS avg_price
        FROM g
    )
    SELECT
        COALESCE(cm.name, '-')                 AS client_name,
        'MF'::TEXT                             AS asset_type,
        p.symbol                               AS scheme_or_basket,
        (floor(p.net_qty::DOUBLE PRECISION * 10000 + 0.5) / 10000)::NUMERIC AS units,   -- Math.round(x*10000)/10000
        (floor((p.net_qty * p.avg_price)::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC AS invested_amount,
        NULL::NUMERIC                          AS current_nav,
        (floor((p.net_qty * p.avg_price)::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC AS current_value,
        NULL::NUMERIC                          AS last_price,
        'nuqi_transactions'::TEXT              AS data_source,
        p.user_ref_id,
        p.net_qty,
        p.avg_price
    FROM p
    LEFT JOIN LATERAL (
        SELECT name FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id = p.user_ref_id
        ORDER BY created_at DESC LIMIT 1
    ) cm ON TRUE
    WHERE p.net_qty > 0
    ORDER BY p.first_at, p.user_ref_id, p.symbol;

    OPEN p_zerodha FOR
    SELECT z.user_ref_id, z.zerodha_user_id, z.last_fetched_portfolio, z.last_fetched_at,
           (z.session_status = 'true') AS is_connected
    FROM "trade".zerodha z
    WHERE v_need_he AND z.user_ref_id = ANY(v_users) AND z.last_fetched_portfolio IS NOT NULL
    ORDER BY z.user_ref_id;

    OPEN p_txns FOR
    SELECT t.user_ref_id, t.trading_symbol, t.scripcode, t.asset, t.transaction_type::TEXT AS transaction_type,
           t.quantity, t.average_price, t.cep_ref_id, t.parent_transaction_id
    FROM "trade"."transaction" t
    WHERE v_need_he AND t.user_ref_id = ANY(v_users)
      AND t.status::TEXT IN ('COMPLETED', 'REVAMPED')
      AND t.transaction_type::TEXT IN ('BUY', 'SELL')
    ORDER BY t.user_ref_id, t.created_at, t.id;

    OPEN p_cep_buys FOR
    SELECT t.user_ref_id, t.cep_ref_id, t.quantity
    FROM "trade"."transaction" t
    WHERE v_need_he AND t.user_ref_id = ANY(v_users)
      AND t.cep_ref_id IS NOT NULL AND t.parent_transaction_id IS NULL
      AND t.status::TEXT IN ('COMPLETED', 'REVAMPED')
    ORDER BY t.user_ref_id, t.created_at, t.id;
END;
$$;

-- File: partner.sp_partner_report_commission_summary.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_report_commission_summary(
    p_partner_id VARCHAR,
    p_period     VARCHAR   DEFAULT NULL,
    p_from       VARCHAR   DEFAULT NULL,
    p_to         VARCHAR   DEFAULT NULL,
    INOUT p_summary    refcursor DEFAULT 'summary_cursor',
    INOUT p_by_product refcursor DEFAULT 'by_product_cursor',
    INOUT p_monthly    refcursor DEFAULT 'monthly_cursor',
    INOUT p_ledger     refcursor DEFAULT 'ledger_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_now          TIMESTAMP := NOW();
    v_this_month   TIMESTAMP;
    v_last_month   TIMESTAMP;
    v_ytd          TIMESTAMP;
    v_six_months   TIMESTAMP;
    v_from         TIMESTAMP;
    v_to           TIMESTAMP;
    v_period_from  TIMESTAMP;
    v_ledger_from  TIMESTAMP;
    -- inlined fn_js_parse_date locals
    _pd_s      TEXT;
    _pd_m      TEXT[];
    _pd_y      INT; _pd_mo INT; _pd_d INT;
    _pd_hh     INT; _pd_mi  INT; _pd_ss NUMERIC;
    _pd_tz     TEXT;
    _pd_base   TIMESTAMP;
    _pd_result TIMESTAMP(3);
BEGIN
    v_this_month := date_trunc('month', v_now);
    v_last_month := v_this_month - INTERVAL '1 month';
    v_ytd        := date_trunc('year', v_now);
    v_six_months := v_this_month - INTERVAL '6 months';
    -- No partner → Node returns zeros without querying (no date errors)
    IF p_partner_id IS NOT NULL THEN
        IF p_from IS NOT NULL AND p_from <> '' THEN
            -- inline fn_js_parse_date(p_from) -> v_from
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_from, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_from := _pd_result;
            IF v_from IS NULL THEN RAISE EXCEPTION 'Failed to fetch commission summary'; END IF;
        END IF;
        IF p_to IS NOT NULL AND p_to <> '' THEN
            -- inline fn_js_parse_date(p_to) -> v_to
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_to, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_to := _pd_result;
            IF v_to IS NULL THEN RAISE EXCEPTION 'Failed to fetch commission summary'; END IF;
            v_to := date_trunc('day', v_to) + INTERVAL '1 day' - INTERVAL '1 millisecond';
        END IF;
    END IF;

    -- period_commission card
    v_period_from := CASE WHEN p_period = 'ytd' THEN v_ytd ELSE v_this_month END;
    v_period_from := COALESCE(v_from, v_period_from);

    -- download ledger rows ('' period = no period, like JS truthiness)
    v_ledger_from := CASE WHEN p_period = 'ytd' THEN v_ytd
                          WHEN COALESCE(p_period, '') <> '' THEN v_this_month END;
    v_ledger_from := COALESCE(v_from, v_ledger_from);

    OPEN p_summary FOR
    SELECT
        COALESCE(SUM(commission_amount), 0)                                                           AS total_commission,
        COALESCE(SUM(commission_amount) FILTER (WHERE created_at >= v_period_from
                                                  AND (v_to IS NULL OR created_at <= v_to)), 0)       AS period_commission,
        COALESCE(SUM(commission_amount) FILTER (WHERE created_at >= v_this_month), 0)                 AS this_month,
        COALESCE(SUM(commission_amount) FILTER (WHERE created_at >= v_last_month
                                                  AND created_at <  v_this_month), 0)                 AS last_month,
        COALESCE(SUM(commission_amount) FILTER (WHERE created_at >= v_ytd), 0)                        AS ytd
    FROM "referral".partner_commission_ledger
    WHERE p_partner_id IS NOT NULL AND partner_id = p_partner_id;

    OPEN p_by_product FOR
    SELECT transaction_type AS product, COALESCE(SUM(commission_amount), 0) AS commission
    FROM "referral".partner_commission_ledger
    WHERE p_partner_id IS NOT NULL AND partner_id = p_partner_id
    GROUP BY transaction_type
    ORDER BY transaction_type;

    OPEN p_monthly FOR
    SELECT TO_CHAR(created_at, 'YYYY-MM') AS month, SUM(commission_amount) AS commission
    FROM "referral".partner_commission_ledger
    WHERE p_partner_id IS NOT NULL AND partner_id = p_partner_id
      AND created_at >= v_six_months
    GROUP BY 1
    ORDER BY 1;

    OPEN p_ledger FOR
    SELECT
        l.created_at              AS date,
        COALESCE(pc.name, '-')    AS client_name,
        l.transaction_type        AS type,
        l.transaction_amount,
        l.commission_rate,
        l.commission_amount
    FROM "referral".partner_commission_ledger l
    LEFT JOIN "referral".partner_client pc ON pc.id = l.client_id
    WHERE p_partner_id IS NOT NULL AND l.partner_id = p_partner_id
      AND (v_ledger_from IS NULL OR l.created_at >= v_ledger_from)
      AND (v_to          IS NULL OR l.created_at <= v_to)
    ORDER BY l.created_at DESC, l.id;
END;
$$;

-- File: partner.sp_partner_report_mf_pnl.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_report_mf_pnl(
    p_partner_id VARCHAR,
    p_page       INT       DEFAULT 1,
    p_limit      INT       DEFAULT 20,
    p_from       VARCHAR   DEFAULT NULL,
    p_to         VARCHAR   DEFAULT NULL,
    p_export     BOOLEAN   DEFAULT FALSE,
    INOUT p_rows       refcursor DEFAULT 'rows_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page  INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit INT := COALESCE(NULLIF(p_limit, 0), 20);
    -- Node filters in JS here (not in Prisma): an unparseable date is an
    -- Invalid Date and every comparison with it is false → no filter, no error.
    v_from  TIMESTAMP;
    v_to    TIMESTAMP;
    v_now   TIMESTAMP := NOW();
    v_users TEXT[];
    v_total INT;
    -- inlined fn_js_parse_date locals
    _pd_s      TEXT;
    _pd_m      TEXT[];
    _pd_y      INT; _pd_mo INT; _pd_d INT;
    _pd_hh     INT; _pd_mi  INT; _pd_ss NUMERIC;
    _pd_tz     TEXT;
    _pd_base   TIMESTAMP;
    _pd_result TIMESTAMP(3);
BEGIN
    -- inline fn_js_parse_date(NULLIF(p_from,'')) -> v_from (no error on NULL = Node Invalid Date)
    IF p_from IS NOT NULL AND p_from <> '' THEN
        _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
        _pd_s := regexp_replace(p_from, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
        IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
        ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
        ELSE
            _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
            IF _pd_m IS NOT NULL THEN
                _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                    IF _pd_m[4] IS NOT NULL THEN
                        _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                        IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                    END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                    IF _pd_m IS NULL THEN _pd_result := NULL;
                    ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                END IF;
                IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                    IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                    ELSE
                        _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                        IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                            _pd_tz := replace(_pd_tz, ':', '');
                            _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                        END IF;
                        _pd_result := _pd_base::TIMESTAMP(3);
                    END IF;
                END IF;
            END IF;
        END IF;
        v_from := _pd_result;  -- NULL = no filter (matches Invalid Date behavior)
    END IF;
    -- inline fn_js_parse_date(NULLIF(p_to,'')) -> v_to (no error on NULL)
    IF p_to IS NOT NULL AND p_to <> '' THEN
        _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
        _pd_s := regexp_replace(p_to, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
        IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
        ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
        ELSE
            _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
            IF _pd_m IS NOT NULL THEN
                _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                    IF _pd_m[4] IS NOT NULL THEN
                        _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                        IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                    END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                    IF _pd_m IS NULL THEN _pd_result := NULL;
                    ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                END IF;
                IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                    IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                    ELSE
                        _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                        IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                            _pd_tz := replace(_pd_tz, ':', '');
                            _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                        END IF;
                        _pd_result := _pd_base::TIMESTAMP(3);
                    END IF;
                END IF;
            END IF;
        END IF;
        IF _pd_result IS NOT NULL THEN
            v_to := date_trunc('day', _pd_result) + INTERVAL '1 day' - INTERVAL '1 millisecond';
        END IF;
    END IF;
    SELECT ARRAY_AGG(linked_user_id) INTO v_users
    FROM "referral".partner_client
    WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL;

    DROP TABLE IF EXISTS tmp_mf_pnl;
    CREATE TEMP TABLE tmp_mf_pnl ON COMMIT DROP AS
    WITH tx AS (
        SELECT
            t.id, t.user_ref_id, t.transaction_type::TEXT AS ttype,
            COALESCE(t.quantity, 0)       AS qty,
            COALESCE(t.average_price, 0)  AS price,
            t.created_at,
            COALESCE(NULLIF(t.trading_symbol, ''), t.scripcode) AS symbol,
            m.id IS NOT NULL              AS has_meta,
            NULLIF(regexp_replace(m.folio_no, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'), '') AS folio,   -- JS folio_no?.trim() || null
            m.client_code, m.end_date, m.trade_type AS m_trade_type, m.amount AS m_amount,
            m.created_at                  AS m_created_at
        FROM "trade"."transaction" t
        LEFT JOIN LATERAL (
            SELECT o.id, o.folio_no, o.client_code, o.end_date, o.trade_type, o.amount, o.created_at
            FROM "trade".nse_mf_order o
            WHERE COALESCE(t.exchange_order_id, '') <> '' AND o.nse_order_id = t.exchange_order_id
            ORDER BY o.created_at DESC, o.id DESC LIMIT 1
        ) m ON TRUE
        WHERE t.user_ref_id = ANY(v_users)
          AND t.status::TEXT IN ('COMPLETED', 'REVAMPED')
          AND t.transaction_type::TEXT IN ('BUY', 'SELL')
          AND UPPER(t.asset) = 'MF'                       -- MySQL: case-insensitive
    ),
    tk AS (
        SELECT tx.*,
               (folio IS NOT NULL) AS resolved,
               CASE WHEN folio IS NOT NULL THEN 'user|' || user_ref_id || '|folio|' || folio
                    ELSE 'user|' || user_ref_id || '|scheme|' || symbol END AS orig_key
        FROM tx
    ),
    grp AS (
        SELECT orig_key,
               BOOL_OR(resolved)                                        AS resolved,
               MIN(user_ref_id)                                         AS user_ref_id,
               (ARRAY_AGG(symbol ORDER BY created_at, id))[1]           AS group_symbol,
               (ARRAY_AGG(folio  ORDER BY created_at, id))[1]           AS folio,
               MIN(created_at)                                          AS key_first
        FROM tk GROUP BY orig_key
    ),
    merge_map AS (
        SELECT g.orig_key,
               CASE WHEN NOT g.resolved AND c.cnt = 1 THEN c.target_key ELSE g.orig_key END AS final_key
        FROM grp g
        LEFT JOIN LATERAL (
            SELECT COUNT(*) AS cnt, MIN(r.orig_key) AS target_key
            FROM grp r
            WHERE r.resolved AND r.user_ref_id = g.user_ref_id AND r.group_symbol = g.group_symbol
        ) c ON TRUE
    ),
    agg AS (
        SELECT
            mm.final_key,
            SUM(CASE WHEN tk.ttype = 'BUY'  THEN tk.qty ELSE 0 END)            AS buy_qty,
            SUM(CASE WHEN tk.ttype = 'BUY'  THEN tk.qty * tk.price ELSE 0 END) AS buy_amt,
            SUM(CASE WHEN tk.ttype = 'SELL' THEN tk.qty ELSE 0 END)            AS sell_qty,
            MIN(tk.created_at)                                                 AS first_date,
            BOOL_OR(tk.m_trade_type = 'SIP')                                   AS any_sip,
            (ARRAY_AGG(tk.m_trade_type ORDER BY tk.m_created_at, tk.created_at, tk.id) FILTER (WHERE tk.has_meta))[1] AS first_type,
            (ARRAY_AGG(tk.m_amount     ORDER BY tk.m_created_at, tk.created_at, tk.id) FILTER (WHERE tk.has_meta))[1] AS first_amount,
            (ARRAY_AGG(tk.client_code  ORDER BY tk.m_created_at, tk.created_at, tk.id) FILTER (WHERE tk.has_meta))[1] AS first_client_code,
            (ARRAY_AGG(tk.end_date     ORDER BY tk.m_created_at DESC, tk.created_at DESC, tk.id DESC)
                 FILTER (WHERE tk.has_meta AND COALESCE(tk.end_date, '') <> ''))[1] AS valid_upto
        FROM tk JOIN merge_map mm ON mm.orig_key = tk.orig_key
        GROUP BY mm.final_key
    ),
    pos AS (
        SELECT g.user_ref_id, g.folio, g.group_symbol AS symbol, g.key_first, a.*,
               a.buy_qty - a.sell_qty                                       AS net_qty,
               CASE WHEN a.buy_qty > 0 THEN a.buy_amt / a.buy_qty ELSE 0 END AS avg_price
        FROM agg a JOIN grp g ON g.orig_key = a.final_key
    ),
    calc AS (
        SELECT p.*,
               (floor((p.net_qty * p.avg_price)::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC AS investment_amount,
               (floor((p.net_qty * p.avg_price)::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC AS current_value,     -- NAV fallback = avg cost
               EXTRACT(EPOCH FROM (v_now - p.first_date)) / (365.25 * 86400) AS years
        FROM pos p
        WHERE p.net_qty > 0
          AND (v_from IS NULL OR p.first_date >= v_from)
          AND (v_to   IS NULL OR p.first_date <= v_to)
    )
    SELECT
        c.folio                                                     AS folio_no,
        NULLIF(c.first_client_code, '')                             AS investor_id,
        COALESCE(cm.name, '-')                                      AS investor_name,
        u.email,
        u.phone_number                                              AS mobile,
        CASE WHEN c.any_sip THEN 'SIP'
             WHEN c.first_type IS NULL THEN NULL
             WHEN c.first_type = 'REDEMPTION' THEN 'LUMPSUM'
             ELSE c.first_type END                                  AS invt_type,
        NULLIF(COALESCE(substring(regexp_replace(c.first_amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::NUMERIC, 0), 0) AS portfolio_amount,   -- parseFloat(amount) || null
        c.first_date                                                AS subscribed_on,
        c.valid_upto,
        c.first_date                                                AS first_trxn_date,
        NULL::NUMERIC                                               AS scheme_aum,
        c.investment_amount,
        c.current_value                                             AS current_portfolio_value,
        (floor((c.current_value - c.investment_amount)::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC AS total_profit_loss,
        CASE WHEN c.investment_amount > 0 AND c.years >= 0.01
             THEN (floor((((POWER((c.current_value / c.investment_amount)::DOUBLE PRECISION, 1 / c.years) - 1) * 100)::NUMERIC)::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC
        END                                                         AS cagr_pct,
        NULL::TEXT                                                  AS scheme_isin,
        c.symbol                                                    AS scheme_code,
        c.symbol                                                    AS scheme_name,
        (floor(c.net_qty::DOUBLE PRECISION * 10000 + 0.5) / 10000)::NUMERIC AS units_held,   -- Math.round(x*10000)/10000
        NULL::NUMERIC                                               AS current_nav,
        (floor((c.avg_price)::DOUBLE PRECISION * 100.0 + 0.5) / 100.0)::NUMERIC AS avg_cost_nav,
        c.net_qty,
        c.avg_price,
        ROW_NUMBER() OVER (ORDER BY c.key_first, c.final_key)       AS pos
    FROM calc c
    LEFT JOIN LATERAL (
        SELECT name FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id = c.user_ref_id
        ORDER BY created_at DESC LIMIT 1
    ) cm ON TRUE
    LEFT JOIN "user"."user" u ON u.id = c.user_ref_id;

    SELECT COUNT(*) INTO v_total FROM tmp_mf_pnl;

    OPEN p_rows FOR
    SELECT * FROM tmp_mf_pnl
    WHERE p_export OR (pos > (v_page - 1) * v_limit AND pos <= v_page * v_limit)
    ORDER BY pos;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_report_payout_statement.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_report_payout_statement(
    p_partner_id VARCHAR,
    p_from       VARCHAR   DEFAULT NULL,
    p_to         VARCHAR   DEFAULT NULL,
    INOUT p_payouts refcursor DEFAULT 'payouts_cursor',
    INOUT p_summary refcursor DEFAULT 'summary_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_from TIMESTAMP;
    v_to   TIMESTAMP;
    -- inlined fn_js_parse_date locals
    _pd_s      TEXT;
    _pd_m      TEXT[];
    _pd_y      INT; _pd_mo INT; _pd_d INT;
    _pd_hh     INT; _pd_mi  INT; _pd_ss NUMERIC;
    _pd_tz     TEXT;
    _pd_base   TIMESTAMP;
    _pd_result TIMESTAMP(3);
BEGIN
    IF p_partner_id IS NOT NULL THEN   -- no partner → Node returns empty without querying
        IF p_from IS NOT NULL AND p_from <> '' THEN
            -- inline fn_js_parse_date(p_from) -> v_from
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_from, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_from := _pd_result;
            IF v_from IS NULL THEN RAISE EXCEPTION 'Failed to fetch payout statement'; END IF;
        END IF;
        IF p_to IS NOT NULL AND p_to <> '' THEN
            -- inline fn_js_parse_date(p_to) -> v_to
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_to, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_to := _pd_result;
            IF v_to IS NULL THEN RAISE EXCEPTION 'Failed to fetch payout statement'; END IF;
            v_to := date_trunc('day', v_to) + INTERVAL '1 day' - INTERVAL '1 millisecond';
        END IF;
    END IF;

    DROP TABLE IF EXISTS tmp_payouts;
    CREATE TEMP TABLE tmp_payouts ON COMMIT DROP AS
    WITH m AS (
        SELECT TO_CHAR(created_at, 'YYYY-MM') AS period, SUM(commission_amount) AS amount
        FROM "referral".partner_commission_ledger
        WHERE p_partner_id IS NOT NULL AND partner_id = p_partner_id
          AND (v_from IS NULL OR created_at >= v_from)
          AND (v_to   IS NULL OR created_at <= v_to)
        GROUP BY 1
    ),
    inv AS (
        SELECT DISTINCT ON (TO_CHAR(cycle_start, 'YYYY-MM'))
               TO_CHAR(cycle_start, 'YYYY-MM') AS period, status, paid_at
        FROM "referral".partner_invoice
        WHERE partner_id = p_partner_id
        ORDER BY TO_CHAR(cycle_start, 'YYYY-MM'), created_at DESC, id DESC
    )
    SELECT
        'payout-' || m.period                                  AS id,
        'PC-' || REPLACE(m.period, '-', '')                    AS payout_id,
        m.amount,
        m.period,
        COALESCE(inv.paid_at, (m.period || '-01')::TIMESTAMP)  AS credited_at,
        COALESCE(inv.paid_at, (m.period || '-01')::TIMESTAMP)  AS date,
        COALESCE(NULLIF(inv.status, ''), 'pending')            AS status
    FROM m LEFT JOIN inv ON inv.period = m.period;

    OPEN p_payouts FOR
    SELECT * FROM tmp_payouts ORDER BY period DESC;

    OPEN p_summary FOR
    SELECT
        COALESCE(SUM(amount) FILTER (WHERE status =  'paid'), 0) AS total_paid,
        COALESCE(SUM(amount) FILTER (WHERE status <> 'paid'), 0) AS total_pending,
        COUNT(*)                                                 AS total_count
    FROM tmp_payouts;
END;
$$;

-- File: partner.sp_partner_report_reverse_feed_transactions.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_report_reverse_feed_transactions(
    p_partner_id VARCHAR,
    p_page       INT DEFAULT 1,
    p_limit      INT DEFAULT 20,
    INOUT p_rows       refcursor DEFAULT 'rows_cursor',
    INOUT p_children   refcursor DEFAULT 'children_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page  INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit INT := COALESCE(NULLIF(p_limit, 0), 20);
    v_users TEXT[];
    v_total INT;
    v_ids   TEXT[];
BEGIN
    SELECT ARRAY_AGG(linked_user_id) INTO v_users
    FROM "referral".partner_client
    WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL;

    SELECT COUNT(*) INTO v_total
    FROM "trade"."transaction"
    WHERE user_ref_id = ANY(v_users) AND LOWER(trade_platform) = 'other' AND parent_transaction_id IS NULL;

    SELECT ARRAY_AGG(id ORDER BY created_at DESC, id) INTO v_ids FROM (
        SELECT id, created_at FROM "trade"."transaction"
        WHERE user_ref_id = ANY(v_users) AND LOWER(trade_platform) = 'other' AND parent_transaction_id IS NULL
        ORDER BY created_at DESC, id
        LIMIT v_limit OFFSET (v_page - 1) * v_limit
    ) x;

    OPEN p_rows FOR
    SELECT
        t.id,
        COALESCE(cm.name, '-')                                           AS client_name,
        t.asset,
        t.scripcode,
        t.trading_symbol,
        t.transaction_type::TEXT                                         AS transaction_type,
        t.quantity                                                       AS ordered_quantity,
        t.filled_quantity                                                AS executed_quantity,
        t.average_price                                                  AS executed_avg_price,
        t.status::TEXT                                                   AS status,
        t.provider                                                       AS broker_name,
        t.transaction_date                                               AS trade_date,
        t.description                                                    AS remarks,
        CASE WHEN SPLIT_PART(t.tag, '|', 1) = 'RF' THEN NULLIF(SPLIT_PART(t.tag, '|', 2), '') END AS batch_id,
        t.created_at,
        CASE WHEN t.asset = 'CEP' AND ch.cnt > 0 THEN ch.cnt END         AS stock_count
    FROM "trade"."transaction" t
    LEFT JOIN LATERAL (
        SELECT COUNT(*) AS cnt FROM "trade"."transaction" s WHERE s.parent_transaction_id = t.id
    ) ch ON TRUE
    LEFT JOIN LATERAL (
        SELECT name FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id = t.user_ref_id
        ORDER BY created_at DESC LIMIT 1
    ) cm ON TRUE
    WHERE t.id = ANY(COALESCE(v_ids, '{}'))
    ORDER BY t.created_at DESC, t.id;

    OPEN p_children FOR
    SELECT
        s.parent_transaction_id                                          AS parent_id,
        s.id,
        COALESCE(cm.name, '-')                                           AS client_name,
        s.asset,
        s.scripcode,
        s.trading_symbol,
        s.transaction_type::TEXT                                         AS transaction_type,
        s.quantity                                                       AS ordered_quantity,
        s.filled_quantity                                                AS executed_quantity,
        s.average_price                                                  AS executed_avg_price,
        s.status::TEXT                                                   AS status,
        s.provider                                                       AS broker_name,
        s.transaction_date                                               AS trade_date,
        s.description                                                    AS remarks,
        CASE WHEN SPLIT_PART(p.tag, '|', 1) = 'RF' THEN NULLIF(SPLIT_PART(p.tag, '|', 2), '') END AS batch_id,
        s.created_at
    FROM "trade"."transaction" s
    JOIN "trade"."transaction" p ON p.id = s.parent_transaction_id
    LEFT JOIN LATERAL (
        SELECT name FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id = p.user_ref_id
        ORDER BY created_at DESC LIMIT 1
    ) cm ON TRUE
    WHERE p.id = ANY(COALESCE(v_ids, '{}')) AND p.asset = 'CEP'
    ORDER BY s.parent_transaction_id, s.created_at, s.id;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", COALESCE(v_total, 0) AS total,
           CEIL(COALESCE(v_total, 0)::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_report_sip.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_report_sip(
    p_partner_id VARCHAR,
    p_page       INT       DEFAULT 1,
    p_limit      INT       DEFAULT 20,
    p_status     VARCHAR   DEFAULT NULL,
    p_from       VARCHAR   DEFAULT NULL,
    p_to         VARCHAR   DEFAULT NULL,
    p_export     BOOLEAN   DEFAULT FALSE,
    INOUT p_rows       refcursor DEFAULT 'rows_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page   INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit  INT := COALESCE(NULLIF(p_limit, 0), 20);
    v_status TEXT := UPPER(NULLIF(p_status, ''));
    v_from   TIMESTAMP;
    v_to     TIMESTAMP;
    v_users  TEXT[];
    v_total  INT;
    -- inlined fn_js_parse_date locals
    _pd_s      TEXT;
    _pd_m      TEXT[];
    _pd_y      INT; _pd_mo INT; _pd_d INT;
    _pd_hh     INT; _pd_mi  INT; _pd_ss NUMERIC;
    _pd_tz     TEXT;
    _pd_base   TIMESTAMP;
    _pd_result TIMESTAMP(3);
BEGIN
    SELECT ARRAY_AGG(linked_user_id) INTO v_users
    FROM "referral".partner_client
    WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL;

    IF v_users IS NOT NULL THEN   -- Node returns before querying when there are no linked clients
        IF p_from IS NOT NULL AND p_from <> '' THEN
            -- inline fn_js_parse_date(p_from) -> v_from
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_from, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_from := _pd_result;
            IF v_from IS NULL THEN RAISE EXCEPTION 'Failed to fetch SIP report'; END IF;
        END IF;
        IF p_to IS NOT NULL AND p_to <> '' THEN
            -- inline fn_js_parse_date(p_to) -> v_to
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_to, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_to := _pd_result;
            IF v_to IS NULL THEN RAISE EXCEPTION 'Failed to fetch SIP report'; END IF;
            v_to := date_trunc('day', v_to) + INTERVAL '1 day' - INTERVAL '1 millisecond';
        END IF;
    END IF;

    SELECT COUNT(*) INTO v_total
    FROM "trade".nse_mf_order
    WHERE user_ref_id = ANY(v_users) AND UPPER(trade_type) = 'SIP'   -- MySQL: case-insensitive
      AND (v_status IS NULL OR UPPER(order_status) = v_status)
      AND (v_from   IS NULL OR created_at >= v_from)
      AND (v_to     IS NULL OR created_at <= v_to);

    OPEN p_rows FOR
    SELECT
        s.id,
        COALESCE(cm.name, '-')                                           AS client_name,
        s.scheme_code                                                    AS scheme_name,
        COALESCE(NULLIF(s.amc_code, ''), s.scheme_code)                  AS fund_name,
        s.scheme_code,
        COALESCE(substring(regexp_replace(s.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::NUMERIC, 0) AS amount,
        COALESCE(NULLIF(s.frequency_type, ''), 'Monthly')                AS frequency,
        s.start_date,
        LOWER(COALESCE(NULLIF(s.order_status, ''), 'PENDING'))           AS status
    FROM "trade".nse_mf_order s
    LEFT JOIN LATERAL (
        SELECT name FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id = s.user_ref_id
        ORDER BY created_at DESC LIMIT 1
    ) cm ON TRUE
    WHERE s.user_ref_id = ANY(v_users) AND UPPER(s.trade_type) = 'SIP'
      AND (v_status IS NULL OR UPPER(s.order_status) = v_status)
      AND (v_from   IS NULL OR s.created_at >= v_from)
      AND (v_to     IS NULL OR s.created_at <= v_to)
    ORDER BY s.created_at DESC, s.id
    LIMIT CASE WHEN p_export THEN NULL ELSE v_limit END
    OFFSET CASE WHEN p_export THEN 0 ELSE (v_page - 1) * v_limit END;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_report_transactions.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_report_transactions(
    p_partner_id VARCHAR,
    p_page       INT       DEFAULT 1,
    p_limit      INT       DEFAULT 20,
    p_from       VARCHAR   DEFAULT NULL,
    p_to         VARCHAR   DEFAULT NULL,
    p_type       VARCHAR   DEFAULT NULL,
    p_export     BOOLEAN   DEFAULT FALSE,
    INOUT p_rows       refcursor DEFAULT 'rows_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page   INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit  INT := COALESCE(NULLIF(p_limit, 0), 20);
    v_from   TIMESTAMP;
    v_to     TIMESTAMP;
    v_type   TEXT;
    v_users  TEXT[];
    v_total  INT;
    -- inlined fn_js_parse_date locals
    _pd_s      TEXT;
    _pd_m      TEXT[];
    _pd_y      INT; _pd_mo INT; _pd_d INT;
    _pd_hh     INT; _pd_mi  INT; _pd_ss NUMERIC;
    _pd_tz     TEXT;
    _pd_base   TIMESTAMP;
    _pd_result TIMESTAMP(3);
BEGIN
    v_type := CASE LOWER(NULLIF(p_type, ''))
                  WHEN 'purchase'   THEN 'LUMPSUM'
                  WHEN 'sip'        THEN 'SIP'
                  WHEN 'redemption' THEN 'REDEMPTION'
                  WHEN 'switch'     THEN 'SWITCH'
                  WHEN 'buy'        THEN 'BUY'
                  WHEN 'sell'       THEN 'SELL'
                  WHEN 'exit'       THEN 'SELL'
                  ELSE UPPER(NULLIF(p_type, '')) END;

    SELECT ARRAY_AGG(linked_user_id) INTO v_users
    FROM "referral".partner_client
    WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL;

    -- Node returns [] before querying when there are no linked clients;
    -- otherwise Prisma throws on a bad date or on a type that is neither an
    -- MF trade type nor a TransactionType enum value (BUY / SELL) → 500.
    IF v_users IS NOT NULL THEN
        IF p_from IS NOT NULL AND p_from <> '' THEN
            -- inline fn_js_parse_date(p_from) -> v_from
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_from, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_from := _pd_result;
            IF v_from IS NULL THEN RAISE EXCEPTION 'Failed to fetch transaction report'; END IF;
        END IF;
        IF p_to IS NOT NULL AND p_to <> '' THEN
            -- inline fn_js_parse_date(p_to) -> v_to
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(p_to, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
            IF _pd_s IS NULL OR _pd_s = '' THEN _pd_result := NULL;
            ELSIF _pd_s ~ '^\d{4}$' THEN _pd_result := make_timestamp(_pd_s::INT, 1, 1, 0, 0, 0);
            ELSE
                _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})$');
                IF _pd_m IS NOT NULL THEN
                    _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT;
                    IF _pd_mo < 1 OR _pd_mo > 12 THEN _pd_result := NULL;
                    ELSE _pd_result := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0); END IF;
                ELSE
                    _pd_m := regexp_match(_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
                    IF _pd_m IS NOT NULL THEN
                        _pd_y := _pd_m[1]::INT; _pd_mo := _pd_m[2]::INT; _pd_d := _pd_m[3]::INT;
                        IF _pd_m[4] IS NOT NULL THEN
                            _pd_hh := _pd_m[4]::INT; _pd_mi := _pd_m[5]::INT; _pd_ss := COALESCE(_pd_m[6]::NUMERIC, 0); _pd_tz := _pd_m[7];
                            IF _pd_hh > 24 OR _pd_mi > 59 OR _pd_ss >= 60 THEN _pd_result := NULL; END IF;
                        END IF;
                    ELSE
                        _pd_m := regexp_match(_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
                        IF _pd_m IS NULL THEN _pd_result := NULL;
                        ELSE _pd_mo := _pd_m[1]::INT; _pd_d := _pd_m[2]::INT; _pd_y := _pd_m[3]::INT; END IF;
                    END IF;
                    IF _pd_result IS NULL AND _pd_m IS NOT NULL THEN
                        IF _pd_mo < 1 OR _pd_mo > 12 OR _pd_d < 1 OR _pd_d > 31 THEN _pd_result := NULL;
                        ELSE
                            _pd_base := make_timestamp(_pd_y, _pd_mo, 1, 0, 0, 0) + make_interval(days => _pd_d - 1) + make_interval(hours => _pd_hh, mins => _pd_mi, secs => _pd_ss);
                            IF _pd_tz IS NOT NULL AND _pd_tz <> 'Z' THEN
                                _pd_tz := replace(_pd_tz, ':', '');
                                _pd_base := _pd_base - (CASE WHEN left(_pd_tz,1)='-' THEN -1 ELSE 1 END) * make_interval(hours => substr(_pd_tz,2,2)::INT, mins => substr(_pd_tz,4,2)::INT);
                            END IF;
                            _pd_result := _pd_base::TIMESTAMP(3);
                        END IF;
                    END IF;
                END IF;
            END IF;
            v_to := _pd_result;
            IF v_to IS NULL THEN RAISE EXCEPTION 'Failed to fetch transaction report'; END IF;
            v_to := date_trunc('day', v_to) + INTERVAL '1 day' - INTERVAL '1 millisecond';
        END IF;
        IF v_type IS NOT NULL AND v_type NOT IN ('LUMPSUM', 'SIP', 'REDEMPTION', 'SWITCH', 'BUY', 'SELL') THEN
            RAISE EXCEPTION 'Failed to fetch transaction report';
        END IF;
    END IF;

    DROP TABLE IF EXISTS tmp_report_txn;
    CREATE TEMP TABLE tmp_report_txn ON COMMIT DROP AS
    WITH cm AS (
        SELECT DISTINCT ON (linked_user_id) linked_user_id, name
        FROM "referral".partner_client
        WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL
        ORDER BY linked_user_id, created_at DESC
    ),
    rows_all AS (
        SELECT
            t.id,
            COALESCE(cm.name, '-')                                     AS client_name,
            t.transaction_type::TEXT                                   AS type,
            COALESCE(NULLIF(t.trading_symbol, ''), t.scripcode)::TEXT  AS fund_name,
            CASE WHEN t.asset = 'CEP'
                 THEN COALESCE((SELECT SUM(COALESCE(s.average_price, 0) * COALESCE(s.filled_quantity, 0))
                                FROM "trade"."transaction" s WHERE s.parent_transaction_id = t.id), 0)
                 ELSE COALESCE(t.average_price, 0) * COALESCE(t.quantity, 0) END AS amount,
            t.quantity                                                 AS quantity,
            t.asset::TEXT                                              AS asset_type,
            t.status::TEXT                                             AS status,
            t.created_at                                               AS date,
            NULL::TEXT                                                 AS scheme_code,
            0                                                          AS src_ord
        FROM "trade"."transaction" t
        LEFT JOIN cm ON cm.linked_user_id = t.user_ref_id
        WHERE t.user_ref_id = ANY(v_users)
          AND t.parent_transaction_id IS NULL
          AND (v_type IS NULL OR (v_type NOT IN ('LUMPSUM', 'SIP', 'REDEMPTION', 'SWITCH')
                                  AND t.transaction_type::TEXT = v_type))
          AND (v_from IS NULL OR t.created_at >= v_from)
          AND (v_to   IS NULL OR t.created_at <= v_to)
        UNION ALL
        SELECT
            o.id,
            COALESCE(cm.name, '-'),
            o.trade_type::TEXT,
            o.scheme_code::TEXT,
            COALESCE(substring(regexp_replace(o.amount, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') FROM '^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)')::NUMERIC, 0),
            NULL::NUMERIC,
            'MF'::TEXT,
            o.order_status::TEXT,
            o.created_at,
            o.scheme_code::TEXT,
            1
        FROM "trade".nse_mf_order o
        LEFT JOIN cm ON cm.linked_user_id = o.user_ref_id
        WHERE o.user_ref_id = ANY(v_users)
          AND (v_type IS NULL OR (v_type NOT IN ('BUY', 'SELL') AND UPPER(o.trade_type) = v_type))
          AND (v_from IS NULL OR o.created_at >= v_from)
          AND (v_to   IS NULL OR o.created_at <= v_to)
    )
    SELECT *, ROW_NUMBER() OVER (ORDER BY date DESC, src_ord, id) AS pos FROM rows_all;

    SELECT COUNT(*) INTO v_total FROM tmp_report_txn;

    OPEN p_rows FOR
    SELECT id, client_name, type, fund_name, scheme_code, amount, quantity, asset_type, status, date
    FROM tmp_report_txn
    WHERE p_export OR (pos > (v_page - 1) * v_limit AND pos <= v_page * v_limit)
    ORDER BY pos;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS total_pages;
END;
$$;

-- File: partner.sp_partner_signup_get_session.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_signup_get_session(
    p_partner_id VARCHAR,
    p_type       VARCHAR,
    p_purpose    VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_hash TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "referral".partner_user WHERE id = p_partner_id) THEN
        RAISE EXCEPTION 'Partner session not found.';
    END IF;

    IF COALESCE(p_type, '') NOT IN ('email', 'mobile') THEN
        RAISE EXCEPTION 'type must be ''email'' or ''mobile''.';
    END IF;

    IF p_purpose = 'verify' THEN
        SELECT CASE WHEN p_type = 'email' THEN email_otp_hash ELSE mobile_otp_hash END
        INTO v_hash
        FROM "referral".partner_user WHERE id = p_partner_id;

        IF v_hash IS NULL THEN
            RAISE EXCEPTION 'No OTP sent to %. Please request a new one.', p_type;
        END IF;
    END IF;

    OPEN p_cursor FOR
    SELECT id, email, mobile, mobile_prefix, full_name,   -- raw, Node applies its own fallback
           CASE WHEN p_type = 'email' THEN email ELSE mobile END                     AS otp_key,
           CASE WHEN p_type = 'email' THEN email_otp_hash ELSE mobile_otp_hash END   AS otp_hash,
           email_verified, mobile_verified, status
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_signup_init.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_signup_init(
    p_email           VARCHAR,
    p_mobile          VARCHAR,
    p_mobile_prefix   VARCHAR,
    p_email_otp_hash  VARCHAR,
    p_mobile_otp_hash VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_email_id      TEXT;
    v_email_status  TEXT;
    v_mobile_id     TEXT;
    v_mobile_status TEXT;
    v_id            TEXT;
    -- Node: `mobile_prefix = "+91"` default applies only when the field is
    -- missing (Node passes the destructured value); '' and null are stored as-is.
    v_prefix        TEXT := p_mobile_prefix;
BEGIN
    IF COALESCE(p_email, '') = '' OR COALESCE(p_mobile, '') = '' THEN
        RAISE EXCEPTION 'Email and mobile are required.';
    END IF;
    IF p_email !~ E'^[^\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF@]+@[^\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF@]+\\.[^\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF@]+$' THEN
        RAISE EXCEPTION 'Invalid email address.';
    END IF;
    IF p_mobile !~ '^[6-9][0-9]{9}$' THEN
        RAISE EXCEPTION 'Invalid mobile number.';
    END IF;

    SELECT id, status::TEXT INTO v_email_id, v_email_status
    FROM "referral".partner_user WHERE LOWER(email) = LOWER(p_email) LIMIT 1;  -- MySQL ci collation
    IF v_email_id IS NOT NULL AND v_email_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'This email is already registered as a partner.';
    END IF;

    SELECT id, status::TEXT INTO v_mobile_id, v_mobile_status
    FROM "referral".partner_user WHERE mobile = p_mobile LIMIT 1;
    IF v_mobile_id IS NOT NULL AND v_mobile_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'This mobile number is already registered as a partner.';
    END IF;

    v_id := COALESCE(v_email_id, v_mobile_id);

    IF v_id IS NOT NULL THEN
        UPDATE "referral".partner_user SET
            email           = p_email,
            mobile          = p_mobile,
            mobile_prefix   = v_prefix,
            email_otp_hash  = p_email_otp_hash,
            mobile_otp_hash = p_mobile_otp_hash,
            email_verified  = FALSE,
            mobile_verified = FALSE,
            updated_at      = NOW()
        WHERE id = v_id;
    ELSE
        v_id := 'c' || replace(gen_random_uuid()::text, '-', '');
        INSERT INTO "referral".partner_user
            (id, email, mobile, mobile_prefix, email_otp_hash, mobile_otp_hash,
             email_verified, mobile_verified, onboarding_step, agreement_accepted,
             status, created_at, updated_at)
        VALUES
            (v_id, p_email, p_mobile, v_prefix, p_email_otp_hash, p_mobile_otp_hash,
             FALSE, FALSE, 0, FALSE,
             'DRAFT', NOW(), NOW());
    END IF;

    OPEN p_cursor FOR
    SELECT id, email, mobile, mobile_prefix, full_name, status
    FROM "referral".partner_user WHERE id = v_id;
END;
$$;

-- File: partner.sp_partner_signup_resend_otp.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_signup_resend_otp(
    p_partner_id VARCHAR,
    p_type       VARCHAR,
    p_otp_hash   VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "referral".partner_user WHERE id = p_partner_id) THEN
        RAISE EXCEPTION 'Partner session not found.';
    END IF;

    IF p_type = 'email' THEN
        UPDATE "referral".partner_user SET email_otp_hash = p_otp_hash, updated_at = NOW()
        WHERE id = p_partner_id;
    ELSIF p_type = 'mobile' THEN
        UPDATE "referral".partner_user SET mobile_otp_hash = p_otp_hash, updated_at = NOW()
        WHERE id = p_partner_id;
    ELSE
        RAISE EXCEPTION 'type must be ''email'' or ''mobile''.';
    END IF;

    OPEN p_cursor FOR
    SELECT id, email, mobile, email_otp_hash, mobile_otp_hash
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_signup_set_credentials.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_signup_set_credentials(
    p_partner_id    VARCHAR,
    p_full_name     VARCHAR,
    p_password_hash VARCHAR,
    p_token         VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_email_verified  BOOLEAN;
    v_mobile_verified BOOLEAN;
BEGIN
    IF COALESCE(p_full_name, '') = '' OR COALESCE(p_password_hash, '') = '' THEN
        RAISE EXCEPTION 'stag_token, full_name, and password are required.';
    END IF;
    IF LENGTH(regexp_replace(p_full_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')) < 2 THEN
        RAISE EXCEPTION 'Full name must be at least 2 characters.';
    END IF;

    SELECT email_verified, mobile_verified INTO v_email_verified, v_mobile_verified
    FROM "referral".partner_user WHERE id = p_partner_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Partner session not found.';
    END IF;

    IF NOT v_email_verified OR NOT v_mobile_verified THEN
        RAISE EXCEPTION 'Both email and mobile must be verified before setting credentials.';
    END IF;

    UPDATE "referral".partner_user SET
        full_name       = regexp_replace(p_full_name, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'),
        password_hash   = p_password_hash,
        token           = p_token,
        status          = 'CREDENTIALS_SET',
        onboarding_step = 0,
        updated_at      = NOW()
    WHERE id = p_partner_id;

    OPEN p_cursor FOR
    SELECT id, email, mobile, full_name, token, status, onboarding_step
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_signup_set_stag_token.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_signup_set_stag_token(
    p_partner_id VARCHAR,
    p_stag_token VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "referral".partner_user
    SET stag_token = p_stag_token, updated_at = NOW()
    WHERE id = p_partner_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Partner session not found.';
    END IF;

    OPEN p_cursor FOR
    SELECT id, stag_token FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_signup_verify_otp.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_signup_verify_otp(
    p_partner_id VARCHAR,
    p_type       VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_email_hash  TEXT;
    v_mobile_hash TEXT;
BEGIN
    SELECT email_otp_hash, mobile_otp_hash INTO v_email_hash, v_mobile_hash
    FROM "referral".partner_user WHERE id = p_partner_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Partner session not found.';
    END IF;

    IF p_type = 'email' THEN
        IF v_email_hash IS NULL THEN
            RAISE EXCEPTION 'No OTP sent to email. Please request a new one.';
        END IF;
        UPDATE "referral".partner_user
        SET email_verified = TRUE, email_otp_hash = NULL, updated_at = NOW()
        WHERE id = p_partner_id;
    ELSIF p_type = 'mobile' THEN
        IF v_mobile_hash IS NULL THEN
            RAISE EXCEPTION 'No OTP sent to mobile. Please request a new one.';
        END IF;
        UPDATE "referral".partner_user
        SET mobile_verified = TRUE, mobile_otp_hash = NULL, updated_at = NOW()
        WHERE id = p_partner_id;
    ELSE
        RAISE EXCEPTION 'type must be ''email'' or ''mobile''.';
    END IF;

    UPDATE "referral".partner_user
    SET status = 'OTP_VERIFIED', updated_at = NOW()
    WHERE id = p_partner_id AND email_verified AND mobile_verified;

    OPEN p_cursor FOR
    SELECT id, email_verified, mobile_verified, status
    FROM "referral".partner_user WHERE id = p_partner_id;
END;
$$;

-- File: partner.sp_partner_verify_client_otp.sql
CREATE OR REPLACE PROCEDURE partner.sp_partner_verify_client_otp(
    p_partner_id     VARCHAR,
    p_wealth_user_id VARCHAR,
    p_name           VARCHAR,
    p_mobile         VARCHAR,
    p_email          VARCHAR DEFAULT NULL,
    p_date_of_birth  VARCHAR DEFAULT NULL,
    p_notes          VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_user_id     TEXT;
    v_user_email  TEXT;
    v_kyc_status  TEXT;
    v_approved    BOOLEAN;
    v_new_id      TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM "referral".partner_client
               WHERE partner_id = p_partner_id AND mobile = p_mobile) THEN
        RAISE EXCEPTION 'A client with this mobile number already exists.' USING HINT = '409';
    END IF;

    SELECT id, email INTO v_user_id, v_user_email
    FROM "user"."user" WHERE id = p_wealth_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'The Nuqi Wealth account was not found.' USING HINT = '422';
    END IF;

    IF NULLIF(p_email, '') IS NOT NULL
       AND (v_user_email IS NULL OR v_user_email = '' OR LOWER(p_email) <> LOWER(v_user_email)) THEN
        RAISE EXCEPTION 'This email no longer matches the Nuqi Wealth account. Please start over.' USING HINT = '422';
    END IF;

    SELECT status INTO v_kyc_status FROM "kyc".kyc WHERE "userId" = v_user_id LIMIT 1;
    v_approved := v_kyc_status IN ('APPROVED', 'auto_approved') IS TRUE;

    v_new_id := 'c' || replace(gen_random_uuid()::TEXT, '-', '');
    INSERT INTO "referral".partner_client
        (id, partner_id, name, date_of_birth, mobile, email, notes,
         linked_user_id, status, source, created_at, updated_at)
    VALUES
        (v_new_id, p_partner_id, p_name, NULLIF(p_date_of_birth, ''), p_mobile, p_email, p_notes,
         v_user_id, CASE WHEN v_approved THEN 'active' ELSE 'kyc_pending' END, 'manual', NOW(), NOW());

    OPEN p_cursor FOR
    SELECT id, name, v_approved AS kyc_verified, status
    FROM "referral".partner_client WHERE id = v_new_id;
END;
$$;

