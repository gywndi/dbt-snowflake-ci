-- 테이블: dbt run 때마다 전체를 다시 계산해 저장한다. 조회는 저장된 결과만 읽는다.
{{ config(materialized='table') }}

select
    o_orderstatus as order_status,
    count(*) as order_count,
    count(distinct o_custkey) as customer_count
from {{ source('tpch', 'orders') }}
group by o_orderstatus
