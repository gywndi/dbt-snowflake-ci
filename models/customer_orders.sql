-- 고객별 주문 건수와 총 주문 금액. 사용자에게 열어 줄 결과 뷰.
select
    c.c_custkey as customer_key,
    c.c_name as customer_name,
    count(o.o_orderkey) as order_count,
    coalesce(sum(o.o_totalprice), 0) as total_price
from {{ source('tpch', 'customer') }} as c
left join {{ source('tpch', 'orders') }} as o
    on o.o_custkey = c.c_custkey
group by c.c_custkey, c.c_name
