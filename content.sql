-- Schema-wise stored procedures
-- Source: Procedure\content\

-- File: content.sp_delete_help_video.sql
-- PROCEDURE: content.sp_delete_help_video
-- Function: deleteHelpVideo
-- Prisma await: await prismaClient.helpVideo.delete(...)
-- Purpose: Atomic PostgreSQL write for Operations Helpdesk video metadata deletion.
-- Point: Operations Helpdesk video metadata deletion
-- Used by: DELETE /operations/helpdesk/videos/:id
-- Physical media-file cleanup remains in Node.js.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar
--   Code / route integration target: Code function: deleteHelpVideo | Route / flow: DELETE
--     /operations/helpdesk/videos/:id | Replace or support: await prismaClient.helpVideo.delete(...)
--   Full routes / trigger: DELETE /operations/helpdesk/videos/:id - delete video metadata
--   Related .js file(s): server_trade/controllers/operations/helpdesk.controller.js;
--     server_trade/routes/operations/helpdesk.routes.js;
--     server_trade/controllers/helpdesk/public.helpdesk.controller.js;
--     server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations Helpdesk video metadata deletion
--   Reason: Atomic PostgreSQL write for Operations Helpdesk video metadata deletion.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "content".sp_delete_help_video(
    p_id varchar
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    DELETE FROM "content".helpvideo WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Help video not found: %', p_id; END IF;
END;
$procedure$;

-- File: content.sp_increment_help_video_view.sql
-- PROCEDURE: content.sp_increment_help_video_view
-- Function: incrementHelpVideoView
-- Prisma await: await prismaClient.helpVideo.update({ data: { viewCount: { increment: 1 } } })
-- Purpose: Atomic PostgreSQL write for Public Helpdesk video view counter.
-- Point: Public Helpdesk video view counter
-- Used by: GET /helpdesk/videos/:id
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar
--   Code / route integration target: Code function: incrementHelpVideoView | Route / flow: GET /helpdesk/videos/:id |
--     Replace or support: await prismaClient.helpVideo.update({ data: { viewCount: { increment: 1 } } })
--   Full routes / trigger: GET /auth/helpdesk/videos/:id - increment the public video view count
--   Related .js file(s): server_trade/routes/helpdesk/user.helpdesk.routes.js;
--     server_trade/routes/operations/helpdesk.routes.js; server_trade/controllers/operations/helpdesk.controller.js;
--     server_trade/controllers/helpdesk/public.helpdesk.controller.js
--   Integration point: Public Helpdesk video view counter
--   Reason: Atomic PostgreSQL write for Public Helpdesk video view counter.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "content".sp_increment_help_video_view(
    p_id varchar
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    UPDATE "content".helpvideo
    SET "viewCount" = "viewCount" + 1,
        "updatedAt" = CURRENT_TIMESTAMP
    WHERE id = p_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'Help video not found: %', p_id; END IF;
END;
$procedure$;

-- File: content.sp_sync_help_video_faq_links.sql
-- PROCEDURE: content.sp_sync_help_video_faq_links
-- Function: syncHelpVideoFaqLinks
-- Prisma await: await prismaClient.helpFAQ.updateMany(...)
-- Purpose: Atomic PostgreSQL write for Atomically link/unlink FAQs when a Helpdesk video is saved..
-- Point: Atomically link/unlink FAQs when a Helpdesk video is saved.
-- Used by: Helpdesk video create/update controller linkFaqIds/unlinkFaqIds.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_video_id varchar; p_link_faq_ids varchar[] DEFAULT ARRAY[]::varchar[]; p_unlink_faq_ids varchar[]
--     DEFAULT ARRAY[]::varchar[]
--   Code / route integration target: Code function: syncHelpVideoFaqLinks | Route / flow: Helpdesk video
--     create/update controller linkFaqIds/unlinkFaqIds. | Replace or support: await
--     prismaClient.helpFAQ.updateMany(...)
--   Full routes / trigger: POST /operations/helpdesk/videos; PUT /operations/helpdesk/videos/:id - save video
--     metadata and FAQ links
--   Related .js file(s): server_trade/controllers/operations/helpdesk.controller.js;
--     server_trade/controllers/helpdesk/public.helpdesk.controller.js;
--     server_trade/routes/operations/helpdesk.routes.js; server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Atomically link/unlink FAQs when a Helpdesk video is saved.
--   Reason: Atomic PostgreSQL write for Atomically link/unlink FAQs when a Helpdesk video is saved..
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "content".sp_sync_help_video_faq_links(
    p_video_id varchar,
    p_link_faq_ids varchar[] DEFAULT ARRAY[]::varchar[],
    p_unlink_faq_ids varchar[] DEFAULT ARRAY[]::varchar[]
)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF COALESCE(array_length(p_link_faq_ids, 1), 0) > 0 THEN
        UPDATE "support".helpfaq
        SET "videoId" = p_video_id,
            "updatedAt" = CURRENT_TIMESTAMP
        WHERE id = ANY(p_link_faq_ids);
    END IF;

    IF COALESCE(array_length(p_unlink_faq_ids, 1), 0) > 0 THEN
        UPDATE "support".helpfaq
        SET "videoId" = NULL,
            "updatedAt" = CURRENT_TIMESTAMP
        WHERE id = ANY(p_unlink_faq_ids)
          AND "videoId" = p_video_id;
    END IF;
END;
$procedure$;

-- File: content.sp_upsert_help_video.sql
-- PROCEDURE: content.sp_upsert_help_video
-- Function: upsertHelpVideo
-- Prisma await: await prismaClient.helpVideo.create/update(...)
-- Purpose: Atomic PostgreSQL write for Operations Helpdesk video metadata create/update.
-- Point: Operations Helpdesk video metadata create/update
-- Used by: POST/PUT /operations/helpdesk/videos[/:id]
-- File upload/deletion remains in Node.js; this persists its database metadata.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_id varchar; p_title varchar; p_url varchar; p_description text DEFAULT NULL; p_thumbnail_url
--     varchar DEFAULT NULL; p_category_id varchar DEFAULT NULL; p_tags text[] DEFAULT NULL; p_duration integer
--     DEFAULT NULL; p_sort_order integer DEFAULT 0; p_is_active boolean DEFAULT true; p_view_count integer DEFAULT 0;
--     p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
--   Code / route integration target: Code function: upsertHelpVideo | Route / flow: POST/PUT
--     /operations/helpdesk/videos[/:id] | Replace or support: await prismaClient.helpVideo.create/update(...)
--   Full routes / trigger: POST /operations/helpdesk/videos; PUT /operations/helpdesk/videos/:id - save video
--     metadata and FAQ links
--   Related .js file(s): server_trade/controllers/operations/helpdesk.controller.js;
--     server_trade/controllers/helpdesk/public.helpdesk.controller.js;
--     server_trade/routes/operations/helpdesk.routes.js; server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations Helpdesk video metadata create/update
--   Reason: Atomic PostgreSQL write for Operations Helpdesk video metadata create/update.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE PROCEDURE "content".sp_upsert_help_video(
    p_id varchar,
    p_title varchar,
    p_url varchar,
    p_description text DEFAULT NULL,
    p_thumbnail_url varchar DEFAULT NULL,
    p_category_id varchar DEFAULT NULL,
    p_tags text[] DEFAULT NULL,
    p_duration integer DEFAULT NULL,
    p_sort_order integer DEFAULT 0,
    p_is_active boolean DEFAULT true,
    p_view_count integer DEFAULT 0,
    p_created_at timestamp DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_id varchar := COALESCE(NULLIF(p_id, ''), gen_random_uuid()::text);
BEGIN
    IF NULLIF(BTRIM(p_title), '') IS NULL OR NULLIF(BTRIM(p_url), '') IS NULL THEN
        RAISE EXCEPTION 'Help video title and URL are required';
    END IF;

    INSERT INTO "content".helpvideo (
        id, title, description, url, "thumbnailUrl", "categoryId", tags,
        duration, "sortOrder", "isActive", "viewCount", "createdAt", "updatedAt"
    ) VALUES (
        v_id, BTRIM(p_title), p_description, p_url, p_thumbnail_url,
        p_category_id, to_jsonb(p_tags), p_duration, p_sort_order, p_is_active,
        p_view_count, p_created_at, p_created_at
    )
    ON CONFLICT (id) DO UPDATE SET
        title = EXCLUDED.title,
        description = EXCLUDED.description,
        url = EXCLUDED.url,
        "thumbnailUrl" = EXCLUDED."thumbnailUrl",
        "categoryId" = EXCLUDED."categoryId",
        tags = EXCLUDED.tags,
        duration = EXCLUDED.duration,
        "sortOrder" = EXCLUDED."sortOrder",
        "isActive" = EXCLUDED."isActive",
        "updatedAt" = CURRENT_TIMESTAMP;
END;
$procedure$;



-- Functions integrated from all_final_function_mandar.sql
-- FUNCTION: content.fn_get_help_videos
-- Function: getHelpVideos
-- Prisma await: await prismaClient.helpVideo.findMany({ include: { category: true, _count: true } })
-- Purpose: PostgreSQL read/calculation for Operations and public Helpdesk video listing/search.
-- Point: Operations and public Helpdesk video listing/search
-- Used by: Helpdesk video list, category detail, and public video routes.
-- ----------------------------------------------------------------------------
-- >>> INTEGRATION METADATA
--   Parameters: p_category_id varchar DEFAULT NULL; p_is_active boolean DEFAULT NULL; p_search varchar DEFAULT NULL
--   Code / route integration target: Code function: getHelpVideos | Route / flow: Helpdesk video list, category
--     detail, and public video routes. | Replace or support: await prismaClient.helpVideo.findMany({ include: {
--     category: true, _count: true } })
--   Full routes / trigger: GET /operations/helpdesk/videos; GET /operations/helpdesk/videos/:id; GET
--     /auth/helpdesk/videos; GET /auth/helpdesk/videos/:id - list video data
--   Related .js file(s): server_trade/controllers/operations/helpdesk.controller.js;
--     server_trade/routes/operations/helpdesk.routes.js;
--     server_trade/controllers/helpdesk/public.helpdesk.controller.js;
--     server_trade/routes/helpdesk/user.helpdesk.routes.js
--   Integration point: Operations and public Helpdesk video listing/search
--   Reason: PostgreSQL read/calculation for Operations and public Helpdesk video listing/search.
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "content".fn_get_help_videos(
    p_category_id varchar DEFAULT NULL,
    p_is_active boolean DEFAULT NULL,
    p_search varchar DEFAULT NULL
)
RETURNS TABLE (
    id varchar,
    title varchar,
    description text,
    url varchar,
    thumbnail_url varchar,
    category_id varchar,
    tags jsonb,
    duration integer,
    sort_order integer,
    is_active boolean,
    view_count integer,
    created_at timestamp,
    updated_at timestamp,
    category_title varchar,
    linked_faq_count bigint
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        v.id,
        v.title,
        v.description,
        v.url,
        v."thumbnailUrl",
        v."categoryId",
        v.tags,
        v.duration,
        v."sortOrder",
        v."isActive",
        v."viewCount",
        v."createdAt",
        v."updatedAt",
        c.title,
        COUNT(f.id)
    FROM "content".helpvideo v
    LEFT JOIN "support".helpcategory c ON c.id = v."categoryId"
    LEFT JOIN "support".helpfaq f ON f."videoId" = v.id
    WHERE (p_category_id IS NULL OR v."categoryId" = p_category_id)
      AND (p_is_active IS NULL OR v."isActive" = p_is_active)
      AND (
          NULLIF(BTRIM(p_search), '') IS NULL
          OR v.title ILIKE '%' || BTRIM(p_search) || '%'
          OR v.description ILIKE '%' || BTRIM(p_search) || '%'
      )
    GROUP BY
        v.id, v.title, v.description, v.url, v."thumbnailUrl",
        v."categoryId", v.tags, v.duration, v."sortOrder", v."isActive",
        v."viewCount", v."createdAt", v."updatedAt", c.title
    ORDER BY v."sortOrder", v."createdAt" DESC;
$function$;
