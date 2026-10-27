-- Schema-wise stored procedures
-- Source: Procedure\referral\
-- File: referral.sp_referral_admin_create_code.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_admin_create_code(
    p_user_id   VARCHAR,
    p_code      VARCHAR DEFAULT NULL,
    p_preset_id VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_code        TEXT;
    v_active_code TEXT;
    v_new_id      TEXT;
    v_gen         refcursor := 'ref_admin_generate';
    v_gen_code    TEXT;
BEGIN
    IF NULLIF(p_user_id, '') IS NULL THEN
        RAISE EXCEPTION 'user_id is required';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'User not found';
    END IF;

    SELECT referal_code INTO v_active_code
    FROM "referral".referral
    WHERE user_ref_id = p_user_id AND is_active = TRUE
    ORDER BY created_at
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'User already has an active referral code: %', v_active_code;
    END IF;

    IF NULLIF(p_code, '') IS NOT NULL THEN
        v_code := UPPER(regexp_replace(p_code, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));

        IF v_code !~ '^[A-Z0-9]{4,8}$' THEN
            RAISE EXCEPTION 'Referral code must be 4–8 alphanumeric characters';
        END IF;

        IF EXISTS (SELECT 1 FROM "referral".referral WHERE referal_code = v_code) THEN
            RAISE EXCEPTION 'Referral code already exists';
        END IF;

        v_new_id := COALESCE(p_preset_id, 'c' || replace(gen_random_uuid()::text, '-', ''));

        INSERT INTO "referral".referral
            (id, referal_code, is_active, user_ref_id, current_uses, created_at, updated_at)
        VALUES
            (v_new_id, v_code, TRUE, p_user_id, 0, NOW(), NOW());

        IF NOT EXISTS (SELECT 1 FROM "referral".partner_points_balance WHERE user_id = p_user_id) THEN
            INSERT INTO "referral".partner_points_balance
                (id, user_id, total_points, current_points, created_at, updated_at)
            VALUES
                ('c' || replace(gen_random_uuid()::text, '-', ''), p_user_id, 0, 0, NOW(), NOW());
        END IF;
    ELSE
        CALL referral.sp_referral_generate_code(p_user_id, p_preset_id, v_gen);
        FETCH v_gen INTO v_new_id, v_gen_code;
        CLOSE v_gen;
    END IF;

    OPEN p_cursor FOR
    SELECT id, referal_code AS code, is_active
    FROM "referral".referral WHERE id = v_new_id;
END;
$$;

-- File: referral.sp_referral_admin_get_analytics.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_admin_get_analytics(
    INOUT p_summary refcursor DEFAULT 'summary_cursor',
    INOUT p_earners refcursor DEFAULT 'earners_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_summary FOR
    SELECT
        (SELECT COUNT(*) FROM "referral".referral)                                    AS total_referral_codes,
        (SELECT COUNT(*) FROM "referral".referral WHERE is_active = TRUE)             AS total_active_codes,
        (SELECT COUNT(*) FROM "referral".referral_use)                                AS total_referral_uses,
        (SELECT COALESCE(SUM(points_earned), 0) FROM "referral".partner_points_ledger) AS total_points_distributed,
        (SELECT COUNT(*) FROM "referral".partner_points_config WHERE is_active = TRUE) AS partners_with_config;

    OPEN p_earners FOR
    SELECT
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS name,
        pb.total_points
    FROM "referral".partner_points_balance pb
    JOIN "user"."user" u ON u.id = pb.user_id
    WHERE pb.total_points > 0
    ORDER BY pb.total_points DESC
    LIMIT 10;
END;
$$;

-- File: referral.sp_referral_admin_get_code_usage.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_admin_get_code_usage(
    p_id       VARCHAR,
    INOUT p_detail refcursor DEFAULT 'detail_cursor',
    INOUT p_uses   refcursor DEFAULT 'uses_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "referral".referral WHERE id = p_id) THEN
        RAISE EXCEPTION 'Referral code not found';
    END IF;

    OPEN p_detail FOR
    SELECT
        r.referal_code                                                       AS code,
        u.id                                                                 AS owner_id,
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS owner_name,
        u.email                                                              AS owner_email,
        r.is_active,
        r.max_uses,
        r.current_uses
    FROM "referral".referral r
    JOIN "user"."user" u ON u.id = r.user_ref_id
    WHERE r.id = p_id;

    OPEN p_uses FOR
    SELECT
        u.id                                                                 AS user_id,
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS name,
        u.email,
        ru.created_at                                                        AS used_at
    FROM "referral".referral_use ru
    JOIN "user"."user" u ON u.id = ru.referred_user_id
    WHERE ru.referral_id = p_id
    ORDER BY ru.created_at DESC;
END;
$$;

-- File: referral.sp_referral_admin_get_tree_for_user.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_admin_get_tree_for_user(
    p_user_id  VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'User not found';
    END IF;

    OPEN p_cursor FOR
    WITH RECURSIVE tree AS (
        SELECT u.id AS user_id, NULL::VARCHAR AS referred_by,
               NULL::TIMESTAMP AS referred_on, 0 AS depth
        FROM "user"."user" u
        WHERE u.id = p_user_id

        UNION ALL

        SELECT ru.referred_user_id, ru.referrer_user_id, ru.created_at, t.depth + 1
        FROM tree t
        JOIN "referral".referral_use ru ON ru.referrer_user_id = t.user_id
        WHERE t.depth < 3
    )
    SELECT
        t.user_id,
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS name,
        u.email,
        ar.referal_code                         AS referral_code,
        COALESCE(ar.current_uses, 0)            AS total_uses,
        t.referred_by,
        t.referred_on,
        t.depth,
        pc.direct_referral_percent,
        pc.parent_referral_percent,
        pc.original_owner_percent,
        COALESCE(pb.total_points, 0)            AS total_points_earned
    FROM tree t
    JOIN "user"."user" u ON u.id = t.user_id
    LEFT JOIN LATERAL (
        SELECT r.referal_code, r.current_uses
        FROM "referral".referral r
        WHERE r.user_ref_id = t.user_id AND r.is_active = TRUE
        ORDER BY r.created_at
        LIMIT 1
    ) ar ON TRUE
    LEFT JOIN "referral".partner_points_config  pc ON pc.user_id = t.user_id
    LEFT JOIN "referral".partner_points_balance pb ON pb.user_id = t.user_id
    ORDER BY t.depth, t.referred_on DESC;
END;
$$;

-- File: referral.sp_referral_admin_get_tree_roots.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_admin_get_tree_roots(
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
        ar.referal_code                                                      AS referral_code,
        COALESCE(ar.current_uses, 0)                                         AS total_uses
    FROM "user"."user" u
    LEFT JOIN LATERAL (
        SELECT r.referal_code, r.current_uses
        FROM "referral".referral r
        WHERE r.user_ref_id = u.id AND r.is_active = TRUE
        ORDER BY r.created_at
        LIMIT 1
    ) ar ON TRUE
    WHERE EXISTS (SELECT 1 FROM "referral".referral r
                   WHERE r.user_ref_id = u.id AND r.is_active = TRUE AND r.current_uses > 0)
    ORDER BY u.created_at ASC
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS limit, COUNT(*) AS total
    FROM "user"."user" u
    WHERE EXISTS (SELECT 1 FROM "referral".referral r
                   WHERE r.user_ref_id = u.id AND r.is_active = TRUE AND r.current_uses > 0);
END;
$$;

-- File: referral.sp_referral_admin_list_codes.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_admin_list_codes(
    p_search    VARCHAR DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL,
    p_user_id   VARCHAR DEFAULT NULL,
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
        r.id,
        r.referal_code                                                       AS code,
        u.id                                                                 AS owner_id,
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS owner_name,
        u.email                                                              AS owner_email,
        r.is_active,
        r.max_uses,
        r.current_uses,
        r.created_at
    FROM "referral".referral r
    JOIN "user"."user" u ON u.id = r.user_ref_id
    WHERE (NULLIF(p_search, '') IS NULL OR r.referal_code ILIKE '%' || replace(replace(replace(p_search, '\', '\\'), '%', '\%'), '_', '\_') || '%' ESCAPE '\')
      AND (p_is_active IS NULL OR r.is_active = p_is_active)
      AND (NULLIF(p_user_id, '') IS NULL OR r.user_ref_id = p_user_id)
    ORDER BY r.created_at DESC
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS limit, COUNT(*) AS total
    FROM "referral".referral r
    JOIN "user"."user" u ON u.id = r.user_ref_id
    WHERE (NULLIF(p_search, '') IS NULL OR r.referal_code ILIKE '%' || replace(replace(replace(p_search, '\', '\\'), '%', '\%'), '_', '\_') || '%' ESCAPE '\')
      AND (p_is_active IS NULL OR r.is_active = p_is_active)
      AND (NULLIF(p_user_id, '') IS NULL OR r.user_ref_id = p_user_id);
END;
$$;

-- File: referral.sp_referral_admin_update_code.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_admin_update_code(
    p_id   VARCHAR,
    p_data JSONB DEFAULT '{}'::jsonb,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_data JSONB := COALESCE(p_data, '{}'::jsonb);
    v_code TEXT  := NULLIF(v_data->>'code', '');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "referral".referral WHERE id = p_id) THEN
        RAISE EXCEPTION 'Referral code not found';
    END IF;

    IF v_code IS NOT NULL THEN
        v_code := UPPER(regexp_replace(v_code, E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));
        IF v_code !~ '^[A-Z0-9]{4,8}$' THEN
            RAISE EXCEPTION 'Referral code must be 4–8 alphanumeric characters';
        END IF;
        IF EXISTS (SELECT 1 FROM "referral".referral WHERE referal_code = v_code AND id <> p_id) THEN
            RAISE EXCEPTION 'Referral code already exists';
        END IF;
    END IF;

    UPDATE "referral".referral
    SET is_active    = CASE WHEN v_data ? 'is_active' THEN (v_data->>'is_active')::BOOLEAN ELSE is_active END,
        max_uses     = CASE WHEN v_data ? 'max_uses'  THEN (v_data->>'max_uses')::INT      ELSE max_uses  END,
        referal_code = COALESCE(v_code, referal_code),
        updated_at   = NOW()
    WHERE id = p_id;

    OPEN p_cursor FOR
    SELECT id, referal_code AS code, is_active, max_uses, current_uses
    FROM "referral".referral WHERE id = p_id;
END;
$$;

-- File: referral.sp_referral_apply_code.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_apply_code(
    p_user_id  VARCHAR,
    p_code     VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_code          TEXT := UPPER(regexp_replace(COALESCE(p_code, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));
    v_val           refcursor := 'ref_apply_validate';
    v_gen           refcursor := 'ref_apply_generate';
    v_valid         BOOLEAN;
    v_reason        TEXT;
    v_masked        TEXT;
    v_referral_id   TEXT;
    v_referrer_id   TEXT;
    v_h_chain       JSONB;
    v_h_depth       INT;
    v_h_direct      TEXT;
    v_h_original    TEXT;
    v_has_hier      BOOLEAN;
    v_chain         JSONB;
    v_depth         INT;
    v_original      TEXT;
BEGIN
    IF v_code = '' THEN
        RAISE EXCEPTION 'Please provide a referral code';
    END IF;

    -- 1. Already used a code?
    IF EXISTS (SELECT 1 FROM "referral".referral_use WHERE referred_user_id = p_user_id) THEN
        RAISE EXCEPTION 'You have already used a referral code';
    END IF;

    -- 2. Validate (reuses SP #3)
    CALL referral.sp_referral_validate_code(v_code, v_val);
    FETCH v_val INTO v_valid, v_reason, v_masked, v_referral_id, v_referrer_id;
    CLOSE v_val;

    IF NOT v_valid THEN
        RAISE EXCEPTION '%', v_reason;
    END IF;

    -- 3. Self-referral
    IF v_referrer_id = p_user_id THEN
        RAISE EXCEPTION 'You cannot use your own referral code';
    END IF;

    -- Referrer's hierarchy (used for both circular check and new row)
    SELECT chain, depth, direct_referrer_id, original_code_owner_id
    INTO   v_h_chain, v_h_depth, v_h_direct, v_h_original
    FROM "referral".referral_hierarchy
    WHERE user_id = v_referrer_id;
    v_has_hier := FOUND;

    -- 4. Circular referral
    IF v_has_hier THEN
        IF (jsonb_typeof(v_h_chain) = 'array' AND v_h_chain @> jsonb_build_array(p_user_id::text))
           OR v_h_direct = p_user_id THEN
            RAISE EXCEPTION 'Circular referral detected — this code cannot be applied';
        END IF;
    END IF;

    -- 5. Build hierarchy info
    IF v_has_hier THEN
        v_original := COALESCE(v_h_original, v_referrer_id);
        v_depth    := v_h_depth + 1;
        v_chain    := CASE WHEN jsonb_typeof(v_h_chain) = 'array'
                           THEN v_h_chain || jsonb_build_array(v_referrer_id::text)
                           ELSE jsonb_build_array(v_referrer_id::text) END;
    ELSE
        v_original := v_referrer_id;
        v_depth    := 1;
        v_chain    := jsonb_build_array(v_referrer_id::text);
    END IF;

    -- 6. Writes
    INSERT INTO "referral".referral_use
        (id, referral_id, referred_user_id, referrer_user_id, created_at)
    VALUES
        ('c' || replace(gen_random_uuid()::text, '-', ''), v_referral_id, p_user_id, v_referrer_id, NOW());

    UPDATE "referral".referral
    SET current_uses = current_uses + 1, updated_at = NOW()
    WHERE referal_code = v_code;

    INSERT INTO "referral".referral_hierarchy
        (id, user_id, direct_referrer_id, original_code_owner_id, depth, chain, created_at, updated_at)
    VALUES
        ('c' || replace(gen_random_uuid()::text, '-', ''), p_user_id, v_referrer_id, v_original, v_depth, v_chain, NOW(), NOW());

    UPDATE "user"."user"
    SET referral = v_code, updated_at = NOW()
    WHERE id = p_user_id;

    -- 7. Auto-generate a code for the new user (non-critical, errors ignored)
    BEGIN
        CALL referral.sp_referral_generate_code(p_user_id, NULL, v_gen);
        CLOSE v_gen;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Auto-generate referral code failed for user: % %', p_user_id, SQLERRM;
    END;

    OPEN p_cursor FOR
    SELECT TRUE AS applied, v_masked AS referrer;
END;
$$;

-- File: referral.sp_referral_generate_code.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_generate_code(
    p_user_id   VARCHAR,
    p_preset_id VARCHAR DEFAULT NULL,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_name        TEXT;
    v_prefix      TEXT;
    v_code        TEXT;
    v_is_unique   BOOLEAN := FALSE;
    v_attempts    INT := 0;
    v_existing_id TEXT;
    v_new_id      TEXT;
BEGIN
    -- JS: user.first_name || user.username || "NUQI"  (empty string falls through)
    SELECT COALESCE(NULLIF(first_name, ''), NULLIF(username, ''), 'NUQI')
    INTO v_name
    FROM "user"."user"
    WHERE id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found';
    END IF;

    -- Already has an active code -> return it
    SELECT id INTO v_existing_id
    FROM "referral".referral
    WHERE user_ref_id = p_user_id AND is_active = TRUE
    ORDER BY created_at
    LIMIT 1;

    IF FOUND THEN
        OPEN p_cursor FOR
        SELECT id, referal_code AS code, is_active, current_uses, max_uses, created_at
        FROM "referral".referral WHERE id = v_existing_id;
        RETURN;
    END IF;

    -- Same as Node: uppercase, strip non A-Z, first 4 chars (may be empty)
    v_prefix := SUBSTRING(REGEXP_REPLACE(UPPER(v_name), '[^A-Z]', '', 'g'), 1, 4);

    WHILE NOT v_is_unique AND v_attempts < 10 LOOP
        v_code := v_prefix || UPPER(SUBSTRING(md5(random()::text || clock_timestamp()::text), 1, 4));
        IF NOT EXISTS (SELECT 1 FROM "referral".referral WHERE referal_code = v_code) THEN
            v_is_unique := TRUE;
        END IF;
        v_attempts := v_attempts + 1;
    END LOOP;

    IF NOT v_is_unique THEN
        RAISE EXCEPTION 'Failed to generate unique referral code after 10 attempts';
    END IF;

    v_new_id := COALESCE(p_preset_id, 'c' || replace(gen_random_uuid()::text, '-', ''));

    INSERT INTO "referral".referral
        (id, referal_code, is_active, user_ref_id, current_uses, created_at, updated_at)
    VALUES
        (v_new_id, v_code, TRUE, p_user_id, 0, NOW(), NOW());

    -- upsert partner_points_balance (update: {} -> do nothing if exists)
    IF NOT EXISTS (SELECT 1 FROM "referral".partner_points_balance WHERE user_id = p_user_id) THEN
        INSERT INTO "referral".partner_points_balance
            (id, user_id, total_points, current_points, created_at, updated_at)
        VALUES
            ('c' || replace(gen_random_uuid()::text, '-', ''), p_user_id, 0, 0, NOW(), NOW());
    END IF;

    OPEN p_cursor FOR
    SELECT id, referal_code AS code, is_active, current_uses, max_uses, created_at
    FROM "referral".referral WHERE id = v_new_id;
END;
$$;

-- File: referral.sp_referral_get_dashboard.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_get_dashboard(
    p_user_id  VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT
        rb.name                                        AS referred_by_name,
        rb.code_used                                   AS referred_by_code,
        (SELECT r.referal_code
           FROM "referral".referral r
          WHERE r.user_ref_id = p_user_id AND r.is_active = TRUE
          ORDER BY r.created_at DESC
          LIMIT 1)                                     AS my_referral_code,
        (SELECT COUNT(*)
           FROM "referral".referral_use
          WHERE referrer_user_id = p_user_id)          AS total_referrals,
        COALESCE(pb.total_points, 0)                   AS total_earned,
        COALESCE(pb.current_points, 0)                 AS current_balance
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (
        SELECT regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g') AS name,
               r.referal_code AS code_used
        FROM "referral".referral_use ru
        JOIN "user"."user" u       ON u.id = ru.referrer_user_id
        JOIN "referral".referral r ON r.id = ru.referral_id
        WHERE ru.referred_user_id = p_user_id
        LIMIT 1
    ) rb ON TRUE
    LEFT JOIN "referral".partner_points_balance pb ON pb.user_id = p_user_id;
END;
$$;

-- File: referral.sp_referral_get_my_codes.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_get_my_codes(
    p_user_id  VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
BEGIN
    OPEN p_cursor FOR
    SELECT
        id,
        referal_code AS code,
        is_active,
        current_uses,
        max_uses,
        created_at
    FROM "referral".referral
    WHERE user_ref_id = p_user_id
    ORDER BY created_at DESC;
END;
$$;

-- File: referral.sp_referral_get_my_referrals.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_get_my_referrals(
    p_user_id  VARCHAR,
    p_page     INT DEFAULT 1,
    p_limit    INT DEFAULT 10,
    INOUT p_cursor     refcursor DEFAULT 'result_cursor',
    INOUT p_pagination refcursor DEFAULT 'pagination_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_page  INT := COALESCE(NULLIF(p_page, 0), 1);
    v_limit INT := COALESCE(NULLIF(p_limit, 0), 10);
BEGIN
    OPEN p_cursor FOR
    SELECT
        u.id                                                                  AS user_id,
        regexp_replace(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g')  AS name,
        ru.created_at                                                         AS referred_on,
        (SELECT COUNT(*) FROM "referral".referral_use sub
          WHERE sub.referrer_user_id = u.id)                                  AS sub_referral_count
    FROM "referral".referral_use ru
    JOIN "user"."user" u ON u.id = ru.referred_user_id
    WHERE ru.referrer_user_id = p_user_id
    ORDER BY ru.created_at DESC
    LIMIT v_limit OFFSET (v_page - 1) * v_limit;

    OPEN p_pagination FOR
    SELECT v_page AS page, v_limit AS limit,
           (SELECT COUNT(*) FROM "referral".referral_use WHERE referrer_user_id = p_user_id) AS total;
END;
$$;

-- File: referral.sp_referral_update_code.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_update_code(
    p_user_id  VARCHAR,
    p_new_code VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_code           TEXT := UPPER(regexp_replace(COALESCE(p_new_code, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));
    v_existing_id    TEXT;
    v_existing_owner TEXT;
    v_active_id      TEXT;
BEGIN
    IF v_code = '' THEN
        RAISE EXCEPTION 'Please provide a new referral code';
    END IF;

    IF v_code !~ '^[A-Z0-9]{4,8}$' THEN
        RAISE EXCEPTION 'Referral code must be 4–8 alphanumeric characters';
    END IF;

    SELECT id, user_ref_id INTO v_existing_id, v_existing_owner
    FROM "referral".referral
    WHERE referal_code = v_code;

    IF FOUND AND v_existing_owner <> p_user_id THEN
        RAISE EXCEPTION 'Referral code already taken';
    END IF;

    IF FOUND THEN
        -- same as current code -> no-op
        OPEN p_cursor FOR
        SELECT id, referal_code AS code, is_active
        FROM "referral".referral WHERE id = v_existing_id;
        RETURN;
    END IF;

    SELECT id INTO v_active_id
    FROM "referral".referral
    WHERE user_ref_id = p_user_id AND is_active = TRUE
    ORDER BY created_at
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active referral code found to update';
    END IF;

    UPDATE "referral".referral
    SET referal_code = v_code, updated_at = NOW()
    WHERE id = v_active_id;

    OPEN p_cursor FOR
    SELECT id, referal_code AS code, is_active
    FROM "referral".referral WHERE id = v_active_id;
END;
$$;

-- File: referral.sp_referral_validate_code.sql
CREATE OR REPLACE PROCEDURE referral.sp_referral_validate_code(
    p_code     VARCHAR,
    INOUT p_cursor refcursor DEFAULT 'result_cursor'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_code         TEXT := UPPER(regexp_replace(COALESCE(p_code, ''), E'^[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+|[\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]+$', '', 'g'));
    v_referral_id  TEXT;
    v_is_active    BOOLEAN;
    v_current_uses INT;
    v_max_uses     INT;
    v_owner_id     TEXT;
    v_first_name   TEXT;
    v_masked       TEXT;
BEGIN
    IF v_code = '' THEN
        RAISE EXCEPTION 'Please provide a referral code';
    END IF;

    SELECT r.id, r.is_active, r.current_uses, r.max_uses, u.id, u.first_name
    INTO   v_referral_id, v_is_active, v_current_uses, v_max_uses, v_owner_id, v_first_name
    FROM "referral".referral r
    JOIN "user"."user" u ON u.id = r.user_ref_id
    WHERE r.referal_code = v_code;

    IF NOT FOUND THEN
        OPEN p_cursor FOR
        SELECT FALSE AS valid, 'Referral code does not exist'::TEXT AS reason,
               NULL::TEXT AS owner_name, NULL::TEXT AS referral_id, NULL::TEXT AS owner_id;
        RETURN;
    END IF;

    IF NOT v_is_active THEN
        OPEN p_cursor FOR
        SELECT FALSE AS valid, 'Referral code is no longer active'::TEXT AS reason,
               NULL::TEXT AS owner_name, NULL::TEXT AS referral_id, NULL::TEXT AS owner_id;
        RETURN;
    END IF;

    IF v_max_uses IS NOT NULL AND v_current_uses >= v_max_uses THEN
        OPEN p_cursor FOR
        SELECT FALSE AS valid, 'Referral code has reached maximum uses'::TEXT AS reason,
               NULL::TEXT AS owner_name, NULL::TEXT AS referral_id, NULL::TEXT AS owner_id;
        RETURN;
    END IF;

    v_first_name := COALESCE(NULLIF(v_first_name, ''), 'User');
    IF LENGTH(v_first_name) <= 2 THEN
        v_masked := LEFT(v_first_name, 1) || '***';
    ELSE
        v_masked := LEFT(v_first_name, 1) || '***' || RIGHT(v_first_name, 1);
    END IF;

    OPEN p_cursor FOR
    SELECT TRUE AS valid, NULL::TEXT AS reason,
           v_masked      AS owner_name,
           v_referral_id AS referral_id,
           v_owner_id    AS owner_id;
END;
$$;
