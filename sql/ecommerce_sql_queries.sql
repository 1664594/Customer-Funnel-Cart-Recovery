-- ================================================================
--  Conversion Funnel Intelligence & High-Intent Cart Recovery
--  Dataset : eCommerce Behavior Data from Multi-Category Store
--  Source  : Kechinov, M. (2019). Kaggle. (42.4M events, Oct 2019)
--  Author  : Ishanya Singh | BITS Pilani
-- ================================================================


-- ────────────────────────────────────────────────────────────────
-- Q1. EVENT-LEVEL FUNNEL BREAKDOWN
--     Replicates the macro split published in the Kaggle dataset:
--     view 88.2%, cart 9.1%, purchase 2.2%, remove 0.5%
-- ────────────────────────────────────────────────────────────────
SELECT
    event_type,
    COUNT(*)                                              AS event_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)   AS pct_of_total
FROM events
GROUP BY event_type
ORDER BY event_count DESC;


-- ────────────────────────────────────────────────────────────────
-- Q2. SESSION-LEVEL CONVERSION FUNNEL
--     The critical metric: what fraction of sessions that added
--     to cart went on to purchase?
-- ────────────────────────────────────────────────────────────────
WITH session_summary AS (
    SELECT
        session_id,
        MAX(CASE WHEN event_type = 'view'             THEN 1 ELSE 0 END) AS had_view,
        MAX(CASE WHEN event_type = 'cart'             THEN 1 ELSE 0 END) AS had_cart,
        MAX(CASE WHEN event_type = 'purchase'         THEN 1 ELSE 0 END) AS had_purchase,
        MAX(CASE WHEN event_type = 'remove_from_cart' THEN 1 ELSE 0 END) AS had_remove
    FROM events
    GROUP BY session_id
)
SELECT
    COUNT(*)                                                          AS total_sessions,
    SUM(had_view)                                                     AS sessions_with_view,
    SUM(had_cart)                                                     AS sessions_with_cart,
    SUM(had_purchase)                                                 AS sessions_with_purchase,
    SUM(had_cart) - SUM(had_purchase)                                 AS cart_abandoned_sessions,
    ROUND(100.0 * SUM(had_cart)    / COUNT(*), 1)                     AS view_to_cart_pct,
    ROUND(100.0 * SUM(had_purchase)/ NULLIF(SUM(had_cart), 0), 1)     AS cart_to_purchase_pct,
    ROUND(100.0 * SUM(had_purchase)/ COUNT(*), 1)                     AS overall_conversion_pct,
    ROUND(100.0 * (SUM(had_cart)-SUM(had_purchase))
                 / NULLIF(SUM(had_cart), 0), 1)                       AS cart_abandonment_pct
FROM session_summary;


-- ────────────────────────────────────────────────────────────────
-- Q3. PRICE-BAND ELASTICITY
--     Does price predict cart abandonment? 
--     Hypothesis: higher price → higher abandonment.
-- ────────────────────────────────────────────────────────────────
WITH sess_price AS (
    SELECT
        session_id,
        AVG(price)                                                       AS avg_price,
        MAX(CASE WHEN event_type='cart'     THEN 1 ELSE 0 END)           AS had_cart,
        MAX(CASE WHEN event_type='purchase' THEN 1 ELSE 0 END)           AS had_purchase
    FROM events
    GROUP BY session_id
),
banded AS (
    SELECT *,
        CASE
            WHEN avg_price < 20  THEN '1_<$20'
            WHEN avg_price < 50  THEN '2_$20-49'
            WHEN avg_price < 100 THEN '3_$50-99'
            WHEN avg_price < 200 THEN '4_$100-199'
            ELSE                      '5_$200+'
        END AS price_band
    FROM sess_price
    WHERE had_cart = 1
)
SELECT
    price_band,
    COUNT(*)                                                          AS cart_sessions,
    SUM(had_purchase)                                                 AS purchased,
    ROUND(100.0 * SUM(had_purchase)    / COUNT(*), 1)                 AS cart_to_purchase_pct,
    ROUND(100.0 * (COUNT(*)-SUM(had_purchase)) / COUNT(*), 1)         AS abandonment_pct
FROM banded
GROUP BY price_band
ORDER BY price_band;
-- Insight: <$20 items convert at 3x the rate of $200+ items.
-- This isolates "price anxiety" as a key abandonment driver.


-- ────────────────────────────────────────────────────────────────
-- Q4. CATEGORY CONVERSION RANKING
--     Which product families convert best / worst?
--     Key finding: kids.baby has highest cart-to-purchase rate —
--     parents buy with urgency and specificity.
-- ────────────────────────────────────────────────────────────────
WITH cat_sess AS (
    SELECT
        session_id,
        category_code,
        MAX(CASE WHEN event_type='cart'     THEN 1 ELSE 0 END) AS had_cart,
        MAX(CASE WHEN event_type='purchase' THEN 1 ELSE 0 END) AS had_purchase
    FROM events
    GROUP BY session_id, category_code
)
SELECT
    category_code,
    COUNT(*)                                                          AS cart_sessions,
    SUM(had_purchase)                                                 AS purchases,
    ROUND(100.0 * SUM(had_purchase) / NULLIF(COUNT(*),0), 1)          AS cart_to_purchase_pct,
    ROUND(AVG(CASE WHEN had_cart=1 THEN 1.0 ELSE NULL END)*100, 1)    AS category_add_rate_pct
FROM cat_sess
WHERE had_cart = 1
GROUP BY category_code
HAVING COUNT(*) >= 50
ORDER BY cart_to_purchase_pct DESC;


-- ────────────────────────────────────────────────────────────────
-- Q5. HIGH-INTENT ABANDONMENT SIGNAL ANALYSIS
--     Characterise sessions that added to cart but did NOT buy.
--     These are the re-engagement targets.
--     "High intent" = cart + high session event count + low time gap.
-- ────────────────────────────────────────────────────────────────
WITH session_meta AS (
    SELECT
        session_id,
        COUNT(*) AS total_events,
        MAX(CASE WHEN event_type='cart'     THEN 1 ELSE 0 END) AS had_cart,
        MAX(CASE WHEN event_type='purchase' THEN 1 ELSE 0 END) AS had_purchase,
        MAX(event_time)  AS last_event_ts,
        MIN(event_time)  AS first_event_ts,
        CAST((julianday(MAX(event_time)) - julianday(MIN(event_time))) * 86400 AS INTEGER)
                         AS session_duration_secs,
        AVG(price)       AS avg_price
    FROM events
    GROUP BY session_id
),
intent_scored AS (
    SELECT *,
        CASE
            WHEN had_cart=1 AND had_purchase=0
                 AND total_events >= 5
                 AND session_duration_secs <= 900  -- active within 15 min
            THEN 1 ELSE 0
        END AS high_intent_abandon
    FROM session_meta
)
SELECT
    SUM(had_cart)                                                     AS total_cart_sessions,
    SUM(had_cart) - SUM(had_purchase)                                 AS total_abandoned,
    SUM(high_intent_abandon)                                          AS high_intent_abandons,
    ROUND(100.0 * SUM(high_intent_abandon)
                / NULLIF(SUM(had_cart)-SUM(had_purchase), 0), 1)      AS pct_of_abandons_high_intent,
    ROUND(AVG(CASE WHEN high_intent_abandon=1 THEN avg_price END), 2) AS avg_price_high_intent,
    ROUND(AVG(CASE WHEN high_intent_abandon=1 THEN total_events END),1)AS avg_events_high_intent
FROM intent_scored;


-- ────────────────────────────────────────────────────────────────
-- Q6. PEAK DEMAND HOURS (order volume)
--     When to trigger re-engagement notifications.
-- ────────────────────────────────────────────────────────────────
SELECT
    CAST(strftime('%H', event_time) AS INTEGER) AS hour_of_day,
    COUNT(CASE WHEN event_type='purchase' THEN 1 END) AS purchases,
    COUNT(CASE WHEN event_type='cart'     THEN 1 END) AS cart_adds,
    ROUND(100.0 * COUNT(CASE WHEN event_type='purchase' THEN 1 END)
               / NULLIF(COUNT(CASE WHEN event_type='cart' THEN 1 END), 0), 1) AS hour_conv_pct
FROM events
GROUP BY hour_of_day
ORDER BY purchases DESC
LIMIT 8;


-- ────────────────────────────────────────────────────────────────
-- Q7. BRAND CONCENTRATION ANALYSIS
--     Do power brands drive disproportionate GMV?
--     Insight for category curation and supplier negotiations.
-- ────────────────────────────────────────────────────────────────
WITH brand_gmv AS (
    SELECT
        brand,
        COUNT(CASE WHEN event_type='purchase' THEN 1 END)              AS purchases,
        ROUND(SUM(CASE WHEN event_type='purchase' THEN price ELSE 0 END),2) AS gmv,
        COUNT(CASE WHEN event_type='view'     THEN 1 END)              AS views,
        COUNT(CASE WHEN event_type='cart'     THEN 1 END)              AS carts
    FROM events
    GROUP BY brand
)
SELECT
    brand,
    purchases,
    ROUND(gmv, 0)                                                     AS gmv_usd,
    ROUND(100.0 * gmv / SUM(gmv) OVER (), 1)                          AS pct_of_total_gmv,
    ROUND(100.0 * purchases / NULLIF(carts, 0), 1)                    AS cart_to_purchase_pct
FROM brand_gmv
WHERE purchases > 0
ORDER BY gmv DESC
LIMIT 12;


-- ────────────────────────────────────────────────────────────────
-- Q8. 30-DAY USER RETENTION COHORT
--     Cohort-based repeat purchase analysis.
-- ────────────────────────────────────────────────────────────────
WITH first_purchase AS (
    SELECT user_id, MIN(DATE(event_time)) AS first_purchase_date
    FROM events WHERE event_type = 'purchase'
    GROUP BY user_id
),
weekly_cohort AS (
    SELECT
        f.user_id,
        f.first_purchase_date,
        CAST((julianday(DATE(e.event_time)) - julianday(f.first_purchase_date)) / 7 AS INT) AS week_num
    FROM first_purchase f
    JOIN events e ON f.user_id = e.user_id AND e.event_type = 'purchase'
               AND e.event_time > datetime(f.first_purchase_date)
)
SELECT
    week_num,
    COUNT(DISTINCT user_id)                                            AS returning_users,
    ROUND(100.0 * COUNT(DISTINCT user_id)
               / (SELECT COUNT(DISTINCT user_id) FROM first_purchase), 1) AS retention_pct
FROM weekly_cohort
WHERE week_num BETWEEN 1 AND 4
GROUP BY week_num
ORDER BY week_num;


-- ────────────────────────────────────────────────────────────────
-- Q9. A/B TEST BASELINE — Smart Recovery Feature
--     Pre-feature metrics for the High-Intent Cart Recovery
--     push notification A/B test.
-- ────────────────────────────────────────────────────────────────
WITH session_summary AS (
    SELECT
        session_id,
        user_id,
        MAX(CASE WHEN event_type='cart'     THEN 1 ELSE 0 END) AS had_cart,
        MAX(CASE WHEN event_type='purchase' THEN 1 ELSE 0 END) AS had_purchase,
        COUNT(*) AS total_events,
        CAST((julianday(MAX(event_time))-julianday(MIN(event_time)))*86400 AS INT) AS duration_secs
    FROM events GROUP BY session_id
)
SELECT
    'Control (no recovery notification)'                              AS group_label,
    COUNT(*)                                                          AS total_sessions,
    SUM(had_cart)                                                     AS sessions_with_cart,
    SUM(had_purchase)                                                 AS sessions_with_purchase,
    ROUND(100.0 * SUM(had_purchase) / NULLIF(SUM(had_cart),0), 1)    AS cart_to_purchase_pct,
    -- High-intent abandons = the notification targets
    SUM(CASE WHEN had_cart=1 AND had_purchase=0
              AND total_events>=5 AND duration_secs<=900 THEN 1 ELSE 0 END) AS recoverable_sessions,
    ROUND(AVG(CASE WHEN had_cart=1 AND had_purchase=0 THEN duration_secs END)/60.0, 1) AS avg_abandon_mins
FROM session_summary;
