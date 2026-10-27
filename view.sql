-- ============================================================================
-- NUQI Wealth - PostgreSQL views for Mandar's work scope
-- Scope: Portfolio, Orders, Transactions, NSE MF, Zerodha, Watchlist, Helpdesk, and Operations
-- Source of truth for names/types: table.sql
--
-- These views intentionally expose no Zerodha access/refresh/encryption tokens.
-- Market NAV/scheme and ETL company enrichment remains in the Node.js layer.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_user_portfolio_positions
-- Function: getUserPortfolioPositions
-- Prisma await: await prismaClient.transaction.findMany(...)
-- Purpose: Reusable PostgreSQL read/reporting model for Portfolio.
-- Point: Portfolio
-- Used by: /trade/portfolio, remaining-quantity APIs, partner/admin reporting.
-- Provides the Main DB BUY/SELL position ledger. Market prices are not included.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getUserPortfolioPositions | Route / flow: /trade/portfolio,
--     remaining-quantity APIs, partner/admin reporting. | Replace or support: await
--     prismaClient.transaction.findMany(...)
--   Full routes / trigger: GET /trade/portfolio; GET /operations/portfolio/:userId - build user/admin portfolio
--     positions and summary
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Portfolio
--   Reason: Reusable PostgreSQL read/reporting model for Portfolio.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_user_portfolio_positions AS
SELECT
    t.user_ref_id,
    t.account_id,
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
    END AS average_buy_price,
    MIN(t.created_at) AS first_transaction_at,
    MAX(t.updated_at) AS last_transaction_at
FROM "trade"."transaction" t
WHERE t.status::text IN ('COMPLETED', 'REVAMPED')
  AND t.transaction_type::text IN ('BUY', 'SELL')
GROUP BY
    t.user_ref_id, t.account_id, t.trading_symbol, t.scripcode,
    COALESCE(t.asset, 'EQUITY'), t.cep_ref_id;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_portfolio_summary
-- Function: getPortfolioSummary
-- Prisma await: await prismaClient.transaction.groupBy/aggregate(...)
-- Purpose: Reusable PostgreSQL read/reporting model for Portfolio summary and migration reconciliation.
-- Point: Portfolio summary and migration reconciliation
-- Used by: API/admin/reporting query flow getPortfolioSummary() and migration validation.
-- Summarizes Main DB position counts, quantities, and cost by user and asset.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getPortfolioSummary | Route / flow: API/admin/reporting query
--     flow getPortfolioSummary() and migration validation. | Replace or support: await
--     prismaClient.transaction.groupBy/aggregate(...)
--   Full routes / trigger: GET /trade/portfolio; GET /operations/portfolio/:userId - build user/admin portfolio
--     positions and summary
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/users.controller.js; server_trade/routes/operations/users.routes.js;
--     server_trade/controllers/partner/partnerReports.controller.js
--   Integration point: Portfolio summary and migration reconciliation
--   Reason: Reusable PostgreSQL read/reporting model for Portfolio summary and migration reconciliation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_portfolio_summary AS
SELECT
    p.user_ref_id,
    u.email,
    u.first_name,
    u.last_name,
    p.asset,
    COUNT(*) FILTER (WHERE p.net_quantity > 0) AS active_position_count,
    COALESCE(SUM(p.net_quantity), 0) AS net_quantity,
    COALESCE(SUM(p.invested_amount), 0) AS gross_invested_amount,
    COALESCE(SUM(p.sold_amount), 0) AS gross_sold_amount,
    MIN(p.first_transaction_at) AS first_transaction_at,
    MAX(p.last_transaction_at) AS last_transaction_at
FROM "trade".vw_user_portfolio_positions p
LEFT JOIN "user"."user" u ON u.id = p.user_ref_id
GROUP BY p.user_ref_id, u.email, u.first_name, u.last_name, p.asset;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_order_details
-- Function: getOrderDetails
-- Prisma await: await prismaClient.order.findMany({ include: { Portfolio: true, Inventory: true, Transaction: true } })
-- Purpose: Reusable PostgreSQL read/reporting model for Orders and Operations order drill-down.
-- Point: Orders and Operations order drill-down
-- Used by: API/admin/reporting query flow getOrderDetails() and migration validation.
-- Combines order, portfolio, inventory, transaction, and user details.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getOrderDetails | Route / flow: API/admin/reporting query flow
--     getOrderDetails() and migration validation. | Replace or support: await prismaClient.order.findMany({ include:
--     { Portfolio: true, Inventory: true, Transaction: true } })
--   Full routes / trigger: GET /operations/order-book; GET /operations/order-book/:transactionId; GET
--     /operations/order-analytics; GET /trade/orderbook - order details/analytics
--   Related .js file(s): server_trade/controllers/operations/orders.controller.js;
--     server_trade/routes/operations/orders.route.js;
--     server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js
--   Integration point: Orders and Operations order drill-down
--   Reason: Reusable PostgreSQL read/reporting model for Orders and Operations order drill-down.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_order_details AS
SELECT
    o.id AS order_id,
    o.status AS order_status,
    o.order_type,
    o.quantity,
    o.remaining_qty,
    o.price,
    o.limit_price,
    o.stop_price,
    o.stock_id,
    o.cep_ref_id,
    o.created_at,
    o.updated_at,
    p.id AS portfolio_id,
    p.name AS portfolio_name,
    p.type AS portfolio_type,
    i.id AS inventory_id,
    i.name AS inventory_name,
    i.type AS inventory_type,
    t.id AS transaction_id,
    t.order_id AS external_order_id,
    t.status AS transaction_status,
    t.transaction_type,
    t.trading_symbol,
    t.scripcode,
    t.average_price,
    COALESCE(o.user_id, t.user_ref_id, p.user_id) AS user_id,
    u.email AS user_email,
    u.first_name,
    u.last_name
FROM "trade"."order" o
LEFT JOIN "trade".portfolio p ON p.id = o.portfolio_id
LEFT JOIN "trade".inventory i ON i.id = o.inventory_id
LEFT JOIN "trade"."transaction" t ON t.id = o.transaction_id
LEFT JOIN "user"."user" u ON u.id = COALESCE(o.user_id, t.user_ref_id, p.user_id);

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_transaction_details
-- Function: getTransactionDetails
-- Prisma await: await prismaClient.transaction.findMany({ include: { User: true, ParentTransaction: true } })
-- Purpose: Reusable PostgreSQL read/reporting model for Transactions and Operations transaction listing.
-- Point: Transactions and Operations transaction listing
-- Used by: API/admin/reporting query flow getTransactionDetails() and migration validation.
-- Adds user and parent-transaction information without exposing token fields.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getTransactionDetails | Route / flow: API/admin/reporting query
--     flow getTransactionDetails() and migration validation. | Replace or support: await
--     prismaClient.transaction.findMany({ include: { User: true, ParentTransaction: true } })
--   Full routes / trigger: GET /trade/orderbook; GET /operations/order-book; GET /operations/order-analytics -
--     transaction details/reporting
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Transactions and Operations transaction listing
--   Reason: Reusable PostgreSQL read/reporting model for Transactions and Operations transaction listing.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_transaction_details AS
SELECT
    t.id,
    t.order_id,
    t.exchange_order_id,
    t.user_ref_id,
    u.email AS user_email,
    u.first_name,
    u.last_name,
    t.status,
    t.transaction_type,
    t.asset,
    t.scripcode,
    t.trading_symbol,
    t.cep_ref_id,
    t.quantity,
    t.filled_quantity,
    t.pending_quantity,
    t.cancelled_quantity,
    t.average_price,
    t.quantity * COALESCE(t.average_price, 0) AS transaction_value,
    t.parent_transaction_id,
    parent.order_id AS parent_order_id,
    t.platform,
    t.provider,
    t.trade_platform,
    t.is_expired,
    t.created_at,
    t.updated_at
FROM "trade"."transaction" t
LEFT JOIN "user"."user" u ON u.id = t.user_ref_id
LEFT JOIN "trade"."transaction" parent ON parent.id = t.parent_transaction_id;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_nse_mf_order_summary
-- Function: getNseMfOrderSummary
-- Prisma await: await prismaClient.nseMfOrder.findMany({ include: { User: true } })
-- Purpose: Reusable PostgreSQL read/reporting model for NSE MF SIP, lumpsum, and redemption operations.
-- Point: NSE MF SIP, lumpsum, and redemption operations
-- Used by: API/admin/reporting query flow getNseMfOrderSummary() and migration validation.
-- Used by user order history, sync jobs, and Operations MF screens.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getNseMfOrderSummary | Route / flow: API/admin/reporting query
--     flow getNseMfOrderSummary() and migration validation. | Replace or support: await
--     prismaClient.nseMfOrder.findMany({ include: { User: true } })
--   Full routes / trigger: GET /operations/mf/users/:userId/orders; POST /operations/mf/users/:userId/orders/sync -
--     operations order view and reconciliation
--   Related .js file(s): server_trade/controllers/nsemf/nseMf.controller.js;
--     server_trade/routes/nseMf/nseMf.routes.js; server_etl/schdulers/mfOrderStatusSync.js;
--     server_etl/schdulers/mandateStatusTracker.js
--   Integration point: NSE MF SIP, lumpsum, and redemption operations
--   Reason: Reusable PostgreSQL read/reporting model for NSE MF SIP, lumpsum, and redemption operations.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_nse_mf_order_summary AS
SELECT
    o.id,
    o.user_ref_id,
    u.email AS user_email,
    u.first_name,
    u.last_name,
    o.trade_type,
    o.scheme_code,
    o.amc_code,
    o.client_code,
    o.amount,
    o.folio_no,
    o.frequency_type,
    o.installment_no,
    o.sip_mandate_id,
    o.order_status,
    o.nse_status,
    o.nse_order_id,
    o.nse_order_status,
    o.nse_remark,
    o.allotted_nav,
    o.allotted_qty,
    o.allotted_amount,
    o.exit_load,
    o.stt,
    o.tax_amount,
    o.payout_status,
    o.created_at,
    o.updated_at,
    CASE
        WHEN o.order_status IN ('FAILED', 'REJECTED', 'CANCELLED') THEN 'FAILED'
        WHEN COALESCE(o.allotted_qty, 0) > 0 THEN 'ALLOTTED'
        WHEN o.nse_order_id IS NOT NULL THEN 'SUBMITTED'
        ELSE 'PENDING'
    END AS normalized_status
FROM "trade".nse_mf_order o
LEFT JOIN "user"."user" u ON u.id = o.user_ref_id;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_nse_mf_onboarding_summary
-- Function: getNseMfOnboardingSummary
-- Prisma await: await prismaClient.nseMfOnboarding.findMany({ include: { User: true, NseMfUCC: true } })
-- Purpose: Reusable PostgreSQL read/reporting model for NSE MF onboarding and Operations MF administration.
-- Point: NSE MF onboarding and Operations MF administration
-- Used by: API/admin/reporting query flow getNseMfOnboardingSummary() and migration validation.
-- Gives one row per onboarding record with the latest matching UCC state.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getNseMfOnboardingSummary | Route / flow: API/admin/reporting
--     query flow getNseMfOnboardingSummary() and migration validation. | Replace or support: await
--     prismaClient.nseMfOnboarding.findMany({ include: { User: true, NseMfUCC: true } })
--   Full routes / trigger: GET /operations/mf/users; GET /operations/mf/users/:userId/onboarding; GET
--     /nse/mf/onboarding/status - onboarding monitoring
--   Related .js file(s): server_trade/controllers/nsemf/nseMfOnboarding.controller.js;
--     server_trade/routes/nseMf/nseMfOnboarding.routes.js; server_etl/schdulers/nseClientAuthPoll.js
--   Integration point: NSE MF onboarding and Operations MF administration
--   Reason: Reusable PostgreSQL read/reporting model for NSE MF onboarding and Operations MF administration.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_nse_mf_onboarding_summary AS
SELECT
    o.id,
    o.user_ref_id,
    u.email AS user_email,
    u.phone_number,
    u.first_name,
    u.last_name,
    o.current_step,
    o.onboarding_status,
    o.step1_completed,
    o.step2_completed,
    o.step3_completed,
    o.step4_completed,
    o.step5_completed,
    o.step6_completed,
    o.step7_completed,
    o.submitted_at,
    ucc.client_code,
    ucc.ucc_status,
    ucc.kyc_status,
    ucc.bank_dtl_status,
    ucc.fatca_status,
    ucc.client_auth_status,
    o.created_at,
    o.updated_at
FROM "trade".nse_mf_onboarding o
LEFT JOIN "user"."user" u ON u.id = o.user_ref_id
LEFT JOIN LATERAL (
    SELECT x.client_code, x.ucc_status, x.kyc_status, x.bank_dtl_status,
           x.fatca_status, x.client_auth_status
    FROM "trade".nse_mf_ucc x
    WHERE x.user_ref_id = o.user_ref_id
    ORDER BY x.updated_at DESC
    LIMIT 1
) ucc ON true;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_nse_mf_mandate_summary
-- Function: getNseMfMandateSummary
-- Prisma await: await prismaClient.nseMfMandate.findMany({ include: { User: true } })
-- Purpose: Reusable PostgreSQL read/reporting model for NSE MF mandate status, expiry, and Operations monitoring.
-- Point: NSE MF mandate status, expiry, and Operations monitoring
-- Used by: API/admin/reporting query flow getNseMfMandateSummary() and migration validation.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getNseMfMandateSummary | Route / flow: API/admin/reporting query
--     flow getNseMfMandateSummary() and migration validation. | Replace or support: await
--     prismaClient.nseMfMandate.findMany({ include: { User: true } })
--   Full routes / trigger: GET /nse/mf/mandates; GET /nse/mf/mandates/:regId; GET
--     /operations/mf/users/:userId/mandates - mandate monitoring
--   Related .js file(s): server_trade/controllers/nsemf/nseMf.controller.js;
--     server_trade/routes/nseMf/nseMf.routes.js; server_etl/schdulers/mfOrderStatusSync.js;
--     server_etl/schdulers/mandateStatusTracker.js
--   Integration point: NSE MF mandate status, expiry, and Operations monitoring
--   Reason: Reusable PostgreSQL read/reporting model for NSE MF mandate status, expiry, and Operations monitoring.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_nse_mf_mandate_summary AS
SELECT
    m.id,
    m.user_ref_id,
    u.email AS user_email,
    u.first_name,
    u.last_name,
    m.client_code,
    m.amount,
    m.start_date,
    m.end_date,
    m.mandate_status,
    m.nse_status,
    m.reg_id,
    m.reg_status,
    m.bank_status,
    m.enach_status,
    m.umrn_no,
    m.approved_date,
    m.reject_reason,
    m.last_status_sync,
    m.created_at,
    m.updated_at
FROM "trade".nse_mf_mandate m
LEFT JOIN "user"."user" u ON u.id = m.user_ref_id;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_zerodha_session_summary
-- Function: getZerodhaSessionSummary
-- Prisma await: await prismaClient.zerodha.findMany({ include: { User: true } })
-- Purpose: Reusable PostgreSQL read/reporting model for Zerodha connection/session administration.
-- Point: Zerodha connection/session administration
-- Used by: API/admin/reporting query flow getZerodhaSessionSummary() and migration validation.
-- Security: access_token, refresh_token, enctoken, and public_token are omitted.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getZerodhaSessionSummary | Route / flow: API/admin/reporting
--     query flow getZerodhaSessionSummary() and migration validation. | Replace or support: await
--     prismaClient.zerodha.findMany({ include: { User: true } })
--   Full routes / trigger: GET /user/profile; GET /kite/user/profile; GET /operations/sessions/active-users -
--     session/connection administration
--   Related .js file(s): server_trade/controllers/zerodha/zerodhaAuth.controller.js;
--     server_trade/controllers/zerodha/zerodhaPortfolio.controller.js;
--     server_trade/controllers/zerodha/zerodhaTrade.controller.js; server_trade/routes/zerodha/zerodhaAuth.routes.js;
--     server_trade/routes/zerodha/zerodhaPortfolio.routes.js; server_trade/routes/zerodha/zerodhaTrade.routes.js;
--     server_etl/schdulers/expireZerodhaSession.js
--   Integration point: Zerodha connection/session administration
--   Reason: Reusable PostgreSQL read/reporting model for Zerodha connection/session administration.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_zerodha_session_summary AS
SELECT
    z.id,
    z.user_ref_id,
    u.email AS registered_email,
    u.first_name,
    u.last_name,
    z.zerodha_user_id,
    z.email AS zerodha_email,
    z."userName" AS zerodha_user_name,
    z.session_status,
    z.is_tnc_accepted,
    z.login_time,
    z.last_fetched_at,
    CASE
        WHEN z.last_fetched_portfolio IS NULL THEN 0
        WHEN jsonb_typeof(z.last_fetched_portfolio) = 'array'
            THEN jsonb_array_length(z.last_fetched_portfolio)
        ELSE 0
    END AS cached_position_count,
    z.created_at,
    z.updated_at
FROM "trade".zerodha z
LEFT JOIN "user"."user" u ON u.id = z.user_ref_id;

-- ----------------------------------------------------------------------------
-- VIEW: support.vw_ticket_summary
-- Function: getTicketSummary
-- Prisma await: await prismaClient.ticket.findMany({ include: { comments: true, assignee: true, category: true, subcategory: true } })
-- Purpose: Reusable PostgreSQL read/reporting model for Operations tickets/helpdesk.
-- Point: Operations tickets/helpdesk
-- Used by: API/admin/reporting query flow getTicketSummary() and migration validation.
-- Used by ticket lists, statistics, assignment, and SLA monitoring.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getTicketSummary | Route / flow: API/admin/reporting query flow
--     getTicketSummary() and migration validation. | Replace or support: await prismaClient.ticket.findMany({
--     include: { comments: true, assignee: true, category: true, subcategory: true } })
--   Full routes / trigger: GET /operations/tickets; GET /operations/tickets/:id; GET /operations/tickets/statistics;
--     GET /auth/tickets; GET /auth/tickets/:ticketId - ticket lists/details
--   Related .js file(s): server_trade/controllers/operations/tickets.controller.js;
--     server_trade/controllers/helpdesk/user.ticket.controller.js; server_trade/routes/operations/tickets.routes.js;
--     server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations tickets/helpdesk
--   Reason: Reusable PostgreSQL read/reporting model for Operations tickets/helpdesk.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "support".vw_ticket_summary AS
SELECT
    t.id,
    t."ticketNumber" AS ticket_number,
    t."userId" AS user_id,
    u.email AS user_email,
    u.first_name,
    u.last_name,
    t.subject,
    t.priority,
    t.status,
    t."internalStatus" AS internal_status,
    t."assignedTo" AS assigned_to,
    a.name AS assignee_name,
    a.email AS assignee_email,
    c.name AS category_name,
    sc.name AS subcategory_name,
    t."escalationLevel" AS escalation_level,
    t."firstResponseAt" AS first_response_at,
    t."resolvedAt" AS resolved_at,
    t."closedAt" AS closed_at,
    t."createdAt" AS created_at,
    t."updatedAt" AS updated_at,
    COUNT(tc.id) AS comment_count
FROM "support".ticket t
LEFT JOIN "user"."user" u ON u.id = t."userId"
LEFT JOIN "support".ticketassignee a ON a.id = t."assignedTo"
LEFT JOIN "support".ticketcategoryconfig c ON c.id = t."categoryId"
LEFT JOIN "support".ticketsubcategory sc ON sc.id = t."subcategoryId"
LEFT JOIN "support".ticketcomment tc ON tc."ticketId" = t.id
GROUP BY
    t.id, t."ticketNumber", t."userId", u.email, u.first_name, u.last_name,
    t.subject, t.priority, t.status, t."internalStatus", t."assignedTo",
    a.name, a.email, c.name, sc.name, t."escalationLevel",
    t."firstResponseAt", t."resolvedAt", t."closedAt", t."createdAt", t."updatedAt";

-- ----------------------------------------------------------------------------
-- VIEW: ops.vw_pending_approvals
-- Function: getPendingApprovals
-- Prisma await: await prismaClient.approvalRequest.findMany({ where: { status: 'PENDING' } })
-- Purpose: Reusable PostgreSQL read/reporting model for Operations maker-checker queue.
-- Point: Operations maker-checker queue
-- Used by: API/admin/reporting query flow getPendingApprovals() and migration validation.
-- Used by approval-request list and dashboard routes.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getPendingApprovals | Route / flow: API/admin/reporting query
--     flow getPendingApprovals() and migration validation. | Replace or support: await
--     prismaClient.approvalRequest.findMany({ where: { status: 'PENDING' } })
--   Full routes / trigger: PUT /operations/approval-requests/:id/approve; PUT
--     /operations/approval-requests/:id/reject - review/read maker-checker requests
--   Related .js file(s): server_trade/controllers/operations/approvalRequests.controller.js;
--     server_trade/routes/operations/approvalRequests.routes.js
--   Integration point: Operations maker-checker queue
--   Reason: Reusable PostgreSQL read/reporting model for Operations maker-checker queue.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "ops".vw_pending_approvals AS
SELECT
    a.id,
    a.module,
    a."actionType" AS action_type,
    a."entityType" AS entity_type,
    a."entityId" AS entity_id,
    a.payload,
    a.status,
    a."requestedBy" AS requested_by,
    a."requestedByEmail" AS requested_by_email,
    a."createdAt" AS created_at,
    CURRENT_TIMESTAMP - a."createdAt" AS pending_age
FROM "ops".approvalrequest a
WHERE UPPER(a.status) IN ('PENDING', 'UNDER_REVIEW');

-- ----------------------------------------------------------------------------
-- VIEW: ops.vw_operations_dashboard
-- Function: getOperationsDashboard
-- Prisma await: await Promise.all([prismaClient.operations_user.count(...), prismaClient.approvalRequest.count(...), prismaClient.auditLog.count(...)])
-- Purpose: Reusable PostgreSQL read/reporting model for Operations dashboard.
-- Point: Operations dashboard
-- Used by: API/admin/reporting query flow getOperationsDashboard() and migration validation.
-- Returns one row of Main DB operational counts.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getOperationsDashboard | Route / flow: API/admin/reporting query
--     flow getOperationsDashboard() and migration validation. | Replace or support: await
--     Promise.all([prismaClient.operations_user.count(...), prismaClient.approvalRequest.count(...),
--     prismaClient.auditLog.count(...)])
--   Full routes / trigger: GET /operations/dashboard-analytics - operations dashboard counters and analytics
--   Related .js file(s): server_trade/controllers/operations/dashboard.controller.js;
--     server_trade/routes/operations/dashboard.route.js
--   Integration point: Operations dashboard
--   Reason: Reusable PostgreSQL read/reporting model for Operations dashboard.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "ops".vw_operations_dashboard AS
SELECT
    (SELECT COUNT(*) FROM "user"."user" WHERE is_deleted = false) AS active_users,
    (SELECT COUNT(*) FROM "trade"."transaction" WHERE status::text = 'PENDING') AS pending_transactions,
    (SELECT COUNT(*) FROM "trade"."transaction" WHERE status::text = 'FAILED') AS failed_transactions,
    (SELECT COUNT(*) FROM "trade".nse_mf_order WHERE UPPER(COALESCE(order_status, '')) = 'PENDING') AS pending_mf_orders,
    (SELECT COUNT(*) FROM "trade".nse_mf_mandate WHERE UPPER(COALESCE(mandate_status, '')) = 'PENDING') AS pending_mandates,
    (SELECT COUNT(*) FROM "support".ticket WHERE UPPER(status) NOT IN ('RESOLVED', 'CLOSED')) AS open_tickets,
    (SELECT COUNT(*) FROM "ops".approvalrequest WHERE UPPER(status) IN ('PENDING', 'UNDER_REVIEW')) AS pending_approvals,
    (SELECT COUNT(*) FROM "trade".zerodha WHERE COALESCE(session_status, '') <> 'false') AS active_zerodha_sessions;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_transaction_validation_issues
-- Function: getTransactionValidationIssues
-- Prisma await: await prismaClient.$queryRaw(...)
-- Purpose: Reusable PostgreSQL read/reporting model for Migration validation.
-- Point: Migration validation
-- Used by: API/admin/reporting query flow getTransactionValidationIssues() and migration validation.
-- Identifies invalid quantities/status combinations after MySQL -> PostgreSQL
-- data migration. A clean migration should return zero rows.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getTransactionValidationIssues | Route / flow:
--     API/admin/reporting query flow getTransactionValidationIssues() and migration validation. | Replace or support:
--     await prismaClient.$queryRaw(...)
--   Full routes / trigger: No HTTP route - migration/DB validation query expected to return zero unresolved rows
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Migration validation
--   Reason: Reusable PostgreSQL read/reporting model for Migration validation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_transaction_validation_issues AS
SELECT
    t.id AS record_id,
    t.user_ref_id,
    'NEGATIVE_QUANTITY'::text AS issue_code,
    'quantity cannot be negative'::text AS issue_detail
FROM "trade"."transaction" t
WHERE t.quantity < 0

UNION ALL

SELECT
    t.id,
    t.user_ref_id,
    'FILLED_EXCEEDS_QUANTITY',
    'filled_quantity is greater than quantity'
FROM "trade"."transaction" t
WHERE t.filled_quantity > t.quantity

UNION ALL

SELECT
    t.id,
    t.user_ref_id,
    'QUANTITY_COMPONENT_MISMATCH',
    'filled + pending + cancelled exceeds quantity'
FROM "trade"."transaction" t
WHERE t.filled_quantity + t.pending_quantity + t.cancelled_quantity > t.quantity

UNION ALL

SELECT
    t.id,
    t.user_ref_id,
    'COMPLETED_WITHOUT_FILL',
    'completed transaction has no filled quantity'
FROM "trade"."transaction" t
WHERE t.status::text = 'COMPLETED'
  AND t.filled_quantity <= 0
  AND t.quantity > 0;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_trade_reference_validation_issues
-- Function: getTradeReferenceValidationIssues
-- Prisma await: await prismaClient.$queryRaw(...)
-- Purpose: Reusable PostgreSQL read/reporting model for Migration FK/reference validation.
-- Point: Migration FK/reference validation
-- Used by: API/admin/reporting query flow getTradeReferenceValidationIssues() and migration validation.
-- Finds references for which table.sql currently has no enforced FK.
-- A clean migration should return zero rows, except documented legacy records.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getTradeReferenceValidationIssues | Route / flow:
--     API/admin/reporting query flow getTradeReferenceValidationIssues() and migration validation. | Replace or
--     support: await prismaClient.$queryRaw(...)
--   Full routes / trigger: No HTTP route - migration/DB validation query expected to return zero unresolved rows
--   Related .js file(s): No direct .js reference found (database/reporting integration target)
--   Integration point: Migration FK/reference validation
--   Reason: Reusable PostgreSQL read/reporting model for Migration FK/reference validation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_trade_reference_validation_issues AS
SELECT
    'ORDER_PORTFOLIO_NOT_FOUND'::text AS issue_code,
    o.id AS record_id,
    o.portfolio_id AS missing_reference
FROM "trade"."order" o
LEFT JOIN "trade".portfolio p ON p.id = o.portfolio_id
WHERE p.id IS NULL

UNION ALL

SELECT
    'ORDER_TRANSACTION_NOT_FOUND',
    o.id,
    o.transaction_id
FROM "trade"."order" o
LEFT JOIN "trade"."transaction" t ON t.id = o.transaction_id
WHERE o.transaction_id IS NOT NULL AND t.id IS NULL

UNION ALL

SELECT
    'ORDER_INVENTORY_NOT_FOUND',
    o.id,
    o.inventory_id
FROM "trade"."order" o
LEFT JOIN "trade".inventory i ON i.id = o.inventory_id
WHERE o.inventory_id IS NOT NULL AND i.id IS NULL

UNION ALL

SELECT
    'INVENTORY_PORTFOLIO_NOT_FOUND',
    i.id,
    i."portfolioId"
FROM "trade".inventory i
LEFT JOIN "trade".portfolio p ON p.id = i."portfolioId"
WHERE i."portfolioId" IS NOT NULL AND p.id IS NULL

UNION ALL

SELECT
    'TRANSACTION_PARENT_NOT_FOUND',
    t.id,
    t.parent_transaction_id
FROM "trade"."transaction" t
LEFT JOIN "trade"."transaction" parent ON parent.id = t.parent_transaction_id
WHERE t.parent_transaction_id IS NOT NULL AND parent.id IS NULL;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_order_status_summary
-- Function: getOrderStatusSummary
-- Prisma await: await prismaClient.order.groupBy({ by: ['status'] })
-- Purpose: Reusable PostgreSQL read/reporting model for Operations order analytics/reporting.
-- Point: Operations order analytics/reporting
-- Used by: API/admin/reporting query flow getOrderStatusSummary() and migration validation.
-- Used by order dashboard totals and status/type distribution endpoints.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getOrderStatusSummary | Route / flow: API/admin/reporting query
--     flow getOrderStatusSummary() and migration validation. | Replace or support: await prismaClient.order.groupBy({
--     by: ['status'] })
--   Full routes / trigger: GET /operations/order-book; GET /operations/order-book/:transactionId; GET
--     /operations/order-analytics; GET /trade/orderbook - order details/analytics
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Operations order analytics/reporting
--   Reason: Reusable PostgreSQL read/reporting model for Operations order analytics/reporting.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_order_status_summary AS
SELECT
    o.status,
    o.order_type,
    p.type AS portfolio_type,
    COUNT(*) AS order_count,
    COALESCE(SUM(o.quantity), 0) AS total_quantity,
    COALESCE(SUM(o.quantity * o.price), 0) AS gross_order_value,
    COALESCE(SUM(o.remaining_qty), 0) AS remaining_quantity,
    MIN(o.created_at) AS first_order_at,
    MAX(o.created_at) AS latest_order_at
FROM "trade"."order" o
LEFT JOIN "trade".portfolio p ON p.id = o.portfolio_id
GROUP BY o.status, o.order_type, p.type;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_daily_transaction_summary
-- Function: getDailyTransactionSummary
-- Prisma await: await prismaClient.transaction.groupBy/aggregate(...)
-- Purpose: Reusable PostgreSQL read/reporting model for Operations transaction dashboard/reports.
-- Point: Operations transaction dashboard/reports
-- Used by: API/admin/reporting query flow getDailyTransactionSummary() and migration validation.
-- Provides daily status/type/asset counts and values from the Main DB.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getDailyTransactionSummary | Route / flow: API/admin/reporting
--     query flow getDailyTransactionSummary() and migration validation. | Replace or support: await
--     prismaClient.transaction.groupBy/aggregate(...)
--   Full routes / trigger: GET /trade/orderbook; GET /operations/order-book; GET /operations/order-analytics -
--     transaction details/reporting
--   Related .js file(s): server_trade/controllers/transactions/transactions.controller.js;
--     server_trade/routes/transactions/transaction.routes.js;
--     server_trade/controllers/operations/orders.controller.js; server_trade/routes/operations/orders.route.js
--   Integration point: Operations transaction dashboard/reports
--   Reason: Reusable PostgreSQL read/reporting model for Operations transaction dashboard/reports.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_daily_transaction_summary AS
SELECT
    t.created_at::date AS transaction_day,
    t.status,
    t.transaction_type,
    COALESCE(t.asset, 'EQUITY') AS asset,
    COUNT(*) AS transaction_count,
    COALESCE(SUM(t.quantity), 0) AS total_quantity,
    COALESCE(SUM(t.quantity * COALESCE(t.average_price, 0)), 0) AS gross_value,
    COUNT(DISTINCT t.user_ref_id) AS unique_users
FROM "trade"."transaction" t
GROUP BY t.created_at::date, t.status, t.transaction_type, COALESCE(t.asset, 'EQUITY');

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_nse_mf_transaction_reconciliation
-- Function: getNseMfTransactionReconciliation
-- Prisma await: await Promise.all([prismaClient.nseMfOrder.findMany(...), prismaClient.transaction.findMany(...)])
-- Purpose: Reusable PostgreSQL read/reporting model for NSE MF migration and runtime reconciliation.
-- Point: NSE MF migration and runtime reconciliation
-- Used by: API/admin/reporting query flow getNseMfTransactionReconciliation() and migration validation.
-- Compares NSE MF orders with unified Transaction rows by user/NSE order ID.
-- Rows where reconciliation_status is not MATCHED require investigation.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getNseMfTransactionReconciliation | Route / flow:
--     API/admin/reporting query flow getNseMfTransactionReconciliation() and migration validation. | Replace or
--     support: await Promise.all([prismaClient.nseMfOrder.findMany(...), prismaClient.transaction.findMany(...)])
--   Full routes / trigger: GET /operations/mf/users/:userId/orders; POST /operations/mf/users/:userId/orders/sync -
--     operations order view and reconciliation
--   Related .js file(s): server_trade/controllers/nsemf/nseMf.controller.js;
--     server_trade/routes/nseMf/nseMf.routes.js; server_etl/schdulers/mfOrderStatusSync.js;
--     server_etl/schdulers/mandateStatusTracker.js
--   Integration point: NSE MF migration and runtime reconciliation
--   Reason: Reusable PostgreSQL read/reporting model for NSE MF migration and runtime reconciliation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_nse_mf_transaction_reconciliation AS
SELECT
    o.id AS nse_mf_order_id,
    o.user_ref_id,
    o.trade_type,
    o.scheme_code,
    o.nse_order_id,
    o.order_status,
    o.allotted_qty,
    t.id AS transaction_id,
    t.status AS transaction_status,
    t.transaction_type,
    t.quantity AS transaction_quantity,
    CASE
        WHEN t.id IS NULL THEN 'TRANSACTION_MISSING'
        WHEN o.user_ref_id <> t.user_ref_id THEN 'USER_MISMATCH'
        WHEN o.scheme_code <> t.trading_symbol THEN 'SCHEME_MISMATCH'
        ELSE 'MATCHED'
    END AS reconciliation_status
FROM "trade".nse_mf_order o
LEFT JOIN "trade"."transaction" t
  ON t.exchange_order_id = o.nse_order_id
 AND t.user_ref_id = o.user_ref_id
 AND UPPER(COALESCE(t.asset, '')) = 'MF';

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_zerodha_trade_history
-- Function: getZerodhaTradeHistory
-- Prisma await: await prismaClient.zerodhaTrade.findMany({ include: { Zerodha: true } })
-- Purpose: Reusable PostgreSQL read/reporting model for Zerodha Operations reporting.
-- Point: Zerodha Operations reporting
-- Used by: API/admin/reporting query flow getZerodhaTradeHistory() and migration validation.
-- Joins stored broker responses to the non-sensitive session summary.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getZerodhaTradeHistory | Route / flow: API/admin/reporting query
--     flow getZerodhaTradeHistory() and migration validation. | Replace or support: await
--     prismaClient.zerodhaTrade.findMany({ include: { Zerodha: true } })
--   Full routes / trigger: GET /kite/trade/orders; GET /kite/trade/orders/history/:order_id; GET /kite/trade/trades -
--     Zerodha order/trade reporting
--   Related .js file(s): server_trade/controllers/zerodha/zerodhaAuth.controller.js;
--     server_trade/controllers/zerodha/zerodhaPortfolio.controller.js;
--     server_trade/controllers/zerodha/zerodhaTrade.controller.js; server_trade/routes/zerodha/zerodhaAuth.routes.js;
--     server_trade/routes/zerodha/zerodhaPortfolio.routes.js; server_trade/routes/zerodha/zerodhaTrade.routes.js;
--     server_etl/schdulers/expireZerodhaSession.js
--   Integration point: Zerodha Operations reporting
--   Reason: Reusable PostgreSQL read/reporting model for Zerodha Operations reporting.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_zerodha_trade_history AS
SELECT
    zt.id,
    zt.order_id,
    zt.trade_response,
    zt."createdAt" AS created_at,
    z.user_ref_id,
    z.zerodha_user_id,
    u.email AS registered_email,
    u.first_name,
    u.last_name
FROM "trade".zerodhatrade zt
JOIN "trade".zerodha z ON z.id = zt."zerodhaId"
LEFT JOIN "user"."user" u ON u.id = z.user_ref_id;

-- ----------------------------------------------------------------------------
-- VIEW: support.vw_ticket_config_catalog
-- Function: getTicketConfigCatalog
-- Prisma await: await Promise.all([prismaClient.ticketCategoryConfig.findMany(...), prismaClient.ticketStatusConfig.findMany(...), prismaClient.ticketPriorityConfig.findMany(...)])
-- Purpose: Reusable PostgreSQL read/reporting model for Operations ticket dropdown/configuration APIs.
-- Point: Operations ticket dropdown/configuration APIs
-- Used by: API/admin/reporting query flow getTicketConfigCatalog() and migration validation.
-- Combines status and priority configuration into a common read model.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getTicketConfigCatalog | Route / flow: API/admin/reporting query
--     flow getTicketConfigCatalog() and migration validation. | Replace or support: await
--     Promise.all([prismaClient.ticketCategoryConfig.findMany(...), prismaClient.ticketStatusConfig.findMany(...),
--     prismaClient.ticketPriorityConfig.findMany(...)])
--   Full routes / trigger: GET /operations/ticket-config/categories; GET
--     /operations/ticket-config/categories/:categoryId/subcategories; GET /operations/ticket-config/assignees; GET
--     /operations/ticket-config/statuses; GET /operations/ticket-config/priorities; GET
--     /auth/ticket-config/categories; GET /auth/ticket-config/statuses - configuration dropdowns
--   Related .js file(s): server_trade/controllers/operations/ticketConfig.controller.js;
--     server_trade/routes/operations/ticketConfig.routes.js
--   Integration point: Operations ticket dropdown/configuration APIs
--   Reason: Reusable PostgreSQL read/reporting model for Operations ticket dropdown/configuration APIs.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "support".vw_ticket_config_catalog AS
SELECT
    'STATUS'::text AS config_type,
    s.id,
    s.name,
    s.label,
    s.description,
    s.color,
    s."bgColor" AS background_color,
    s."sortOrder" AS sort_order,
    s."isDefault" AS is_default,
    s."isFinal" AS is_final,
    s."isActive" AS is_active
FROM "support".ticketstatusconfig s

UNION ALL

SELECT
    'PRIORITY',
    p.id,
    p.name,
    p.label,
    p.description,
    p.color,
    p."bgColor",
    p."sortOrder",
    p."isDefault",
    false,
    p."isActive"
FROM "support".ticketpriorityconfig p;

-- ----------------------------------------------------------------------------
-- VIEW: ops.vw_admin_notification_summary
-- Function: getAdminNotificationSummary
-- Prisma await: await prismaClient.adminNotification.groupBy(...)
-- Purpose: Reusable PostgreSQL read/reporting model for Operations notification bell, unread badge, and history.
-- Point: Operations notification bell, unread badge, and history
-- Used by: API/admin/reporting query flow getAdminNotificationSummary() and migration validation.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getAdminNotificationSummary | Route / flow: API/admin/reporting
--     query flow getAdminNotificationSummary() and migration validation. | Replace or support: await
--     prismaClient.adminNotification.groupBy(...)
--   Full routes / trigger: GET /operations/admin-notifications; GET /operations/admin-notifications/unread-count -
--     notification list/badge
--   Related .js file(s): server_trade/controllers/operations/adminNotifications.controller.js;
--     server_trade/routes/operations/adminNotifications.routes.js
--   Integration point: Operations notification bell, unread badge, and history
--   Reason: Reusable PostgreSQL read/reporting model for Operations notification bell, unread badge, and history.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "ops".vw_admin_notification_summary AS
SELECT
    n.admin_email,
    COUNT(*) AS total_notifications,
    COUNT(*) FILTER (WHERE n.is_read = false) AS unread_notifications,
    COUNT(*) FILTER (WHERE n.priority::text IN ('HIGH', 'URGENT') AND n.is_read = false) AS unread_high_priority,
    MAX(n."createdAt") AS latest_notification_at
FROM "ops".adminnotification n
GROUP BY n.admin_email;

-- ----------------------------------------------------------------------------
-- VIEW: ops.vw_admin_session_activity
-- Function: getAdminSessionActivity
-- Prisma await: await prismaClient.adminSession.findMany(...)
-- Purpose: Reusable PostgreSQL read/reporting model for Operations session-log reports.
-- Point: Operations session-log reports
-- Used by: API/admin/reporting query flow getAdminSessionActivity() and migration validation.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getAdminSessionActivity | Route / flow: API/admin/reporting query
--     flow getAdminSessionActivity() and migration validation. | Replace or support: await
--     prismaClient.adminSession.findMany(...)
--   Full routes / trigger: GET /operations/sessions/active-users; GET /operations/users/:userId/sessions - session
--     activity reports
--   Related .js file(s): server_trade/controllers/operations/sessions.controller.js;
--     server_trade/routes/operations/sessions.routes.js
--   Integration point: Operations session-log reports
--   Reason: Reusable PostgreSQL read/reporting model for Operations session-log reports.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "ops".vw_admin_session_activity AS
SELECT
    s.id,
    s.admin_id,
    s.admin_email,
    s.ip_address,
    s.device_type,
    s.browser,
    s.os,
    s.event,
    s.created_at,
    LAG(s.created_at) OVER (
        PARTITION BY COALESCE(s.admin_id, s.admin_email)
        ORDER BY s.created_at
    ) AS previous_event_at
FROM "ops".adminsession s;

-- ----------------------------------------------------------------------------
-- VIEW: catalog.vw_active_reason_templates
-- Function: getActiveReasonTemplates
-- Prisma await: await prismaClient.reasonTemplate.findMany({ where: { status: 'Active' } })
-- Purpose: Reusable PostgreSQL read/reporting model for Operations reason-template manager and KYC/ticket dropdowns.
-- Point: Operations reason-template manager and KYC/ticket dropdowns
-- Used by: API/admin/reporting query flow getActiveReasonTemplates() and migration validation.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getActiveReasonTemplates | Route / flow: API/admin/reporting
--     query flow getActiveReasonTemplates() and migration validation. | Replace or support: await
--     prismaClient.reasonTemplate.findMany({ where: { status: 'Active' } })
--   Full routes / trigger: GET /operations/reason-templates - provide active reasons for operations dropdowns
--   Related .js file(s): server_trade/controllers/operations/reasonTemplates.controller.js;
--     server_trade/routes/operations/reasonTemplates.routes.js
--   Integration point: Operations reason-template manager and KYC/ticket dropdowns
--   Reason: Reusable PostgreSQL read/reporting model for Operations reason-template manager and KYC/ticket dropdowns.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "catalog".vw_active_reason_templates AS
SELECT
    r.id,
    r.ref_id,
    r.subject,
    r.reason,
    r.html_content,
    r.reason_type,
    r.status,
    r."createdAt" AS created_at,
    r."updatedAt" AS updated_at
FROM "catalog".reason_templates r
WHERE r.status::text = 'Active';

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_watchlist_summary
-- Function: getWatchlistSummary
-- Prisma await: await prismaClient.watchlist.findMany({ include: { WatchlistDetails: true, _count: true } })
-- Purpose: Reusable PostgreSQL read/reporting model for Watchlist reporting and migration reconciliation.
-- Point: Watchlist reporting and migration reconciliation
-- Used by: API/admin/reporting query flow getWatchlistSummary() and migration validation.
-- Main DB data only; stock names/prices remain a Market/ETL enrichment.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getWatchlistSummary | Route / flow: API/admin/reporting query
--     flow getWatchlistSummary() and migration validation. | Replace or support: await
--     prismaClient.watchlist.findMany({ include: { WatchlistDetails: true, _count: true } })
--   Full routes / trigger: GET /watchlist/data; GET /iris-external/watchlist - return the user's watchlists and
--     stocks
--   Related .js file(s): server_trade/controllers/watchlist/watchlist.controller.js;
--     server_trade/routes/watchlist/watchlist.routes.js
--   Integration point: Watchlist reporting and migration reconciliation
--   Reason: Reusable PostgreSQL read/reporting model for Watchlist reporting and migration reconciliation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_watchlist_summary AS
SELECT
    w.id AS watchlist_id,
    w.user_ref_id,
    w.name,
    w.is_active,
    w.created_at,
    w.updated_at,
    COUNT(d.id) AS stock_count,
    COALESCE(SUM(d.demo_trade_price), 0) AS total_demo_trade_price,
    MIN(d.created_at) AS first_stock_added_at,
    MAX(d.created_at) AS latest_stock_added_at
FROM "trade".watchlist w
LEFT JOIN "trade".watchlistdetail d ON d.watchlist_id = w.id
GROUP BY
    w.id, w.user_ref_id, w.name, w.is_active, w.created_at, w.updated_at;

-- ----------------------------------------------------------------------------
-- VIEW: trade.vw_mf_portfolio_milestone_summary
-- Function: getMfPortfolioMilestoneSummary
-- Prisma await: await tradeDB.mfPortfolioMilestone.groupBy(...)
-- Purpose: Reusable PostgreSQL read/reporting model for MF portfolio milestone scheduler and migration validation.
-- Point: MF portfolio milestone scheduler and migration validation
-- Used by: API/admin/reporting query flow getMfPortfolioMilestoneSummary() and migration validation.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getMfPortfolioMilestoneSummary | Route / flow:
--     API/admin/reporting query flow getMfPortfolioMilestoneSummary() and migration validation. | Replace or support:
--     await tradeDB.mfPortfolioMilestone.groupBy(...)
--   Full routes / trigger: No HTTP route - server_etl/schdulers/mfPortfolioMilestoneNotifier.js reads/records
--     notification milestones
--   Related .js file(s): server_etl/schdulers/mfPortfolioMilestoneNotifier.js
--   Integration point: MF portfolio milestone scheduler and migration validation
--   Reason: Reusable PostgreSQL read/reporting model for MF portfolio milestone scheduler and migration validation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "trade".vw_mf_portfolio_milestone_summary AS
SELECT
    m.user_id,
    COUNT(*) AS notified_milestone_count,
    MIN(m.milestone) AS first_milestone,
    MAX(m.milestone) AS highest_milestone,
    MIN(m.notified_at) AS first_notified_at,
    MAX(m.notified_at) AS latest_notified_at
FROM "trade".mf_portfolio_milestones m
GROUP BY m.user_id;

-- ----------------------------------------------------------------------------
-- VIEW: ops.vw_operations_user_role_mapping
-- Function: getOperationsUserRoleMapping
-- Prisma await: await prismaClient.operations_user.findMany({ include: { operations_user_mapping: true } })
-- Purpose: Reusable PostgreSQL read/reporting model for Operations admin registry, login authorization, and reconciliation.
-- Point: Operations admin registry, login authorization, and reconciliation
-- Used by: API/admin/reporting query flow getOperationsUserRoleMapping() and migration validation.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getOperationsUserRoleMapping | Route / flow: API/admin/reporting
--     query flow getOperationsUserRoleMapping() and migration validation. | Replace or support: await
--     prismaClient.operations_user.findMany({ include: { operations_user_mapping: true } })
--   Full routes / trigger: POST /operations/register; POST /operations/login; GET /operations/operational-users -
--     resolve operations roles
--   Related .js file(s): server_trade/controllers/operations/auth.controller.js;
--     server_trade/controllers/operations/adminRegistry.controller.js;
--     server_trade/routes/operations/adminRegistry.routes.js
--   Integration point: Operations admin registry, login authorization, and reconciliation
--   Reason: Reusable PostgreSQL read/reporting model for Operations admin registry, login authorization, and
--     reconciliation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "ops".vw_operations_user_role_mapping AS
SELECT
    u.id AS user_id,
    u.email,
    u.first_name,
    u.last_name,
    u.role AS primary_role,
    u.is_active,
    u.menu_access,
    u.can_create,
    u.can_read,
    u.can_update,
    u.can_delete,
    m.id AS mapping_id,
    m.role AS mapped_role,
    m.created_at AS mapping_created_at,
    m.updated_at AS mapping_updated_at,
    (m.role IS NOT NULL AND m.role = u.role) AS role_is_consistent
FROM "ops".operations_user u
LEFT JOIN "ops".operations_user_mapping m ON m.user_id = u.id;

-- ----------------------------------------------------------------------------
-- VIEW: support.vw_helpdesk_content_summary
-- Function: getHelpdeskContentSummary
-- Prisma await: await prismaClient.helpCategory.findMany({ include: { faqs: true, videos: true, _count: true } })
-- Purpose: Reusable PostgreSQL read/reporting model for Operations/public Helpdesk categories, FAQs, and videos.
-- Point: Operations/public Helpdesk categories, FAQs, and videos
-- Used by: API/admin/reporting query flow getHelpdeskContentSummary() and migration validation.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getHelpdeskContentSummary | Route / flow: API/admin/reporting
--     query flow getHelpdeskContentSummary() and migration validation. | Replace or support: await
--     prismaClient.helpCategory.findMany({ include: { faqs: true, videos: true, _count: true } })
--   Full routes / trigger: GET /operations/helpdesk/categories; GET /operations/helpdesk/faqs; GET
--     /operations/helpdesk/videos; GET /auth/helpdesk/categories; GET /auth/helpdesk/faqs; GET /auth/helpdesk/videos
--     - Helpdesk reporting/content reads
--   Related .js file(s): server_trade/controllers/operations/helpdesk.controller.js;
--     server_trade/controllers/helpdesk/public.helpdesk.controller.js;
--     server_trade/routes/operations/helpdesk.routes.js; server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations/public Helpdesk categories, FAQs, and videos
--   Reason: Reusable PostgreSQL read/reporting model for Operations/public Helpdesk categories, FAQs, and videos.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "support".vw_helpdesk_content_summary AS
SELECT
    c.id AS category_id,
    c.title AS category_title,
    c.description AS category_description,
    c.icon AS category_icon,
    c."sortOrder" AS category_sort_order,
    c."isActive" AS category_is_active,
    COALESCE(f.faq_count, 0) AS faq_count,
    COALESCE(f.active_faq_count, 0) AS active_faq_count,
    COALESCE(v.video_count, 0) AS video_count,
    COALESCE(v.active_video_count, 0) AS active_video_count,
    COALESCE(v.video_view_count, 0) AS video_view_count
FROM "support".helpcategory c
LEFT JOIN (
    SELECT
        "categoryId",
        COUNT(*) AS faq_count,
        COUNT(*) FILTER (WHERE "isActive") AS active_faq_count
    FROM "support".helpfaq
    GROUP BY "categoryId"
) f ON f."categoryId" = c.id
LEFT JOIN (
    SELECT
        "categoryId",
        COUNT(*) AS video_count,
        COUNT(*) FILTER (WHERE "isActive") AS active_video_count,
        SUM("viewCount") AS video_view_count
    FROM "content".helpvideo
    GROUP BY "categoryId"
) v ON v."categoryId" = c.id;

-- ----------------------------------------------------------------------------
-- VIEW: payments.vw_withdrawal_request_details
-- Function: fetchWithdrawalRequests
-- Prisma await: supports walletTransaction.findMany(...) replacement
-- Purpose: Operations reporting view for withdrawal, wallet, and user details.
-- Point: Operations withdrawal queue and reconciliation
-- Used by: GET /operations/withdrawals and operations reporting.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: fetchWithdrawalRequests | Route / flow: GET
--     /operations/withdrawals and operations reporting. | Replace or support: supports
--     walletTransaction.findMany(...) replacement
--   Full routes / trigger: GET /operations/withdrawals - fetch the pending/under-review debit withdrawal queue
--   Related .js file(s): server_trade/routes/operations/operations.route.js;
--     server_trade/controllers/operations/operations.controller.js
--   Integration point: Operations withdrawal queue and reconciliation
--   Reason: Operations reporting view for withdrawal, wallet, and user details.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "payments".vw_withdrawal_request_details AS
SELECT
    wt.id AS transaction_id,
    wt."Wallet_id" AS wallet_id,
    wt.user_ref_id,
    u.email AS user_email,
    u.first_name,
    u.last_name,
    wt.amount AS withdrawal_amount,
    wt.type AS transaction_type,
    wt.status AS transaction_status,
    wt.is_blocked,
    w.amount AS available_wallet_amount,
    w.blocked_amount,
    w.status AS wallet_status,
    wt.created_at,
    wt.updated_at
FROM "payments".wallettransaction wt
JOIN "payments".wallet w ON w.id = wt."Wallet_id"
JOIN "user"."user" u ON u.id = wt.user_ref_id
WHERE wt.type::text = 'DEBIT';

-- ----------------------------------------------------------------------------
-- VIEW: ops.vw_admin_audit_log_details
-- Function: getAdminAuditLogs
-- Prisma await: replaces getRecentAuditLogs(...) file read after DB audit cutover
-- Purpose: Database-backed Operations audit-log reporting model.
-- Point: Operations governance/audit history
-- Used by: GET /operations/admin-audit-logs and audit reporting.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: No input parameters (read-only view)
--   Code / route integration target: Code function: getAdminAuditLogs | Route / flow: GET
--     /operations/admin-audit-logs and audit reporting. | Replace or support: replaces getRecentAuditLogs(...) file
--     read after DB audit cutover
--   Full routes / trigger: GET /operations/admin-audit-logs - query database-backed audit history and filters
--   Related .js file(s): server_trade/controllers/operations/operations.controller.js;
--     server_trade/routes/operations/users.routes.js; server_trade/routes/operations/auditLog.routes.js;
--     server_trade/utils/adminAuditLogger.js
--   Integration point: Operations governance/audit history
--   Reason: Database-backed Operations audit-log reporting model.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE VIEW "ops".vw_admin_audit_log_details AS
SELECT
    a.id,
    a.module,
    a."actionType" AS action_type,
    a."entityType" AS entity_type,
    a."entityId" AS entity_id,
    a."statusBefore" AS status_before,
    a."statusAfter" AS status_after,
    a."actionReason" AS action_reason,
    a."adminEmail" AS admin_email,
    a."adminName" AS admin_name,
    a."ipAddress" AS ip_address,
    a.browser,
    a.success,
    CASE WHEN a.success THEN 'SUCCESS' ELSE 'FAILED' END AS status,
    a.metadata,
    a."createdAt" AS created_at
FROM "ops".audit_logs a;

COMMIT;
