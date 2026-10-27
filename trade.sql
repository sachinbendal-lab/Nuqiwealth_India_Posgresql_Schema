-- Schema-wise stored procedures
-- Source: Procedure\trade\
-- File: trade.sp_add_transaction_log.sql
-- PROCEDURE: trade.sp_add_transaction_log
-- Function: addTransactionLog
-- Prisma await: await prismaClient.transactionLogs.create(...)
-- Purpose: Atomic PostgreSQL write for Orders / Transactions error and status logging.
-- Point: Orders / Transactions error and status logging
-- Used by: Controller/service flow addTransactionLog() when replacing the matching Prisma write.
-- Replaces: prisma.transactionLogs.create({ data }).
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_reason text DEFAULT NULL; p_error text DEFAULT NULL; p_transaction_id varchar DEFAULT
--     NULL; p_order_id varchar DEFAULT NULL; p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: addTransactionLog | Route / flow: Controller/service flow
--     addTransactionLog() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.transactionLogs.create(...)
--   Full routes / trigger: POST /trade/preTransaction; PUT /trade/postTransaction; GET /trade/orderbook -
--     create/update order and transaction records used by the trade flow
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Orders / Transactions error and status logging
--   Reason: Atomic PostgreSQL write for Orders / Transactions error and status logging.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_add_transaction_log(
    p_id varchar,
    p_reason text DEFAULT NULL,
    p_error text DEFAULT NULL,
    p_transaction_id varchar DEFAULT NULL,
    p_order_id varchar DEFAULT NULL,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "trade".transactionlogs (
        id, reason, error, transaction_id, order_id, created_at, updated_at
    ) VALUES (
        p_id, p_reason, p_error, p_transaction_id, p_order_id,
        p_created_at, p_created_at
    );
END;
$procedure$;

-- File: trade.sp_add_watchlist_stock.sql
-- PROCEDURE: trade.sp_add_watchlist_stock
-- Function: addWatchlistStock
-- Prisma await: await prismaClient.watchlistDetail.create(...)
-- Purpose: Atomic PostgreSQL write for Watchlist stock insertion/de-duplication.
-- Point: Watchlist stock insertion/de-duplication
-- Used by: POST /watchlist/create after Market/ETL stock validation.
-- Parameters map to Prisma WatchlistDetail data.
-- ----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_watchlistdetail_watchlist_scripcode
    ON "trade".watchlistdetail(watchlist_id, scripcode);

-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_watchlist_id varchar; p_scripcode integer; p_demo_trade_price numeric DEFAULT 0;
--     p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: addWatchlistStock | Route / flow: POST /watchlist/create after
--     Market/ETL stock validation. | Replace or support: await prismaClient.watchlistDetail.create(...)
--   Full routes / trigger: POST /watchlist/create - create/update a watchlist and add validated stocks
--   Related .js file(s): server_trade/routes/watchlist/watchlist.routes.js;
--     server_trade/controllers/watchlist/watchlist.controller.js
--   Integration point: Watchlist stock insertion/de-duplication
--   Reason: Atomic PostgreSQL write for Watchlist stock insertion/de-duplication.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_add_watchlist_stock(
    p_id varchar,
    p_watchlist_id varchar,
    p_scripcode integer,
    p_demo_trade_price numeric DEFAULT 0,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id varchar := COALESCE(NULLIF(p_id, ''), gen_random_uuid()::text);
BEGIN
    INSERT INTO "trade".watchlistdetail (
        id, watchlist_id, demo_trade_price, created_at, scripcode
    ) VALUES (
        v_id, p_watchlist_id, p_demo_trade_price, p_created_at, p_scripcode
    )
    ON CONFLICT (watchlist_id, scripcode) DO NOTHING;
END;
$procedure$;

-- File: trade.sp_cache_zerodha_portfolio.sql
-- PROCEDURE: trade.sp_cache_zerodha_portfolio
-- Function: cacheZerodhaPortfolio
-- Prisma await: await prismaClient.zerodha.update(...)
-- Purpose: Atomic PostgreSQL write for Zerodha portfolio cache.
-- Point: Zerodha portfolio cache
-- Used by: GET /trade/portfolio after a successful Zerodha API fetch.
-- Prisma mapping: where.user_ref_id/zerodha_user_id plus
-- data.last_fetched_portfolio and data.last_fetched_at.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar; p_zerodha_user_id varchar; p_last_fetched_portfolio_keys text[];
--     p_last_fetched_portfolio_values text[]; p_last_fetched_at timestamp
--   Code / route integration target: Code function: cacheZerodhaPortfolio | Route / flow: GET /trade/portfolio after
--     a successful Zerodha API fetch. | Replace or support: await prismaClient.zerodha.update(...)
--   Full routes / trigger: GET /trade/portfolio; GET /kite/portfolio/holdings; GET /kite/portfolio/positions - cache
--     a successful Zerodha portfolio fetch
--   Related .js file(s): server_trade/controllers/partner/partnerReports.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/zerodha/zerodhaAuth.controller.js;
--     server_trade/controllers/zerodha/zerodhaPortfolio.controller.js;
--     server_trade/controllers/zerodha/zerodhaTrade.controller.js; server_trade/routes/zerodha/zerodhaAuth.routes.js;
--     server_trade/routes/zerodha/zerodhaPortfolio.routes.js
--   Integration point: Zerodha portfolio cache
--   Reason: Atomic PostgreSQL write for Zerodha portfolio cache.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_cache_zerodha_portfolio(
    p_user_ref_id varchar,
    p_zerodha_user_id varchar,
    p_last_fetched_portfolio_keys text[],
    p_last_fetched_portfolio_values text[],
    p_last_fetched_at timestamp
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".zerodha
    SET last_fetched_portfolio = "integration".fn_jsonb_from_pairs(p_last_fetched_portfolio_keys, p_last_fetched_portfolio_values),
        last_fetched_at = p_last_fetched_at,
        updated_at = CURRENT_TIMESTAMP
    WHERE user_ref_id = p_user_ref_id
      AND zerodha_user_id = p_zerodha_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Zerodha session not found for user %, client %', p_user_ref_id, p_zerodha_user_id;
    END IF;
END;
$procedure$;

-- File: trade.sp_cancel_nse_mf_order.sql
-- PROCEDURE: trade.sp_cancel_nse_mf_order
-- Function: cancelNseMfOrder
-- Prisma await: await prismaClient.nseMfOrder.update(...)
-- Purpose: Atomic PostgreSQL write for NSE MF SIP/redemption cancellation.
-- Point: NSE MF SIP/redemption cancellation
-- Used by: Controller/service flow cancelNseMfOrder() when replacing the matching Prisma write.
-- Atomically updates NseMfOrder and the linked unified Transaction.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_user_ref_id varchar; p_nse_order_id varchar; p_nse_order_status varchar DEFAULT
--     'CANCELLED'; p_nse_remark text DEFAULT NULL; p_nse_response_keys text[] DEFAULT NULL; p_nse_response_values
--     text[] DEFAULT NULL
--   Code / route integration target: Code function: cancelNseMfOrder | Route / flow: Controller/service flow
--     cancelNseMfOrder() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.nseMfOrder.update(...)
--   Full routes / trigger: POST /nse/mf/sip/cancel; POST /nse/mf/order/cancel - persist cancellation status and
--     response
--   Related .js file(s): server_trade/controllers/nsemf/nseMf.controller.js;
--     server_trade/routes/nseMf/nseMf.routes.js; server_etl/schdulers/mfOrderStatusSync.js;
--     server_etl/schdulers/mandateStatusTracker.js
--   Integration point: NSE MF SIP/redemption cancellation
--   Reason: Atomic PostgreSQL write for NSE MF SIP/redemption cancellation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_cancel_nse_mf_order(
    p_id varchar,
    p_user_ref_id varchar,
    p_nse_order_id varchar,
    p_nse_order_status varchar DEFAULT 'CANCELLED',
    p_nse_remark text DEFAULT NULL,
    p_nse_response_keys text[] DEFAULT NULL,
    p_nse_response_values text[] DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".nse_mf_order
    SET order_status = 'CANCELLED',
        nse_order_status = p_nse_order_status,
        nse_remark = COALESCE(p_nse_remark, nse_remark),
        nse_response = COALESCE("integration".fn_jsonb_from_pairs(p_nse_response_keys, p_nse_response_values), nse_response),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id AND user_ref_id = p_user_ref_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NSE MF order not found: %', p_id;
    END IF;

    UPDATE "trade"."transaction"
    SET status = 'CANCELLED'::global_transaction_status,
        cancelled_quantity = quantity,
        pending_quantity = 0,
        updated_at = CURRENT_TIMESTAMP
    WHERE user_ref_id = p_user_ref_id
      AND exchange_order_id = p_nse_order_id
      AND UPPER(COALESCE(asset, '')) = 'MF';
END;
$procedure$;

-- File: trade.sp_cancel_order.sql
-- PROCEDURE: trade.sp_cancel_order
-- Function: cancelOrder
-- Prisma await: await prismaClient.$transaction([prismaClient.order.update(...), prismaClient.transaction.updateMany(...)])
-- Purpose: Atomic PostgreSQL write for Orders / cancellation.
-- Point: Orders / cancellation
-- Used by: Controller/service flow cancelOrder() when replacing the matching Prisma write.
-- Atomically cancels an Order and its linked Transaction when one exists.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_reason text DEFAULT NULL
--   Code / route integration target: Code function: cancelOrder | Route / flow: Controller/service flow cancelOrder()
--     when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.$transaction([prismaClient.order.update(...), prismaClient.transaction.updateMany(...)])
--   Full routes / trigger: POST /trade/preTransaction; PUT /trade/postTransaction; GET /trade/orderbook -
--     create/update order and transaction records used by the trade flow
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Orders / cancellation
--   Reason: Atomic PostgreSQL write for Orders / cancellation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_cancel_order(
    p_id varchar,
    p_reason text DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_transaction_id varchar;
BEGIN
    UPDATE "trade"."order"
    SET status = 'CANCELLED'::order_status_enum,
        remaining_qty = 0,
        gtn_response = COALESCE(p_reason, gtn_response),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id
    RETURNING transaction_id INTO v_transaction_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order not found: %', p_id;
    END IF;

    IF v_transaction_id IS NOT NULL THEN
        UPDATE "trade"."transaction"
        SET status = 'CANCELLED'::global_transaction_status,
            cancelled_quantity = quantity,
            pending_quantity = 0,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_transaction_id;
    END IF;
END;
$procedure$;

-- File: trade.sp_close_zerodha_session.sql
-- PROCEDURE: trade.sp_close_zerodha_session
-- Function: closeZerodhaSession
-- Prisma await: await prismaClient.zerodha.updateMany(...)
-- Purpose: Atomic PostgreSQL write for Zerodha logout/session invalidation.
-- Point: Zerodha logout/session invalidation
-- Used by: Controller/service flow closeZerodhaSession() when replacing the matching Prisma write.
-- Prisma mapping: where.user_ref_id plus session_status/token fields.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar
--   Code / route integration target: Code function: closeZerodhaSession | Route / flow: Controller/service flow
--     closeZerodhaSession() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.zerodha.updateMany(...)
--   Full routes / trigger: DELETE /user/session/token; DELETE /kite/user/session/token - close the current Zerodha
--     session
--   Related .js file(s): server_trade/controllers/zerodha/zerodhaAuth.controller.js;
--     server_trade/controllers/zerodha/zerodhaPortfolio.controller.js;
--     server_trade/controllers/zerodha/zerodhaTrade.controller.js; server_trade/routes/zerodha/zerodhaAuth.routes.js;
--     server_trade/routes/zerodha/zerodhaPortfolio.routes.js; server_trade/routes/zerodha/zerodhaTrade.routes.js;
--     server_etl/schdulers/expireZerodhaSession.js
--   Integration point: Zerodha logout/session invalidation
--   Reason: Atomic PostgreSQL write for Zerodha logout/session invalidation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_close_zerodha_session(
    p_user_ref_id varchar
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".zerodha
    SET session_status = 'false',
        access_token = '',
        refresh_token = '',
        enctoken = NULL,
        public_token = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE user_ref_id = p_user_ref_id;
END;
$procedure$;

-- File: trade.sp_create_nse_mf_mandate.sql
-- PROCEDURE: trade.sp_create_nse_mf_mandate
-- Function: createNseMfMandate
-- Prisma await: await prismaClient.nseMfMandate.create(...)
-- Purpose: Atomic PostgreSQL write for NSE MF / mandate creation.
-- Point: NSE MF / mandate creation
-- Used by: Controller/service flow createNseMfMandate() when replacing the matching Prisma write.
-- Replaces: prisma.nseMfMandate.create({ data }).
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_user_ref_id varchar; p_client_code varchar; p_amount varchar; p_account_no varchar;
--     p_ifsc_code varchar; p_start_date varchar; p_end_date varchar; p_request_payload_keys text[] DEFAULT NULL;
--     p_request_payload_values text[] DEFAULT NULL; p_mandate_status varchar DEFAULT 'PENDING'; p_created_at
--     timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: createNseMfMandate | Route / flow: Controller/service flow
--     createNseMfMandate() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.nseMfMandate.create(...)
--   Full routes / trigger: POST /nse/mf/mandate/create - persist a newly created mandate
--   Related .js file(s): server_trade/controllers/nsemf/nseMf.controller.js;
--     server_trade/routes/nseMf/nseMf.routes.js; server_etl/schdulers/mfOrderStatusSync.js;
--     server_etl/schdulers/mandateStatusTracker.js
--   Integration point: NSE MF / mandate creation
--   Reason: Atomic PostgreSQL write for NSE MF / mandate creation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_create_nse_mf_mandate(
    p_id varchar,
    p_user_ref_id varchar,
    p_client_code varchar,
    p_amount varchar,
    p_account_no varchar,
    p_ifsc_code varchar,
    p_start_date varchar,
    p_end_date varchar,
    p_request_payload_keys text[] DEFAULT NULL,
    p_request_payload_values text[] DEFAULT NULL,
    p_mandate_status varchar DEFAULT 'PENDING',
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "trade".nse_mf_mandate (
        id, user_ref_id, client_code, amount, account_no, ifsc_code,
        start_date, end_date, request_payload, mandate_status, created_at,
        updated_at, reminder_days_sent
    ) VALUES (
        p_id, p_user_ref_id, p_client_code, p_amount, p_account_no, p_ifsc_code,
        p_start_date, p_end_date,
        "integration".fn_jsonb_from_pairs(p_request_payload_keys, p_request_payload_values),
        p_mandate_status,
        p_created_at, p_created_at, '[]'::jsonb
    );
END;
$procedure$;

-- File: trade.sp_create_nse_mf_order.sql
-- PROCEDURE: trade.sp_create_nse_mf_order
-- Function: createNseMfOrder
-- Prisma await: await prismaClient.nseMfOrder.create(...)
-- Purpose: Atomic PostgreSQL write for NSE MF / capture SIP, lumpsum, or redemption intent before API call.
-- Point: NSE MF / capture SIP, lumpsum, or redemption intent before API call
-- Used by: Controller/service flow createNseMfOrder() when replacing the matching Prisma write.
-- Replaces: prisma.nseMfOrder.create({ data }).
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_user_ref_id varchar; p_trade_type varchar; p_scheme_code varchar; p_client_code
--     varchar; p_amount varchar; p_amc_code varchar DEFAULT NULL; p_folio_no varchar DEFAULT NULL; p_account_no
--     varchar DEFAULT NULL; p_mobile_no varchar DEFAULT NULL; p_email varchar DEFAULT NULL; p_request_payload_keys
--     text[] DEFAULT NULL; p_request_payload_values text[] DEFAULT NULL; p_order_status varchar DEFAULT 'PENDING';
--     p_start_date varchar DEFAULT NULL; p_end_date varchar DEFAULT NULL; p_frequency_type varchar DEFAULT NULL;
--     p_installment_no varchar DEFAULT NULL; p_sip_mandate_id varchar DEFAULT NULL; p_created_at timestamp DEFAULT
--     CURRENT_TIMESTAMP
--   Code / route integration target: Code function: createNseMfOrder | Route / flow: Controller/service flow
--     createNseMfOrder() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.nseMfOrder.create(...)
--   Full routes / trigger: POST /nse/mf/sip/create; POST /nse/mf/lumpsum/purchase; POST /nse/mf/redeem - save the
--     order intent before/after the NSE API call
--   Related .js file(s): server_trade/controllers/nsemf/nseMf.controller.js;
--     server_trade/routes/nseMf/nseMf.routes.js; server_etl/schdulers/mfOrderStatusSync.js;
--     server_etl/schdulers/mandateStatusTracker.js
--   Integration point: NSE MF / capture SIP, lumpsum, or redemption intent before API call
--   Reason: Atomic PostgreSQL write for NSE MF / capture SIP, lumpsum, or redemption intent before API call.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_create_nse_mf_order(
    p_id varchar,
    p_user_ref_id varchar,
    p_trade_type varchar,
    p_scheme_code varchar,
    p_client_code varchar,
    p_amount varchar,
    p_amc_code varchar DEFAULT NULL,
    p_folio_no varchar DEFAULT NULL,
    p_account_no varchar DEFAULT NULL,
    p_mobile_no varchar DEFAULT NULL,
    p_email varchar DEFAULT NULL,
    p_request_payload_keys text[] DEFAULT NULL,
    p_request_payload_values text[] DEFAULT NULL,
    p_order_status varchar DEFAULT 'PENDING',
    p_start_date varchar DEFAULT NULL,
    p_end_date varchar DEFAULT NULL,
    p_frequency_type varchar DEFAULT NULL,
    p_installment_no varchar DEFAULT NULL,
    p_sip_mandate_id varchar DEFAULT NULL,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "trade".nse_mf_order (
        id, user_ref_id, trade_type, scheme_code, amc_code, client_code,
        amount, folio_no, start_date, end_date, frequency_type, installment_no,
        sip_mandate_id, account_no, mobile_no, email, request_payload,
        order_status, created_at, updated_at,
        lumpsum_allotment_delayed_email_sent,
        lumpsum_payment_confirmed_email_sent, sip_activation_email_sent,
        sip_linked_mandate_email_sent, order_failed_email_sent,
        order_rejection_push_sent
    ) VALUES (
        p_id, p_user_ref_id, p_trade_type, p_scheme_code, p_amc_code,
        p_client_code, p_amount, p_folio_no, p_start_date, p_end_date,
        p_frequency_type, p_installment_no, p_sip_mandate_id, p_account_no,
        p_mobile_no, p_email,
        "integration".fn_jsonb_from_pairs(p_request_payload_keys, p_request_payload_values),
        p_order_status,
        p_created_at, p_created_at, false, false, false, false, false, false
    );
END;
$procedure$;

-- File: trade.sp_create_order.sql
-- PROCEDURE: trade.sp_create_order
-- Function: createOrder
-- Prisma await: await prismaClient.order.create(...)
-- Purpose: Atomic PostgreSQL write for Orders / generic order creation.
-- Point: Orders / generic order creation
-- Used by: Controller/service flow createOrder() when replacing the matching Prisma write.
-- Replaces: prisma.order.create({ data }). All parameters map to Order fields.
-- IDs continue to be generated by the application, matching Prisma's cuid flow.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_portfolio_id varchar; p_order_type text; p_quantity numeric; p_remaining_qty numeric;
--     p_price numeric; p_status text; p_stock_id varchar DEFAULT NULL; p_cep_ref_id varchar DEFAULT NULL;
--     p_traded_currency varchar DEFAULT NULL; p_transaction_id varchar DEFAULT NULL; p_user_id varchar DEFAULT NULL;
--     p_settled_currency varchar DEFAULT NULL; p_limit_price numeric DEFAULT NULL; p_stop_price numeric DEFAULT NULL;
--     p_gtn_response text DEFAULT NULL; p_inventory_id varchar DEFAULT NULL; p_created_at timestamp DEFAULT
--     CURRENT_TIMESTAMP
--   Code / route integration target: Code function: createOrder | Route / flow: Controller/service flow createOrder()
--     when replacing the matching Prisma write. | Replace or support: await prismaClient.order.create(...)
--   Full routes / trigger: POST /trade/preTransaction; PUT /trade/postTransaction; GET /trade/orderbook -
--     create/update order and transaction records used by the trade flow
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Orders / generic order creation
--   Reason: Atomic PostgreSQL write for Orders / generic order creation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_create_order(
    p_id varchar,
    p_portfolio_id varchar,
    p_order_type text,
    p_quantity numeric,
    p_remaining_qty numeric,
    p_price numeric,
    p_status text,
    p_stock_id varchar DEFAULT NULL,
    p_cep_ref_id varchar DEFAULT NULL,
    p_traded_currency varchar DEFAULT NULL,
    p_transaction_id varchar DEFAULT NULL,
    p_user_id varchar DEFAULT NULL,
    p_settled_currency varchar DEFAULT NULL,
    p_limit_price numeric DEFAULT NULL,
    p_stop_price numeric DEFAULT NULL,
    p_gtn_response text DEFAULT NULL,
    p_inventory_id varchar DEFAULT NULL,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "trade"."order" (
        id, portfolio_id, stock_id, cep_ref_id, traded_currency,
        transaction_id, user_id, settled_currency, order_type, limit_price,
        stop_price, quantity, remaining_qty, gtn_response, price, status,
        created_at, updated_at, inventory_id
    ) VALUES (
        p_id, p_portfolio_id, p_stock_id, p_cep_ref_id, p_traded_currency,
        p_transaction_id, p_user_id, p_settled_currency,
        p_order_type::order_type_enum, p_limit_price, p_stop_price, p_quantity,
        p_remaining_qty, p_gtn_response, p_price, p_status::order_status_enum,
        p_created_at, p_created_at, p_inventory_id
    );
END;
$procedure$;

-- File: trade.sp_create_transaction.sql
-- PROCEDURE: trade.sp_create_transaction
-- Function: createTransaction
-- Prisma await: await prismaClient.transaction.create(...)
-- Purpose: Atomic PostgreSQL write for Transactions / generic transaction creation.
-- Point: Transactions / generic transaction creation
-- Used by: Controller/service flow createTransaction() when replacing the matching Prisma write.
-- Replaces: prisma.transaction.create({ data }) outside the NSE-specific flow.
-- Parameters map directly to the existing Transaction Prisma fields.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_status text; p_scripcode varchar; p_user_ref_id varchar; p_quantity numeric;
--     p_transaction_type text; p_order_id varchar DEFAULT NULL; p_tag varchar DEFAULT NULL; p_account_id varchar
--     DEFAULT NULL; p_trading_symbol varchar DEFAULT NULL; p_average_price numeric DEFAULT NULL;
--     p_order_response_keys text[] DEFAULT NULL; p_order_response_values text[] DEFAULT NULL; p_asset varchar DEFAULT
--     'EQUITY'; p_filled_quantity numeric DEFAULT 0; p_pending_quantity numeric DEFAULT 0; p_cancelled_quantity
--     numeric DEFAULT 0; p_transaction_date varchar DEFAULT NULL; p_description text DEFAULT NULL; p_is_expired
--     boolean DEFAULT false; p_platform varchar DEFAULT 'WEB'; p_provider varchar DEFAULT 'ZERODHA'; p_trade_platform
--     varchar DEFAULT 'NUQI'; p_broker_client_id varchar DEFAULT NULL; p_exchange_order_id varchar DEFAULT NULL;
--     p_guid varchar DEFAULT NULL; p_parent_transaction_id varchar DEFAULT NULL; p_cep_ref_id varchar DEFAULT NULL;
--     p_enctoken text DEFAULT NULL; p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: createTransaction | Route / flow: Controller/service flow
--     createTransaction() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.transaction.create(...)
--   Full routes / trigger: POST /trade/preTransaction; PUT /trade/postTransaction; GET /trade/orderbook -
--     create/update order and transaction records used by the trade flow
--   Related .js file(s): server_trade/controllers/billdesk/payment.controller.js;
--     server_trade/scripts/collect-billdesk-uat-proof.js; server_trade/test.js; server_trade/utils/billdesk.js;
--     server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js
--   Integration point: Transactions / generic transaction creation
--   Reason: Atomic PostgreSQL write for Transactions / generic transaction creation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_create_transaction(
    p_id varchar,
    p_status text,
    p_scripcode varchar,
    p_user_ref_id varchar,
    p_quantity numeric,
    p_transaction_type text,
    p_order_id varchar DEFAULT NULL,
    p_tag varchar DEFAULT NULL,
    p_account_id varchar DEFAULT NULL,
    p_trading_symbol varchar DEFAULT NULL,
    p_average_price numeric DEFAULT NULL,
    p_order_response_keys text[] DEFAULT NULL,
    p_order_response_values text[] DEFAULT NULL,
    p_asset varchar DEFAULT 'EQUITY',
    p_filled_quantity numeric DEFAULT 0,
    p_pending_quantity numeric DEFAULT 0,
    p_cancelled_quantity numeric DEFAULT 0,
    p_transaction_date varchar DEFAULT NULL,
    p_description text DEFAULT NULL,
    p_is_expired boolean DEFAULT false,
    p_platform varchar DEFAULT 'WEB',
    p_provider varchar DEFAULT 'ZERODHA',
    p_trade_platform varchar DEFAULT 'NUQI',
    p_broker_client_id varchar DEFAULT NULL,
    p_exchange_order_id varchar DEFAULT NULL,
    p_guid varchar DEFAULT NULL,
    p_parent_transaction_id varchar DEFAULT NULL,
    p_cep_ref_id varchar DEFAULT NULL,
    p_enctoken text DEFAULT NULL,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "trade"."transaction" (
        id, status, scripcode, tag, exchange_order_id, account_id,
        trading_symbol, user_ref_id, average_price, order_response, asset, guid,
        filled_quantity, quantity, pending_quantity, cancelled_quantity,
        transaction_date, parent_transaction_id, cep_ref_id, description,
        enctoken, is_expired, platform, provider, trade_platform, created_at,
        updated_at, transaction_type, order_id, broker_client_id
    ) VALUES (
        p_id, p_status::global_transaction_status, p_scripcode, p_tag,
        p_exchange_order_id, p_account_id, p_trading_symbol, p_user_ref_id,
        p_average_price,
        "integration".fn_jsonb_from_pairs(p_order_response_keys, p_order_response_values),
        p_asset, p_guid, p_filled_quantity,
        p_quantity, p_pending_quantity, p_cancelled_quantity,
        p_transaction_date, p_parent_transaction_id, p_cep_ref_id,
        p_description, p_enctoken, p_is_expired, p_platform, p_provider,
        p_trade_platform, p_created_at, p_created_at,
        p_transaction_type::order_direction_type, p_order_id, p_broker_client_id
    );
END;
$procedure$;

-- File: trade.sp_delete_watchlist.sql
-- PROCEDURE: trade.sp_delete_watchlist
-- Function: deleteWatchlist
-- Prisma await: await prismaClient.watchlist.delete(...)
-- Purpose: Atomic PostgreSQL write for Watchlist deletion; details cascade through the table foreign key..
-- Point: Watchlist deletion; details cascade through the table foreign key.
-- Used by: DELETE /watchlist/delete
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar; p_watchlist_name varchar
--   Code / route integration target: Code function: deleteWatchlist | Route / flow: DELETE /watchlist/delete |
--     Replace or support: await prismaClient.watchlist.delete(...)
--   Full routes / trigger: DELETE /watchlist/delete - delete a user-owned watchlist
--   Related .js file(s): server_trade/routes/watchlist/watchlist.routes.js;
--     server_trade/controllers/watchlist/watchlist.controller.js
--   Integration point: Watchlist deletion; details cascade through the table foreign key.
--   Reason: Atomic PostgreSQL write for Watchlist deletion; details cascade through the table foreign key..
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_delete_watchlist(
    p_user_ref_id varchar,
    p_watchlist_name varchar
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    DELETE FROM "trade".watchlist
    WHERE user_ref_id = p_user_ref_id
      AND name = LOWER(BTRIM(p_watchlist_name));

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Watchlist not found for user';
    END IF;
END;
$procedure$;

-- File: trade.sp_delete_watchlist_stock.sql
-- PROCEDURE: trade.sp_delete_watchlist_stock
-- Function: deleteWatchlistStock
-- Prisma await: await prismaClient.watchlistDetail.delete(...)
-- Purpose: Atomic PostgreSQL write for Delete one stock while enforcing watchlist ownership..
-- Point: Delete one stock while enforcing watchlist ownership.
-- Used by: DELETE /watchlist/deleteitem
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar; p_watchlist_name varchar; p_scripcode integer
--   Code / route integration target: Code function: deleteWatchlistStock | Route / flow: DELETE /watchlist/deleteitem
--     | Replace or support: await prismaClient.watchlistDetail.delete(...)
--   Full routes / trigger: DELETE /watchlist/deleteitem - remove one stock from a user-owned watchlist
--   Related .js file(s): server_trade/routes/watchlist/watchlist.routes.js;
--     server_trade/controllers/watchlist/watchlist.controller.js
--   Integration point: Delete one stock while enforcing watchlist ownership.
--   Reason: Atomic PostgreSQL write for Delete one stock while enforcing watchlist ownership..
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_delete_watchlist_stock(
    p_user_ref_id varchar,
    p_watchlist_name varchar,
    p_scripcode integer
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    DELETE FROM "trade".watchlistdetail d
    USING "trade".watchlist w
    WHERE d.watchlist_id = w.id
      AND w.user_ref_id = p_user_ref_id
      AND w.name = LOWER(BTRIM(p_watchlist_name))
      AND d.scripcode = p_scripcode;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock is not present in the user watchlist';
    END IF;
END;
$procedure$;

-- File: trade.sp_expire_all_zerodha_sessions.sql
-- PROCEDURE: trade.sp_expire_all_zerodha_sessions
-- Function: expireAllZerodhaSessions
-- Prisma await: await prismaClient.zerodha.updateMany(...)
-- Purpose: Atomic PostgreSQL write for Zerodha session-expiry scheduler.
-- Point: Zerodha session-expiry scheduler
-- Used by: server_etl/schdulers/expireZerodhaSession.js
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters
--   Code / route integration target: Code function: expireAllZerodhaSessions | Route / flow:
--     server_etl/schdulers/expireZerodhaSession.js | Replace or support: await prismaClient.zerodha.updateMany(...)
--   Full routes / trigger: No HTTP route - server_etl/schdulers/expireZerodhaSession.js expires stored sessions
--   Related .js file(s): server_trade/controllers/zerodha/zerodhaAuth.controller.js;
--     server_trade/controllers/zerodha/zerodhaPortfolio.controller.js;
--     server_trade/controllers/zerodha/zerodhaTrade.controller.js; server_trade/routes/zerodha/zerodhaAuth.routes.js;
--     server_trade/routes/zerodha/zerodhaPortfolio.routes.js; server_trade/routes/zerodha/zerodhaTrade.routes.js;
--     server_etl/schdulers/expireZerodhaSession.js
--   Integration point: Zerodha session-expiry scheduler
--   Reason: Atomic PostgreSQL write for Zerodha session-expiry scheduler.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_expire_all_zerodha_sessions()
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".zerodha
    SET session_status = 'false',
        updated_at = CURRENT_TIMESTAMP
    WHERE COALESCE(session_status, '') <> 'false';
END;
$procedure$;

-- File: trade.sp_expire_pending_transactions.sql
-- PROCEDURE: trade.sp_expire_pending_transactions
-- Function: expirePendingTransactions
-- Prisma await: await prismaClient.transaction.updateMany(...)
-- Purpose: Atomic PostgreSQL write for Transactions scheduler.
-- Point: Transactions scheduler
-- Used by: expireTransactions / stale NSE MF order processing.
-- Parameter p_cutoff corresponds to the Prisma created_at lt filter.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_cutoff timestamp
--   Code / route integration target: Code function: expirePendingTransactions | Route / flow: expireTransactions /
--     stale NSE MF order processing. | Replace or support: await prismaClient.transaction.updateMany(...)
--   Full routes / trigger: No HTTP route - server_etl/schdulers/expireTransactions.js expires stale pending
--     transactions
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Transactions scheduler
--   Reason: Atomic PostgreSQL write for Transactions scheduler.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_expire_pending_transactions(
    p_cutoff timestamp
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade"."transaction"
    SET status = 'EXPIRED'::global_transaction_status,
        is_expired = true,
        updated_at = CURRENT_TIMESTAMP
    WHERE status::text = 'PENDING'
      AND created_at < p_cutoff;
END;
$procedure$;

-- File: trade.sp_finalize_nse_mf_order_and_create_transaction.sql
-- PROCEDURE: trade.sp_finalize_nse_mf_order_and_create_transaction
-- Function: finalizeNseMfOrderAndCreateTransaction
-- Prisma await: await prismaClient.$transaction([prismaClient.nseMfOrder.update(...), prismaClient.transaction.create(...)])
-- Purpose: Atomic PostgreSQL write for NSE MF SIP/lumpsum/redemption finalization.
-- Point: NSE MF SIP/lumpsum/redemption finalization
-- Used by: POST NSE MF order flows after the NSE API response is received.
-- Replaces: NseMfOrder.update() followed by Transaction.create().
-- Why procedure: both Main DB writes must commit or roll back together.
-- Parameters map to the existing Prisma NseMfOrder.update data and
-- Transaction.create data. IDs/order_id are still generated by the application.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_nse_mf_order_id varchar; p_order_status varchar; p_nse_status varchar; p_nse_response_keys text[];
--     p_nse_response_values text[]; p_nse_order_id varchar; p_nse_order_status varchar; p_nse_remark text;
--     p_transaction_id varchar; p_transaction_order_id varchar; p_transaction_status text; p_scripcode varchar;
--     p_trading_symbol varchar; p_user_ref_id varchar; p_account_id varchar; p_average_price numeric; p_quantity
--     numeric; p_transaction_date varchar; p_description text; p_transaction_type text
--   Code / route integration target: Code function: finalizeNseMfOrderAndCreateTransaction | Route / flow: POST NSE
--     MF order flows after the NSE API response is received. | Replace or support: await
--     prismaClient.$transaction([prismaClient.nseMfOrder.update(...), prismaClient.transaction.create(...)])
--   Full routes / trigger: POST /nse/mf/sip/create; POST /nse/mf/lumpsum/purchase; POST /nse/mf/redeem - finalize the
--     NSE order and create its transaction atomically
--   Related .js file(s): server_trade/controllers/nsemf/nseMf.controller.js;
--     server_trade/routes/nseMf/nseMf.routes.js; server_etl/schdulers/mfOrderStatusSync.js;
--     server_etl/schdulers/mandateStatusTracker.js
--   Integration point: NSE MF SIP/lumpsum/redemption finalization
--   Reason: Atomic PostgreSQL write for NSE MF SIP/lumpsum/redemption finalization.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_finalize_nse_mf_order_and_create_transaction(
    p_nse_mf_order_id varchar,
    p_order_status varchar,
    p_nse_status varchar,
    p_nse_response_keys text[],
    p_nse_response_values text[],
    p_nse_order_id varchar,
    p_nse_order_status varchar,
    p_nse_remark text,
    p_transaction_id varchar,
    p_transaction_order_id varchar,
    p_transaction_status text,
    p_scripcode varchar,
    p_trading_symbol varchar,
    p_user_ref_id varchar,
    p_account_id varchar,
    p_average_price numeric,
    p_quantity numeric,
    p_transaction_date varchar,
    p_description text,
    p_transaction_type text
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".nse_mf_order
    SET order_status = p_order_status,
        nse_status = p_nse_status,
        nse_response = "integration".fn_jsonb_from_pairs(p_nse_response_keys, p_nse_response_values),
        nse_order_id = p_nse_order_id,
        nse_order_status = p_nse_order_status,
        nse_remark = p_nse_remark,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_nse_mf_order_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NSE MF order not found: %', p_nse_mf_order_id;
    END IF;

    INSERT INTO "trade"."transaction" (
        id, order_id, status, scripcode, trading_symbol, exchange_order_id,
        user_ref_id, account_id, order_response, asset, average_price,
        filled_quantity, quantity, pending_quantity, cancelled_quantity,
        transaction_date, description, is_expired, provider, created_at,
        updated_at, transaction_type
    ) VALUES (
        p_transaction_id,
        p_transaction_order_id,
        p_transaction_status::global_transaction_status,
        p_scripcode,
        p_trading_symbol,
        p_nse_order_id,
        p_user_ref_id,
        p_account_id,
        "integration".fn_jsonb_from_pairs(p_nse_response_keys, p_nse_response_values),
        'MF',
        p_average_price,
        0,
        p_quantity,
        0,
        0,
        p_transaction_date,
        p_description,
        false,
        'NSE_MF',
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP,
        p_transaction_type::order_direction_type
    );
END;
$procedure$;

-- File: trade.sp_recalculate_portfolio_invested_amount.sql
-- PROCEDURE: trade.sp_recalculate_portfolio_invested_amount
-- Function: recalculatePortfolioInvestedAmount
-- Prisma await: await prismaClient.$transaction([prismaClient.transaction.aggregate(...), prismaClient.portfolio.update(...)])
-- Purpose: Atomic PostgreSQL write for Portfolio cached invested amount.
-- Point: Portfolio cached invested amount
-- Used by: Controller/service flow recalculatePortfolioInvestedAmount() when replacing the matching Prisma write.
-- Recalculates a portfolio from completed/revamped Main DB transactions for the
-- same user and asset type. Current market value remains application-calculated.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_portfolio_id varchar
--   Code / route integration target: Code function: recalculatePortfolioInvestedAmount | Route / flow:
--     Controller/service flow recalculatePortfolioInvestedAmount() when replacing the matching Prisma write. |
--     Replace or support: await prismaClient.$transaction([prismaClient.transaction.aggregate(...),
--     prismaClient.portfolio.update(...)])
--   Full routes / trigger: POST /trade/preTransaction; PUT /trade/postTransaction; GET /trade/portfolio - maintain
--     portfolio/inventory records around the trade lifecycle
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Portfolio cached invested amount
--   Reason: Atomic PostgreSQL write for Portfolio cached invested amount.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_recalculate_portfolio_invested_amount(
    p_portfolio_id varchar
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".portfolio p
    SET invested_amount = COALESCE((
            SELECT SUM(
                CASE
                    WHEN t.transaction_type::text = 'BUY'
                        THEN t.quantity * COALESCE(t.average_price, 0)
                    WHEN t.transaction_type::text = 'SELL'
                        THEN -(t.quantity * COALESCE(t.average_price, 0))
                    ELSE 0
                END
            )
            FROM "trade"."transaction" t
            WHERE t.user_ref_id = p.user_id
              AND UPPER(COALESCE(t.asset, 'EQUITY')) = p.type::text
              AND t.status::text IN ('COMPLETED', 'REVAMPED')
        ), 0),
        updated_at = CURRENT_TIMESTAMP
    WHERE p.id = p_portfolio_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'Portfolio not found: %', p_portfolio_id; END IF;
END;
$procedure$;

-- File: trade.sp_record_mf_portfolio_milestone.sql
-- PROCEDURE: trade.sp_record_mf_portfolio_milestone
-- Function: recordMfPortfolioMilestone
-- Prisma await: await tradeDB.mfPortfolioMilestone.createMany(...)
-- Purpose: Atomic PostgreSQL write for MF portfolio milestone notification de-duplication.
-- Point: MF portfolio milestone notification de-duplication
-- Used by: server_etl/schdulers/mfPortfolioMilestoneNotifier.js
-- Parameters map to Prisma MfPortfolioMilestone.createMany().
-- ----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_mf_portfolio_milestones_user_milestone
    ON "trade".mf_portfolio_milestones(user_id, milestone);

-- >>> INTEGRATION METADATA
--   Parameters: p_user_id varchar; p_milestone integer; p_notified_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: recordMfPortfolioMilestone | Route / flow:
--     server_etl/schdulers/mfPortfolioMilestoneNotifier.js | Replace or support: await
--     tradeDB.mfPortfolioMilestone.createMany(...)
--   Full routes / trigger: No HTTP route - server_etl/schdulers/mfPortfolioMilestoneNotifier.js reads/records
--     notification milestones
--   Related .js file(s): server_etl/schdulers/mfPortfolioMilestoneNotifier.js
--   Integration point: MF portfolio milestone notification de-duplication
--   Reason: Atomic PostgreSQL write for MF portfolio milestone notification de-duplication.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_record_mf_portfolio_milestone(
    p_user_id varchar,
    p_milestone integer,
    p_notified_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_milestone <= 0 THEN
        RAISE EXCEPTION 'Milestone must be greater than zero';
    END IF;

    INSERT INTO "trade".mf_portfolio_milestones (
        user_id, milestone, notified_at
    ) VALUES (
        p_user_id, p_milestone, p_notified_at
    )
    ON CONFLICT (user_id, milestone) DO NOTHING;
END;
$procedure$;

-- File: trade.sp_rename_watchlist.sql
-- PROCEDURE: trade.sp_rename_watchlist
-- Function: renameWatchlist
-- Prisma await: await prismaClient.watchlist.update(...)
-- Purpose: Atomic PostgreSQL write for Watchlist rename with user ownership validation.
-- Point: Watchlist rename with user ownership validation
-- Used by: PUT /watchlist/rename
-- Parameters map to req.user.user.id, body.watchlist, and body.newName.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar; p_watchlist_name varchar; p_new_name varchar
--   Code / route integration target: Code function: renameWatchlist | Route / flow: PUT /watchlist/rename | Replace
--     or support: await prismaClient.watchlist.update(...)
--   Full routes / trigger: PUT /watchlist/rename - rename a user-owned watchlist
--   Related .js file(s): server_trade/routes/watchlist/watchlist.routes.js;
--     server_trade/controllers/watchlist/watchlist.controller.js
--   Integration point: Watchlist rename with user ownership validation
--   Reason: Atomic PostgreSQL write for Watchlist rename with user ownership validation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_rename_watchlist(
    p_user_ref_id varchar,
    p_watchlist_name varchar,
    p_new_name varchar
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF NULLIF(BTRIM(p_new_name), '') IS NULL THEN
        RAISE EXCEPTION 'New watchlist name is required';
    END IF;

    IF EXISTS (
        SELECT 1 FROM "trade".watchlist
        WHERE user_ref_id = p_user_ref_id
          AND name = LOWER(BTRIM(p_new_name))
          AND name <> LOWER(BTRIM(p_watchlist_name))
    ) THEN
        RAISE EXCEPTION 'A watchlist with this name already exists';
    END IF;

    UPDATE "trade".watchlist
    SET name = LOWER(BTRIM(p_new_name)),
        updated_at = CURRENT_TIMESTAMP
    WHERE user_ref_id = p_user_ref_id
      AND name = LOWER(BTRIM(p_watchlist_name));

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Watchlist not found for user';
    END IF;
END;
$procedure$;

-- File: trade.sp_save_zerodha_trade.sql
-- PROCEDURE: trade.sp_save_zerodha_trade
-- Function: saveZerodhaTrade
-- Prisma await: await prismaClient.zerodhaTrade.create(...)
-- Purpose: Atomic PostgreSQL write for Zerodha order placement/modification/cancellation audit.
-- Point: Zerodha order placement/modification/cancellation audit
-- Used by: Controller/service flow saveZerodhaTrade() when replacing the matching Prisma write.
-- Prisma mapping: ZerodhaTrade id, zerodhaId, order_id, trade_response.
-- Updates an existing order_id; otherwise inserts the supplied Prisma ID.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_zerodha_id varchar; p_order_id varchar; p_trade_response_keys text[];
--     p_trade_response_values text[]; p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: saveZerodhaTrade | Route / flow: Controller/service flow
--     saveZerodhaTrade() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.zerodhaTrade.create(...)
--   Full routes / trigger: POST /kite/trade/orders/:variety; PUT /kite/trade/orders/:variety/:order_id; DELETE
--     /kite/trade/orders/:variety/:order_id - save Zerodha trade audit data
--   Related .js file(s): server_trade/controllers/zerodha/zerodhaAuth.controller.js;
--     server_trade/controllers/zerodha/zerodhaPortfolio.controller.js;
--     server_trade/controllers/zerodha/zerodhaTrade.controller.js; server_trade/routes/zerodha/zerodhaAuth.routes.js;
--     server_trade/routes/zerodha/zerodhaPortfolio.routes.js; server_trade/routes/zerodha/zerodhaTrade.routes.js;
--     server_etl/schdulers/expireZerodhaSession.js
--   Integration point: Zerodha order placement/modification/cancellation audit
--   Reason: Atomic PostgreSQL write for Zerodha order placement/modification/cancellation audit.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_save_zerodha_trade(
    p_id varchar,
    p_zerodha_id varchar,
    p_order_id varchar,
    p_trade_response_keys text[],
    p_trade_response_values text[],
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".zerodhatrade
    SET trade_response = "integration".fn_jsonb_from_pairs(p_trade_response_keys, p_trade_response_values)
    WHERE order_id = p_order_id;

    IF NOT FOUND THEN
        INSERT INTO "trade".zerodhatrade (
            id, "zerodhaId", order_id, trade_response, "createdAt"
        ) VALUES (
            p_id, p_zerodha_id, p_order_id,
            "integration".fn_jsonb_from_pairs(p_trade_response_keys, p_trade_response_values), p_created_at
        );
    END IF;
END;
$procedure$;

-- File: trade.sp_set_reverse_feed_batch_status.sql
-- PROCEDURE: trade.sp_set_reverse_feed_batch_status
-- Function: setReverseFeedBatchStatus
-- Prisma await: await prismaClient.transaction.updateMany(...)
-- Purpose: Atomic PostgreSQL write for Transactions / partner reverse-feed approval or rejection.
-- Point: Transactions / partner reverse-feed approval or rejection
-- Used by: Controller/service flow setReverseFeedBatchStatus() when replacing the matching Prisma write.
-- Replaces: transaction.updateMany({ where: { tag: { startsWith }}}).
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_tag_prefix varchar; p_status text
--   Code / route integration target: Code function: setReverseFeedBatchStatus | Route / flow: Controller/service flow
--     setReverseFeedBatchStatus() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.transaction.updateMany(...)
--   Full routes / trigger: PATCH /operations/reverse-feed/batches/:batchId/approve; PATCH
--     /operations/reverse-feed/batches/:batchId/reject - approve/reject all pending batch transactions
--   Related .js file(s): server_trade/controllers/partner/partnerReverseFeed.controller.js;
--     server_trade/routes/partner/partnerReverseFeed.routes.js;
--     server_trade/routes/operations/reverseFeedAdmin.routes.js
--   Integration point: Transactions / partner reverse-feed approval or rejection
--   Reason: Atomic PostgreSQL write for Transactions / partner reverse-feed approval or rejection.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_set_reverse_feed_batch_status(
    p_tag_prefix varchar,
    p_status text
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_status NOT IN ('COMPLETED', 'CANCELLED') THEN
        RAISE EXCEPTION 'Reverse-feed status must be COMPLETED or CANCELLED';
    END IF;

    UPDATE "trade"."transaction"
    SET status = p_status::global_transaction_status,
        updated_at = CURRENT_TIMESTAMP
    WHERE tag LIKE p_tag_prefix || '%'
      AND status::text = 'PENDING';
END;
$procedure$;

-- File: trade.sp_update_nse_mf_mandate_status.sql
-- PROCEDURE: trade.sp_update_nse_mf_mandate_status
-- Function: updateNseMfMandateStatus
-- Prisma await: await prismaClient.nseMfMandate.update(...)
-- Purpose: Atomic PostgreSQL write for NSE MF mandate tracking.
-- Point: NSE MF mandate tracking
-- Used by: Controller/service flow updateNseMfMandateStatus() when replacing the matching Prisma write.
-- Prisma mapping: where.id plus mandate_status/NSE/bank/eNACH response fields.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_mandate_status varchar DEFAULT NULL; p_nse_status varchar DEFAULT NULL;
--     p_nse_response_keys text[] DEFAULT NULL; p_nse_response_values text[] DEFAULT NULL; p_reg_status varchar
--     DEFAULT NULL; p_reg_remark text DEFAULT NULL; p_bank_status varchar DEFAULT NULL; p_enach_status varchar
--     DEFAULT NULL; p_umrn_no varchar DEFAULT NULL; p_reject_reason text DEFAULT NULL; p_last_status_sync timestamp
--     DEFAULT NULL
--   Code / route integration target: Code function: updateNseMfMandateStatus | Route / flow: Controller/service flow
--     updateNseMfMandateStatus() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.nseMfMandate.update(...)
--   Full routes / trigger: POST /nse/mf/mandates/sync; POST /operations/mf/users/:userId/mandates/sync; no-route
--     mandateStatusTracker scheduler - update mandate status
--   Related .js file(s): server_trade/controllers/nsemf/nseMf.controller.js;
--     server_trade/routes/nseMf/nseMf.routes.js; server_etl/schdulers/mfOrderStatusSync.js;
--     server_etl/schdulers/mandateStatusTracker.js
--   Integration point: NSE MF mandate tracking
--   Reason: Atomic PostgreSQL write for NSE MF mandate tracking.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_update_nse_mf_mandate_status(
    p_id varchar,
    p_mandate_status varchar DEFAULT NULL,
    p_nse_status varchar DEFAULT NULL,
    p_nse_response_keys text[] DEFAULT NULL,
    p_nse_response_values text[] DEFAULT NULL,
    p_reg_status varchar DEFAULT NULL,
    p_reg_remark text DEFAULT NULL,
    p_bank_status varchar DEFAULT NULL,
    p_enach_status varchar DEFAULT NULL,
    p_umrn_no varchar DEFAULT NULL,
    p_reject_reason text DEFAULT NULL,
    p_last_status_sync timestamp DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".nse_mf_mandate
    SET mandate_status = COALESCE(p_mandate_status, mandate_status),
        nse_status = COALESCE(p_nse_status, nse_status),
        nse_response = COALESCE("integration".fn_jsonb_from_pairs(p_nse_response_keys, p_nse_response_values), nse_response),
        reg_status = COALESCE(p_reg_status, reg_status),
        reg_remark = COALESCE(p_reg_remark, reg_remark),
        bank_status = COALESCE(p_bank_status, bank_status),
        enach_status = COALESCE(p_enach_status, enach_status),
        umrn_no = COALESCE(p_umrn_no, umrn_no),
        reject_reason = COALESCE(p_reject_reason, reject_reason),
        last_status_sync = COALESCE(p_last_status_sync, CURRENT_TIMESTAMP),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NSE MF mandate not found: %', p_id;
    END IF;
END;
$procedure$;

-- File: trade.sp_update_nse_mf_onboarding_step.sql
-- PROCEDURE: trade.sp_update_nse_mf_onboarding_step
-- Function: updateNseMfOnboardingStep
-- Prisma await: await prismaClient.nseMfOnboarding.update(...)
-- Purpose: Atomic PostgreSQL write for NSE MF onboarding.
-- Point: NSE MF onboarding
-- Used by: /nse/mf/onboarding step APIs.
-- Prisma mapping: user_ref_id, current_step, stepN_data, stepN_completed,
-- onboarding_status and submitted_at.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar; p_current_step integer; p_step_data_keys text[]; p_step_data_values text[];
--     p_step_completed boolean DEFAULT true; p_onboarding_status varchar DEFAULT NULL; p_submitted_at timestamp
--     DEFAULT NULL
--   Code / route integration target: Code function: updateNseMfOnboardingStep | Route / flow: /nse/mf/onboarding step
--     APIs. | Replace or support: await prismaClient.nseMfOnboarding.update(...)
--   Full routes / trigger: POST /nse/mf/onboarding/start; POST /nse/mf/onboarding/step1; POST
--     /nse/mf/onboarding/step2; POST /nse/mf/onboarding/step3; POST /nse/mf/onboarding/step4; POST
--     /nse/mf/onboarding/step5; POST /nse/mf/onboarding/step6; POST /nse/mf/onboarding/step7 - persist each
--     onboarding step
--   Related .js file(s): server_trade/controllers/nsemf/nseMfOnboarding.controller.js;
--     server_trade/routes/nseMf/nseMfOnboarding.routes.js; server_etl/schdulers/nseClientAuthPoll.js
--   Integration point: NSE MF onboarding
--   Reason: Atomic PostgreSQL write for NSE MF onboarding.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_update_nse_mf_onboarding_step(
    p_user_ref_id varchar,
    p_current_step integer,
    p_step_data_keys text[],
    p_step_data_values text[],
    p_step_completed boolean DEFAULT true,
    p_onboarding_status varchar DEFAULT NULL,
    p_submitted_at timestamp DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_current_step NOT BETWEEN 1 AND 7 THEN
        RAISE EXCEPTION 'current_step must be between 1 and 7';
    END IF;

    UPDATE "trade".nse_mf_onboarding
    SET current_step = GREATEST(current_step, p_current_step),
        step1_data = CASE WHEN p_current_step = 1 THEN "integration".fn_jsonb_from_pairs(p_step_data_keys, p_step_data_values) ELSE step1_data END,
        step1_completed = CASE WHEN p_current_step = 1 THEN p_step_completed ELSE step1_completed END,
        step2_data = CASE WHEN p_current_step = 2 THEN "integration".fn_jsonb_from_pairs(p_step_data_keys, p_step_data_values) ELSE step2_data END,
        step2_completed = CASE WHEN p_current_step = 2 THEN p_step_completed ELSE step2_completed END,
        step3_data = CASE WHEN p_current_step = 3 THEN "integration".fn_jsonb_from_pairs(p_step_data_keys, p_step_data_values) ELSE step3_data END,
        step3_completed = CASE WHEN p_current_step = 3 THEN p_step_completed ELSE step3_completed END,
        step4_data = CASE WHEN p_current_step = 4 THEN "integration".fn_jsonb_from_pairs(p_step_data_keys, p_step_data_values) ELSE step4_data END,
        step4_completed = CASE WHEN p_current_step = 4 THEN p_step_completed ELSE step4_completed END,
        step5_data = CASE WHEN p_current_step = 5 THEN "integration".fn_jsonb_from_pairs(p_step_data_keys, p_step_data_values) ELSE step5_data END,
        step5_completed = CASE WHEN p_current_step = 5 THEN p_step_completed ELSE step5_completed END,
        step6_data = CASE WHEN p_current_step = 6 THEN "integration".fn_jsonb_from_pairs(p_step_data_keys, p_step_data_values) ELSE step6_data END,
        step6_completed = CASE WHEN p_current_step = 6 THEN p_step_completed ELSE step6_completed END,
        step7_data = CASE WHEN p_current_step = 7 THEN "integration".fn_jsonb_from_pairs(p_step_data_keys, p_step_data_values) ELSE step7_data END,
        step7_completed = CASE WHEN p_current_step = 7 THEN p_step_completed ELSE step7_completed END,
        onboarding_status = COALESCE(p_onboarding_status, onboarding_status),
        submitted_at = COALESCE(p_submitted_at, submitted_at),
        updated_at = CURRENT_TIMESTAMP
    WHERE user_ref_id = p_user_ref_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NSE MF onboarding record not found for user: %', p_user_ref_id;
    END IF;
END;
$procedure$;

-- File: trade.sp_update_nse_mf_order_status.sql
-- PROCEDURE: trade.sp_update_nse_mf_order_status
-- Function: updateNseMfOrderStatus
-- Prisma await: await prismaClient.nseMfOrder.update(...)
-- Purpose: Atomic PostgreSQL write for NSE MF SIP, lumpsum, redemption, allotment, and payout synchronization.
-- Point: NSE MF SIP, lumpsum, redemption, allotment, and payout synchronization
-- Used by: Controller/service flow updateNseMfOrderStatus() when replacing the matching Prisma write.
-- Prisma mapping: where.id plus the same NseMfOrder data fields.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_order_status varchar DEFAULT NULL; p_nse_status varchar DEFAULT NULL;
--     p_nse_order_status varchar DEFAULT NULL; p_nse_order_id varchar DEFAULT NULL; p_nse_remark text DEFAULT NULL;
--     p_nse_response_keys text[] DEFAULT NULL; p_nse_response_values text[] DEFAULT NULL; p_folio_no varchar DEFAULT
--     NULL; p_allotted_nav numeric DEFAULT NULL; p_allotted_qty numeric DEFAULT NULL; p_allotted_amount numeric
--     DEFAULT NULL; p_exit_load numeric DEFAULT NULL; p_stt numeric DEFAULT NULL; p_tax_amount numeric DEFAULT NULL;
--     p_rta_txn_no varchar DEFAULT NULL; p_payout_status varchar DEFAULT NULL; p_payout_report_keys text[] DEFAULT
--     NULL; p_payout_report_values text[] DEFAULT NULL
--   Code / route integration target: Code function: updateNseMfOrderStatus | Route / flow: Controller/service flow
--     updateNseMfOrderStatus() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.nseMfOrder.update(...)
--   Full routes / trigger: POST /nse/mf/orders/sync; POST /nse/mf/sip/cancel; POST /nse/mf/order/cancel; no-route
--     mfOrderStatusSync scheduler - persist NSE order status
--   Related .js file(s): server_trade/controllers/nsemf/nseMf.controller.js;
--     server_trade/routes/nseMf/nseMf.routes.js; server_etl/schdulers/mfOrderStatusSync.js;
--     server_etl/schdulers/mandateStatusTracker.js
--   Integration point: NSE MF SIP, lumpsum, redemption, allotment, and payout synchronization
--   Reason: Atomic PostgreSQL write for NSE MF SIP, lumpsum, redemption, allotment, and payout synchronization.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_update_nse_mf_order_status(
    p_id varchar,
    p_order_status varchar DEFAULT NULL,
    p_nse_status varchar DEFAULT NULL,
    p_nse_order_status varchar DEFAULT NULL,
    p_nse_order_id varchar DEFAULT NULL,
    p_nse_remark text DEFAULT NULL,
    p_nse_response_keys text[] DEFAULT NULL,
    p_nse_response_values text[] DEFAULT NULL,
    p_folio_no varchar DEFAULT NULL,
    p_allotted_nav numeric DEFAULT NULL,
    p_allotted_qty numeric DEFAULT NULL,
    p_allotted_amount numeric DEFAULT NULL,
    p_exit_load numeric DEFAULT NULL,
    p_stt numeric DEFAULT NULL,
    p_tax_amount numeric DEFAULT NULL,
    p_rta_txn_no varchar DEFAULT NULL,
    p_payout_status varchar DEFAULT NULL,
    p_payout_report_keys text[] DEFAULT NULL,
    p_payout_report_values text[] DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".nse_mf_order
    SET order_status = COALESCE(p_order_status, order_status),
        nse_status = COALESCE(p_nse_status, nse_status),
        nse_order_status = COALESCE(p_nse_order_status, nse_order_status),
        nse_order_id = COALESCE(p_nse_order_id, nse_order_id),
        nse_remark = COALESCE(p_nse_remark, nse_remark),
        nse_response = COALESCE("integration".fn_jsonb_from_pairs(p_nse_response_keys, p_nse_response_values), nse_response),
        folio_no = COALESCE(p_folio_no, folio_no),
        allotted_nav = COALESCE(p_allotted_nav, allotted_nav),
        allotted_qty = COALESCE(p_allotted_qty, allotted_qty),
        allotted_amount = COALESCE(p_allotted_amount, allotted_amount),
        exit_load = COALESCE(p_exit_load, exit_load),
        stt = COALESCE(p_stt, stt),
        tax_amount = COALESCE(p_tax_amount, tax_amount),
        rta_txn_no = COALESCE(p_rta_txn_no, rta_txn_no),
        payout_status = COALESCE(p_payout_status, payout_status),
        payout_report = COALESCE("integration".fn_jsonb_from_pairs(p_payout_report_keys, p_payout_report_values), payout_report),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NSE MF order not found: %', p_id;
    END IF;
END;
$procedure$;

-- File: trade.sp_update_nse_mf_ucc_status.sql
-- PROCEDURE: trade.sp_update_nse_mf_ucc_status
-- Function: updateNseMfUccStatus
-- Prisma await: await prismaClient.nseMfUCC.update(...)
-- Purpose: Atomic PostgreSQL write for NSE MF UCC, KYC, bank, FATCA, and client authorization status.
-- Point: NSE MF UCC, KYC, bank, FATCA, and client authorization status
-- Used by: Controller/service flow updateNseMfUccStatus() when replacing the matching Prisma write.
-- Prisma mapping: where.user_ref_id plus the corresponding status/response data.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar; p_ucc_status varchar DEFAULT NULL; p_nse_status varchar DEFAULT NULL;
--     p_nse_response_keys text[] DEFAULT NULL; p_nse_response_values text[] DEFAULT NULL; p_kyc_status varchar
--     DEFAULT NULL; p_kyc_check_response_keys text[] DEFAULT NULL; p_kyc_check_response_values text[] DEFAULT NULL;
--     p_bank_dtl_status varchar DEFAULT NULL; p_bank_dtl_response_keys text[] DEFAULT NULL;
--     p_bank_dtl_response_values text[] DEFAULT NULL; p_fatca_status varchar DEFAULT NULL; p_fatca_nse_response_keys
--     text[] DEFAULT NULL; p_fatca_nse_response_values text[] DEFAULT NULL; p_client_auth_status varchar DEFAULT
--     NULL; p_client_auth_response_keys text[] DEFAULT NULL; p_client_auth_response_values text[] DEFAULT NULL
--   Code / route integration target: Code function: updateNseMfUccStatus | Route / flow: Controller/service flow
--     updateNseMfUccStatus() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.nseMfUCC.update(...)
--   Full routes / trigger: POST /nse/mf/ucc/register; POST /nse/mf/fatca/register; POST
--     /operations/mf/users/:userId/ucc/refresh - update UCC/KYC/FATCA state
--   Related .js file(s): server_trade/controllers/nsemf/nseMfOnboarding.controller.js;
--     server_trade/routes/nseMf/nseMfOnboarding.routes.js; server_etl/schdulers/nseClientAuthPoll.js
--   Integration point: NSE MF UCC, KYC, bank, FATCA, and client authorization status
--   Reason: Atomic PostgreSQL write for NSE MF UCC, KYC, bank, FATCA, and client authorization status.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_update_nse_mf_ucc_status(
    p_user_ref_id varchar,
    p_ucc_status varchar DEFAULT NULL,
    p_nse_status varchar DEFAULT NULL,
    p_nse_response_keys text[] DEFAULT NULL,
    p_nse_response_values text[] DEFAULT NULL,
    p_kyc_status varchar DEFAULT NULL,
    p_kyc_check_response_keys text[] DEFAULT NULL,
    p_kyc_check_response_values text[] DEFAULT NULL,
    p_bank_dtl_status varchar DEFAULT NULL,
    p_bank_dtl_response_keys text[] DEFAULT NULL,
    p_bank_dtl_response_values text[] DEFAULT NULL,
    p_fatca_status varchar DEFAULT NULL,
    p_fatca_nse_response_keys text[] DEFAULT NULL,
    p_fatca_nse_response_values text[] DEFAULT NULL,
    p_client_auth_status varchar DEFAULT NULL,
    p_client_auth_response_keys text[] DEFAULT NULL,
    p_client_auth_response_values text[] DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".nse_mf_ucc
    SET ucc_status = COALESCE(p_ucc_status, ucc_status),
        nse_status = COALESCE(p_nse_status, nse_status),
        nse_response = COALESCE("integration".fn_jsonb_from_pairs(p_nse_response_keys, p_nse_response_values), nse_response),
        kyc_status = COALESCE(p_kyc_status, kyc_status),
        kyc_check_response = COALESCE("integration".fn_jsonb_from_pairs(p_kyc_check_response_keys, p_kyc_check_response_values), kyc_check_response),
        bank_dtl_status = COALESCE(p_bank_dtl_status, bank_dtl_status),
        bank_dtl_response = COALESCE("integration".fn_jsonb_from_pairs(p_bank_dtl_response_keys, p_bank_dtl_response_values), bank_dtl_response),
        fatca_status = COALESCE(p_fatca_status, fatca_status),
        fatca_nse_response = COALESCE("integration".fn_jsonb_from_pairs(p_fatca_nse_response_keys, p_fatca_nse_response_values), fatca_nse_response),
        client_auth_status = COALESCE(p_client_auth_status, client_auth_status),
        client_auth_response = COALESCE("integration".fn_jsonb_from_pairs(p_client_auth_response_keys, p_client_auth_response_values), client_auth_response),
        updated_at = CURRENT_TIMESTAMP
    WHERE user_ref_id = p_user_ref_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NSE MF UCC record not found for user: %', p_user_ref_id;
    END IF;
END;
$procedure$;

-- File: trade.sp_update_order_status.sql
-- PROCEDURE: trade.sp_update_order_status
-- Function: updateOrderStatus
-- Prisma await: await prismaClient.order.update(...)
-- Purpose: Atomic PostgreSQL write for Orders.
-- Point: Orders
-- Used by: Controller/service flow updateOrderStatus() when replacing the matching Prisma write.
-- Prisma mapping: where.id plus data.status, remaining_qty, gtn_response.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_status text; p_remaining_qty numeric DEFAULT NULL; p_gtn_response text DEFAULT NULL
--   Code / route integration target: Code function: updateOrderStatus | Route / flow: Controller/service flow
--     updateOrderStatus() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.order.update(...)
--   Full routes / trigger: POST /trade/preTransaction; PUT /trade/postTransaction; GET /trade/orderbook -
--     create/update order and transaction records used by the trade flow
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Orders
--   Reason: Atomic PostgreSQL write for Orders.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_update_order_status(
    p_id varchar,
    p_status text,
    p_remaining_qty numeric DEFAULT NULL,
    p_gtn_response text DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade"."order"
    SET status = p_status::order_status_enum,
        remaining_qty = COALESCE(p_remaining_qty, remaining_qty),
        gtn_response = COALESCE(p_gtn_response, gtn_response),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order not found: %', p_id;
    END IF;
END;
$procedure$;

-- File: trade.sp_update_transaction_status.sql
-- PROCEDURE: trade.sp_update_transaction_status
-- Function: updateTransactionStatus
-- Prisma await: await prismaClient.transaction.update(...)
-- Purpose: Atomic PostgreSQL write for Transactions / order-status synchronization.
-- Point: Transactions / order-status synchronization
-- Used by: NSE MF status sync, cancellation, and order update flows.
-- Prisma mapping: where.id plus data.status, filled_quantity,
-- pending_quantity, cancelled_quantity, average_price, order_response.
-- Optional parameters preserve the existing value when NULL.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_status text; p_filled_quantity numeric DEFAULT NULL; p_pending_quantity numeric
--     DEFAULT NULL; p_cancelled_quantity numeric DEFAULT NULL; p_average_price numeric DEFAULT NULL;
--     p_order_response_keys text[] DEFAULT NULL; p_order_response_values text[] DEFAULT NULL
--   Code / route integration target: Code function: updateTransactionStatus | Route / flow: NSE MF status sync,
--     cancellation, and order update flows. | Replace or support: await prismaClient.transaction.update(...)
--   Full routes / trigger: POST /nse/mf/orders/sync; POST /nse/mf/sip/cancel; POST /nse/mf/order/cancel; PUT
--     /trade/postTransaction - persist synchronized transaction status
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Transactions / order-status synchronization
--   Reason: Atomic PostgreSQL write for Transactions / order-status synchronization.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_update_transaction_status(
    p_id varchar,
    p_status text,
    p_filled_quantity numeric DEFAULT NULL,
    p_pending_quantity numeric DEFAULT NULL,
    p_cancelled_quantity numeric DEFAULT NULL,
    p_average_price numeric DEFAULT NULL,
    p_order_response_keys text[] DEFAULT NULL,
    p_order_response_values text[] DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade"."transaction"
    SET status = p_status::global_transaction_status,
        filled_quantity = COALESCE(p_filled_quantity, filled_quantity),
        pending_quantity = COALESCE(p_pending_quantity, pending_quantity),
        cancelled_quantity = COALESCE(p_cancelled_quantity, cancelled_quantity),
        average_price = COALESCE(p_average_price, average_price),
        order_response = COALESCE("integration".fn_jsonb_from_pairs(p_order_response_keys, p_order_response_values), order_response),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction not found: %', p_id;
    END IF;
END;
$procedure$;

-- File: trade.sp_update_zerodha_connection.sql
-- PROCEDURE: trade.sp_update_zerodha_connection
-- Function: updateZerodhaConnection
-- Prisma await: await prismaClient.zerodha.updateMany(...)
-- Purpose: Atomic PostgreSQL write for Zerodha enctoken, client ID, and T&C updates.
-- Point: Zerodha enctoken, client ID, and T&C updates
-- Used by: Controller/service flow updateZerodhaConnection() when replacing the matching Prisma write.
-- Replaces the small zerodha.update() calls in auth/transaction controllers.
-- NULL parameters preserve the existing value.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar; p_zerodha_user_id varchar DEFAULT NULL; p_enctoken text DEFAULT NULL;
--     p_is_tnc_accepted boolean DEFAULT NULL
--   Code / route integration target: Code function: updateZerodhaConnection | Route / flow: Controller/service flow
--     updateZerodhaConnection() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.zerodha.updateMany(...)
--   Full routes / trigger: POST /user/enctoken; POST /kite/user/enctoken; POST /trade/zerodha/tncacceptance - update
--     connection token/client/T&C state
--   Related .js file(s): server_trade/controllers/zerodha/zerodhaAuth.controller.js;
--     server_trade/controllers/zerodha/zerodhaPortfolio.controller.js;
--     server_trade/controllers/zerodha/zerodhaTrade.controller.js; server_trade/routes/zerodha/zerodhaAuth.routes.js;
--     server_trade/routes/zerodha/zerodhaPortfolio.routes.js; server_trade/routes/zerodha/zerodhaTrade.routes.js;
--     server_etl/schdulers/expireZerodhaSession.js
--   Integration point: Zerodha enctoken, client ID, and T&C updates
--   Reason: Atomic PostgreSQL write for Zerodha enctoken, client ID, and T&C updates.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_update_zerodha_connection(
    p_user_ref_id varchar,
    p_zerodha_user_id varchar DEFAULT NULL,
    p_enctoken text DEFAULT NULL,
    p_is_tnc_accepted boolean DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".zerodha
    SET zerodha_user_id = COALESCE(p_zerodha_user_id, zerodha_user_id),
        enctoken = COALESCE(p_enctoken, enctoken),
        is_tnc_accepted = COALESCE(p_is_tnc_accepted, is_tnc_accepted),
        updated_at = CURRENT_TIMESTAMP
    WHERE user_ref_id = p_user_ref_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Zerodha connection not found for user: %', p_user_ref_id;
    END IF;
END;
$procedure$;

-- File: trade.sp_upsert_inventory.sql
-- PROCEDURE: trade.sp_upsert_inventory
-- Function: upsertInventory
-- Prisma await: await prismaClient.inventory.upsert(...)
-- Purpose: Atomic PostgreSQL write for Portfolio inventory/holding master.
-- Point: Portfolio inventory/holding master
-- Used by: Controller/service flow upsertInventory() when replacing the matching Prisma write.
-- Covers Inventory.create/update/upsert parameters used by Order relationships.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_name varchar; p_type text; p_user_id varchar; p_quantity numeric; p_stock_key varchar
--     DEFAULT NULL; p_cep_ref_id varchar DEFAULT NULL; p_traded_currency varchar DEFAULT NULL; p_settled_currency
--     varchar DEFAULT NULL; p_portfolio_id varchar DEFAULT NULL; p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: upsertInventory | Route / flow: Controller/service flow
--     upsertInventory() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.inventory.upsert(...)
--   Full routes / trigger: POST /trade/preTransaction; PUT /trade/postTransaction; GET /trade/portfolio - maintain
--     portfolio/inventory records around the trade lifecycle
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Portfolio inventory/holding master
--   Reason: Atomic PostgreSQL write for Portfolio inventory/holding master.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_upsert_inventory(
    p_id varchar,
    p_name varchar,
    p_type text,
    p_user_id varchar,
    p_quantity numeric,
    p_stock_key varchar DEFAULT NULL,
    p_cep_ref_id varchar DEFAULT NULL,
    p_traded_currency varchar DEFAULT NULL,
    p_settled_currency varchar DEFAULT NULL,
    p_portfolio_id varchar DEFAULT NULL,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "trade".inventory (
        id, name, stock_key, cep_ref_id, type, traded_currency,
        settled_currency, user_id, quantity, created_at, updated_at, "portfolioId"
    ) VALUES (
        p_id, p_name, p_stock_key, p_cep_ref_id, p_type::inventory_type,
        p_traded_currency, p_settled_currency, p_user_id, p_quantity,
        p_created_at, p_created_at, p_portfolio_id
    )
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name, stock_key = EXCLUDED.stock_key,
        cep_ref_id = EXCLUDED.cep_ref_id, type = EXCLUDED.type,
        traded_currency = EXCLUDED.traded_currency,
        settled_currency = EXCLUDED.settled_currency,
        user_id = EXCLUDED.user_id, quantity = EXCLUDED.quantity,
        "portfolioId" = EXCLUDED."portfolioId", updated_at = CURRENT_TIMESTAMP;
END;
$procedure$;

-- File: trade.sp_upsert_nse_mf_ucc.sql
-- PROCEDURE: trade.sp_upsert_nse_mf_ucc
-- Function: upsertNseMfUcc
-- Prisma await: await prismaClient.nseMfUCC.upsert(...)
-- Purpose: Atomic PostgreSQL write for NSE MF / UCC registration and status persistence.
-- Point: NSE MF / UCC registration and status persistence
-- Used by: Controller/service flow upsertNseMfUcc() when replacing the matching Prisma write.
-- Replaces: prisma.nseMfUCC.upsert({ where: { user_ref_id }, create, update }).
-- Required identity fields match the Prisma create payload; optional fields map
-- to the same UCC columns and preserve existing values during an update.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_user_ref_id varchar; p_client_code varchar; p_primary_holder_first_name varchar
--     DEFAULT NULL; p_primary_holder_last_name varchar DEFAULT NULL; p_primary_holder_pan varchar DEFAULT NULL;
--     p_primary_holder_dob_incorporation varchar DEFAULT NULL; p_gender varchar DEFAULT NULL; p_tax_status varchar
--     DEFAULT NULL; p_holding_nature varchar DEFAULT NULL; p_email varchar DEFAULT NULL; p_indian_mobile_no varchar
--     DEFAULT NULL; p_account_no_1 varchar DEFAULT NULL; p_ifsc_code_1 varchar DEFAULT NULL; p_address_1 varchar
--     DEFAULT NULL; p_city varchar DEFAULT NULL; p_state varchar DEFAULT NULL; p_pincode varchar DEFAULT NULL;
--     p_country varchar DEFAULT NULL; p_request_payload_keys text[] DEFAULT NULL; p_request_payload_values text[]
--     DEFAULT NULL; p_ucc_status varchar DEFAULT 'PENDING'; p_nse_status varchar DEFAULT NULL; p_nse_response_keys
--     text[] DEFAULT NULL; p_nse_response_values text[] DEFAULT NULL; p_reg_id varchar DEFAULT NULL; p_reg_status
--     varchar DEFAULT NULL; p_reg_remark text DEFAULT NULL; p_client_auth_status varchar DEFAULT NULL;
--     p_client_authorized_email_sent boolean DEFAULT false; p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: upsertNseMfUcc | Route / flow: Controller/service flow
--     upsertNseMfUcc() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.nseMfUCC.upsert(...)
--   Full routes / trigger: POST /nse/mf/ucc/register; POST /nse/mf/fatca/register; POST /nse/mf/fatca/retry - persist
--     UCC/FATCA registration data
--   Related .js file(s): server_trade/controllers/nsemf/nseMfOnboarding.controller.js;
--     server_trade/routes/nseMf/nseMfOnboarding.routes.js; server_etl/schdulers/nseClientAuthPoll.js
--   Integration point: NSE MF / UCC registration and status persistence
--   Reason: Atomic PostgreSQL write for NSE MF / UCC registration and status persistence.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_upsert_nse_mf_ucc(
    p_id varchar,
    p_user_ref_id varchar,
    p_client_code varchar,
    p_primary_holder_first_name varchar DEFAULT NULL,
    p_primary_holder_last_name varchar DEFAULT NULL,
    p_primary_holder_pan varchar DEFAULT NULL,
    p_primary_holder_dob_incorporation varchar DEFAULT NULL,
    p_gender varchar DEFAULT NULL,
    p_tax_status varchar DEFAULT NULL,
    p_holding_nature varchar DEFAULT NULL,
    p_email varchar DEFAULT NULL,
    p_indian_mobile_no varchar DEFAULT NULL,
    p_account_no_1 varchar DEFAULT NULL,
    p_ifsc_code_1 varchar DEFAULT NULL,
    p_address_1 varchar DEFAULT NULL,
    p_city varchar DEFAULT NULL,
    p_state varchar DEFAULT NULL,
    p_pincode varchar DEFAULT NULL,
    p_country varchar DEFAULT NULL,
    p_request_payload_keys text[] DEFAULT NULL,
    p_request_payload_values text[] DEFAULT NULL,
    p_ucc_status varchar DEFAULT 'PENDING',
    p_nse_status varchar DEFAULT NULL,
    p_nse_response_keys text[] DEFAULT NULL,
    p_nse_response_values text[] DEFAULT NULL,
    p_reg_id varchar DEFAULT NULL,
    p_reg_status varchar DEFAULT NULL,
    p_reg_remark text DEFAULT NULL,
    p_client_auth_status varchar DEFAULT NULL,
    p_client_authorized_email_sent boolean DEFAULT false,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".nse_mf_ucc
    SET client_code = p_client_code,
        primary_holder_first_name = COALESCE(p_primary_holder_first_name, primary_holder_first_name),
        primary_holder_last_name = COALESCE(p_primary_holder_last_name, primary_holder_last_name),
        primary_holder_pan = COALESCE(p_primary_holder_pan, primary_holder_pan),
        primary_holder_dob_incorporation = COALESCE(p_primary_holder_dob_incorporation, primary_holder_dob_incorporation),
        gender = COALESCE(p_gender, gender),
        tax_status = COALESCE(p_tax_status, tax_status),
        holding_nature = COALESCE(p_holding_nature, holding_nature),
        email = COALESCE(p_email, email),
        indian_mobile_no = COALESCE(p_indian_mobile_no, indian_mobile_no),
        account_no_1 = COALESCE(p_account_no_1, account_no_1),
        ifsc_code_1 = COALESCE(p_ifsc_code_1, ifsc_code_1),
        address_1 = COALESCE(p_address_1, address_1),
        city = COALESCE(p_city, city),
        state = COALESCE(p_state, state),
        pincode = COALESCE(p_pincode, pincode),
        country = COALESCE(p_country, country),
        request_payload = COALESCE("integration".fn_jsonb_from_pairs(p_request_payload_keys, p_request_payload_values), request_payload),
        ucc_status = COALESCE(p_ucc_status, ucc_status),
        nse_status = COALESCE(p_nse_status, nse_status),
        nse_response = COALESCE("integration".fn_jsonb_from_pairs(p_nse_response_keys, p_nse_response_values), nse_response),
        reg_id = COALESCE(p_reg_id, reg_id),
        reg_status = COALESCE(p_reg_status, reg_status),
        reg_remark = COALESCE(p_reg_remark, reg_remark),
        client_auth_status = COALESCE(p_client_auth_status, client_auth_status),
        client_authorized_email_sent = client_authorized_email_sent OR p_client_authorized_email_sent,
        updated_at = CURRENT_TIMESTAMP
    WHERE user_ref_id = p_user_ref_id;

    IF NOT FOUND THEN
        INSERT INTO "trade".nse_mf_ucc (
            id, user_ref_id, client_code, primary_holder_first_name,
            primary_holder_last_name, primary_holder_pan,
            primary_holder_dob_incorporation, gender, tax_status, holding_nature,
            email, indian_mobile_no, account_no_1, ifsc_code_1, address_1,
            city, state, pincode, country, request_payload, ucc_status,
            nse_status, nse_response, reg_id, reg_status, reg_remark,
            client_auth_status, fatca_submitted, client_authorized_email_sent,
            created_at, updated_at
        ) VALUES (
            p_id, p_user_ref_id, p_client_code, p_primary_holder_first_name,
            p_primary_holder_last_name, p_primary_holder_pan,
            p_primary_holder_dob_incorporation, p_gender, p_tax_status,
            p_holding_nature, p_email, p_indian_mobile_no, p_account_no_1,
            p_ifsc_code_1, p_address_1, p_city, p_state, p_pincode, p_country,
            "integration".fn_jsonb_from_pairs(p_request_payload_keys, p_request_payload_values),
            p_ucc_status, p_nse_status,
            "integration".fn_jsonb_from_pairs(p_nse_response_keys, p_nse_response_values),
            p_reg_id, p_reg_status, p_reg_remark, p_client_auth_status,
            false, p_client_authorized_email_sent,
            p_created_at, p_created_at
        );
    END IF;
END;
$procedure$;

-- File: trade.sp_upsert_portfolio.sql
-- PROCEDURE: trade.sp_upsert_portfolio
-- Function: upsertPortfolio
-- Prisma await: await prismaClient.portfolio.upsert(...)
-- Purpose: Atomic PostgreSQL write for Portfolio master record.
-- Point: Portfolio master record
-- Used by: Controller/service flow upsertPortfolio() when replacing the matching Prisma write.
-- Covers future Portfolio.create/update/upsert calls even though current runtime
-- primarily calculates holdings from Transaction. Parameters map to Portfolio.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_user_id varchar; p_name varchar; p_type text; p_invested_amount numeric DEFAULT 0;
--     p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: upsertPortfolio | Route / flow: Controller/service flow
--     upsertPortfolio() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.portfolio.upsert(...)
--   Full routes / trigger: POST /trade/preTransaction; PUT /trade/postTransaction; GET /trade/portfolio - maintain
--     portfolio/inventory records around the trade lifecycle
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Portfolio master record
--   Reason: Atomic PostgreSQL write for Portfolio master record.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_upsert_portfolio(
    p_id varchar,
    p_user_id varchar,
    p_name varchar,
    p_type text,
    p_invested_amount numeric DEFAULT 0,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "trade".portfolio (
        id, user_id, invested_amount, name, type, created_at, updated_at
    ) VALUES (
        p_id, p_user_id, p_invested_amount, p_name,
        p_type::portfolio_type_enum, p_created_at, p_created_at
    )
    ON CONFLICT (id) DO UPDATE SET
        user_id = EXCLUDED.user_id,
        invested_amount = EXCLUDED.invested_amount,
        name = EXCLUDED.name,
        type = EXCLUDED.type,
        updated_at = CURRENT_TIMESTAMP;
END;
$procedure$;

-- File: trade.sp_upsert_watchlist.sql
-- PROCEDURE: trade.sp_upsert_watchlist
-- Function: upsertWatchlist
-- Prisma await: await prismaClient.watchlist.findFirst(...); await prismaClient.watchlist.create/update(...)
-- Purpose: Atomic PostgreSQL write for Watchlist creation/update.
-- Point: Watchlist creation/update
-- Used by: POST /watchlist/create
-- Parameters map to Prisma Watchlist data. Pass NULL p_id to generate an ID.
-- ----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_watchlist_user_name
    ON "trade".watchlist(user_ref_id, name);

-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_user_ref_id varchar; p_name varchar; p_is_active boolean DEFAULT true; p_created_at
--     timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: upsertWatchlist | Route / flow: POST /watchlist/create | Replace
--     or support: await prismaClient.watchlist.findFirst(...); await prismaClient.watchlist.create/update(...)
--   Full routes / trigger: POST /watchlist/create - create/update a watchlist and add validated stocks
--   Related .js file(s): server_trade/routes/watchlist/watchlist.routes.js;
--     server_trade/controllers/watchlist/watchlist.controller.js
--   Integration point: Watchlist creation/update
--   Reason: Atomic PostgreSQL write for Watchlist creation/update.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_upsert_watchlist(
    p_id varchar,
    p_user_ref_id varchar,
    p_name varchar,
    p_is_active boolean DEFAULT true,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id varchar := COALESCE(NULLIF(p_id, ''), gen_random_uuid()::text);
BEGIN
    IF NULLIF(BTRIM(p_user_ref_id), '') IS NULL THEN
        RAISE EXCEPTION 'Watchlist user_ref_id is required';
    END IF;
    IF NULLIF(BTRIM(p_name), '') IS NULL THEN
        RAISE EXCEPTION 'Watchlist name is required';
    END IF;

    INSERT INTO "trade".watchlist (
        id, user_ref_id, name, is_active, created_at, updated_at
    ) VALUES (
        v_id, p_user_ref_id, LOWER(BTRIM(p_name)), p_is_active,
        p_created_at, p_created_at
    )
    ON CONFLICT (user_ref_id, name) DO UPDATE SET
        is_active = EXCLUDED.is_active,
        updated_at = CURRENT_TIMESTAMP;
END;
$procedure$;

-- File: trade.sp_upsert_zerodha_session.sql
-- PROCEDURE: trade.sp_upsert_zerodha_session
-- Function: upsertZerodhaSession
-- Prisma await: await prismaClient.zerodha.upsert(...)
-- Purpose: Atomic PostgreSQL write for Zerodha login/session persistence.
-- Point: Zerodha login/session persistence
-- Used by: Controller/service flow upsertZerodhaSession() when replacing the matching Prisma write.
-- Replaces: prisma.zerodha.upsert({ where: { user_ref_id }, update, create }).
-- Sensitive token values are accepted exactly as encrypted by the application.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_user_ref_id varchar; p_zerodha_user_id varchar; p_access_token text; p_refresh_token
--     text; p_email varchar; p_user_name varchar; p_enctoken text DEFAULT NULL; p_public_token varchar DEFAULT NULL;
--     p_avatar_url varchar DEFAULT NULL; p_session_status varchar DEFAULT 'true'; p_is_tnc_accepted boolean DEFAULT
--     false; p_login_time timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: upsertZerodhaSession | Route / flow: Controller/service flow
--     upsertZerodhaSession() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.zerodha.upsert(...)
--   Full routes / trigger: POST /user/session/token; POST /kite/user/session/token - create/update the Zerodha login
--     session
--   Related .js file(s): server_trade/controllers/zerodha/zerodhaAuth.controller.js;
--     server_trade/controllers/zerodha/zerodhaPortfolio.controller.js;
--     server_trade/controllers/zerodha/zerodhaTrade.controller.js; server_trade/routes/zerodha/zerodhaAuth.routes.js;
--     server_trade/routes/zerodha/zerodhaPortfolio.routes.js; server_trade/routes/zerodha/zerodhaTrade.routes.js;
--     server_etl/schdulers/expireZerodhaSession.js
--   Integration point: Zerodha login/session persistence
--   Reason: Atomic PostgreSQL write for Zerodha login/session persistence.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "trade".sp_upsert_zerodha_session(
    p_id varchar,
    p_user_ref_id varchar,
    p_zerodha_user_id varchar,
    p_access_token text,
    p_refresh_token text,
    p_email varchar,
    p_user_name varchar,
    p_enctoken text DEFAULT NULL,
    p_public_token varchar DEFAULT NULL,
    p_avatar_url varchar DEFAULT NULL,
    p_session_status varchar DEFAULT 'true',
    p_is_tnc_accepted boolean DEFAULT false,
    p_login_time timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "trade".zerodha
    SET zerodha_user_id = p_zerodha_user_id,
        access_token = p_access_token,
        refresh_token = p_refresh_token,
        enctoken = p_enctoken,
        public_token = p_public_token,
        login_time = p_login_time,
        session_status = p_session_status,
        email = p_email,
        "userName" = p_user_name,
        "avatarUrl" = p_avatar_url,
        is_tnc_accepted = p_is_tnc_accepted,
        updated_at = CURRENT_TIMESTAMP
    WHERE user_ref_id = p_user_ref_id;

    IF NOT FOUND THEN
        INSERT INTO "trade".zerodha (
            id, user_ref_id, zerodha_user_id, access_token, refresh_token,
            enctoken, public_token, login_time, created_at, updated_at,
            session_status, email, "userName", "avatarUrl", is_tnc_accepted
        ) VALUES (
            p_id, p_user_ref_id, p_zerodha_user_id, p_access_token,
            p_refresh_token, p_enctoken, p_public_token, p_login_time,
            p_login_time, p_login_time, p_session_status, p_email,
            p_user_name, p_avatar_url, p_is_tnc_accepted
        );
    END IF;
END;
$procedure$;



-- Functions integrated from all_final_function_mandar.sql
-- FUNCTION: trade.fn_get_user_positions
-- Function: getUserPositions
-- Prisma await: await prismaClient.transaction.findMany(...)
-- Purpose: PostgreSQL read/calculation for Portfolio / Transactions.
-- Point: Portfolio / Transactions
-- Used by: GET /trade/portfolio and GET /operations/portfolio/:userId
-- Replaces: transaction.findMany() followed by BUY/SELL quantity aggregation.
-- Parameters:
--   p_user_ref_id = Prisma Transaction.user_ref_id
--   p_account_id   = optional Prisma Transaction.account_id filter
-- Returns one position per symbol, asset, and CEP basket.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar; p_account_id varchar DEFAULT NULL
--   Code / route integration target: Code function: getUserPositions | Route / flow: GET /trade/portfolio and GET
--     /operations/portfolio/:userId | Replace or support: await prismaClient.transaction.findMany(...)
--   Full routes / trigger: GET /trade/portfolio; GET /operations/portfolio/:userId - build user/admin portfolio
--     positions and summary
--   Related .js file(s): server_trade/controllers/partner/partnerReports.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/controllers/operations/users.controller.js; server_trade/routes/operations/users.routes.js
--   Integration point: Portfolio / Transactions
--   Reason: PostgreSQL read/calculation for Portfolio / Transactions.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "trade".fn_get_user_positions(
    p_user_ref_id varchar,
    p_account_id varchar DEFAULT NULL
)
RETURNS TABLE (
    trading_symbol varchar,
    scripcode varchar,
    asset varchar,
    cep_ref_id varchar,
    buy_quantity numeric,
    sell_quantity numeric,
    net_quantity numeric,
    invested_amount numeric,
    sold_amount numeric,
    average_buy_price numeric
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        t.trading_symbol,
        t.scripcode,
        COALESCE(t.asset, 'EQUITY') AS asset,
        t.cep_ref_id,
        SUM(CASE WHEN t.transaction_type::text = 'BUY' THEN t.quantity ELSE 0 END) AS buy_quantity,
        SUM(CASE WHEN t.transaction_type::text = 'SELL' THEN t.quantity ELSE 0 END) AS sell_quantity,
        SUM(CASE WHEN t.transaction_type::text = 'BUY' THEN t.quantity ELSE -t.quantity END) AS net_quantity,
        SUM(CASE WHEN t.transaction_type::text = 'BUY'
                 THEN t.quantity * COALESCE(t.average_price, 0) ELSE 0 END) AS invested_amount,
        SUM(CASE WHEN t.transaction_type::text = 'SELL'
                 THEN t.quantity * COALESCE(t.average_price, 0) ELSE 0 END) AS sold_amount,
        CASE
            WHEN SUM(CASE WHEN t.transaction_type::text = 'BUY' THEN t.quantity ELSE 0 END) = 0 THEN 0
            ELSE
                SUM(CASE WHEN t.transaction_type::text = 'BUY'
                         THEN t.quantity * COALESCE(t.average_price, 0) ELSE 0 END)
                / NULLIF(SUM(CASE WHEN t.transaction_type::text = 'BUY' THEN t.quantity ELSE 0 END), 0)
        END AS average_buy_price
    FROM "trade"."transaction" t
    WHERE t.user_ref_id = p_user_ref_id
      AND t.status::text IN ('COMPLETED', 'REVAMPED')
      AND t.transaction_type::text IN ('BUY', 'SELL')
      AND (
          p_account_id IS NULL
          OR t.account_id = p_account_id
          OR t.account_id = p_user_ref_id
      )
    GROUP BY t.trading_symbol, t.scripcode, COALESCE(t.asset, 'EQUITY'), t.cep_ref_id;
$function$;

-- FUNCTION: trade.fn_get_remaining_equity_qty
-- Function: getRemainingEquityQty
-- Prisma await: await prismaClient.transaction.findMany(...)
-- Purpose: PostgreSQL read/calculation for Portfolio / Equity and ETF sell validation.
-- Point: Portfolio / Equity and ETF sell validation
-- Used by: GET /trade/remaining_qty
-- Replaces: completed BUY/SELL transaction quantity calculation.
-- Note: This returns NUQI quantity only. The controller must still apply the
-- live/cached Zerodha quantity rule after calling this function.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar; p_scripcode varchar; p_account_id varchar DEFAULT NULL
--   Code / route integration target: Code function: getRemainingEquityQty | Route / flow: GET /trade/remaining_qty |
--     Replace or support: await prismaClient.transaction.findMany(...)
--   Full routes / trigger: GET /trade/remaining_qty - validate available EQUITY/ETF quantity before sell
--   Related .js file(s): server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Portfolio / Equity and ETF sell validation
--   Reason: PostgreSQL read/calculation for Portfolio / Equity and ETF sell validation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "trade".fn_get_remaining_equity_qty(
    p_user_ref_id varchar,
    p_scripcode varchar,
    p_account_id varchar DEFAULT NULL
)
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
    SELECT GREATEST(
        COALESCE(SUM(
            CASE
                WHEN t.transaction_type::text = 'BUY' THEN t.quantity
                WHEN t.transaction_type::text = 'SELL' THEN -t.quantity
                ELSE 0
            END
        ), 0),
        0
    )
    FROM "trade"."transaction" t
    WHERE t.user_ref_id = p_user_ref_id
      AND t.scripcode = p_scripcode
      AND UPPER(COALESCE(t.asset, 'EQUITY')) IN ('EQUITY', 'ETF')
      AND t.status::text IN ('COMPLETED', 'REVAMPED')
      AND (p_account_id IS NULL OR t.account_id IN (p_account_id, p_user_ref_id));
$function$;

-- FUNCTION: trade.fn_get_remaining_mf_qty
-- Function: getRemainingMfQty
-- Prisma await: await prismaClient.transaction.findMany(...)
-- Purpose: PostgreSQL read/calculation for Portfolio / Mutual Fund redemption validation.
-- Point: Portfolio / Mutual Fund redemption validation
-- Used by: GET /trade/remaining_qty_mf
-- Replaces: completed MF transaction aggregation plus confirmed pending debit.
-- Parameters match Transaction.user_ref_id and Transaction.trading_symbol.
-- Market NAV lookup remains in Node.js.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar; p_scheme_code varchar
--   Code / route integration target: Code function: getRemainingMfQty | Route / flow: GET /trade/remaining_qty_mf |
--     Replace or support: await prismaClient.transaction.findMany(...)
--   Full routes / trigger: GET /trade/remaining_qty_mf - validate available mutual-fund units before redemption
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Portfolio / Mutual Fund redemption validation
--   Reason: PostgreSQL read/calculation for Portfolio / Mutual Fund redemption validation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "trade".fn_get_remaining_mf_qty(
    p_user_ref_id varchar,
    p_scheme_code varchar
)
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
    WITH completed AS (
        SELECT COALESCE(SUM(
            CASE
                WHEN t.transaction_type::text = 'BUY' THEN t.quantity
                WHEN t.transaction_type::text = 'SELL' THEN -t.quantity
                ELSE 0
            END
        ), 0) AS qty
        FROM "trade"."transaction" t
        WHERE t.user_ref_id = p_user_ref_id
          AND UPPER(COALESCE(t.asset, '')) = 'MF'
          AND t.trading_symbol = p_scheme_code
          AND t.status::text IN ('COMPLETED', 'REVAMPED')
    ),
    confirmed_pending_sell AS (
        SELECT
            COALESCE(SUM(
                CASE
                    WHEN COALESCE(t.description, '') ILIKE '%All Units%' THEN 0
                    ELSE CASE WHEN t.filled_quantity > 0 THEN t.filled_quantity ELSE t.quantity END
                END
            ), 0) AS qty,
            BOOL_OR(COALESCE(t.description, '') ILIKE '%All Units%') AS sell_all
        FROM "trade"."transaction" t
        JOIN "trade".nse_mf_order o
          ON o.nse_order_id = t.exchange_order_id
         AND o.user_ref_id = t.user_ref_id
        WHERE t.user_ref_id = p_user_ref_id
          AND UPPER(COALESCE(t.asset, '')) = 'MF'
          AND t.trading_symbol = p_scheme_code
          AND t.transaction_type::text = 'SELL'
          AND t.status::text IN ('PENDING', 'PARTIALLY_FILLED')
          AND (
              UPPER(COALESCE(o.nse_remark, '')) LIKE '%FINAL VALIDATED%'
              OR UPPER(COALESCE(o.nse_remark, '')) LIKE '%AUTO VALIDATED%'
              OR UPPER(COALESCE(o.nse_remark, '')) LIKE '%VALIDATED BY RTA%'
              OR UPPER(COALESCE(o.nse_remark, '')) LIKE '%ALLOTMENT DONE%'
          )
    )
    SELECT CASE
        WHEN COALESCE(p.sell_all, false) THEN 0
        ELSE GREATEST(c.qty - p.qty, 0)
    END
    FROM completed c
    CROSS JOIN confirmed_pending_sell p;
$function$;

-- FUNCTION: trade.fn_get_cep_positions
-- Function: getCepPositions
-- Prisma await: await prismaClient.transaction.findMany(...)
-- Purpose: PostgreSQL read/calculation for Portfolio / CEP basket holdings.
-- Point: Portfolio / CEP basket holdings
-- Used by: GET /trade/remaining_qty_cep and GET /trade/portfolio
-- Returns Main DB quantities. Basket composition from Market DB is merged in JS.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar; p_cep_ref_id varchar DEFAULT NULL
--   Code / route integration target: Code function: getCepPositions | Route / flow: GET /trade/remaining_qty_cep and
--     GET /trade/portfolio | Replace or support: await prismaClient.transaction.findMany(...)
--   Full routes / trigger: GET /trade/remaining_qty_cep; GET /trade/portfolio - calculate CEP basket holdings
--   Related .js file(s): server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/partner/partnerReports.controller.js;
--     server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Portfolio / CEP basket holdings
--   Reason: PostgreSQL read/calculation for Portfolio / CEP basket holdings.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "trade".fn_get_cep_positions(
    p_user_ref_id varchar,
    p_cep_ref_id varchar DEFAULT NULL
)
RETURNS TABLE (
    cep_ref_id varchar,
    trading_symbol varchar,
    scripcode varchar,
    buy_quantity numeric,
    sell_quantity numeric,
    remaining_quantity numeric
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        t.cep_ref_id,
        t.trading_symbol,
        t.scripcode,
        SUM(CASE WHEN t.transaction_type::text = 'BUY' THEN t.quantity ELSE 0 END),
        SUM(CASE WHEN t.transaction_type::text = 'SELL' THEN t.quantity ELSE 0 END),
        GREATEST(SUM(CASE WHEN t.transaction_type::text = 'BUY' THEN t.quantity ELSE -t.quantity END), 0)
    FROM "trade"."transaction" t
    WHERE t.user_ref_id = p_user_ref_id
      AND t.cep_ref_id IS NOT NULL
      AND (p_cep_ref_id IS NULL OR t.cep_ref_id = p_cep_ref_id)
      AND t.status::text IN ('COMPLETED', 'REVAMPED')
      AND t.transaction_type::text IN ('BUY', 'SELL')
    GROUP BY t.cep_ref_id, t.trading_symbol, t.scripcode;
$function$;

-- FUNCTION: trade.fn_get_portfolio_summary
-- Function: getPortfolioSummary
-- Prisma await: await prismaClient.transaction.findMany/aggregate(...)
-- Purpose: PostgreSQL read/calculation for Portfolio summary cards and admin portfolio summary.
-- Point: Portfolio summary cards and admin portfolio summary
-- Used by: GET /trade/portfolio and GET /operations/portfolio/:userId
-- Returns cost/quantity only; current value and P&L require Market/ETL prices.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar
--   Code / route integration target: Code function: getPortfolioSummary | Route / flow: GET /trade/portfolio and GET
--     /operations/portfolio/:userId | Replace or support: await prismaClient.transaction.findMany/aggregate(...)
--   Full routes / trigger: GET /trade/portfolio; GET /operations/portfolio/:userId - build user/admin portfolio
--     positions and summary
--   Related .js file(s): server_trade/controllers/partner/partnerReports.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/controllers/operations/users.controller.js; server_trade/routes/operations/users.routes.js
--   Integration point: Portfolio summary cards and admin portfolio summary
--   Reason: PostgreSQL read/calculation for Portfolio summary cards and admin portfolio summary.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "trade".fn_get_portfolio_summary(
    p_user_ref_id varchar
)
RETURNS TABLE (
    asset varchar,
    position_count bigint,
    net_quantity numeric,
    invested_amount numeric,
    sold_amount numeric
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        p.asset,
        COUNT(*) FILTER (WHERE p.net_quantity > 0) AS position_count,
        COALESCE(SUM(p.net_quantity), 0) AS net_quantity,
        COALESCE(SUM(p.invested_amount), 0) AS invested_amount,
        COALESCE(SUM(p.sold_amount), 0) AS sold_amount
    FROM "trade".fn_get_user_positions(p_user_ref_id, NULL) p
    GROUP BY p.asset;
$function$;

-- FUNCTION: trade.fn_get_admin_portfolio_transactions
-- Function: getAdminPortfolioTransactions
-- Prisma await: await prismaClient.transaction.findMany(...)
-- Purpose: PostgreSQL read/calculation for Operations / user portfolio drill-down.
-- Point: Operations / user portfolio drill-down
-- Used by: GET /operations/portfolio/:userId
-- Replaces the Main DB portion of transaction.findMany().
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar
--   Code / route integration target: Code function: getAdminPortfolioTransactions | Route / flow: GET
--     /operations/portfolio/:userId | Replace or support: await prismaClient.transaction.findMany(...)
--   Full routes / trigger: GET /operations/portfolio/:userId - load transaction drill-down for an operations user
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/users.controller.js; server_trade/routes/operations/users.routes.js;
--     server_trade/controllers/partner/partnerReports.controller.js
--   Integration point: Operations / user portfolio drill-down
--   Reason: PostgreSQL read/calculation for Operations / user portfolio drill-down.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "trade".fn_get_admin_portfolio_transactions(
    p_user_ref_id varchar
)
RETURNS SETOF "trade"."transaction"
LANGUAGE sql
STABLE
AS $function$
    SELECT t.*
    FROM "trade"."transaction" t
    WHERE t.user_ref_id = p_user_ref_id
      AND t.status::text IN ('COMPLETED', 'REVAMPED', 'PENDING', 'PARTIALLY_FILLED')
    ORDER BY t.created_at DESC;
$function$;

-- FUNCTION: trade.fn_claim_nse_mf_notification
-- Function: claimNseMfNotification
-- Prisma await: await prismaClient.nseMfOrder.updateMany(...)
-- Purpose: PostgreSQL read/calculation for NSE MF notification de-duplication.
-- Point: NSE MF notification de-duplication
-- Used by: MF status/push/email schedulers.
-- Atomically changes one false flag to true and returns whether this caller won.
-- Supported p_notification_type values are documented in the CASE below.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_order_id varchar; p_notification_type varchar
--   Code / route integration target: Code function: claimNseMfNotification | Route / flow: MF status/push/email
--     schedulers. | Replace or support: await prismaClient.nseMfOrder.updateMany(...)
--   Full routes / trigger: No HTTP route - MF order-status/push/email schedulers claim a notification atomically
--   Related .js file(s): server_trade/controllers/nsemf/nseMf.controller.js;
--     server_trade/routes/nseMf/nseMf.routes.js; server_etl/schdulers/mfOrderStatusSync.js;
--     server_etl/schdulers/mandateStatusTracker.js
--   Integration point: NSE MF notification de-duplication
--   Reason: PostgreSQL read/calculation for NSE MF notification de-duplication.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "trade".fn_claim_nse_mf_notification(
    p_order_id varchar,
    p_notification_type varchar
)
RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE
    v_affected_rows bigint := 0;
BEGIN
    CASE p_notification_type
        WHEN 'ORDER_FAILED_EMAIL' THEN
            UPDATE "trade".nse_mf_order SET order_failed_email_sent = true, updated_at = CURRENT_TIMESTAMP
            WHERE id = p_order_id AND order_failed_email_sent = false;
        WHEN 'ORDER_REJECTION_PUSH' THEN
            UPDATE "trade".nse_mf_order SET order_rejection_push_sent = true, updated_at = CURRENT_TIMESTAMP
            WHERE id = p_order_id AND order_rejection_push_sent = false;
        WHEN 'LUMPSUM_ALLOTMENT_DELAYED_EMAIL' THEN
            UPDATE "trade".nse_mf_order SET lumpsum_allotment_delayed_email_sent = true, updated_at = CURRENT_TIMESTAMP
            WHERE id = p_order_id AND lumpsum_allotment_delayed_email_sent = false;
        WHEN 'LUMPSUM_PAYMENT_CONFIRMED_EMAIL' THEN
            UPDATE "trade".nse_mf_order SET lumpsum_payment_confirmed_email_sent = true, updated_at = CURRENT_TIMESTAMP
            WHERE id = p_order_id AND lumpsum_payment_confirmed_email_sent = false;
        WHEN 'SIP_ACTIVATION_EMAIL' THEN
            UPDATE "trade".nse_mf_order SET sip_activation_email_sent = true, updated_at = CURRENT_TIMESTAMP
            WHERE id = p_order_id AND sip_activation_email_sent = false;
        WHEN 'SIP_LINKED_MANDATE_EMAIL' THEN
            UPDATE "trade".nse_mf_order SET sip_linked_mandate_email_sent = true, updated_at = CURRENT_TIMESTAMP
            WHERE id = p_order_id AND sip_linked_mandate_email_sent = false;
        ELSE
            RAISE EXCEPTION 'Unsupported NSE MF notification type: %', p_notification_type;
    END CASE;

    GET DIAGNOSTICS v_affected_rows = ROW_COUNT;
    RETURN v_affected_rows = 1;
END;
$function$;

-- FUNCTION: trade.fn_get_user_watchlists
-- Function: getUserWatchlists
-- Prisma await: await prismaClient.watchlist.findMany({ include: { WatchlistDetails: true } })
-- Purpose: PostgreSQL read/calculation for Watchlist read model.
-- Point: Watchlist read model
-- Used by: GET /watchlist/data and IRIS watchlist synchronization.
-- Returns Main DB watchlist rows only. Market/ETL enrichment remains in Node.js.
-- Parameters:
--   p_user_ref_id = Prisma Watchlist.user_ref_id
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_ref_id varchar
--   Code / route integration target: Code function: getUserWatchlists | Route / flow: GET /watchlist/data and IRIS
--     watchlist synchronization. | Replace or support: await prismaClient.watchlist.findMany({ include: {
--     WatchlistDetails: true } })
--   Full routes / trigger: GET /watchlist/data; GET /iris-external/watchlist - return the user's watchlists and
--     stocks
--   Related .js file(s): server_trade/routes/watchlist/watchlist.routes.js;
--     server_trade/controllers/watchlist/watchlist.controller.js
--   Integration point: Watchlist read model
--   Reason: PostgreSQL read/calculation for Watchlist read model.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "trade".fn_get_user_watchlists(
    p_user_ref_id varchar
)
RETURNS TABLE (
    watchlist_id varchar,
    watchlist_name varchar,
    is_active boolean,
    watchlist_created_at timestamp,
    watchlist_updated_at timestamp,
    detail_id varchar,
    scripcode integer,
    demo_trade_price numeric,
    detail_created_at timestamp
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        w.id,
        w.name,
        w.is_active,
        w.created_at,
        w.updated_at,
        d.id,
        d.scripcode,
        d.demo_trade_price,
        d.created_at
    FROM "trade".watchlist w
    LEFT JOIN "trade".watchlistdetail d ON d.watchlist_id = w.id
    WHERE w.user_ref_id = p_user_ref_id
    ORDER BY w.name ASC, d.created_at ASC;
$function$;

-- FUNCTION: trade.fn_get_mf_portfolio_milestones
-- Function: getMfPortfolioMilestones
-- Prisma await: await tradeDB.mfPortfolioMilestone.findMany(...)
-- Purpose: PostgreSQL read/calculation for Portfolio / mutual-fund milestone notification history.
-- Point: Portfolio / mutual-fund milestone notification history
-- Used by: server_etl/schdulers/mfPortfolioMilestoneNotifier.js
-- Parameters:
--   p_user_id = Prisma MfPortfolioMilestone.user_id; NULL returns all users.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_user_id varchar DEFAULT NULL
--   Code / route integration target: Code function: getMfPortfolioMilestones | Route / flow:
--     server_etl/schdulers/mfPortfolioMilestoneNotifier.js | Replace or support: await
--     tradeDB.mfPortfolioMilestone.findMany(...)
--   Full routes / trigger: No HTTP route - server_etl/schdulers/mfPortfolioMilestoneNotifier.js reads/records
--     notification milestones
--   Related .js file(s): server_etl/schdulers/mfPortfolioMilestoneNotifier.js
--   Integration point: Portfolio / mutual-fund milestone notification history
--   Reason: PostgreSQL read/calculation for Portfolio / mutual-fund milestone notification history.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "trade".fn_get_mf_portfolio_milestones(
    p_user_id varchar DEFAULT NULL
)
RETURNS SETOF "trade".mf_portfolio_milestones
LANGUAGE sql
STABLE
AS $function$
    SELECT m.*
    FROM "trade".mf_portfolio_milestones m
    WHERE p_user_id IS NULL OR m.user_id = p_user_id
    ORDER BY m.user_id, m.milestone;
$function$;
