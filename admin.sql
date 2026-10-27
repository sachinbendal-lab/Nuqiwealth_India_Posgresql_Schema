-- Schema-wise stored procedures
-- Source: Procedure\admin\
CREATE SCHEMA IF NOT EXISTS "admin";

-- File: admin.sp_admin_commission_config_get.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_commission_config_get(
    p_partner_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "referral".partner_user WHERE id = p_partner_id) THEN
        RAISE EXCEPTION 'Partner not found';
    END IF;

    OPEN p_cursor FOR
    SELECT
        p.id                        AS partner_id,
        COALESCE(p.full_name, '')   AS name,
        p.email,
        p.status,
        COALESCE(cc.mf_rate, 0)     AS mf_rate,
        COALESCE(cc.cep_rate, 0)    AS cep_rate,
        cc.updated_at
    FROM "referral".partner_user p
    LEFT JOIN "referral".partner_commission_config cc ON cc.partner_id = p.id
    WHERE p.id = p_partner_id;
END;
$$;

-- File: admin.sp_admin_commission_config_list.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_commission_config_list(
    p_search       VARCHAR DEFAULT NULL,
    p_search_field VARCHAR DEFAULT NULL,
    p_has_config   VARCHAR DEFAULT NULL,
    p_page         INT DEFAULT 1,
    p_limit        INT DEFAULT 20,
    INOUT p_cursor     refcursor DEFAULT 'result_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page   INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit  INT := COALESCE(NULLIF(p_limit, 0), 20);
    v_terms  TEXT[];
    v_fields TEXT[];
BEGIN
    -- search.split(',').map(trim).filter(Boolean) — LIKE wildcards escaped
    SELECT ARRAY_AGG('%' || replace(replace(replace(t, '\', '\\'), '%', '\%'), '_', '\_') || '%' ORDER BY n)
    INTO v_terms
    FROM (
        SELECT regexp_replace(x, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS t, n
        FROM UNNEST(STRING_TO_ARRAY(COALESCE(p_search, ''), ',')) WITH ORDINALITY u(x, n)
    ) s
    WHERE t <> '';

    -- searchField.split(',').map(trim) — NOT filtered (same as Node)
    SELECT ARRAY_AGG(regexp_replace(x, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') ORDER BY n) INTO v_fields
    FROM UNNEST(STRING_TO_ARRAY(NULLIF(p_search_field, ''), ',')) WITH ORDINALITY u(x, n);

    CREATE TEMP TABLE IF NOT EXISTS tmp_pcm_cfg_list (
        partner_id TEXT, created_at TIMESTAMP, cfg_id TEXT
    ) ON COMMIT DROP;
    TRUNCATE tmp_pcm_cfg_list;

    INSERT INTO tmp_pcm_cfg_list
    SELECT p.id, p.created_at, cc.id
    FROM "referral".partner_user p
    LEFT JOIN "referral".partner_commission_config cc ON cc.partner_id = p.id
    WHERE p.status IN ('APPROVED', 'ACTIVE')
      AND (p_has_config IS DISTINCT FROM 'true'  OR cc.id IS NOT NULL)
      AND (p_has_config IS DISTINCT FROM 'false' OR cc.id IS NULL)
      AND NOT EXISTS (
          SELECT 1
          FROM UNNEST(COALESCE(v_terms, '{}')) WITH ORDINALITY t(term, i)
          WHERE NOT (
              CASE COALESCE(v_fields[i], '')
                  WHEN 'name'   THEN COALESCE(p.full_name, '') ILIKE term
                  WHEN 'email'  THEN COALESCE(p.email, '')     ILIKE term
                  WHEN 'mobile' THEN COALESCE(p.mobile, '')    ILIKE term
                  ELSE COALESCE(p.full_name, '') ILIKE term
                    OR COALESCE(p.email, '')     ILIKE term
                    OR COALESCE(p.mobile, '')    ILIKE term
              END
          )
      );

    OPEN p_cursor FOR
    SELECT
        p.id                      AS partner_id,
        COALESCE(p.full_name, '') AS name,
        p.email,
        p.mobile,
        p.status,
        cc.mf_rate,
        cc.cep_rate,
        cc.updated_at             AS config_updated_at,
        (cc.id IS NOT NULL)       AS has_config,
        CASE WHEN ar.id IS NULL THEN NULL
             WHEN ar."actionType" = 'PARTNER_COMMISSION_RESET' THEN 'RESET'
             ELSE 'SET_RATES' END                                   AS pending_action,
        CASE WHEN ar.id IS NULL THEN NULL
             WHEN ar."actionType" = 'PARTNER_COMMISSION_RESET'
                  THEN 'reset this partner''s rates to 0%'
             ELSE 'set this partner''s rates to MF ' || COALESCE(ar.payload->>'mf_rate', 'undefined')
                  || '% / CEP ' || COALESCE(ar.payload->>'cep_rate', 'undefined') || '%'
        END                                                         AS pending_description,
        ar."requestedByEmail"     AS pending_requested_by
    FROM tmp_pcm_cfg_list f
    JOIN "referral".partner_user p ON p.id = f.partner_id
    LEFT JOIN "referral".partner_commission_config cc ON cc.id = f.cfg_id
    LEFT JOIN LATERAL (
        SELECT * FROM "ops".approvalrequest a
        WHERE a.module = 'partner-commission-config'
          AND a.status = 'PENDING'
          AND a."actionType" IN ('PARTNER_COMMISSION_SET_RATES', 'PARTNER_COMMISSION_RESET')
          AND a."entityId" = p.id
        ORDER BY a."createdAt" DESC LIMIT 1
    ) ar ON TRUE
    ORDER BY f.created_at DESC, f.partner_id
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS limit, (SELECT COUNT(*) FROM tmp_pcm_cfg_list) AS total;
END;
$$;

-- File: admin.sp_admin_commission_config_reset.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_commission_config_reset(
    p_partner_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor',
    p_from_approval BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_id      TEXT;
    v_old_mf  NUMERIC;
    v_old_cep NUMERIC;
    v_msg     TEXT;
BEGIN
    SELECT id, mf_rate, cep_rate INTO v_id, v_old_mf, v_old_cep
    FROM "referral".partner_commission_config
    WHERE partner_id = p_partner_id;

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No commission config found for this partner';
    END IF;

    IF NOT COALESCE(p_from_approval, FALSE) THEN
        SELECT 'A request to '
               || CASE WHEN a."actionType" = 'PARTNER_COMMISSION_RESET'
                       THEN 'reset this partner''s rates to 0%'
                       ELSE 'set this partner''s rates to MF ' || COALESCE(a.payload->>'mf_rate', 'undefined')
                            || '% / CEP ' || COALESCE(a.payload->>'cep_rate', 'undefined') || '%'
                  END
               || ' is already awaiting Checker review (requested by ' || a."requestedByEmail" || ').'
        INTO v_msg
        FROM "ops".approvalrequest a
        WHERE a.module = 'partner-commission-config'
          AND a.status = 'PENDING'
          AND a."actionType" IN ('PARTNER_COMMISSION_SET_RATES', 'PARTNER_COMMISSION_RESET')
          AND a."entityId" = p_partner_id
        ORDER BY a."createdAt" DESC
        LIMIT 1;
        IF v_msg IS NOT NULL THEN
            RAISE EXCEPTION '%', v_msg;
        END IF;
    END IF;

    UPDATE "referral".partner_commission_config
    SET mf_rate = 0, cep_rate = 0, updated_at = NOW()
    WHERE id = v_id;

    OPEN p_cursor FOR
    SELECT TRUE AS success,
           'Commission rates reset to 0. Existing ledger entries are preserved.' AS message,
           p_partner_id AS partner_id,
           v_old_mf     AS old_mf_rate,
           v_old_cep    AS old_cep_rate;
END;
$$;

-- File: admin.sp_admin_commission_config_reset_precheck.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_commission_config_reset_precheck(
    p_partner_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_msg TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "referral".partner_commission_config WHERE partner_id = p_partner_id) THEN
        RAISE EXCEPTION 'No commission config found for this partner';
    END IF;

    SELECT 'A request to '
           || CASE WHEN a."actionType" = 'PARTNER_COMMISSION_RESET'
                   THEN 'reset this partner''s rates to 0%'
                   ELSE 'set this partner''s rates to MF ' || COALESCE(a.payload->>'mf_rate', 'undefined')
                        || '% / CEP ' || COALESCE(a.payload->>'cep_rate', 'undefined') || '%'
              END
           || ' is already awaiting Checker review (requested by ' || a."requestedByEmail" || ').'
    INTO v_msg
    FROM "ops".approvalrequest a
    WHERE a.module = 'partner-commission-config'
      AND a.status = 'PENDING'
      AND a."actionType" IN ('PARTNER_COMMISSION_SET_RATES', 'PARTNER_COMMISSION_RESET')
      AND a."entityId" = p_partner_id
    ORDER BY a."createdAt" DESC
    LIMIT 1;
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION '%', v_msg;
    END IF;

    OPEN p_cursor FOR
    SELECT cc.partner_id, p.email, p.full_name,
           cc.mf_rate  AS old_mf_rate,
           cc.cep_rate AS old_cep_rate
    FROM "referral".partner_commission_config cc
    LEFT JOIN "referral".partner_user p ON p.id = cc.partner_id
    WHERE cc.partner_id = p_partner_id;
END;
$$;

-- File: admin.sp_admin_commission_config_set.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_commission_config_set(
    p_partner_id VARCHAR,
    p_mf_rate    NUMERIC,
    p_cep_rate   NUMERIC,
    INOUT p_cursor refcursor DEFAULT 'result_cursor',
    p_from_approval BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_msg     TEXT;
    v_old_id  TEXT;
    v_old_mf  NUMERIC;
    v_old_cep NUMERIC;
BEGIN
    IF NOT COALESCE(p_from_approval, FALSE) THEN
        -- 1. Validate rates (handler only)
        IF p_mf_rate IS NULL OR p_mf_rate < 0 OR p_mf_rate > 100
           OR p_cep_rate IS NULL OR p_cep_rate < 0 OR p_cep_rate > 100 THEN
            RAISE EXCEPTION 'mf_rate and cep_rate must be numbers between 0 and 100';
        END IF;
    END IF;

    -- 2. Partner exists (handler and applier)
    IF NOT EXISTS (SELECT 1 FROM "referral".partner_user WHERE id = p_partner_id) THEN
        RAISE EXCEPTION 'Partner not found';
    END IF;

    IF NOT COALESCE(p_from_approval, FALSE) THEN
        -- 3. Block if a Maker→Checker request is already open (handler only)
        SELECT 'A request to '
               || CASE WHEN a."actionType" = 'PARTNER_COMMISSION_RESET'
                       THEN 'reset this partner''s rates to 0%'
                       ELSE 'set this partner''s rates to MF ' || COALESCE(a.payload->>'mf_rate', 'undefined')
                            || '% / CEP ' || COALESCE(a.payload->>'cep_rate', 'undefined') || '%'
                  END
               || ' is already awaiting Checker review (requested by ' || a."requestedByEmail" || ').'
        INTO v_msg
        FROM "ops".approvalrequest a
        WHERE a.module = 'partner-commission-config'
          AND a.status = 'PENDING'
          AND a."actionType" IN ('PARTNER_COMMISSION_SET_RATES', 'PARTNER_COMMISSION_RESET')
          AND a."entityId" = p_partner_id
        ORDER BY a."createdAt" DESC
        LIMIT 1;
        IF v_msg IS NOT NULL THEN
            RAISE EXCEPTION '%', v_msg;
        END IF;
    END IF;

    -- 4. Upsert (partner_id is unique in Prisma)
    SELECT id, mf_rate, cep_rate INTO v_old_id, v_old_mf, v_old_cep
    FROM "referral".partner_commission_config
    WHERE partner_id = p_partner_id;

    IF v_old_id IS NOT NULL THEN
        UPDATE "referral".partner_commission_config
        SET mf_rate = p_mf_rate, cep_rate = p_cep_rate, updated_at = NOW()
        WHERE id = v_old_id;
    ELSE
        v_old_id := 'c' || replace(gen_random_uuid()::text, '-', '');
        INSERT INTO "referral".partner_commission_config
            (id, partner_id, mf_rate, cep_rate, created_at, updated_at)
        VALUES
            (v_old_id, p_partner_id, p_mf_rate, p_cep_rate, NOW(), NOW());
    END IF;

    OPEN p_cursor FOR
    SELECT partner_id, mf_rate, cep_rate, updated_at,
           v_old_mf  AS old_mf_rate,
           v_old_cep AS old_cep_rate
    FROM "referral".partner_commission_config WHERE id = v_old_id;
END;
$$;

-- File: admin.sp_admin_commission_config_set_precheck.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_commission_config_set_precheck(
    p_partner_id VARCHAR,
    p_mf_rate    NUMERIC,
    p_cep_rate   NUMERIC,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_msg TEXT;
BEGIN
    IF p_mf_rate IS NULL OR p_mf_rate < 0 OR p_mf_rate > 100
       OR p_cep_rate IS NULL OR p_cep_rate < 0 OR p_cep_rate > 100 THEN
        RAISE EXCEPTION 'mf_rate and cep_rate must be numbers between 0 and 100';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "referral".partner_user WHERE id = p_partner_id) THEN
        RAISE EXCEPTION 'Partner not found';
    END IF;

    SELECT 'A request to '
           || CASE WHEN a."actionType" = 'PARTNER_COMMISSION_RESET'
                   THEN 'reset this partner''s rates to 0%'
                   ELSE 'set this partner''s rates to MF ' || COALESCE(a.payload->>'mf_rate', 'undefined')
                        || '% / CEP ' || COALESCE(a.payload->>'cep_rate', 'undefined') || '%'
              END
           || ' is already awaiting Checker review (requested by ' || a."requestedByEmail" || ').'
    INTO v_msg
    FROM "ops".approvalrequest a
    WHERE a.module = 'partner-commission-config'
      AND a.status = 'PENDING'
      AND a."actionType" IN ('PARTNER_COMMISSION_SET_RATES', 'PARTNER_COMMISSION_RESET')
      AND a."entityId" = p_partner_id
    ORDER BY a."createdAt" DESC
    LIMIT 1;
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION '%', v_msg;
    END IF;

    OPEN p_cursor FOR
    SELECT p.id AS partner_id, p.email, p.full_name,
           cc.mf_rate  AS old_mf_rate,
           cc.cep_rate AS old_cep_rate
    FROM "referral".partner_user p
    LEFT JOIN "referral".partner_commission_config cc ON cc.partner_id = p.id
    WHERE p.id = p_partner_id;
END;
$$;

-- File: admin.sp_admin_commission_get_invoice_for_mark_paid.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_commission_get_invoice_for_mark_paid(
    p_invoice_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    SELECT status INTO v_status
    FROM "referral".partner_invoice WHERE id = p_invoice_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invoice not found';
    END IF;

    IF v_status = 'paid' THEN
        RAISE EXCEPTION 'Invoice already marked as paid';
    END IF;

    OPEN p_cursor FOR
    SELECT
        i.id, i.partner_id, i.invoice_number, i.cycle_start, i.cycle_end,
        i.commission_amount, i.gst_applied, i.gst_amount, i.total_amount,
        i.status, i.paid_at, i.created_at,
        p.full_name AS partner_full_name,
        p.email     AS partner_email
    FROM "referral".partner_invoice i
    LEFT JOIN "referral".partner_user p ON p.id = i.partner_id
    WHERE i.id = p_invoice_id;
END;
$$;

-- File: admin.sp_admin_commission_get_invoices.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_commission_get_invoices(
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT
        i.id, i.partner_id, i.invoice_number, i.cycle_start, i.cycle_end,
        i.commission_amount, i.gst_applied, i.gst_amount, i.total_amount,
        i.status, i.paid_at, i.created_at,
        p.full_name AS partner_full_name,
        p.email     AS partner_email
    FROM "referral".partner_invoice i
    LEFT JOIN "referral".partner_user p ON p.id = i.partner_id
    ORDER BY i.created_at DESC;
END;
$$;

-- File: admin.sp_admin_commission_mark_invoice_paid.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_commission_mark_invoice_paid(
    p_invoice_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    SELECT status INTO v_status
    FROM "referral".partner_invoice WHERE id = p_invoice_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invoice not found';
    END IF;

    IF v_status = 'paid' THEN
        RAISE EXCEPTION 'Invoice already marked as paid';
    END IF;

    UPDATE "referral".partner_invoice
    SET status = 'paid', paid_at = NOW()
    WHERE id = p_invoice_id;

    OPEN p_cursor FOR
    SELECT
        i.id, i.partner_id, i.invoice_number, i.cycle_start, i.cycle_end,
        i.commission_amount, i.gst_applied, i.gst_amount, i.total_amount,
        i.status, i.paid_at, i.created_at,
        v_status    AS status_before,
        p.full_name AS partner_full_name,
        p.email     AS partner_email
    FROM "referral".partner_invoice i
    LEFT JOIN "referral".partner_user p ON p.id = i.partner_id
    WHERE i.id = p_invoice_id;
END;
$$;

-- File: admin.sp_admin_partner_config_deactivate.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_partner_config_deactivate(
    p_user_id  VARCHAR,
    p_admin_id VARCHAR DEFAULT 'UNKNOWN',
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_cfg_id  TEXT;
    v_old_pct NUMERIC;
BEGIN
    SELECT id, direct_referral_percent INTO v_cfg_id, v_old_pct
    FROM "referral".partner_points_config
    WHERE user_id = p_user_id;

    IF v_cfg_id IS NULL THEN
        RAISE EXCEPTION 'No config found for this user';
    END IF;

    UPDATE "referral".partner_points_config SET
        direct_referral_percent = 0,
        parent_referral_percent = 0,
        original_owner_percent  = 0,
        is_active               = FALSE,
        set_by                  = COALESCE(p_admin_id, 'UNKNOWN'),
        updated_at              = NOW()
    WHERE id = v_cfg_id;

    OPEN p_cursor FOR
    SELECT TRUE AS success,
           'Partner config deactivated. Existing points are preserved.' AS message,
           p_user_id AS user_id,
           v_old_pct AS old_referral_percent;
END;
$$;

-- File: admin.sp_admin_partner_config_get.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_partner_config_get(
    p_user_id VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'User not found';
    END IF;

    OPEN p_cursor FOR
    SELECT
        u.id                                                                     AS user_id,
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS name,
        u.email,
        r.referal_code                                                           AS referral_code,
        (pc.id IS NOT NULL)                                                      AS has_config,
        pc.direct_referral_percent                                               AS referral_percent,
        pc.is_active                                                             AS config_is_active,
        pc.set_by                                                                AS config_set_by,
        pc.updated_at                                                            AS config_updated_at,
        COALESCE(pb.total_points, 0)                                             AS total_earned,
        COALESCE(pb.current_points, 0)                                           AS current_balance
    FROM "user"."user" u
    LEFT JOIN LATERAL (
        SELECT referal_code FROM "referral".referral
        WHERE user_ref_id = u.id AND is_active = TRUE
        ORDER BY created_at DESC LIMIT 1
    ) r ON TRUE
    LEFT JOIN "referral".partner_points_config  pc ON pc.user_id = u.id
    LEFT JOIN "referral".partner_points_balance pb ON pb.user_id = u.id
    WHERE u.id = p_user_id;
END;
$$;

-- File: admin.sp_admin_partner_config_list.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_partner_config_list(
    p_search       VARCHAR DEFAULT NULL,
    p_search_field VARCHAR DEFAULT NULL,
    p_has_config   VARCHAR DEFAULT NULL,
    p_page         INT DEFAULT 1,
    p_limit        INT DEFAULT 20,
    INOUT p_cursor     refcursor DEFAULT 'result_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page   INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit  INT := COALESCE(NULLIF(p_limit, 0), 20);
    v_terms  TEXT[];
    v_fields TEXT[];
BEGIN
    SELECT ARRAY_AGG('%' || replace(replace(replace(t, '\', '\\'), '%', '\%'), '_', '\_') || '%' ORDER BY n)
    INTO v_terms
    FROM (
        SELECT regexp_replace(x, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS t, n
        FROM UNNEST(STRING_TO_ARRAY(COALESCE(p_search, ''), ',')) WITH ORDINALITY u(x, n)
    ) s
    WHERE t <> '';

    SELECT ARRAY_AGG(regexp_replace(x, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') ORDER BY n) INTO v_fields
    FROM UNNEST(STRING_TO_ARRAY(NULLIF(p_search_field, ''), ',')) WITH ORDINALITY u(x, n);

    CREATE TEMP TABLE IF NOT EXISTS tmp_pcm_ppc_list (
        user_id TEXT, created_at TIMESTAMP
    ) ON COMMIT DROP;
    TRUNCATE tmp_pcm_ppc_list;

    INSERT INTO tmp_pcm_ppc_list
    SELECT u.id, u.created_at
    FROM "user"."user" u
    WHERE EXISTS (SELECT 1 FROM "referral".referral rr WHERE rr.user_ref_id = u.id)
      AND (p_has_config IS DISTINCT FROM 'true'
           OR EXISTS (SELECT 1 FROM "referral".partner_points_config c WHERE c.user_id = u.id))
      AND (p_has_config IS DISTINCT FROM 'false'
           OR NOT EXISTS (SELECT 1 FROM "referral".partner_points_config c WHERE c.user_id = u.id))
      AND NOT EXISTS (
          SELECT 1
          FROM UNNEST(COALESCE(v_terms, '{}')) WITH ORDINALITY t(term, i)
          WHERE NOT (
              CASE COALESCE(v_fields[i], '')
                  WHEN 'name'  THEN COALESCE(u.first_name, '') ILIKE term
                                 OR COALESCE(u.last_name, '')  ILIKE term
                  WHEN 'email' THEN COALESCE(u.email, '')      ILIKE term
                  ELSE COALESCE(u.first_name, '') ILIKE term
                    OR COALESCE(u.last_name, '')  ILIKE term
                    OR COALESCE(u.email, '')      ILIKE term
              END
          )
      );

    OPEN p_cursor FOR
    SELECT
        u.id                                                                     AS user_id,
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS name,
        u.email,
        r.referal_code                                                           AS referral_code,
        (pc.id IS NOT NULL)                                                      AS has_config,
        pc.direct_referral_percent                                               AS referral_percent,
        pc.is_active                                                             AS config_is_active,
        pc.set_by                                                                AS config_set_by,
        pc.updated_at                                                            AS config_updated_at,
        COALESCE(pb.total_points, 0)                                             AS total_earned,
        COALESCE(pb.current_points, 0)                                           AS current_balance
    FROM tmp_pcm_ppc_list f
    JOIN "user"."user" u ON u.id = f.user_id
    LEFT JOIN LATERAL (
        SELECT referal_code FROM "referral".referral
        WHERE user_ref_id = u.id AND is_active = TRUE
        ORDER BY created_at DESC LIMIT 1
    ) r ON TRUE
    LEFT JOIN "referral".partner_points_config  pc ON pc.user_id = u.id
    LEFT JOIN "referral".partner_points_balance pb ON pb.user_id = u.id
    ORDER BY f.created_at DESC, f.user_id
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS limit, (SELECT COUNT(*) FROM tmp_pcm_ppc_list) AS total;
END;
$$;

-- File: admin.sp_admin_partner_config_set.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_partner_config_set(
    p_user_id          VARCHAR,
    p_referral_percent NUMERIC,
    p_admin_id         VARCHAR DEFAULT 'UNKNOWN',
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_cfg_id  TEXT;
    v_old_pct NUMERIC;
BEGIN
    IF p_referral_percent IS NULL OR p_referral_percent < 0 OR p_referral_percent > 100 THEN
        RAISE EXCEPTION 'referral_percent must be a number between 0 and 100';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'User not found';
    END IF;

    SELECT id, direct_referral_percent INTO v_cfg_id, v_old_pct
    FROM "referral".partner_points_config
    WHERE user_id = p_user_id;

    IF v_cfg_id IS NOT NULL THEN
        UPDATE "referral".partner_points_config SET
            direct_referral_percent = p_referral_percent,
            parent_referral_percent = 0,
            original_owner_percent  = 0,
            is_active               = TRUE,
            set_by                  = COALESCE(p_admin_id, 'UNKNOWN'),
            updated_at              = NOW()
        WHERE id = v_cfg_id;
    ELSE
        v_cfg_id := 'c' || replace(gen_random_uuid()::text, '-', '');
        INSERT INTO "referral".partner_points_config
            (id, user_id, direct_referral_percent, parent_referral_percent, original_owner_percent,
             is_active, set_by, created_at, updated_at)
        VALUES
            (v_cfg_id, p_user_id, p_referral_percent, 0, 0,
             TRUE, COALESCE(p_admin_id, 'UNKNOWN'), NOW(), NOW());
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "referral".partner_points_balance WHERE user_id = p_user_id) THEN
        INSERT INTO "referral".partner_points_balance
            (id, user_id, total_points, current_points, created_at, updated_at)
        VALUES
            ('c' || replace(gen_random_uuid()::text, '-', ''), p_user_id, 0, 0, NOW(), NOW());
    END IF;

    OPEN p_cursor FOR
    SELECT user_id,
           direct_referral_percent AS referral_percent,
           is_active,
           v_old_pct               AS old_referral_percent
    FROM "referral".partner_points_config WHERE id = v_cfg_id;
END;
$$;

-- File: admin.sp_admin_points_ledger_for_user.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_points_ledger_for_user(
    p_user_id VARCHAR,
    p_page    INT DEFAULT 1,
    p_limit   INT DEFAULT 20,
    INOUT p_balance    refcursor DEFAULT 'balance_cursor',
    INOUT p_ledger     refcursor DEFAULT 'ledger_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page  INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit INT := COALESCE(NULLIF(p_limit, 0), 20);
BEGIN
    OPEN p_balance FOR
    SELECT
        COALESCE(MAX(total_points), 0)   AS total_earned,
        COALESCE(MAX(current_points), 0) AS current_balance
    FROM "referral".partner_points_balance
    WHERE user_id = p_user_id;

    OPEN p_ledger FOR
    SELECT
        l.id,
        regexp_replace(COALESCE(s.first_name, '') || ' ' || COALESCE(s.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS source_user_name,
        s.email                                                                  AS source_user_email,
        l.points_type,
        l.percentage_applied,
        l.transaction_amount,
        l.points_earned,
        l.status,
        l.created_at
    FROM "referral".partner_points_ledger l
    JOIN "user"."user" s ON s.id = l.source_user_id
    WHERE l.beneficiary_user_id = p_user_id
    ORDER BY l.created_at DESC, l.id
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS limit,
           (SELECT COUNT(*) FROM "referral".partner_points_ledger WHERE beneficiary_user_id = p_user_id) AS total;
END;
$$;

-- File: admin.sp_admin_points_ledger_list.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_points_ledger_list(
    p_user_id VARCHAR DEFAULT NULL,
    p_type    VARCHAR DEFAULT NULL,
    p_from    VARCHAR DEFAULT NULL,
    p_to      VARCHAR DEFAULT NULL,
    p_page    INT DEFAULT 1,
    p_limit   INT DEFAULT 20,
    INOUT p_cursor     refcursor DEFAULT 'result_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page    INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit   INT := COALESCE(NULLIF(p_limit, 0), 20);
    v_type    TEXT := NULLIF(p_type, '');
    v_from    TIMESTAMP;
    v_to      TIMESTAMP;
    v_total   BIGINT;
    -- fn_js_parse_date helper variables (inlined)
    v_pd_s    TEXT;
    v_pd_m    TEXT[];
    v_pd_y    INT;
    v_pd_mo   INT;
    v_pd_d    INT;
    v_pd_hh   INT;
    v_pd_mi   INT;
    v_pd_ss   NUMERIC;
    v_pd_tz   TEXT;
    v_pd_base TIMESTAMP;
BEGIN
    -- fn_js_parse_date inlined for v_from
    v_from := NULL;
    v_pd_s := regexp_replace(NULLIF(p_from, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
    <<parse_from>>
    BEGIN
        IF v_pd_s IS NULL OR v_pd_s = '' THEN EXIT parse_from; END IF;
        IF v_pd_s ~ '^\d{4}$' THEN
            v_from := make_timestamp(v_pd_s::INT, 1, 1, 0, 0, 0); EXIT parse_from;
        END IF;
        v_pd_m := regexp_match(v_pd_s, '^(\d{4})-(\d{2})$');
        IF v_pd_m IS NOT NULL THEN
            v_pd_y := v_pd_m[1]::INT; v_pd_mo := v_pd_m[2]::INT;
            IF v_pd_mo >= 1 AND v_pd_mo <= 12 THEN v_from := make_timestamp(v_pd_y, v_pd_mo, 1, 0, 0, 0); END IF;
            EXIT parse_from;
        END IF;
        v_pd_hh := 0; v_pd_mi := 0; v_pd_ss := 0; v_pd_tz := NULL;
        v_pd_m := regexp_match(v_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
        IF v_pd_m IS NOT NULL THEN
            v_pd_y := v_pd_m[1]::INT; v_pd_mo := v_pd_m[2]::INT; v_pd_d := v_pd_m[3]::INT;
            IF v_pd_m[4] IS NOT NULL THEN
                v_pd_hh := v_pd_m[4]::INT; v_pd_mi := v_pd_m[5]::INT;
                v_pd_ss := COALESCE(v_pd_m[6]::NUMERIC, 0); v_pd_tz := v_pd_m[7];
                IF v_pd_hh > 24 OR v_pd_mi > 59 OR v_pd_ss >= 60 THEN EXIT parse_from; END IF;
            END IF;
        ELSE
            v_pd_m := regexp_match(v_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
            IF v_pd_m IS NULL THEN EXIT parse_from; END IF;
            v_pd_mo := v_pd_m[1]::INT; v_pd_d := v_pd_m[2]::INT; v_pd_y := v_pd_m[3]::INT;
        END IF;
        IF v_pd_mo < 1 OR v_pd_mo > 12 OR v_pd_d < 1 OR v_pd_d > 31 THEN EXIT parse_from; END IF;
        v_pd_base := make_timestamp(v_pd_y, v_pd_mo, 1, 0, 0, 0)
                    + make_interval(days => v_pd_d - 1)
                    + make_interval(hours => v_pd_hh, mins => v_pd_mi, secs => v_pd_ss);
        IF v_pd_tz IS NOT NULL AND v_pd_tz <> 'Z' THEN
            v_pd_tz := replace(v_pd_tz, ':', '');
            v_pd_base := v_pd_base - (CASE WHEN left(v_pd_tz, 1) = '-' THEN -1 ELSE 1 END)
                         * make_interval(hours => substr(v_pd_tz, 2, 2)::INT, mins => substr(v_pd_tz, 4, 2)::INT);
        END IF;
        v_from := v_pd_base::TIMESTAMP(3);
    END;

    -- fn_js_parse_date inlined for v_to
    v_to := NULL;
    v_pd_s := regexp_replace(NULLIF(p_to, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
    <<parse_to>>
    BEGIN
        IF v_pd_s IS NULL OR v_pd_s = '' THEN EXIT parse_to; END IF;
        IF v_pd_s ~ '^\d{4}$' THEN
            v_to := make_timestamp(v_pd_s::INT, 1, 1, 0, 0, 0); EXIT parse_to;
        END IF;
        v_pd_m := regexp_match(v_pd_s, '^(\d{4})-(\d{2})$');
        IF v_pd_m IS NOT NULL THEN
            v_pd_y := v_pd_m[1]::INT; v_pd_mo := v_pd_m[2]::INT;
            IF v_pd_mo >= 1 AND v_pd_mo <= 12 THEN v_to := make_timestamp(v_pd_y, v_pd_mo, 1, 0, 0, 0); END IF;
            EXIT parse_to;
        END IF;
        v_pd_hh := 0; v_pd_mi := 0; v_pd_ss := 0; v_pd_tz := NULL;
        v_pd_m := regexp_match(v_pd_s, '^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*(Z|[+-]\d{2}:?\d{2})?)?$');
        IF v_pd_m IS NOT NULL THEN
            v_pd_y := v_pd_m[1]::INT; v_pd_mo := v_pd_m[2]::INT; v_pd_d := v_pd_m[3]::INT;
            IF v_pd_m[4] IS NOT NULL THEN
                v_pd_hh := v_pd_m[4]::INT; v_pd_mi := v_pd_m[5]::INT;
                v_pd_ss := COALESCE(v_pd_m[6]::NUMERIC, 0); v_pd_tz := v_pd_m[7];
                IF v_pd_hh > 24 OR v_pd_mi > 59 OR v_pd_ss >= 60 THEN EXIT parse_to; END IF;
            END IF;
        ELSE
            v_pd_m := regexp_match(v_pd_s, '^(\d{1,2})/(\d{1,2})/(\d{4})$');
            IF v_pd_m IS NULL THEN EXIT parse_to; END IF;
            v_pd_mo := v_pd_m[1]::INT; v_pd_d := v_pd_m[2]::INT; v_pd_y := v_pd_m[3]::INT;
        END IF;
        IF v_pd_mo < 1 OR v_pd_mo > 12 OR v_pd_d < 1 OR v_pd_d > 31 THEN EXIT parse_to; END IF;
        v_pd_base := make_timestamp(v_pd_y, v_pd_mo, 1, 0, 0, 0)
                    + make_interval(days => v_pd_d - 1)
                    + make_interval(hours => v_pd_hh, mins => v_pd_mi, secs => v_pd_ss);
        IF v_pd_tz IS NOT NULL AND v_pd_tz <> 'Z' THEN
            v_pd_tz := replace(v_pd_tz, ':', '');
            v_pd_base := v_pd_base - (CASE WHEN left(v_pd_tz, 1) = '-' THEN -1 ELSE 1 END)
                         * make_interval(hours => substr(v_pd_tz, 2, 2)::INT, mins => substr(v_pd_tz, 4, 2)::INT);
        END IF;
        v_to := v_pd_base::TIMESTAMP(3);
    END;

    IF v_type IS NOT NULL
       AND v_type NOT IN ('DIRECT_REFERRAL', 'PARENT_REFERRAL', 'ORIGINAL_OWNER') THEN
        RAISE EXCEPTION 'Failed to fetch points ledger';
    END IF;
    IF (NULLIF(p_from, '') IS NOT NULL AND v_from IS NULL)
       OR (NULLIF(p_to, '') IS NOT NULL AND v_to IS NULL) THEN
        RAISE EXCEPTION 'Failed to fetch points ledger';
    END IF;

    SELECT COUNT(*) INTO v_total
    FROM "referral".partner_points_ledger l
    WHERE (NULLIF(p_user_id, '') IS NULL OR l.beneficiary_user_id = p_user_id)
      AND (v_type IS NULL OR l.points_type = v_type::partner_points_type)
      AND (v_from IS NULL OR l.created_at >= v_from)
      AND (v_to   IS NULL OR l.created_at <= v_to);

    OPEN p_cursor FOR
    SELECT
        l.id,
        regexp_replace(COALESCE(b.first_name, '') || ' ' || COALESCE(b.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS beneficiary_name,
        b.email                                                                  AS beneficiary_email,
        regexp_replace(COALESCE(s.first_name, '') || ' ' || COALESCE(s.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS source_user_name,
        s.email                                                                  AS source_user_email,
        l.points_type,
        l.percentage_applied,
        l.transaction_amount,
        l.points_earned,
        l.status,
        l.created_at
    FROM "referral".partner_points_ledger l
    JOIN "user"."user" b ON b.id = l.beneficiary_user_id
    JOIN "user"."user" s ON s.id = l.source_user_id
    WHERE (NULLIF(p_user_id, '') IS NULL OR l.beneficiary_user_id = p_user_id)
      AND (v_type IS NULL OR l.points_type = v_type::partner_points_type)
      AND (v_from IS NULL OR l.created_at >= v_from)
      AND (v_to   IS NULL OR l.created_at <= v_to)
    ORDER BY l.created_at DESC, l.id
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS limit, v_total AS total;
END;
$$;

-- File: admin.sp_admin_points_summary.sql
CREATE OR REPLACE PROCEDURE admin.sp_admin_points_summary(
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT
        (SELECT COALESCE(SUM(points_earned), 0) FROM "referral".partner_points_ledger)        AS total_points_distributed,
        (SELECT COUNT(*) FROM "referral".partner_points_balance)                              AS total_partners,
        (SELECT COUNT(*) FROM "referral".partner_points_config WHERE is_active = TRUE)        AS partners_with_active_config,
        (SELECT COALESCE(SUM(total_points), 0) FROM "referral".partner_points_balance)        AS aggregate_total_earned,
        (SELECT COALESCE(SUM(current_points), 0) FROM "referral".partner_points_balance)      AS aggregate_current_balance;
END;
$$;

