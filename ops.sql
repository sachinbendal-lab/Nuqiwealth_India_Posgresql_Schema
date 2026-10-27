-- Schema-wise stored procedures
-- Source: Procedure\ops\

-- File: ops.create_manual_kyc.sql
CREATE OR REPLACE PROCEDURE "ops".create_manual_kyc(
    p_user_id VARCHAR(191),
    p_full_name VARCHAR(191),
    p_pan_number VARCHAR(191),
    p_dob VARCHAR(191),
    p_gender VARCHAR(191),
    p_aadhaar_number VARCHAR(191),
    p_address_text TEXT,
    p_address_json JSON,
    p_transaction_id VARCHAR(191),
    p_status VARCHAR(191),
    p_provider VARCHAR(191),
    p_saved_paths JSON, 
    OUT data JSON
) 
LANGUAGE plpgsql
AS $$
DECLARE
    v_kyc_id VARCHAR(191);
    v_locked_user_id VARCHAR(191);
    v_user_deleted BOOLEAN := FALSE;
    v_user_json JSON;
    v_kyc_json JSON;
BEGIN
    -- 1. Lock and verify the core user record
    SELECT id, is_deleted INTO v_locked_user_id, v_user_deleted
    FROM "user"."user" WHERE id = $1 FOR UPDATE;
      
    IF v_locked_user_id IS NULL OR v_user_deleted THEN
        RAISE EXCEPTION 'User not found or deleted';
    END IF;

    -- 2. Verify duplicate KYC record using double-quoted camelCase column
    IF EXISTS (SELECT 1 FROM kyc.kyc WHERE "userId" = $1) THEN
        RAISE EXCEPTION 'KYC record already exists';
    END IF;

    -- 3. Prepare UUID primary key
    v_kyc_id := REPLACE(gen_random_uuid()::text, '-', '');
    
    -- 4. Execute data insertion with accurate positioning and explicitly cast JSONB types
    INSERT INTO kyc.kyc (
        id, "userId", "transactionId", status, provider, "fullName", dob, gender,
        "addressText", "addressJson", "panNumber", "aadhaarMaskedNumber",
        "selfieImagePath", "livenessImagePath", "panCroppedImagePath", "poiIdFaceImagePath",
        "eaadhaarPdfPath", "aadhaarXmlPath", "aadhaarPhotoImagePath",
        "verifiedAt", "createdAt", "updatedAt"
    ) VALUES (
        v_kyc_id, 
        $1,                             -- p_user_id
        $9,                             -- p_transaction_id
        $10,                            -- p_status
        $11,                            -- p_provider
        $2,                             -- p_full_name
        $4,                             -- p_dob
        $5,                             -- p_gender
        $7,                             -- p_address_text (Fixed alignment mismatch)
        $8::jsonb,                      -- p_address_json (Added explicit cast to jsonb)
        $3,                             -- p_pan_number
        $6,                             -- p_aadhaar_number (Fixed alignment mismatch)
        $12->>'selfieImagePath',
        $12->>'livenessImagePath',
        $12->>'panCroppedImagePath',
        $12->>'poiIdFaceImagePath',
        $12->>'eaadhaarPdfPath',
        $12->>'aadhaarXmlPath',
        $12->>'aadhaarPhotoImagePath',
        CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    );

    -- 5. Synchronize User table parameters
    UPDATE "user"."user"
    SET is_kyc_verified = ($10 IN ('APPROVED', 'auto_approved')), 
        kyc_status = $10
    WHERE id = $1;

    -- 6. Fetch updated user context into standard JSON formatting
    SELECT json_build_object('id', id, 'email', email, 'first_name', first_name, 'last_name', last_name)
    INTO v_user_json FROM "user"."user" WHERE id = $1;
      
    -- 7. Fetch finalized KYC structural array to output payload mapping
    SELECT json_build_object(
        'id', k.id, 'userId', k."userId", 'transactionId', k."transactionId",
        'status', k.status, 'provider', k.provider, 'fullName', k."fullName",
        'dob', k.dob, 'gender', k.gender, 'addressText', k."addressText",
        'addressJson', k."addressJson", 'panNumber', k."panNumber",
        'aadhaarMaskedNumber', k."aadhaarMaskedNumber",
        'rejection_reason', k.rejection_reason,
        'selfieImagePath', k."selfieImagePath", 'livenessImagePath', k."livenessImagePath",
        'panCroppedImagePath', k."panCroppedImagePath", 'poiIdFaceImagePath', k."poiIdFaceImagePath",
        'eaadhaarPdfPath', k."eaadhaarPdfPath", 'aadhaarXmlPath', k."aadhaarXmlPath",
        'aadhaarPhotoImagePath', k."aadhaarPhotoImagePath",
        'hyperverResponse', k."hyperverResponse", 'nameMatchScore', k."nameMatchScore",
        'verifiedAt', k."verifiedAt", 'createdAt', k."createdAt", 'updatedAt', k."updatedAt",
        'user', v_user_json
    ) INTO v_kyc_json FROM kyc.kyc k WHERE k.id = v_kyc_id;
    
    SELECT v_kyc_json INTO data;
END;
$$;

--CALL ops.create_manual_kyc('NUQI00000002', 'Sumit Patil', 'PAN_NUMBER', '2016-06-02', 'MALE', 'AADHAAR_LAST4', 'ADDRESS', '{}'::json, 'TRANSACTION_ID', 'PENDING', 'MANUAL', '{}'::json, NULL);

-- File: ops.deactivate_operational_user.sql
CREATE OR REPLACE PROCEDURE ops.deactivate_operational_user(
    IN    p_id             VARCHAR,
    INOUT p_result         TEXT DEFAULT NULL,
    INOUT p_http_status    INTEGER DEFAULT NULL,
    INOUT p_code           TEXT DEFAULT NULL,
    INOUT p_message        TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_email VARCHAR;
    v_role  VARCHAR;
BEGIN
    -- Initialize output results
    p_result      := 'SUCCESS';
    p_http_status := 200;
    p_code        := 'OK';
    p_message     := 'User deactivated successfully';

    -- 1. Verify user existence and collect metadata
    SELECT email, role::VARCHAR 
      INTO v_email, v_role
      FROM ops.operations_user 
     WHERE id = p_id;

    IF v_email IS NULL THEN
        p_result      := 'USER_NOT_FOUND';
        p_http_status := 404;
        p_code        := 'NOT_FOUND';
        p_message     := 'User not found';
        RETURN;
    END IF;

    -- 2. Perform the update operation directly
    UPDATE ops.operations_user
       SET is_active = FALSE,
           updated_at = NOW()
     WHERE id = p_id;

    -- 3. Exact Audit Insert matching the correct Boolean type assignment
    BEGIN
        INSERT INTO ops.audit_logs (
            module, 
            "actionType", 
            "entityType", 
            "entityId", 
            "statusBefore", 
            "statusAfter", 
            "actionReason", 
            "adminEmail",        
            "adminName",         
            "ipAddress",         
            browser,             
            success,             -- Boolean column
            "createdAt"          
        )
        VALUES (
            'Governance & Audit', 
            'Admin Account Updated', 
            'Operational User',
            p_id, 
            'Active', 
            'Inactive',
            'Admin ' || v_email || ' deactivated via system override — Role: ' || v_role,
            'SYSTEM',                             
            'SYSTEM_OVERRIDE',                    
            '10.14.14.1',                         
            'Mozilla/5.0 (Macro; Execution System Override)', 
            TRUE,                                 -- Changed from 1 to TRUE to resolve the crash
            NOW()
        );
    EXCEPTION WHEN OTHERS THEN
        -- Re-throws structural exceptions if any other database constraint fails
        RAISE EXCEPTION 'Audit insertion trace breakdown: %', SQLERRM;
    END;
END;
$$;
--CALL ops.deactivate_operational_user('NUQIADMIN887766554', NULL, NULL, NULL, NULL );

-- File: ops.get_all_kyc_records.sql
CREATE OR REPLACE PROCEDURE "ops".get_all_kyc_records(
    p_terms JSON,
    p_fields JSON,
    p_start_date TIMESTAMP,
    p_end_date TIMESTAMP,
    p_status VARCHAR(64),
    p_page_offset INT,
    p_page_limit INT,
    p_fetch_all BOOLEAN, OUT data JSON) 
LANGUAGE plpgsql
AS $$
DECLARE
    v_records JSON;
    v_total BIGINT := 0;
    v_status_counts JSON;
    v_limit INT;
    v_offset INT;
BEGIN
    v_limit := CASE WHEN p_fetch_all THEN NULL ELSE COALESCE(p_page_limit, 10) END;
    v_offset := CASE WHEN p_fetch_all THEN 0 ELSE COALESCE(p_page_offset, 0) END;

    SELECT COUNT(*) INTO v_total
    FROM kyc.kyc k JOIN "user"."user" u ON u.id = k.userId
    WHERE (p_start_date IS NULL OR k.createdAt >= p_start_date)
      AND (p_end_date IS NULL OR k.createdAt <= p_end_date)
      AND (p_status IS NULL OR p_status = 'All'
           OR (p_status = 'Pending' AND k.status IN ('PENDING', 'UNDER_REVIEW', 'IN_PROGRESS'))
           OR (p_status <> 'Pending' AND k.status = p_status));

    SELECT COALESCE(json_agg(row_data.kyc_data), '[]'::json) INTO v_records
    FROM (
        SELECT json_build_object(
            'id', k.id,
            'userId', k.userId,
            'transactionId', k.transactionId,
            'status', k.status,
            'provider', k.provider,
            'fullName', k.fullName,
            'dob', k.dob,
            'gender', k.gender,
            'addressText', k.addressText,
            'addressJson', k.addressJson,
            'panNumber', k.panNumber,
            'aadhaarMaskedNumber', k.aadhaarMaskedNumber,
            'rejection_reason', k.rejection_reason,
            'selfieImagePath', k.selfieImagePath,
            'livenessImagePath', k.livenessImagePath,
            'panCroppedImagePath', k.panCroppedImagePath,
            'poiIdFaceImagePath', k.poiIdFaceImagePath,
            'eaadhaarPdfPath', k.eaadhaarPdfPath,
            'aadhaarXmlPath', k.aadhaarXmlPath,
            'aadhaarPhotoImagePath', k.aadhaarPhotoImagePath,
            'hyperverResponse', k.hyperverResponse,
            'nameMatchScore', k.nameMatchScore,
            'verifiedAt', k.verifiedAt,
            'createdAt', k.createdAt,
            'updatedAt', k.updatedAt,
            'user', json_build_object(
                'id', u.id, 'email', u.email, 'first_name', u.first_name,
                'last_name', u.last_name, 'phone_number', u.phone_number,
                'is_kyc_verified', u.is_kyc_verified, 'created_at', u.created_at
            )
        ) AS kyc_data
        FROM kyc.kyc k JOIN "user"."user" u ON u.id = k.userId
        WHERE (p_start_date IS NULL OR k.createdAt >= p_start_date)
          AND (p_end_date IS NULL OR k.createdAt <= p_end_date)
          AND (p_status IS NULL OR p_status = 'All'
               OR (p_status = 'Pending' AND k.status IN ('PENDING', 'UNDER_REVIEW', 'IN_PROGRESS'))
               OR (p_status <> 'Pending' AND k.status = p_status))
        ORDER BY k.verifiedAt DESC
        LIMIT v_limit OFFSET v_offset
    ) row_data;

    SELECT COALESCE(json_object_agg(COALESCE(k.status, '__NULL__'), status_rows.row_count), '{}'::json)
      INTO v_status_counts
      FROM (
        SELECT k.status, COUNT(*) AS row_count
        FROM kyc.kyc k JOIN "user"."user" u ON u.id = k.userId
        WHERE (p_start_date IS NULL OR k.createdAt >= p_start_date)
          AND (p_end_date IS NULL OR k.createdAt <= p_end_date)
        GROUP BY k.status
      ) status_rows;

    SELECT json_build_object('records', v_records, 'total', v_total, 'statusCounts', v_status_counts) INTO data ;
END;
$$;
-- CALL ops.get_all_kyc_records('{}'::json, '[]'::json, NULL::timestamp, NULL::timestamp, 'All', 0, 10, FALSE, NULL);

-- File: ops.get_all_user_subscriptions.sql
CREATE OR REPLACE PROCEDURE "ops".get_all_user_subscriptions(
    p_search VARCHAR(255),
    p_page_offset INT,
    p_page_limit INT, 
    OUT data JSON
) 
LANGUAGE plpgsql
AS $$
DECLARE
    v_data JSON;
    v_total BIGINT := 0;
BEGIN
    -- 1. Calculate total count for pagination (Fixed: double quotes and $1 applied)
    SELECT COUNT(*) INTO v_total
    FROM payments.usersubscription us
    JOIN "user"."user" u ON u.id = us.user_ref_id
    JOIN payments.subscriptions s ON s.id = us."subscriptionsId" -- Fixed: Added double quotes for case-sensitivity
    WHERE COALESCE($1, '') = '' -- Fixed: Using $1 positional parameter instead of p_search
       OR POSITION($1 IN us.user_ref_id) > 0
       OR POSITION($1 IN COALESCE(u.email, '')) > 0
       OR POSITION($1 IN COALESCE(u.first_name, '')) > 0
       OR POSITION($1 IN COALESCE(u.last_name, '')) > 0
       OR POSITION($1 IN s.name) > 0;

    -- 2. Fetch dataset compiled into a single JSON array
    SELECT COALESCE(json_agg(result_row.sub_data), '[]'::json) INTO v_data
    FROM (
        SELECT json_build_object(
            'id', us.id,
            'user_ref_id', us.user_ref_id,
            'subscriptionsId', us."subscriptionsId", -- Fixed: Added double quotes
            'plan_name', us.plan_name,
            'amount', us.amount,
            'start_date', us.start_date,
            'end_date', us.end_date,
            'subscription_status', us.subscription_status,
            'transaction_status', us.transaction_status,
            'trace_id', us.trace_id,
            'response_data', us.response_data,
            'created_at', us.created_at,
            'update_at', us.update_at,
            'User', json_build_object(
                'id', u.id, 'email', u.email, 'first_name', u.first_name,
                'last_name', u.last_name, 'is_kyc_verified', u.is_kyc_verified,
                'is_risk_verified', u.is_risk_verified
            ),
            'Subscriptions', json_build_object('id', s.id, 'name', s.name)
        ) AS sub_data
        FROM payments.usersubscription us
        JOIN "user"."user" u ON u.id = us.user_ref_id
        JOIN payments.subscriptions s ON s.id = us."subscriptionsId" -- Fixed: Added double quotes
        WHERE COALESCE($1, '') = '' 
           OR POSITION($1 IN us.user_ref_id) > 0
           OR POSITION($1 IN COALESCE(u.email, '')) > 0
           OR POSITION($1 IN COALESCE(u.first_name, '')) > 0
           OR POSITION($1 IN COALESCE(u.last_name, '')) > 0
           OR POSITION($1 IN s.name) > 0
        ORDER BY us.created_at DESC
        LIMIT $3 OFFSET $2 -- Fixed: Handled using positional parameters
    ) result_row;

    -- 3. Set the final packaged output object
    SELECT json_build_object('subscriptions', v_data, 'total', v_total) INTO data ;
END;
$$;

-- CALL ops.get_all_user_subscriptions('', 0, 10, NULL);

-- File: ops.get_all_users.sql
CREATE OR REPLACE PROCEDURE "ops".get_all_users(
    p_terms JSON,
    p_fields JSON,
    p_start_date TIMESTAMP,
    p_end_date TIMESTAMP,
    p_account_status VARCHAR(64),
    p_page_offset INT,
    p_page_limit INT,
    p_fetch_all BOOLEAN, OUT data JSON) 
LANGUAGE plpgsql
AS $$
DECLARE
    v_users JSON;
    v_total BIGINT := 0;
    v_counts JSON;
    v_limit INT;
    v_offset INT;
BEGIN
    v_limit := CASE WHEN p_fetch_all THEN NULL ELSE COALESCE(p_page_limit, 10) END;
    v_offset := CASE WHEN p_fetch_all THEN 0 ELSE COALESCE(p_page_offset, 0) END;

    -- Count total records matching filter criteria
    SELECT COUNT(*) INTO v_total
    FROM "user"."user" u
    WHERE u.is_deleted = FALSE
      AND (p_start_date IS NULL OR u.created_at >= p_start_date)
      AND (p_end_date IS NULL OR u.created_at <= p_end_date)
      AND (p_account_status IS NULL OR p_account_status = 'All' OR u.account_status = p_account_status);

    -- Build core dynamic output
    SELECT COALESCE(json_agg(page_rows), '[]'::json) INTO v_users
    FROM (
        SELECT u.id, u.email, u.first_name, u.last_name, u.phone_number, u.role,
               u.is_email_verified, u.is_phone_verified, u.is_kyc_verified,
               u.is_bank_kyc_verified, u.is_risk_verified, u.account_status,
               u.created_at,
               (SELECT r.risk_level
                  FROM catalog.userriskprofile urp
                  JOIN catalog.riskprofilescoregrid r ON r.id = urp.risk_profile_id
                 WHERE urp.user_id = u.id LIMIT 1) AS risk_level
        FROM "user"."user" u
        WHERE u.is_deleted = FALSE
          AND (p_start_date IS NULL OR u.created_at >= p_start_date)
          AND (p_end_date IS NULL OR u.created_at <= p_end_date)
          AND (p_account_status IS NULL OR p_account_status = 'All' OR u.account_status = p_account_status)
        ORDER BY u.created_at DESC
        LIMIT v_limit OFFSET v_offset
    ) page_rows;

    -- Aggregate Status Counts
    SELECT COALESCE(json_object_agg(COALESCE(status_key, 'Active'), status_count), '{}'::json)
      INTO v_counts
      FROM (
        SELECT COALESCE(u.account_status, 'Active') AS status_key, COUNT(*) AS status_count
        FROM "user"."user" u
        WHERE u.is_deleted = FALSE
          AND (p_start_date IS NULL OR u.created_at >= p_start_date)
          AND (p_end_date IS NULL OR u.created_at <= p_end_date)
        GROUP BY COALESCE(u.account_status, 'Active')
      ) status_rows;

    SELECT json_build_object('users', v_users, 'total', v_total, 'statusCounts', v_counts) INTO data ;
END;
$$;
-- CALL ops.get_all_users('{}'::json, '[]'::json, NULL::timestamp, NULL::timestamp, 'All', 0, 10, FALSE, NULL);

-- File: ops.get_subscription_plans.sql
CREATE OR REPLACE PROCEDURE "ops".get_subscription_plans(OUT data JSON) 
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT COALESCE(json_agg(p), '[]'::json)
     INTO data FROM (
        SELECT id, name, price, is_nuclear
        FROM payments.subscriptions
        WHERE is_active = TRUE
        ORDER BY price ASC
    ) AS p;
END;
$$;
-- CALL "ops".get_subscription_plans(NULL);

-- File: ops.get_user_details.sql
CREATE OR REPLACE PROCEDURE "ops".get_user_details(p_user_id VARCHAR(191), OUT data JSON) 
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT CASE WHEN u.id IS NULL THEN NULL ELSE
        json_build_object(
            'id', u.id,
            'email', u.email,
            'first_name', u.first_name,
            'last_name', u.last_name,
            'phone_number', u.phone_number,
            'role', u.role,
            'is_email_verified', u.is_email_verified,
            'is_phone_verified', u.is_phone_verified,
            'is_kyc_verified', u.is_kyc_verified,
            'is_risk_verified', u.is_risk_verified,
            'is_bank_kyc_verified', u.is_bank_kyc_verified,
            'is_deleted', u.is_deleted,
            'created_at', u.created_at,
            'SubscriptionFeature', (
                SELECT json_build_object(
                    'id', sf.id,
                    'user_ref_id', sf.user_ref_id,
                    'ethicalStocksAccess', sf.ethicalStocksAccess,
                    'brokerAccess', sf.brokerAccess,
                    'portfolioAccess', sf.portfolioAccess,
                    'cepsAccess', sf.cepsAccess,
                    'featuredStocksAccess', sf.featuredStocksAccess,
                    'storiesAccess', sf.storiesAccess,
                    'stockDetailsAccess', sf.stockDetailsAccess,
                    'keyInsightsAccess', sf.keyInsightsAccess,
                    'priceAlertsLimit', sf.priceAlertsLimit,
                    'advancedAlertsAccess', sf.advancedAlertsAccess,
                    'advancedSearchAccess', sf.advancedSearchAccess,
                    'peerComparisonLimit', sf.peerComparisonLimit,
                    'sectorAnalysisAccess', sf.sectorAnalysisAccess,
                    'downloadResultsAccess', sf.downloadResultsAccess,
                    'pricingDataYears', sf.pricingDataYears,
                    'fundamentalDataYears', sf.fundamentalDataYears,
                    'shareholderDataAccess', sf.shareholderDataAccess,
                    'marketShareAccess', sf.marketShareAccess,
                    'revenueAccess', sf.revenueAccess,
                    'financialStatementsYears', sf.financialStatementsYears,
                    'technicalDataYears', sf.technicalDataYears,
                    'technicalScreenersLimit', sf.technicalScreenersLimit,
                    'customScreenersAccess', sf.customScreenersAccess,
                    'cepLimit', sf.cepLimit,
                    'aiAdvisorAccess', sf.aiAdvisorAccess,
                    'dailyMarketNewsAccess', sf.dailyMarketNewsAccess,
                    'postMarketAnalysisAccess', sf.postMarketAnalysisAccess,
                    'portfolioAnalysisAccess', sf.portfolioAnalysisAccess,
                    'aiPicksAccess', sf.aiPicksAccess,
                    'watchlistLimit', sf.watchlistLimit,
                    'tradeExecutionAccess', sf.tradeExecutionAccess,
                    'portfolioPurification', sf.portfolioPurification,
                    'portfolioAggregation', sf.portfolioAggregation,
                    'mfTradeExecution', sf.mfTradeExecution,
                    'mfAggregationAccess', sf.mfAggregationAccess,
                    'globalStocksAccess', sf.globalStocksAccess,
                    'netWorthAccess', sf.netWorthAccess,
                    'calculatorsAccess', sf.calculatorsAccess,
                    'sentimentAnalysisLimit', sf.sentimentAnalysisLimit,
                    'dedicatedAgentAccess', sf.dedicatedAgentAccess,
                    'createdAt', sf.createdAt,
                    'updatedAt', sf.updatedAt
                ) FROM catalog.subscriptionfeature sf WHERE sf.user_ref_id = u.id
            ),
            'UserSubscription', COALESCE((
                SELECT json_agg(sub_row.sub_data)
                FROM (
                    SELECT json_build_object(
                        'id', us.id,
                        'user_ref_id', us.user_ref_id,
                        'subscriptionsId', us.subscriptionsId,
                        'plan_name', us.plan_name,
                        'amount', us.amount,
                        'start_date', us.start_date,
                        'end_date', us.end_date,
                        'subscription_status', us.subscription_status,
                        'transaction_status', us.transaction_status,
                        'trace_id', us.trace_id,
                        'response_data', us.response_data,
                        'created_at', us.created_at,
                        'update_at', us.update_at,
                        'Subscriptions', json_build_object('id', s.id, 'name', s.name, 'price', s.price)
                    ) AS sub_data
                    FROM payments.usersubscription us
                    JOIN payments.subscriptions s ON s.id = us.subscriptionsId
                    WHERE us.user_ref_id = u.id
                    ORDER BY us.created_at DESC
                    LIMIT 5
                ) sub_row
            ), '[]'::json)
        ) END AS data
     INTO data FROM "user"."user" u
    WHERE u.id = p_user_id
    LIMIT 1;
END;
$$;
-- CALL ops.get_user_details('USER_ID_HERE', NULL);

-- File: ops.reactivate_operational_user.sql
CREATE OR REPLACE PROCEDURE ops.reactivate_operational_user(
    IN    p_id             VARCHAR,
    INOUT p_result         TEXT DEFAULT NULL,
    INOUT p_http_status    INTEGER DEFAULT NULL,
    INOUT p_code           TEXT DEFAULT NULL,
    INOUT p_message        TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_email VARCHAR;
BEGIN
    -- Initialize execution outcomes
    p_result      := 'SUCCESS';
    p_http_status := 200;
    p_code        := 'OK';
    p_message     := 'User reactivated successfully';

    -- 1. Check if the user exists and collect metadata for the audit reason string
    SELECT email 
      INTO v_email
      FROM ops.operations_user 
     WHERE id = p_id;

    IF v_email IS NULL THEN
        p_result      := 'USER_NOT_FOUND';
        p_http_status := 404;
        p_code        := 'NOT_FOUND';
        p_message     := 'User not found';
        RETURN;
    END IF;

    -- 2. Update the user status directly to active (TRUE)
    UPDATE ops.operations_user
       SET is_active = TRUE,
           updated_at = NOW()
     WHERE id = p_id;

    -- 3. Exact Audit Insert matching your specific visual layout parameters
    BEGIN
        INSERT INTO ops.audit_logs (
            module, 
            "actionType", 
            "entityType", 
            "entityId", 
            "statusBefore", 
            "statusAfter", 
            "actionReason", 
            "adminEmail",        
            "adminName",         
            "ipAddress",         
            browser,             
            success,             -- Explicitly handles strict BOOLEAN rules
            "createdAt"          
        )
        VALUES (
            'Governance & Audit', 
            'Admin Status Changed', 
            'Operational User',
            p_id, 
            'Inactive', 
            'Active',
            'Admin account ' || v_email || ' reactivated',
            'SYSTEM',                             
            'SYSTEM_OVERRIDE',                    
            '10.14.14.1',                         
            'Mozilla/5.0 (Macro; Execution System Override)', 
            TRUE,                                 
            NOW()
        );
    EXCEPTION WHEN OTHERS THEN
        -- Safely log syntax failures on secondary dependencies to isolate the flow
        RAISE NOTICE 'Reactivation audit write failed: %', SQLERRM;
    END;
END;
$$;
--CALL ops.reactivate_operational_user('NUQIADMIN887766554', NULL, NULL, NULL, NULL);

-- File: ops.rotate_admin_refresh_token.sql
CREATE OR REPLACE PROCEDURE "ops".rotate_admin_refresh_token(
    IN    p_token_hash       VARCHAR(64),
    IN    p_family_id        VARCHAR(36),
    IN    p_claimed_user_id  VARCHAR(64),
    IN    p_new_token_hash   VARCHAR(64),
    IN    p_new_expires_at   TIMESTAMP(3),
    IN    p_device_info      JSONB,
    INOUT p_result         TEXT DEFAULT NULL,
    INOUT p_http_status    INTEGER DEFAULT NULL,
    INOUT p_code           TEXT DEFAULT NULL,
    INOUT p_message        TEXT DEFAULT NULL,
    INOUT p_user_id        VARCHAR(64) DEFAULT NULL,
    INOUT p_token_version  INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- 1. Consume and update using integer 1 (TRUE) and 0 (FALSE)
    UPDATE "user".refreshtoken AS rt
       SET "isUsed" = 1
     WHERE rt."tokenHash" = p_token_hash
       AND rt."userType" = 'admin'
       AND rt."isUsed" = 0
    RETURNING rt."userId", rt."tokenVersion"
    INTO p_user_id, p_token_version;

    -- 2. Replay Attack / Reuse Protection if no active token row was updated
    IF NOT FOUND THEN
        IF EXISTS (
            SELECT 1 FROM "user".refreshtoken AS rt
             WHERE rt."tokenHash" = p_token_hash AND rt."userType" = 'admin'
        ) THEN
            -- Invalidate the entire family chain using integer 1 (TRUE)
            UPDATE "user".refreshtoken AS rt
               SET revoked = 1,
                   "revokedAt" = CURRENT_TIMESTAMP,
                   "revokedReason" = 'theft_detected'
             WHERE rt."familyId" = p_family_id
               AND rt."userType" = 'admin';

            p_result      := 'TOKEN_REPLAYED';
            p_http_status := 498;
            p_code        := 'TOKEN_REVOKED';
            p_message     := 'Token reuse detected. All sessions revoked.';
            p_user_id     := NULL;
            p_token_version := NULL;
            RETURN;
        ELSE
            -- Token is completely missing from the database
            IF EXISTS (
                SELECT 1 FROM "user".refreshtoken AS rt
                 WHERE rt."familyId" = p_family_id AND rt."userType" = 'admin'
            ) THEN
                UPDATE "user".refreshtoken AS rt
                   SET revoked = 1,
                       "revokedAt" = CURRENT_TIMESTAMP,
                       "revokedReason" = 'theft_detected'
                 WHERE rt."familyId" = p_family_id AND rt."userType" = 'admin';
            END IF;

            p_result      := 'TOKEN_NOT_FOUND';
            p_http_status := 498;
            p_code        := 'TOKEN_REVOKED';
            p_message     := 'Token reuse detected. All sessions revoked.';
            p_user_id     := NULL;
            p_token_version := NULL;
            RETURN;
        END IF;
    END IF;

    -- 3. Validate security claims against JWT properties
    IF NOT EXISTS (
        SELECT 1 FROM "user".refreshtoken AS rt
         WHERE rt."tokenHash" = p_token_hash
           AND rt."familyId" = p_family_id
           AND rt."userId" = p_claimed_user_id
    ) THEN
        p_result      := 'TOKEN_CLAIM_MISMATCH';
        p_http_status := 498;
        p_code        := 'TOKEN_REVOKED';
        p_message     := 'Refresh token claims do not match the stored session.';
        RETURN;
    END IF;

    -- 4. Check expiration and manual revocations (Checking if revoked = 1)
    IF EXISTS (
        SELECT 1 FROM "user".refreshtoken AS rt
         WHERE rt."tokenHash" = p_token_hash
           AND (rt.revoked = 1 OR rt."expiresAt" < CURRENT_TIMESTAMP)
    ) THEN
        p_result      := 'TOKEN_REVOKED';
        p_http_status := 498;
        p_code        := 'TOKEN_REVOKED';
        p_message     := 'Refresh token has been revoked.';
        RETURN;
    END IF;

    -- 5. Lock and evaluate admin account state (Checking if is_active = TRUE/1 based on column type)
    -- If your operations_user table uses boolean for is_active, keep "= TRUE". If it's integer, change to "= 1".
    IF NOT EXISTS (
        SELECT 1 FROM "ops".operations_user AS ou
         WHERE ou.id = p_claimed_user_id AND ou.is_active = TRUE
         FOR UPDATE
    ) THEN
        p_result      := 'ADMIN_NOT_FOUND_OR_INACTIVE';
        p_http_status := 403;
        p_code        := 'INVALID_TOKEN';
        p_message     := 'Account not found or inactive.';
        RETURN;
    END IF;

    -- 6. Check for master token version invalidation
    IF NOT EXISTS (
        SELECT 1 FROM "ops".operations_user AS ou
         WHERE ou.id = p_claimed_user_id AND ou.token_version = p_token_version
    ) THEN
        p_result      := 'TOKEN_VERSION_MISMATCH';
        p_http_status := 401;
        p_code        := 'TOKEN_REVOKED';
        p_message     := 'Session invalidated. Please log in again.';
        RETURN;
    END IF;

    -- 7. Process Rotation: Insert the new token row using 0 (FALSE) for flags
    -- Adjusting "id" column generation style if your database requires an explicit unique string id
    INSERT INTO "user".refreshtoken (
        id, "userId", "userType", "tokenHash", "familyId", "tokenVersion",
        "deviceInfo", "expiresAt", "isUsed", revoked, "createdAt"
    ) VALUES (
        'c' || substr(md5(random()::text), 1, 24), p_claimed_user_id, 'admin', p_new_token_hash, p_family_id,
        p_token_version, p_device_info, p_new_expires_at,
        0, 0, CURRENT_TIMESTAMP
    );

    -- 8. Finalize: Explicitly mark the parent row as safely rotated (revoked = 1)
    UPDATE "user".refreshtoken AS rt
       SET revoked = 1,
           "revokedAt" = CURRENT_TIMESTAMP,
           "revokedReason" = 'rotated'
     WHERE rt."tokenHash" = p_token_hash 
       AND rt."userType" = 'admin';

    -- Set return variables for success state
    p_result      := 'ROTATED';
    p_http_status := 200;
    p_code        := 'OK';
    p_message     := 'Admin refresh token rotated.';
END;
$$;

--CALL "ops".rotate_admin_refresh_token('sample_incoming_hash_xyz','sample-family-uuid-1111','NUQIADMIN002','new_generated_hash_abc123',(CURRENT_TIMESTAMP + INTERVAL '7 days')::TIMESTAMP(3),'{"ip":"10.14.14.1"}'::jsonb);

-- File: ops.soft_delete_user.sql
CREATE OR REPLACE PROCEDURE "ops".soft_delete_user(p_user_id VARCHAR(191), OUT data JSON) 
LANGUAGE plpgsql
AS $$
DECLARE
    v_email VARCHAR(191);
    v_phone VARCHAR(191);
    v_google_id VARCHAR(191);
    v_apple_id VARCHAR(191);
    v_first_name VARCHAR(191);
    v_last_name VARCHAR(191);
    v_deleted BOOLEAN;
    v_suffix INT := 1;
    v_new_email VARCHAR(191);
    v_new_phone VARCHAR(191);
    v_new_google_id VARCHAR(191);
    v_new_apple_id VARCHAR(191);
    v_user_exists BOOLEAN := FALSE;
BEGIN
    SELECT EXISTS(SELECT 1 FROM "user"."user" WHERE id = p_user_id) INTO v_user_exists;
    IF NOT v_user_exists THEN
        RAISE EXCEPTION 'User not found';
    END IF;

    SELECT email, phone_number, google_id, apple_id, first_name, last_name, is_deleted
      INTO v_email, v_phone, v_google_id, v_apple_id, v_first_name, v_last_name, v_deleted
      FROM "user"."user" WHERE id = p_user_id FOR UPDATE;

    IF v_deleted THEN
        RAISE EXCEPTION 'User is already deleted';
    END IF;
    v_email := COALESCE(v_email, 'null');

    LOOP
        v_new_email := v_email || '_DEL_' || v_suffix;
        v_new_phone := CASE WHEN v_phone IS NULL THEN NULL ELSE v_phone || '_DEL_' || v_suffix END;
        v_new_google_id := CASE WHEN v_google_id IS NULL THEN NULL ELSE v_google_id || '_DEL_' || v_suffix END;
        v_new_apple_id := CASE WHEN v_apple_id IS NULL THEN NULL ELSE v_apple_id || '_DEL_' || v_suffix END;

        IF NOT EXISTS (SELECT 1 FROM "user"."user" WHERE email = v_new_email)
           AND (v_new_phone IS NULL OR NOT EXISTS (SELECT 1 FROM "user"."user" WHERE phone_number = v_new_phone))
           AND (v_new_google_id IS NULL OR NOT EXISTS (SELECT 1 FROM "user"."user" WHERE google_id = v_new_google_id))
           AND (v_new_apple_id IS NULL OR NOT EXISTS (SELECT 1 FROM "user"."user" WHERE apple_id = v_new_apple_id)) THEN
            EXIT;
        END IF;

        v_suffix := v_suffix + 1;
    END LOOP;

    UPDATE "user"."user"
       SET is_deleted = TRUE,
           email = v_new_email,
           phone_number = v_new_phone,
           google_id = v_new_google_id,
           apple_id = v_new_apple_id
     WHERE id = p_user_id;

    SELECT json_build_object(
        'userId', p_user_id,
        'originalEmail', v_email,
        'newEmail', v_new_email,
        'originalPhone', v_phone,
        'newPhone', v_new_phone,
        'is_deleted', TRUE,
        'first_name', v_first_name,
        'last_name', v_last_name
    ) INTO data ;
END;
$$;

-- CALL "ops".soft_delete_user('USER_ID_HERE', NULL);

-- File: ops.sp_create_admin_notification.sql
-- PROCEDURE: ops.sp_create_admin_notification
-- Function: createAdminNotification
-- Prisma await: await prismaClient.adminNotification.create(...)
-- Purpose: Atomic PostgreSQL write for Operations notification bell/badge.
-- Point: Operations notification bell/badge
-- Used by: Controller/service flow createAdminNotification() when replacing the matching Prisma write.
-- Replaces: prisma.adminNotification.create({ data }); ID remains serial.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_title varchar; p_message text; p_admin_email varchar; p_type text DEFAULT 'SYSTEM'; p_priority text
--     DEFAULT 'NORMAL'; p_metadata_keys text[] DEFAULT NULL; p_metadata_values text[] DEFAULT NULL; p_created_at
--     timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: createAdminNotification | Route / flow: Controller/service flow
--     createAdminNotification() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.adminNotification.create(...)
--   Full routes / trigger: No single HTTP route - operations maker/checker actions create notification records
--   Related .js file(s): server_trade/controllers/operations/approvalRequests.controller.js;
--     server_trade/utils/adminNotification.js; server_trade/utils/notifyCheckers.js;
--     server_trade/controllers/operations/adminNotifications.controller.js;
--     server_trade/routes/operations/adminNotifications.routes.js
--   Integration point: Operations notification bell/badge
--   Reason: Atomic PostgreSQL write for Operations notification bell/badge.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "ops".sp_create_admin_notification
(
    p_title varchar,
    p_message text,
    p_admin_email varchar,
    p_type text DEFAULT 'SYSTEM',
    p_priority text DEFAULT 'NORMAL',
    p_metadata_keys text[] DEFAULT NULL,
    p_metadata_values text[] DEFAULT NULL,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "ops".adminnotification (
        title, message, type, priority, is_read, admin_email, metadata,
        "createdAt", "updatedAt"
    ) VALUES (
        p_title, p_message, p_type::admin_notification_type,
        p_priority::admin_notification_priority, false, p_admin_email,
        "integration".fn_jsonb_from_pairs(p_metadata_keys, p_metadata_values),
        p_created_at, p_created_at
    );
END;
$procedure$;

-- File: ops.sp_create_operational_user.sql
CREATE OR REPLACE PROCEDURE ops.sp_create_operational_user(
    IN    p_first_name     VARCHAR,
    IN    p_last_name      VARCHAR,
    IN    p_email          VARCHAR,
    IN    p_password       VARCHAR,
    IN    p_role           VARCHAR,
    IN    p_menu_access    JSONB,
    IN    p_generated_id   VARCHAR,
    IN    p_can_create     BOOLEAN,
    IN    p_can_delete     BOOLEAN,
    IN    p_can_read       BOOLEAN,
    IN    p_can_update     BOOLEAN,
    IN    p_ip_address     VARCHAR,
    IN    p_user_agent     TEXT,
    INOUT p_result         TEXT DEFAULT NULL,
    INOUT p_http_status    INTEGER DEFAULT NULL,
    INOUT p_message        TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Initialize execution outcomes
    p_result      := 'SUCCESS';
    p_http_status := 201;
    p_message     := 'User created successfully';

    -- 1. Check if the user email already exists (lowercased constraint)
    IF EXISTS (SELECT 1 FROM ops.operations_user WHERE LOWER(email) = LOWER(p_email)) THEN
        p_result      := 'EMAIL_EXISTS';
        p_http_status := 409;
        p_message     := 'User with this email already exists';
        RETURN;
    END IF;

    -- 2. Insert the core operational profile record (Removed "ops." prefix from the enum cast)
    INSERT INTO ops.operations_user (
        id, first_name, last_name, email, password, role,
        can_create, can_delete, can_read, can_update, menu_access,
        create_at, updated_at, is_active, token_version
    )
    VALUES (
        p_generated_id, p_first_name, p_last_name, LOWER(p_email), p_password, p_role::operations_role,
        p_can_create, p_can_delete, p_can_read, p_can_update, p_menu_access,
        NOW(), NOW(), TRUE, 0
    );

    -- 3. Best-effort mapping table row insert
    BEGIN
        INSERT INTO ops.operations_user_mapping (id, user_id, role, created_at, updated_at)
        VALUES ('c' || substr(md5(random()::text), 1, 24), p_generated_id, p_role::operations_role, NOW(), NOW());
    EXCEPTION WHEN OTHERS THEN
        -- Safely drop out silently on structural errors to mimic catch() {}
    END;

    -- 4. Audit ledger action registration step
    BEGIN
        INSERT INTO "user".auditlog (
            id, module, "actionType", "entityType", "entityId", "statusAfter", 
            "actionReason", success, ip, "userAgent", "createdAt"
        )
        VALUES (
            'c' || substr(md5(random()::text), 1, 24),
            'Governance & Audit', 'Admin Account Created', 'Operational User',
            p_generated_id, 'Active', 
            'New admin created: ' || LOWER(p_email) || ' — Role: ' || p_role,
            TRUE, p_ip_address, p_user_agent, NOW()
        );
    EXCEPTION WHEN OTHERS THEN
        -- Handle silent exit block for secondary dependencies
    END;
END;
$$;
--CALL ops.sp_create_operational_user('John','Doe','john.doe@nuqiwealth.com','$2b$10$UnV6ZkM...','ADMIN','{"dashboard": true}'::jsonb,'NUQIADMIN887766554',TRUE, FALSE, TRUE,TRUE,'192.168.1.1','Mozilla/5.0 (Windows NT 10.0;...)',NULL,NULL,NULL);

-- File: ops.sp_get_operational_users.sql
CREATE OR REPLACE PROCEDURE ops.sp_get_operational_users(
    INOUT o_ids           VARCHAR[] DEFAULT '{}',
    INOUT o_first_names   VARCHAR[] DEFAULT '{}',
    INOUT o_last_names    VARCHAR[] DEFAULT '{}',
    INOUT o_emails        VARCHAR[] DEFAULT '{}',
    INOUT o_roles         VARCHAR[] DEFAULT '{}',
    INOUT o_is_actives    BOOLEAN[] DEFAULT '{}',
    INOUT o_can_creates   BOOLEAN[] DEFAULT '{}',
    INOUT o_can_reads     BOOLEAN[] DEFAULT '{}',
    INOUT o_can_updates   BOOLEAN[] DEFAULT '{}',
    INOUT o_can_deletes   BOOLEAN[] DEFAULT '{}',
    INOUT o_create_ats    TIMESTAMP[] DEFAULT '{}',
    INOUT o_updated_ats   TIMESTAMP[] DEFAULT '{}'
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Aggregate each flat field natively into its corresponding output array vector
    SELECT 
        ARRAY_AGG(ou.id ORDER BY ou.create_at DESC),
        ARRAY_AGG(ou.first_name ORDER BY ou.create_at DESC),
        ARRAY_AGG(ou.last_name ORDER BY ou.create_at DESC),
        ARRAY_AGG(ou.email ORDER BY ou.create_at DESC),
        ARRAY_AGG(ou.role::VARCHAR ORDER BY ou.create_at DESC), -- Safely casts the custom enum to string
        ARRAY_AGG(ou.is_active ORDER BY ou.create_at DESC),
        ARRAY_AGG(ou.can_create ORDER BY ou.create_at DESC),
        ARRAY_AGG(ou.can_read ORDER BY ou.create_at DESC),
        ARRAY_AGG(ou.can_update ORDER BY ou.create_at DESC),
        ARRAY_AGG(ou.can_delete ORDER BY ou.create_at DESC),
        ARRAY_AGG(ou.create_at ORDER BY ou.create_at DESC),
        ARRAY_AGG(ou.updated_at ORDER BY ou.create_at DESC)
    INTO 
        o_ids, o_first_names, o_last_names, o_emails, o_roles, o_is_actives,
        o_can_creates, o_can_reads, o_can_updates, o_can_deletes, o_create_ats, o_updated_ats
    FROM "ops".operations_user AS ou;
END;
$$;
--CALL ops.sp_get_operational_users(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- File: ops.sp_iris_login_user.sql
CREATE PROCEDURE ops.sp_iris_login_user(
    IN p_email TEXT,
    IN p_iris_refresh_token TEXT,
    OUT o_status BOOLEAN,
    OUT o_message TEXT,
    OUT o_user_id TEXT,
    OUT o_iris_email TEXT,
    OUT o_iris_password TEXT
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    o_status := FALSE;
    o_message := NULL;
    o_user_id := NULL;
    o_iris_email := NULL;
    o_iris_password := NULL;

    UPDATE "user"."user" AS u
       SET "irisRefreshToken" = COALESCE(p_iris_refresh_token, u."irisRefreshToken"),
           updated_at = CASE WHEN p_iris_refresh_token IS NOT NULL THEN CURRENT_TIMESTAMP ELSE u.updated_at END
     WHERE u.email = p_email
       AND u."irisEmail" IS NOT NULL
       AND u."irisPassword" IS NOT NULL
     RETURNING u.id, u."irisEmail", u."irisPassword"
          INTO o_user_id, o_iris_email, o_iris_password;

    IF NOT FOUND THEN
        IF NOT EXISTS (SELECT 1 FROM "user"."user" WHERE email = p_email) THEN
            o_message := 'User not found.';
        ELSE
            o_message := 'IRIS credentials not found. Complete IRIS registration first.';
        END IF;
        RETURN;
    END IF;

    o_status := TRUE;
    o_message := 'IRIS credentials found; use them to call the IRIS login API.';
END;
$procedure$;
-- CALL ops.sp_iris_login_user('brand_new_user@example.com', 'IRIS_REFRESH_TOKEN', NULL, NULL, NULL, NULL, NULL);

-- File: ops.sp_iris_refresh_token.sql

CREATE PROCEDURE ops.sp_iris_refresh_token(
    IN p_user_id TEXT,
    IN p_new_refresh_token TEXT,
    OUT o_status BOOLEAN,
    OUT o_message TEXT,
    OUT o_iris_email TEXT,
    OUT o_iris_password TEXT,
    OUT o_stored_refresh_token TEXT
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    o_status := FALSE;
    o_message := NULL;
    o_iris_email := NULL;
    o_iris_password := NULL;
    o_stored_refresh_token := NULL;

    IF p_user_id IS NULL THEN
        o_message := 'User not authenticated.';
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM payments.usersubscription us
         WHERE us.user_ref_id = p_user_id
           AND us.subscription_status = 'ACTIVE'
           AND us.end_date > CURRENT_TIMESTAMP
    ) THEN
        o_message := 'Active subscription required for IRIS access.';
        RETURN;
    END IF;

    UPDATE "user"."user" AS u
       SET "irisRefreshToken" = COALESCE(p_new_refresh_token, u."irisRefreshToken"),
           updated_at = CASE WHEN p_new_refresh_token IS NOT NULL THEN CURRENT_TIMESTAMP ELSE u.updated_at END
     WHERE u.id = p_user_id
     RETURNING u."irisEmail", u."irisPassword", u."irisRefreshToken"
          INTO o_iris_email, o_iris_password, o_stored_refresh_token;

    IF NOT FOUND THEN
        o_message := 'User not found.';
        RETURN;
    END IF;

    o_status := TRUE;
    o_message := 'Subscription is active; use returned token/credentials for the IRIS API flow.';
END;
$procedure$;
-- CALL ops.sp_iris_refresh_token('NUQI00000002', 'NEW_IRIS_REFRESH_TOKEN', NULL, NULL, NULL, NULL, NULL);

-- File: ops.sp_iris_register_user.sql
CREATE PROCEDURE ops.sp_iris_register_user(
    IN p_email TEXT,
    IN p_iris_email TEXT,
    IN p_iris_password TEXT,
    IN p_iris_refresh_token TEXT,
    OUT o_status BOOLEAN,
    OUT o_message TEXT,
    OUT o_user_id TEXT,
    OUT o_full_name TEXT
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    o_status := FALSE;
    o_message := NULL;
    o_user_id := NULL;
    o_full_name := NULL;

    IF NULLIF(BTRIM(p_email), '') IS NULL
       OR NULLIF(BTRIM(p_iris_email), '') IS NULL
       OR NULLIF(p_iris_password, '') IS NULL THEN
        o_message := 'Email and IRIS credentials are required.';
        RETURN;
    END IF;

    UPDATE "user"."user" AS u
       SET "irisEmail" = p_iris_email,
           "irisPassword" = p_iris_password,
           "irisRefreshToken" = p_iris_refresh_token,
           updated_at = CURRENT_TIMESTAMP
     WHERE u.email = p_email
     RETURNING u.id,
               BTRIM(COALESCE(u.first_name, '') || ' ' || COALESCE(u.last_name, ''))
          INTO o_user_id, o_full_name;

    IF NOT FOUND THEN
        o_message := 'User not found. Complete standard registration first.';
        RETURN;
    END IF;

    o_status := TRUE;
    o_message := 'IRIS credentials saved.';
END;
$procedure$;

-- CALL ops.sp_iris_register_user('brand_new_user@example.com', 'brand_new_user@example.com', 'IRIS_PASSWORD', 'IRIS_REFRESH_TOKEN', NULL, NULL, NULL, NULL);

-- File: ops.sp_login_operations_user.sql
CREATE OR REPLACE PROCEDURE ops.sp_login_operations_user(
    IN p_email VARCHAR(255),
    OUT o_id VARCHAR(50),
    OUT o_first_name VARCHAR(100),
    OUT o_last_name VARCHAR(100),
    OUT o_password VARCHAR(255),
    OUT o_role VARCHAR(50),
    OUT o_is_active BOOLEAN,
    OUT o_token_version INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Select data directly into the OUT parameters
    SELECT id, first_name, last_name, password, role::VARCHAR, is_active, token_version
    INTO o_id, o_first_name, o_last_name, o_password, o_role, o_is_active, o_token_version
    FROM ops.operations_user
    WHERE email = p_email;

    -- Validate user existence using the OUT parameter directly
    IF o_id IS NULL THEN
        RAISE EXCEPTION 'USER_NOT_FOUND';
    END IF;

    -- Validate if the user account is active
    IF o_is_active = FALSE THEN
        RAISE EXCEPTION 'USER_INACTIVE';
    END IF;
END;
$$;
--CALL ops.sp_login_operations_user('piyush.thakkar@nuqiwealth.com',NULL,NULL,NULL,NULL,NULL,NULL,NULL);

-- File: ops.sp_mark_admin_notifications_read.sql
-- PROCEDURE: ops.sp_mark_admin_notifications_read
-- Function: markAdminNotificationsRead
-- Prisma await: await prismaClient.adminNotification.updateMany(...)
-- Purpose: Atomic PostgreSQL write for Operations notification read state.
-- Point: Operations notification read state
-- Used by: Controller/service flow markAdminNotificationsRead() when replacing the matching Prisma write.
-- When p_id is NULL, marks all notifications for p_admin_email as read.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_admin_email varchar; p_id integer DEFAULT NULL
--   Code / route integration target: Code function: markAdminNotificationsRead | Route / flow: Controller/service
--     flow markAdminNotificationsRead() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.adminNotification.updateMany(...)
--   Full routes / trigger: PUT /operations/admin-notifications/read-all; PUT /operations/admin-notifications/:id/read
--     - mark notifications read
--   Related .js file(s): server_trade/controllers/operations/adminNotifications.controller.js;
--     server_trade/routes/operations/adminNotifications.routes.js
--   Integration point: Operations notification read state
--   Reason: Atomic PostgreSQL write for Operations notification read state.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "ops".sp_mark_admin_notifications_read(
    p_admin_email varchar,
    p_id integer DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "ops".adminnotification
    SET is_read = true,
        "updatedAt" = CURRENT_TIMESTAMP
    WHERE admin_email = p_admin_email
      AND (p_id IS NULL OR id = p_id)
      AND is_read = false;
END;
$procedure$;

-- File: ops.sp_ops_admin_validate_promo_code.sql
CREATE PROCEDURE ops.sp_ops_admin_validate_promo_code(
    IN p_code TEXT,
    IN p_user_id TEXT,
    IN p_plan_id TEXT,
    OUT data JSONB
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_promo catalog.promo_code%ROWTYPE;
    v_plan_price NUMERIC(19, 4);
    v_use_count BIGINT;
    v_discount NUMERIC(19, 2);
    v_final_amount NUMERIC(19, 2);
    v_now TIMESTAMP := CURRENT_TIMESTAMP;
BEGIN
    SELECT s.price
      INTO v_plan_price
      FROM payments.subscriptions s
     WHERE s.id = p_plan_id;

    IF NOT FOUND THEN
        data := jsonb_build_object('valid', FALSE, 'reason', 'Subscription plan not found');
        RETURN;
    END IF;

    SELECT pc.*
      INTO v_promo
      FROM catalog.promo_code pc
     WHERE UPPER(BTRIM(pc.code)) = UPPER(BTRIM(p_code))
     LIMIT 1;

    IF NOT FOUND THEN
        data := jsonb_build_object('valid', FALSE, 'reason', 'Promo code does not exist');
        RETURN;
    ELSIF NOT v_promo.is_active THEN
        data := jsonb_build_object('valid', FALSE, 'reason', 'Promo code is no longer active');
        RETURN;
    ELSIF v_now < v_promo.valid_from THEN
        data := jsonb_build_object('valid', FALSE, 'reason', 'Promo code is not yet active');
        RETURN;
    ELSIF v_now > v_promo.valid_till THEN
        data := jsonb_build_object('valid', FALSE, 'reason', 'Promo code has expired');
        RETURN;
    ELSIF v_promo.max_uses IS NOT NULL AND v_promo.current_uses >= v_promo.max_uses THEN
        data := jsonb_build_object('valid', FALSE, 'reason', 'Promo code has reached maximum uses');
        RETURN;
    END IF;

    SELECT COUNT(*)
      INTO v_use_count
      FROM catalog.promo_code_use pcu
     WHERE pcu.promo_code_id = v_promo.id
       AND pcu.user_id = p_user_id;

    IF v_use_count >= v_promo.max_uses_per_user THEN
        data := jsonb_build_object('valid', FALSE, 'reason', 'You have already used this promo code');
        RETURN;
    END IF;

    IF p_plan_id IS NOT NULL
       AND v_promo.applicable_plans IS NOT NULL
       AND NOT (v_promo.applicable_plans @> to_jsonb(p_plan_id)) THEN
        data := jsonb_build_object('valid', FALSE, 'reason', 'Promo code is not applicable to this plan');
        RETURN;
    END IF;

    IF v_promo.min_order_amount IS NOT NULL
       AND v_promo.min_order_amount <> 0
       AND v_plan_price < v_promo.min_order_amount THEN
        data := jsonb_build_object(
            'valid', FALSE,
            'reason', 'Minimum order amount is ' || v_promo.min_order_amount::TEXT
        );
        RETURN;
    END IF;

    IF v_promo.discount_type::TEXT = 'PERCENTAGE' THEN
        v_discount := v_plan_price * v_promo.discount_value / 100;
        IF v_promo.max_discount IS NOT NULL
           AND v_promo.max_discount <> 0
           AND v_discount > v_promo.max_discount THEN
            v_discount := v_promo.max_discount;
        END IF;
    ELSIF v_promo.discount_type::TEXT = 'FLAT' THEN
        v_discount := v_promo.discount_value;
    ELSE
        data := jsonb_build_object('valid', FALSE, 'reason', 'Unsupported promo discount type');
        RETURN;
    END IF;

    v_discount := ROUND(LEAST(v_discount, v_plan_price), 2);
    v_final_amount := ROUND(v_plan_price - v_discount, 2);

    data := jsonb_build_object(
        'valid', TRUE,
        'promo', jsonb_build_object(
            'id', v_promo.id,
            'code', v_promo.code,
            'discount_type', v_promo.discount_type::TEXT,
            'discount_value', v_promo.discount_value,
            'min_order_amount', v_promo.min_order_amount,
            'max_discount', v_promo.max_discount
        ),
        'original_amount', v_plan_price,
        'discount_amount', v_discount,
        'final_amount', v_final_amount
    );
END;
$procedure$;

-- CALL ops.sp_ops_admin_validate_promo_code('PROMO_CODE', '<USER_ID>', '<PLAN_ID>', NULL);

-- File: ops.sp_ops_apply_kyc_update.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_apply_kyc_update(
    IN p_user_id VARCHAR,
    IN p_update JSONB,
    OUT data JSONB -- Natively returns the affected KYC record details directly
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_user RECORD;
    v_kyc_id VARCHAR;
    v_status TEXT;
    v_template_id INTEGER;
    v_custom_reason TEXT;
    v_existing_kyc kyc.kyc%ROWTYPE;
    v_kyc_record kyc.kyc%ROWTYPE;
    
    -- Variables to hold cleansed inputs if they exist in payload
    v_dob TEXT;
    v_gender TEXT;
    v_aadhaar TEXT;
BEGIN
    -- 1. Input Validation
    SELECT id, email, first_name, last_name INTO v_user
      FROM "user"."user" WHERE id = p_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'User not found'; END IF;
    
    IF p_update IS NULL OR jsonb_typeof(p_update) <> 'object' THEN
        RAISE EXCEPTION 'KYC update payload must be a JSON object';
    END IF;

    v_status := p_update->>'status';
    v_template_id := NULLIF(p_update->>'templateId', '')::INTEGER;
    v_custom_reason := NULLIF(BTRIM(p_update->>'rejection_reason'), '');

    -- 2. Cleanse and Format fields only if present in payload
    IF p_update ? 'dob' THEN
        v_dob := CASE
            WHEN COALESCE(p_update->>'dob', '') = '' THEN NULL
            WHEN BTRIM(p_update->>'dob') ~ '^\d{4}-\d{2}-\d{2}' THEN SUBSTRING(BTRIM(p_update->>'dob') FROM 9 FOR 2) || '-' || SUBSTRING(BTRIM(p_update->>'dob') FROM 6 FOR 2) || '-' || SUBSTRING(BTRIM(p_update->>'dob') FROM 1 FOR 4)
            WHEN BTRIM(p_update->>'dob') ~ '^\d{2}[-/]\d{2}[-/]\d{4}$' THEN REPLACE(BTRIM(p_update->>'dob'), '/', '-')
            ELSE BTRIM(p_update->>'dob') 
        END;
    END IF;

    IF p_update ? 'gender' THEN
        v_gender := CASE UPPER(BTRIM(COALESCE(p_update->>'gender', '')))
            WHEN 'M' THEN 'Male' WHEN 'MALE' THEN 'Male' 
            WHEN 'F' THEN 'Female' WHEN 'FEMALE' THEN 'Female'
            WHEN 'T' THEN 'Transgender' WHEN 'TRANSGENDER' THEN 'Transgender' 
            WHEN 'OTHER' THEN 'Transgender' WHEN 'OTHERS' THEN 'Transgender' 
            WHEN '' THEN NULL 
            ELSE BTRIM(p_update->>'gender') 
        END;
    END IF;

    IF p_update ? 'aadhaarNumber' THEN
        v_aadhaar := CASE
            WHEN COALESCE(p_update->>'aadhaarNumber', '') = '' THEN NULL
            WHEN p_update->>'aadhaarNumber' ~ '[xX]' THEN p_update->>'aadhaarNumber'
            WHEN LENGTH(REGEXP_REPLACE(p_update->>'aadhaarNumber', '[[:space:]-]', '', 'g')) >= 4 THEN 'XXXX-XXXX-' || RIGHT(REGEXP_REPLACE(p_update->>'aadhaarNumber', '[[:space:]-]', '', 'g'), 4)
            ELSE p_update->>'aadhaarNumber' 
        END;
    END IF;

    -- 3. Check for existing KYC row
    SELECT * INTO v_existing_kyc FROM kyc.kyc WHERE "userId" = p_user_id LIMIT 1;

    IF v_existing_kyc.id IS NOT NULL THEN
        -- Run manual UPDATE simulation fallback
        UPDATE kyc.kyc SET
            "fullName" = CASE WHEN p_update ? 'fullName' THEN NULLIF(BTRIM(p_update->>'fullName'), '') ELSE v_existing_kyc."fullName" END,
            "panNumber" = CASE WHEN p_update ? 'panNumber' THEN NULLIF(UPPER(BTRIM(p_update->>'panNumber')), '') ELSE v_existing_kyc."panNumber" END,
            dob = CASE WHEN p_update ? 'dob' THEN v_dob ELSE v_existing_kyc.dob END,
            gender = CASE WHEN p_update ? 'gender' THEN v_gender ELSE v_existing_kyc.gender END,
            "aadhaarMaskedNumber" = CASE WHEN p_update ? 'aadhaarNumber' THEN v_aadhaar ELSE v_existing_kyc."aadhaarMaskedNumber" END,
            "addressText" = CASE WHEN p_update ? 'addressText' THEN NULLIF(BTRIM(p_update->>'addressText'), '') ELSE v_existing_kyc."addressText" END,
            "addressJson" = CASE WHEN p_update ? 'addressJson' THEN p_update->'addressJson' ELSE v_existing_kyc."addressJson" END,
            status = CASE WHEN p_update ? 'status' THEN v_status ELSE v_existing_kyc.status END,
            provider = CASE WHEN p_update ? 'provider' THEN p_update->>'provider' ELSE v_existing_kyc.provider END,
            rejection_reason = CASE WHEN p_update ? 'rejection_reason' THEN v_custom_reason ELSE v_existing_kyc.rejection_reason END,
            "verifiedAt" = CASE WHEN v_status = 'APPROVED' THEN CURRENT_TIMESTAMP ELSE v_existing_kyc."verifiedAt" END,
            "selfieImagePath" = COALESCE(p_update->'filePaths'->>'selfieImagePath', v_existing_kyc."selfieImagePath"),
            "livenessImagePath" = COALESCE(p_update->'filePaths'->>'livenessImagePath', v_existing_kyc."livenessImagePath"),
            "panCroppedImagePath" = COALESCE(p_update->'filePaths'->>'panCroppedImagePath', v_existing_kyc."panCroppedImagePath"),
            "eaadhaarPdfPath" = COALESCE(p_update->'filePaths'->>'eaadhaarPdfPath', v_existing_kyc."eaadhaarPdfPath"),
            "poiIdFaceImagePath" = COALESCE(p_update->'filePaths'->>'poiIdFaceImagePath', v_existing_kyc."poiIdFaceImagePath"),
            "aadhaarXmlPath" = COALESCE(p_update->'filePaths'->>'aadhaarXmlPath', v_existing_kyc."aadhaarXmlPath"),
            "aadhaarPhotoImagePath" = COALESCE(p_update->'filePaths'->>'aadhaarPhotoImagePath', v_existing_kyc."aadhaarPhotoImagePath"),
            "updatedAt" = CURRENT_TIMESTAMP
        WHERE id = v_existing_kyc.id
        RETURNING * INTO v_kyc_record;
        
        v_kyc_id := v_existing_kyc.id;
    ELSE
        -- Run standard clean INSERT statement logic
        v_kyc_id := md5(random()::text || clock_timestamp()::text);
        
        INSERT INTO kyc.kyc (
            id, "userId", "fullName", "panNumber", dob, gender, "aadhaarMaskedNumber",
            "addressText", "addressJson", status, provider, rejection_reason, "verifiedAt",
            "selfieImagePath", "livenessImagePath", "panCroppedImagePath", "eaadhaarPdfPath",
            "poiIdFaceImagePath", "aadhaarXmlPath", "aadhaarPhotoImagePath", "createdAt", "updatedAt"
        ) VALUES (
            v_kyc_id, p_user_id,
            CASE WHEN p_update ? 'fullName' THEN NULLIF(BTRIM(p_update->>'fullName'), '') END,
            CASE WHEN p_update ? 'panNumber' THEN NULLIF(UPPER(BTRIM(p_update->>'panNumber')), '') END,
            v_dob, v_gender, v_aadhaar,
            CASE WHEN p_update ? 'addressText' THEN NULLIF(BTRIM(p_update->>'addressText'), '') END,
            CASE WHEN p_update ? 'addressJson' THEN p_update->'addressJson' END,
            COALESCE(v_status, 'UNDER_REVIEW'), COALESCE(p_update->>'provider', 'MANUAL'), v_custom_reason,
            CASE WHEN v_status = 'APPROVED' THEN CURRENT_TIMESTAMP END,
            p_update->'filePaths'->>'selfieImagePath', p_update->'filePaths'->>'livenessImagePath',
            p_update->'filePaths'->>'panCroppedImagePath', p_update->'filePaths'->>'eaadhaarPdfPath',
            p_update->'filePaths'->>'poiIdFaceImagePath', p_update->'filePaths'->>'aadhaarXmlPath',
            p_update->'filePaths'->>'aadhaarPhotoImagePath', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        ) RETURNING * INTO v_kyc_record;
    END IF;

    -- 4. State updates across secondary table relations
    IF p_update ? 'status' THEN
        UPDATE "user"."user" SET is_kyc_verified = (v_status = 'APPROVED') WHERE id = p_user_id;
        
        IF v_status IN ('APPROVED', 'REJECTED') THEN
            DELETE FROM kyc.kyc_user_on_hold WHERE user_id = p_user_id;
        ELSIF v_status = 'On Hold' THEN
            -- Sync state fallback simulation to bypass conflict traps
            IF EXISTS (SELECT 1 FROM kyc.kyc_user_on_hold WHERE user_id = p_user_id) THEN
                UPDATE kyc.kyc_user_on_hold 
                   SET kyc_id = v_kyc_id, "templateId" = v_template_id, custom_reason = v_custom_reason, "updatedAt" = CURRENT_TIMESTAMP
                 WHERE user_id = p_user_id;
            ELSE
                INSERT INTO kyc.kyc_user_on_hold (user_id, kyc_id, "templateId", custom_reason, "createdAt", "updatedAt")
                VALUES (p_user_id, v_kyc_id, v_template_id, v_custom_reason, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
            END IF;
        END IF;
    END IF;

    -- 5. Format payload return output
    data := to_jsonb(v_kyc_record);
END;
$procedure$;
--CALL ops.sp_ops_apply_kyc_update('NUQI00000001','{"status":"REJECTED","rejection_reason":"Please resubmit documents"}'::jsonb,NULL::jsonb );

-- File: ops.sp_ops_build_kyc_templated_email.sql
CREATE PROCEDURE ops.sp_ops_build_kyc_templated_email(
    IN p_template_id INTEGER,
    IN p_user_name TEXT,
    OUT subject TEXT,
    OUT html TEXT
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_html TEXT;
BEGIN
    IF p_template_id IS NULL THEN
        subject := NULL;
        html := NULL;
        RETURN;
    END IF;
    SELECT rt.subject, rt.html_content INTO subject, v_html
      FROM catalog.reason_templates rt
     WHERE rt.id = p_template_id;
    IF NOT FOUND OR v_html IS NULL THEN
        subject := NULL;
        html := NULL;
        RETURN;
    END IF;
    html := REPLACE(REPLACE(REPLACE(v_html, '[Recipient''s Name]', COALESCE(p_user_name, '')),
                            '{{CustomerName}}', COALESCE(p_user_name, '')),
                            '{{Name}}', COALESCE(p_user_name, ''));
END;
$procedure$;
--CALL ops.sp_ops_build_kyc_templated_email(1, 'Investor Name', NULL, NULL);

-- File: ops.sp_ops_create_approval_request.sql
CREATE PROCEDURE ops.sp_ops_create_approval_request(
    IN p_module TEXT,
    IN p_action_type TEXT,
    IN p_entity_type TEXT,
    IN p_entity_id TEXT,
    IN p_payload JSONB,
    IN p_requested_by TEXT,
    IN p_requested_by_email TEXT,
    OUT data JSONB
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id TEXT;
BEGIN
    IF NULLIF(BTRIM(p_module), '') IS NULL
       OR NULLIF(BTRIM(p_action_type), '') IS NULL
       OR NULLIF(BTRIM(p_entity_type), '') IS NULL
       OR NULLIF(BTRIM(p_requested_by), '') IS NULL
       OR NULLIF(BTRIM(p_requested_by_email), '') IS NULL THEN
        RAISE EXCEPTION 'module, actionType, entityType, requestedBy, and requestedByEmail are required';
    END IF;

    IF p_payload IS NULL OR jsonb_typeof(p_payload) NOT IN ('object', 'array') THEN
        RAISE EXCEPTION 'payload must be a JSON object or array';
    END IF;

    v_id := REPLACE(gen_random_uuid()::TEXT, '-', '');

    INSERT INTO ops.approvalrequest (
        id,
        module,
        "actionType",
        "entityType",
        "entityId",
        payload,
        status,
        "requestedBy",
        "requestedByEmail",
        "createdAt"
    ) VALUES (
        v_id,
        p_module,
        p_action_type,
        p_entity_type,
        p_entity_id,
        p_payload,
        'PENDING',
        p_requested_by,
        p_requested_by_email,
        CURRENT_TIMESTAMP
    );

    data := jsonb_build_object('id', v_id);
END;
$procedure$;

-- Example CALL (replace sample values):
-- CALL ops.sp_ops_create_approval_request('allusers', 'USER_DELETE', 'User', '<USER_ID>', '{}'::jsonb,'<OPS_USER_ID>', 'admin@example.com', NULL);

-- File: ops.sp_ops_create_manual_kyc.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_create_manual_kyc(
    IN p_user_id VARCHAR,
    IN p_full_name VARCHAR,
    IN p_pan_number VARCHAR,
    IN p_dob TEXT,
    IN p_gender TEXT,
    IN p_aadhaar_number TEXT,
    IN p_address_text TEXT,
    IN p_address_json JSONB,
    IN p_status TEXT,
    IN p_provider TEXT,
    IN p_selfie_image_path TEXT,
    IN p_liveness_image_path TEXT,
    IN p_pan_cropped_image_path TEXT,
    IN p_eaadhaar_pdf_path TEXT,
    IN p_poi_id_face_image_path TEXT,
    IN p_aadhaar_xml_path TEXT,
    IN p_aadhaar_photo_image_path TEXT,
    OUT data JSONB
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_dob TEXT;
    v_gender TEXT;
    v_aadhaar TEXT;
    v_kyc_record kyc.kyc%ROWTYPE;
    v_existing_id VARCHAR;
BEGIN
    -- 1. Input Validation
    IF p_user_id IS NULL OR p_full_name IS NULL OR p_pan_number IS NULL THEN
        RAISE EXCEPTION 'userId, fullName, and panNumber are required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'User not found';
    END IF;

    -- 2. Data Cleansing & Formatting (DOB & Gender)
    v_dob := CASE
        WHEN p_dob IS NULL OR BTRIM(p_dob) = '' THEN NULL
        WHEN BTRIM(p_dob) ~ '^\d{4}-\d{2}-\d{2}' THEN
            SUBSTRING(BTRIM(p_dob) FROM 9 FOR 2) || '-' || SUBSTRING(BTRIM(p_dob) FROM 6 FOR 2) || '-' || SUBSTRING(BTRIM(p_dob) FROM 1 FOR 4)
        WHEN BTRIM(p_dob) ~ '^\d{2}[-/]\d{2}[-/]\d{4}$' THEN REPLACE(BTRIM(p_dob), '/', '-')
        ELSE BTRIM(p_dob)
    END;
    
    v_gender := CASE UPPER(BTRIM(COALESCE(p_gender, '')))
        WHEN 'M' THEN 'Male' WHEN 'MALE' THEN 'Male'
        WHEN 'F' THEN 'Female' WHEN 'FEMALE' THEN 'Female'
        WHEN 'T' THEN 'Transgender' WHEN 'TRANSGENDER' THEN 'Transgender'
        WHEN 'OTHER' THEN 'Transgender' WHEN 'OTHERS' THEN 'Transgender'
        WHEN '' THEN NULL ELSE BTRIM(p_gender)
    END;
    
    -- 3. Mask Aadhaar Number
    IF p_aadhaar_number IS NULL OR BTRIM(p_aadhaar_number) = '' THEN
        v_aadhaar := NULL;
    ELSIF p_aadhaar_number ~ '[xX]' THEN
        v_aadhaar := p_aadhaar_number;
    ELSIF LENGTH(REGEXP_REPLACE(p_aadhaar_number, '[[:space:]-]', '', 'g')) >= 4 THEN
        v_aadhaar := 'XXXX-XXXX-' || RIGHT(REGEXP_REPLACE(p_aadhaar_number, '[[:space:]-]', '', 'g'), 4);
    ELSE
        v_aadhaar := p_aadhaar_number;
    END IF;

    -- 4. Check for an existing KYC record for this user
    SELECT id INTO v_existing_id FROM kyc.kyc WHERE "userId" = p_user_id LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
        -- Record exists: Update it
        UPDATE kyc.kyc SET
            "fullName" = NULLIF(BTRIM(p_full_name), ''), 
            "panNumber" = UPPER(BTRIM(p_pan_number)), 
            dob = v_dob,
            gender = v_gender, 
            "aadhaarMaskedNumber" = v_aadhaar,
            "addressText" = NULLIF(BTRIM(p_address_text), ''), 
            "addressJson" = p_address_json,
            status = COALESCE(p_status, 'APPROVED'), 
            provider = COALESCE(p_provider, 'MANUAL'), 
            "verifiedAt" = CASE WHEN COALESCE(p_status, 'APPROVED') = 'APPROVED' THEN CURRENT_TIMESTAMP ELSE "verifiedAt" END,
            "selfieImagePath" = p_selfie_image_path, 
            "livenessImagePath" = p_liveness_image_path,
            "panCroppedImagePath" = p_pan_cropped_image_path, 
            "eaadhaarPdfPath" = p_eaadhaar_pdf_path,
            "poiIdFaceImagePath" = p_poi_id_face_image_path, 
            "aadhaarXmlPath" = p_aadhaar_xml_path,
            "aadhaarPhotoImagePath" = p_aadhaar_photo_image_path, 
            "updatedAt" = CURRENT_TIMESTAMP
        WHERE id = v_existing_id
        RETURNING * INTO v_kyc_record;
    ELSE
        -- No record found: Insert it
        INSERT INTO kyc.kyc (
            id, "userId", "fullName", "panNumber", dob, gender, "aadhaarMaskedNumber",
            "addressText", "addressJson", status, provider, "verifiedAt",
            "selfieImagePath", "livenessImagePath", "panCroppedImagePath", "eaadhaarPdfPath",
            "poiIdFaceImagePath", "aadhaarXmlPath", "aadhaarPhotoImagePath", "createdAt", "updatedAt"
        ) VALUES (
            md5(random()::text || clock_timestamp()::text), p_user_id,
            NULLIF(BTRIM(p_full_name), ''), UPPER(BTRIM(p_pan_number)), v_dob, v_gender, v_aadhaar,
            NULLIF(BTRIM(p_address_text), ''), p_address_json, COALESCE(p_status, 'APPROVED'),
            COALESCE(p_provider, 'MANUAL'), CASE WHEN COALESCE(p_status, 'APPROVED') = 'APPROVED' THEN CURRENT_TIMESTAMP END,
            p_selfie_image_path, p_liveness_image_path, p_pan_cropped_image_path, p_eaadhaar_pdf_path,
            p_poi_id_face_image_path, p_aadhaar_xml_path, p_aadhaar_photo_image_path, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        ) RETURNING * INTO v_kyc_record;
    END IF;

    -- 5. FIXED: Using native boolean values (TRUE / FALSE) to match your schema column type
    UPDATE "user"."user" 
    SET is_kyc_verified = (COALESCE(p_status, 'APPROVED') = 'APPROVED')
    WHERE id = p_user_id;

    -- 6. Pass output back to the single line editor window panel
    data := to_jsonb(v_kyc_record);
END;
$procedure$;
--CALL ops.sp_ops_create_manual_kyc(    'NUQI00000001', 'John Doe', 'ABCDE1234F', '1990-01-31', 'M', '1234 5678 2523', 'Sample Address', '{}'::jsonb, 'APPROVED', 'MANUAL', NULL, NULL, NULL, NULL, NULL, NULL, NULL,NULL::jsonb);

-- File: ops.sp_ops_describe_kyc_update.sql
CREATE PROCEDURE ops.sp_ops_describe_kyc_update(
    IN p_user_id VARCHAR,
    IN p_update JSONB,
    OUT status_before TEXT,
    OUT status_after TEXT,
    OUT action_reason TEXT
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_existing RECORD;
    v_lines TEXT[] := ARRAY[]::TEXT[];
    v_before TEXT;
    v_after TEXT;
    v_dob TEXT;
    v_gender TEXT;
    v_masked TEXT;
    v_doc TEXT;
BEGIN
    SELECT status, "fullName", "panNumber", dob, gender, "aadhaarMaskedNumber", "addressText", provider
      INTO v_existing FROM kyc.kyc WHERE "userId" = p_user_id;
    IF NOT FOUND THEN
        status_before := 'N/A';
    ELSE
        status_before := COALESCE(v_existing.status, 'N/A');
    END IF;
    status_after := CASE WHEN p_update ? 'status' THEN p_update->>'status' ELSE status_before END;

    IF p_update ? 'status' AND status_after IS DISTINCT FROM status_before THEN
        v_lines := array_append(v_lines, 'KYC Status: ' || status_before || ' → ' || status_after);
    END IF;

    IF p_update ? 'fullName' THEN
        v_before := NULLIF(v_existing."fullName", ''); v_after := NULLIF(BTRIM(p_update->>'fullName'), '');
        IF v_before IS DISTINCT FROM v_after THEN v_lines := array_append(v_lines, 'Full Name: ' || COALESCE(v_before, '—') || ' → ' || COALESCE(v_after, '—')); END IF;
    END IF;
    IF p_update ? 'panNumber' THEN
        v_before := NULLIF(v_existing."panNumber", ''); v_after := NULLIF(UPPER(BTRIM(p_update->>'panNumber')), '');
        IF v_before IS DISTINCT FROM v_after THEN v_lines := array_append(v_lines, 'PAN: ' || COALESCE(v_before, '—') || ' → ' || COALESCE(v_after, '—')); END IF;
    END IF;
    IF p_update ? 'dob' THEN
        v_before := v_existing.dob;
        IF p_update->>'dob' ~ '^\d{4}-\d{2}-\d{2}' THEN v_dob := SUBSTRING(p_update->>'dob' FROM 9 FOR 2) || '-' || SUBSTRING(p_update->>'dob' FROM 6 FOR 2) || '-' || SUBSTRING(p_update->>'dob' FROM 1 FOR 4);
        ELSIF p_update->>'dob' ~ '^\d{2}[-/]\d{2}[-/]\d{4}$' THEN v_dob := REPLACE(p_update->>'dob', '/', '-'); ELSE v_dob := NULLIF(BTRIM(p_update->>'dob'), ''); END IF;
        v_after := v_dob;
        IF v_before IS DISTINCT FROM v_after THEN v_lines := array_append(v_lines, 'Date of Birth: ' || COALESCE(v_before, '—') || ' → ' || COALESCE(v_after, '—')); END IF;
    END IF;
    IF p_update ? 'gender' THEN
        v_before := v_existing.gender;
        v_gender := CASE UPPER(BTRIM(COALESCE(p_update->>'gender', '')))
            WHEN 'M' THEN 'Male' WHEN 'MALE' THEN 'Male' WHEN 'F' THEN 'Female' WHEN 'FEMALE' THEN 'Female'
            WHEN 'T' THEN 'Transgender' WHEN 'TRANSGENDER' THEN 'Transgender' WHEN 'OTHER' THEN 'Transgender'
            WHEN 'OTHERS' THEN 'Transgender' WHEN '' THEN NULL ELSE BTRIM(p_update->>'gender') END;
        v_after := v_gender;
        IF v_before IS DISTINCT FROM v_after THEN v_lines := array_append(v_lines, 'Gender: ' || COALESCE(v_before, '—') || ' → ' || COALESCE(v_after, '—')); END IF;
    END IF;
    IF p_update ? 'aadhaarNumber' THEN
        v_before := v_existing."aadhaarMaskedNumber";
        v_masked := REGEXP_REPLACE(COALESCE(p_update->>'aadhaarNumber', ''), '[[:space:]-]', '', 'g');
        IF v_masked = '' THEN v_after := NULL;
        ELSIF v_masked ~ '[xX]' THEN v_after := p_update->>'aadhaarNumber';
        ELSIF LENGTH(v_masked) >= 4 THEN v_after := 'XXXX-XXXX-' || RIGHT(v_masked, 4);
        ELSE v_after := p_update->>'aadhaarNumber'; END IF;
        IF v_before IS DISTINCT FROM v_after THEN v_lines := array_append(v_lines, 'Aadhaar: ' || COALESCE(v_before, '—') || ' → ' || COALESCE(v_after, '—')); END IF;
    END IF;
    IF p_update ? 'addressText' THEN
        v_before := v_existing."addressText"; v_after := NULLIF(BTRIM(p_update->>'addressText'), '');
        IF v_before IS DISTINCT FROM v_after THEN v_lines := array_append(v_lines, 'Address: ' || COALESCE(v_before, '—') || ' → ' || COALESCE(v_after, '—')); END IF;
    END IF;
    IF p_update ? 'provider' THEN
        v_before := v_existing.provider; v_after := NULLIF(p_update->>'provider', '');
        IF v_before IS DISTINCT FROM v_after THEN v_lines := array_append(v_lines, 'Provider: ' || COALESCE(v_before, '—') || ' → ' || COALESCE(v_after, '—')); END IF;
    END IF;

    IF jsonb_typeof(p_update->'filePaths') = 'object' THEN
        FOR v_doc IN SELECT key FROM jsonb_each(p_update->'filePaths') LOOP
            v_lines := array_append(v_lines, 'Documents updated: ' || CASE v_doc
                WHEN 'selfieImagePath' THEN 'Selfie' WHEN 'aadhaarPhotoImagePath' THEN 'Aadhaar Photo'
                WHEN 'panCroppedImagePath' THEN 'PAN Image' WHEN 'eaadhaarPdfPath' THEN 'e-Aadhaar PDF'
                WHEN 'livenessImagePath' THEN 'Liveness Image' WHEN 'poiIdFaceImagePath' THEN 'POI Face Image'
                WHEN 'aadhaarXmlPath' THEN 'Aadhaar XML' ELSE v_doc END);
        END LOOP;
    END IF;
    IF NULLIF(p_update->>'rejection_reason', '') IS NOT NULL THEN
        v_lines := array_append(v_lines, 'Reason: ' || (p_update->>'rejection_reason'));
    END IF;

    action_reason := 'Update KYC' || E'\n' || COALESCE(array_to_string(v_lines, E'\n'), 'No changes');
END;
$procedure$;

-- CALL ops.sp_ops_describe_kyc_update('NUQI00000001', '{"status":"REJECTED"}'::jsonb, NULL, NULL, NULL);

-- File: ops.sp_ops_get_all_riskprofile.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_get_all_riskprofile(
    IN p_page INTEGER,
    IN p_limit INTEGER,
    IN p_search TEXT,
    IN p_search_field TEXT,
    IN p_start_date TIMESTAMP,
    IN p_end_date TIMESTAMP,
    IN p_fetch_all BOOLEAN,
    OUT p_profiles JSONB, -- Natively returns the array of matching records directly
    OUT p_total BIGINT     -- Natively returns the total matching count metrics natively
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_page INTEGER := GREATEST(COALESCE(p_page, 1), 1);
    v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 500);
    v_offset INTEGER;
BEGIN
    v_offset := (v_page - 1) * v_limit;

    -- 1. Calculate the overall count matching your query filters
    SELECT COUNT(*) INTO p_total
      FROM catalog.userriskprofile rp
      JOIN "user"."user" u ON u.id = rp.user_id
     WHERE (p_start_date IS NULL OR rp.created_at >= p_start_date)
       AND (p_end_date IS NULL OR rp.created_at <= p_end_date)
       AND NOT EXISTS (
           SELECT 1
             FROM unnest(string_to_array(COALESCE(p_search, ''), ',')) WITH ORDINALITY AS terms(term, idx)
             LEFT JOIN unnest(string_to_array(COALESCE(p_search_field, ''), ',')) WITH ORDINALITY AS fields(field, idx)
               ON fields.idx = terms.idx
            WHERE BTRIM(terms.term) <> ''
              AND NOT CASE LOWER(BTRIM(COALESCE(fields.field, '')))
                  WHEN 'nuqiid' THEN rp.user_id ILIKE '%' || BTRIM(terms.term) || '%'
                  WHEN 'name' THEN (COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                                 OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%')
                  WHEN 'email' THEN COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                  ELSE (rp.user_id ILIKE '%' || BTRIM(terms.term) || '%'
                     OR COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%')
              END
       );

    -- 2. Aggregate the full record set into a clean JSONB array block directly
    IF COALESCE(p_fetch_all, FALSE) THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(res)), '[]'::jsonb) INTO p_profiles
        FROM (
            SELECT rp.*,
                   u.id AS joined_user_id, u.email AS user_email,
                   u.first_name AS user_first_name, u.last_name AS user_last_name,
                   u.phone_number AS user_phone_number, u.is_risk_verified AS user_is_risk_verified,
                   u.is_deleted AS user_is_deleted,
                   rg.id AS risk_level_id, rg.risk_level AS risk_level_name,
                   rg.min_score AS risk_level_min_score, rg.max_score AS risk_level_max_score,
                   rg.description AS risk_level_description
              FROM catalog.userriskprofile rp
              JOIN "user"."user" u ON u.id = rp.user_id
              JOIN catalog.riskprofilescoregrid rg ON rg.id = rp.risk_profile_id
             WHERE (p_start_date IS NULL OR rp.created_at >= p_start_date)
               AND (p_end_date IS NULL OR rp.created_at <= p_end_date)
               AND NOT EXISTS (
                   SELECT 1
                     FROM unnest(string_to_array(COALESCE(p_search, ''), ',')) WITH ORDINALITY AS terms(term, idx)
                     LEFT JOIN unnest(string_to_array(COALESCE(p_search_field, ''), ',')) WITH ORDINALITY AS fields(field, idx)
                       ON fields.idx = terms.idx
                    WHERE BTRIM(terms.term) <> ''
                      AND NOT CASE LOWER(BTRIM(COALESCE(fields.field, '')))
                          WHEN 'nuqiid' THEN rp.user_id ILIKE '%' || BTRIM(terms.term) || '%'
                          WHEN 'name' THEN (COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                                         OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%')
                          WHEN 'email' THEN COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                          ELSE (rp.user_id ILIKE '%' || BTRIM(terms.term) || '%'
                             OR COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                             OR COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                             OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%')
                      END
               )
             ORDER BY rp.created_at DESC
        ) res;
    ELSE
        SELECT COALESCE(jsonb_agg(to_jsonb(res)), '[]'::jsonb) INTO p_profiles
        FROM (
            SELECT rp.*,
                   u.id AS joined_user_id, u.email AS user_email,
                   u.first_name AS user_first_name, u.last_name AS user_last_name,
                   u.phone_number AS user_phone_number, u.is_risk_verified AS user_is_risk_verified,
                   u.is_deleted AS user_is_deleted,
                   rg.id AS risk_level_id, rg.risk_level AS risk_level_name,
                   rg.min_score AS risk_level_min_score, rg.max_score AS risk_level_max_score,
                   rg.description AS risk_level_description
              FROM catalog.userriskprofile rp
              JOIN "user"."user" u ON u.id = rp.user_id
              JOIN catalog.riskprofilescoregrid rg ON rg.id = rp.risk_profile_id
             WHERE (p_start_date IS NULL OR rp.created_at >= p_start_date)
               AND (p_end_date IS NULL OR rp.created_at <= p_end_date)
               AND NOT EXISTS (
                   SELECT 1
                     FROM unnest(string_to_array(COALESCE(p_search, ''), ',')) WITH ORDINALITY AS terms(term, idx)
                     LEFT JOIN unnest(string_to_array(COALESCE(p_search_field, ''), ',')) WITH ORDINALITY AS fields(field, idx)
                       ON fields.idx = terms.idx
                    WHERE BTRIM(terms.term) <> ''
                      AND NOT CASE LOWER(BTRIM(COALESCE(fields.field, '')))
                          WHEN 'nuqiid' THEN rp.user_id ILIKE '%' || BTRIM(terms.term) || '%'
                          WHEN 'name' THEN (COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                                         OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%')
                          WHEN 'email' THEN COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                          ELSE (rp.user_id ILIKE '%' || BTRIM(terms.term) || '%'
                             OR COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                             OR COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                             OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%')
                      END
               )
             ORDER BY rp.created_at DESC
             LIMIT v_limit OFFSET v_offset
        ) res;
    END IF;
END;
$procedure$;

--CALL ops.sp_ops_get_all_riskprofile(1, 10, '', '', NULL, NULL, TRUE, NULL::jsonb, NULL);

-- File: ops.sp_ops_get_all_riskprofile_by_id.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_get_all_riskprofile_by_id(
    IN p_user_id VARCHAR,
    OUT p_profile JSONB,   -- Natively returns the user risk profile object directly
    OUT p_questions JSONB, -- Natively returns the list array of all risk questions
    OUT p_found BOOLEAN
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    -- 1. Check if the user has an existing risk profile (Fixed to exact lowercase schema naming)
    SELECT EXISTS (
        SELECT 1 FROM catalog.userriskprofile WHERE user_id = p_user_id
    ) INTO p_found;

    -- 2. Fetch user profile data directly into a JSONB object layout
    SELECT jsonb_build_object(
               'id', rp.id,
               'user_id', rp.user_id,
               'risk_profile_id', rp.risk_profile_id,
               'joined_user_id', u.id, 
               'user_email', u.email,
               'user_first_name', u.first_name, 
               'user_last_name', u.last_name,
               'user_phone_number', u.phone_number, 
               'user_is_risk_verified', u.is_risk_verified,
               'user_is_deleted', u.is_deleted,
               'risk_level_id', rg.id, 
               'risk_level_name', rg.risk_level,
               'risk_level_min_score', rg.min_score, 
               'risk_level_max_score', rg.max_score,
               'risk_level_description', rg.description
           ) INTO p_profile
      FROM catalog.userriskprofile rp
      JOIN "user"."user" u ON u.id = rp.user_id
      JOIN catalog.riskprofilescoregrid rg ON rg.id = rp.risk_profile_id
     WHERE rp.user_id = p_user_id
     LIMIT 1;

    -- 3. Aggregate all risk questions directly into a clean JSONB array block
    SELECT COALESCE(
        jsonb_agg(to_jsonb(q)), 
        '[]'::jsonb
    ) INTO p_questions
    FROM catalog.riskprofilequestions q;

END;
$procedure$;
--CALL ops.sp_ops_get_all_riskprofile_by_id('NUQI00000001', NULL::jsonb, NULL::jsonb, NULL);

-- File: ops.sp_ops_get_all_subscription_users.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_get_all_subscription_users(
    IN p_page INTEGER,
    IN p_limit INTEGER,
    IN p_search TEXT,
    IN p_search_field TEXT,
    IN p_status TEXT,
    IN p_plan_id TEXT,
    IN p_start_date TIMESTAMP,
    IN p_end_date TIMESTAMP,
    IN p_expiry_status TEXT,
    IN p_kyc_status TEXT,
    IN p_sort_by TEXT,
    IN p_sort_order TEXT,
    IN p_export_all BOOLEAN,
    INOUT p_rows REFCURSOR,
    OUT p_total BIGINT,
    OUT p_active BIGINT,
    OUT p_pending BIGINT,
    OUT p_failed BIGINT,
    OUT p_expired BIGINT,
    OUT p_expiring_soon BIGINT
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_page INTEGER := GREATEST(COALESCE(p_page, 1), 1);
    v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 10000);
    v_offset INTEGER;
    v_now TIMESTAMP := CURRENT_TIMESTAMP;
    v_thirty_days TIMESTAMP := CURRENT_TIMESTAMP + INTERVAL '30 days';
    v_sort TEXT := LOWER(COALESCE(p_sort_by, 'created_at'));
    v_desc BOOLEAN := LOWER(COALESCE(p_sort_order, 'desc')) <> 'asc';
BEGIN
    v_offset := (v_page - 1) * v_limit;

    SELECT COUNT(*) INTO p_total
      FROM payments.usersubscription us
      JOIN "user"."user" u ON u.id = us.user_ref_id
     WHERE (p_status IS NULL OR p_status = '' OR us.subscription_status::text = p_status)
       AND (p_plan_id IS NULL OR p_plan_id = '' OR us."subscriptionsId" = p_plan_id)
       AND (p_start_date IS NULL OR us.created_at >= p_start_date)
       AND (p_end_date IS NULL OR us.created_at <= p_end_date)
       AND (p_kyc_status IS NULL OR p_kyc_status = '' OR u.kyc_status = p_kyc_status)
       AND (p_expiry_status IS NULL OR p_expiry_status = ''
            OR (p_expiry_status = 'expiring_soon' AND us.end_date BETWEEN v_now AND v_thirty_days AND us.subscription_status::text = 'ACTIVE')
            OR (p_expiry_status = 'expired' AND us.end_date < v_now)
            OR (p_expiry_status = 'active' AND us.end_date >= v_now AND us.subscription_status::text = 'ACTIVE'))
       AND NOT EXISTS (
           SELECT 1
             FROM unnest(string_to_array(COALESCE(p_search, ''), ',')) WITH ORDINALITY AS terms(term, idx)
             LEFT JOIN unnest(string_to_array(COALESCE(p_search_field, ''), ',')) WITH ORDINALITY AS fields(field, idx)
               ON fields.idx = terms.idx
            WHERE BTRIM(terms.term) <> ''
              AND NOT CASE LOWER(BTRIM(COALESCE(fields.field, '')))
                  WHEN 'name' THEN (COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                                 OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%')
                  WHEN 'email' THEN COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                  WHEN 'nuqiid' THEN u.id ILIKE '%' || BTRIM(terms.term) || '%'
                  ELSE (COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR COALESCE(u.phone_number, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR COALESCE(u.customer_number, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR u.id ILIKE '%' || BTRIM(terms.term) || '%')
              END
       );

    -- Summary values use the same base filters, with each metric's status/expiry condition applied.
    SELECT COUNT(*) FILTER (WHERE us.subscription_status::text = 'ACTIVE' AND us.end_date >= v_now),
           COUNT(*) FILTER (WHERE us.subscription_status::text = 'PENDING'),
           COUNT(*) FILTER (WHERE us.subscription_status::text = 'FAILED'),
           COUNT(*) FILTER (WHERE us.end_date < v_now),
           COUNT(*) FILTER (WHERE us.end_date BETWEEN v_now AND v_thirty_days)
      INTO p_active, p_pending, p_failed, p_expired, p_expiring_soon
      FROM payments.usersubscription us
      JOIN "user"."user" u ON u.id = us.user_ref_id
     WHERE (p_plan_id IS NULL OR p_plan_id = '' OR us."subscriptionsId" = p_plan_id)
       AND (p_start_date IS NULL OR us.created_at >= p_start_date)
       AND (p_end_date IS NULL OR us.created_at <= p_end_date)
       AND (p_kyc_status IS NULL OR p_kyc_status = '' OR u.kyc_status = p_kyc_status)
       AND NOT EXISTS (
           SELECT 1
             FROM unnest(string_to_array(COALESCE(p_search, ''), ',')) WITH ORDINALITY AS terms(term, idx)
             LEFT JOIN unnest(string_to_array(COALESCE(p_search_field, ''), ',')) WITH ORDINALITY AS fields(field, idx)
               ON fields.idx = terms.idx
            WHERE BTRIM(terms.term) <> ''
              AND NOT CASE LOWER(BTRIM(COALESCE(fields.field, '')))
                  WHEN 'name' THEN (COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                                 OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%')
                  WHEN 'email' THEN COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                  WHEN 'nuqiid' THEN u.id ILIKE '%' || BTRIM(terms.term) || '%'
                  ELSE (COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR COALESCE(u.phone_number, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR COALESCE(u.customer_number, '') ILIKE '%' || BTRIM(terms.term) || '%'
                     OR u.id ILIKE '%' || BTRIM(terms.term) || '%')
              END
       );

    OPEN p_rows FOR
        SELECT us.id AS subscription_user_id,
               u.id AS user_id, u.first_name, u.last_name, u.email, u.phone_number,
               u.customer_number, u.kyc_status, u.is_kyc_verified,
               u.created_at AS user_created_at,
               s.id AS plan_id, s.name AS plan_name, s.price AS plan_price, s.is_nuclear,
               us.subscription_status, us.transaction_status, us.amount,
               us.start_date, us.end_date,
               CEIL(EXTRACT(EPOCH FROM (us.end_date - v_now)) / 86400)::INTEGER AS days_remaining,
               (us.end_date < v_now) AS is_expired,
               (us.end_date > v_now AND us.end_date <= v_thirty_days) AS is_expiring_soon,
               us.trace_id, us.created_at, us.update_at AS updated_at,
               COUNT(st.id) AS total_transactions,
               COUNT(st.id) FILTER (WHERE st.transaction_status::text = 'SUCCESS') AS successful_transactions
          FROM payments.usersubscription us
          JOIN "user"."user" u ON u.id = us.user_ref_id
          LEFT JOIN payments.subscriptions s ON s.id = us."subscriptionsId"
          LEFT JOIN payments.subscriptiontransaction st ON st.user_subscription_id = us.id
         WHERE (p_status IS NULL OR p_status = '' OR us.subscription_status::text = p_status)
           AND (p_plan_id IS NULL OR p_plan_id = '' OR us."subscriptionsId" = p_plan_id)
           AND (p_start_date IS NULL OR us.created_at >= p_start_date)
           AND (p_end_date IS NULL OR us.created_at <= p_end_date)
           AND (p_kyc_status IS NULL OR p_kyc_status = '' OR u.kyc_status = p_kyc_status)
           AND (p_expiry_status IS NULL OR p_expiry_status = ''
                OR (p_expiry_status = 'expiring_soon' AND us.end_date BETWEEN v_now AND v_thirty_days AND us.subscription_status::text = 'ACTIVE')
                OR (p_expiry_status = 'expired' AND us.end_date < v_now)
                OR (p_expiry_status = 'active' AND us.end_date >= v_now AND us.subscription_status::text = 'ACTIVE'))
           AND NOT EXISTS (
               SELECT 1
                 FROM unnest(string_to_array(COALESCE(p_search, ''), ',')) WITH ORDINALITY AS terms(term, idx)
                 LEFT JOIN unnest(string_to_array(COALESCE(p_search_field, ''), ',')) WITH ORDINALITY AS fields(field, idx)
                   ON fields.idx = terms.idx
                WHERE BTRIM(terms.term) <> ''
                  AND NOT CASE LOWER(BTRIM(COALESCE(fields.field, '')))
                      WHEN 'name' THEN (COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                                     OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%')
                      WHEN 'email' THEN COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                      WHEN 'nuqiid' THEN u.id ILIKE '%' || BTRIM(terms.term) || '%'
                      ELSE (COALESCE(u.first_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                         OR COALESCE(u.last_name, '') ILIKE '%' || BTRIM(terms.term) || '%'
                         OR COALESCE(u.email, '') ILIKE '%' || BTRIM(terms.term) || '%'
                         OR COALESCE(u.phone_number, '') ILIKE '%' || BTRIM(terms.term) || '%'
                         OR COALESCE(u.customer_number, '') ILIKE '%' || BTRIM(terms.term) || '%'
                         OR u.id ILIKE '%' || BTRIM(terms.term) || '%')
                  END
           )
         GROUP BY us.id, u.id, s.id
         ORDER BY
             CASE WHEN v_sort = 'created_at' AND v_desc THEN us.created_at END DESC,
             CASE WHEN v_sort = 'created_at' AND NOT v_desc THEN us.created_at END ASC,
             CASE WHEN v_sort = 'start_date' AND v_desc THEN us.start_date END DESC,
             CASE WHEN v_sort = 'start_date' AND NOT v_desc THEN us.start_date END ASC,
             CASE WHEN v_sort = 'end_date' AND v_desc THEN us.end_date END DESC,
             CASE WHEN v_sort = 'end_date' AND NOT v_desc THEN us.end_date END ASC,
             CASE WHEN v_sort = 'amount' AND v_desc THEN us.amount END DESC,
             CASE WHEN v_sort = 'amount' AND NOT v_desc THEN us.amount END ASC,
             CASE WHEN v_sort = 'subscription_status' AND v_desc THEN us.subscription_status::text END DESC,
             CASE WHEN v_sort = 'subscription_status' AND NOT v_desc THEN us.subscription_status::text END ASC,
             us.created_at DESC
         LIMIT CASE WHEN COALESCE(p_export_all, FALSE) THEN NULL ELSE v_limit END
         OFFSET CASE WHEN COALESCE(p_export_all, FALSE) THEN 0 ELSE v_offset END;
END;
$procedure$;

-- CALL ops.sp_ops_get_all_subscription_users(1, 50, '', '', NULL, NULL, NULL, NULL, NULL, NULL, 'created_at', 'desc', FALSE, 'subscription_users_cur', NULL, NULL, NULL, NULL, NULL, NULL);

-- File: ops.sp_ops_get_assignee_for_login.sql

CREATE OR REPLACE PROCEDURE ops.sp_ops_get_assignee_for_login(
    IN p_email VARCHAR(191),
    OUT data JSON
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT json_build_object(
        'id', id,
        'email', email,
        'name', name,
        'role', role,
        'department', department,
        'isActive', "isActive",
        'password', password
    )
      INTO data
      FROM support.ticketassignee
     WHERE email = p_email
     LIMIT 1;
END;
$$;
--CALL ops.sp_ops_get_assignee_for_login('sachin@gmail.com', NULL);

-- File: ops.sp_ops_get_current_admin.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_get_current_admin(
    IN p_admin_id VARCHAR(191),
    OUT data JSON
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT json_build_object(
        'id', id,
        'first_name', first_name,
        'last_name', last_name,
        'email', email,
        'role', role,
        'is_active', is_active,
        'menu_access', menu_access,
        'can_create', can_create,
        'can_read', can_read,
        'can_update', can_update,
        'can_delete', can_delete
    )
      INTO data
      FROM ops.operations_user
     WHERE id = p_admin_id
     LIMIT 1;
END;
$$;
-- CALL ops.sp_ops_get_current_admin('<ADMIN_ID>', NULL);

-- File: ops.sp_ops_get_kyc_records.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_get_kyc_records(
    IN p_page INTEGER,
    IN p_limit INTEGER,
    IN p_search TEXT,
    OUT p_records JSONB, -- Returns the array of matching records natively
    OUT total BIGINT     -- Returns the total record count value natively
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_page INTEGER := GREATEST(COALESCE(p_page, 1), 1);
    v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 500);
    v_offset INTEGER;
BEGIN
    v_offset := (v_page - 1) * v_limit;

    -- 1. Calculate the overall count matching your query filters
    SELECT COUNT(*) INTO total
      FROM kyc.kyc k
      JOIN "user"."user" u ON u.id = k."userId"
     WHERE COALESCE(p_search, '') = ''
        OR k."userId" ILIKE '%' || p_search || '%'
        OR COALESCE(u.email, '') ILIKE '%' || p_search || '%'
        OR COALESCE(u.first_name, '') ILIKE '%' || p_search || '%'
        OR COALESCE(u.last_name, '') ILIKE '%' || p_search || '%'
        OR COALESCE(k."panNumber", '') ILIKE '%' || p_search || '%'
        OR COALESCE(k."fullName", '') ILIKE '%' || p_search || '%';

    -- 2. Aggregate the full record set into a clean JSONB array block directly
    SELECT COALESCE(
        jsonb_agg(
            to_jsonb(k_res)
        ), 
        '[]'::jsonb
    ) INTO p_records
    FROM (
        SELECT k.*,
               u.id AS joined_user_id,
               u.email AS user_email,
               u.first_name AS user_first_name,
               u.last_name AS user_last_name,
               u.is_kyc_verified AS user_is_kyc_verified,
               u.created_at AS user_created_at
          FROM kyc.kyc k
          JOIN "user"."user" u ON u.id = k."userId"
         WHERE COALESCE(p_search, '') = ''
            OR k."userId" ILIKE '%' || p_search || '%'
            OR COALESCE(u.email, '') ILIKE '%' || p_search || '%'
            OR COALESCE(u.first_name, '') ILIKE '%' || p_search || '%'
            OR COALESCE(u.last_name, '') ILIKE '%' || p_search || '%'
            OR COALESCE(k."panNumber", '') ILIKE '%' || p_search || '%'
            OR COALESCE(k."fullName", '') ILIKE '%' || p_search || '%'
         ORDER BY k."createdAt" DESC
         LIMIT v_limit OFFSET v_offset
    ) k_res;

END;
$procedure$;

--CALL ops.sp_ops_get_kyc_records(1, 10, '', NULL::jsonb, NULL);

-- File: ops.sp_ops_get_subscription_analytics.sql
CREATE PROCEDURE ops.sp_ops_get_subscription_analytics(
    IN p_start_date TIMESTAMP,
    IN p_end_date TIMESTAMP,
    INOUT p_plan_distribution REFCURSOR,
    INOUT p_monthly_trends REFCURSOR,
    OUT p_total_active BIGINT,
    OUT p_total_revenue NUMERIC,
    OUT p_monthly_revenue NUMERIC,
    OUT p_expiring_soon BIGINT,
    OUT p_conversion_rate NUMERIC,
    OUT p_failed BIGINT,
    OUT p_pending BIGINT
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_now TIMESTAMP := CURRENT_TIMESTAMP;
BEGIN
    SELECT COUNT(*) INTO p_total_active FROM payments.usersubscription
     WHERE subscription_status::text = 'ACTIVE' AND end_date >= v_now
       AND (p_start_date IS NULL OR created_at >= p_start_date)
       AND (p_end_date IS NULL OR created_at <= p_end_date);
    SELECT COALESCE(SUM(amount), 0) INTO p_total_revenue FROM payments.usersubscription
     WHERE subscription_status::text = 'ACTIVE'
       AND (p_start_date IS NULL OR created_at >= p_start_date)
       AND (p_end_date IS NULL OR created_at <= p_end_date);
    SELECT COALESCE(SUM(amount), 0) INTO p_monthly_revenue FROM payments.usersubscription
     WHERE subscription_status::text = 'ACTIVE' AND created_at >= v_now - INTERVAL '30 days';
    SELECT COUNT(*) INTO p_expiring_soon FROM payments.usersubscription
     WHERE subscription_status::text = 'ACTIVE' AND end_date BETWEEN v_now AND v_now + INTERVAL '30 days';
    SELECT COUNT(*) INTO p_failed FROM payments.usersubscription WHERE subscription_status::text = 'FAILED';
    SELECT COUNT(*) INTO p_pending FROM payments.usersubscription WHERE subscription_status::text = 'PENDING';
    SELECT CASE WHEN COUNT(*) = 0 THEN 0
                ELSE ROUND(COUNT(*) FILTER (WHERE subscription_status::text = 'ACTIVE')::NUMERIC * 100 / COUNT(*), 2)
           END INTO p_conversion_rate
      FROM payments.usersubscription
     WHERE (p_start_date IS NULL OR created_at >= p_start_date)
       AND (p_end_date IS NULL OR created_at <= p_end_date);

    OPEN p_plan_distribution FOR
        SELECT us."subscriptionsId" AS plan_id, s.name AS plan_name, s.price,
               COUNT(us.id) AS subscription_count
          FROM payments.usersubscription us
          LEFT JOIN payments.subscriptions s ON s.id = us."subscriptionsId"
         WHERE us.subscription_status::text = 'ACTIVE' AND us.end_date >= v_now
         GROUP BY us."subscriptionsId", s.name, s.price
         ORDER BY subscription_count DESC;

    OPEN p_monthly_trends FOR
        SELECT date_trunc('month', created_at)::DATE AS month_start,
               COUNT(id) AS subscriptions,
               COALESCE(SUM(amount), 0) AS revenue
          FROM payments.usersubscription
         WHERE subscription_status::text = 'ACTIVE'
           AND created_at >= date_trunc('month', v_now) - INTERVAL '5 months'
           AND created_at < date_trunc('month', v_now) + INTERVAL '1 month'
         GROUP BY date_trunc('month', created_at)
         ORDER BY month_start;
END;
$procedure$;

-- CALL ops.sp_ops_get_subscription_analytics(NULL, NULL, 'plan_distribution_cur', 'monthly_trends_cur', NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- File: ops.sp_ops_get_user_subscription_details.sql
CREATE PROCEDURE ops.sp_ops_get_user_subscription_details(
    IN p_user_id VARCHAR,
    INOUT p_user_cursor REFCURSOR,
    INOUT p_subscriptions_cursor REFCURSOR,
    INOUT p_features_cursor REFCURSOR,
    OUT p_user_found BOOLEAN,
    OUT p_total_subscriptions BIGINT,
    OUT p_total_spent NUMERIC
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    SELECT EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_user_id) INTO p_user_found;
    SELECT COUNT(*), COALESCE(SUM(CASE WHEN subscription_status::text = 'ACTIVE' THEN amount ELSE 0 END), 0)
      INTO p_total_subscriptions, p_total_spent
      FROM payments.usersubscription WHERE user_ref_id = p_user_id;

    OPEN p_user_cursor FOR
        SELECT id, first_name, last_name, email, phone_number, customer_number,
               kyc_status, is_kyc_verified, created_at
          FROM "user"."user" WHERE id = p_user_id;

    OPEN p_subscriptions_cursor FOR
        SELECT us.id AS subscription_user_id, us.user_ref_id, us."subscriptionsId",
               us.plan_name, us.amount, us.subscription_status, us.transaction_status,
               us.start_date, us.end_date,
               CEIL(EXTRACT(EPOCH FROM (us.end_date - CURRENT_TIMESTAMP)) / 86400)::INTEGER AS days_remaining,
               (us.end_date < CURRENT_TIMESTAMP) AS is_expired,
               us.trace_id, us.created_at, us.update_at,
               s.id AS plan_id, s.name AS plan_name_current, s.price AS plan_price, s.is_nuclear,
               st.id AS transaction_record_id, st.transaction_id, st.order_id,
               st.transaction_status AS payment_status, st.trace_id AS transaction_trace_id,
               st.created_at AS transaction_created_at, st.update_at AS transaction_updated_at
          FROM payments.usersubscription us
          LEFT JOIN payments.subscriptions s ON s.id = us."subscriptionsId"
          LEFT JOIN payments.subscriptiontransaction st ON st.user_subscription_id = us.id
         WHERE us.user_ref_id = p_user_id
         ORDER BY us.created_at DESC, st.created_at DESC;

    OPEN p_features_cursor FOR
        SELECT * FROM catalog.subscriptionfeature WHERE user_ref_id = p_user_id;
END;
$procedure$;

-- CALL ops.sp_ops_get_user_subscription_details('NUQI00000001', 'user_cur', 'user_subscriptions_cur', 'subscription_features_cur', NULL, NULL, NULL);

-- File: ops.sp_ops_logout_all_operations.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_logout_all_operations(
    IN p_admin_id VARCHAR(191)
)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE ops.operations_user
       SET token_version = token_version + 1
     WHERE id = p_admin_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Admin not found';
    END IF;

    UPDATE "user".refreshtoken
       SET revoked = 1,
           "revokedAt" = CURRENT_TIMESTAMP,
           "revokedReason" = 'force_logout'
     WHERE "userId" = p_admin_id
       AND "userType" = 'admin';
END;
$$;
--CALL ops.sp_ops_logout_all_operations('NUQIADMIN887766554');

-- File: ops.sp_ops_logout_operations.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_logout_operations(
    IN p_token_hash VARCHAR(64)
)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE "user".refreshtoken
       SET revoked = 1,
           "revokedAt" = CURRENT_TIMESTAMP,
           "revokedReason" = 'logout'
     WHERE "tokenHash" = p_token_hash;
END;
$$;
--CALL ops.sp_ops_logout_operations('32410da57ab6b4b8b6559a8dfb5331cl375c81d571db5020f2b6d94468bs302B');

-- File: ops.sp_ops_mf_get_user_bank.sql

CREATE PROCEDURE ops.sp_ops_mf_get_user_bank(IN p_user_id VARCHAR, INOUT p_result REFCURSOR)
LANGUAGE plpgsql AS $procedure$
BEGIN
    OPEN p_result FOR
        SELECT c.account_no_1, c.ifsc_code_1, c.bank_dtl_response,
               c.bank_dtl_status, c.bank_dtl_error_remark, o.step5_data
          FROM trade.nse_mf_ucc c
          FULL JOIN trade.nse_mf_onboarding o ON o.user_ref_id = c.user_ref_id
         WHERE COALESCE(c.user_ref_id, o.user_ref_id) = p_user_id;
END;
$procedure$;
-- CALL ops.sp_ops_mf_get_user_bank('<USER_ID>', 'mf_bank_cur');

-- File: ops.sp_ops_mf_get_user_fatca.sql
CREATE PROCEDURE ops.sp_ops_mf_get_user_fatca(IN p_user_id VARCHAR, INOUT p_result REFCURSOR)
LANGUAGE plpgsql AS $procedure$
BEGIN
    OPEN p_result FOR
        SELECT fatca_submitted, fatca_request_payload, fatca_nse_response,
               fatca_status, fatca_reg_id, fatca_reg_status, fatca_reg_remark
          FROM trade.nse_mf_ucc WHERE user_ref_id = p_user_id;
END;
$procedure$;


-- CALL ops.sp_ops_mf_get_user_fatca('<USER_ID>', 'mf_fatca_cur');

-- File: ops.sp_ops_mf_get_user_kyc.sql
CREATE PROCEDURE ops.sp_ops_mf_get_user_kyc(IN p_user_id VARCHAR, INOUT p_result REFCURSOR)
LANGUAGE plpgsql AS $procedure$
BEGIN
    OPEN p_result FOR
        SELECT kyc_check_response, kyc_status, kyc_status_remark, primary_holder_pan
          FROM trade.nse_mf_ucc WHERE user_ref_id = p_user_id;
END;
$procedure$;

-- CALL ops.sp_ops_mf_get_user_kyc('NUQI00000001', 'mf_kyc_cur');

-- File: ops.sp_ops_mf_get_user_mandates.sql

CREATE PROCEDURE ops.sp_ops_mf_get_user_mandates(IN p_user_id VARCHAR, INOUT p_result REFCURSOR)
LANGUAGE plpgsql AS $procedure$
BEGIN
    OPEN p_result FOR
        SELECT * FROM trade.nse_mf_mandate
         WHERE user_ref_id = p_user_id ORDER BY created_at DESC;
END;
$procedure$;
-- CALL ops.sp_ops_mf_get_user_mandates('<USER_ID>', 'mf_mandates_cur');

-- File: ops.sp_ops_mf_get_user_onboarding.sql
CREATE PROCEDURE ops.sp_ops_mf_get_user_onboarding(IN p_user_id VARCHAR, INOUT p_result REFCURSOR)
LANGUAGE plpgsql AS $procedure$
BEGIN
    OPEN p_result FOR SELECT * FROM trade.nse_mf_onboarding WHERE user_ref_id = p_user_id;
END;
$procedure$;

-- CALL ops.sp_ops_mf_get_user_onboarding('NUQI00000001', 'mf_onboarding_cur');

-- File: ops.sp_ops_mf_get_user_orders.sql


CREATE PROCEDURE ops.sp_ops_mf_get_user_orders(IN p_user_id VARCHAR, INOUT p_result REFCURSOR)
LANGUAGE plpgsql AS $procedure$
BEGIN
    OPEN p_result FOR
        SELECT * FROM trade.nse_mf_order
         WHERE user_ref_id = p_user_id ORDER BY created_at DESC;
END;
$procedure$;

-- CALL ops.sp_ops_mf_get_user_orders('<USER_ID>', 'mf_orders_cur');

-- File: ops.sp_ops_mf_get_user_ucc.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_mf_get_user_ucc(
    IN p_user_id VARCHAR,
    OUT p_result JSONB -- Natively returns the UCC record details directly
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_record RECORD;
BEGIN
    -- Fetch the UCC details for the specific user matching your exact filter
    SELECT * INTO v_record 
      FROM trade.nse_mf_ucc 
     WHERE user_ref_id = p_user_id 
     LIMIT 1;

    -- Map the result row into a clean JSONB payload object
    IF v_record.user_ref_id IS NOT NULL THEN
        p_result := to_jsonb(v_record);
    ELSE
        p_result := NULL; -- Returns NULL if no UCC row exists for the user
    END IF;
END;
$procedure$;


-- call ops.sp_ops_mf_get_user_ucc('NUQI00000001', NULL::jsonb);

-- File: ops.sp_ops_mf_get_users.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_mf_get_users(
    IN p_page INTEGER,
    IN p_limit INTEGER,
    IN p_search TEXT,
    IN p_search_field TEXT,
    IN p_onboarding_status TEXT,
    OUT p_result JSONB, 
    OUT p_total BIGINT   
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_page INTEGER := GREATEST(COALESCE(p_page, 1), 1);
    v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 500);
    v_offset INTEGER;
    v_term TEXT := NULLIF(BTRIM(p_search), '');
    v_field TEXT := LOWER(NULLIF(BTRIM(p_search_field), ''));
BEGIN
    v_offset := (v_page - 1) * v_limit;
    
    -- 1. Calculate the overall count matching your query filters
    SELECT COUNT(*) INTO p_total
      FROM "user"."user" u
      LEFT JOIN trade.nse_mf_onboarding o ON o.user_ref_id = u.id
      LEFT JOIN kyc.kyc k ON k."userId" = u.id
     WHERE (p_onboarding_status IS NULL OR p_onboarding_status = '' OR o.onboarding_status = p_onboarding_status)
       AND (v_term IS NULL
         OR (v_field = 'name' AND (COALESCE(u.first_name, '') ILIKE '%' || v_term || '%' OR COALESCE(u.last_name, '') ILIKE '%' || v_term || '%'))
         OR (v_field = 'email' AND COALESCE(u.email, '') ILIKE '%' || v_term || '%')
         OR (v_field = 'pan' AND COALESCE(k."panNumber", '') ILIKE '%' || v_term || '%')
         OR ((v_field IS NULL OR v_field = '' OR v_field = 'all fields')
             AND (COALESCE(u.first_name, '') ILIKE '%' || v_term || '%'
               OR COALESCE(u.last_name, '') ILIKE '%' || v_term || '%'
               OR COALESCE(u.email, '') ILIKE '%' || v_term || '%'
               OR COALESCE(k."panNumber", '') ILIKE '%' || v_term || '%')));

    -- 2. Aggregate the full record set into a clean JSONB array block directly
    SELECT COALESCE(
        jsonb_agg(
            to_jsonb(res)
        ), 
        '[]'::jsonb
    ) INTO p_result
    FROM (
        SELECT u.id, u.first_name, u.last_name, u.email, u.created_at,
               k."panNumber" AS pan,
               o.onboarding_status, o.current_step, o.created_at AS mf_created_at,
               c.ucc_status, c.fatca_status, c.client_code
          FROM "user"."user" u
          LEFT JOIN trade.nse_mf_onboarding o ON o.user_ref_id = u.id
          LEFT JOIN kyc.kyc k ON k."userId" = u.id
          LEFT JOIN trade.nse_mf_ucc c ON c.user_ref_id = u.id
         WHERE (p_onboarding_status IS NULL OR p_onboarding_status = '' OR o.onboarding_status = p_onboarding_status)
           AND (v_term IS NULL
             OR (v_field = 'name' AND (COALESCE(u.first_name, '') ILIKE '%' || v_term || '%' OR COALESCE(u.last_name, '') ILIKE '%' || v_term || '%'))
             OR (v_field = 'email' AND COALESCE(u.email, '') ILIKE '%' || v_term || '%')
             OR (v_field = 'pan' AND COALESCE(k."panNumber", '') ILIKE '%' || v_term || '%')
             OR ((v_field IS NULL OR v_field = '' OR v_field = 'all fields')
                 AND (COALESCE(u.first_name, '') ILIKE '%' || v_term || '%'
                   OR COALESCE(u.last_name, '') ILIKE '%' || v_term || '%'
                   OR COALESCE(u.email, '') ILIKE '%' || v_term || '%'
                   OR COALESCE(k."panNumber", '') ILIKE '%' || v_term || '%'))) -- FIXED: Removed premature semicolon here
         ORDER BY u.created_at DESC
         LIMIT v_limit OFFSET v_offset
    ) res;

END;
$procedure$;

--CALL ops.sp_ops_mf_get_users(1, 20, '', '', NULL, NULL::jsonb, NULL);

-- File: ops.sp_ops_mf_refresh_ucc_status.sql
CREATE PROCEDURE ops.sp_ops_mf_refresh_ucc_status(
    IN p_user_id VARCHAR,
    IN p_nse_response JSONB,
    IN p_new_status TEXT,
    INOUT p_result REFCURSOR
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_previous_status TEXT;
BEGIN
    SELECT ucc_status INTO v_previous_status
      FROM trade.nse_mf_ucc WHERE user_ref_id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No UCC record found'; END IF;

    UPDATE trade.nse_mf_ucc
       SET client_auth_status = CASE WHEN p_new_status = 'REGISTERED' THEN 'AUTHORIZED' ELSE p_new_status END,
           client_auth_response = p_nse_response,
           ucc_status = COALESCE(p_new_status, v_previous_status),
           updated_at = CURRENT_TIMESTAMP
     WHERE user_ref_id = p_user_id;

    OPEN p_result FOR
        SELECT v_previous_status AS previous_status, ucc_status AS new_status,
               client_auth_response AS nse_response
          FROM trade.nse_mf_ucc WHERE user_ref_id = p_user_id;
END;
$procedure$;
-- CALL ops.sp_ops_mf_refresh_ucc_status('<USER_ID>', '{"response_status":"S"}'::jsonb, 'REGISTERED', 'mf_refresh_cur');

-- File: ops.sp_ops_mf_retry_fatca.sql

CREATE PROCEDURE ops.sp_ops_mf_retry_fatca(
    IN p_user_id VARCHAR,
    IN p_nse_response JSONB,
    IN p_submitted BOOLEAN,
    IN p_fatca_status TEXT,
    IN p_reg_id TEXT,
    IN p_reg_status TEXT,
    IN p_reg_remark TEXT,
    INOUT p_result REFCURSOR
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM trade.nse_mf_ucc WHERE user_ref_id = p_user_id) THEN
        RAISE EXCEPTION 'No UCC record found';
    END IF;
    UPDATE trade.nse_mf_ucc
       SET fatca_submitted = COALESCE(p_submitted, TRUE),
           fatca_nse_response = p_nse_response,
           fatca_status = p_fatca_status,
           fatca_reg_id = COALESCE(NULLIF(p_reg_id, ''), fatca_reg_id),
           fatca_reg_status = p_reg_status,
           fatca_reg_remark = p_reg_remark,
           updated_at = CURRENT_TIMESTAMP
     WHERE user_ref_id = p_user_id;
    OPEN p_result FOR SELECT fatca_status, fatca_nse_response, fatca_reg_id,
                             fatca_reg_status, fatca_reg_remark
                        FROM trade.nse_mf_ucc WHERE user_ref_id = p_user_id;
END;
$procedure$;


-- CALL ops.sp_ops_mf_retry_fatca('<USER_ID>', '{"status":true}'::jsonb, TRUE, 'REGISTERED', 'REG-123', 'REGISTERED', NULL, 'mf_fatca_retry_cur');

-- File: ops.sp_ops_mf_sync_mandates.sql
CREATE PROCEDURE ops.sp_ops_mf_sync_mandates(
    IN p_user_id VARCHAR,
    IN p_updates JSONB,
    INOUT p_result REFCURSOR
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_updates IS NULL OR jsonb_typeof(p_updates) <> 'array' THEN
        RAISE EXCEPTION 'Mandate updates must be a JSON array';
    END IF;
    UPDATE trade.nse_mf_mandate m
       SET bank_status = x.bank_status,
           enach_status = x.enach_status,
           umrn_no = x.umrn_no,
           approved_date = x.approved_date,
           reject_reason = x.reject_reason,
           mandate_status = COALESCE(x.mandate_status, m.mandate_status),
           last_status_sync = CURRENT_TIMESTAMP,
           updated_at = CURRENT_TIMESTAMP
      FROM jsonb_to_recordset(p_updates) AS x(
          id TEXT, bank_status TEXT, enach_status TEXT, umrn_no TEXT,
          approved_date TEXT, reject_reason TEXT, mandate_status TEXT
      )
     WHERE m.id = x.id AND m.user_ref_id = p_user_id;
    OPEN p_result FOR SELECT * FROM trade.nse_mf_mandate
      WHERE user_ref_id = p_user_id ORDER BY created_at DESC;
END;
$procedure$;

-- CALL ops.sp_ops_mf_sync_mandates('<USER_ID>', '[{"id":"<MANDATE_ID>","bank_status":"APPROVED","mandate_status":"APPROVED"}]'::jsonb, 'mf_mandate_sync_cur');

-- File: ops.sp_ops_mf_sync_orders.sql
CREATE PROCEDURE ops.sp_ops_mf_sync_orders(
    IN p_user_id VARCHAR,
    IN p_updates JSONB,
    INOUT p_result REFCURSOR
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_updates IS NULL OR jsonb_typeof(p_updates) <> 'array' THEN
        RAISE EXCEPTION 'Order updates must be a JSON array';
    END IF;
    UPDATE trade.nse_mf_order o
       SET order_status = COALESCE(x.order_status, o.order_status),
           nse_order_status = x.nse_order_status,
           nse_remark = x.nse_remark,
           updated_at = CURRENT_TIMESTAMP
      FROM jsonb_to_recordset(p_updates) AS x(
          id TEXT, order_status TEXT, nse_order_status TEXT, nse_remark TEXT
      )
     WHERE o.id = x.id AND o.user_ref_id = p_user_id
       AND o.order_status NOT IN ('COMPLETED', 'FAILED', 'CANCELLED');
    OPEN p_result FOR SELECT * FROM trade.nse_mf_order
      WHERE user_ref_id = p_user_id ORDER BY created_at DESC;
END;
$procedure$;


-- CALL ops.sp_ops_mf_sync_orders('<USER_ID>', '[{"id":"<ORDER_ID>","order_status":"COMPLETED","nse_order_status":"ALLOTTED"}]'::jsonb, 'mf_order_sync_cur');

-- File: ops.sp_ops_soft_delete_profile_user.sql
CREATE OR REPLACE PROCEDURE ops.sp_ops_soft_delete_profile_user(
    IN p_user_id VARCHAR(191),
    OUT data JSON
)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE "user"."user"
       SET is_deleted = TRUE
     WHERE id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found';
    END IF;

    data := json_build_object('id', p_user_id, 'is_deleted', TRUE);
END;
$$;

	-- CALL ops.sp_ops_soft_delete_profile_user('NUQI00000001', NULL);

-- File: ops.sp_ops_update_kyc.sql
CREATE PROCEDURE ops.sp_ops_update_kyc(
    IN p_user_id VARCHAR,
    IN p_update JSONB,
    IN p_is_maker_only BOOLEAN,
    IN p_requested_by VARCHAR,
    IN p_requested_by_email VARCHAR,
    INOUT p_kyc_cursor REFCURSOR,
    OUT p_request_id TEXT,
    OUT p_status_code INTEGER,
    OUT p_message TEXT
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_user_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM "user"."user" WHERE id = p_user_id
    ) THEN
        p_status_code := 404;
        p_message := 'User not found.';
        p_request_id := NULL;
        RETURN;
    END IF;

    IF p_update IS NULL OR jsonb_typeof(p_update) <> 'object' THEN
        RAISE EXCEPTION 'KYC update payload must be a JSON object';
    END IF;

    IF p_update ? 'status' AND COALESCE(p_is_maker_only, FALSE) THEN
        IF p_requested_by IS NULL OR p_requested_by_email IS NULL THEN
            RAISE EXCEPTION 'Maker id and email are required for approval submission';
        END IF;

        p_request_id := md5(random()::text || clock_timestamp()::text);
        INSERT INTO ops.approvalrequest (
            id, module, "actionType", "entityType", "entityId", payload,
            status, "requestedBy", "requestedByEmail", "createdAt"
        ) VALUES (
            p_request_id, 'kyc-verified', 'KYC_STATUS_UPDATE', 'KYC', p_user_id,
            p_update, 'PENDING', p_requested_by, p_requested_by_email, CURRENT_TIMESTAMP
        );

        p_status_code := 202;
        p_message := 'Submitted for approval.';
        RETURN;
    END IF;

    p_request_id := NULL;
    CALL ops.sp_ops_apply_kyc_update(p_user_id, p_update, p_kyc_cursor);
    p_status_code := 200;
    p_message := 'KYC record updated.';
END;
$procedure$;
--CALL ops.sp_ops_update_kyc('NUQI00000001', '{"status":"REJECTED","rejection_reason":"Please resubmit"}'::jsonb,TRUE, '<OPS_USER_ID>', 'admin@example.com', 'kyc_update_cur', NULL, NULL, NULL);

-- File: ops.sp_ops_update_subscription_status.sql
CREATE PROCEDURE ops.sp_ops_update_subscription_status(
    IN p_subscription_id VARCHAR,
    IN p_subscription_status TEXT,
    IN p_end_date TIMESTAMP,
    IN p_set_admin_note BOOLEAN,
    IN p_admin_note TEXT,
    INOUT p_updated_cursor REFCURSOR,
    OUT p_found BOOLEAN
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_status_type TEXT;
BEGIN
    IF p_subscription_status IS NOT NULL
       AND p_subscription_status NOT IN ('PENDING', 'ACTIVE', 'FAILED') THEN
        RAISE EXCEPTION 'Invalid status. Must be one of: PENDING, ACTIVE, FAILED';
    END IF;

    SELECT EXISTS (SELECT 1 FROM payments.usersubscription WHERE id = p_subscription_id)
      INTO p_found;
    IF NOT p_found THEN RETURN; END IF;

    SELECT format_type(a.atttypid, a.atttypmod) INTO v_status_type
      FROM pg_attribute a
     WHERE a.attrelid = 'payments.usersubscription'::regclass
       AND a.attname = 'subscription_status' AND NOT a.attisdropped;

    EXECUTE format(
        'UPDATE payments.usersubscription
            SET subscription_status = COALESCE($1::%s, subscription_status),
                end_date = COALESCE($2, end_date),
                response_data = CASE WHEN COALESCE($3, FALSE) THEN $4 ELSE response_data END,
                update_at = CURRENT_TIMESTAMP
          WHERE id = $5',
        v_status_type
    ) USING p_subscription_status, p_end_date, p_set_admin_note, p_admin_note, p_subscription_id;

    OPEN p_updated_cursor FOR
        SELECT us.*,
               u.first_name AS user_first_name, u.last_name AS user_last_name, u.email AS user_email,
               s.name AS plan_name_current, s.price AS plan_price
          FROM payments.usersubscription us
          LEFT JOIN "user"."user" u ON u.id = us.user_ref_id
          LEFT JOIN payments.subscriptions s ON s.id = us."subscriptionsId"
         WHERE us.id = p_subscription_id;
END;
$procedure$;

-- CALL ops.sp_ops_update_subscription_status('9f6239b801f1ff965db2d30f8421cf0d', 'ACTIVE', NULL, FALSE, NULL, 'updated_subscription_cur', NULL);

-- File: ops.sp_ops_users_assign_subscription.sql

CREATE PROCEDURE ops.sp_ops_users_assign_subscription(
    IN p_user_id VARCHAR,
    IN p_plan_id VARCHAR,
    IN p_duration_months INTEGER,
    IN p_admin_note TEXT,
    IN p_promo_code TEXT,
    IN p_promo_id VARCHAR,
    IN p_discount_amount NUMERIC,
    IN p_original_amount NUMERIC,
    IN p_final_amount NUMERIC,
    INOUT p_subscription_cursor REFCURSOR,
    INOUT p_transaction_cursor REFCURSOR
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_plan_name TEXT;
    v_start TIMESTAMP := CURRENT_TIMESTAMP;
    v_end TIMESTAMP;
    v_subscription_id VARCHAR;
    v_transaction_row_id VARCHAR;
    v_trace_id TEXT;
    v_order_id TEXT;
    v_transaction_id TEXT;
BEGIN
    IF p_duration_months IS NULL OR p_duration_months <= 0 THEN
        RAISE EXCEPTION 'durationMonths must be a positive integer';
    END IF;
    IF p_final_amount IS NULL OR p_final_amount < 0 THEN
        RAISE EXCEPTION 'final amount must be zero or greater';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_user_id AND is_deleted = FALSE FOR UPDATE) THEN
        RAISE EXCEPTION 'User not found or deleted';
    END IF;
    SELECT name INTO v_plan_name FROM payments.subscriptions WHERE id = p_plan_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Subscription plan not found'; END IF;

    v_end := v_start + make_interval(months => p_duration_months);
    v_trace_id := 'ADMIN_' || REPLACE(gen_random_uuid()::TEXT, '-', '');
    v_order_id := 'ADMIN_ORDER_' || REPLACE(gen_random_uuid()::TEXT, '-', '');
    v_transaction_id := 'ADMIN_TXN_' || REPLACE(gen_random_uuid()::TEXT, '-', '');
    v_subscription_id := REPLACE(gen_random_uuid()::TEXT, '-', '');
    v_transaction_row_id := REPLACE(gen_random_uuid()::TEXT, '-', '');

    INSERT INTO payments.usersubscription (
        id, user_ref_id, "subscriptionsId", plan_name, amount, start_date, end_date,
        subscription_status, transaction_status, trace_id, response_data, created_at, update_at
    ) VALUES (
        v_subscription_id, p_user_id, p_plan_id, v_plan_name, p_final_amount, v_start, v_end,
        'ACTIVE', 'SUCCESS', v_trace_id,
        jsonb_build_object('admin_assigned', TRUE, 'admin_note', p_admin_note,
          'assigned_at', v_start, 'promo_code', p_promo_code,
          'original_amount', p_original_amount, 'discount_amount', p_discount_amount)::TEXT,
        v_start, v_start
    );

    INSERT INTO payments.subscriptiontransaction (
        id, user_ref_id, user_subscription_id, subscription_id, request_raw, response_raw,
        order_id, transaction_id, transaction_status, trace_id, response_data,
        promo_code_id, discount_amount, original_amount, created_at, update_at
    ) VALUES (
        v_transaction_row_id, p_user_id, v_subscription_id, p_plan_id,
        jsonb_build_object('admin_assigned', TRUE)::TEXT,
        jsonb_build_object('admin_assigned', TRUE)::TEXT,
        v_order_id, v_transaction_id, 'SUCCESS', v_trace_id,
        jsonb_build_object('admin_assigned', TRUE, 'admin_note', p_admin_note,
          'orderid', v_order_id, 'transactionid', v_transaction_id,
          'auth_status', '0300', 'amount', p_final_amount, 'promo_code', p_promo_code,
          'original_amount', p_original_amount, 'discount_amount', p_discount_amount)::TEXT,
        p_promo_id, p_discount_amount, p_original_amount, v_start, v_start
    );

    IF p_promo_id IS NOT NULL THEN
        INSERT INTO catalog.promo_code_use (id, promo_code_id, user_id, subscription_txn_id, discount_applied, used_at)
        VALUES (REPLACE(gen_random_uuid()::TEXT, '-', ''), p_promo_id, p_user_id,
                v_transaction_row_id, COALESCE(p_discount_amount, 0), v_start);
        UPDATE catalog.promo_code SET current_uses = current_uses + 1, updated_at = v_start
         WHERE id = p_promo_id;
    END IF;

    -- This database has no unique constraint on user_ref_id, so use a locked
    -- update-then-insert instead of ON CONFLICT (user_ref_id).
    PERFORM pg_advisory_xact_lock(hashtext('subscriptionfeature:' || p_user_id));

    UPDATE catalog.subscriptionfeature
       SET "ethicalStocksAccess" = 0,
           "brokerAccess" = TRUE,
           "portfolioAccess" = TRUE,
           "featuredStocksAccess" = 100,
           "storiesAccess" = 0,
           "cepsAccess" = '{"id":[]}'::jsonb,
           "stockDetailsAccess" = '{"peer":true,"range":true,"overview":true}'::jsonb,
           "sectorAnalysisAccess" = TRUE,
           "downloadResultsAccess" = TRUE,
           "aiAdvisorAccess" = TRUE,
           "dailyMarketNewsAccess" = TRUE,
           "postMarketAnalysisAccess" = TRUE,
           "portfolioAnalysisAccess" = TRUE,
           "aiPicksAccess" = TRUE,
           "tradeExecutionAccess" = TRUE,
           "dedicatedAgentAccess" = CASE WHEN v_plan_name = 'Pro' THEN TRUE ELSE "dedicatedAgentAccess" END,
           "updatedAt" = v_start
     WHERE user_ref_id = p_user_id;

    IF NOT FOUND THEN
        INSERT INTO catalog.subscriptionfeature (
            id, user_ref_id,
            "ethicalStocksAccess", "brokerAccess", "portfolioAccess", "cepsAccess",
            "featuredStocksAccess", "storiesAccess", "stockDetailsAccess", "keyInsightsAccess",
            "priceAlertsLimit", "advancedAlertsAccess", "advancedSearchAccess", "peerComparisonLimit",
            "sectorAnalysisAccess", "downloadResultsAccess", "pricingDataYears", "fundamentalDataYears",
            "shareholderDataAccess", "marketShareAccess", "revenueAccess", "financialStatementsYears",
            "technicalDataYears", "technicalScreenersLimit", "customScreenersAccess", "cepLimit",
            "aiAdvisorAccess", "dailyMarketNewsAccess", "postMarketAnalysisAccess", "portfolioAnalysisAccess",
            "aiPicksAccess", "watchlistLimit", "tradeExecutionAccess", "portfolioPurification",
            "portfolioAggregation", "mfTradeExecution", "mfAggregationAccess", "globalStocksAccess",
            "netWorthAccess", "calculatorsAccess", "sentimentAnalysisLimit", "dedicatedAgentAccess",
            "createdAt", "updatedAt"
        ) VALUES (
            REPLACE(gen_random_uuid()::TEXT, '-', ''), p_user_id,
            0, TRUE, TRUE, '{"id":[]}'::jsonb,
            100, 0, '{"peer":true,"range":true,"overview":true}'::jsonb, 0,
            0, FALSE, FALSE, 0,
            TRUE, TRUE, 0, 0,
            FALSE, FALSE, FALSE, 0,
            0, 0, FALSE, 0,
            TRUE, TRUE, TRUE, TRUE,
            TRUE, 0, TRUE, FALSE,
            FALSE, FALSE, FALSE, FALSE,
            FALSE, FALSE, 0, (v_plan_name = 'Pro'),
            v_start, v_start
        );
    END IF;

    OPEN p_subscription_cursor FOR
        SELECT * FROM payments.usersubscription WHERE id = v_subscription_id;
    OPEN p_transaction_cursor FOR
        SELECT * FROM payments.subscriptiontransaction WHERE id = v_transaction_row_id;
END;
$procedure$;

-- CALL ops.sp_ops_users_assign_subscription('NUQI00000002', 'c18fc402bd7fb7ec147e6a5210ca8cfa', 12, 'Admin assignment', NULL, NULL, 0, 15000, 15000, 'assigned_subscription_cur', 'assigned_transaction_cur');

-- File: ops.sp_ops_users_create_manual_kyc.sql

CREATE PROCEDURE ops.sp_ops_users_create_manual_kyc(
    IN p_user_id VARCHAR,
    IN p_full_name TEXT,
    IN p_pan_number TEXT,
    IN p_dob TEXT,
    IN p_gender TEXT,
    IN p_aadhaar_clean TEXT,
    IN p_address_text TEXT,
    IN p_address_json JSONB,
    IN p_transaction_id TEXT,
    IN p_status TEXT,
    IN p_provider TEXT,
    IN p_saved_paths JSONB,
    INOUT p_created_kyc REFCURSOR
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_kyc_id VARCHAR;
    v_aadhaar TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_user_id AND is_deleted = FALSE FOR UPDATE) THEN
        RAISE EXCEPTION 'User not found or deleted';
    END IF;
    IF EXISTS (SELECT 1 FROM kyc.kyc WHERE "userId" = p_user_id) THEN
        RAISE EXCEPTION 'KYC record already exists';
    END IF;

    v_kyc_id := REPLACE(gen_random_uuid()::TEXT, '-', '');
    v_aadhaar := CASE
        WHEN p_aadhaar_clean IS NULL OR BTRIM(p_aadhaar_clean) = '' THEN NULL
        WHEN p_aadhaar_clean ~ '[xX]' THEN p_aadhaar_clean
        ELSE 'XXXX-XXXX-' || RIGHT(REGEXP_REPLACE(p_aadhaar_clean, '[[:space:]-]', '', 'g'), 4)
    END;

    INSERT INTO kyc.kyc (
        id, "userId", "transactionId", status, provider, "fullName", dob, gender,
        "addressText", "addressJson", "panNumber", "aadhaarMaskedNumber",
        "selfieImagePath", "livenessImagePath", "panCroppedImagePath", "poiIdFaceImagePath",
        "eaadhaarPdfPath", "aadhaarXmlPath", "aadhaarPhotoImagePath", "verifiedAt", "createdAt", "updatedAt"
    ) VALUES (
        v_kyc_id, p_user_id, p_transaction_id, p_status, p_provider, p_full_name, p_dob, p_gender,
        p_address_text, p_address_json, p_pan_number, v_aadhaar,
        p_saved_paths->>'selfieImagePath', p_saved_paths->>'livenessImagePath',
        p_saved_paths->>'panCroppedImagePath', p_saved_paths->>'poiIdFaceImagePath',
        p_saved_paths->>'eaadhaarPdfPath', p_saved_paths->>'aadhaarXmlPath',
        p_saved_paths->>'aadhaarPhotoImagePath', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    );

    UPDATE "user"."user"
       SET is_kyc_verified = p_status IN ('APPROVED', 'auto_approved'),
           kyc_status = p_status,
           updated_at = CURRENT_TIMESTAMP
     WHERE id = p_user_id;

    OPEN p_created_kyc FOR
        SELECT k.*, u.id AS joined_user_id, u.email AS user_email,
               u.first_name AS user_first_name, u.last_name AS user_last_name
          FROM kyc.kyc k JOIN "user"."user" u ON u.id = k."userId"
         WHERE k.id = v_kyc_id;
END;
$procedure$;
--CALL ops.sp_ops_users_create_manual_kyc('NUQI00000002', 'Full Name', 'ABCDE1234F', '01-01-1990', 'Male', '123456789012', 'Address', NULL, NULL, 'APPROVED', 'MANUAL', '{}'::jsonb, 'created_kyc_cur');

-- File: ops.sp_ops_users_get_cached_portfolio.sql
CREATE PROCEDURE ops.sp_ops_users_get_cached_portfolio(
    IN p_user_id VARCHAR,
    IN p_portfolio_type TEXT,
    INOUT p_cached_portfolio REFCURSOR
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_user_id IS NULL OR p_user_id = '' THEN RAISE EXCEPTION 'userId is required'; END IF;
    IF UPPER(COALESCE(p_portfolio_type, 'NUQI')) NOT IN ('NUQI', 'ZERODHA') THEN
        RAISE EXCEPTION 'Invalid portfolioType. Only NUQI and ZERODHA are supported.';
    END IF;
    OPEN p_cached_portfolio FOR
        SELECT zerodha_user_id, session_status, last_fetched_at, last_fetched_portfolio
          FROM trade.zerodha WHERE user_ref_id = p_user_id
         ORDER BY updated_at DESC LIMIT 1;
END;
$procedure$;

-- CALL ops.sp_ops_users_get_cached_portfolio('NUQI00000002', 'NUQI', 'cached_portfolio_cur');

-- File: ops.sp_ops_users_soft_delete.sql

CREATE PROCEDURE ops.sp_ops_users_soft_delete(IN p_user_id VARCHAR, INOUT p_result REFCURSOR)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_email TEXT;
    v_phone TEXT;
    v_google_id TEXT;
    v_apple_id TEXT;
    v_first_name TEXT;
    v_last_name TEXT;
    v_suffix INTEGER := 1;
    v_new_email TEXT;
    v_new_phone TEXT;
    v_new_google_id TEXT;
    v_new_apple_id TEXT;
BEGIN
    SELECT email, phone_number, google_id, apple_id, first_name, last_name
      INTO v_email, v_phone, v_google_id, v_apple_id, v_first_name, v_last_name
      FROM "user"."user" WHERE id = p_user_id AND is_deleted = FALSE FOR UPDATE;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_user_id) THEN
            RAISE EXCEPTION 'User is already deleted';
        END IF;
        RAISE EXCEPTION 'User not found';
    END IF;

    LOOP
        v_new_email := COALESCE(v_email, 'null') || '_DEL_' || v_suffix::TEXT;
        v_new_phone := CASE WHEN v_phone IS NULL THEN NULL ELSE v_phone || '_DEL_' || v_suffix::TEXT END;
        v_new_google_id := CASE WHEN v_google_id IS NULL THEN NULL ELSE v_google_id || '_DEL_' || v_suffix::TEXT END;
        v_new_apple_id := CASE WHEN v_apple_id IS NULL THEN NULL ELSE v_apple_id || '_DEL_' || v_suffix::TEXT END;
        EXIT WHEN NOT EXISTS (
            SELECT 1 FROM "user"."user" u WHERE u.id <> p_user_id
              AND (u.email = v_new_email OR (v_new_phone IS NOT NULL AND u.phone_number = v_new_phone)
                   OR (v_new_google_id IS NOT NULL AND u.google_id = v_new_google_id)
                   OR (v_new_apple_id IS NOT NULL AND u.apple_id = v_new_apple_id))
        );
        v_suffix := v_suffix + 1;
    END LOOP;

    UPDATE "user"."user"
       SET is_deleted = TRUE, email = v_new_email, phone_number = v_new_phone,
           google_id = v_new_google_id, apple_id = v_new_apple_id, updated_at = CURRENT_TIMESTAMP
     WHERE id = p_user_id;

    OPEN p_result FOR SELECT p_user_id AS user_id, v_email AS original_email,
        v_new_email AS new_email, v_phone AS original_phone, v_new_phone AS new_phone,
        TRUE AS is_deleted, v_first_name AS first_name, v_last_name AS last_name;
END;
$procedure$;
-- CALL ops.sp_ops_users_soft_delete('NUQI00000001', 'deleted_user_cur');

-- File: ops.sp_ops_users_toggle_verification.sql
CREATE PROCEDURE ops.sp_ops_users_toggle_verification(
    IN p_user_id VARCHAR,
    IN p_field TEXT,
    IN p_value BOOLEAN,
    OUT p_id VARCHAR,
    OUT p_email TEXT,
    OUT p_first_name TEXT,
    OUT p_last_name TEXT,
    OUT p_is_kyc_verified BOOLEAN,
    OUT p_is_risk_verified BOOLEAN,
    OUT p_is_bank_kyc_verified BOOLEAN
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_field NOT IN ('is_kyc_verified', 'is_risk_verified', 'is_bank_kyc_verified') THEN
        RAISE EXCEPTION 'Invalid verification field';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM "user"."user" WHERE id = p_user_id) THEN
        RAISE EXCEPTION 'User not found';
    END IF;

    UPDATE "user"."user"
       SET is_kyc_verified = CASE WHEN p_field = 'is_kyc_verified' THEN p_value ELSE is_kyc_verified END,
           is_risk_verified = CASE WHEN p_field = 'is_risk_verified' THEN p_value ELSE is_risk_verified END,
           is_bank_kyc_verified = CASE WHEN p_field = 'is_bank_kyc_verified' THEN p_value ELSE is_bank_kyc_verified END,
           updated_at = CURRENT_TIMESTAMP
     WHERE id = p_user_id;

    SELECT u.id, u.email, u.first_name, u.last_name,
           u.is_kyc_verified, u.is_risk_verified, u.is_bank_kyc_verified
      INTO p_id, p_email, p_first_name, p_last_name,
           p_is_kyc_verified, p_is_risk_verified, p_is_bank_kyc_verified
      FROM "user"."user" u WHERE u.id = p_user_id;
END;
$procedure$;
--CALL ops.sp_ops_users_toggle_verification('NUQI00000002','is_kyc_verified', TRUE, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- File: ops.sp_ops_users_update_account_status.sql

CREATE PROCEDURE ops.sp_ops_users_update_account_status(
    IN p_user_id VARCHAR,
    IN p_account_status TEXT,
    INOUT p_updated_user REFCURSOR
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_account_status NOT IN ('Active', 'Frozen', 'Dormant', 'Closed') THEN
        RAISE EXCEPTION 'Invalid account status';
    END IF;
    UPDATE "user"."user" SET account_status = p_account_status, updated_at = CURRENT_TIMESTAMP
     WHERE id = p_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'User not found'; END IF;
    OPEN p_updated_user FOR
        SELECT id, email, first_name, last_name, account_status
          FROM "user"."user" WHERE id = p_user_id;
END;
$procedure$;

-- CALL ops.sp_ops_users_update_account_status('NUQI00000002', 'Frozen', 'updated_user_cur');

-- File: ops.sp_record_admin_session.sql
CREATE OR REPLACE PROCEDURE ops.sp_record_admin_session(
    p_admin_id VARCHAR(50),     
    p_admin_email VARCHAR(255),
    p_ip_address VARCHAR(45),
    p_device_type VARCHAR(100),
    p_browser VARCHAR(100),     
    p_os VARCHAR(100),          
    p_user_agent TEXT,
    p_event VARCHAR(255)
)
LANGUAGE plpgsql

AS $$

BEGIN

		INSERT INTO ops.adminsession (id,admin_id, admin_email, ip_address, device_type, browser, os, user_agent, event, created_at)
    	
		VALUES ('c' || substr(md5(random()::text), 1, 24), p_admin_id, p_admin_email, p_ip_address, p_device_type, p_browser, p_os,p_user_agent, p_event, NOW());

END;
$$;

--CALL ops.sp_record_admin_session('NUQIADMIN002','piyush.thakkar@nuqiwealth.com','10.14.14.1','web','Chrome','macOS','Mozilla/5.0 (Macintosh; Intel...)', 'logout');

-- File: ops.sp_record_audit_log.sql
-- PROCEDURE: ops.sp_record_audit_log
-- Function: recordAuditLog
-- Prisma await: await prismaClient.auditLog.create(...)
-- Purpose: Atomic PostgreSQL write for Operations / governance and auditing.
-- Point: Operations / governance and auditing
-- Used by: admin actions that currently call AuditLog.create().
-- Parameters map directly to Prisma AuditLog.create data fields.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_module varchar; p_action_type varchar; p_entity_type varchar; p_entity_id varchar; p_admin_email
--     varchar; p_status_before varchar DEFAULT NULL; p_status_after varchar DEFAULT NULL; p_action_reason text
--     DEFAULT NULL; p_admin_name varchar DEFAULT NULL; p_ip_address varchar DEFAULT NULL; p_browser varchar DEFAULT
--     NULL; p_success boolean DEFAULT true; p_metadata_keys text[] DEFAULT NULL; p_metadata_values text[] DEFAULT
--     NULL; p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: recordAuditLog | Route / flow: admin actions that currently call
--     AuditLog.create(). | Replace or support: await prismaClient.auditLog.create(...)
--   Full routes / trigger: POST /operations/audit-logs - write an operations audit event
--   Related .js file(s): server_trade/controllers/auth/apple.controller.js;
--     server_trade/controllers/auth/auth.controller.js; server_trade/controllers/auth/google.controller.js;
--     server_trade/controllers/auth/loginwithapplemob.controller.js;
--     server_trade/controllers/auth/riskprofile.controller.js;
--     server_trade/controllers/auth/supscription.controller.js;
--     server_trade/controllers/bankinfo/bankinfo.controller.js
--   Integration point: Operations / governance and auditing
--   Reason: Atomic PostgreSQL write for Operations / governance and auditing.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "ops".sp_record_audit_log(
    p_module varchar,
    p_action_type varchar,
    p_entity_type varchar,
    p_entity_id varchar,
    p_admin_email varchar,
    p_status_before varchar DEFAULT NULL,
    p_status_after varchar DEFAULT NULL,
    p_action_reason text DEFAULT NULL,
    p_admin_name varchar DEFAULT NULL,
    p_ip_address varchar DEFAULT NULL,
    p_browser varchar DEFAULT NULL,
    p_success boolean DEFAULT true,
    p_metadata_keys text[] DEFAULT NULL,
    p_metadata_values text[] DEFAULT NULL,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "ops".audit_logs (
        module, "actionType", "entityType", "entityId", "statusBefore",
        "statusAfter", "actionReason", "adminEmail", "adminName", "ipAddress",
        browser, success, metadata, "createdAt"
    ) VALUES (
        p_module, p_action_type, p_entity_type, p_entity_id, p_status_before,
        p_status_after, p_action_reason, p_admin_email, p_admin_name, p_ip_address,
        p_browser, p_success,
        "integration".fn_jsonb_from_pairs(p_metadata_keys, p_metadata_values), p_created_at
    );
END;
$procedure$;

-- File: ops.sp_register_operations_user.sql
CREATE OR REPLACE PROCEDURE ops.sp_register_operations_user(
    p_first_name VARCHAR(100),
    p_last_name VARCHAR(100),
    p_email VARCHAR(255),
    p_password VARCHAR(255),
    p_role VARCHAR(50),
    p_generated_id VARCHAR(50)
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- 1. Check if the email already exists
    IF EXISTS (SELECT 1 FROM ops.operations_user WHERE email = p_email) THEN
        RAISE EXCEPTION 'EMAIL_EXISTS';
    END IF;

    -- 2. Insert into operations_user table
    INSERT INTO ops.operations_user (id, first_name, last_name, password, role, email,create_at, updated_at, can_create, can_delete,can_read,can_update,is_active,token_version)
    VALUES (p_generated_id, p_first_name, p_last_name, p_password, COALESCE(p_role, 'USER')::operations_role, p_email, NOW(), NOW(), 0::boolean, 0::boolean, 1::boolean, 0::boolean,1::boolean,0);

    -- 3. Insert into operations_user_mapping table (with timestamps added)
    INSERT INTO ops.operations_user_mapping (id, user_id, role, created_at, updated_at )
    VALUES ('c' || substr(md5(random()::text), 1, 24), p_generated_id,  COALESCE(p_role, 'USER')::operations_role, NOW(), NOW());
	
END;
$$;
--CALL ops.sp_register_operations_user('Piyush','Thakkar','piyush.thakkar@nuqiwealth.com','277062637e...', 'ADMIN', 'NUQIADMIN002');

-- File: ops.sp_replace_operations_user_role.sql
-- PROCEDURE: ops.sp_replace_operations_user_role
-- Function: replaceOperationsUserRole
-- Prisma await: await prismaClient.$transaction([prismaClient.operations_user.update(...), prismaClient.operations_user_mapping.deleteMany/create(...)])
-- Purpose: Atomic PostgreSQL write for Operations role update.
-- Point: Operations role update
-- Used by: PUT /operations/operational-users/:id when role changes.
-- Keeps operations_user.role and its mapping synchronized atomically.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_id varchar; p_role text
--   Code / route integration target: Code function: replaceOperationsUserRole | Route / flow: PUT
--     /operations/operational-users/:id when role changes. | Replace or support: await
--     prismaClient.$transaction([prismaClient.operations_user.update(...),
--     prismaClient.operations_user_mapping.deleteMany/create(...)])
--   Full routes / trigger: PUT /operations/operational-users/:id - replace the operations user's role mapping
--   Related .js file(s): server_trade/controllers/operations/auth.controller.js;
--     server_trade/controllers/operations/adminRegistry.controller.js;
--     server_trade/routes/operations/adminRegistry.routes.js
--   Integration point: Operations role update
--   Reason: Atomic PostgreSQL write for Operations role update.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "ops".sp_replace_operations_user_role(
    p_user_id varchar,
    p_role text
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "ops".operations_user
    SET role = p_role::operations_role,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Operations user not found: %', p_user_id;
    END IF;

    DELETE FROM "ops".operations_user_mapping
    WHERE user_id = p_user_id;

    INSERT INTO "ops".operations_user_mapping (
        id, user_id, role, created_at, updated_at
    ) VALUES (
        gen_random_uuid()::text, p_user_id, p_role::operations_role,
        CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    );
END;
$procedure$;

-- File: ops.sp_review_approval_request.sql
-- PROCEDURE: ops.sp_review_approval_request
-- Function: reviewApprovalRequest
-- Prisma await: await prismaClient.approvalRequest.update(...)
-- Purpose: Atomic PostgreSQL write for Operations / maker-checker approval workflow.
-- Point: Operations / maker-checker approval workflow
-- Used by: approval request approve/reject routes.
-- Prisma mapping: where.id plus status/reviewer/review note/reviewedAt.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_status varchar; p_reviewed_by varchar; p_reviewed_by_email varchar; p_review_note
--     varchar DEFAULT NULL; p_reviewed_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: reviewApprovalRequest | Route / flow: approval request
--     approve/reject routes. | Replace or support: await prismaClient.approvalRequest.update(...)
--   Full routes / trigger: PUT /operations/approval-requests/:id/approve; PUT
--     /operations/approval-requests/:id/reject - review/read maker-checker requests
--   Related .js file(s): server_trade/controllers/operations/approvalRequests.controller.js;
--     server_trade/routes/operations/approvalRequests.routes.js
--   Integration point: Operations / maker-checker approval workflow
--   Reason: Atomic PostgreSQL write for Operations / maker-checker approval workflow.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "ops".sp_review_approval_request(
    p_id varchar,
    p_status varchar,
    p_reviewed_by varchar,
    p_reviewed_by_email varchar,
    p_review_note varchar DEFAULT NULL,
    p_reviewed_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "ops".approvalrequest
    SET status = p_status,
        "reviewedBy" = p_reviewed_by,
        "reviewedByEmail" = p_reviewed_by_email,
        "reviewNote" = p_review_note,
        "reviewedAt" = p_reviewed_at
    WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Approval request not found: %', p_id;
    END IF;
END;
$procedure$;

-- File: ops.sp_set_operations_user_active.sql
-- PROCEDURE: ops.sp_set_operations_user_active
-- Function: setOperationsUserActive
-- Prisma await: await prismaClient.operations_user.update(...)
-- Purpose: Atomic PostgreSQL write for Operations / admin registry.
-- Point: Operations / admin registry
-- Used by: activate/deactivate operations-user routes.
-- Prisma mapping: where.id plus is_active/token_version.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_is_active boolean; p_increment_token_version boolean DEFAULT true
--   Code / route integration target: Code function: setOperationsUserActive | Route / flow: activate/deactivate
--     operations-user routes. | Replace or support: await prismaClient.operations_user.update(...)
--   Full routes / trigger: DELETE /operations/operational-users/:id; POST
--     /operations/operational-users/:id/reactivate - deactivate/reactivate an operations user
--   Related .js file(s): server_trade/controllers/operations/auth.controller.js;
--     server_trade/controllers/operations/adminRegistry.controller.js;
--     server_trade/routes/operations/adminRegistry.routes.js
--   Integration point: Operations / admin registry
--   Reason: Atomic PostgreSQL write for Operations / admin registry.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "ops".sp_set_operations_user_active(
    p_id varchar,
    p_is_active boolean,
    p_increment_token_version boolean DEFAULT true
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "ops".operations_user
    SET is_active = p_is_active,
        token_version = CASE
            WHEN p_increment_token_version THEN token_version + 1
            ELSE token_version
        END,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Operations user not found: %', p_id;
    END IF;
END;
$procedure$;

-- File: ops.sp_update_operational_user.sql
CREATE OR REPLACE PROCEDURE ops.sp_update_operational_user(
    IN    p_id             VARCHAR,
    IN    p_first_name     VARCHAR,
    IN    p_last_name      VARCHAR,
    IN    p_email          VARCHAR,
    IN    p_password       VARCHAR,
    IN    p_role           VARCHAR,
    IN    p_is_active      BOOLEAN,
    IN    p_menu_access    JSONB,
    IN    p_can_create     BOOLEAN,
    IN    p_can_read       BOOLEAN,
    IN    p_can_update     BOOLEAN,
    IN    p_can_delete     BOOLEAN,
    IN    p_ip_address     VARCHAR,
    IN    p_user_agent     TEXT,
    INOUT p_result         TEXT DEFAULT NULL,
    INOUT p_http_status    INTEGER DEFAULT NULL,
    INOUT p_message        TEXT DEFAULT NULL,
    INOUT o_id             VARCHAR DEFAULT NULL,
    INOUT o_first_name     VARCHAR DEFAULT NULL,
    INOUT o_last_name      VARCHAR DEFAULT NULL,
    INOUT o_email          VARCHAR DEFAULT NULL,
    INOUT o_role           VARCHAR DEFAULT NULL,
    INOUT o_is_active      BOOLEAN DEFAULT NULL,
    INOUT o_can_create     BOOLEAN DEFAULT NULL,
    INOUT o_can_read       BOOLEAN DEFAULT NULL,
    INOUT o_can_update     BOOLEAN DEFAULT NULL,
    INOUT o_can_delete     BOOLEAN DEFAULT NULL,
    INOUT o_menu_access    JSONB DEFAULT NULL,
    INOUT o_status_before  TEXT DEFAULT NULL,
    INOUT o_status_after   TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Initialize default response signatures
    p_result      := 'SUCCESS';
    p_http_status := 200;
    p_message     := 'User updated successfully';

    -- 1. Fetch current status metadata to track operational state changes
    SELECT 
        CASE WHEN ou.is_active = TRUE THEN 'Active' ELSE 'Inactive' END
    INTO 
        o_status_before
    FROM ops.operations_user AS ou
    WHERE ou.id = p_id;

    -- Handle non-existent records
    IF o_status_before IS NULL THEN
        p_result      := 'USER_NOT_FOUND';
        p_http_status := 404;
        p_message     := 'User not found';
        RETURN;
    END IF;

    -- 2. Execute dynamic delta updates. COALESCE bypasses unchanged attributes.
    UPDATE ops.operations_user AS ou
    SET 
        first_name  = COALESCE(p_first_name, ou.first_name),
        last_name   = COALESCE(p_last_name, ou.last_name),
        email       = COALESCE(LOWER(p_email), ou.email),
        password    = COALESCE(p_password, ou.password),
        role        = COALESCE(p_role::operations_role, ou.role),
        is_active   = COALESCE(p_is_active, ou.is_active),
        menu_access = COALESCE(p_menu_access, ou.menu_access),
        can_create  = COALESCE(p_can_create, ou.can_create),
        can_read    = COALESCE(p_can_read, ou.can_read),
        can_update  = COALESCE(p_can_update, ou.can_update),
        can_delete  = COALESCE(p_can_delete, ou.can_delete),
        updated_at  = NOW()
    WHERE ou.id = p_id
    RETURNING 
        ou.id, ou.first_name, ou.last_name, ou.email, ou.role::VARCHAR, ou.is_active,
        ou.can_create, ou.can_read, ou.can_update, ou.can_delete, ou.menu_access,
        CASE WHEN ou.is_active = TRUE THEN 'Active' ELSE 'Inactive' END
    INTO 
        o_id, o_first_name, o_last_name, o_email, o_role, o_is_active,
        o_can_create, o_can_read, o_can_update, o_can_delete, o_menu_access,
        o_status_after;

    -- 3. Append metadata details to the audit log ledger asynchronously
    BEGIN
        INSERT INTO "user".auditlog (
            id, module, "actionType", "entityType", "entityId", "statusBefore", "statusAfter", 
            "actionReason", success, ip, "userAgent", "createdAt"
        )
        VALUES (
            'c' || substr(md5(random()::text), 1, 24),
            'Governance & Audit', 'Admin Account Updated', 'Operational User',
            p_id, o_status_before, o_status_after,
            'Admin ' || o_email || ' updated — Role: ' || o_role,
            TRUE, p_ip_address, p_user_agent, NOW()
        );
    EXCEPTION WHEN OTHERS THEN
        -- Safely drop out silently on audit writing dependencies to isolate critical flows
    END;
END;
$$;
--CALL ops.sp_update_operational_user('NUQIADMIN887766554','sachin','bendal','new.email@nuqiwealth.com', NULL,'ADMIN',NULL,NULL,NULL, NULL, NULL, NULL,'10.14.14.1','Manual Script execution terminal', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- File: ops.sp_upsert_operations_user_mapping.sql
-- PROCEDURE: ops.sp_upsert_operations_user_mapping
-- Function: upsertOperationsUserMapping
-- Prisma await: await prismaClient.operations_user_mapping.create/upsert(...)
-- Purpose: Atomic PostgreSQL write for Operations user-to-role mapping.
-- Point: Operations user-to-role mapping
-- Used by: operations registration and admin-registry create/update routes.
-- Parameters map to Prisma operations_user_mapping data.
-- ----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_operations_user_mapping_user_role
    ON "ops".operations_user_mapping(user_id, role);

-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_user_id varchar; p_role text; p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: upsertOperationsUserMapping | Route / flow: operations
--     registration and admin-registry create/update routes. | Replace or support: await
--     prismaClient.operations_user_mapping.create/upsert(...)
--   Full routes / trigger: POST /operations/register; POST /operations/operational-users - create user-role mapping
--   Related .js file(s): server_trade/controllers/operations/auth.controller.js;
--     server_trade/controllers/operations/adminRegistry.controller.js;
--     server_trade/routes/operations/adminRegistry.routes.js
--   Integration point: Operations user-to-role mapping
--   Reason: Atomic PostgreSQL write for Operations user-to-role mapping.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "ops".sp_upsert_operations_user_mapping(
    p_id varchar,
    p_user_id varchar,
    p_role text,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id varchar := COALESCE(NULLIF(p_id, ''), gen_random_uuid()::text);
BEGIN
    INSERT INTO "ops".operations_user_mapping (
        id, user_id, role, created_at, updated_at
    ) VALUES (
        v_id, p_user_id, p_role::operations_role, p_created_at, p_created_at
    )
    ON CONFLICT (user_id, role) DO UPDATE SET
        updated_at = CURRENT_TIMESTAMP;
END;
$procedure$;

-- File: ops.update_user_account_status.sql

CREATE OR REPLACE PROCEDURE "ops".update_user_account_status(
    p_user_id VARCHAR(191),
    p_account_status VARCHAR(64), OUT data JSON) 
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE "user"."user" SET account_status = p_account_status WHERE id = p_user_id;
    
    SELECT json_build_object(
        'id', id,
        'email', email,
        'first_name', first_name,
        'last_name', last_name,
        'account_status', account_status
    ) AS data
     INTO data FROM "user"."user" WHERE id = p_user_id LIMIT 1;
END;
$$;
--CALL ops.update_user_account_status('NUQI00000002', 'ACTIVE', NULL);

-- File: ops.update_user_verification.sql
CREATE OR REPLACE PROCEDURE "ops".update_user_verification(
    p_user_id VARCHAR(191),
    p_field VARCHAR(64),
    p_value BOOLEAN, OUT data JSON) 
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_field NOT IN ('is_kyc_verified', 'is_risk_verified', 'is_bank_kyc_verified') THEN
        RAISE EXCEPTION 'Invalid verification field';
    END IF;

    IF p_field = 'is_kyc_verified' THEN
        UPDATE "user"."user" SET is_kyc_verified = p_value WHERE id = p_user_id;
    ELSIF p_field = 'is_risk_verified' THEN
        UPDATE "user"."user" SET is_risk_verified = p_value WHERE id = p_user_id;
    ELSE
        UPDATE "user"."user" SET is_bank_kyc_verified = p_value WHERE id = p_user_id;
    END IF;

    SELECT json_build_object(
        'id', id,
        'email', email,
        'first_name', first_name,
        'last_name', last_name,
        'is_kyc_verified', is_kyc_verified,
        'is_risk_verified', is_risk_verified,
        'is_bank_kyc_verified', is_bank_kyc_verified
    ) AS data
     INTO data FROM "user"."user" WHERE id = p_user_id LIMIT 1;
END;
$$;
-- CALL ops.update_user_verification('NUQI00000002', 'is_kyc_verified', TRUE, NULL);



-- Functions integrated from all_final_function_mandar.sql
-- FUNCTION: ops.fn_get_operations_user_mappings
-- Function: getOperationsUserMappings
-- Prisma await: await prismaClient.operations_user_mapping.findMany({ include: { user: true } })
-- Purpose: PostgreSQL read/calculation for Operations admin registry / role mapping.
-- Point: Operations admin registry / role mapping
-- Used by: registration, login authorization, and admin-registry routes.
-- Parameters:
--   p_user_id = optional Prisma operations_user_mapping.user_id filter.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_id varchar DEFAULT NULL
--   Code / route integration target: Code function: getOperationsUserMappings | Route / flow: registration, login
--     authorization, and admin-registry routes. | Replace or support: await
--     prismaClient.operations_user_mapping.findMany({ include: { user: true } })
--   Full routes / trigger: POST /operations/register; POST /operations/login; GET /operations/operational-users -
--     resolve operations roles
--   Related .js file(s): server_trade/controllers/operations/auth.controller.js;
--     server_trade/controllers/operations/adminRegistry.controller.js;
--     server_trade/routes/operations/adminRegistry.routes.js
--   Integration point: Operations admin registry / role mapping
--   Reason: PostgreSQL read/calculation for Operations admin registry / role mapping.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "ops".fn_get_operations_user_mappings(
    p_user_id varchar DEFAULT NULL
)
RETURNS TABLE (
    mapping_id varchar,
    user_id varchar,
    role operations_role,
    created_at timestamp,
    updated_at timestamp,
    email varchar,
    first_name varchar,
    last_name varchar,
    is_active boolean
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        m.id,
        m.user_id,
        m.role,
        m.created_at,
        m.updated_at,
        u.email,
        u.first_name,
        u.last_name,
        u.is_active
    FROM "ops".operations_user_mapping m
    JOIN "ops".operations_user u ON u.id = m.user_id
    WHERE p_user_id IS NULL OR m.user_id = p_user_id
    ORDER BY u.email, m.role;
$function$;

-- FUNCTION: ops.fn_get_admin_audit_logs
-- Function: getAdminAuditLogs
-- Prisma await: replaces getRecentAuditLogs(...) file read after DB audit cutover
-- Purpose: Query database-backed Operations audit logs with the controller filters.
-- Point: Operations admin audit-log listing
-- Used by: GET /operations/admin-audit-logs
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_limit integer DEFAULT 100; p_action varchar DEFAULT NULL; p_admin_email varchar DEFAULT NULL;
--     p_entity_id varchar DEFAULT NULL; p_status text DEFAULT NULL
--   Code / route integration target: Code function: getAdminAuditLogs | Route / flow: GET
--     /operations/admin-audit-logs | Replace or support: replaces getRecentAuditLogs(...) file read after DB audit
--     cutover
--   Full routes / trigger: GET /operations/admin-audit-logs - query database-backed audit history and filters
--   Related .js file(s): server_trade/controllers/operations/operations.controller.js;
--     server_trade/routes/operations/users.routes.js; server_trade/routes/operations/auditLog.routes.js;
--     server_trade/utils/adminAuditLogger.js
--   Integration point: Operations admin audit-log listing
--   Reason: Query database-backed Operations audit logs with the controller filters.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "ops".fn_get_admin_audit_logs(
    p_limit integer DEFAULT 100,
    p_action varchar DEFAULT NULL,
    p_admin_email varchar DEFAULT NULL,
    p_entity_id varchar DEFAULT NULL,
    p_status text DEFAULT NULL
)
RETURNS TABLE (
    id integer,
    module varchar,
    action_type varchar,
    entity_type varchar,
    entity_id varchar,
    status_before varchar,
    status_after varchar,
    action_reason text,
    admin_email varchar,
    admin_name varchar,
    ip_address varchar,
    browser varchar,
    success boolean,
    metadata jsonb,
    created_at timestamp
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        a.id,
        a.module,
        a."actionType",
        a."entityType",
        a."entityId",
        a."statusBefore",
        a."statusAfter",
        a."actionReason",
        a."adminEmail",
        a."adminName",
        a."ipAddress",
        a.browser,
        a.success,
        a.metadata,
        a."createdAt"
    FROM "ops".audit_logs a
    WHERE (p_action IS NULL OR a."actionType" = p_action)
      AND (
          p_admin_email IS NULL
          OR a."adminEmail" ILIKE '%' || BTRIM(p_admin_email) || '%'
      )
      AND (p_entity_id IS NULL OR a."entityId" = p_entity_id)
      AND (
          p_status IS NULL
          OR (UPPER(p_status) = 'SUCCESS' AND a.success)
          OR (UPPER(p_status) = 'FAILED' AND NOT a.success)
      )
    ORDER BY a."createdAt" DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 1000);
$function$;
