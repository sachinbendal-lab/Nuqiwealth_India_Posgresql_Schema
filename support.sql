-- Schema-wise stored procedures
-- Source: Procedure\support\
-- File: support.sp_add_ticket_comment.sql
-- PROCEDURE: support.sp_add_ticket_comment
-- Function: addTicketComment
-- Prisma await: await prismaClient.ticketComment.create(...)
-- Purpose: Atomic PostgreSQL write for Operations / ticket comments.
-- Point: Operations / ticket comments
-- Used by: POST /operations/tickets/:id/comment
-- Parameters map directly to Prisma TicketComment.create data fields.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_ticket_id varchar; p_user_id varchar; p_message text; p_comment_by varchar;
--     p_comment_type varchar; p_is_internal boolean; p_attachment_keys text[] DEFAULT NULL; p_attachment_values
--     text[] DEFAULT NULL; p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: addTicketComment | Route / flow: POST
--     /operations/tickets/:id/comment | Replace or support: await prismaClient.ticketComment.create(...)
--   Full routes / trigger: POST /operations/tickets/:id/comment; POST /auth/tickets/:ticketId/comments - add
--     operations/user comments
--   Related .js file(s): server_trade/controllers/operations/tickets.controller.js;
--     server_trade/routes/operations/tickets.routes.js; server_trade/controllers/helpdesk/user.ticket.controller.js;
--     server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations / ticket comments
--   Reason: Atomic PostgreSQL write for Operations / ticket comments.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_add_ticket_comment(
    p_id varchar,
    p_ticket_id varchar,
    p_user_id varchar,
    p_message text,
    p_comment_by varchar,
    p_comment_type varchar,
    p_is_internal boolean,
    p_attachment_keys text[] DEFAULT NULL,
    p_attachment_values text[] DEFAULT NULL,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "support".ticketcomment (
        id, "ticketId", "userId", message, "commentBy", "commentType",
        "isInternal", attachments, "createdAt", "updatedAt"
    ) VALUES (
        p_id, p_ticket_id, p_user_id, p_message, p_comment_by, p_comment_type,
        p_is_internal,
        CASE WHEN p_attachment_keys IS NULL THEN NULL
             ELSE jsonb_build_array("integration".fn_jsonb_from_pairs(p_attachment_keys, p_attachment_values)) END,
        p_created_at, p_created_at
    );

    UPDATE "support".ticket
    SET "updatedAt" = CURRENT_TIMESTAMP
    WHERE id = p_ticket_id;
END;
$procedure$;

-- File: support.sp_assign_ticket.sql
-- PROCEDURE: support.sp_assign_ticket
-- Function: assignTicket
-- Prisma await: await prismaClient.ticket.update(...)
-- Purpose: Atomic PostgreSQL write for Operations / ticket assignment.
-- Point: Operations / ticket assignment
-- Used by: POST /operations/tickets/:id/assign
-- Prisma mapping: where.id plus assignedTo/status/firstResponseAt.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_assigned_to varchar; p_status varchar DEFAULT NULL; p_first_response_at timestamp
--     DEFAULT NULL
--   Code / route integration target: Code function: assignTicket | Route / flow: POST /operations/tickets/:id/assign
--     | Replace or support: await prismaClient.ticket.update(...)
--   Full routes / trigger: POST /operations/tickets/:id/assign - assign a ticket
--   Related .js file(s): server_trade/controllers/operations/tickets.controller.js;
--     server_trade/routes/operations/tickets.routes.js; server_trade/controllers/helpdesk/user.ticket.controller.js;
--     server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations / ticket assignment
--   Reason: Atomic PostgreSQL write for Operations / ticket assignment.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_assign_ticket(
    p_id varchar,
    p_assigned_to varchar,
    p_status varchar DEFAULT NULL,
    p_first_response_at timestamp DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "support".ticket
    SET "assignedTo" = p_assigned_to,
        status = COALESCE(p_status, status),
        "firstResponseAt" = COALESCE("firstResponseAt", p_first_response_at, CURRENT_TIMESTAMP),
        "updatedAt" = CURRENT_TIMESTAMP
    WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ticket not found: %', p_id;
    END IF;
END;
$procedure$;

-- File: support.sp_create_ticket.sql
-- PROCEDURE: support.sp_create_ticket
-- Function: createTicket
-- Prisma await: await prismaClient.ticket.create(...)
-- Purpose: Atomic PostgreSQL write for Operations/Helpdesk ticket creation.
-- Point: Operations/Helpdesk ticket creation
-- Used by: Controller/service flow createTicket() when replacing the matching Prisma write.
-- Replaces: prisma.ticket.create({ data }).
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_ticket_number varchar; p_user_id varchar; p_subject varchar; p_description text;
--     p_category_id varchar DEFAULT NULL; p_subcategory_id varchar DEFAULT NULL; p_priority text DEFAULT 'MEDIUM';
--     p_status varchar DEFAULT 'OPEN'; p_assigned_to varchar DEFAULT NULL; p_escalation_level integer DEFAULT 0;
--     p_attachment_keys text[] DEFAULT NULL; p_attachment_values text[] DEFAULT NULL; p_metadata_keys text[] DEFAULT
--     NULL; p_metadata_values text[] DEFAULT NULL; p_internal_status varchar DEFAULT NULL; p_created_at timestamp
--     DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: createTicket | Route / flow: Controller/service flow
--     createTicket() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.ticket.create(...)
--   Full routes / trigger: POST /auth/tickets - create a Helpdesk ticket
--   Related .js file(s): server_trade/controllers/helpdesk/user.ticket.controller.js;
--     server_trade/routes/helpdesk/user.helpdesk.routes.js;
--     server_trade/controllers/operations/tickets.controller.js; server_trade/routes/operations/tickets.routes.js
--   Integration point: Operations/Helpdesk ticket creation
--   Reason: Atomic PostgreSQL write for Operations/Helpdesk ticket creation.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_create_ticket(
    p_id varchar,
    p_ticket_number varchar,
    p_user_id varchar,
    p_subject varchar,
    p_description text,
    p_category_id varchar DEFAULT NULL,
    p_subcategory_id varchar DEFAULT NULL,
    p_priority text DEFAULT 'MEDIUM',
    p_status varchar DEFAULT 'OPEN',
    p_assigned_to varchar DEFAULT NULL,
    p_escalation_level integer DEFAULT 0,
    p_attachment_keys text[] DEFAULT NULL,
    p_attachment_values text[] DEFAULT NULL,
    p_metadata_keys text[] DEFAULT NULL,
    p_metadata_values text[] DEFAULT NULL,
    p_internal_status varchar DEFAULT NULL,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "support".ticket (
        id, "ticketNumber", "userId", "categoryId", "subcategoryId",
        subject, description, priority, status, "assignedTo",
        "escalationLevel", attachments, metadata, "createdAt", "updatedAt",
        "internalStatus"
    ) VALUES (
        p_id, p_ticket_number, p_user_id, p_category_id, p_subcategory_id,
        p_subject, p_description, p_priority::ticket_priority_enum, p_status,
        p_assigned_to, p_escalation_level,
        CASE WHEN p_attachment_keys IS NULL THEN NULL
             ELSE jsonb_build_array("integration".fn_jsonb_from_pairs(p_attachment_keys, p_attachment_values)) END,
        "integration".fn_jsonb_from_pairs(p_metadata_keys, p_metadata_values),
        p_created_at, p_created_at, p_internal_status
    );
END;
$procedure$;

-- File: support.sp_delete_help_category.sql
-- PROCEDURE: support.sp_delete_help_category
-- Function: deleteHelpCategory
-- Prisma await: await prismaClient.helpCategory.delete(...)
-- Purpose: Atomic PostgreSQL write for Operations Helpdesk category deletion.
-- Point: Operations Helpdesk category deletion
-- Used by: DELETE /operations/helpdesk/categories/:id
-- Related FAQs/videos retain their rows and have categoryId set to NULL.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar
--   Code / route integration target: Code function: deleteHelpCategory | Route / flow: DELETE
--     /operations/helpdesk/categories/:id | Replace or support: await prismaClient.helpCategory.delete(...)
--   Full routes / trigger: DELETE /operations/helpdesk/categories/:id - delete Helpdesk category
--   Related .js file(s): server_trade/controllers/operations/helpdesk.controller.js;
--     server_trade/routes/operations/helpdesk.routes.js;
--     server_trade/controllers/helpdesk/public.helpdesk.controller.js;
--     server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations Helpdesk category deletion
--   Reason: Atomic PostgreSQL write for Operations Helpdesk category deletion.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_delete_help_category(
    p_id varchar
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    DELETE FROM "support".helpcategory WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Help category not found: %', p_id; END IF;
END;
$procedure$;

-- File: support.sp_delete_help_faq.sql
-- PROCEDURE: support.sp_delete_help_faq
-- Function: deleteHelpFaq
-- Prisma await: await prismaClient.helpFAQ.delete(...)
-- Purpose: Atomic PostgreSQL write for Operations Helpdesk FAQ deletion.
-- Point: Operations Helpdesk FAQ deletion
-- Used by: DELETE /operations/helpdesk/faqs/:id
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar
--   Code / route integration target: Code function: deleteHelpFaq | Route / flow: DELETE
--     /operations/helpdesk/faqs/:id | Replace or support: await prismaClient.helpFAQ.delete(...)
--   Full routes / trigger: DELETE /operations/helpdesk/faqs/:id - delete FAQ
--   Related .js file(s): server_trade/controllers/operations/helpdesk.controller.js;
--     server_trade/controllers/helpdesk/public.helpdesk.controller.js;
--     server_trade/routes/operations/helpdesk.routes.js; server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations Helpdesk FAQ deletion
--   Reason: Atomic PostgreSQL write for Operations Helpdesk FAQ deletion.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_delete_help_faq(
    p_id varchar
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    DELETE FROM "support".helpfaq WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Help FAQ not found: %', p_id; END IF;
END;
$procedure$;

-- File: support.sp_delete_ticket_config.sql
-- PROCEDURE: support.sp_delete_ticket_config
-- Function: deleteTicketConfig
-- Prisma await: await prismaClient.ticketCategoryConfig/ticketSubcategory/ticketAssignee/ticketStatusConfig/ticketPriorityConfig.delete(...)
-- Purpose: Atomic PostgreSQL write for Operations ticket configuration deletes.
-- Point: Operations ticket configuration deletes
-- Used by: Controller/service flow deleteTicketConfig() when replacing the matching Prisma write.
-- p_config_type: CATEGORY, SUBCATEGORY, ASSIGNEE, STATUS, or PRIORITY.
-- Mirrors the existing delete endpoints while keeping identifiers parameterized.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_config_type varchar; p_id varchar
--   Code / route integration target: Code function: deleteTicketConfig | Route / flow: Controller/service flow
--     deleteTicketConfig() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.ticketCategoryConfig/ticketSubcategory/ticketAssignee/ticketStatusConfig/ticketPriorityConfig.delete(...)
--   Full routes / trigger: DELETE /operations/ticket-config/categories/:id; DELETE
--     /operations/ticket-config/subcategories/:id; DELETE /operations/ticket-config/assignees/:id; DELETE
--     /operations/ticket-config/statuses/:id; DELETE /operations/ticket-config/priorities/:id - delete the selected
--     config type
--   Related .js file(s): server_trade/controllers/operations/ticketConfig.controller.js;
--     server_trade/routes/operations/ticketConfig.routes.js
--   Integration point: Operations ticket configuration deletes
--   Reason: Atomic PostgreSQL write for Operations ticket configuration deletes.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_delete_ticket_config(
    p_config_type varchar,
    p_id varchar
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    CASE UPPER(p_config_type)
        WHEN 'CATEGORY' THEN DELETE FROM "support".ticketcategoryconfig WHERE id = p_id;
        WHEN 'SUBCATEGORY' THEN DELETE FROM "support".ticketsubcategory WHERE id = p_id;
        WHEN 'ASSIGNEE' THEN DELETE FROM "support".ticketassignee WHERE id = p_id;
        WHEN 'STATUS' THEN DELETE FROM "support".ticketstatusconfig WHERE id = p_id;
        WHEN 'PRIORITY' THEN DELETE FROM "support".ticketpriorityconfig WHERE id = p_id;
        ELSE RAISE EXCEPTION 'Unsupported ticket config type: %', p_config_type;
    END CASE;
END;
$procedure$;

-- File: support.sp_update_ticket_priority_and_rating.sql
-- PROCEDURE: support.sp_update_ticket_priority_and_rating
-- Function: updateTicketPriorityAndRating
-- Prisma await: await prismaClient.ticket.update(...)
-- Purpose: Atomic PostgreSQL write for Operations ticket priority and customer feedback.
-- Point: Operations ticket priority and customer feedback
-- Used by: Controller/service flow updateTicketPriorityAndRating() when replacing the matching Prisma write.
-- Replaces the corresponding ticket.update() calls.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_priority text DEFAULT NULL; p_rating integer DEFAULT NULL; p_rating_feedback text
--     DEFAULT NULL; p_rated_at timestamp DEFAULT NULL
--   Code / route integration target: Code function: updateTicketPriorityAndRating | Route / flow: Controller/service
--     flow updateTicketPriorityAndRating() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.ticket.update(...)
--   Full routes / trigger: PUT /operations/tickets/:id/priority; POST /auth/tickets/:ticketId/rate - update priority
--     or customer rating
--   Related .js file(s): server_trade/controllers/operations/tickets.controller.js;
--     server_trade/controllers/helpdesk/user.ticket.controller.js; server_trade/routes/operations/tickets.routes.js;
--     server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations ticket priority and customer feedback
--   Reason: Atomic PostgreSQL write for Operations ticket priority and customer feedback.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_update_ticket_priority_and_rating(
    p_id varchar,
    p_priority text DEFAULT NULL,
    p_rating integer DEFAULT NULL,
    p_rating_feedback text DEFAULT NULL,
    p_rated_at timestamp DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_rating IS NOT NULL AND (p_rating < 1 OR p_rating > 5) THEN
        RAISE EXCEPTION 'rating must be between 1 and 5';
    END IF;

    UPDATE "support".ticket
    SET priority = COALESCE(p_priority::ticket_priority_enum, priority),
        rating = COALESCE(p_rating, rating),
        "ratingFeedback" = COALESCE(p_rating_feedback, "ratingFeedback"),
        "ratedAt" = COALESCE(p_rated_at, "ratedAt"),
        "updatedAt" = CURRENT_TIMESTAMP
    WHERE id = p_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'Ticket not found: %', p_id; END IF;
END;
$procedure$;

-- File: support.sp_update_ticket_status.sql
-- PROCEDURE: support.sp_update_ticket_status
-- Function: updateTicketStatus
-- Prisma await: await prismaClient.ticket.update(...)
-- Purpose: Atomic PostgreSQL write for Operations / ticket workflow.
-- Point: Operations / ticket workflow
-- Used by: PUT /operations/tickets/:id/status
-- Prisma mapping: where.id plus status, internalStatus, resolution and timestamps.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_status varchar; p_internal_status varchar DEFAULT NULL; p_resolution text DEFAULT
--     NULL; p_resolved_at timestamp DEFAULT NULL; p_closed_at timestamp DEFAULT NULL
--   Code / route integration target: Code function: updateTicketStatus | Route / flow: PUT
--     /operations/tickets/:id/status | Replace or support: await prismaClient.ticket.update(...)
--   Full routes / trigger: PUT /operations/tickets/:id/status - change workflow status
--   Related .js file(s): server_trade/controllers/operations/ticketConfig.controller.js;
--     server_trade/controllers/operations/tickets.controller.js;
--     server_trade/routes/operations/ticketConfig.routes.js; server_trade/routes/operations/tickets.routes.js;
--     server_trade/controllers/helpdesk/user.ticket.controller.js;
--     server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations / ticket workflow
--   Reason: Atomic PostgreSQL write for Operations / ticket workflow.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_update_ticket_status(
    p_id varchar,
    p_status varchar,
    p_internal_status varchar DEFAULT NULL,
    p_resolution text DEFAULT NULL,
    p_resolved_at timestamp DEFAULT NULL,
    p_closed_at timestamp DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "support".ticket
    SET status = p_status,
        "internalStatus" = COALESCE(p_internal_status, "internalStatus"),
        resolution = COALESCE(p_resolution, resolution),
        "resolvedAt" = COALESCE(p_resolved_at, "resolvedAt"),
        "closedAt" = COALESCE(p_closed_at, "closedAt"),
        "updatedAt" = CURRENT_TIMESTAMP
    WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ticket not found: %', p_id;
    END IF;
END;
$procedure$;

-- File: support.sp_upsert_help_category.sql
-- PROCEDURE: support.sp_upsert_help_category
-- Function: upsertHelpCategory
-- Prisma await: await prismaClient.helpCategory.create/update(...)
-- Purpose: Atomic PostgreSQL write for Operations Helpdesk category create/update.
-- Point: Operations Helpdesk category create/update
-- Used by: POST/PUT /operations/helpdesk/categories[/:id]
-- Parameters map to Prisma HelpCategory fields.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_title varchar; p_description text DEFAULT NULL; p_icon varchar DEFAULT NULL;
--     p_sort_order integer DEFAULT 0; p_is_active boolean DEFAULT true; p_created_at timestamp DEFAULT
--     CURRENT_TIMESTAMP
--   Code / route integration target: Code function: upsertHelpCategory | Route / flow: POST/PUT
--     /operations/helpdesk/categories[/:id] | Replace or support: await prismaClient.helpCategory.create/update(...)
--   Full routes / trigger: POST /operations/helpdesk/categories; PUT /operations/helpdesk/categories/:id -
--     create/update Helpdesk category
--   Related .js file(s): server_trade/controllers/operations/helpdesk.controller.js;
--     server_trade/controllers/helpdesk/public.helpdesk.controller.js;
--     server_trade/routes/operations/helpdesk.routes.js; server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations Helpdesk category create/update
--   Reason: Atomic PostgreSQL write for Operations Helpdesk category create/update.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_upsert_help_category(
    p_id varchar,
    p_title varchar,
    p_description text DEFAULT NULL,
    p_icon varchar DEFAULT NULL,
    p_sort_order integer DEFAULT 0,
    p_is_active boolean DEFAULT true,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id varchar := COALESCE(NULLIF(p_id, ''), gen_random_uuid()::text);
BEGIN
    IF NULLIF(BTRIM(p_title), '') IS NULL THEN
        RAISE EXCEPTION 'Help category title is required';
    END IF;

    INSERT INTO "support".helpcategory (
        id, title, description, icon, "sortOrder", "isActive",
        "createdAt", "updatedAt"
    ) VALUES (
        v_id, BTRIM(p_title), p_description, p_icon, p_sort_order, p_is_active,
        p_created_at, p_created_at
    )
    ON CONFLICT (id) DO UPDATE SET
        title = EXCLUDED.title,
        description = EXCLUDED.description,
        icon = EXCLUDED.icon,
        "sortOrder" = EXCLUDED."sortOrder",
        "isActive" = EXCLUDED."isActive",
        "updatedAt" = CURRENT_TIMESTAMP;
END;
$procedure$;

-- File: support.sp_upsert_help_faq.sql
-- PROCEDURE: support.sp_upsert_help_faq
-- Function: upsertHelpFaq
-- Prisma await: await prismaClient.helpFAQ.create/update(...)
-- Purpose: Atomic PostgreSQL write for Operations Helpdesk FAQ create/update.
-- Point: Operations Helpdesk FAQ create/update
-- Used by: POST/PUT /operations/helpdesk/faqs[/:id]
-- Parameters map to Prisma HelpFAQ fields.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_question varchar; p_answer text; p_category_id varchar DEFAULT NULL; p_video_id
--     varchar DEFAULT NULL; p_sort_order integer DEFAULT 0; p_is_active boolean DEFAULT true; p_created_at timestamp
--     DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: upsertHelpFaq | Route / flow: POST/PUT
--     /operations/helpdesk/faqs[/:id] | Replace or support: await prismaClient.helpFAQ.create/update(...)
--   Full routes / trigger: POST /operations/helpdesk/faqs; PUT /operations/helpdesk/faqs/:id - create/update FAQ
--   Related .js file(s): server_trade/controllers/operations/helpdesk.controller.js;
--     server_trade/controllers/helpdesk/public.helpdesk.controller.js;
--     server_trade/routes/operations/helpdesk.routes.js; server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations Helpdesk FAQ create/update
--   Reason: Atomic PostgreSQL write for Operations Helpdesk FAQ create/update.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_upsert_help_faq(
    p_id varchar,
    p_question varchar,
    p_answer text,
    p_category_id varchar DEFAULT NULL,
    p_video_id varchar DEFAULT NULL,
    p_sort_order integer DEFAULT 0,
    p_is_active boolean DEFAULT true,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id varchar := COALESCE(NULLIF(p_id, ''), gen_random_uuid()::text);
BEGIN
    IF NULLIF(BTRIM(p_question), '') IS NULL OR NULLIF(BTRIM(p_answer), '') IS NULL THEN
        RAISE EXCEPTION 'FAQ question and answer are required';
    END IF;

    INSERT INTO "support".helpfaq (
        id, question, answer, "categoryId", "videoId", "sortOrder",
        "isActive", "createdAt", "updatedAt"
    ) VALUES (
        v_id, BTRIM(p_question), p_answer, p_category_id, p_video_id,
        p_sort_order, p_is_active, p_created_at, p_created_at
    )
    ON CONFLICT (id) DO UPDATE SET
        question = EXCLUDED.question,
        answer = EXCLUDED.answer,
        "categoryId" = EXCLUDED."categoryId",
        "videoId" = EXCLUDED."videoId",
        "sortOrder" = EXCLUDED."sortOrder",
        "isActive" = EXCLUDED."isActive",
        "updatedAt" = CURRENT_TIMESTAMP;
END;
$procedure$;

-- File: support.sp_upsert_ticket_assignee.sql
-- PROCEDURE: support.sp_upsert_ticket_assignee
-- Function: upsertTicketAssignee
-- Prisma await: await prismaClient.ticketAssignee.upsert(...)
-- Purpose: Atomic PostgreSQL write for Operations ticket configuration / assignees.
-- Point: Operations ticket configuration / assignees
-- Used by: Controller/service flow upsertTicketAssignee() when replacing the matching Prisma write.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_name varchar; p_email varchar; p_role varchar DEFAULT NULL; p_department varchar
--     DEFAULT NULL; p_sort_order integer DEFAULT 0; p_is_active boolean DEFAULT true; p_password varchar DEFAULT NULL
--   Code / route integration target: Code function: upsertTicketAssignee | Route / flow: Controller/service flow
--     upsertTicketAssignee() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.ticketAssignee.upsert(...)
--   Full routes / trigger: POST /operations/ticket-config/assignees; PUT /operations/ticket-config/assignees/:id -
--     create/update assignee config
--   Related .js file(s): server_trade/controllers/operations/ticketConfig.controller.js;
--     server_trade/routes/operations/ticketConfig.routes.js
--   Integration point: Operations ticket configuration / assignees
--   Reason: Atomic PostgreSQL write for Operations ticket configuration / assignees.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_upsert_ticket_assignee(
    p_id varchar,
    p_name varchar,
    p_email varchar,
    p_role varchar DEFAULT NULL,
    p_department varchar DEFAULT NULL,
    p_sort_order integer DEFAULT 0,
    p_is_active boolean DEFAULT true,
    p_password varchar DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "support".ticketassignee (
        id, name, email, role, department, "sortOrder", "isActive",
        "createdAt", "updatedAt", password
    ) VALUES (
        p_id, p_name, p_email, p_role, p_department, p_sort_order,
        p_is_active, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, p_password
    )
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name, email = EXCLUDED.email, role = EXCLUDED.role,
        department = EXCLUDED.department, "sortOrder" = EXCLUDED."sortOrder",
        "isActive" = EXCLUDED."isActive",
        password = COALESCE(EXCLUDED.password, ticketassignee.password),
        "updatedAt" = CURRENT_TIMESTAMP;
END;
$procedure$;

-- File: support.sp_upsert_ticket_category.sql
-- PROCEDURE: support.sp_upsert_ticket_category
-- Function: upsertTicketCategory
-- Prisma await: await prismaClient.ticketCategoryConfig.upsert(...)
-- Purpose: Atomic PostgreSQL write for Operations ticket configuration / categories.
-- Point: Operations ticket configuration / categories
-- Used by: Controller/service flow upsertTicketCategory() when replacing the matching Prisma write.
-- Replaces category create and update calls; p_id is the Prisma-generated cuid.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_name varchar; p_description text DEFAULT NULL; p_icon varchar DEFAULT NULL;
--     p_attachment_required boolean DEFAULT false; p_sort_order integer DEFAULT 0; p_is_active boolean DEFAULT true
--   Code / route integration target: Code function: upsertTicketCategory | Route / flow: Controller/service flow
--     upsertTicketCategory() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.ticketCategoryConfig.upsert(...)
--   Full routes / trigger: POST /operations/ticket-config/categories; PUT /operations/ticket-config/categories/:id -
--     create/update category config
--   Related .js file(s): server_trade/controllers/operations/ticketConfig.controller.js;
--     server_trade/routes/operations/ticketConfig.routes.js
--   Integration point: Operations ticket configuration / categories
--   Reason: Atomic PostgreSQL write for Operations ticket configuration / categories.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_upsert_ticket_category(
    p_id varchar,
    p_name varchar,
    p_description text DEFAULT NULL,
    p_icon varchar DEFAULT NULL,
    p_attachment_required boolean DEFAULT false,
    p_sort_order integer DEFAULT 0,
    p_is_active boolean DEFAULT true
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "support".ticketcategoryconfig (
        id, name, description, icon, "attachmentRequired", "sortOrder",
        "isActive", "createdAt", "updatedAt"
    ) VALUES (
        p_id, p_name, p_description, p_icon, p_attachment_required,
        p_sort_order, p_is_active, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    )
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name, description = EXCLUDED.description,
        icon = EXCLUDED.icon, "attachmentRequired" = EXCLUDED."attachmentRequired",
        "sortOrder" = EXCLUDED."sortOrder", "isActive" = EXCLUDED."isActive",
        "updatedAt" = CURRENT_TIMESTAMP;
END;
$procedure$;

-- File: support.sp_upsert_ticket_priority_config.sql
-- PROCEDURE: support.sp_upsert_ticket_priority_config
-- Function: upsertTicketPriorityConfig
-- Prisma await: await prismaClient.ticketPriorityConfig.upsert(...)
-- Purpose: Atomic PostgreSQL write for Operations ticket configuration / priorities.
-- Point: Operations ticket configuration / priorities
-- Used by: Controller/service flow upsertTicketPriorityConfig() when replacing the matching Prisma write.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_name varchar; p_label varchar; p_color varchar; p_bg_color varchar; p_description
--     text DEFAULT NULL; p_sort_order integer DEFAULT 0; p_is_default boolean DEFAULT false; p_is_active boolean
--     DEFAULT true
--   Code / route integration target: Code function: upsertTicketPriorityConfig | Route / flow: Controller/service
--     flow upsertTicketPriorityConfig() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.ticketPriorityConfig.upsert(...)
--   Full routes / trigger: POST /operations/ticket-config/priorities; PUT /operations/ticket-config/priorities/:id -
--     create/update priority config
--   Related .js file(s): server_trade/controllers/operations/ticketConfig.controller.js;
--     server_trade/routes/operations/ticketConfig.routes.js
--   Integration point: Operations ticket configuration / priorities
--   Reason: Atomic PostgreSQL write for Operations ticket configuration / priorities.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_upsert_ticket_priority_config(
    p_id varchar,
    p_name varchar,
    p_label varchar,
    p_color varchar,
    p_bg_color varchar,
    p_description text DEFAULT NULL,
    p_sort_order integer DEFAULT 0,
    p_is_default boolean DEFAULT false,
    p_is_active boolean DEFAULT true
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "support".ticketpriorityconfig (
        id, name, label, description, color, "bgColor", "sortOrder",
        "isDefault", "isActive", "createdAt", "updatedAt"
    ) VALUES (
        p_id, p_name, p_label, p_description, p_color, p_bg_color,
        p_sort_order, p_is_default, p_is_active, CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name, label = EXCLUDED.label,
        description = EXCLUDED.description, color = EXCLUDED.color,
        "bgColor" = EXCLUDED."bgColor", "sortOrder" = EXCLUDED."sortOrder",
        "isDefault" = EXCLUDED."isDefault", "isActive" = EXCLUDED."isActive",
        "updatedAt" = CURRENT_TIMESTAMP;
END;
$procedure$;

-- File: support.sp_upsert_ticket_status_config.sql
-- PROCEDURE: support.sp_upsert_ticket_status_config
-- Function: upsertTicketStatusConfig
-- Prisma await: await prismaClient.ticketStatusConfig.upsert(...)
-- Purpose: Atomic PostgreSQL write for Operations ticket configuration / statuses.
-- Point: Operations ticket configuration / statuses
-- Used by: Controller/service flow upsertTicketStatusConfig() when replacing the matching Prisma write.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_name varchar; p_label varchar; p_color varchar; p_bg_color varchar; p_description
--     text DEFAULT NULL; p_icon varchar DEFAULT NULL; p_status_type varchar DEFAULT 'USER'; p_sort_order integer
--     DEFAULT 0; p_is_default boolean DEFAULT false; p_is_final boolean DEFAULT false; p_is_active boolean DEFAULT
--     true
--   Code / route integration target: Code function: upsertTicketStatusConfig | Route / flow: Controller/service flow
--     upsertTicketStatusConfig() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.ticketStatusConfig.upsert(...)
--   Full routes / trigger: POST /operations/ticket-config/statuses; PUT /operations/ticket-config/statuses/:id -
--     create/update status config
--   Related .js file(s): server_trade/controllers/operations/tickets.controller.js;
--     server_trade/controllers/helpdesk/user.ticket.controller.js; server_trade/routes/operations/tickets.routes.js;
--     server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations ticket configuration / statuses
--   Reason: Atomic PostgreSQL write for Operations ticket configuration / statuses.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_upsert_ticket_status_config(
    p_id varchar,
    p_name varchar,
    p_label varchar,
    p_color varchar,
    p_bg_color varchar,
    p_description text DEFAULT NULL,
    p_icon varchar DEFAULT NULL,
    p_status_type varchar DEFAULT 'USER',
    p_sort_order integer DEFAULT 0,
    p_is_default boolean DEFAULT false,
    p_is_final boolean DEFAULT false,
    p_is_active boolean DEFAULT true
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "support".ticketstatusconfig (
        id, name, label, description, color, "bgColor", icon, "statusType",
        "sortOrder", "isDefault", "isFinal", "isActive", "createdAt", "updatedAt"
    ) VALUES (
        p_id, p_name, p_label, p_description, p_color, p_bg_color, p_icon,
        p_status_type, p_sort_order, p_is_default, p_is_final, p_is_active,
        CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    )
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name, label = EXCLUDED.label,
        description = EXCLUDED.description, color = EXCLUDED.color,
        "bgColor" = EXCLUDED."bgColor", icon = EXCLUDED.icon,
        "statusType" = EXCLUDED."statusType", "sortOrder" = EXCLUDED."sortOrder",
        "isDefault" = EXCLUDED."isDefault", "isFinal" = EXCLUDED."isFinal",
        "isActive" = EXCLUDED."isActive", "updatedAt" = CURRENT_TIMESTAMP;
END;
$procedure$;

-- File: support.sp_upsert_ticket_subcategory.sql
-- PROCEDURE: support.sp_upsert_ticket_subcategory
-- Function: upsertTicketSubcategory
-- Prisma await: await prismaClient.ticketSubcategory.upsert(...)
-- Purpose: Atomic PostgreSQL write for Operations ticket configuration / subcategories.
-- Point: Operations ticket configuration / subcategories
-- Used by: Controller/service flow upsertTicketSubcategory() when replacing the matching Prisma write.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_category_id varchar; p_name varchar; p_description text DEFAULT NULL;
--     p_attachment_required boolean DEFAULT NULL; p_sort_order integer DEFAULT 0; p_is_active boolean DEFAULT true
--   Code / route integration target: Code function: upsertTicketSubcategory | Route / flow: Controller/service flow
--     upsertTicketSubcategory() when replacing the matching Prisma write. | Replace or support: await
--     prismaClient.ticketSubcategory.upsert(...)
--   Full routes / trigger: POST /operations/ticket-config/subcategories; PUT
--     /operations/ticket-config/subcategories/:id - create/update subcategory config
--   Related .js file(s): server_trade/controllers/operations/ticketConfig.controller.js;
--     server_trade/routes/operations/ticketConfig.routes.js
--   Integration point: Operations ticket configuration / subcategories
--   Reason: Atomic PostgreSQL write for Operations ticket configuration / subcategories.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "support".sp_upsert_ticket_subcategory(
    p_id varchar,
    p_category_id varchar,
    p_name varchar,
    p_description text DEFAULT NULL,
    p_attachment_required boolean DEFAULT NULL,
    p_sort_order integer DEFAULT 0,
    p_is_active boolean DEFAULT true
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    INSERT INTO "support".ticketsubcategory (
        id, "categoryId", name, description, "attachmentRequired",
        "sortOrder", "isActive", "createdAt", "updatedAt"
    ) VALUES (
        p_id, p_category_id, p_name, p_description, p_attachment_required,
        p_sort_order, p_is_active, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    )
    ON CONFLICT (id) DO UPDATE SET
        "categoryId" = EXCLUDED."categoryId", name = EXCLUDED.name,
        description = EXCLUDED.description,
        "attachmentRequired" = EXCLUDED."attachmentRequired",
        "sortOrder" = EXCLUDED."sortOrder", "isActive" = EXCLUDED."isActive",
        "updatedAt" = CURRENT_TIMESTAMP;
END;
$procedure$;



-- Functions integrated from all_final_function_mandar.sql
-- FUNCTION: support.fn_get_help_categories
-- Function: getHelpCategories
-- Prisma await: await prismaClient.helpCategory.findMany({ include: { _count: true } })
-- Purpose: PostgreSQL read/calculation for Operations and public Helpdesk categories.
-- Point: Operations and public Helpdesk categories
-- Used by: GET /operations/helpdesk/categories and GET /helpdesk/categories.
-- Parameters:
--   p_is_active = Prisma HelpCategory.isActive; NULL includes all rows.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_is_active boolean DEFAULT NULL
--   Code / route integration target: Code function: getHelpCategories | Route / flow: GET
--     /operations/helpdesk/categories and GET /helpdesk/categories. | Replace or support: await
--     prismaClient.helpCategory.findMany({ include: { _count: true } })
--   Full routes / trigger: GET /operations/helpdesk/categories; GET /operations/helpdesk/categories/:id; GET
--     /auth/helpdesk/categories; GET /auth/helpdesk/categories/:id - list category data
--   Related .js file(s): server_trade/routes/operations/helpdesk.routes.js;
--     server_trade/controllers/operations/helpdesk.controller.js
--   Integration point: Operations and public Helpdesk categories
--   Reason: PostgreSQL read/calculation for Operations and public Helpdesk categories.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "support".fn_get_help_categories(
    p_is_active boolean DEFAULT NULL
)
RETURNS TABLE (
    id varchar,
    title varchar,
    description text,
    icon varchar,
    sort_order integer,
    is_active boolean,
    created_at timestamp,
    updated_at timestamp,
    active_faq_count bigint,
    active_video_count bigint
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        c.id,
        c.title,
        c.description,
        c.icon,
        c."sortOrder",
        c."isActive",
        c."createdAt",
        c."updatedAt",
        COUNT(DISTINCT f.id) FILTER (WHERE f."isActive") AS active_faq_count,
        COUNT(DISTINCT v.id) FILTER (WHERE v."isActive") AS active_video_count
    FROM "support".helpcategory c
    LEFT JOIN "support".helpfaq f ON f."categoryId" = c.id
    LEFT JOIN "content".helpvideo v ON v."categoryId" = c.id
    WHERE p_is_active IS NULL OR c."isActive" = p_is_active
    GROUP BY
        c.id, c.title, c.description, c.icon, c."sortOrder",
        c."isActive", c."createdAt", c."updatedAt"
    ORDER BY c."sortOrder", c.title;
$function$;

-- FUNCTION: support.fn_get_help_faqs
-- Function: getHelpFaqs
-- Prisma await: await prismaClient.helpFAQ.findMany({ include: { category: true, video: true } })
-- Purpose: PostgreSQL read/calculation for Operations and public Helpdesk FAQ listing/search.
-- Point: Operations and public Helpdesk FAQ listing/search
-- Used by: Helpdesk FAQ list, category detail, and public search routes.
-- Parameters mirror Prisma filters: categoryId, isActive, search, and take.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_category_id varchar DEFAULT NULL; p_is_active boolean DEFAULT NULL; p_search varchar DEFAULT NULL;
--     p_limit integer DEFAULT NULL
--   Code / route integration target: Code function: getHelpFaqs | Route / flow: Helpdesk FAQ list, category detail,
--     and public search routes. | Replace or support: await prismaClient.helpFAQ.findMany({ include: { category:
--     true, video: true } })
--   Full routes / trigger: GET /operations/helpdesk/faqs; GET /operations/helpdesk/faqs/:id; GET /auth/helpdesk/faqs;
--     GET /auth/helpdesk/faqs/search; GET /auth/helpdesk/faqs/:id - list/search FAQ data
--   Related .js file(s): server_trade/controllers/operations/helpdesk.controller.js;
--     server_trade/controllers/helpdesk/public.helpdesk.controller.js;
--     server_trade/routes/operations/helpdesk.routes.js; server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations and public Helpdesk FAQ listing/search
--   Reason: PostgreSQL read/calculation for Operations and public Helpdesk FAQ listing/search.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "support".fn_get_help_faqs(
    p_category_id varchar DEFAULT NULL,
    p_is_active boolean DEFAULT NULL,
    p_search varchar DEFAULT NULL,
    p_limit integer DEFAULT NULL
)
RETURNS TABLE (
    id varchar,
    question varchar,
    answer text,
    category_id varchar,
    video_id varchar,
    sort_order integer,
    is_active boolean,
    created_at timestamp,
    updated_at timestamp,
    category_title varchar,
    category_icon varchar,
    video_title varchar,
    video_url varchar,
    video_thumbnail_url varchar
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        f.id,
        f.question,
        f.answer,
        f."categoryId",
        f."videoId",
        f."sortOrder",
        f."isActive",
        f."createdAt",
        f."updatedAt",
        c.title,
        c.icon,
        v.title,
        v.url,
        v."thumbnailUrl"
    FROM "support".helpfaq f
    LEFT JOIN "support".helpcategory c ON c.id = f."categoryId"
    LEFT JOIN "content".helpvideo v ON v.id = f."videoId"
    WHERE (p_category_id IS NULL OR f."categoryId" = p_category_id)
      AND (p_is_active IS NULL OR f."isActive" = p_is_active)
      AND (
          NULLIF(BTRIM(p_search), '') IS NULL
          OR f.question ILIKE '%' || BTRIM(p_search) || '%'
          OR f.answer ILIKE '%' || BTRIM(p_search) || '%'
      )
    ORDER BY f."sortOrder", f."createdAt" DESC
    LIMIT COALESCE(p_limit, 2147483647);
$function$;
