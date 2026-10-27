-- DROP DATABASE nuqiwealthmain;
CREATE DATABASE nuqiwealthmain;

-- Purpose-based PostgreSQL schema organization
-- Tables are grouped by functional area. Enum types remain in public schema.
CREATE SCHEMA IF NOT EXISTS "user";
CREATE SCHEMA IF NOT EXISTS "kyc";
CREATE SCHEMA IF NOT EXISTS "trade";
CREATE SCHEMA IF NOT EXISTS "payments";
CREATE SCHEMA IF NOT EXISTS "catalog";
CREATE SCHEMA IF NOT EXISTS "referral";
CREATE SCHEMA IF NOT EXISTS "content";
CREATE SCHEMA IF NOT EXISTS "support";
CREATE SCHEMA IF NOT EXISTS "ops";
CREATE SCHEMA IF NOT EXISTS "integration";

-- ==========================================
-- 1. CREATE ENUM TYPES
-- ==========================================
CREATE TYPE admin_notification_type AS ENUM ('SYSTEM', 'USER_ACTION', 'TRANSACTION', 'KYC', 'SECURITY', 'TICKET', 'APPROVAL_REQUEST');
CREATE TYPE admin_notification_priority AS ENUM ('LOW', 'NORMAL', 'HIGH', 'URGENT');
CREATE TYPE bank_kyc_status AS ENUM ('PENDING', 'INREVIEW', 'APPROVED', 'REJECTED');
CREATE TYPE inventory_type AS ENUM ('CEP', 'EQUITY', 'MF', 'ETF');
CREATE TYPE operations_role AS ENUM ('USER', 'ADMIN', 'SUPER_ADMIN', 'MAU', 'DEVELOPER');
CREATE TYPE order_type_enum AS ENUM ('LIMIT', 'MARKET', 'PRE_BUY', 'POST_BUY', 'FRACTIONAL', 'SELL', 'STOPLOSS');
CREATE TYPE order_status_enum AS ENUM ('PENDING', 'COMPLETED', 'SCHEDULED', 'QUEUED', 'CANCELLED', 'FAILED');
CREATE TYPE partner_points_type AS ENUM ('DIRECT_REFERRAL', 'PARENT_REFERRAL', 'ORIGINAL_OWNER');
CREATE TYPE partner_ledger_status AS ENUM ('CREDITED', 'REVERSED');
CREATE TYPE partner_account_type AS ENUM ('Company', 'INDIVIDUAL', 'LLP', 'PARTNERSHIP', 'SOLE_PROPRIETORSHIP');
CREATE TYPE partner_company_type AS ENUM ('MUTUAL_FUNDS', 'LOAN_AGGREGATOR', 'DSA_LOANS', 'INSURANCE', 'FMCG', 'INDUSTRIAL_GOODS', 'FINANCIAL_SERVICES', 'MARKETING_AGENCY');
CREATE TYPE partner_status AS ENUM ('DRAFT', 'OTP_VERIFIED', 'CREDENTIALS_SET', 'ONBOARDING', 'SUBMITTED', 'ACTIVE', 'UNDER_REVIEW', 'APPROVED', 'REJECTED');
CREATE TYPE portfolio_type_enum AS ENUM ('CEP', 'EQUITY', 'MF', 'ETF');
CREATE TYPE promo_discount_type AS ENUM ('PERCENTAGE', 'FLAT');
CREATE TYPE template_reason_type AS ENUM ('ON_HOLD', 'REJECTED', 'APPROVED', 'GENERAL');
CREATE TYPE template_status_enum AS ENUM ('Active', 'Inactive');
CREATE TYPE sub_transaction_status AS ENUM ('PENDING', 'SUCCESS', 'FAILED');
CREATE TYPE ticket_priority_enum AS ENUM ('LOW', 'MEDIUM', 'HIGH', 'URGENT');
CREATE TYPE user_role_enum AS ENUM ('USER', 'ADMIN', 'SUPER_ADMIN', 'MAU', 'DEVELOPER');
CREATE TYPE global_transaction_status AS ENUM ('PENDING', 'COMPLETED', 'CANCELLED', 'EXPIRED', 'IMPEDED', 'REVAMPED', 'PARTIALLY_FILLED', 'FAILED', 'REFUNDED', 'REVERSED', 'REVERSAL_FAILED', 'REVERSAL_PENDING', 'REVERSAL_COMPLETED', 'REVERSAL_CANCEL');
CREATE TYPE order_direction_type AS ENUM ('BUY', 'SELL');
CREATE TYPE subscription_state AS ENUM ('PENDING', 'ACTIVE', 'FAILED');
CREATE TYPE invoice_payment_status AS ENUM ('PENDING', 'SUCCESS', 'FAILED');
CREATE TYPE wallet_status_enum AS ENUM ('ACTIVE', 'INACTIVE', 'SUSPENDED');
CREATE TYPE ledger_action_type AS ENUM ('CREDIT', 'DEBIT', 'REFUND');

-- ==========================================
-- 2. CREATE TABLES WITH CONSTRAINTS
-- ==========================================

-- Table: _prisma_migrations
CREATE TABLE "ops"._prisma_migrations (
    id varchar(36) NOT NULL, 
    checksum varchar(64) NOT NULL, 
    finished_at timestamp(3) DEFAULT NULL, 
    migration_name varchar(255) NOT NULL, 
    logs text DEFAULT NULL, 
    rolled_back_at timestamp(3) DEFAULT NULL, 
    started_at timestamp(3) NOT NULL, 
    applied_steps_count integer NOT NULL,
    CONSTRAINT pk__prisma_migrations PRIMARY KEY (id)
);

-- Table: adminnotification
CREATE TABLE "ops".adminnotification (
    id serial NOT NULL, 
    title varchar(191) NOT NULL, 
    message text NOT NULL, 
    type admin_notification_type NOT NULL, 
    priority admin_notification_priority NOT NULL, 
    is_read boolean NOT NULL, 
    admin_email varchar(191) NOT NULL, 
    metadata jsonb DEFAULT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_adminnotification PRIMARY KEY (id)
);

-- Table: adminsession
CREATE TABLE "ops".adminsession (
    id varchar(191) NOT NULL, 
    admin_id varchar(191) DEFAULT NULL, 
    admin_email varchar(191) DEFAULT NULL, 
    ip_address varchar(191) DEFAULT NULL, 
    device_type varchar(191) DEFAULT NULL, 
    browser varchar(191) DEFAULT NULL, 
    os varchar(191) DEFAULT NULL, 
    user_agent text DEFAULT NULL, 
    event varchar(191) NOT NULL, 
    created_at timestamp(3) NOT NULL,
    CONSTRAINT pk_adminsession PRIMARY KEY (id)
);

-- Table: approvalrequest
CREATE TABLE "ops".approvalrequest (
    id varchar(191) NOT NULL, 
    module varchar(191) NOT NULL, 
    "actionType" varchar(191) NOT NULL, 
    "entityType" varchar(191) NOT NULL, 
    "entityId" varchar(191) DEFAULT NULL, 
    payload jsonb NOT NULL, 
    status varchar(191) NOT NULL, 
    "requestedBy" varchar(191) NOT NULL, 
    "requestedByEmail" varchar(191) NOT NULL, 
    "reviewedBy" varchar(191) DEFAULT NULL, 
    "reviewedByEmail" varchar(191) DEFAULT NULL, 
    "reviewNote" varchar(191) DEFAULT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "reviewedAt" timestamp(3) DEFAULT NULL,
    CONSTRAINT pk_approvalrequest PRIMARY KEY (id)
);

-- Table: audit_logs
CREATE TABLE "ops".audit_logs (
    id serial NOT NULL, 
    module varchar(191) NOT NULL, 
    "actionType" varchar(191) NOT NULL, 
    "entityType" varchar(191) NOT NULL, 
    "entityId" varchar(191) NOT NULL, 
    "statusBefore" varchar(191) DEFAULT NULL, 
    "statusAfter" varchar(191) DEFAULT NULL, 
    "actionReason" text DEFAULT NULL, 
    "adminEmail" varchar(191) NOT NULL, 
    "adminName" varchar(191) DEFAULT NULL, 
    "ipAddress" varchar(191) DEFAULT NULL, 
    browser varchar(191) DEFAULT NULL, 
    success boolean NOT NULL, 
    metadata jsonb DEFAULT NULL, 
    "createdAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_audit_logs PRIMARY KEY (id)
);

-- Table: bankinfo
CREATE TABLE "user".bankinfo (
    id varchar(191) NOT NULL, 
    bank_namee varchar(191) NOT NULL, 
    account_type varchar(191) NOT NULL, 
    account_name varchar(191) NOT NULL, 
    address text NOT NULL, 
    swift_code varchar(191) NOT NULL, 
    iban varchar(191) NOT NULL, 
    "isActive" boolean NOT NULL,
    CONSTRAINT pk_bankinfo PRIMARY KEY (id)
);

-- Table: bankkyc
CREATE TABLE "kyc".bankkyc (
    id serial NOT NULL, 
    "bankName" varchar(191) NOT NULL, 
    "branchName" varchar(191) NOT NULL, 
    ifsc varchar(191) NOT NULL, 
    "accountHolderName" varchar(191) NOT NULL, 
    "accountNumber" varchar(191) NOT NULL, 
    "selectedDocument" varchar(191) NOT NULL, 
    "filePath" varchar(191) NOT NULL, 
    status bank_kyc_status NOT NULL, 
    user_ref varchar(191) NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL, 
    "responseJson" jsonb DEFAULT NULL,
    CONSTRAINT pk_bankkyc PRIMARY KEY (id)
);

-- Table: companyconfig
CREATE TABLE "catalog".companyconfig (
    id varchar(191) NOT NULL, 
    name varchar(191) DEFAULT NULL, 
    assertion text DEFAULT NULL, 
    watchlist_content text DEFAULT NULL, 
    portfolio_equity_desc text DEFAULT NULL, 
    portfolio_etf_desc text DEFAULT NULL, 
    portfolio_mf_desc text DEFAULT NULL, 
    portfolio_cep_desc text DEFAULT NULL, 
    portfolio_equity_long_desc text DEFAULT NULL, 
    portfolio_etf_long_desc text DEFAULT NULL, 
    portfolio_mf_long_desc text DEFAULT NULL, 
    portfolio_cep_long_desc text DEFAULT NULL, 
    is_active boolean DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_companyconfig PRIMARY KEY (id)
);

-- Table: countries
CREATE TABLE "catalog".countries (
    id varchar(191) NOT NULL, 
    dial_code varchar(191) NOT NULL, 
    name varchar(191) NOT NULL, 
    flag varchar(191) NOT NULL, 
    mobile_number_length integer NOT NULL, 
    status boolean NOT NULL,
    CONSTRAINT pk_countries PRIMARY KEY (id)
);

-- Table: deleteduser
CREATE TABLE "user".deleteduser (
    id varchar(191) NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    email varchar(191) NOT NULL, 
    username varchar(191) DEFAULT NULL, 
    first_name varchar(191) DEFAULT NULL, 
    last_name varchar(191) DEFAULT NULL, 
    phone_number varchar(191) DEFAULT NULL, 
    deleted_at timestamp(3) NOT NULL, 
    reason varchar(191) DEFAULT NULL,
    CONSTRAINT pk_deleteduser PRIMARY KEY (id)
);

-- Table: googleuser
CREATE TABLE "user".googleuser (
    id varchar(191) NOT NULL, 
    google_id varchar(191) NOT NULL, 
    email varchar(191) NOT NULL, 
    "givenName" varchar(191) DEFAULT NULL, 
    "familyName" varchar(191) DEFAULT NULL, 
    name varchar(191) DEFAULT NULL, 
    photo varchar(191) DEFAULT NULL, 
    scopes varchar(191) DEFAULT NULL, 
    "idToken" varchar(191) DEFAULT NULL, 
    "serverAuthCode" varchar(191) DEFAULT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_googleuser PRIMARY KEY (id)
);

-- Table: helpcategory
CREATE TABLE "support".helpcategory (
    id varchar(191) NOT NULL, 
    title varchar(191) NOT NULL, 
    description text DEFAULT NULL, 
    icon varchar(191) DEFAULT NULL, 
    "sortOrder" integer NOT NULL, 
    "isActive" boolean NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_helpcategory PRIMARY KEY (id)
);

-- Table: helpfaq
CREATE TABLE "support".helpfaq (
    id varchar(191) NOT NULL, 
    question varchar(191) NOT NULL, 
    answer text NOT NULL, 
    "categoryId" varchar(191) DEFAULT NULL, 
    "videoId" varchar(191) DEFAULT NULL, 
    "sortOrder" integer NOT NULL, 
    "isActive" boolean NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_helpfaq PRIMARY KEY (id),
    CONSTRAINT fk_helpfaq_category FOREIGN KEY ("categoryId") REFERENCES "support".helpcategory (id) ON DELETE SET NULL
);

-- Table: helpvideo
CREATE TABLE "content".helpvideo (
    id varchar(191) NOT NULL, 
    title varchar(191) NOT NULL, 
    description text DEFAULT NULL, 
    url varchar(191) NOT NULL, 
    "thumbnailUrl" varchar(191) DEFAULT NULL, 
    "categoryId" varchar(191) DEFAULT NULL, 
    tags jsonb DEFAULT NULL, -- json changed to jsonb for faster filtering
    duration integer DEFAULT NULL, 
    "sortOrder" integer NOT NULL, 
    "isActive" boolean NOT NULL, 
    "viewCount" integer NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_helpvideo PRIMARY KEY (id),
    CONSTRAINT fk_helpvideo_category FOREIGN KEY ("categoryId") REFERENCES "support".helpcategory (id) ON DELETE SET NULL
);

-- Table: historicaldata
CREATE TABLE "trade".historicaldata (
    id varchar(191) NOT NULL, 
    key varchar(191) NOT NULL, 
    ticker_id varchar(191) DEFAULT NULL, 
    source_id varchar(191) DEFAULT NULL, 
    open varchar(191) DEFAULT NULL, 
    high varchar(191) DEFAULT NULL, 
    low varchar(191) DEFAULT NULL, 
    close varchar(191) DEFAULT NULL, 
    volume varchar(191) DEFAULT NULL, 
    turnover varchar(191) DEFAULT NULL, 
    avg_price varchar(191) DEFAULT NULL, 
    change varchar(191) DEFAULT NULL, 
    pct_change varchar(191) DEFAULT NULL, 
    prev_closed varchar(191) DEFAULT NULL, 
    market_cap varchar(191) DEFAULT NULL, 
    transaction_date varchar(191) DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_historicaldata PRIMARY KEY (id)
);

-- Table: inventory
CREATE TABLE "trade".inventory (
    id varchar(191) NOT NULL, 
    name varchar(191) NOT NULL, 
    stock_key varchar(191) DEFAULT NULL, 
    cep_ref_id varchar(191) DEFAULT NULL, 
    type inventory_type NOT NULL, 
    traded_currency varchar(191) DEFAULT NULL, 
    settled_currency varchar(191) DEFAULT NULL, 
    user_id varchar(191) NOT NULL, 
    quantity decimal(65,30) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    "portfolioId" varchar(191) DEFAULT NULL,
    CONSTRAINT pk_inventory PRIMARY KEY (id)
    -- Foreign key to portfolio table can be added once 'portfolio' table is declared
);

-- Table: kyc
CREATE TABLE "kyc".kyc (
    id varchar(191) NOT NULL, 
    "userId" varchar(191) NOT NULL, 
    "transactionId" varchar(191) DEFAULT NULL, 
    status varchar(191) DEFAULT NULL, 
    provider varchar(191) DEFAULT NULL, 
    "fullName" varchar(191) DEFAULT NULL, 
    dob varchar(191) DEFAULT NULL, 
    gender varchar(191) DEFAULT NULL, 
    "addressText" text DEFAULT NULL, -- longtext maps to text
    "addressJson" jsonb DEFAULT NULL, 
    "panNumber" varchar(191) DEFAULT NULL, 
    "aadhaarMaskedNumber" varchar(191) DEFAULT NULL, 
    "selfieImagePath" text DEFAULT NULL, 
    "livenessImagePath" text DEFAULT NULL, 
    "panCroppedImagePath" text DEFAULT NULL, 
    "poiIdFaceImagePath" text DEFAULT NULL, 
    "eaadhaarPdfPath" text DEFAULT NULL, 
    "aadhaarXmlPath" text DEFAULT NULL, 
    "aadhaarPhotoImagePath" text DEFAULT NULL, 
    "hyperverResponse" jsonb DEFAULT NULL, 
    "verifiedAt" timestamp(3) DEFAULT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL, 
    "nameMatchScore" double precision DEFAULT NULL, -- double maps to double precision
    rejection_reason text DEFAULT NULL,
    CONSTRAINT pk_kyc PRIMARY KEY (id)
);

-- Table: kyc_user_on_hold
CREATE TABLE "kyc".kyc_user_on_hold (
    id serial NOT NULL, -- int auto_increment maps to serial
    user_id varchar(191) NOT NULL, 
    kyc_id varchar(191) DEFAULT NULL, 
    "templateId" integer DEFAULT NULL, 
    custom_reason text DEFAULT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_kyc_user_on_hold PRIMARY KEY (id),
    CONSTRAINT fk_kyc_user_on_hold_kyc FOREIGN KEY (kyc_id) REFERENCES "kyc".kyc (id) ON DELETE SET NULL
);

-- Table: loginmethod
CREATE TABLE "user".loginmethod (
    id varchar(191) NOT NULL, 
    "Platform" varchar(191) NOT NULL, 
    email boolean NOT NULL, 
    phone boolean NOT NULL, 
    apple boolean NOT NULL, 
    google boolean NOT NULL, 
    password boolean NOT NULL, 
    description varchar(191) DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_loginmethod PRIMARY KEY (id)
);

-- Table: media
CREATE TABLE "content".media (
    id serial NOT NULL, 
    filename varchar(191) NOT NULL, 
    mimetype varchar(191) NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    data bytea DEFAULT NULL, -- longblob maps perfectly to bytea
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL, 
    filepath varchar(191) DEFAULT NULL,
    CONSTRAINT pk_media PRIMARY KEY (id)
);

-- Table: mf_portfolio_milestones
CREATE TABLE "trade".mf_portfolio_milestones (
    id serial NOT NULL, 
    user_id varchar(191) NOT NULL, 
    milestone integer NOT NULL, 
    notified_at timestamp(3) NOT NULL,
    CONSTRAINT pk_mf_portfolio_milestones PRIMARY KEY (id)
);

-- Table: nse_mf_mandate
CREATE TABLE "trade".nse_mf_mandate (
    id varchar(191) NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    client_code varchar(50) NOT NULL, 
    amount varchar(20) NOT NULL, 
    account_no varchar(50) NOT NULL, 
    ifsc_code varchar(20) NOT NULL, 
    start_date varchar(20) NOT NULL, 
    end_date varchar(20) NOT NULL, 
    request_payload jsonb DEFAULT NULL, 
    mandate_status varchar(20) DEFAULT NULL, 
    nse_status varchar(50) DEFAULT NULL, 
    nse_response jsonb DEFAULT NULL, 
    reg_id varchar(50) DEFAULT NULL, 
    reg_status varchar(50) DEFAULT NULL, 
    reg_remark text DEFAULT NULL, 
    bank_status varchar(100) DEFAULT NULL, 
    enach_status varchar(50) DEFAULT NULL, 
    umrn_no varchar(50) DEFAULT NULL, 
    approved_date varchar(20) DEFAULT NULL, 
    reject_reason text DEFAULT NULL, 
    last_status_sync timestamp(3) DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    reminder_days_sent jsonb DEFAULT NULL,
    CONSTRAINT pk_nse_mf_mandate PRIMARY KEY (id)
);

-- Table: nse_mf_onboarding
CREATE TABLE "trade".nse_mf_onboarding (
    id varchar(191) NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    current_step integer NOT NULL, 
    step1_data jsonb DEFAULT NULL, 
    step1_completed boolean NOT NULL, 
    step2_data jsonb DEFAULT NULL, 
    step2_completed boolean NOT NULL, 
    step3_data jsonb DEFAULT NULL, 
    step3_completed boolean NOT NULL, 
    step4_data jsonb DEFAULT NULL, 
    step4_completed boolean NOT NULL, 
    step5_data jsonb DEFAULT NULL, 
    step5_completed boolean NOT NULL, 
    step6_data jsonb DEFAULT NULL, 
    step6_completed boolean NOT NULL, 
    step7_data jsonb DEFAULT NULL, 
    step7_completed boolean NOT NULL, 
    onboarding_status varchar(20) NOT NULL, 
    submitted_at timestamp(3) DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_nse_mf_onboarding PRIMARY KEY (id)
);

-- Table: nse_mf_order
CREATE TABLE "trade".nse_mf_order (
    id varchar(191) NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    trade_type varchar(20) NOT NULL, 
    scheme_code varchar(50) NOT NULL, 
    amc_code varchar(100) DEFAULT NULL, 
    client_code varchar(50) NOT NULL, 
    amount varchar(20) NOT NULL, 
    folio_no varchar(50) DEFAULT NULL, 
    start_date varchar(20) DEFAULT NULL, 
    end_date varchar(20) DEFAULT NULL, 
    frequency_type varchar(20) DEFAULT NULL, 
    installment_no varchar(10) DEFAULT NULL, 
    sip_mandate_id varchar(50) DEFAULT NULL, 
    account_no varchar(50) DEFAULT NULL, 
    mobile_no varchar(20) DEFAULT NULL, 
    email varchar(100) DEFAULT NULL, 
    request_payload jsonb DEFAULT NULL, 
    order_status varchar(20) DEFAULT NULL, 
    nse_status varchar(50) DEFAULT NULL, 
    nse_response jsonb DEFAULT NULL, 
    nse_order_id varchar(50) DEFAULT NULL, 
    nse_order_status varchar(50) DEFAULT NULL, 
    nse_remark text DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    lumpsum_allotment_delayed_email_sent boolean NOT NULL, 
    lumpsum_payment_confirmed_email_sent boolean NOT NULL, 
    sip_activation_email_sent boolean NOT NULL, 
    sip_linked_mandate_email_sent boolean NOT NULL, 
    sip_reminder_sent_at timestamp(3) DEFAULT NULL, 
    allotted_amount decimal(19,4) DEFAULT NULL, 
    allotted_nav decimal(19,4) DEFAULT NULL, 
    allotted_qty decimal(19,4) DEFAULT NULL, 
    exit_load decimal(19,4) DEFAULT NULL, 
    payout_account varchar(50) DEFAULT NULL, 
    payout_bank varchar(100) DEFAULT NULL, 
    payout_date varchar(50) DEFAULT NULL, 
    payout_mode varchar(50) DEFAULT NULL, 
    payout_report jsonb DEFAULT NULL, 
    payout_status varchar(50) DEFAULT NULL, 
    redemption_report jsonb DEFAULT NULL, 
    rta_txn_no varchar(50) DEFAULT NULL, 
    settlement_id varchar(20) DEFAULT NULL, 
    settlement_type varchar(10) DEFAULT NULL, 
    stt decimal(19,4) DEFAULT NULL, 
    tax_amount decimal(19,4) DEFAULT NULL, 
    order_failed_email_sent boolean NOT NULL, 
    order_rejection_push_sent boolean NOT NULL,
    CONSTRAINT pk_nse_mf_order PRIMARY KEY (id)
);

-- Table: nse_mf_ucc
CREATE TABLE "trade".nse_mf_ucc (
    id varchar(191) NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    client_code varchar(191) NOT NULL, 
    primary_holder_first_name varchar(100) DEFAULT NULL, 
    primary_holder_last_name varchar(100) DEFAULT NULL, 
    primary_holder_pan varchar(20) DEFAULT NULL, 
    primary_holder_dob_incorporation varchar(20) DEFAULT NULL, 
    gender varchar(10) DEFAULT NULL, 
    tax_status varchar(10) DEFAULT NULL, 
    holding_nature varchar(10) DEFAULT NULL, 
    email varchar(100) DEFAULT NULL, 
    indian_mobile_no varchar(20) DEFAULT NULL, 
    account_no_1 varchar(50) DEFAULT NULL, 
    ifsc_code_1 varchar(20) DEFAULT NULL, 
    address_1 varchar(200) DEFAULT NULL, 
    city varchar(50) DEFAULT NULL, 
    state varchar(50) DEFAULT NULL, 
    pincode varchar(10) DEFAULT NULL, 
    country varchar(50) DEFAULT NULL, 
    request_payload jsonb DEFAULT NULL, 
    ucc_status varchar(20) DEFAULT NULL, 
    nse_status varchar(50) DEFAULT NULL, 
    nse_response jsonb DEFAULT NULL, 
    reg_id varchar(50) DEFAULT NULL, 
    reg_status varchar(50) DEFAULT NULL, 
    reg_remark text DEFAULT NULL, 
    kyc_check_response jsonb DEFAULT NULL, 
    kyc_status varchar(20) DEFAULT NULL, 
    kyc_status_remark varchar(100) DEFAULT NULL, 
    bank_dtl_response jsonb DEFAULT NULL, 
    bank_dtl_status varchar(20) DEFAULT NULL, 
    bank_dtl_error_remark text DEFAULT NULL, 
    fatca_submitted boolean NOT NULL, 
    fatca_request_payload jsonb DEFAULT NULL, 
    fatca_nse_response jsonb DEFAULT NULL, 
    fatca_status varchar(20) DEFAULT NULL, 
    fatca_reg_id varchar(50) DEFAULT NULL, 
    fatca_reg_status varchar(50) DEFAULT NULL, 
    fatca_reg_remark text DEFAULT NULL, 
    client_auth_status varchar(20) DEFAULT NULL, 
    client_auth_response jsonb DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    client_authorized_email_sent boolean NOT NULL,
    CONSTRAINT pk_nse_mf_ucc PRIMARY KEY (id)
);

-- Table: operations_user
CREATE TABLE "ops".operations_user (
    id varchar(191) NOT NULL, 
    first_name varchar(191) DEFAULT NULL, 
    last_name varchar(191) DEFAULT NULL, 
    password varchar(191) DEFAULT NULL, 
    role operations_role NOT NULL, 
    email varchar(191) NOT NULL, 
    create_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    can_create boolean NOT NULL, 
    can_delete boolean NOT NULL, 
    can_read boolean NOT NULL, 
    can_update boolean NOT NULL, 
    is_active boolean NOT NULL, 
    menu_access jsonb DEFAULT NULL, 
    token_version integer NOT NULL,
    CONSTRAINT pk_operations_user PRIMARY KEY (id)
);

-- Table: operations_user_mapping
CREATE TABLE "ops".operations_user_mapping (
    id varchar(191) NOT NULL, 
    user_id varchar(191) NOT NULL, 
    role operations_role NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_operations_user_mapping PRIMARY KEY (id)
);

-- Table: order ("order" is a PostgreSQL reserved keyword and must be double-quoted)
CREATE TABLE "trade"."order" (
    id varchar(191) NOT NULL, 
    portfolio_id varchar(191) NOT NULL, 
    stock_id varchar(191) DEFAULT NULL, 
    cep_ref_id varchar(191) DEFAULT NULL, 
    traded_currency varchar(191) DEFAULT NULL, 
    transaction_id varchar(191) DEFAULT NULL, 
    user_id varchar(191) DEFAULT NULL, 
    settled_currency varchar(191) DEFAULT NULL, 
    order_type order_type_enum NOT NULL, 
    limit_price decimal(19,4) DEFAULT NULL, 
    stop_price decimal(19,4) DEFAULT NULL, 
    quantity decimal(65,30) NOT NULL, 
    remaining_qty decimal(65,30) NOT NULL, 
    gtn_response text DEFAULT NULL, 
    price decimal(19,4) NOT NULL, 
    status order_status_enum NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    inventory_id varchar(191) DEFAULT NULL,
    CONSTRAINT pk_order PRIMARY KEY (id)
);

-- Table: partner_access_request
CREATE TABLE "referral".partner_access_request (
    id varchar(191) NOT NULL, 
    partner_id varchar(191) NOT NULL, 
    user_email varchar(191) NOT NULL, 
    user_id varchar(191) DEFAULT NULL, 
    status varchar(191) NOT NULL, 
    admin_notes text DEFAULT NULL, 
    reviewed_by varchar(191) DEFAULT NULL, 
    reviewed_at timestamp(3) DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_partner_access_request PRIMARY KEY (id)
);

-- Table: partner_client
CREATE TABLE "referral".partner_client (
    id varchar(191) NOT NULL, 
    partner_id varchar(191) NOT NULL, 
    name varchar(191) NOT NULL, 
    pan_number varchar(10) DEFAULT NULL, 
    date_of_birth varchar(10) DEFAULT NULL, 
    mobile varchar(15) DEFAULT NULL, 
    email varchar(191) DEFAULT NULL, 
    status varchar(191) NOT NULL, 
    source varchar(191) NOT NULL, 
    linked_user_id varchar(191) DEFAULT NULL, 
    notes text DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_partner_client PRIMARY KEY (id)
);

-- Table: partner_commission_config
CREATE TABLE "referral".partner_commission_config (
    id varchar(191) NOT NULL, 
    partner_id varchar(191) NOT NULL, 
    mf_rate decimal(5,2) NOT NULL, 
    cep_rate decimal(5,2) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_partner_commission_config PRIMARY KEY (id)
);

-- Table: partner_commission_ledger
CREATE TABLE "referral".partner_commission_ledger (
    id varchar(191) NOT NULL, 
    partner_id varchar(191) NOT NULL, 
    client_id varchar(191) NOT NULL, 
    transaction_ref varchar(191) NOT NULL, 
    transaction_type varchar(191) NOT NULL, 
    transaction_amount decimal(15,2) NOT NULL, 
    commission_rate decimal(5,2) NOT NULL, 
    commission_amount decimal(15,2) NOT NULL, 
    created_at timestamp(3) NOT NULL,
    CONSTRAINT pk_partner_commission_ledger PRIMARY KEY (id),
    CONSTRAINT fk_commission_ledger_client FOREIGN KEY (client_id) REFERENCES "referral".partner_client (id) ON DELETE RESTRICT
);

-- Table: partner_invoice
CREATE TABLE "referral".partner_invoice (
    id varchar(191) NOT NULL, 
    partner_id varchar(191) NOT NULL, 
    invoice_number varchar(191) NOT NULL, 
    cycle_start timestamp(3) NOT NULL, 
    cycle_end timestamp(3) NOT NULL, 
    commission_amount decimal(15,2) NOT NULL, 
    gst_applied boolean NOT NULL, -- tinyint(1) rewritten to standard relational boolean
    gst_amount decimal(15,2) NOT NULL, 
    total_amount decimal(15,2) NOT NULL, 
    status varchar(191) NOT NULL, 
    paid_at timestamp(3) DEFAULT NULL, 
    created_at timestamp(3) NOT NULL,
    CONSTRAINT pk_partner_invoice PRIMARY KEY (id)
);

-- Table: partner_lead
CREATE TABLE "referral".partner_lead (
    id varchar(191) NOT NULL, 
    partner_id varchar(191) DEFAULT NULL, 
    name varchar(191) NOT NULL, 
    phone varchar(191) DEFAULT NULL, 
    email varchar(191) DEFAULT NULL, 
    city varchar(191) DEFAULT NULL, 
    category varchar(191) NOT NULL, 
    est_value decimal(19,4) DEFAULT NULL, 
    notes text DEFAULT NULL, 
    status varchar(191) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    partner_user_id varchar(191) DEFAULT NULL,
    CONSTRAINT pk_partner_lead PRIMARY KEY (id)
);

-- Table: partner_points_balance
CREATE TABLE "referral".partner_points_balance (
    id varchar(191) NOT NULL, 
    user_id varchar(191) NOT NULL, 
    total_points decimal(19,4) NOT NULL, 
    current_points decimal(19,4) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_partner_points_balance PRIMARY KEY (id)
);

-- Table: partner_points_config
CREATE TABLE "referral".partner_points_config (
    id varchar(191) NOT NULL, 
    user_id varchar(191) NOT NULL, 
    direct_referral_percent decimal(5,2) NOT NULL, 
    parent_referral_percent decimal(5,2) NOT NULL, 
    original_owner_percent decimal(5,2) NOT NULL, 
    is_active boolean NOT NULL, -- tinyint(1) mapped to boolean
    set_by varchar(191) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_partner_points_config PRIMARY KEY (id)
);

-- Table: partner_points_ledger
CREATE TABLE "referral".partner_points_ledger (
    id varchar(191) NOT NULL, 
    beneficiary_user_id varchar(191) NOT NULL, 
    source_user_id varchar(191) NOT NULL, 
    transaction_ref_id varchar(191) NOT NULL, 
    points_type partner_points_type NOT NULL, 
    percentage_applied decimal(5,2) NOT NULL, 
    transaction_amount decimal(19,4) NOT NULL, 
    points_earned decimal(19,4) NOT NULL, 
    status partner_ledger_status NOT NULL, 
    created_at timestamp(3) NOT NULL,
    CONSTRAINT pk_partner_points_ledger PRIMARY KEY (id)
);

-- Table: partner_user
CREATE TABLE "referral".partner_user (
    id varchar(191) NOT NULL, 
    email varchar(191) DEFAULT NULL, 
    mobile varchar(191) DEFAULT NULL, 
    mobile_prefix varchar(191) DEFAULT NULL, 
    email_verified boolean NOT NULL, 
    mobile_verified boolean NOT NULL, 
    stag_token varchar(512) DEFAULT NULL, 
    full_name varchar(191) DEFAULT NULL, 
    password_hash varchar(191) DEFAULT NULL, 
    token varchar(512) DEFAULT NULL, 
    email_otp_hash varchar(512) DEFAULT NULL, 
    mobile_otp_hash varchar(512) DEFAULT NULL, 
    onboarding_step integer NOT NULL, 
    account_type partner_account_type DEFAULT NULL, 
    company_type partner_company_type DEFAULT NULL, 
    date_of_birth timestamp(3) DEFAULT NULL, 
    age integer DEFAULT NULL, 
    firm_name varchar(191) DEFAULT NULL, 
    sebi_registration_number varchar(191) DEFAULT NULL, 
    arn_number varchar(191) DEFAULT NULL, 
    entity_type varchar(191) DEFAULT NULL, 
    pan_number varchar(10) DEFAULT NULL, 
    pan_image_url varchar(191) DEFAULT NULL, 
    aadhaar_number varchar(12) DEFAULT NULL, 
    aadhaar_front_url varchar(191) DEFAULT NULL, 
    aadhaar_back_url varchar(191) DEFAULT NULL, 
    address_line1 varchar(191) DEFAULT NULL, 
    address_line2 varchar(191) DEFAULT NULL, 
    city varchar(191) DEFAULT NULL, 
    state varchar(191) DEFAULT NULL, 
    pin_code varchar(6) DEFAULT NULL, 
    bank_name varchar(191) DEFAULT NULL, 
    bank_account_number varchar(20) DEFAULT NULL, 
    bank_account_holder_name varchar(191) DEFAULT NULL, 
    ifsc_code varchar(11) DEFAULT NULL, 
    gst_number varchar(15) DEFAULT NULL, 
    bank_verification_doc_type varchar(30) DEFAULT NULL, 
    bank_verification_doc_url varchar(191) DEFAULT NULL, 
    signature_url varchar(191) DEFAULT NULL, 
    agreement_otp_hash varchar(512) DEFAULT NULL, 
    agreement_accepted boolean NOT NULL, 
    agreement_accepted_at timestamp(3) DEFAULT NULL, 
    agreement_pdf_version varchar(191) DEFAULT NULL, 
    submitted_at timestamp(3) DEFAULT NULL, 
    reviewed_at timestamp(3) DEFAULT NULL, 
    reviewed_by varchar(191) DEFAULT NULL, 
    rejection_reason text DEFAULT NULL, 
    status partner_status NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    referral_code varchar(10) DEFAULT NULL,
    CONSTRAINT pk_partner_user PRIMARY KEY (id)
);

-- Table: portfolio
CREATE TABLE "trade".portfolio (
    id varchar(191) NOT NULL, 
    user_id varchar(191) NOT NULL, 
    invested_amount decimal(65,30) DEFAULT NULL, 
    name varchar(191) NOT NULL, 
    type portfolio_type_enum NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_portfolio PRIMARY KEY (id)
);

-- Table: promo_code
CREATE TABLE "catalog".promo_code (
    id varchar(191) NOT NULL, 
    code varchar(191) NOT NULL, 
    description text DEFAULT NULL, 
    discount_type promo_discount_type NOT NULL, 
    discount_value decimal(19,4) NOT NULL, 
    min_order_amount decimal(19,4) DEFAULT NULL, 
    max_discount decimal(19,4) DEFAULT NULL, 
    max_uses integer DEFAULT NULL, 
    max_uses_per_user integer NOT NULL, 
    current_uses integer NOT NULL, 
    valid_from timestamp(3) NOT NULL, 
    valid_till timestamp(3) NOT NULL, 
    applicable_plans jsonb DEFAULT NULL, 
    is_active boolean NOT NULL, 
    created_by varchar(191) NOT NULL, 
    linked_user_id varchar(191) DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_promo_code PRIMARY KEY (id)
);

-- Table: promo_code_use
CREATE TABLE "catalog".promo_code_use (
    id varchar(191) NOT NULL, 
    promo_code_id varchar(191) NOT NULL, 
    user_id varchar(191) NOT NULL, 
    subscription_txn_id varchar(191) DEFAULT NULL, 
    discount_applied decimal(19,4) NOT NULL, 
    used_at timestamp(3) NOT NULL,
    CONSTRAINT pk_promo_code_use PRIMARY KEY (id),
    CONSTRAINT fk_promo_code_use_promo FOREIGN KEY (promo_code_id) REFERENCES "catalog".promo_code (id) ON DELETE CASCADE
);

-- Table: reason_templates
CREATE TABLE "catalog".reason_templates (
    id serial NOT NULL, 
    ref_id varchar(191) NOT NULL, 
    subject varchar(191) NOT NULL, 
    reason text NOT NULL, 
    html_content text DEFAULT NULL, 
    reason_type template_reason_type NOT NULL, 
    status template_status_enum NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_reason_templates PRIMARY KEY (id)
);

-- Table: referral
CREATE TABLE "referral".referral (
    id varchar(191) NOT NULL, 
    referal_code varchar(191) NOT NULL, 
    is_active boolean NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    current_uses integer NOT NULL, 
    max_uses integer DEFAULT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_referral PRIMARY KEY (id)
);

-- Table: referral_hierarchy
CREATE TABLE "referral".referral_hierarchy (
    id varchar(191) NOT NULL, 
    user_id varchar(191) NOT NULL, 
    direct_referrer_id varchar(191) DEFAULT NULL, 
    original_code_owner_id varchar(191) DEFAULT NULL, 
    depth integer NOT NULL, 
    "chain" jsonb DEFAULT NULL, -- chain is an optional reserved word block inside some frameworks
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_referral_hierarchy PRIMARY KEY (id)
);

-- Table: referral_use
CREATE TABLE "referral".referral_use (
    id varchar(191) NOT NULL, 
    referral_id varchar(191) NOT NULL, 
    referred_user_id varchar(191) NOT NULL, 
    referrer_user_id varchar(191) NOT NULL, 
    created_at timestamp(3) NOT NULL,
    CONSTRAINT pk_referral_use PRIMARY KEY (id),
    CONSTRAINT fk_referral_use_parent FOREIGN KEY (referral_id) REFERENCES "referral".referral (id) ON DELETE CASCADE
);

-- Table: refreshtoken
CREATE TABLE "user".refreshtoken (
    id serial NOT NULL, 
    "userId" varchar(64) NOT NULL, 
    "tokenHash" varchar(64) NOT NULL, 
    "familyId" varchar(36) NOT NULL, 
    "expiresAt" timestamp(3) NOT NULL, 
    revoked boolean NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "deviceInfo" jsonb DEFAULT NULL, 
    "isUsed" boolean NOT NULL, 
    "revokedAt" timestamp(3) DEFAULT NULL, 
    "revokedReason" varchar(191) DEFAULT NULL, 
    "tokenVersion" integer NOT NULL, 
    "userType" varchar(191) NOT NULL,
    CONSTRAINT pk_refreshtoken PRIMARY KEY (id)
);

-- Table: registerstagging
CREATE TABLE "user".registerstagging (
    id varchar(191) NOT NULL, 
    google_id varchar(191) DEFAULT NULL, 
    apple_id varchar(191) DEFAULT NULL, 
    email varchar(191) DEFAULT NULL, 
    phone_number varchar(191) DEFAULT NULL, 
    phone_prefix varchar(191) DEFAULT NULL, 
    is_email_verified boolean NOT NULL, 
    is_phone_verified boolean NOT NULL, 
    stag_token text DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    token_expiry timestamp(3) DEFAULT NULL, 
    referring_partner_id varchar(191) DEFAULT NULL,
    CONSTRAINT pk_registerstagging PRIMARY KEY (id)
);

-- Table: riskprofilequestions
CREATE TABLE "catalog".riskprofilequestions (
    id varchar(191) NOT NULL, 
    question varchar(191) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_riskprofilequestions PRIMARY KEY (id)
);

-- Table: riskprofileanswer
CREATE TABLE "catalog".riskprofileanswer (
    id varchar(191) NOT NULL, 
    answer varchar(191) NOT NULL, 
    score integer NOT NULL, 
    question_id varchar(191) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_riskprofileanswer PRIMARY KEY (id),
    CONSTRAINT fk_riskprofileanswer_question FOREIGN KEY (question_id) REFERENCES "catalog".riskprofilequestions (id) ON DELETE CASCADE
);

-- Table: riskprofilescoregrid
CREATE TABLE "catalog".riskprofilescoregrid (
    id varchar(191) NOT NULL, 
    risk_level varchar(191) NOT NULL, 
    min_score integer NOT NULL, 
    max_score integer NOT NULL, 
    description text DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_riskprofilescoregrid PRIMARY KEY (id)
);

-- Table: subscriptions
CREATE TABLE "payments".subscriptions (
    id varchar(191) NOT NULL, 
    name varchar(191) NOT NULL, 
    price integer NOT NULL, 
    is_active boolean NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    update_at timestamp(3) NOT NULL, 
    feature_summary jsonb DEFAULT NULL, 
    is_nuclear boolean NOT NULL, 
    upcoming_feature jsonb DEFAULT NULL,
    CONSTRAINT pk_subscriptions PRIMARY KEY (id)
);

-- Table: subscription_coming_soon_features
CREATE TABLE "catalog".subscription_coming_soon_features (
    id varchar(191) NOT NULL, 
    title varchar(191) NOT NULL, 
    description varchar(191) DEFAULT NULL, 
    "subscriptionId" varchar(191) NOT NULL,
    CONSTRAINT pk_subscription_coming_soon_features PRIMARY KEY (id),
    CONSTRAINT fk_coming_soon_sub FOREIGN KEY ("subscriptionId") REFERENCES "payments".subscriptions (id) ON DELETE CASCADE
);

-- Table: subscription_features
CREATE TABLE "catalog".subscription_features (
    id varchar(191) NOT NULL, 
    title varchar(191) NOT NULL, 
    category varchar(191) NOT NULL, 
    description varchar(191) DEFAULT NULL, 
    "subscriptionId" varchar(191) NOT NULL,
    CONSTRAINT pk_subscription_features PRIMARY KEY (id),
    CONSTRAINT fk_features_sub FOREIGN KEY ("subscriptionId") REFERENCES "payments".subscriptions (id) ON DELETE CASCADE
);

-- Table: subscriptionfeature
CREATE TABLE "catalog".subscriptionfeature (
    id varchar(191) NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    "ethicalStocksAccess" integer NOT NULL, 
    "brokerAccess" boolean NOT NULL, 
    "portfolioAccess" boolean NOT NULL, 
    "cepsAccess" jsonb DEFAULT NULL, 
    "featuredStocksAccess" integer NOT NULL, 
    "storiesAccess" integer NOT NULL, 
    "stockDetailsAccess" jsonb DEFAULT NULL, 
    "keyInsightsAccess" integer NOT NULL, 
    "priceAlertsLimit" integer NOT NULL, 
    "advancedAlertsAccess" boolean NOT NULL, 
    "advancedSearchAccess" boolean NOT NULL, 
    "peerComparisonLimit" integer NOT NULL, 
    "sectorAnalysisAccess" boolean NOT NULL, 
    "downloadResultsAccess" boolean NOT NULL, 
    "pricingDataYears" integer NOT NULL, 
    "fundamentalDataYears" integer NOT NULL, 
    "shareholderDataAccess" boolean NOT NULL, 
    "marketShareAccess" boolean NOT NULL, 
    "revenueAccess" boolean NOT NULL, 
    "financialStatementsYears" integer NOT NULL, 
    "technicalDataYears" integer NOT NULL, 
    "technicalScreenersLimit" integer NOT NULL, 
    "customScreenersAccess" boolean NOT NULL, 
    "cepLimit" integer NOT NULL, 
    "aiAdvisorAccess" boolean NOT NULL, 
    "dailyMarketNewsAccess" boolean NOT NULL, 
    "postMarketAnalysisAccess" boolean NOT NULL, 
    "portfolioAnalysisAccess" boolean NOT NULL, 
    "aiPicksAccess" boolean NOT NULL, 
    "watchlistLimit" integer NOT NULL, 
    "tradeExecutionAccess" boolean NOT NULL, 
    "portfolioPurification" boolean NOT NULL, 
    "portfolioAggregation" boolean NOT NULL, 
    "mfTradeExecution" boolean NOT NULL, 
    "mfAggregationAccess" boolean NOT NULL, 
    "globalStocksAccess" boolean NOT NULL, 
    "netWorthAccess" boolean NOT NULL, 
    "calculatorsAccess" boolean NOT NULL, 
    "sentimentAnalysisLimit" integer NOT NULL, 
    "dedicatedAgentAccess" boolean NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_subscriptionfeature PRIMARY KEY (id)
);

-- Table: subscriptiontransaction
CREATE TABLE "payments".subscriptiontransaction (
    id varchar(191) NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    user_subscription_id varchar(191) NOT NULL, 
    subscription_id varchar(191) NOT NULL, 
    transaction_id varchar(191) DEFAULT NULL, 
    order_id varchar(191) NOT NULL, 
    transaction_status sub_transaction_status NOT NULL, 
    trace_id varchar(191) DEFAULT NULL, 
    response_data text DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    update_at timestamp(3) NOT NULL, 
    request_raw text DEFAULT NULL, 
    response_raw text DEFAULT NULL, 
    mode varchar(191) DEFAULT NULL, 
    discount_amount decimal(19,4) DEFAULT NULL, 
    original_amount decimal(19,4) DEFAULT NULL, 
    promo_code_id varchar(191) DEFAULT NULL,
    CONSTRAINT pk_subscriptiontransaction PRIMARY KEY (id),
    CONSTRAINT fk_sub_transaction_sub FOREIGN KEY (subscription_id) REFERENCES "payments".subscriptions (id) ON DELETE RESTRICT
    -- ForeignKey to promo_code(id) and usersubscription(id) can be safely established once those schemas load
);

-- Table: ticketassignee
CREATE TABLE "support".ticketassignee (
    id varchar(191) NOT NULL, 
    name varchar(191) NOT NULL, 
    email varchar(191) NOT NULL, 
    role varchar(191) DEFAULT NULL, 
    department varchar(191) DEFAULT NULL, 
    "sortOrder" integer NOT NULL, 
    "isActive" boolean NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL, 
    password varchar(191) DEFAULT NULL,
    CONSTRAINT pk_ticketassignee PRIMARY KEY (id)
);

-- Table: ticketcategoryconfig
CREATE TABLE "support".ticketcategoryconfig (
    id varchar(191) NOT NULL, 
    name varchar(191) NOT NULL, 
    description text DEFAULT NULL, 
    icon varchar(191) DEFAULT NULL, 
    "attachmentRequired" boolean NOT NULL, 
    "sortOrder" integer NOT NULL, 
    "isActive" boolean NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_ticketcategoryconfig PRIMARY KEY (id)
);

-- Table: ticketpriorityconfig
CREATE TABLE "support".ticketpriorityconfig (
    id varchar(191) NOT NULL, 
    name varchar(191) NOT NULL, 
    label varchar(191) NOT NULL, 
    description text DEFAULT NULL, 
    color varchar(191) NOT NULL, 
    "bgColor" varchar(191) NOT NULL, 
    "sortOrder" integer NOT NULL, 
    "isDefault" boolean NOT NULL, 
    "isActive" boolean NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_ticketpriorityconfig PRIMARY KEY (id)
);

-- Table: ticketstatusconfig
CREATE TABLE "support".ticketstatusconfig (
    id varchar(191) NOT NULL, 
    name varchar(191) NOT NULL, 
    label varchar(191) NOT NULL, 
    description text DEFAULT NULL, 
    color varchar(191) NOT NULL, 
    "bgColor" varchar(191) NOT NULL, 
    icon varchar(191) DEFAULT NULL, 
    "statusType" varchar(191) NOT NULL, 
    "sortOrder" integer NOT NULL, 
    "isDefault" boolean NOT NULL, 
    "isFinal" boolean NOT NULL, 
    "isActive" boolean NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_ticketstatusconfig PRIMARY KEY (id)
);

-- Table: ticketsubcategory
CREATE TABLE "support".ticketsubcategory (
    id varchar(191) NOT NULL, 
    "categoryId" varchar(191) NOT NULL, 
    name varchar(191) NOT NULL, 
    description text DEFAULT NULL, 
    "attachmentRequired" boolean DEFAULT NULL, 
    "sortOrder" integer NOT NULL, 
    "isActive" boolean NOT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_ticketsubcategory PRIMARY KEY (id),
    CONSTRAINT fk_ticketsubcat_category FOREIGN KEY ("categoryId") REFERENCES "support".ticketcategoryconfig (id) ON DELETE CASCADE
);

-- Table: user ("user" is a strict PostgreSQL reserved keyword and must be double-quoted)
CREATE TABLE "user"."user" (
    id varchar(191) NOT NULL, 
    google_id varchar(191) DEFAULT NULL, 
    email varchar(191) DEFAULT NULL, 
    username varchar(191) DEFAULT NULL, 
    first_name varchar(191) DEFAULT NULL, 
    last_name varchar(191) DEFAULT NULL, 
    phone_number varchar(191) DEFAULT NULL, 
    phone_prefix varchar(191) DEFAULT NULL, 
    last_login_region varchar(191) DEFAULT NULL, 
    "profileUrl" varchar(191) DEFAULT NULL, 
    address varchar(191) DEFAULT NULL, 
    kyc_status varchar(191) DEFAULT NULL, 
    bankkyc_status varchar(191) DEFAULT NULL, 
    currency_pref varchar(191) DEFAULT NULL, 
    notification_token varchar(191) DEFAULT NULL, 
    otp varchar(191) DEFAULT NULL, 
    password varchar(191) DEFAULT NULL, 
    mpin integer DEFAULT NULL, 
    date_of_birth timestamp(3) DEFAULT NULL, 
    referral varchar(191) DEFAULT NULL, 
    customer_number varchar(191) DEFAULT NULL, 
    equity_account_number varchar(191) DEFAULT NULL, 
    etf_account_number varchar(191) DEFAULT NULL, 
    mf_account_number varchar(191) DEFAULT NULL, 
    token text DEFAULT NULL, 
    token_expiry_time varchar(191) DEFAULT NULL, 
    role user_role_enum NOT NULL, 
    is_phone_verified boolean NOT NULL, 
    is_email_verified boolean NOT NULL, 
    is_kyc_verified boolean NOT NULL, 
    is_bank_kyc_verified boolean NOT NULL, 
    is_risk_verified boolean NOT NULL, 
    is_deleted boolean NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    refreshtoken varchar(191) DEFAULT NULL, 
    homelayout jsonb DEFAULT NULL, 
    apple_id varchar(191) DEFAULT NULL, 
    "irisEmail" varchar(191) DEFAULT NULL, 
    "irisPassword" varchar(191) DEFAULT NULL, 
    "irisRefreshToken" text DEFAULT NULL, 
    middle_name varchar(191) DEFAULT NULL, 
    account_status varchar(191) DEFAULT NULL, 
    last_active_at timestamp(3) DEFAULT NULL, 
    token_version integer NOT NULL,
    CONSTRAINT pk_user PRIMARY KEY (id)
);

-- Table: ticket
CREATE TABLE "support".ticket (
    id varchar(191) NOT NULL, 
    "ticketNumber" varchar(191) NOT NULL, 
    "userId" varchar(191) NOT NULL, 
    "categoryId" varchar(191) DEFAULT NULL, 
    "subcategoryId" varchar(191) DEFAULT NULL, 
    subject varchar(191) NOT NULL, 
    description text NOT NULL, 
    priority ticket_priority_enum NOT NULL, 
    status varchar(191) NOT NULL, 
    "assignedTo" varchar(191) DEFAULT NULL, 
    resolution text DEFAULT NULL, 
    "escalationLevel" integer NOT NULL, 
    attachments jsonb DEFAULT NULL, 
    metadata jsonb DEFAULT NULL, 
    "firstResponseAt" timestamp(3) DEFAULT NULL, 
    "resolvedAt" timestamp(3) DEFAULT NULL, 
    "closedAt" timestamp(3) DEFAULT NULL, 
    rating integer DEFAULT NULL, 
    "ratingFeedback" text DEFAULT NULL, 
    "ratedAt" timestamp(3) DEFAULT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL, 
    "internalStatus" varchar(191) DEFAULT NULL,
    CONSTRAINT pk_ticket PRIMARY KEY (id),
    CONSTRAINT fk_ticket_user FOREIGN KEY ("userId") REFERENCES "user"."user" (id) ON DELETE RESTRICT,
    CONSTRAINT fk_ticket_category FOREIGN KEY ("categoryId") REFERENCES "support".ticketcategoryconfig (id) ON DELETE SET NULL,
    CONSTRAINT fk_ticket_subcategory FOREIGN KEY ("subcategoryId") REFERENCES "support".ticketsubcategory (id) ON DELETE SET NULL,
    CONSTRAINT fk_ticket_assignee FOREIGN KEY ("assignedTo") REFERENCES "support".ticketassignee (id) ON DELETE SET NULL
);

-- Table: ticketcomment
CREATE TABLE "support".ticketcomment (
    id varchar(191) NOT NULL, 
    "ticketId" varchar(191) NOT NULL, 
    "userId" varchar(191) DEFAULT NULL, 
    message text NOT NULL, 
    "commentBy" varchar(191) NOT NULL, 
    "commentType" varchar(191) NOT NULL, 
    "isInternal" boolean NOT NULL, 
    attachments jsonb DEFAULT NULL, 
    "createdAt" timestamp(3) NOT NULL, 
    "updatedAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_ticketcomment PRIMARY KEY (id),
    CONSTRAINT fk_ticketcomment_ticket FOREIGN KEY ("ticketId") REFERENCES "support".ticket (id) ON DELETE CASCADE,
    CONSTRAINT fk_ticketcomment_user FOREIGN KEY ("userId") REFERENCES "user"."user" (id) ON DELETE SET NULL
);

-- Table: transactionlogs
CREATE TABLE "trade".transactionlogs (
    id varchar(191) NOT NULL, 
    reason text DEFAULT NULL, 
    error text DEFAULT NULL, 
    transaction_id varchar(191) DEFAULT NULL, 
    order_id varchar(191) DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_transactionlogs PRIMARY KEY (id)
    -- Note: Foreign key constraint to the 'transaction' table can be wired once the main transaction schema batch is run.
);

-- Table: transaction ("transaction" is a highly restricted PostgreSQL keyword)
CREATE TABLE "trade"."transaction" (
    id varchar(191) NOT NULL, 
    status global_transaction_status NOT NULL, 
    scripcode varchar(191) NOT NULL, 
    tag varchar(191) DEFAULT NULL, 
    exchange_order_id varchar(191) DEFAULT NULL, 
    account_id varchar(191) DEFAULT NULL, 
    trading_symbol varchar(191) DEFAULT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    average_price decimal(19,4) DEFAULT NULL, 
    order_response jsonb DEFAULT NULL, 
    asset varchar(191) DEFAULT NULL, 
    guid varchar(191) DEFAULT NULL, 
    filled_quantity decimal(19,4) NOT NULL, 
    quantity decimal(19,4) NOT NULL, 
    pending_quantity decimal(19,4) NOT NULL, 
    cancelled_quantity decimal(19,4) NOT NULL, 
    transaction_date varchar(191) DEFAULT NULL, 
    parent_transaction_id varchar(191) DEFAULT NULL, 
    cep_ref_id varchar(191) DEFAULT NULL, 
    description text DEFAULT NULL, 
    enctoken text DEFAULT NULL, 
    is_expired boolean NOT NULL, 
    platform varchar(191) DEFAULT NULL, 
    provider varchar(191) DEFAULT NULL, 
    trade_platform varchar(191) DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    transaction_type order_direction_type NOT NULL, 
    order_id varchar(12) DEFAULT NULL, 
    broker_client_id varchar(191) DEFAULT NULL,
    CONSTRAINT pk_transaction PRIMARY KEY (id),
    CONSTRAINT fk_transaction_user FOREIGN KEY (user_ref_id) REFERENCES "user"."user" (id) ON DELETE RESTRICT
);

-- Table: userriskprofile
CREATE TABLE "catalog".userriskprofile (
    id varchar(191) NOT NULL, 
    user_id varchar(191) NOT NULL, 
    total_score integer NOT NULL, 
    risk_profile_id varchar(191) NOT NULL, 
    reason varchar(191) DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    answers text DEFAULT NULL, -- longtext translated to text
    is_active boolean DEFAULT NULL, 
    is_checked boolean DEFAULT NULL, 
    is_override boolean NOT NULL,
    CONSTRAINT pk_userriskprofile PRIMARY KEY (id),
    CONSTRAINT fk_userriskprofile_user FOREIGN KEY (user_id) REFERENCES "user"."user" (id) ON DELETE CASCADE,
    CONSTRAINT fk_userriskprofile_grid FOREIGN KEY (risk_profile_id) REFERENCES "catalog".riskprofilescoregrid (id) ON DELETE RESTRICT
);

-- Table: usersubscription
CREATE TABLE "payments".usersubscription (
    id varchar(191) NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    "subscriptionsId" varchar(191) NOT NULL, 
    plan_name varchar(191) DEFAULT NULL, 
    amount decimal(19,4) NOT NULL, 
    start_date timestamp(3) NOT NULL, 
    end_date timestamp(3) NOT NULL, 
    subscription_status subscription_state NOT NULL, 
    transaction_status invoice_payment_status NOT NULL, 
    trace_id varchar(191) DEFAULT NULL, 
    response_data text DEFAULT NULL, 
    created_at timestamp(3) NOT NULL, 
    update_at timestamp(3) NOT NULL,
    CONSTRAINT pk_usersubscription PRIMARY KEY (id),
    CONSTRAINT fk_usersub_user FOREIGN KEY (user_ref_id) REFERENCES "user"."user" (id) ON DELETE RESTRICT,
    CONSTRAINT fk_usersub_sub FOREIGN KEY ("subscriptionsId") REFERENCES "payments".subscriptions (id) ON DELETE RESTRICT
);

-- Table: wallet
CREATE TABLE "payments".wallet (
    id varchar(191) NOT NULL, 
    amount decimal(65,30) NOT NULL, 
    blocked_amount decimal(65,30) NOT NULL, 
    status wallet_status_enum NOT NULL, 
    suspended_till timestamp(3) DEFAULT NULL, 
    is_deleted boolean NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    update_at timestamp(3) NOT NULL,
    CONSTRAINT pk_wallet PRIMARY KEY (id),
    CONSTRAINT fk_wallet_user FOREIGN KEY (user_ref_id) REFERENCES "user"."user" (id) ON DELETE RESTRICT
);

-- Table: wallettransaction
CREATE TABLE "payments".wallettransaction (
    id varchar(191) NOT NULL, 
    "Wallet_id" varchar(191) NOT NULL, 
    amount decimal(19,4) NOT NULL, 
    type ledger_action_type NOT NULL, 
    status global_transaction_status NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    is_blocked boolean NOT NULL,
    CONSTRAINT pk_wallettransaction PRIMARY KEY (id),
    CONSTRAINT fk_wallettransaction_wallet FOREIGN KEY ("Wallet_id") REFERENCES "payments".wallet (id) ON DELETE CASCADE,
    CONSTRAINT fk_wallettransaction_user FOREIGN KEY (user_ref_id) REFERENCES "user"."user" (id) ON DELETE RESTRICT
);

-- Table: watchlist
CREATE TABLE "trade".watchlist (
    id varchar(191) NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    name varchar(191) NOT NULL, 
    is_active boolean NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL,
    CONSTRAINT pk_watchlist PRIMARY KEY (id),
    CONSTRAINT fk_watchlist_user FOREIGN KEY (user_ref_id) REFERENCES "user"."user" (id) ON DELETE CASCADE
);

-- Table: watchlistdetail
CREATE TABLE "trade".watchlistdetail (
    id varchar(191) NOT NULL, 
    watchlist_id varchar(191) NOT NULL, 
    demo_trade_price decimal(19,2) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    scripcode integer NOT NULL,
    CONSTRAINT pk_watchlistdetail PRIMARY KEY (id),
    CONSTRAINT fk_watchlistdetail_parent FOREIGN KEY (watchlist_id) REFERENCES "trade".watchlist (id) ON DELETE CASCADE
);

-- Table: zerodha
CREATE TABLE "trade".zerodha (
    id varchar(191) NOT NULL, 
    user_ref_id varchar(191) NOT NULL, 
    zerodha_user_id varchar(191) NOT NULL, 
    access_token text NOT NULL, 
    refresh_token text NOT NULL, 
    enctoken text DEFAULT NULL, 
    public_token varchar(191) DEFAULT NULL, 
    login_time timestamp(3) NOT NULL, 
    created_at timestamp(3) NOT NULL, 
    updated_at timestamp(3) NOT NULL, 
    session_status varchar(191) DEFAULT NULL, 
    email varchar(191) NOT NULL, 
    "userName" varchar(191) NOT NULL, 
    "avatarUrl" varchar(191) DEFAULT NULL, 
    is_tnc_accepted boolean NOT NULL, 
    last_fetched_at timestamp(3) DEFAULT NULL, 
    last_fetched_portfolio jsonb DEFAULT NULL,
    CONSTRAINT pk_zerodha PRIMARY KEY (id),
    CONSTRAINT fk_zerodha_user FOREIGN KEY (user_ref_id) REFERENCES "user"."user" (id) ON DELETE CASCADE
);

-- Table: zerodhatrade
CREATE TABLE "trade".zerodhatrade (
    id varchar(191) NOT NULL, 
    "zerodhaId" varchar(191) NOT NULL, 
    order_id varchar(191) NOT NULL, 
    trade_response jsonb NOT NULL, 
    "createdAt" timestamp(3) NOT NULL,
    CONSTRAINT pk_zerodhatrade PRIMARY KEY (id),
    CONSTRAINT fk_zerodhatrade_parent FOREIGN KEY ("zerodhaId") REFERENCES "trade".zerodha (id) ON DELETE CASCADE
);


-- ==========================================
-- 3. CREATE PERFORMANCE INDEXES
-- ==========================================
CREATE INDEX idx_adminnotification_email ON "ops".adminnotification(admin_email);
CREATE INDEX idx_adminsession_admin_id ON "ops".adminsession(admin_id);
CREATE INDEX idx_approvalrequest_status ON "ops".approvalrequest(status);
CREATE INDEX idx_audit_logs_entity ON "ops".audit_logs("entityType", "entityId");
CREATE INDEX idx_bankkyc_user_ref ON "kyc".bankkyc(user_ref);
CREATE INDEX idx_helpfaq_category ON "support".helpfaq("categoryId");
CREATE INDEX idx_helpvideo_category ON "content".helpvideo("categoryId");
CREATE INDEX idx_inventory_user ON "trade".inventory(user_id);
CREATE INDEX idx_kyc_user ON "kyc".kyc("userId");
CREATE INDEX idx_kyc_user_on_hold_user ON "kyc".kyc_user_on_hold(user_id);
CREATE INDEX idx_media_user_ref ON "content".media(user_ref_id);
CREATE INDEX idx_historicaldata_key ON "trade".historicaldata(key);
CREATE INDEX idx_mf_portfolio_milestones_user ON "trade".mf_portfolio_milestones(user_id);
CREATE INDEX idx_nse_mf_mandate_user ON "trade".nse_mf_mandate(user_ref_id);
CREATE INDEX idx_nse_mf_onboarding_user ON "trade".nse_mf_onboarding(user_ref_id);
CREATE INDEX idx_nse_mf_order_user ON "trade".nse_mf_order(user_ref_id);
CREATE INDEX idx_nse_mf_ucc_user ON "trade".nse_mf_ucc(user_ref_id);
CREATE INDEX idx_operations_user_email ON "ops".operations_user(email);
CREATE INDEX idx_partner_client_partner_id ON "referral".partner_client(partner_id);
CREATE INDEX idx_partner_client_linked_user ON "referral".partner_client(linked_user_id);
CREATE INDEX idx_partner_commission_cfg_partner ON "referral".partner_commission_config(partner_id);
CREATE INDEX idx_partner_comm_ledger_partner_client ON "referral".partner_commission_ledger(partner_id, client_id);
CREATE INDEX idx_partner_invoice_number ON "referral".partner_invoice(invoice_number);
CREATE INDEX idx_partner_invoice_partner ON "referral".partner_invoice(partner_id);
CREATE INDEX idx_partner_lead_partner ON "referral".partner_lead(partner_id);
CREATE INDEX idx_partner_points_balance_user ON "referral".partner_points_balance(user_id);
CREATE INDEX idx_partner_points_config_user ON "referral".partner_points_config(user_id);
CREATE INDEX idx_partner_pts_ledger_beneficiary ON "referral".partner_points_ledger(beneficiary_user_id);
CREATE INDEX idx_partner_user_email ON "referral".partner_user(email);
CREATE INDEX idx_partner_user_mobile ON "referral".partner_user(mobile);
CREATE INDEX idx_portfolio_user ON "trade".portfolio(user_id);
CREATE INDEX idx_promo_code_lookup ON "catalog".promo_code(code);
CREATE INDEX idx_promo_code_use_user ON "catalog".promo_code_use(user_id);
CREATE INDEX idx_referral_lookup_code ON "referral".referral(referal_code);
CREATE INDEX idx_referral_hierarchy_user ON "referral".referral_hierarchy(user_id);
CREATE INDEX idx_refreshtoken_hash ON "user".refreshtoken("tokenHash");
CREATE INDEX idx_refreshtoken_user ON "user".refreshtoken("userId");
CREATE INDEX idx_registerstagging_email_phone ON "user".registerstagging(email, phone_number);
CREATE INDEX idx_riskprofileanswer_question ON "catalog".riskprofileanswer(question_id);
CREATE INDEX idx_sub_coming_soon_sub ON "catalog".subscription_coming_soon_features("subscriptionId");
CREATE INDEX idx_sub_features_sub ON "catalog".subscription_features("subscriptionId");
CREATE INDEX idx_subscriptionfeature_user ON "catalog".subscriptionfeature(user_ref_id);
CREATE INDEX idx_sub_transaction_user ON "payments".subscriptiontransaction(user_ref_id);
CREATE INDEX idx_sub_transaction_order ON "payments".subscriptiontransaction(order_id);
CREATE INDEX idx_sub_transaction_sub_id ON "payments".subscriptiontransaction(subscription_id);
CREATE INDEX idx_user_email ON "user"."user"(email);
CREATE INDEX idx_user_phone ON "user"."user"(phone_number);
CREATE INDEX idx_ticket_user ON "support".ticket("userId");
CREATE INDEX idx_ticket_number ON "support".ticket("ticketNumber");
CREATE INDEX idx_ticketcomment_ticket ON "support".ticketcomment("ticketId");
CREATE INDEX idx_ticketsubcategory_cat ON "support".ticketsubcategory("categoryId");
CREATE INDEX idx_transaction_user ON "trade"."transaction"(user_ref_id);
CREATE INDEX idx_transaction_symbol ON "trade"."transaction"(trading_symbol);
CREATE INDEX idx_userriskprofile_user ON "catalog".userriskprofile(user_id);
CREATE INDEX idx_usersubscription_user ON "payments".usersubscription(user_ref_id);
CREATE INDEX idx_wallet_user ON "payments".wallet(user_ref_id);
CREATE INDEX idx_wallettransaction_wallet ON "payments".wallettransaction("Wallet_id");
CREATE INDEX idx_watchlist_user ON "trade".watchlist(user_ref_id);
CREATE INDEX idx_watchlistdetail_parent ON "trade".watchlistdetail(watchlist_id);
CREATE INDEX idx_zerodha_user ON "trade".zerodha(user_ref_id);
CREATE INDEX idx_zerodhatrade_parent ON "trade".zerodhatrade("zerodhaId");
