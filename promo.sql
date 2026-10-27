-- Schema-wise stored procedures
-- Source: Procedure\promo\
CREATE SCHEMA IF NOT EXISTS "promo";

-- File: promo.sp_promo_admin_analytics.sql
CREATE OR REPLACE PROCEDURE promo.sp_promo_admin_analytics(
    INOUT p_summary refcursor DEFAULT 'summary_cursor',
    INOUT p_top     refcursor DEFAULT 'top_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_summary FOR
    SELECT
        (SELECT COUNT(*) FROM "catalog".promo_code)                                   AS total_promo_codes,
        (SELECT COUNT(*) FROM "catalog".promo_code WHERE is_active = TRUE)            AS active_promo_codes,
        (SELECT COUNT(*) FROM "catalog".promo_code_use)                               AS total_redemptions,
        (SELECT COALESCE(SUM(discount_applied), 0) FROM "catalog".promo_code_use)     AS total_discount_given;

    OPEN p_top FOR
    SELECT
        pc.code,
        (SELECT COUNT(*) FROM "catalog".promo_code_use pcu WHERE pcu.promo_code_id = pc.id) AS redemptions,
        pc.discount_type,
        pc.discount_value,
        pc.is_active
    FROM "catalog".promo_code pc
    ORDER BY pc.current_uses DESC
    LIMIT 10;
END;
$$;

-- File: promo.sp_promo_admin_create.sql
CREATE OR REPLACE PROCEDURE promo.sp_promo_admin_create(
    p_code              VARCHAR,
    p_discount_type     VARCHAR,
    p_discount_value    NUMERIC,
    p_valid_from        TEXT,
    p_valid_till        TEXT,
    p_description       VARCHAR DEFAULT NULL,
    p_min_order_amount  NUMERIC DEFAULT NULL,
    p_max_discount      NUMERIC DEFAULT NULL,
    p_max_uses          INT     DEFAULT NULL,
    p_max_uses_per_user INT     DEFAULT NULL,
    p_applicable_plans  JSONB   DEFAULT NULL,
    p_linked_user_id    VARCHAR DEFAULT NULL,
    p_created_by        VARCHAR DEFAULT NULL,
    p_preset_id         VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor',
    p_discount_value_sent BOOLEAN DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    v_code   TEXT;
    v_from   TIMESTAMP(3);
    v_till   TIMESTAMP(3);
    v_new_id TEXT := COALESCE(p_preset_id, 'c' || replace(gen_random_uuid()::text, '-', ''));
    _pd_s      TEXT;
    _pd_m      TEXT[];
    _pd_y      INT; _pd_mo INT; _pd_d INT;
    _pd_hh     INT; _pd_mi  INT; _pd_ss NUMERIC;
    _pd_tz     TEXT;
    _pd_base   TIMESTAMP;
    _pd_result TIMESTAMP(3);
BEGIN
    -- Node: `discount_value === undefined` → required. An explicit JSON null is NOT
    -- undefined, so Node continues and fails at `null <= 0`. Pass
    -- p_discount_value_sent = TRUE when the key was present in the body.
    IF NULLIF(p_code, '') IS NULL OR NULLIF(p_discount_type, '') IS NULL
       OR (p_discount_value IS NULL AND NOT COALESCE(p_discount_value_sent, FALSE))
       OR NULLIF(p_valid_from, '') IS NULL OR NULLIF(p_valid_till, '') IS NULL THEN
        RAISE EXCEPTION 'code, discount_type, discount_value, valid_from, valid_till are required';
    END IF;

    v_code := UPPER(regexp_replace(p_code, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));
    IF v_code !~ '^[A-Z0-9]{4,20}$' THEN
        RAISE EXCEPTION 'Code must be 4-20 alphanumeric characters';
    END IF;

    IF p_discount_type NOT IN ('PERCENTAGE', 'FLAT') THEN
        RAISE EXCEPTION 'discount_type must be PERCENTAGE or FLAT';
    END IF;

    IF COALESCE(p_discount_value, 0) <= 0 THEN          -- JS: null <= 0 is true
        RAISE EXCEPTION 'discount_value must be greater than 0';
    END IF;

    IF p_discount_type = 'PERCENTAGE' AND p_discount_value > 100 THEN
        RAISE EXCEPTION 'Percentage discount cannot exceed 100';
    END IF;

    -- new Date(valid_from) — keeps the timezone offset, stored as UTC like Prisma
    -- inline fn_js_parse_date(p_valid_from) → v_from
    _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
    _pd_s := regexp_replace(p_valid_from, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
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
    -- inline fn_js_parse_date(p_valid_till) → v_till
    _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
    _pd_s := regexp_replace(p_valid_till, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
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
    v_till := _pd_result;

    -- JS: an Invalid Date compares false, so Node goes on and Prisma rejects it at create
    IF v_from >= v_till THEN
        RAISE EXCEPTION 'valid_from must be before valid_till';
    END IF;

    IF NULLIF(p_linked_user_id, '') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_linked_user_id) THEN
        RAISE EXCEPTION 'Linked user not found';
    END IF;

    IF EXISTS (SELECT 1 FROM "catalog".promo_code WHERE code = v_code) THEN
        RAISE EXCEPTION 'Promo code already exists';
    END IF;

    IF v_from IS NULL THEN
        RAISE EXCEPTION 'Invalid value for argument `valid_from`: Provided Date object is invalid. Expected Date.';
    END IF;
    IF v_till IS NULL THEN
        RAISE EXCEPTION 'Invalid value for argument `valid_till`: Provided Date object is invalid. Expected Date.';
    END IF;

    INSERT INTO "catalog".promo_code
        (id, code, description, discount_type, discount_value,
         min_order_amount, max_discount, max_uses, max_uses_per_user,
         valid_from, valid_till, applicable_plans, is_active,
         created_by, linked_user_id, current_uses, created_at, updated_at)
    VALUES
        (v_new_id, v_code, NULLIF(p_description, ''), p_discount_type::promo_discount_type, p_discount_value,
         NULLIF(p_min_order_amount, 0), NULLIF(p_max_discount, 0), p_max_uses, COALESCE(p_max_uses_per_user, 1),
         v_from, v_till, NULLIF(p_applicable_plans, 'null'::jsonb), TRUE,
         p_created_by, NULLIF(p_linked_user_id, ''), 0, NOW(), NOW());

    OPEN p_cursor FOR
    SELECT id, code, discount_type, discount_value, is_active
    FROM "catalog".promo_code WHERE id = v_new_id;
END;
$$;

-- File: promo.sp_promo_admin_delete.sql
CREATE OR REPLACE PROCEDURE promo.sp_promo_admin_delete(
    p_id       VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "catalog".promo_code WHERE id = p_id) THEN
        RAISE EXCEPTION 'Promo code not found';
    END IF;

    UPDATE "catalog".promo_code
    SET is_active = FALSE, updated_at = NOW()
    WHERE id = p_id;

    OPEN p_cursor FOR
    SELECT id, code, is_active, 'Promo code ' || code || ' deactivated' AS message
    FROM "catalog".promo_code WHERE id = p_id;
END;
$$;

-- File: promo.sp_promo_admin_get_one.sql
CREATE OR REPLACE PROCEDURE promo.sp_promo_admin_get_one(
    p_id       VARCHAR,
    INOUT p_detail refcursor DEFAULT 'detail_cursor',
    INOUT p_uses   refcursor DEFAULT 'uses_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "catalog".promo_code WHERE id = p_id) THEN
        RAISE EXCEPTION 'Promo code not found';
    END IF;

    OPEN p_detail FOR
    SELECT
        pc.id,
        pc.code,
        pc.description,
        pc.discount_type,
        pc.discount_value,
        pc.min_order_amount                                                   AS min_order_amount,
        pc.max_discount                                                       AS max_discount,
        pc.max_uses,
        pc.max_uses_per_user,
        pc.current_uses,
        pc.valid_from,
        pc.valid_till,
        pc.applicable_plans,
        pc.is_active,
        pc.created_at,
        u.id                                                                 AS linked_user_id,
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS linked_user_name,
        u.email                                                              AS linked_user_email
    FROM "catalog".promo_code pc
    LEFT JOIN "user"."user" u ON u.id = pc.linked_user_id
    WHERE pc.id = p_id;

    OPEN p_uses FOR
    SELECT
        u.id                                                                 AS user_id,
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS name,
        u.email,
        pcu.discount_applied,
        pcu.used_at
    FROM "catalog".promo_code_use pcu
    JOIN "user"."user" u ON u.id = pcu.user_id
    WHERE pcu.promo_code_id = p_id
    ORDER BY pcu.used_at DESC
    LIMIT 50;
END;
$$;

-- File: promo.sp_promo_admin_get_usage.sql
CREATE OR REPLACE PROCEDURE promo.sp_promo_admin_get_usage(
    p_id    VARCHAR,
    p_page  INT DEFAULT 1,
    p_limit INT DEFAULT 20,
    INOUT p_cursor     refcursor DEFAULT 'result_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page  INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit INT := COALESCE(NULLIF(p_limit, 0), 20);
BEGIN
    OPEN p_cursor FOR
    SELECT
        u.id                                                                 AS user_id,
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS name,
        u.email,
        pcu.discount_applied,
        pcu.used_at
    FROM "catalog".promo_code_use pcu
    JOIN "user"."user" u ON u.id = pcu.user_id
    WHERE pcu.promo_code_id = p_id
    ORDER BY pcu.used_at DESC
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS limit, COUNT(*) AS total
    FROM "catalog".promo_code_use
    WHERE promo_code_id = p_id;
END;
$$;

-- File: promo.sp_promo_admin_list.sql
CREATE OR REPLACE PROCEDURE promo.sp_promo_admin_list(
    p_search    VARCHAR DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL,
    p_page      INT     DEFAULT 1,
    p_limit     INT     DEFAULT 20,
    INOUT p_cursor     refcursor DEFAULT 'result_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page  INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit INT := COALESCE(NULLIF(p_limit, 0), 20);
BEGIN
    OPEN p_cursor FOR
    SELECT
        pc.id,
        pc.code,
        pc.description,
        pc.discount_type,
        pc.discount_value,
        pc.min_order_amount                                                   AS min_order_amount,
        pc.max_discount                                                       AS max_discount,
        pc.max_uses,
        pc.max_uses_per_user,
        pc.current_uses,
        pc.valid_from,
        pc.valid_till,
        pc.is_active,
        pc.created_at,
        u.id                                                                 AS linked_user_id,
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS linked_user_name,
        u.email                                                              AS linked_user_email
    FROM "catalog".promo_code pc
    LEFT JOIN "user"."user" u ON u.id = pc.linked_user_id
    WHERE (NULLIF(p_search, '') IS NULL OR pc.code ILIKE '%' || replace(replace(replace(p_search, '\', '\\'), '%', '\%'), '_', '\_') || '%' ESCAPE '\')
      AND (p_is_active IS NULL OR pc.is_active = p_is_active)
    ORDER BY pc.created_at DESC
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS limit, COUNT(*) AS total
    FROM "catalog".promo_code pc
    WHERE (NULLIF(p_search, '') IS NULL OR pc.code ILIKE '%' || replace(replace(replace(p_search, '\', '\\'), '%', '\%'), '_', '\_') || '%' ESCAPE '\')
      AND (p_is_active IS NULL OR pc.is_active = p_is_active);
END;
$$;

-- File: promo.sp_promo_admin_update.sql
CREATE OR REPLACE PROCEDURE promo.sp_promo_admin_update(
    p_id   VARCHAR,
    p_data JSONB DEFAULT '{}'::jsonb,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    d        JSONB := COALESCE(p_data, '{}'::jsonb);
    v_linked TEXT  := NULLIF(d->>'linked_user_id', '');
    v_from   TIMESTAMP(3);
    v_till   TIMESTAMP(3);
    _pd_s      TEXT;
    _pd_m      TEXT[];
    _pd_y      INT; _pd_mo INT; _pd_d INT;
    _pd_hh     INT; _pd_mi  INT; _pd_ss NUMERIC;
    _pd_tz     TEXT;
    _pd_base   TIMESTAMP;
    _pd_result TIMESTAMP(3);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "catalog".promo_code WHERE id = p_id) THEN
        RAISE EXCEPTION 'Promo code not found';
    END IF;

    -- new Date(value): keeps the offset (→ UTC); new Date(null) = 1970-01-01
    IF d ? 'valid_from' THEN
        IF jsonb_typeof(d->'valid_from') = 'null' THEN
            v_from := TIMESTAMP '1970-01-01';
        ELSE
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(d->>'valid_from', E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
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
        END IF;
    END IF;
    IF d ? 'valid_till' THEN
        IF jsonb_typeof(d->'valid_till') = 'null' THEN
            v_till := TIMESTAMP '1970-01-01';
        ELSE
            _pd_hh := 0; _pd_mi := 0; _pd_ss := 0; _pd_tz := NULL; _pd_result := NULL;
            _pd_s := regexp_replace(d->>'valid_till', E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g');
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
            v_till := _pd_result;
        END IF;
    END IF;

    IF v_linked IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "user"."user" WHERE id = v_linked) THEN
        RAISE EXCEPTION 'Linked user not found';
    END IF;

    -- Invalid Date → Prisma rejects the update
    IF d ? 'valid_from' AND v_from IS NULL THEN
        RAISE EXCEPTION 'Invalid value for argument `valid_from`: Provided Date object is invalid. Expected Date.';
    END IF;
    IF d ? 'valid_till' AND v_till IS NULL THEN
        RAISE EXCEPTION 'Invalid value for argument `valid_till`: Provided Date object is invalid. Expected Date.';
    END IF;

    UPDATE "catalog".promo_code SET
        description       = CASE WHEN d ? 'description'       THEN d->>'description'                              ELSE description       END,
        discount_type     = CASE WHEN d ? 'discount_type'     THEN (d->>'discount_type')::promo_discount_type     ELSE discount_type     END,
        discount_value    = CASE WHEN d ? 'discount_value'    THEN (d->>'discount_value')::NUMERIC                ELSE discount_value    END,
        min_order_amount  = CASE WHEN d ? 'min_order_amount'  THEN (d->>'min_order_amount')::NUMERIC              ELSE min_order_amount  END,
        max_discount      = CASE WHEN d ? 'max_discount'      THEN (d->>'max_discount')::NUMERIC                  ELSE max_discount      END,
        max_uses          = CASE WHEN d ? 'max_uses'          THEN (d->>'max_uses')::INT                          ELSE max_uses          END,
        max_uses_per_user = CASE WHEN d ? 'max_uses_per_user' THEN (d->>'max_uses_per_user')::INT                 ELSE max_uses_per_user END,
        valid_from        = CASE WHEN d ? 'valid_from'        THEN v_from                                         ELSE valid_from        END,
        valid_till        = CASE WHEN d ? 'valid_till'        THEN v_till                                         ELSE valid_till        END,
        applicable_plans  = CASE WHEN d ? 'applicable_plans'  THEN NULLIF(d->'applicable_plans', 'null'::jsonb)   ELSE applicable_plans  END,
        is_active         = CASE WHEN d ? 'is_active'         THEN (d->>'is_active')::BOOLEAN                     ELSE is_active         END,
        linked_user_id    = CASE WHEN d ? 'linked_user_id'    THEN v_linked                                       ELSE linked_user_id    END,
        updated_at        = NOW()
    WHERE id = p_id;

    OPEN p_cursor FOR
    SELECT id, code, is_active
    FROM "catalog".promo_code WHERE id = p_id;
END;
$$;

-- File: promo.sp_promo_apply.sql
CREATE OR REPLACE PROCEDURE promo.sp_promo_apply(
    p_code            VARCHAR,
    p_subscription_id VARCHAR,
    p_user_id         VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_val        refcursor := 'promo_apply_validate';
    v_valid      BOOLEAN;
    v_reason     TEXT;
    v_promo_id   TEXT;
    v_code       TEXT;
    v_type       promo_discount_type;
    v_value      NUMERIC;
    v_min        NUMERIC;
    v_max        NUMERIC;
    v_discount   NUMERIC;
    v_final      NUMERIC;
BEGIN
    IF NULLIF(p_code, '') IS NULL OR NULLIF(p_subscription_id, '') IS NULL THEN
        RAISE EXCEPTION 'Please provide code and subscription_id';
    END IF;

    -- Node's `!code` lets "   " through; the lookup for "" then finds nothing
    IF regexp_replace(p_code, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') = '' THEN
        RAISE EXCEPTION 'Promo code does not exist';
    END IF;

    CALL promo.sp_promo_validate(p_code, p_user_id, p_subscription_id, v_val);
    FETCH v_val INTO v_valid, v_reason, v_promo_id, v_code, v_type, v_value, v_min, v_max, v_discount, v_final;
    CLOSE v_val;

    IF NOT v_valid THEN
        RAISE EXCEPTION '%', v_reason;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "payments".subscriptions WHERE id = p_subscription_id) THEN
        RAISE EXCEPTION 'Subscription plan not found';
    END IF;

    OPEN p_cursor FOR
    SELECT TRUE       AS applied,
           v_promo_id AS promo_id,
           v_type     AS discount_type,
           v_value    AS discount_value,
           v_discount AS calculated_discount,
           v_final    AS final_amount;
END;
$$;

-- File: promo.sp_promo_record_use.sql
CREATE OR REPLACE PROCEDURE promo.sp_promo_record_use(
    p_promo_id            VARCHAR,
    p_user_id             VARCHAR,
    p_discount_applied    NUMERIC,
    p_subscription_txn_id VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_new_id TEXT := 'c' || replace(gen_random_uuid()::text, '-', '');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "catalog".promo_code WHERE id = p_promo_id) THEN
        RAISE EXCEPTION 'Promo code not found';
    END IF;

    INSERT INTO "catalog".promo_code_use
        (id, promo_code_id, user_id, subscription_txn_id, discount_applied, used_at)
    VALUES
        (v_new_id, p_promo_id, p_user_id, p_subscription_txn_id, p_discount_applied, NOW());

    UPDATE "catalog".promo_code
    SET current_uses = current_uses + 1, updated_at = NOW()
    WHERE id = p_promo_id;

    OPEN p_cursor FOR
    SELECT pcu.id, pcu.promo_code_id, pcu.user_id, pcu.discount_applied, pcu.used_at, pc.current_uses
    FROM "catalog".promo_code_use pcu
    JOIN "catalog".promo_code pc ON pc.id = pcu.promo_code_id
    WHERE pcu.id = v_new_id;
END;
$$;

-- File: promo.sp_promo_validate.sql
CREATE OR REPLACE PROCEDURE promo.sp_promo_validate(
    p_code            VARCHAR,
    p_user_id         VARCHAR,
    p_subscription_id VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_code     TEXT := UPPER(regexp_replace(COALESCE(p_code, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));
    v_promo    "catalog".promo_code%ROWTYPE;
    v_min      NUMERIC;
    v_max_disc NUMERIC;
    v_price    NUMERIC;
    v_discount NUMERIC;
    v_final    NUMERIC;
    v_d        DOUBLE PRECISION;
    v_reason   TEXT;
BEGIN
    IF v_code = '' THEN
        RAISE EXCEPTION 'Please provide a promo code';
    END IF;

    SELECT * INTO v_promo FROM "catalog".promo_code WHERE code = v_code;

    IF NOT FOUND THEN
        v_reason := 'Promo code does not exist';
    ELSIF NOT v_promo.is_active THEN
        v_reason := 'Promo code is no longer active';
    ELSIF NOW() < v_promo.valid_from THEN
        v_reason := 'Promo code is not yet active';
    ELSIF NOW() > v_promo.valid_till THEN
        v_reason := 'Promo code has expired';
    ELSIF v_promo.max_uses IS NOT NULL AND v_promo.current_uses >= v_promo.max_uses THEN
        v_reason := 'Promo code has reached maximum uses';
    ELSIF (SELECT COUNT(*) FROM "catalog".promo_code_use
            WHERE promo_code_id = v_promo.id AND user_id = p_user_id) >= v_promo.max_uses_per_user THEN
        v_reason := 'You have already used this promo code';
    ELSIF NULLIF(p_subscription_id, '') IS NOT NULL
          AND jsonb_typeof(v_promo.applicable_plans) = 'array'
          AND NOT (v_promo.applicable_plans @> jsonb_build_array(p_subscription_id::text)) THEN
        v_reason := 'Promo code is not applicable to this plan';
    END IF;

    IF v_reason IS NOT NULL THEN
        OPEN p_cursor FOR
        SELECT FALSE AS valid, v_reason AS reason,
               NULL::TEXT AS promo_id, NULL::TEXT AS code, NULL::promo_discount_type AS discount_type,
               NULL::NUMERIC AS discount_value, NULL::NUMERIC AS min_order_amount, NULL::NUMERIC AS max_discount,
               NULL::NUMERIC AS calculated_discount, NULL::NUMERIC AS final_amount;
        RETURN;
    END IF;

    -- JS: promo.min_order_amount ? Number(...) : null  (0 counts as "not set")
    v_min      := NULLIF(v_promo.min_order_amount, 0);
    v_max_disc := NULLIF(v_promo.max_discount, 0);

    IF NULLIF(p_subscription_id, '') IS NOT NULL THEN
        SELECT price INTO v_price FROM "payments".subscriptions WHERE id = p_subscription_id;
    END IF;

    IF v_price IS NOT NULL THEN
        IF v_min IS NOT NULL AND v_price < v_min THEN
            OPEN p_cursor FOR
            SELECT FALSE AS valid, ('Minimum order amount is ' || trim_scale(v_min)::TEXT) AS reason,
                   NULL::TEXT AS promo_id, NULL::TEXT AS code, NULL::promo_discount_type AS discount_type,
                   NULL::NUMERIC AS discount_value, NULL::NUMERIC AS min_order_amount, NULL::NUMERIC AS max_discount,
                   NULL::NUMERIC AS calculated_discount, NULL::NUMERIC AS final_amount;
            RETURN;
        END IF;

        -- JS number (double) maths, exactly like promoService.calculateDiscount
        IF v_promo.discount_type = 'PERCENTAGE' THEN
            v_d := (v_price::DOUBLE PRECISION * v_promo.discount_value::DOUBLE PRECISION) / 100::DOUBLE PRECISION;
            IF v_max_disc IS NOT NULL AND v_d > v_max_disc::DOUBLE PRECISION THEN
                v_d := v_max_disc::DOUBLE PRECISION;
            END IF;
        ELSE
            v_d := v_promo.discount_value::DOUBLE PRECISION;
        END IF;

        IF v_d > v_price::DOUBLE PRECISION THEN
            v_d := v_price::DOUBLE PRECISION;
        END IF;

        -- Math.round(x * 100) / 100  (Math.round(v) = floor(v + 0.5))
        v_d        := floor(v_d * 100 + 0.5) / 100;
        v_discount := v_d::NUMERIC;
        v_final    := (floor((v_price::DOUBLE PRECISION - v_d) * 100 + 0.5) / 100)::NUMERIC;
    END IF;

    OPEN p_cursor FOR
    SELECT TRUE                         AS valid,
           NULL::TEXT                   AS reason,
           v_promo.id::TEXT             AS promo_id,
           v_promo.code::TEXT           AS code,
           v_promo.discount_type        AS discount_type,
           trim_scale(v_promo.discount_value) AS discount_value,
           trim_scale(v_min)            AS min_order_amount,
           trim_scale(v_max_disc)       AS max_discount,
           v_discount                   AS calculated_discount,
           v_final                      AS final_amount;
END;
$$;

