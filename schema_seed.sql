-- Schema + seed for the Supabase↔Grafana hands-on lab.
-- Scenario hook: an e-commerce-ish dataset where a reporting query filters
-- order_items.batch, which is DELIBERATELY left un-indexed. Running that query under
-- concurrency forces full seq scans -> CPU/IO saturation -> query latency ->
-- connection pile-up (the "resource cascade"). Remediation in the demo = add the
-- missing index and watch it recover.

create schema if not exists shop;
set search_path to shop, public;

drop table if exists order_items, orders, events, products, customers cascade;

create table customers (
  id         bigint primary key,
  email      text not null,
  full_name  text not null,
  country    text not null,
  created_at timestamptz not null default now()
);

create table products (
  id         bigint primary key,
  name       text not null,
  category   text not null,
  price      numeric(10,2) not null,
  created_at timestamptz not null default now()
);

create table orders (
  id          bigint primary key,
  customer_id bigint not null references customers(id),
  status      text not null,          -- un-indexed too, but not queried by the demo
  total       numeric(12,2) not null,
  note        text,
  created_at  timestamptz not null
);

create table order_items (
  id         bigint primary key,
  order_id   bigint not null references orders(id),
  product_id bigint not null references products(id),
  qty        int not null,
  price      numeric(10,2) not null,
  batch      text              -- selective (~1/1000), UN-indexed = the fault hook
);

-- append-heavy table for baseline write load
create table events (
  id          bigserial primary key,
  customer_id bigint,
  type        text not null,
  payload     jsonb,
  created_at  timestamptz not null default now()
);

-- ---- seed (server-side via generate_series; fast, no data transfer) ----
insert into shop.customers (id,email,full_name,country,created_at)
select g,
       'user'||g||'@example.com',
       'Customer '||g,
       (array['US','GB','DE','IN','BR','CA','AU','FR'])[1+floor(random()*8)],
       now() - (random()*interval '365 days')
from generate_series(1,20000) g;

insert into shop.products (id,name,category,price,created_at)
select g,
       'Product '||g,
       (array['widgets','gadgets','gizmos','doohickeys','thingamajigs'])[1+floor(random()*5)],
       round((random()*200+1)::numeric,2),
       now() - (random()*interval '365 days')
from generate_series(1,2000) g;

insert into shop.orders (id,customer_id,status,total,note,created_at)
select g,
       1+floor(random()*20000),
       (array['paid','paid','paid','pending','shipped','refunded','cancelled'])[1+floor(random()*7)],
       round((random()*500+5)::numeric,2),
       case when random()<0.02 then 'flagged' else null end,
       now() - (random()*interval '90 days')
from generate_series(1,500000) g;

insert into shop.order_items (id,order_id,product_id,qty,price,batch)
select g,
       1+floor(random()*500000),
       1+floor(random()*2000),
       1+floor(random()*5),
       round((random()*200+1)::numeric,2),
       (g % 1000)::text
from generate_series(1,1250000) g;

-- normal indexes a well-tuned app WOULD have...
create index on shop.orders(customer_id);
create index on shop.orders(created_at);
create index on shop.order_items(order_id);
create index on shop.order_items(product_id);
create index on shop.events(created_at);
-- ...but NO index on shop.order_items(batch)  <-- this is what the demo diagnoses & fixes

analyze;
