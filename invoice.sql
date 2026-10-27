-- Schema-wise stored procedures
-- Source: Procedure\invoice\
CREATE SCHEMA IF NOT EXISTS "invoice";

-- File: invoice.sp_subscription_invoice_get_data.sql
CREATE OR REPLACE PROCEDURE invoice.sp_subscription_invoice_get_data(
    p_user_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_txn_id   TEXT;
    v_count    INT;
    v_digits   TEXT;
    v_last_two TEXT;
    v_seq      TEXT;
BEGIN
    IF p_user_id IS NULL OR p_user_id = '' THEN
        RAISE EXCEPTION 'User ID is missing';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'User not found with ID %', p_user_id;
    END IF;

    -- Latest transaction of this user whose UserSubscription also belongs to this user
    SELECT st.id INTO v_txn_id
    FROM "payments".subscriptiontransaction st
    JOIN "payments".usersubscription us ON us.id = st.user_subscription_id
    WHERE st.user_ref_id = p_user_id
      AND us.user_ref_id = p_user_id
    ORDER BY st.created_at DESC
    LIMIT 1;

    IF v_txn_id IS NULL THEN
        RAISE EXCEPTION 'Subscription transaction not found for user %', p_user_id;
    END IF;

    -- Global invoice counter (all users, status <> PENDING)
    SELECT COUNT(*) INTO v_count
    FROM "payments".subscriptiontransaction
    WHERE transaction_status <> 'PENDING';

    -- 'INV' + last two digits of user id + 5-digit counter
    v_digits   := REGEXP_REPLACE(p_user_id, '\D', '', 'g');
    v_last_two := CASE WHEN LENGTH(v_digits) >= 2 THEN RIGHT(v_digits, 2)
                       ELSE LPAD(v_digits, 2, '0') END;
    v_seq      := GREATEST(v_count, 1)::TEXT;
    IF LENGTH(v_seq) < 5 THEN v_seq := LPAD(v_seq, 5, '0'); END IF;

    OPEN p_cursor FOR
    SELECT
        v_count                                                         AS invoice_count,
        'INV' || v_last_two || v_seq                                    AS invoice_number,
        -- user
        u.id                                                            AS user_id,
        NULLIF(CONCAT_WS(' ', NULLIF(u.first_name, ''), NULLIF(u.last_name, '')), '') AS user_name,
        u.email                                                         AS user_email,
        u.phone_prefix                                                  AS user_phone_prefix,
        u.phone_number                                                  AS user_phone,
        -- kyc
        k."fullName"                                                    AS kyc_full_name,
        k."panNumber"                                                   AS kyc_pan_number,
        k."addressText"                                                 AS kyc_address_text,
        COALESCE(NULLIF(k."addressJson"->>'country', ''), 'India')      AS kyc_country,
        -- subscription plan
        s.id                                                            AS subscription_id,
        s.name                                                          AS subscription_name,
        s.price                                                         AS subscription_price,
        -- transaction
        st.id                                                           AS transaction_row_id,
        st.order_id,
        st.transaction_id,
        st.created_at                                                   AS transaction_date,
        st.transaction_status                                           AS status,
        us.amount,
        us.plan_name,
        us.start_date,
        us.end_date,
        us.subscription_status,
        st.original_amount                                              AS original_amount,
        st.discount_amount                                              AS discount_amount,
        (COALESCE(st.discount_amount, 0) > 0)                           AS has_discount,
        pc.code                                                         AS promo_code,
        -- computed for PDF / email
        b.base_f::NUMERIC                                               AS base_amount,
        (floor((b.total_f - b.base_f) * 100::DOUBLE PRECISION + 0.5::DOUBLE PRECISION)
         / 100::DOUBLE PRECISION)::NUMERIC                              AS gst_amount,
        us.end_date - INTERVAL '1 day'                                  AS invoice_end_date
    FROM "payments".subscriptiontransaction st
    JOIN "payments".usersubscription us ON us.id = st.user_subscription_id
    JOIN "payments".subscriptions s     ON s.id  = st.subscription_id
    JOIN "user"."user" u                ON u.id  = st.user_ref_id
    LEFT JOIN "kyc".kyc k               ON k."userId" = u.id
    LEFT JOIN "catalog".promo_code pc   ON pc.id = st.promo_code_id
    CROSS JOIN LATERAL (
        SELECT t.total_f,
               floor((t.total_f / 1.18::DOUBLE PRECISION) * 100::DOUBLE PRECISION + 0.5::DOUBLE PRECISION)
               / 100::DOUBLE PRECISION AS base_f
        FROM (SELECT ROUND(us.amount, 2)::DOUBLE PRECISION AS total_f) t
    ) b
    WHERE st.id = v_txn_id
    LIMIT 1;
END;
$$;

