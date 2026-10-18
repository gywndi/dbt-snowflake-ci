-- 다이내믹 테이블: 원천이 바뀌면 Snowflake가 target_lag 안에서 스스로 갱신한다.
{{ config(
    materialized='dynamic_table',
    snowflake_warehouse='DBT_WH',
    target_lag='1 hour'
) }}

select
    o_orderstatus as order_status,
    count(*) as order_count,
    count(distinct o_custkey) as customer_count
from {{ source('tpch', 'orders') }}
group by o_orderstatus
