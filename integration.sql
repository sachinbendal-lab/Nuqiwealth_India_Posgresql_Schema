-- Schema-wise functions

-- Functions integrated from all_final_function_mandar.sql
-- Converts parallel scalar key/value arrays into a JSONB object. Callers never
-- pass JSON: booleans and canonical numbers are inferred; every other value is
-- preserved as a string (including identifiers with leading zeroes).
-- >>> INTEGRATION METADATA
--   Parameters: p_keys text[]; p_values text[]
--   Code / route integration target: Code function: Internal SQL helper; not called directly by an HTTP controller |
--     Route / flow: Transaction, NSE MF, Zerodha, ticket, audit, and notification procedures | Replace or support:
--     Called inside procedures that accept parallel text[] key/value inputs
--   Full routes / trigger: No HTTP route - internal SQL helper invoked inside write procedures before JSONB
--     INSERT/UPDATE
--   Related .js file(s): No direct .js file (internal helper called by SQL procedures)
--   Integration point: Convert API key/value arrays to a validated JSONB object before INSERT/UPDATE
--   Reason: Avoid json/jsonb procedure parameters while preserving JSONB table columns and rejecting mismatched
--     key/value arrays
-- <<< INTEGRATION METADATA
CREATE OR REPLACE FUNCTION "integration".fn_jsonb_from_pairs(
    p_keys text[],
    p_values text[]
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
    v_result jsonb := '{}'::jsonb;
    v_value jsonb;
    v_index integer;
BEGIN
    IF p_keys IS NULL AND p_values IS NULL THEN
        RETURN NULL;
    END IF;

    IF COALESCE(cardinality(p_keys), 0) <> COALESCE(cardinality(p_values), 0) THEN
        RAISE EXCEPTION 'JSON property key/value counts must match';
    END IF;

    FOR v_index IN 1..COALESCE(cardinality(p_keys), 0) LOOP
        IF p_keys[v_index] IS NULL OR BTRIM(p_keys[v_index]) = '' THEN
            RAISE EXCEPTION 'JSON property key at position % is empty', v_index;
        END IF;

        v_value := CASE
            WHEN p_values[v_index] IS NULL THEN 'null'::jsonb
            WHEN LOWER(p_values[v_index]) IN ('true', 'false')
                THEN to_jsonb(p_values[v_index]::boolean)
            WHEN p_values[v_index] ~ '^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$'
                THEN to_jsonb(p_values[v_index]::numeric)
            ELSE to_jsonb(p_values[v_index])
        END;

        v_result := v_result || jsonb_build_object(p_keys[v_index], v_value);
    END LOOP;

    RETURN v_result;
END;
$function$;
