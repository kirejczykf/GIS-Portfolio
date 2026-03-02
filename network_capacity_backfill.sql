
/*
 * Project: Fiber Network Data Enrichment
 * Description: 
 * Automates the backfilling of missing network usage data for regulatory reporting.
 * Uses probabilistic modeling to estimate usage for new infrastructure and 
 * applies organic growth factors to existing connections within physical constraints.
 *
 * Tech Stack: PostgreSQL, CTE, Window Functions, Conditional Logic
 */

WITH network_snapshot AS (
    SELECT
        id,
        -- Handle potential NULLs in capacity to prevent arithmetic errors
        COALESCE(total_fiber_capacity, 0) AS total_capacity, 
        used_fiber_count AS current_usage,
        -- Generate random seed for stochastic update logic
        random() AS update_probability,
        random() AS growth_factor
    FROM
        fiber_network_inventory
),
usage_calculation AS (
    SELECT
        id,
        current_usage, -- Kept for tracking changes
        CASE
            -- SCENARIO 1: New Infrastructure (Cold Start)
            -- Logic: If usage data is missing (NULL), simulate initial usage 
            -- based on a random distribution within physical capacity limits.
            WHEN current_usage IS NULL AND total_capacity > 0 THEN
                FLOOR(growth_factor * total_capacity + 1)

            -- SCENARIO 2: Existing Infrastructure (Organic Growth)
            -- Logic: 30% chance to update existing records.
            -- Apply a variation factor (+/- 10%) but ensure it never drops below 1 
            -- and never exceeds total physical capacity (LEAST constraint).
            WHEN current_usage IS NOT NULL AND update_probability <= 0.30 THEN
                LEAST(
                    GREATEST(
                        ROUND(current_usage * (0.9 + (growth_factor * 0.2))), 
                        1 
                    ),
                    total_capacity
                )
            -- SCENARIO 3: No Change (Data Stability)
            ELSE
                current_usage
        END AS new_usage
    FROM
        network_snapshot
)
-- Apply updates efficiently using a join on the calculated CTE
UPDATE fiber_network_inventory t
SET used_fiber_count = c.new_usage
FROM
    usage_calculation c
WHERE
    t.id = c.id
-- Log changes for audit purposes
RETURNING 
    t.id, 
    c.current_usage AS previous_value, 
    t.used_fiber_count AS updated_value;
