-- 증분 테이블: 첫 실행은 전체를 만들고, 이후에는 새 날짜만 계산해 unique_key 기준으로 병합한다.
{{ config(materialized='incremental', unique_key='order_date', incremental_strategy='merge') }}

select
    o_orderdate as order_date,
    count(*) as order_count,
    count(distinct o_custkey) as customer_count
from {{ source('tpch', 'orders') }}
{% if is_incremental() %}
where o_orderdate > (select max(order_date) from {{ this }})
{% endif %}
group by o_orderdate
