-- Schema-wise stored procedures
-- Source: Procedure\reverse_feed\
CREATE SCHEMA IF NOT EXISTS "reverse_feed";

-- File: reverse_feed.sp_reverse_feed_admin_approve_batch.sql
CREATE OR REPLACE PROCEDURE reverse_feed.sp_reverse_feed_admin_approve_batch(
    p_batch_id    VARCHAR,
    p_admin_id    VARCHAR DEFAULT NULL,
    p_admin_email VARCHAR DEFAULT NULL,
    p_admin_role  VARCHAR DEFAULT NULL,
    INOUT p_result        refcursor DEFAULT 'result_cursor',
    INOUT p_notifications refcursor DEFAULT 'notifications_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_prefix      TEXT := 'RF|' || COALESCE(p_batch_id, '') || '|';
    v_has_admin   BOOLEAN := (p_admin_id IS NOT NULL OR p_admin_email IS NOT NULL);
    v_count       INT;
    v_open_action TEXT;
    v_open_by     TEXT;
    v_reason      TEXT;
    v_req         TEXT;
    v_ids         INT[];
    -- for inline fn_pob_is_maker_only
    v_menu        JSONB;
    v_role        TEXT;
    v_profiles    JSONB;
    v_is_maker    BOOLEAN := FALSE;
    -- for inline fn_pob_admin_name / fn_js_trim
    v_admin_name  TEXT;
    v_ws_re       CONSTANT TEXT := E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$';
BEGIN
    SELECT COUNT(*) INTO v_count FROM "trade"."transaction" t
    WHERE LEFT(t.tag, LENGTH(v_prefix)) = v_prefix AND t.status = 'PENDING';
    IF v_count = 0 THEN
        RAISE EXCEPTION 'No pending reverse feed transactions found for this batch.';
    END IF;

    -- One open Maker request per batch (409 check, HTTP handlers only)
    IF v_has_admin THEN
        SELECT CASE WHEN ar."actionType" = 'REVERSE_FEED_BATCH_APPROVE' THEN 'approve' ELSE 'reject' END,
               ar."requestedByEmail"
        INTO v_open_action, v_open_by
        FROM "ops".approvalrequest ar
        WHERE ar.module = 'reverse-feed' AND ar.status = 'PENDING'
          AND ar."actionType" IN ('REVERSE_FEED_BATCH_APPROVE', 'REVERSE_FEED_BATCH_REJECT')
          AND ar."entityId" = p_batch_id
        ORDER BY ar."createdAt" LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'A request to % this batch is already awaiting Checker review (requested by %).', v_open_action, v_open_by;
        END IF;
    END IF;

    v_reason := 'Field: Batch Status — Approve (' || v_count || ' pending records)';

    -- ── Inline fn_pob_is_maker_only for module 'reverse-feed' ───
    v_is_maker := FALSE;
    IF p_admin_id IS NOT NULL THEN
        BEGIN
            SELECT CASE WHEN menu_access IS NULL OR jsonb_typeof(menu_access) = 'null'
                        THEN NULL ELSE menu_access END,
                   role::TEXT
            INTO v_menu, v_role
            FROM "ops".operations_user WHERE id = p_admin_id;
            IF NOT (v_menu IS NULL AND COALESCE(v_role, p_admin_role) IN ('SUPER_ADMIN', 'DEVELOPER')) THEN
                v_profiles := v_menu -> 'reverse-feed' -> 'profiles';
                v_is_maker := COALESCE(v_profiles ? 'Maker' AND NOT (v_profiles ? 'Checker'), FALSE);
            END IF;
        EXCEPTION WHEN OTHERS THEN v_is_maker := FALSE;
        END;
    END IF;

    -- ── Maker-only: stage ────────────────────────────────────────
    IF v_has_admin AND v_is_maker THEN
        v_req := 'c' || replace(gen_random_uuid()::text, '-', '');
        INSERT INTO "ops".approvalrequest
            (id, module, "actionType", "entityType", "entityId", payload, status,
             "requestedBy", "requestedByEmail", "createdAt")
        VALUES
            (v_req, 'reverse-feed', 'REVERSE_FEED_BATCH_APPROVE', 'ReverseFeedBatch', p_batch_id,
             '{}'::jsonb, 'PENDING', p_admin_id, p_admin_email, NOW());

        -- Inline fn_pob_write_audit (module label = 'Reverse Feed')
        BEGIN
            INSERT INTO "ops".audit_logs
                (module, "actionType", "entityType", "entityId", "statusBefore", "statusAfter",
                 "actionReason", "adminEmail", "adminName", success, metadata, "createdAt")
            VALUES ('Reverse Feed', 'Submitted for Approval', 'ApprovalRequest',
                    p_batch_id, 'PENDING', 'COMPLETED', v_reason,
                    p_admin_email, p_admin_email,
                    TRUE, jsonb_build_object('module', 'reverse-feed',
                                             'actionType', 'REVERSE_FEED_BATCH_APPROVE',
                                             'requestId', v_req), NOW());
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[ApprovalAudit] failed: %', SQLERRM;
        END;

        -- Inline fn_pob_notify_checkers(module_id='reverse-feed', route='/reverse-feed') [APPROVE]
        WITH _ins AS (
            INSERT INTO "ops".adminnotification
                (title, message, type, priority, is_read, admin_email, metadata, "createdAt", "updatedAt")
            SELECT 'Action Requires Review',
                   'Wants to approve reverse feed batch ' || p_batch_id
                       || ' (' || v_count || ' pending records)',
                   'APPROVAL_REQUEST', 'HIGH', FALSE, ou.email,
                   to_jsonb(jsonb_strip_nulls(jsonb_build_object(
                       'requestId',        v_req,
                       'module',           'reverse-feed',
                       'route',            '/reverse-feed',
                       'targetUserId',     NULL::TEXT,
                       'requestedByEmail', p_admin_email
                   ))::TEXT),
                   NOW(), NOW()
            FROM "ops".operations_user ou
            WHERE ou.is_active = TRUE AND ou.email IS DISTINCT FROM p_admin_email
              AND (
                    ((ou.menu_access IS NULL OR jsonb_typeof(ou.menu_access) = 'null')
                      AND ou.role::TEXT IN ('SUPER_ADMIN', 'DEVELOPER'))
                 OR ((ou.menu_access -> 'reverse-feed' -> 'enabled') IS DISTINCT FROM 'false'::jsonb
                      AND COALESCE(ou.menu_access -> 'reverse-feed' -> 'profiles' ? 'Checker', FALSE))
              )
            RETURNING id
        )
        SELECT COALESCE(ARRAY_AGG(id), ARRAY[]::INT[]) INTO v_ids FROM _ins;

        OPEN p_result FOR
        SELECT TRUE AS pending, 'Submitted for approval.'::TEXT AS message,
               p_batch_id AS batch_id, NULL::INT AS records_approved, v_req AS request_id;
        OPEN p_notifications FOR
        SELECT * FROM "ops".adminnotification WHERE id = ANY(v_ids) ORDER BY id;
        RETURN;
    END IF;

    -- ── Direct apply: PENDING → COMPLETED ───────────────────────
    UPDATE "trade"."transaction" t
    SET status = 'COMPLETED'::global_transaction_status, updated_at = NOW()
    WHERE LEFT(t.tag, LENGTH(v_prefix)) = v_prefix AND t.status = 'PENDING';
    GET DIAGNOSTICS v_count = ROW_COUNT;

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
            VALUES ('Reverse Feed', 'Batch Approved', 'ReverseFeedBatch',
                    p_batch_id, 'PENDING', 'COMPLETED', v_reason,
                    p_admin_email, COALESCE(v_admin_name, p_admin_email),
                    TRUE, jsonb_build_object('module', 'reverse-feed',
                                             'actionType', 'REVERSE_FEED_BATCH_APPROVE',
                                             'direct', TRUE), NOW());
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[ApprovalAudit] failed: %', SQLERRM;
        END;
    END IF;

    OPEN p_result FOR
    SELECT FALSE AS pending, NULL::TEXT AS message,
           p_batch_id AS batch_id, v_count AS records_approved, NULL::TEXT AS request_id;
    OPEN p_notifications FOR
    SELECT * FROM "ops".adminnotification WHERE FALSE;
END;
$$;

-- File: reverse_feed.sp_reverse_feed_admin_list_batches.sql
CREATE OR REPLACE PROCEDURE reverse_feed.sp_reverse_feed_admin_list_batches(
    p_page   INT     DEFAULT 1,
    p_limit  INT     DEFAULT 20,
    p_status VARCHAR DEFAULT NULL,
    INOUT p_data       refcursor DEFAULT 'data_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page  INT := GREATEST(1, COALESCE(p_page, 1));
    v_limit INT := LEAST(100, GREATEST(1, COALESCE(p_limit, 20)));
    v_total INT;
BEGIN
    IF NULLIF(p_status, '') IS NOT NULL
       AND NOT (p_status = ANY (enum_range(NULL::global_transaction_status)::TEXT[])) THEN
        RAISE EXCEPTION 'Failed to fetch batches';
    END IF;

    SELECT COUNT(DISTINCT t.tag) INTO v_total
    FROM "trade"."transaction" t
    WHERE LEFT(t.tag, 3) = 'RF|'
      AND (NULLIF(p_status, '') IS NULL OR t.status::TEXT = p_status);

    OPEN p_data FOR
    WITH batches AS (
        SELECT t.tag, COUNT(t.id) AS record_count, MIN(t.created_at) AS upload_date
        FROM "trade"."transaction" t
        WHERE LEFT(t.tag, 3) = 'RF|'
          AND (NULLIF(p_status, '') IS NULL OR t.status::TEXT = p_status)
        GROUP BY t.tag
        ORDER BY MIN(t.created_at) DESC, t.tag
        LIMIT v_limit OFFSET (v_page - 1) * v_limit
    )
    SELECT
        split_part(b.tag, '|', 2)                                                     AS batch_id,
        COALESCE(NULLIF(array_to_string((string_to_array(b.tag, '|'))[3:], '|'), ''), 'Unknown') AS file_name,
        b.upload_date,
        b.record_count,
        s.pending AS pending_count,
        CASE
            WHEN s.pending   > 0 THEN 'PENDING'
            WHEN s.cancelled > 0 THEN 'REJECTED'
            WHEN s.expired   > 0 THEN 'EXPIRED'
            ELSE 'APPROVED'
        END AS approval_status,
        (SELECT jsonb_build_object(
                    'action', CASE WHEN ar."actionType" = 'REVERSE_FEED_BATCH_APPROVE' THEN 'APPROVE' ELSE 'REJECT' END,
                    'requested_by', ar."requestedByEmail")
           FROM "ops".approvalrequest ar
          WHERE ar.module = 'reverse-feed' AND ar.status = 'PENDING'
            AND ar."actionType" IN ('REVERSE_FEED_BATCH_APPROVE', 'REVERSE_FEED_BATCH_REJECT')
            AND ar."entityId" = split_part(b.tag, '|', 2)
          ORDER BY ar."createdAt" DESC LIMIT 1) AS pending_checker_request
    FROM batches b
    CROSS JOIN LATERAL (
        SELECT COUNT(*) FILTER (WHERE x.status = 'PENDING')   AS pending,
               COUNT(*) FILTER (WHERE x.status = 'CANCELLED') AS cancelled,
               COUNT(*) FILTER (WHERE x.status = 'EXPIRED')   AS expired
        FROM "trade"."transaction" x WHERE x.tag = b.tag
    ) s
    ORDER BY b.upload_date DESC, b.tag;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS "totalPages";
END;
$$;

-- File: reverse_feed.sp_reverse_feed_admin_reject_batch.sql
CREATE OR REPLACE PROCEDURE reverse_feed.sp_reverse_feed_admin_reject_batch(
    p_batch_id    VARCHAR,
    p_admin_id    VARCHAR DEFAULT NULL,
    p_admin_email VARCHAR DEFAULT NULL,
    p_admin_role  VARCHAR DEFAULT NULL,
    INOUT p_result        refcursor DEFAULT 'result_cursor',
    INOUT p_notifications refcursor DEFAULT 'notifications_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_prefix      TEXT := 'RF|' || COALESCE(p_batch_id, '') || '|';
    v_has_admin   BOOLEAN := (p_admin_id IS NOT NULL OR p_admin_email IS NOT NULL);
    v_count       INT;
    v_open_action TEXT;
    v_open_by     TEXT;
    v_reason      TEXT;
    v_req         TEXT;
    v_ids         INT[];
    -- for inline fn_pob_is_maker_only
    v_menu        JSONB;
    v_role        TEXT;
    v_profiles    JSONB;
    v_is_maker    BOOLEAN := FALSE;
    -- for inline fn_pob_admin_name / fn_js_trim
    v_admin_name  TEXT;
    v_ws_re       CONSTANT TEXT := E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$';
BEGIN
    SELECT COUNT(*) INTO v_count FROM "trade"."transaction" t
    WHERE LEFT(t.tag, LENGTH(v_prefix)) = v_prefix AND t.status = 'PENDING';
    IF v_count = 0 THEN
        RAISE EXCEPTION 'No pending reverse feed transactions found for this batch.';
    END IF;

    -- One open Maker request per batch (409 check, HTTP handlers only)
    IF v_has_admin THEN
        SELECT CASE WHEN ar."actionType" = 'REVERSE_FEED_BATCH_APPROVE' THEN 'approve' ELSE 'reject' END,
               ar."requestedByEmail"
        INTO v_open_action, v_open_by
        FROM "ops".approvalrequest ar
        WHERE ar.module = 'reverse-feed' AND ar.status = 'PENDING'
          AND ar."actionType" IN ('REVERSE_FEED_BATCH_APPROVE', 'REVERSE_FEED_BATCH_REJECT')
          AND ar."entityId" = p_batch_id
        ORDER BY ar."createdAt" LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'A request to % this batch is already awaiting Checker review (requested by %).', v_open_action, v_open_by;
        END IF;
    END IF;

    v_reason := 'Field: Batch Status — Reject (' || v_count || ' pending records)';

    -- ── Inline fn_pob_is_maker_only for module 'reverse-feed' ───
    v_is_maker := FALSE;
    IF p_admin_id IS NOT NULL THEN
        BEGIN
            SELECT CASE WHEN menu_access IS NULL OR jsonb_typeof(menu_access) = 'null'
                        THEN NULL ELSE menu_access END,
                   role::TEXT
            INTO v_menu, v_role
            FROM "ops".operations_user WHERE id = p_admin_id;
            IF NOT (v_menu IS NULL AND COALESCE(v_role, p_admin_role) IN ('SUPER_ADMIN', 'DEVELOPER')) THEN
                v_profiles := v_menu -> 'reverse-feed' -> 'profiles';
                v_is_maker := COALESCE(v_profiles ? 'Maker' AND NOT (v_profiles ? 'Checker'), FALSE);
            END IF;
        EXCEPTION WHEN OTHERS THEN v_is_maker := FALSE;
        END;
    END IF;

    -- ── Maker-only: stage ────────────────────────────────────────
    IF v_has_admin AND v_is_maker THEN
        v_req := 'c' || replace(gen_random_uuid()::text, '-', '');
        INSERT INTO "ops".approvalrequest
            (id, module, "actionType", "entityType", "entityId", payload, status,
             "requestedBy", "requestedByEmail", "createdAt")
        VALUES
            (v_req, 'reverse-feed', 'REVERSE_FEED_BATCH_REJECT', 'ReverseFeedBatch', p_batch_id,
             '{}'::jsonb, 'PENDING', p_admin_id, p_admin_email, NOW());

        -- Inline fn_pob_write_audit
        BEGIN
            INSERT INTO "ops".audit_logs
                (module, "actionType", "entityType", "entityId", "statusBefore", "statusAfter",
                 "actionReason", "adminEmail", "adminName", success, metadata, "createdAt")
            VALUES ('Reverse Feed', 'Submitted for Approval', 'ApprovalRequest',
                    p_batch_id, 'PENDING', 'CANCELLED', v_reason,
                    p_admin_email, p_admin_email,
                    TRUE, jsonb_build_object('module', 'reverse-feed',
                                             'actionType', 'REVERSE_FEED_BATCH_REJECT',
                                             'requestId', v_req), NOW());
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[ApprovalAudit] failed: %', SQLERRM;
        END;

        -- Inline fn_pob_notify_checkers(module_id='reverse-feed', route='/reverse-feed') [REJECT]
        WITH _ins AS (
            INSERT INTO "ops".adminnotification
                (title, message, type, priority, is_read, admin_email, metadata, "createdAt", "updatedAt")
            SELECT 'Action Requires Review',
                   'Wants to reject reverse feed batch ' || p_batch_id
                       || ' (' || v_count || ' pending records)',
                   'APPROVAL_REQUEST', 'HIGH', FALSE, ou.email,
                   to_jsonb(jsonb_strip_nulls(jsonb_build_object(
                       'requestId',        v_req,
                       'module',           'reverse-feed',
                       'route',            '/reverse-feed',
                       'targetUserId',     NULL::TEXT,
                       'requestedByEmail', p_admin_email
                   ))::TEXT),
                   NOW(), NOW()
            FROM "ops".operations_user ou
            WHERE ou.is_active = TRUE AND ou.email IS DISTINCT FROM p_admin_email
              AND (
                    ((ou.menu_access IS NULL OR jsonb_typeof(ou.menu_access) = 'null')
                      AND ou.role::TEXT IN ('SUPER_ADMIN', 'DEVELOPER'))
                 OR ((ou.menu_access -> 'reverse-feed' -> 'enabled') IS DISTINCT FROM 'false'::jsonb
                      AND COALESCE(ou.menu_access -> 'reverse-feed' -> 'profiles' ? 'Checker', FALSE))
              )
            RETURNING id
        )
        SELECT COALESCE(ARRAY_AGG(id), ARRAY[]::INT[]) INTO v_ids FROM _ins;

        OPEN p_result FOR
        SELECT TRUE AS pending, 'Submitted for approval.'::TEXT AS message,
               p_batch_id AS batch_id, NULL::INT AS records_rejected, v_req AS request_id;
        OPEN p_notifications FOR
        SELECT * FROM "ops".adminnotification WHERE id = ANY(v_ids) ORDER BY id;
        RETURN;
    END IF;

    -- ── Direct apply: PENDING → CANCELLED ───────────────────────
    UPDATE "trade"."transaction" t
    SET status = 'CANCELLED'::global_transaction_status, updated_at = NOW()
    WHERE LEFT(t.tag, LENGTH(v_prefix)) = v_prefix AND t.status = 'PENDING';
    GET DIAGNOSTICS v_count = ROW_COUNT;

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
            VALUES ('Reverse Feed', 'Batch Rejected', 'ReverseFeedBatch',
                    p_batch_id, 'PENDING', 'CANCELLED', v_reason,
                    p_admin_email, COALESCE(v_admin_name, p_admin_email),
                    TRUE, jsonb_build_object('module', 'reverse-feed',
                                             'actionType', 'REVERSE_FEED_BATCH_REJECT',
                                             'direct', TRUE), NOW());
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[ApprovalAudit] failed: %', SQLERRM;
        END;
    END IF;

    OPEN p_result FOR
    SELECT FALSE AS pending, NULL::TEXT AS message,
           p_batch_id AS batch_id, v_count AS records_rejected, NULL::TEXT AS request_id;
    OPEN p_notifications FOR
    SELECT * FROM "ops".adminnotification WHERE FALSE;
END;
$$;

-- File: reverse_feed.sp_reverse_feed_confirm.sql
CREATE OR REPLACE PROCEDURE reverse_feed.sp_reverse_feed_confirm(
    p_partner_id VARCHAR,
    p_client_id  VARCHAR,
    p_tag        VARCHAR,
    p_rows       JSONB,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_user_id    TEXT;
    v_created    INT := 0;
    v_failed     INT := 0;
    v_errors     JSONB := '[]'::jsonb;
    r            RECORD;
    g            RECORD;
    v_parent_id  TEXT;
    v_total      NUMERIC;
    v_err        TEXT;
    v_fatal      BOOLEAN := FALSE;
    -- inline fn_js_trim
    v_ws_re      CONSTANT TEXT := E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$';
    -- inline fn_rf_insert_txn + fn_rf_generate_order_id vars
    v_txn_id     TEXT;
    v_ord_sfx    TEXT;
    v_ord_last   TEXT;
    v_ord_ser    BIGINT;
    v_ord_dig    TEXT;
    v_ord_try    TEXT;
    v_ord_ms     BIGINT;
    v_ord_b36    TEXT;
    v_ord_id     TEXT;
BEGIN
    IF p_client_id IS NULL OR p_client_id = '' THEN
        RAISE EXCEPTION 'Please select a client before uploading a Reverse Feed file.';
    END IF;

    SELECT linked_user_id INTO v_user_id
    FROM "referral".partner_client
    WHERE id = p_client_id AND partner_id = p_partner_id;

    IF NOT FOUND OR v_user_id IS NULL THEN
        RAISE EXCEPTION 'Selected client was not found or is not linked to a Nuqi Wealth account.';
    END IF;

    IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
        RAISE EXCEPTION 'No valid records to submit. All rows have validation errors.';
    END IF;

    -- Normalise every row once.
    -- Inline fn_rf_parse_float(v) as:
    --   CASE WHEN trim(v) ~ '^[+-]?Infinity' THEN (CASE WHEN left(trim(v),1)='-' THEN '-Infinity' ELSE 'Infinity' END)::NUMERIC
    --        ELSE (regexp_match(trim(v), '^([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)'))[1]::NUMERIC END
    -- where trim(v) = regexp_replace(v, v_ws_re, '', 'g')
    CREATE TEMP TABLE IF NOT EXISTS tmp_rf_rows (
        ord INT, row_no INT, asset TEXT, txn_type TEXT, scripcode TEXT, trading_symbol TEXT,
        basket_id TEXT, basket_name TEXT, multiplier NUMERIC,
        quantity NUMERIC, filled NUMERIC, avg_cep NUMERIC, avg_other NUMERIC,
        txn_date TEXT, description TEXT, provider TEXT, broker_client_id TEXT
    ) ON COMMIT DROP;
    DELETE FROM tmp_rf_rows;

    INSERT INTO tmp_rf_rows
    SELECT
        e.ord, (e.v ->> 'row')::INT, e.v ->> 'asset', e.v ->> 'txn_type',
        e.v ->> 'scripcode', NULLIF(e.v ->> 'trading_symbol', ''),
        e.v ->> 'basket_id', e.v ->> 'basket_name',
        -- inline fn_rf_parse_float for multiplier
        pf.mult,
        -- inline fn_rf_parse_float for quantities / prices
        COALESCE(pf.oq, 0),
        COALESCE(pf.eq_, 0),
        COALESCE(pf.eap, 0),
        COALESCE(NULLIF(pf.eap, 0), NULLIF(pf.na, 0), NULLIF(pf.ga, 0), 0),
        -- inline fn_js_trim for date / text fields
        NULLIF(regexp_replace(COALESCE(
            NULLIF(e.v ->> 'order_datetime', ''),
            NULLIF(e.v ->> 'trade_datetime', ''),
            NULLIF(e.v ->> 'trade_date', ''), ''), v_ws_re, '', 'g'), ''),
        NULLIF(regexp_replace(COALESCE(e.v ->> 'remarks', ''), v_ws_re, '', 'g'), ''),
        NULLIF(UPPER(regexp_replace(COALESCE(e.v ->> 'broker_name', ''), v_ws_re, '', 'g')), ''),
        NULLIF(regexp_replace(COALESCE(e.v ->> 'broker_client_id', ''), v_ws_re, '', 'g'), '')
    FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS e(v, ord)
    -- inline fn_rf_parse_float for all numeric fields in one LATERAL
    CROSS JOIN LATERAL (
        SELECT
            (SELECT CASE WHEN t ~ '^[+-]?Infinity'
                         THEN (CASE WHEN left(t,1)='-' THEN '-Infinity' ELSE 'Infinity' END)::NUMERIC
                         ELSE (regexp_match(t, '^([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)'))[1]::NUMERIC
                    END
             FROM (SELECT regexp_replace(COALESCE(e.v->>'multiplier',''), v_ws_re,'','g') AS t) _) AS mult,
            (SELECT CASE WHEN t ~ '^[+-]?Infinity'
                         THEN (CASE WHEN left(t,1)='-' THEN '-Infinity' ELSE 'Infinity' END)::NUMERIC
                         ELSE (regexp_match(t, '^([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)'))[1]::NUMERIC
                    END
             FROM (SELECT regexp_replace(COALESCE(e.v->>'ordered_quantity',''), v_ws_re,'','g') AS t) _) AS oq,
            (SELECT CASE WHEN t ~ '^[+-]?Infinity'
                         THEN (CASE WHEN left(t,1)='-' THEN '-Infinity' ELSE 'Infinity' END)::NUMERIC
                         ELSE (regexp_match(t, '^([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)'))[1]::NUMERIC
                    END
             FROM (SELECT regexp_replace(COALESCE(e.v->>'executed_quantity',''), v_ws_re,'','g') AS t) _) AS eq_,
            (SELECT CASE WHEN t ~ '^[+-]?Infinity'
                         THEN (CASE WHEN left(t,1)='-' THEN '-Infinity' ELSE 'Infinity' END)::NUMERIC
                         ELSE (regexp_match(t, '^([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)'))[1]::NUMERIC
                    END
             FROM (SELECT regexp_replace(COALESCE(e.v->>'executed_avg_price',''), v_ws_re,'','g') AS t) _) AS eap,
            (SELECT CASE WHEN t ~ '^[+-]?Infinity'
                         THEN (CASE WHEN left(t,1)='-' THEN '-Infinity' ELSE 'Infinity' END)::NUMERIC
                         ELSE (regexp_match(t, '^([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)'))[1]::NUMERIC
                    END
             FROM (SELECT regexp_replace(COALESCE(e.v->>'net_amount',''), v_ws_re,'','g') AS t) _) AS na,
            (SELECT CASE WHEN t ~ '^[+-]?Infinity'
                         THEN (CASE WHEN left(t,1)='-' THEN '-Infinity' ELSE 'Infinity' END)::NUMERIC
                         ELSE (regexp_match(t, '^([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)'))[1]::NUMERIC
                    END
             FROM (SELECT regexp_replace(COALESCE(e.v->>'gross_amount',''), v_ws_re,'','g') AS t) _) AS ga
    ) pf;

    -- 1. EQUITY / ETF — one transaction per row, file order.
    FOR r IN SELECT * FROM tmp_rf_rows WHERE asset <> 'CEP' ORDER BY ord LOOP
        BEGIN
            -- Inline fn_rf_generate_order_id(v_user_id)
            v_ord_sfx := CASE WHEN COALESCE(v_user_id, '') = '' THEN '00' ELSE RIGHT(v_user_id, 2) END;
            v_ord_ser := 1; v_ord_b36 := ''; v_ord_id := NULL;
            SELECT order_id INTO v_ord_last FROM "trade"."transaction"
            WHERE order_id LIKE 'OD%'
            ORDER BY created_at DESC, SUBSTRING(order_id FROM 5) DESC LIMIT 1;
            IF v_ord_last IS NOT NULL AND LENGTH(v_ord_last) = 12 THEN
                v_ord_dig := (regexp_match(SUBSTRING(v_ord_last FROM 5), '^\s*([+-]?\d+)'))[1];
                IF v_ord_dig IS NOT NULL THEN v_ord_ser := v_ord_dig::BIGINT + 1; END IF;
            END IF;
            FOR i IN 0..4 LOOP
                v_ord_try := 'OD' || v_ord_sfx || LPAD((v_ord_ser + i)::TEXT, 8, '0');
                IF NOT EXISTS (SELECT 1 FROM "trade"."transaction" WHERE order_id = v_ord_try) THEN
                    v_ord_id := v_ord_try; EXIT;
                END IF;
            END LOOP;
            IF v_ord_id IS NULL THEN
                v_ord_ms := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT;
                WHILE v_ord_ms > 0 LOOP
                    v_ord_b36 := SUBSTRING('0123456789abcdefghijklmnopqrstuvwxyz' FROM (v_ord_ms % 36)::INT + 1 FOR 1) || v_ord_b36;
                    v_ord_ms  := v_ord_ms / 36;
                END LOOP;
                v_ord_id := LEFT('OD' || v_ord_sfx || v_ord_b36 || SUBSTRING(md5(random()::TEXT) FOR 4), 12);
            END IF;
            -- Inline fn_rf_insert_txn
            v_txn_id := 'c' || replace(gen_random_uuid()::text, '-', '');
            INSERT INTO "trade"."transaction"
                (id, order_id, status, scripcode, tag, account_id, trading_symbol, user_ref_id,
                 average_price, asset, filled_quantity, quantity, pending_quantity, cancelled_quantity,
                 transaction_date, parent_transaction_id, cep_ref_id, description, is_expired,
                 platform, provider, broker_client_id, trade_platform, created_at, updated_at, transaction_type)
            VALUES
                (v_txn_id, v_ord_id, 'COMPLETED', r.scripcode, p_tag, v_user_id, r.trading_symbol, v_user_id,
                 r.avg_other, r.asset, r.filled, r.quantity, 0, 0,
                 r.txn_date, NULL, NULL, r.description, FALSE,
                 'WEB', r.provider, r.broker_client_id, 'Other',
                 (clock_timestamp() AT TIME ZONE 'UTC')::TIMESTAMP(3),
                 (clock_timestamp() AT TIME ZONE 'UTC')::TIMESTAMP(3),
                 r.txn_type::order_direction_type);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Confirm reverse feed error: %', SQLERRM;
            v_fatal := TRUE;
        END;
        EXIT WHEN v_fatal;
        v_created := v_created + 1;
    END LOOP;

    IF v_fatal THEN
        OPEN p_cursor FOR
        SELECT FALSE AS success, 'Failed to process reverse feed file'::TEXT AS error_message,
               split_part(p_tag, '|', 2) AS batch_id,
               NULLIF(array_to_string((string_to_array(p_tag, '|'))[3:], '|'), '') AS file_name,
               jsonb_array_length(p_rows) AS total_rows,
               v_created AS records_created, v_failed AS records_failed, '[]'::jsonb AS errors;
        RETURN;
    END IF;

    -- 2. CEP — one parent per (basket, BUY/SELL) group, one child per row.
    FOR g IN
        SELECT basket_id, txn_type, MIN(ord) AS first_ord,
               (ARRAY_AGG(basket_name ORDER BY ord))[1] AS basket_name,
               (ARRAY_AGG(row_no ORDER BY ord))[1]      AS first_row,
               COALESCE(NULLIF((ARRAY_AGG(ROUND(multiplier) ORDER BY ord))[1], 0), 1) AS multiplier,
               COUNT(*) AS children,
               CASE WHEN COUNT(DISTINCT txn_date)         = 1 THEN MAX(txn_date)         END AS txn_date,
               CASE WHEN COUNT(DISTINCT description)      = 1 THEN MAX(description)      END AS description,
               CASE WHEN COUNT(DISTINCT provider)         = 1 THEN MAX(provider)         END AS provider,
               CASE WHEN COUNT(DISTINCT broker_client_id) = 1 THEN MAX(broker_client_id) END AS broker_client_id
        FROM tmp_rf_rows WHERE asset = 'CEP'
        GROUP BY basket_id, txn_type
        ORDER BY MIN(ord)
    LOOP
        v_err := NULL;
        BEGIN
            -- Inline fn_rf_generate_order_id for CEP parent
            v_ord_sfx := CASE WHEN COALESCE(v_user_id, '') = '' THEN '00' ELSE RIGHT(v_user_id, 2) END;
            v_ord_ser := 1; v_ord_b36 := ''; v_ord_id := NULL;
            SELECT order_id INTO v_ord_last FROM "trade"."transaction"
            WHERE order_id LIKE 'OD%'
            ORDER BY created_at DESC, SUBSTRING(order_id FROM 5) DESC LIMIT 1;
            IF v_ord_last IS NOT NULL AND LENGTH(v_ord_last) = 12 THEN
                v_ord_dig := (regexp_match(SUBSTRING(v_ord_last FROM 5), '^\s*([+-]?\d+)'))[1];
                IF v_ord_dig IS NOT NULL THEN v_ord_ser := v_ord_dig::BIGINT + 1; END IF;
            END IF;
            FOR i IN 0..4 LOOP
                v_ord_try := 'OD' || v_ord_sfx || LPAD((v_ord_ser + i)::TEXT, 8, '0');
                IF NOT EXISTS (SELECT 1 FROM "trade"."transaction" WHERE order_id = v_ord_try) THEN
                    v_ord_id := v_ord_try; EXIT;
                END IF;
            END LOOP;
            IF v_ord_id IS NULL THEN
                v_ord_ms := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT;
                WHILE v_ord_ms > 0 LOOP
                    v_ord_b36 := SUBSTRING('0123456789abcdefghijklmnopqrstuvwxyz' FROM (v_ord_ms % 36)::INT + 1 FOR 1) || v_ord_b36;
                    v_ord_ms  := v_ord_ms / 36;
                END LOOP;
                v_ord_id := LEFT('OD' || v_ord_sfx || v_ord_b36 || SUBSTRING(md5(random()::TEXT) FOR 4), 12);
            END IF;
            -- Inline fn_rf_insert_txn for CEP parent (returns id via v_parent_id)
            v_parent_id := 'c' || replace(gen_random_uuid()::text, '-', '');
            INSERT INTO "trade"."transaction"
                (id, order_id, status, scripcode, tag, account_id, trading_symbol, user_ref_id,
                 average_price, asset, filled_quantity, quantity, pending_quantity, cancelled_quantity,
                 transaction_date, parent_transaction_id, cep_ref_id, description, is_expired,
                 platform, provider, broker_client_id, trade_platform, created_at, updated_at, transaction_type)
            VALUES
                (v_parent_id, v_ord_id, 'COMPLETED', g.basket_name, p_tag, v_user_id, NULL, v_user_id,
                 0, 'CEP', g.multiplier, g.multiplier, 0, 0,
                 g.txn_date, NULL, g.basket_id, g.description, FALSE,
                 'WEB', g.provider, g.broker_client_id, 'Other',
                 (clock_timestamp() AT TIME ZONE 'UTC')::TIMESTAMP(3),
                 (clock_timestamp() AT TIME ZONE 'UTC')::TIMESTAMP(3),
                 g.txn_type::order_direction_type);
        EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
        END;

        IF v_err IS NULL THEN
            v_total := 0;
            FOR r IN SELECT * FROM tmp_rf_rows
                     WHERE asset = 'CEP' AND basket_id IS NOT DISTINCT FROM g.basket_id AND txn_type = g.txn_type
                     ORDER BY ord LOOP
                BEGIN
                    -- Inline fn_rf_generate_order_id for CEP child
                    v_ord_sfx := CASE WHEN COALESCE(v_user_id, '') = '' THEN '00' ELSE RIGHT(v_user_id, 2) END;
                    v_ord_ser := 1; v_ord_b36 := ''; v_ord_id := NULL;
                    SELECT order_id INTO v_ord_last FROM "trade"."transaction"
                    WHERE order_id LIKE 'OD%'
                    ORDER BY created_at DESC, SUBSTRING(order_id FROM 5) DESC LIMIT 1;
                    IF v_ord_last IS NOT NULL AND LENGTH(v_ord_last) = 12 THEN
                        v_ord_dig := (regexp_match(SUBSTRING(v_ord_last FROM 5), '^\s*([+-]?\d+)'))[1];
                        IF v_ord_dig IS NOT NULL THEN v_ord_ser := v_ord_dig::BIGINT + 1; END IF;
                    END IF;
                    FOR i IN 0..4 LOOP
                        v_ord_try := 'OD' || v_ord_sfx || LPAD((v_ord_ser + i)::TEXT, 8, '0');
                        IF NOT EXISTS (SELECT 1 FROM "trade"."transaction" WHERE order_id = v_ord_try) THEN
                            v_ord_id := v_ord_try; EXIT;
                        END IF;
                    END LOOP;
                    IF v_ord_id IS NULL THEN
                        v_ord_ms := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT;
                        WHILE v_ord_ms > 0 LOOP
                            v_ord_b36 := SUBSTRING('0123456789abcdefghijklmnopqrstuvwxyz' FROM (v_ord_ms % 36)::INT + 1 FOR 1) || v_ord_b36;
                            v_ord_ms  := v_ord_ms / 36;
                        END LOOP;
                        v_ord_id := LEFT('OD' || v_ord_sfx || v_ord_b36 || SUBSTRING(md5(random()::TEXT) FOR 4), 12);
                    END IF;
                    -- Inline fn_rf_insert_txn for CEP child
                    v_txn_id := 'c' || replace(gen_random_uuid()::text, '-', '');
                    INSERT INTO "trade"."transaction"
                        (id, order_id, status, scripcode, tag, account_id, trading_symbol, user_ref_id,
                         average_price, asset, filled_quantity, quantity, pending_quantity, cancelled_quantity,
                         transaction_date, parent_transaction_id, cep_ref_id, description, is_expired,
                         platform, provider, broker_client_id, trade_platform, created_at, updated_at, transaction_type)
                    VALUES
                        (v_txn_id, v_ord_id, 'COMPLETED', r.scripcode, p_tag, v_user_id, r.trading_symbol, v_user_id,
                         r.avg_cep, 'CEP', r.filled, r.quantity, 0, 0,
                         r.txn_date, v_parent_id, g.basket_id, r.description, FALSE,
                         'WEB', r.provider, r.broker_client_id, 'Other',
                         (clock_timestamp() AT TIME ZONE 'UTC')::TIMESTAMP(3),
                         (clock_timestamp() AT TIME ZONE 'UTC')::TIMESTAMP(3),
                         g.txn_type::order_direction_type);
                EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
                END;
                EXIT WHEN v_err IS NOT NULL;
                v_total := v_total + r.filled * r.avg_cep;
            END LOOP;
        END IF;

        IF v_err IS NULL THEN
            BEGIN
                UPDATE "trade"."transaction"
                SET average_price = v_total,
                    updated_at = (clock_timestamp() AT TIME ZONE 'UTC')::TIMESTAMP(3)
                WHERE id = v_parent_id;
            EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
            END;
        END IF;

        IF v_err IS NULL THEN
            v_created := v_created + 1 + g.children;
        ELSE
            v_failed := v_failed + g.children;
            v_errors := v_errors || jsonb_build_array(jsonb_build_object(
                'row', g.first_row,
                'message', 'Failed to create CEP transactions for basket "' || COALESCE(g.basket_name, '') || '": ' || v_err));
        END IF;
    END LOOP;

    OPEN p_cursor FOR
    SELECT TRUE AS success, NULL::TEXT AS error_message,
           split_part(p_tag, '|', 2) AS batch_id,
           NULLIF(array_to_string((string_to_array(p_tag, '|'))[3:], '|'), '') AS file_name,
           jsonb_array_length(p_rows) AS total_rows,
           v_created AS records_created,
           v_failed  AS records_failed,
           (SELECT COALESCE(jsonb_agg(e), '[]'::jsonb)
              FROM (SELECT e FROM jsonb_array_elements(v_errors) e LIMIT 50) s) AS errors;
END;
$$;

-- File: reverse_feed.sp_reverse_feed_get_records.sql
CREATE OR REPLACE PROCEDURE reverse_feed.sp_reverse_feed_get_records(
    p_partner_id VARCHAR,
    p_batch_id   VARCHAR,
    p_page       INT DEFAULT 1,
    p_limit      INT DEFAULT 20,
    INOUT p_data       refcursor DEFAULT 'data_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_prefix TEXT := 'RF|' || COALESCE(p_batch_id, '') || '|';
    v_page   INT  := GREATEST(1, COALESCE(p_page, 1));
    v_limit  INT  := LEAST(100, GREATEST(1, COALESCE(p_limit, 20)));
    v_total  INT;
BEGIN
    SELECT COUNT(*) INTO v_total
    FROM "trade"."transaction" WHERE LEFT(tag, LENGTH(v_prefix)) = v_prefix;

    OPEN p_data FOR
    SELECT
        t.id,
        COALESCE(
            (SELECT pc.name FROM "referral".partner_client pc
              WHERE (p_partner_id IS NULL OR pc.partner_id = p_partner_id)
                AND pc.linked_user_id = t.user_ref_id AND COALESCE(pc.name, '') <> ''
              ORDER BY pc.created_at DESC, pc.id DESC LIMIT 1),
            NULLIF(CONCAT_WS(' ', NULLIF(u.first_name, ''), NULLIF(u.last_name, '')), ''),
            'N/A')                                                        AS client_name,
        COALESCE(u.id, 'N/A')                                             AS client_code,
        COALESCE(
            (SELECT k."panNumber" FROM "kyc".kyc k
              WHERE k."userId" = t.user_ref_id AND COALESCE(k."panNumber", '') <> ''
              ORDER BY k."createdAt" DESC LIMIT 1),
            'N/A')                                                        AS client_pan,
        COALESCE(NULLIF(t.asset, ''), 'EQUITY')                           AS segment,
        t.scripcode                                                       AS stock_name,
        COALESCE(NULLIF(t.trading_symbol, ''), t.scripcode)               AS trading_symbol,
        t.transaction_type,
        t.status                                                          AS order_status,
        t.transaction_date                                                AS trade_date,
        t.quantity                                                        AS ordered_quantity,
        t.filled_quantity                                                 AS executed_quantity,
        t.average_price                                                   AS executed_avg_price,
        t.provider                                                        AS broker_name,
        t.description                                                     AS remarks,
        t.created_at
    FROM "trade"."transaction" t
    LEFT JOIN "user"."user" u ON u.id = t.user_ref_id
    WHERE LEFT(t.tag, LENGTH(v_prefix)) = v_prefix
    ORDER BY t.created_at DESC, t.id
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS "totalPages";
END;
$$;

-- File: reverse_feed.sp_reverse_feed_list_files.sql
CREATE OR REPLACE PROCEDURE reverse_feed.sp_reverse_feed_list_files(
    p_partner_id VARCHAR,
    p_page       INT DEFAULT 1,
    p_limit      INT DEFAULT 20,
    INOUT p_data       refcursor DEFAULT 'data_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page  INT := GREATEST(1, COALESCE(p_page, 1));
    v_limit INT := LEAST(100, GREATEST(1, COALESCE(p_limit, 20)));
    v_total INT;
BEGIN
    SELECT COUNT(DISTINCT t.tag) INTO v_total
    FROM "trade"."transaction" t
    WHERE LEFT(t.tag, 3) = 'RF|'
      AND t.user_ref_id IN (SELECT linked_user_id FROM "referral".partner_client
                            WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL);

    OPEN p_data FOR
    WITH batches AS (
        SELECT t.tag, COUNT(t.id) AS record_count, MIN(t.created_at) AS upload_date
        FROM "trade"."transaction" t
        WHERE LEFT(t.tag, 3) = 'RF|'
          AND t.user_ref_id IN (SELECT linked_user_id FROM "referral".partner_client
                                WHERE partner_id = p_partner_id AND linked_user_id IS NOT NULL)
        GROUP BY t.tag
        ORDER BY MIN(t.created_at) DESC, t.tag
        LIMIT v_limit OFFSET (v_page - 1) * v_limit
    )
    SELECT
        split_part(b.tag, '|', 2)                                                     AS batch_id,
        COALESCE(NULLIF(array_to_string((string_to_array(b.tag, '|'))[3:], '|'), ''), 'Unknown') AS file_name,
        b.upload_date,
        b.record_count,
        CASE
            WHEN s.pending   > 0 THEN 'PENDING'
            WHEN s.cancelled > 0 THEN 'REJECTED'
            WHEN s.expired   > 0 THEN 'EXPIRED'
            ELSE 'APPROVED'
        END AS approval_status
    FROM batches b
    CROSS JOIN LATERAL (
        SELECT COUNT(*) FILTER (WHERE x.status = 'PENDING')   AS pending,
               COUNT(*) FILTER (WHERE x.status = 'CANCELLED') AS cancelled,
               COUNT(*) FILTER (WHERE x.status = 'EXPIRED')   AS expired
        FROM "trade"."transaction" x WHERE x.tag = b.tag
    ) s
    ORDER BY b.upload_date DESC, b.tag;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS "limit", v_total AS total,
           CEIL(v_total::NUMERIC / v_limit)::INT AS "totalPages";
END;
$$;

-- File: reverse_feed.sp_reverse_feed_validate_client.sql
CREATE OR REPLACE PROCEDURE reverse_feed.sp_reverse_feed_validate_client(
    p_partner_id VARCHAR,
    p_client_id  VARCHAR,
    p_rows       JSONB,
    INOUT p_client     refcursor DEFAULT 'client_cursor',
    INOUT p_mismatches refcursor DEFAULT 'mismatch_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_client_name TEXT;
    v_user_id     TEXT;
    v_pan         TEXT;
    v_name        TEXT;
    v_mismatch    INT;
    -- inline fn_js_trim whitespace regex
    v_ws_re       CONSTANT TEXT := E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$';
BEGIN
    -- 1-2. resolveExpectedClient
    IF p_client_id IS NULL OR p_client_id = '' THEN
        RAISE EXCEPTION 'Please select a client before uploading a Reverse Feed file.';
    END IF;

    SELECT name, linked_user_id INTO v_client_name, v_user_id
    FROM "referral".partner_client
    WHERE id = p_client_id AND partner_id = p_partner_id;

    IF NOT FOUND OR v_user_id IS NULL THEN
        RAISE EXCEPTION 'Selected client was not found or is not linked to a Nuqi Wealth account.';
    END IF;

    -- 3-4. file shape
    IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
        RAISE EXCEPTION 'File is empty or has no data rows';
    END IF;
    IF NOT (p_rows -> 0 ? 'transaction_type') THEN
        RAISE EXCEPTION 'File is missing required columns: transaction_type';
    END IF;

    -- 5a. Canonical PAN
    SELECT UPPER(k."panNumber") INTO v_pan
    FROM "kyc".kyc k
    WHERE k."userId" = v_user_id AND COALESCE(k."panNumber", '') <> ''
    ORDER BY k."createdAt" DESC LIMIT 1;

    IF v_pan IS NULL THEN
        SELECT UPPER(pc.pan_number) INTO v_pan
        FROM "referral".partner_client pc
        WHERE pc.partner_id = p_partner_id AND pc.linked_user_id = v_user_id
          AND COALESCE(pc.pan_number, '') <> ''
        ORDER BY pc.created_at DESC, pc.id DESC LIMIT 1;
    END IF;

    -- 5b. Canonical name
    WITH named AS (
        SELECT UPPER(pc.name) AS n, pc.linked_user_id AS u,
               ROW_NUMBER() OVER (ORDER BY pc.created_at, pc.id) AS rn
        FROM "referral".partner_client pc
        WHERE pc.partner_id = p_partner_id AND pc.linked_user_id IS NOT NULL AND COALESCE(pc.name, '') <> ''
    ), owners AS (
        SELECT DISTINCT ON (n) n, u, MIN(rn) OVER (PARTITION BY n) AS first_rn
        FROM named ORDER BY n, rn DESC
    )
    SELECT n INTO v_name FROM owners WHERE u = v_user_id ORDER BY first_rn LIMIT 1;

    -- 5c. Per-row identity check (inline fn_js_trim via v_ws_re)
    CREATE TEMP TABLE IF NOT EXISTS tmp_rf_mismatch (row_no INT, message TEXT) ON COMMIT DROP;
    DELETE FROM tmp_rf_mismatch;

    INSERT INTO tmp_rf_mismatch (row_no, message)
    SELECT r.ord + 1,
           'Row''s ' || array_to_string(ARRAY_REMOVE(ARRAY[
               CASE WHEN x.pan  <> '' AND v_pan  IS NOT NULL AND x.pan  <> v_pan        THEN 'PAN "'  || x.pan  || '"' END,
               CASE WHEN x.code <> '' AND x.code <> UPPER(v_user_id)                    THEN 'Code "' || x.code || '"' END,
               CASE WHEN x.name <> '' AND v_name IS NOT NULL AND x.name <> v_name       THEN 'Name "' || x.name || '"' END
           ], NULL), ', ') || ' does not match the client selected on the upload screen.'
    FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS r(val, ord)
    CROSS JOIN LATERAL (
        SELECT UPPER(regexp_replace(COALESCE(r.val ->> 'client_pan',  ''), v_ws_re, '', 'g')) AS pan,
               UPPER(regexp_replace(COALESCE(r.val ->> 'client_code', ''), v_ws_re, '', 'g')) AS code,
               UPPER(regexp_replace(COALESCE(r.val ->> 'client_name', ''), v_ws_re, '', 'g')) AS name
    ) x
    WHERE (x.pan  <> '' AND v_pan  IS NOT NULL AND x.pan  <> v_pan)
       OR (x.code <> '' AND x.code <> UPPER(v_user_id))
       OR (x.name <> '' AND v_name IS NOT NULL AND x.name <> v_name);

    SELECT COUNT(*) INTO v_mismatch FROM tmp_rf_mismatch;

    OPEN p_client FOR
    SELECT p_client_id AS client_id, v_client_name AS client_name, v_user_id AS linked_user_id,
           v_pan AS canonical_pan, v_name AS canonical_name,
           jsonb_array_length(p_rows) AS total_rows, v_mismatch AS mismatch_count,
           CASE WHEN v_mismatch > 0 THEN
               'Upload rejected: ' || v_mismatch || ' row(s) belong to a different client than the selected client ("'
               || v_client_name || '"). Every row in the file must belong to the same selected client.'
           END AS rejection_message;

    OPEN p_mismatches FOR
    SELECT row_no AS "row", message FROM tmp_rf_mismatch ORDER BY row_no;
END;
$$;

