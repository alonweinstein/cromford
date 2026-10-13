CREATE TABLE customers (
  id bigint primary key,
  name text not null,
  email text not null
);
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
