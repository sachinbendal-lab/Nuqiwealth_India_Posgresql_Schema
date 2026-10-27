-- Schema-wise stored procedures
-- Source: Procedure\catalog\

-- File: catalog.sp_add_risk_profile_data.sql
CREATE OR REPLACE PROCEDURE catalog.sp_add_risk_profile_data(
    OUT data JSON
)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO catalog.riskprofilescoregrid (
        id, risk_level, min_score, max_score, description, created_at, updated_at
    ) 
    VALUES 
    (md5(random()::text || clock_timestamp()::text), 'Conservative', 8, 19, 'You are an investor who is prepared to accept lower returns with lower levels of risk in order to preserve your capital.', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    (md5(random()::text || clock_timestamp()::text), 'Balanced', 20, 29, 'You are an investor who would like to invest in both income and growth assets. You will be comfortable with calculated risks to achieve good returns.', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    (md5(random()::text || clock_timestamp()::text), 'Growth', 30, 39, 'You are an investor who is comfortable with high volatility and a high level of risk in order to achieve higher returns over the long term. Your objective is to accumulate assets over the long term by primarily investing in growth assets.', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    (md5(random()::text || clock_timestamp()::text), 'Aggressive', 40, 100, 'You are an investor who is comfortable with a higher level of risk in order to achieve potentially higher returns. Capital security is secondary to potential wealth accumulation.', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    ON CONFLICT (risk_level) 
    DO UPDATE SET 
        min_score = EXCLUDED.min_score, 
        max_score = EXCLUDED.max_score, 
        description = EXCLUDED.description, 
        updated_at = CURRENT_TIMESTAMP;

    data := json_build_object('message', 'Risk profile data added/updated successfully.');
END;
$$;

-- File: catalog.sp_generate_risk_profile.sql
CREATE OR REPLACE PROCEDURE catalog.sp_generate_risk_profile(
    OUT data JSON
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_question JSON;
    v_answer JSON;
    v_question_id VARCHAR(191);
    v_questions JSON := '[
      {"question":"Which of these scenarios best describes your ''Risk Range''? What level of losses and profits would you be comfortable with?","answers":[{"answer":"Investment A (Worst Year: 1%, Best Year: 15%)","score":0},{"answer":"Investment B (Worst Year: -5%, Best Year: 20%)","score":1},{"answer":"Investment C (Worst Year: -10%, Best Year: 25%)","score":2},{"answer":"Investment D (Worst Year: -15%, Best Year: 30%)","score":3},{"answer":"Investment E (Worst Year: -18%, Best Year: 35%)","score":4},{"answer":"Investment F (Worst Year: -20%, Best Year: 40%)","score":5}]},
      {"question":"Would you be interested in investing in US, UK, Europe, Middle East, and other global equity markets?","answers":[{"answer":"Yes","score":1},{"answer":"No","score":0}]},
      {"question":"Would you be interested in investing in Sukuks of the world''s leading corporates?","answers":[{"answer":"Yes","score":1},{"answer":"No","score":0}]},
      {"question":"Would you be interested in investing in gold as an alternate currency?","answers":[{"answer":"Yes","score":1},{"answer":"No","score":0}]}
    ]'::json;
BEGIN
    -- 1. Lock the tables to prevent concurrent insert race conditions
    LOCK TABLE catalog.riskprofilequestions IN SHARE ROW EXCLUSIVE MODE;
    LOCK TABLE catalog.riskprofileanswer IN SHARE ROW EXCLUSIVE MODE;

    FOR v_question IN
        SELECT value FROM json_array_elements(v_questions) AS questions(value)
    LOOP
        -- 2. Safe check: Look up if the question text already exists
        SELECT id INTO v_question_id 
        FROM catalog.riskprofilequestions 
        WHERE question = v_question->>'question';

        -- 3. If it does not exist, generate an ID and insert it cleanly
        IF v_question_id IS NULL THEN
            v_question_id := md5(random()::text || clock_timestamp()::text);
            
            INSERT INTO catalog.riskprofilequestions (id, question, created_at, updated_at)
            VALUES (v_question_id, v_question->>'question', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
        END IF;

        -- 4. Loop through options and check for duplicates before inserting
        FOR v_answer IN
            SELECT value FROM json_array_elements(v_question->'answers') AS answers(value)
        LOOP
            IF NOT EXISTS (
                SELECT 1
                FROM catalog.riskprofileanswer
                WHERE question_id = v_question_id
                  AND answer = v_answer->>'answer'
                  AND score = (v_answer->>'score')::INTEGER
            ) THEN
                INSERT INTO catalog.riskprofileanswer (
                    id, answer, score, question_id, created_at, updated_at
                ) VALUES (
                    md5(random()::text || clock_timestamp()::text),
                    v_answer->>'answer',
                    (v_answer->>'score')::INTEGER,
                    v_question_id,
                    CURRENT_TIMESTAMP,
                    CURRENT_TIMESTAMP
                );
            END IF;
        END LOOP;
    END LOOP;

    data := json_build_object('message', 'Risk profile generated successfully');
END;
$$;

-- CALL catalog.sp_generate_risk_profile(NULL);

-- File: catalog.sp_get_master_risk_profile.sql
CREATE OR REPLACE PROCEDURE catalog.sp_get_master_risk_profile(
    OUT data JSON
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_profiles JSON;
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM catalog.riskprofilequestions;
    SELECT COALESCE(json_agg(question_row ORDER BY question_row->>'question'), '[]'::json)
      INTO v_profiles
      FROM (
        SELECT json_build_object(
            'id', q.id,
            'question', q.question,
            'created_at', q.created_at,
            'updated_at', q.updated_at,
            'options', '[]'::json,
            'answers', COALESCE((
                SELECT json_agg(json_build_object(
                    'id', a.id,
                    'answer', a.answer,
                    'score', a.score,
                    'question_id', a.question_id,
                    'created_at', a.created_at,
                    'updated_at', a.updated_at
                ) ORDER BY a.created_at, a.id)
                  FROM catalog.riskprofileanswer a
                 WHERE a.question_id = q.id
            ), '[]'::json)
        ) AS question_row
          FROM catalog.riskprofilequestions q
      ) AS questions;

    data := json_build_object(
        'message', 'Risk profiles fetched successfully',
        'risk_profiles', v_profiles,
        'length', v_count
    );
END;
$$;
-- CALL catalog.sp_get_master_risk_profile(NULL);

-- File: catalog.sp_get_risk_level.sql
CREATE OR REPLACE PROCEDURE catalog.sp_get_risk_level(
    IN p_user_id VARCHAR(191),
    OUT data JSON
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_profile catalog.userriskprofile%ROWTYPE;
    v_grid catalog.riskprofilescoregrid%ROWTYPE;
BEGIN
    SELECT * INTO v_profile
      FROM catalog.userriskprofile
     WHERE user_id = p_user_id
     LIMIT 1;
    IF NOT FOUND THEN
        data := NULL;
        RETURN;
    END IF;

    SELECT * INTO v_grid
      FROM catalog.riskprofilescoregrid
     WHERE id = v_profile.risk_profile_id;

    data := json_build_object(
        'message', 'Risk level fetched successfully',
        'risk_level', json_build_object(
        'id', v_profile.id,
        'user_id', v_profile.user_id,
        'total_score', v_profile.total_score,
        'risk_profile_id', v_profile.risk_profile_id,
        'reason', v_profile.reason,
        'answers', v_profile.answers,
        'created_at', v_profile.created_at,
        'updated_at', v_profile.updated_at,
        'is_active', v_profile.is_active,
        'is_checked', v_profile.is_checked,
        'is_override', v_profile.is_override,
        'risk_level', json_build_object(
            'id', v_grid.id,
            'risk_level', v_grid.risk_level,
            'min_score', v_grid.min_score,
            'max_score', v_grid.max_score,
            'description', v_grid.description
        )
        )
    );
END;
$$;
-- CALL catalog.sp_get_risk_level('NUQI00000001', NULL);

-- File: catalog.sp_get_risk_profile_possible_jumps.sql
CREATE OR REPLACE PROCEDURE catalog.sp_get_risk_profile_possible_jumps(
    IN p_user_id VARCHAR(191),
    OUT data JSON
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_profile catalog.userriskprofile%ROWTYPE;
    v_current_grid catalog.riskprofilescoregrid%ROWTYPE;
    v_lower JSONB := '[]'::jsonb;
    v_upper JSONB := '[]'::jsonb;
    v_result JSONB := '[]'::jsonb;
BEGIN
    SELECT * INTO v_profile
      FROM catalog.userriskprofile
     WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existing risk profile found for the user';
    END IF;

    SELECT * INTO v_current_grid
      FROM catalog.riskprofilescoregrid
     WHERE id = v_profile.risk_profile_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid risk level associated with the user profile';
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', id, 'name', risk_level, 'description', description
           ) ORDER BY min_score), '[]'::jsonb)
      INTO v_lower
      FROM catalog.riskprofilescoregrid
     WHERE min_score < v_current_grid.min_score;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', id, 'name', risk_level, 'description', description
           ) ORDER BY min_score), '[]'::jsonb)
      INTO v_upper
      FROM catalog.riskprofilescoregrid
     WHERE min_score > v_current_grid.min_score;

    IF v_profile.is_override THEN
        v_result := v_lower;
    ELSIF jsonb_array_length(v_upper) > 0 THEN
        v_result := jsonb_build_array(v_upper->0) || v_lower;
    ELSE
        v_result := v_lower;
    END IF;

    data := json_build_object(
        'message', 'Possible risk profile jumps fetched successfully',
        'data', v_result,
        'total_score', v_profile.total_score
    );
END;
$$;
-- CALL catalog.sp_get_risk_profile_possible_jumps('NUQI00000001', NULL);

-- File: catalog.sp_get_risk_profiles.sql
CREATE OR REPLACE PROCEDURE catalog.sp_get_risk_profiles(
    OUT data JSON
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_profiles JSON;
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM catalog.riskprofilequestions;
    SELECT COALESCE(json_agg(profile_row ORDER BY profile_row->>'index'), '[]'::json)
      INTO v_profiles
      FROM (
        SELECT json_build_object(
            'id', q.id,
            'index', row_number() OVER (ORDER BY q.created_at, q.id),
            'question', q.question,
            'answers', COALESCE((
                SELECT json_agg(json_build_object(
                    'id', a.id,
                    'label', a.answer,
                    'score', a.score
                ) ORDER BY a.created_at, a.id)
                  FROM catalog.riskprofileanswer a
                 WHERE a.question_id = q.id
            ), '[]'::json)
        ) AS profile_row
          FROM catalog.riskprofilequestions q
      ) AS profiles;

    data := json_build_object(
        'message', 'Risk profiles fetched successfully',
        'risk_profiles', v_profiles,
        'length', v_count
    );
END;
$$;
-- CALL catalog.sp_get_risk_profiles(NULL);

-- File: catalog.sp_get_risk_score.sql
CREATE OR REPLACE PROCEDURE catalog.sp_get_risk_score(
    IN p_user_id VARCHAR(191),
    IN p_answers JSON,
    IN p_score INTEGER,
    OUT data JSON
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_user RECORD;
    v_grid catalog.riskprofilescoregrid%ROWTYPE;
    v_profile catalog.userriskprofile%ROWTYPE;
BEGIN
    IF p_answers IS NULL OR json_typeof(p_answers) <> 'array' THEN
        RAISE EXCEPTION 'Answers must be provided as an array';
    END IF;
    IF p_score IS NULL OR p_score = 0 OR p_score < 0 OR p_score > 100 THEN
        RAISE EXCEPTION 'Score should be between 1 and 100';
    END IF;

    SELECT id, email, first_name, is_risk_verified
      INTO v_user
      FROM "user"."user"
     WHERE id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User is unauthorized';
    END IF;

    SELECT * INTO v_grid
      FROM catalog.riskprofilescoregrid
     WHERE min_score <= p_score AND max_score >= p_score
     ORDER BY min_score
     LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Risk profile not found';
    END IF;

    INSERT INTO catalog.userriskprofile (
        id, user_id, total_score, risk_profile_id, answers,
        created_at, updated_at, is_override
    ) VALUES (
        md5(random()::text || clock_timestamp()::text), p_user_id, p_score,
        v_grid.id, p_answers::text, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, FALSE
    )
    ON CONFLICT (user_id) DO UPDATE SET
        risk_profile_id = EXCLUDED.risk_profile_id,
        total_score = EXCLUDED.total_score,
        answers = EXCLUDED.answers,
        updated_at = CURRENT_TIMESTAMP
    RETURNING * INTO v_profile;

    UPDATE "user"."user"
       SET is_risk_verified = TRUE
     WHERE id = p_user_id;

    data := json_build_object(
        'message', 'Risk score calculated successfully',
        'score', json_build_object(
        'id', v_profile.id,
        'user_id', v_profile.user_id,
        'total_score', v_profile.total_score,
        'risk_profile_id', v_profile.risk_profile_id,
        'reason', v_profile.reason,
        'answers', v_profile.answers,
        'created_at', v_profile.created_at,
        'updated_at', v_profile.updated_at,
        'is_active', v_profile.is_active,
        'is_checked', v_profile.is_checked,
        'is_override', v_profile.is_override,
        'risk_level', json_build_object(
            'id', v_grid.id,
            'risk_level', v_grid.risk_level,
            'min_score', v_grid.min_score,
            'max_score', v_grid.max_score,
            'description', v_grid.description
        )
        )
    );
END;
$$;
-- CALL catalog.sp_get_risk_score('<USER_ID>', '[{"question_id":"<QUESTION_ID>","answer_id":"<ANSWER_ID>"}]'::json, 20, NULL);

-- File: catalog.sp_update_user_risk_profile.sql
CREATE OR REPLACE PROCEDURE catalog.sp_update_user_risk_profile(
	IN p_user_id character varying,
	IN p_risk_profile_id character varying,
	OUT data json)
LANGUAGE 'plpgsql'
AS $BODY$
DECLARE
    v_profile catalog.userriskprofile%ROWTYPE;
    v_current_grid catalog.riskprofilescoregrid%ROWTYPE;
    v_new_grid catalog.riskprofilescoregrid%ROWTYPE;
    v_risk_order TEXT[] := ARRAY['Conservative', 'Balanced', 'Growth', 'Aggressive'];
    v_current_index INTEGER;
    v_new_index INTEGER;
BEGIN
    SELECT * INTO v_profile
      FROM catalog.userriskprofile
     WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User risk profile not found';
    END IF;

    SELECT * INTO v_current_grid
      FROM catalog.riskprofilescoregrid
     WHERE id = v_profile.risk_profile_id;
    SELECT * INTO v_new_grid
      FROM catalog.riskprofilescoregrid
     WHERE id = p_risk_profile_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'The specified risk profile does not exist';
    END IF;

    v_current_index := array_position(v_risk_order, v_current_grid.risk_level);
    v_new_index := array_position(v_risk_order, v_new_grid.risk_level);
    IF v_current_index IS NULL OR v_new_index IS NULL THEN
        RAISE EXCEPTION 'Invalid risk levels found for current or new profile';
    END IF;
    IF v_new_index > v_current_index + 1 THEN
        RAISE EXCEPTION 'Users can only jump one level higher in risk profiles';
    END IF;

    UPDATE catalog.userriskprofile
       SET risk_profile_id = p_risk_profile_id,
           is_override = TRUE,
           updated_at = CURRENT_TIMESTAMP
     WHERE user_id = p_user_id
     RETURNING * INTO v_profile;

    data := json_build_object(
        'message', 'User risk profile updated successfully',
        'updatedProfile', json_build_object(
        'id', v_profile.id,
        'user_id', v_profile.user_id,
        'total_score', v_profile.total_score,
        'risk_profile_id', v_profile.risk_profile_id,
        'reason', v_profile.reason,
        'answers', v_profile.answers,
        'created_at', v_profile.created_at,
        'updated_at', v_profile.updated_at,
        'is_active', v_profile.is_active,
        'is_checked', v_profile.is_checked,
        'is_override', v_profile.is_override,
        'risk_level', json_build_object(
            'id', v_new_grid.id,
            'risk_level', v_new_grid.risk_level,
            'min_score', v_new_grid.min_score,
            'max_score', v_new_grid.max_score,
            'description', v_new_grid.description
        )
        )
    );
END;
$procedure$;

-- File: catalog.sp_upsert_reason_template.sql
-- PROCEDURE: catalog.sp_upsert_reason_template
-- Function: upsertReasonTemplate
-- Prisma await: await prismaClient.reasonTemplate.upsert(...)
-- Purpose: Atomic PostgreSQL write for Operations reason-template manager.
-- Point: Operations reason-template manager
-- Used by: Controller/service flow upsertReasonTemplate() when replacing the matching Prisma write.
-- Replaces: ReasonTemplate create/update. Pass NULL p_id to create using serial.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_ref_id varchar; p_subject varchar; p_reason text; p_reason_type text; p_id integer DEFAULT NULL;
--     p_html_content text DEFAULT NULL; p_status text DEFAULT 'Active'
--   Code / route integration target: Code function: upsertReasonTemplate | Route / flow: Controller/service flow
--     upsertReasonTemplate() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.reasonTemplate.upsert(...)
--   Full routes / trigger: POST /operations/reason-templates; PUT /operations/reason-templates/:id; PUT
--     /operations/reason-templates/:id/toggle - create/update/toggle a reason template
--   Related .js file(s): server_trade/controllers/operations/reasonTemplates.controller.js;
--     server_trade/routes/operations/reasonTemplates.routes.js
--   Integration point: Operations reason-template manager
--   Reason: Atomic PostgreSQL write for Operations reason-template manager.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "catalog".sp_upsert_reason_template(
    p_ref_id varchar,
    p_subject varchar,
    p_reason text,
    p_reason_type text,
    p_id integer DEFAULT NULL,
    p_html_content text DEFAULT NULL,
    p_status text DEFAULT 'Active'
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_id IS NULL THEN
        INSERT INTO "catalog".reason_templates (
            ref_id, subject, reason, html_content, reason_type, status,
            "createdAt", "updatedAt"
        ) VALUES (
            p_ref_id, p_subject, p_reason, p_html_content,
            p_reason_type::template_reason_type, p_status::template_status_enum,
            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        );
    ELSE
        UPDATE "catalog".reason_templates
        SET ref_id = p_ref_id,
            subject = p_subject,
            reason = p_reason,
            html_content = p_html_content,
            reason_type = p_reason_type::template_reason_type,
            status = p_status::template_status_enum,
            "updatedAt" = CURRENT_TIMESTAMP
        WHERE id = p_id;

        IF NOT FOUND THEN RAISE EXCEPTION 'Reason template not found: %', p_id; END IF;
    END IF;
END;
$procedure$;
