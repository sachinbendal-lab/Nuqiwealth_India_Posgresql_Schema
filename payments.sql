-- Schema-wise stored procedures
-- Source: Procedure\payments\

-- File: payments.sp_cancel_withdrawal.sql
-- PROCEDURE: payments.sp_cancel_withdrawal
-- Function: cancelWithdrawal
-- Prisma await: replaces walletTransaction.findUnique/update plus wallet.update
-- Purpose: Cancel a pending withdrawal and release the blocked amount back to
-- the available wallet balance in one transaction.
-- Point: Operations withdrawal cancellation
-- Used by: PUT /operations/cancelwithdrawal
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_transaction_id varchar; p_admin_id varchar DEFAULT NULL; p_admin_email varchar DEFAULT 'UNKNOWN';
--     p_admin_name varchar DEFAULT NULL; p_ip_address varchar DEFAULT NULL; p_browser varchar DEFAULT NULL;
--     p_updated_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: cancelWithdrawal | Route / flow: PUT /operations/cancelwithdrawal
--     | Replace or support: replaces walletTransaction.findUnique/update plus wallet.update
--   Full routes / trigger: PUT /operations/cancelwithdrawal - atomically cancel the request and release blocked funds
--   Related .js file(s): server_trade/routes/operations/operations.route.js;
--     server_trade/controllers/operations/operations.controller.js
--   Integration point: Operations withdrawal cancellation
--   Reason: Cancel a pending withdrawal and release the blocked amount back to
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "payments".sp_cancel_withdrawal(
    p_transaction_id varchar,
    p_admin_id varchar DEFAULT NULL,
    p_admin_email varchar DEFAULT 'UNKNOWN',
    p_admin_name varchar DEFAULT NULL,
    p_ip_address varchar DEFAULT NULL,
    p_browser varchar DEFAULT NULL,
    p_updated_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_transaction "payments".wallettransaction%ROWTYPE;
BEGIN
    SELECT *
    INTO v_transaction
    FROM "payments".wallettransaction
    WHERE id = p_transaction_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Withdrawal transaction not found: %', p_transaction_id;
    END IF;

    IF v_transaction.type::text <> 'DEBIT' THEN
        RAISE EXCEPTION 'Transaction is not a withdrawal: %', p_transaction_id;
    END IF;

    IF v_transaction.status::text <> 'PENDING' THEN
        RAISE EXCEPTION 'Withdrawal is not pending: % (status: %)',
            p_transaction_id, v_transaction.status::text;
    END IF;

    UPDATE "payments".wallettransaction
    SET status = 'CANCELLED'::global_transaction_status,
        updated_at = p_updated_at,
        is_blocked = false
    WHERE id = p_transaction_id;

    UPDATE "payments".wallet
    SET amount = amount + v_transaction.amount,
        blocked_amount = blocked_amount - v_transaction.amount,
        update_at = p_updated_at
    WHERE id = v_transaction."Wallet_id";

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wallet not found for withdrawal: %', p_transaction_id;
    END IF;

    CALL "ops".sp_record_audit_log(
        p_module => 'Wallet Withdrawal',
        p_action_type => 'CANCEL_WITHDRAWAL',
        p_entity_type => 'WalletTransaction',
        p_entity_id => p_transaction_id,
        p_admin_email => COALESCE(NULLIF(BTRIM(p_admin_email), ''), 'UNKNOWN'),
        p_status_before => 'PENDING',
        p_status_after => 'CANCELLED',
        p_action_reason => 'Withdrawal cancelled and blocked amount released',
        p_admin_name => p_admin_name,
        p_ip_address => p_ip_address,
        p_browser => p_browser,
        p_success => true,
        p_metadata_keys => ARRAY['admin_id', 'user_id', 'wallet_id', 'amount'],
        p_metadata_values => ARRAY[
            p_admin_id,
            v_transaction.user_ref_id,
            v_transaction."Wallet_id",
            v_transaction.amount::text
        ],
        p_created_at => p_updated_at
    );
END;
$procedure$;

-- File: payments.sp_create_withdrawal.sql
-- PROCEDURE: payments.sp_create_withdrawal
-- Function: withdrawAmount
-- Prisma await: replaces wallet.findUnique/update plus walletTransaction.create
-- Purpose: Debit available wallet amount, block it, and create the withdrawal
-- request atomically so partial wallet/transaction updates cannot occur.
-- Point: Operations withdrawal creation
-- Used by: POST /operations/withdraw
-- Pass NULL p_transaction_id to generate a UUID that fits varchar(191).
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_transaction_id varchar; p_user_id varchar; p_amount numeric; p_admin_id varchar DEFAULT NULL;
--     p_admin_email varchar DEFAULT 'UNKNOWN'; p_admin_name varchar DEFAULT NULL; p_ip_address varchar DEFAULT NULL;
--     p_browser varchar DEFAULT NULL; p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: withdrawAmount | Route / flow: POST /operations/withdraw |
--     Replace or support: replaces wallet.findUnique/update plus walletTransaction.create
--   Full routes / trigger: POST /operations/withdraw - atomically debit/block wallet funds and create the withdrawal
--     request
--   Related .js file(s): server_trade/routes/operations/operations.route.js;
--     server_trade/controllers/operations/operations.controller.js
--   Integration point: Operations withdrawal creation
--   Reason: Debit available wallet amount, block it, and create the withdrawal
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "payments".sp_create_withdrawal(
    p_transaction_id varchar,
    p_user_id varchar,
    p_amount numeric,
    p_admin_id varchar DEFAULT NULL,
    p_admin_email varchar DEFAULT 'UNKNOWN',
    p_admin_name varchar DEFAULT NULL,
    p_ip_address varchar DEFAULT NULL,
    p_browser varchar DEFAULT NULL,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_wallet "payments".wallet%ROWTYPE;
    v_transaction_id varchar := COALESCE(NULLIF(BTRIM(p_transaction_id), ''), gen_random_uuid()::text);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Withdrawal amount must be greater than zero';
    END IF;

    SELECT *
    INTO v_wallet
    FROM "payments".wallet
    WHERE user_ref_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wallet not found for user: %', p_user_id;
    END IF;

    IF v_wallet.amount < p_amount THEN
        RAISE EXCEPTION 'Insufficient wallet balance for user: %', p_user_id;
    END IF;

    UPDATE "payments".wallet
    SET amount = amount - p_amount,
        blocked_amount = blocked_amount + p_amount,
        update_at = CURRENT_TIMESTAMP
    WHERE id = v_wallet.id;

    INSERT INTO "payments".wallettransaction (
        id, "Wallet_id", amount, type, status, user_ref_id,
        created_at, updated_at, is_blocked
    ) VALUES (
        v_transaction_id,
        v_wallet.id,
        p_amount,
        'DEBIT'::ledger_action_type,
        'PENDING'::global_transaction_status,
        p_user_id,
        p_created_at,
        p_created_at,
        false
    );

    CALL "ops".sp_record_audit_log(
        p_module => 'Wallet Withdrawal',
        p_action_type => 'WITHDRAW_AMOUNT',
        p_entity_type => 'WalletTransaction',
        p_entity_id => v_transaction_id,
        p_admin_email => COALESCE(NULLIF(BTRIM(p_admin_email), ''), 'UNKNOWN'),
        p_status_before => NULL,
        p_status_after => 'PENDING',
        p_action_reason => 'Withdrawal request created',
        p_admin_name => p_admin_name,
        p_ip_address => p_ip_address,
        p_browser => p_browser,
        p_success => true,
        p_metadata_keys => ARRAY['admin_id', 'user_id', 'wallet_id', 'amount'],
        p_metadata_values => ARRAY[
            p_admin_id,
            p_user_id,
            v_wallet.id,
            p_amount::text
        ],
        p_created_at => p_created_at
    );
END;
$procedure$;

-- File: payments.sp_subscription_create.sql
CREATE OR REPLACE PROCEDURE payments.sp_subscription_create(
    IN p_name VARCHAR,
    IN p_price NUMERIC,
    IN p_benefits JSONB,
    IN p_coming_soon JSONB,
    OUT data JSONB
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id VARCHAR(191);
    v_plan payments.subscriptions%ROWTYPE;
BEGIN
    -- 1. Input Validation
    IF p_name IS NULL OR p_name = '' OR p_price IS NULL OR p_price <= 0 THEN
        RAISE EXCEPTION 'Name and positive price are required';
    END IF;
    IF p_price <> trunc(p_price) THEN
        RAISE EXCEPTION 'Subscription price must be a whole number';
    END IF;
    IF p_benefits IS NOT NULL AND jsonb_typeof(p_benefits) <> 'array' THEN
        RAISE EXCEPTION 'Benefits must be a JSON array';
    END IF;
    IF p_coming_soon IS NOT NULL AND jsonb_typeof(p_coming_soon) <> 'array' THEN
        RAISE EXCEPTION 'Coming soon features must be a JSON array';
    END IF;

    v_id := md5(random()::text || clock_timestamp()::text);
    
    -- 2. Store arrays directly into the subscriptions table JSONB columns
    INSERT INTO payments.subscriptions (
        id, 
        name, 
        price, 
        is_active, 
        is_nuclear, 
        feature_summary,   -- maps to your p_benefits array
        upcoming_feature,  -- maps to your p_coming_soon array
        created_at, 
        update_at
    ) VALUES (
        v_id, 
        p_name, 
        p_price::INTEGER, 
        1, 
        FALSE, 
        COALESCE(p_benefits, '[]'::jsonb),
        COALESCE(p_coming_soon, '[]'::jsonb),
        CURRENT_TIMESTAMP, 
        CURRENT_TIMESTAMP
    ) RETURNING * INTO v_plan;

    -- 3. Construct the clean response payload matching your original format
    data := jsonb_build_object(
        'status', 'success',
        'data', to_jsonb(v_plan) || jsonb_build_object(
            'features', COALESCE(p_benefits, '[]'::jsonb), 
            'comingSoonFeatures', COALESCE(p_coming_soon, '[]'::jsonb)
        )
    );
END;
$procedure$;


--CALL payments.sp_subscription_create('Prime Plan', 15000, '["Feature A","Feature B"]'::jsonb, '["Upcoming features"]'::jsonb,  NULL::jsonb);

-- File: payments.sp_subscription_delete.sql

CREATE OR REPLACE PROCEDURE payments.sp_subscription_delete(
    IN p_id VARCHAR,
    OUT data JSONB
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM payments.subscriptions WHERE id = p_id) THEN
        RAISE EXCEPTION 'Subscription plan not found';
    END IF;

    -- Match Prisma's onDelete: Cascade relations explicitly.
    DELETE FROM catalog.subscriptionfeatures WHERE "subscriptionId" = p_id;
    DELETE FROM catalog.subscription_coming_soon_features WHERE "subscriptionId" = p_id;
    DELETE FROM payments.subscriptions WHERE id = p_id;

    data := jsonb_build_object(
        'status', 'success',
        'message', 'Subscription plan deleted successfully'
    );
END;
$procedure$;

-- CALL payments.sp_subscription_delete('c18fc402bd7fb7ec147e6a5210ca8cfa', NULL);

-- File: payments.sp_subscription_get_all.sql
CREATE OR REPLACE PROCEDURE payments.sp_subscription_get_all(
    INOUT p_payload JSONB DEFAULT NULL -- Returns the clean aggregated layout payload
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT COALESCE(
        jsonb_agg(
            to_jsonb(s) || jsonb_build_object(
                'features', COALESCE(s.feature_summary, '[]'::jsonb),
                'comingSoonFeatures', COALESCE(s.upcoming_feature, '[]'::jsonb)
            )
        ), 
        '[]'::jsonb
    ) INTO p_payload
    FROM payments.subscriptions s
    WHERE s.is_active = 1; -- Matches your integer layout configuration constraint (1 instead of TRUE)
END;
$$;

-- CALL payments.sp_subscription_get_all(NULL::jsonb);

-- File: payments.sp_subscription_update.sql
CREATE OR REPLACE PROCEDURE payments.sp_subscription_update(
    IN p_id VARCHAR,
    IN p_name VARCHAR,
    IN p_price NUMERIC,
    IN p_benefits JSONB,
    IN p_coming_soon JSONB,
    OUT data JSONB
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_plan payments.subscriptions%ROWTYPE;
BEGIN
    -- 1. Input Validation
    IF p_id IS NULL OR p_name IS NULL OR p_name = '' OR p_price IS NULL OR p_price <= 0 THEN
        RAISE EXCEPTION 'ID, name, and positive price are required';
    END IF;
    IF p_price <> trunc(p_price) THEN
        RAISE EXCEPTION 'Subscription price must be a whole number';
    END IF;
    IF p_benefits IS NOT NULL AND jsonb_typeof(p_benefits) <> 'array' THEN
        RAISE EXCEPTION 'Benefits must be a JSON array';
    END IF;
    IF p_coming_soon IS NOT NULL AND jsonb_typeof(p_coming_soon) <> 'array' THEN
        RAISE EXCEPTION 'Coming soon features must be a JSON array';
    END IF;

    -- 2. Update the columns directly in the subscriptions table
    UPDATE payments.subscriptions
       SET name = p_name,
           price = p_price::INTEGER,
           feature_summary = COALESCE(p_benefits, '[]'::jsonb),  -- Directly updating your JSONB column
           upcoming_feature = COALESCE(p_coming_soon, '[]'::jsonb), -- Directly updating your JSONB column
           update_at = CURRENT_TIMESTAMP
     WHERE id = p_id
     RETURNING * INTO v_plan;
     
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Subscription not found';
    END IF;

    -- 3. Construct the clean response payload matching your expected application layout
    data := jsonb_build_object(
        'status', 'success',
        'data', to_jsonb(v_plan) || jsonb_build_object(
            'features', COALESCE(p_benefits, '[]'::jsonb), 
            'comingSoonFeatures', COALESCE(p_coming_soon, '[]'::jsonb)
        )
    );
END;
$procedure$;


--CALL payments.sp_subscription_update('cmdu9ze860000x1swwboxbz', 'Updated Plan', 1500, '["Benefit A"]'::jsonb, '[]'::jsonb, NULL);

-- File: payments.sp_user_add_subscription_plans.sql
CREATE OR REPLACE PROCEDURE payments.sp_user_add_subscription_plans(
    OUT payload JSON
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT := 0;
BEGIN
    -- Check if plans already exist
    SELECT COUNT(*) INTO v_count FROM payments.subscriptions;
    
    IF v_count > 0 THEN
        payload := json_build_object('status', TRUE, 'message', 'Subscription plans already exist.');
    ELSE
        -- Insert active subscription plans
        INSERT INTO payments.subscriptions (
            id, name, price, feature_summary, upcoming_feature, is_nuclear, is_active, created_at, update_at
        )
        VALUES
          ('cmdu9ze860000x1swwbexbz1s', 'Prime', 15000,
           '[
             "Ethical Stocks Access: Yes", "Minimum Portfolio Size: > 1500 INR", "Portfolio Access: Full access", 
             "CEPs (Curated Equity Portfolios) Access: All CEPs included", "Featured Stocks Access: Yes", 
             "Stories Access: Yes", "Stock Details Access: Access to all stocks", "Key Insights Access: Yes", 
             "Advanced Search Access: Yes", "Sector Analysis Access: Yes", "Pricing Data History: 5 years", 
             "Fundamental Data History: 5 years", "Shareholder Data Access: Yes", "Market Share Access: Yes", 
             "Revenue Access: Yes", "Financial Statements History: 5 years", "Technical Data History: 5 years", 
             "Technical Screeners Limit: 50 screeners", "Custom Screeners Access: Yes", "CEP Limit: Up to 999 portfolios", 
             "AI Advisor Access: Yes", "AI Picks Access: Up to 50 picks", "Sentiment Analysis Limit: Yes", 
             "Daily Market News Access: Up to 999 news updates", "Watchlist Limit: 999 items", "Trade Execution Access: Yes", 
             "Calculators Access: Yes", "Portfolio Analysis Access: Yes", "Dedicated Agent Access: No"
           ]'::json,
           '{
             "upcoming_feature": [
               "Set up price alerts for timely market updates", "Create advanced alerts based on custom triggers", 
               "Download reports and data for offline use", "Receive daily post-market summaries in PDF", 
               "Compare stocks using detailed peer analysis"
             ]
           }'::json, 
           0, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
           
          ('cmdu9ze860000x1swwbkshcys', 'Pro', 25000,
           '[
             "Ethical Stocks Access: Yes", "Minimum Portfolio Size: > 1500 INR", "Portfolio Access: Full access", 
             "CEPs (Curated Equity Portfolios) Access: All CEPs included", "Featured Stocks Access: Yes", 
             "Stories Access: Yes", "Stock Details Access: Access to all stocks", "Key Insights Access: Yes", 
             "Advanced Search Access: Yes", "Sector Analysis Access: Yes", "Pricing Data History: 5 years", 
             "Fundamental Data History: 5 years", "Shareholder Data Access: Yes", "Market Share Access: Yes", 
             "Revenue Access: Yes", "Financial Statements History: 5 years", "Technical Data History: 5 years", 
             "Technical Screeners Limit: 50 screeners", "Custom Screeners Access: Yes", "CEP Limit: Up to 999 portfolios", 
             "AI Advisor Access: Yes", "AI Picks Access: Up to 50 picks", "Sentiment Analysis Limit: Yes", 
             "Daily Market News Access: Up to 999 news updates", "Watchlist Limit: Unlimited", "Trade Execution Access: Yes", 
             "Calculators Access: Yes", "Portfolio Analysis Access: Yes", "Dedicated Agent Access: Yes"
           ]'::json,
           '{
             "upcoming_feature": [
               "Set up price alerts and advanced multi-criteria alerts", "Download filtered results for offline use or analysis", 
               "Access detailed post-market analysis in PDF format", "Run peer comparisons to evaluate performance against competitors"
             ]
           }'::json, 
           0, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
           
        payload := json_build_object('status', TRUE, 'message', 'Subscription plans added successfully.');
    END IF;
END;
$$;
-- CALL payments.sp_user_add_subscription_plans(NULL::json);

-- File: payments.sp_user_get_subscription.sql
CREATE OR REPLACE PROCEDURE payments.sp_user_get_subscription(
    IN p_user_id VARCHAR(191),
    INOUT p_payload JSON DEFAULT NULL -- Used to output the final data object
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT json_build_object(
      'id', us.id, 
      'user_ref_id', us.user_ref_id, 
      'subscriptionsId', us."subscriptionsId", -- Quoted camelCase column
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
      'Subscriptions', json_build_object(
          'id', s.id, 
          'name', s.name, 
          'price', s.price, 
          'feature_summary', s.feature_summary,
          'upcoming_feature', s.upcoming_feature, 
          'is_nuclear', s.is_nuclear, 
          'is_active', s.is_active, 
          'created_at', s.created_at, 
          'update_at', s.update_at
      )
    ) INTO p_payload -- Directly assigns the query output to the output parameter
    FROM payments.usersubscription us 
    JOIN payments.subscriptions s ON s.id = us."subscriptionsId" -- Quoted camelCase JOIN column
    WHERE us.user_ref_id = p_user_id 
      AND us.transaction_status = 'SUCCESS' 
      AND us.subscription_status = 'ACTIVE'
    ORDER BY us.created_at DESC 
    LIMIT 1;
END;
$$;

--CALL payments.sp_user_get_subscription('NUQI00000001', NULL);

-- File: payments.sp_user_get_subscription_transactions.sql
CREATE OR REPLACE PROCEDURE payments.sp_user_get_subscription_transactions(
    IN p_user_id VARCHAR(191),
    INOUT p_payload JSON DEFAULT NULL -- Used to output the compiled array payload
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT COALESCE(
        json_agg(
            json_build_object(
                'id', st.id, 
                'user_ref_id', st.user_ref_id, 
                'user_subscription_id', st.user_subscription_id,
                'subscription_id', st.subscription_id, 
                'request_raw', st.request_raw, 
                'response_raw', st.response_raw,
                'transaction_id', st.transaction_id, 
                'order_id', st.order_id, 
                'mode', st.mode,
                'transaction_status', st.transaction_status, 
                'trace_id', st.trace_id, 
                'response_data', st.response_data,
                'promo_code_id', st.promo_code_id, 
                'discount_amount', st.discount_amount, 
                'original_amount', st.original_amount,
                'created_at', st.created_at, 
                'update_at', st.update_at,
                'UserSubscription', json_build_object(
                    'id', us.id, 
                    'user_ref_id', us.user_ref_id, 
                    'subscriptionsId', us."subscriptionsId", -- Kept case-sensitive camelCase with double quotes
                    'plan_name', us.plan_name, 
                    'amount', us.amount, 
                    'start_date', us.start_date, 
                    'end_date', us.end_date,
                    'subscription_status', us.subscription_status, 
                    'transaction_status', us.transaction_status,
                    'created_at', us.created_at, 
                    'update_at', us.update_at
                ),
                'subscription', json_build_object(
                    'id', s.id, 
                    'name', s.name, 
                    'price', s.price, 
                    'feature_summary', s.feature_summary,
                    'upcoming_feature', s.upcoming_feature, 
                    'is_nuclear', s.is_nuclear, 
                    'is_active', s.is_active
                )
            )
        ), 
        '[]'::json -- Proper fallback representation for empty states
    ) INTO p_payload
    FROM payments.subscriptiontransaction st
    JOIN payments.usersubscription us ON us.id = st.user_subscription_id
    JOIN payments.subscriptions s ON s.id = st.subscription_id
    WHERE st.user_ref_id = p_user_id;
END;
$$;

--CALL payments.sp_user_get_subscription_transactions('NUQI00000001', NULL::json);

-- File: payments.sp_user_get_transactions.sql
CREATE OR REPLACE PROCEDURE payments.sp_user_get_transactions(
    IN p_user_id VARCHAR(191),
    INOUT p_payload JSON DEFAULT NULL -- Used to output the compiled array payload
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT COALESCE(
        json_agg(
            json_build_object(
                'id', st.id, 
                'user_ref_id', st.user_ref_id, 
                'user_subscription_id', st.user_subscription_id,
                'subscription_id', st.subscription_id, 
                'request_raw', st.request_raw, 
                'response_raw', st.response_raw,
                'transaction_id', st.transaction_id, 
                'order_id', st.order_id, 
                'mode', st.mode,
                'transaction_status', st.transaction_status, 
                'trace_id', st.trace_id, 
                'response_data', st.response_data,
                'promo_code_id', st.promo_code_id, 
                'discount_amount', st.discount_amount, 
                'original_amount', st.original_amount,
                'created_at', st.created_at, 
                'update_at', st.update_at,
                'Subscription', json_build_object(
                    'id', s.id, 
                    'name', s.name, 
                    'price', s.price, 
                    'feature_summary', s.feature_summary,
                    'upcoming_feature', s.upcoming_feature, 
                    'is_nuclear', s.is_nuclear, 
                    'is_active', s.is_active
                )
            )
        ), 
        '[]'::json -- Proper fallback representation for empty states
    ) INTO p_payload
    FROM payments.subscriptiontransaction st 
    JOIN payments.subscriptions s ON s.id = st.subscription_id
    WHERE st.user_ref_id = p_user_id;
END;
$$;

--CALL payments.sp_user_get_transactions('NUQI00000001', NULL::json);

-- File: payments.sp_user_upgrade_subscription.sql
CREATE OR REPLACE PROCEDURE payments.sp_user_upgrade_subscription(
    IN p_user_id VARCHAR(191), 
    IN p_plan_id VARCHAR(191),
    INOUT p_payload JSON DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE 
    v_sub_id VARCHAR(191);
    v_old_plan_id VARCHAR(191);
    v_old_end TIMESTAMP(3);
    v_old_price DECIMAL(19,4);
    v_new_price DECIMAL(19,4);
    v_new_name VARCHAR(191);
    v_wallet_id VARCHAR(191);
    v_balance DECIMAL(19,4);
    v_refund DECIMAL(19,4);
    v_cost DECIMAL(19,4);
    v_now TIMESTAMP(3) := CURRENT_TIMESTAMP(3);
    v_tx_id VARCHAR(191);
    v_order_id VARCHAR(191);
    
    v_updated_sub JSON;
    v_transaction JSON;
    v_updated_wallet JSON;
BEGIN
    -- 1. Find and lock active user subscription (Fixed camelCase columns with double quotes)
    SELECT id, "subscriptionsId", end_date INTO v_sub_id, v_old_plan_id, v_old_end
      FROM payments.usersubscription 
      WHERE user_ref_id = p_user_id AND end_date >= v_now 
      ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
      
    IF v_sub_id IS NULL THEN 
        RAISE EXCEPTION 'User does not have an active subscription' USING ERRCODE = '45000';
    END IF;
    
    -- 2. Fetch new subscription details
    SELECT price, name INTO v_new_price, v_new_name FROM payments.subscriptions WHERE id = p_plan_id;
    IF v_new_price IS NULL THEN 
        RAISE EXCEPTION 'Subscription not found' USING ERRCODE = '45000';
    END IF;
    
    -- 3. Fetch old subscription price
    SELECT price INTO v_old_price FROM payments.subscriptions WHERE id = v_old_plan_id;
    
    -- 4. Find and lock user wallet balance
    SELECT id, amount INTO v_wallet_id, v_balance FROM payments.wallet WHERE user_ref_id = p_user_id LIMIT 1 FOR UPDATE;
    IF v_wallet_id IS NULL THEN 
        RAISE EXCEPTION 'Wallet not found' USING ERRCODE = '45000';
    END IF;
    
    -- 5. Calculate refund and upgrade costs
    v_refund := (v_old_price / 365) * GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_old_end - v_now)) / 86400));
    v_cost := v_new_price - v_refund;
    
    IF v_balance < v_cost THEN 
        RAISE EXCEPTION 'Insufficient wallet balance for upgrade' USING ERRCODE = '45000';
    END IF;
    
    -- 6. Update user wallet and subscription status (Fixed camelCase target update columns)
    UPDATE payments.wallet SET amount = amount - v_cost, update_at = v_now WHERE id = v_wallet_id;
    
    UPDATE payments.usersubscription 
    SET "subscriptionsId" = p_plan_id, plan_name = v_new_name, amount = v_new_price,
        start_date = v_now, end_date = v_now + INTERVAL '1 year', 
        subscription_status = 'ACTIVE', transaction_status = 'SUCCESS', update_at = v_now 
    WHERE id = v_sub_id;
    
    -- 7. Generate clean UUID strings
    v_tx_id := REPLACE(gen_random_uuid()::TEXT, '-', '');
    v_order_id := CONCAT('TR', REPLACE(gen_random_uuid()::TEXT, '-', ''));
    
    -- 8. Log the upgrade tracking entry into transaction table
    INSERT INTO payments.subscriptiontransaction (id, user_ref_id, user_subscription_id, subscription_id, transaction_id, order_id, transaction_status, original_amount, discount_amount, created_at, update_at)
    VALUES (v_tx_id, p_user_id, v_sub_id, p_plan_id, CONCAT('TR', REPLACE(gen_random_uuid()::TEXT, '-', '')), v_order_id, 'SUCCESS', v_new_price, v_refund, v_now, v_now);
    
    -- 9. Structure and aggregate data component parts into clean JSON blocks
    SELECT json_build_object('id', us.id, 'user_ref_id', us.user_ref_id, 'subscriptionsId', us."subscriptionsId", 'plan_name', us.plan_name, 'amount', us.amount, 'start_date', us.start_date, 'end_date', us.end_date, 'subscription_status', us.subscription_status, 'transaction_status', us.transaction_status, 'created_at', us.created_at, 'update_at', us.update_at)
      INTO v_updated_sub FROM payments.usersubscription us WHERE us.id = v_sub_id;

    SELECT json_build_object('id', st.id, 'user_ref_id', st.user_ref_id, 'user_subscription_id', st.user_subscription_id, 'subscription_id', st.subscription_id, 'transaction_id', st.transaction_id, 'order_id', st.order_id, 'transaction_status', st.transaction_status, 'original_amount', st.original_amount, 'discount_amount', st.discount_amount, 'created_at', st.created_at, 'update_at', st.update_at)
      INTO v_transaction FROM payments.subscriptiontransaction st WHERE st.id = v_tx_id;

    SELECT json_build_object('id', w.id, 'user_ref_id', w.user_ref_id, 'amount', w.amount, 'blocked_amount', w.blocked_amount, 'status', w.status, 'suspended_till', w.suspended_till, 'is_deleted', w.is_deleted, 'created_at', w.created_at, 'update_at', w.update_at)
      INTO v_updated_wallet FROM payments.wallet w WHERE w.id = v_wallet_id;

    -- Map unified JSON output mapping to the outward-facing INOUT parameter
    SELECT json_build_object(
      'status', TRUE, 
      'message', 'Subscription upgraded successfully',
      'updatedSubscription', v_updated_sub,
      'transaction', v_transaction,
      'updatedWallet', v_updated_wallet
    ) INTO p_payload;

END;
$$;

--CALL payments.sp_user_upgrade_subscription('NUQI00000001', 'cmdu9ze860000x1swwboxbz', NULL);



-- Functions integrated from all_final_function_mandar.sql
-- FUNCTION: payments.fn_get_withdrawal_requests
-- Function: fetchWithdrawalRequests
-- Prisma await: await prismaClient.walletTransaction.findMany(...)
-- Purpose: Return pending/under-review debit requests for Operations.
-- Point: Operations withdrawal queue
-- Used by: GET /operations/withdrawals
-- Note: UNDERREVIEW is retained as a text filter for controller compatibility;
-- the current global_transaction_status enum contains PENDING but not UNDERREVIEW.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_limit integer DEFAULT 100; p_user_ref_id varchar DEFAULT NULL; p_statuses text[] DEFAULT
--     ARRAY['PENDING', 'UNDERREVIEW']::text[]
--   Code / route integration target: Code function: fetchWithdrawalRequests | Route / flow: GET
--     /operations/withdrawals | Replace or support: await prismaClient.walletTransaction.findMany(...)
--   Full routes / trigger: GET /operations/withdrawals - fetch the pending/under-review debit withdrawal queue
--   Related .js file(s): server_trade/routes/operations/operations.route.js;
--     server_trade/controllers/operations/operations.controller.js
--   Integration point: Operations withdrawal queue
--   Reason: Return pending/under-review debit requests for Operations.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "payments".fn_get_withdrawal_requests(
    p_limit integer DEFAULT 100,
    p_user_ref_id varchar DEFAULT NULL,
    p_statuses text[] DEFAULT ARRAY['PENDING', 'UNDERREVIEW']::text[]
)
RETURNS TABLE (
    id varchar,
    wallet_id varchar,
    amount numeric,
    transaction_type text,
    status text,
    user_ref_id varchar,
    created_at timestamp,
    updated_at timestamp,
    is_blocked boolean
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        wt.id,
        wt."Wallet_id",
        wt.amount,
        wt.type::text,
        wt.status::text,
        wt.user_ref_id,
        wt.created_at,
        wt.updated_at,
        wt.is_blocked
    FROM "payments".wallettransaction wt
    WHERE wt.type::text = 'DEBIT'
      AND wt.status::text = ANY(COALESCE(p_statuses, ARRAY['PENDING']::text[]))
      AND (p_user_ref_id IS NULL OR wt.user_ref_id = p_user_ref_id)
    ORDER BY wt.created_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 1000);
$function$;
