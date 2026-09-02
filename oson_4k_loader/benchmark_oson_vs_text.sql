-- Compare textual JSON BLOB storage with BLOB IS JSON FORMAT OSON storage.
-- Prerequisite: PO_OSON_OVER_4K contains the OSON documents under test.
-- This script creates and replaces only PO_JSON_TEXT_OVER_4K.

set serveroutput on
set timing on
set linesize 260

begin
  execute immediate 'drop table po_json_text_over_4k purge';
exception
  when others then
    if sqlcode != -942 then raise; end if;
end;
/

begin
  execute immediate 'drop table po_json_benchmark_results purge';
exception
  when others then
    if sqlcode != -942 then raise; end if;
end;
/

create table po_json_benchmark_results
(
  use_case                      varchar2(40) not null,
  measure                       varchar2(50) not null,
  oson_result                   number not null,
  text_blob_result              number not null,
  executions                    number not null,
  oson_elapsed_seconds          number not null,
  text_blob_elapsed_seconds     number not null,
  oson_ms_per_execution         number not null,
  text_blob_ms_per_execution    number not null,
  difference_ms_text_minus_oson number not null,
  oson_benefit_percent          number not null,
  constraint po_json_benchmark_results_pk primary key (use_case, measure)
);

-- One row per purchase order: this view exposes OSON fields as relational
-- SQL columns. The JSON field paths and their corresponding Oracle types are
-- visible in the view definition; DESC below shows the resulting columns.
create or replace view po_oson_over_4k_relational_v as
select p.po_number as table_po_number,
       jt.document_po_number,
       jt.document_reference,
       jt.requestor,
       jt.application_user,
       jt.cost_center,
       jt.shipping_city,
       jt.shipping_zip_code,
       jt.first_line_unit_price,
       jt.benchmark_timestamp,
       jt.padding_character_count
  from po_oson_over_4k p,
       json_table(p.attributes, '$'
         columns (
           document_po_number      number         path '$.PONumber',
           document_reference      varchar2(30)   path '$.Reference',
           requestor               varchar2(100)  path '$.Requestor',
           application_user        varchar2(30)   path '$.User',
           cost_center             varchar2(10)   path '$.CostCenter',
           shipping_city           varchar2(100)  path '$.ShippingInstructions.Address.city',
           shipping_zip_code       number         path '$.ShippingInstructions.Address.zipCode',
           first_line_unit_price   number         path '$.LineItems[0].Part.UnitPrice',
           benchmark_timestamp     timestamp with time zone
                                              path '$.OSONStorageTest.benchmarkTimestamp',
           padding_character_count number         path '$.OSONStorageTest.paddingCharacterCount'
         )) jt;

prompt === OSON relational view (JSON fields mapped to Oracle SQL types) ===
desc po_oson_over_4k_relational_v

-- Rebuild the paired predicate indexes so repeated benchmark runs are
-- idempotent. These names are specific to this test case.
begin
  execute immediate 'drop index po_oson_over_4k_costcenter_ix';
exception
  when others then
    if sqlcode != -1418 then raise; end if;
end;
/

begin
  execute immediate 'drop index po_oson_over_4k_user_ix';
exception
  when others then
    if sqlcode != -1418 then raise; end if;
end;
/

-- This control table stores UTF-8 serialized JSON text, not OSON.
create table po_json_text_over_4k
(
  po_number  number not null,
  attributes blob not null,
  constraint po_json_text_over_4k_pk primary key (po_number),
  constraint po_json_text_over_4k_json_chk check (attributes is json)
);

-- JSON_SERIALIZE converts the existing OSON documents to textual JSON. Thus
-- both tables contain the same logical documents and have the same row keys.
insert into po_json_text_over_4k (po_number, attributes)
select po_number,
       json_serialize(attributes returning blob)
  from po_oson_over_4k;
commit;

-- Identical function-based indexes for the JSON_VALUE predicate below.
create index po_oson_over_4k_costcenter_ix
  on po_oson_over_4k
  (json_value(attributes, '$.CostCenter' returning varchar2(10)));

create index po_json_text_over_4k_costcenter_ix
  on po_json_text_over_4k
  (json_value(attributes, '$.CostCenter' returning varchar2(10)));

create index po_oson_over_4k_user_ix
  on po_oson_over_4k
  (json_value(attributes, '$.User' returning varchar2(30)));

create index po_json_text_over_4k_user_ix
  on po_json_text_over_4k
  (json_value(attributes, '$.User' returning varchar2(30)));

begin
  dbms_stats.gather_table_stats(user, 'PO_OSON_OVER_4K', cascade => true);
  dbms_stats.gather_table_stats(user, 'PO_JSON_TEXT_OVER_4K', cascade => true);
end;
/

prompt === Row-count equivalence ===
select 'OSON' as storage, count(*) as documents from po_oson_over_4k
union all
select 'TEXT', count(*) from po_json_text_over_4k;

prompt === Matching JSON_VALUE index storage ===
select segment_name as index_name,
       round(sum(bytes) / 1024 / 1024, 2) as allocated_mb
 from user_segments
 where segment_name in ('PO_OSON_OVER_4K_COSTCENTER_IX',
                        'PO_JSON_TEXT_OVER_4K_COSTCENTER_IX',
                        'PO_OSON_OVER_4K_USER_IX',
                        'PO_JSON_TEXT_OVER_4K_USER_IX')
 group by segment_name
 order by index_name;

prompt === Average document bytes (payload only; excludes LOB/index overhead) ===
select 'OSON' as storage, round(avg(dbms_lob.getlength(attributes))) as average_bytes
  from po_oson_over_4k
union all
select 'TEXT', round(avg(dbms_lob.getlength(attributes)))
  from po_json_text_over_4k;

-- The matching function-based indexes above apply only to the JSON_VALUE
-- predicate. JSON_TABLE below has no predicate, so it remains a full traversal.
declare
  multi_value_repetitions constant pls_integer := 100;
  json_table_repetitions constant pls_integer := 100;
  update_repetitions     constant pls_integer := 1;

  procedure time_workload (
    p_statement       varchar2,
    p_repetitions     pls_integer,
    p_result          out number,
    p_elapsed_seconds out number
  ) is
    started_at pls_integer;
  begin
    -- One warm-up execution avoids including initial cursor/cache setup.
    execute immediate p_statement into p_result;
    started_at := dbms_utility.get_time;
    for iteration in 1 .. p_repetitions loop
      execute immediate p_statement into p_result;
    end loop;
    p_elapsed_seconds := (dbms_utility.get_time - started_at) / 100;
  end;

  procedure benchmark (
    p_use_case       varchar2,
    p_measure        varchar2,
    p_oson_statement varchar2,
    p_text_statement varchar2,
    p_repetitions    pls_integer
  ) is
    oson_result   number;
    text_result   number;
    oson_seconds  number;
    text_seconds  number;
    oson_ms       number;
    text_ms       number;
  begin
    time_workload(p_oson_statement, p_repetitions, oson_result, oson_seconds);
    time_workload(p_text_statement, p_repetitions, text_result, text_seconds);
    oson_ms := (oson_seconds * 1000) / p_repetitions;
    text_ms := (text_seconds * 1000) / p_repetitions;

    insert into po_json_benchmark_results values
      (p_use_case, p_measure, oson_result, text_result, p_repetitions,
       oson_seconds, text_seconds, oson_ms, text_ms, text_ms - oson_ms,
       case when text_ms = 0 then 0
            else ((text_ms - oson_ms) / text_ms) * 100
       end);
  end;

  procedure time_update (
    p_table           varchar2,
    p_result          out number,
    p_elapsed_seconds out number
  ) is
    started_at      pls_integer;
    update_sql      varchar2(32767);
    count_sql       varchar2(2000);
    max_line_items  pls_integer;
  begin
    -- JSON_TRANSFORM NESTED PATH is not available in Oracle 19c. Determine
    -- the maximum array length, then generate one literal-path SET operation
    -- per possible array position. IGNORE ON MISSING handles shorter orders.
    count_sql :=
      'select max(line_item_count) from (' ||
      'select count(*) line_item_count from ' || p_table || ' p, ' ||
      'json_table(p.attributes, ''$.LineItems[*]'' ' ||
      'columns (item_number number path ''$.ItemNumber'')) jt ' ||
      'group by p.po_number)';
    execute immediate count_sql into max_line_items;

    update_sql := 'update ' || p_table || ' set attributes = json_transform(attributes, ';
    for item_index in 0 .. max_line_items - 1 loop
      if item_index > 0 then
        update_sql := update_sql || ', ';
      end if;
      -- In 19c, PATH is a JSON-path reference, not an arithmetic expression.
      -- Both JSON paths below are emitted as SQL literals; the multiplication is
      -- a regular SQL NUMBER expression used as the SET value.
      update_sql := update_sql ||
        'SET ''$.LineItems[' || item_index || '].Part.UnitPrice'' = ' ||
        'json_value(attributes, ''$.LineItems[' || item_index ||
        '].Part.UnitPrice'' returning number) * 1.1 ' ||
        'IGNORE ON MISSING IGNORE ON NULL';
    end loop;
    update_sql := update_sql || ' returning blob)';

    started_at := dbms_utility.get_time;
    for iteration in 1 .. update_repetitions loop
      -- Each statement updates every document and every LineItems[*].Part.UnitPrice.
      -- A single execution keeps the rollback/undo volume practical; compare
      -- repeated full-script runs using the reported elapsed time.
      execute immediate update_sql;
      p_result := sql%rowcount;
    end loop;
    p_elapsed_seconds := (dbms_utility.get_time - started_at) / 100;
  end;

  procedure benchmark_update (
    p_use_case varchar2,
    p_measure  varchar2
  ) is
    oson_result   number;
    text_result   number;
    oson_seconds  number;
    text_seconds  number;
    oson_ms       number;
    text_ms       number;
  begin
    -- Each timed run starts from identical documents and rolls back all
    -- changes, leaving the data ready for the next run.
    savepoint oson_update_benchmark;
    time_update('po_oson_over_4k', oson_result, oson_seconds);
    rollback to oson_update_benchmark;

    savepoint text_update_benchmark;
    time_update('po_json_text_over_4k', text_result, text_seconds);
    rollback to text_update_benchmark;

    oson_ms := (oson_seconds * 1000) / update_repetitions;
    text_ms := (text_seconds * 1000) / update_repetitions;
    insert into po_json_benchmark_results values
      (p_use_case, p_measure, oson_result, text_result, update_repetitions,
       oson_seconds, text_seconds, oson_ms, text_ms, text_ms - oson_ms,
       case when text_ms = 0 then 0
            else ((text_ms - oson_ms) / text_ms) * 100
       end);
  end;
begin

  -- The outer SUM forces evaluation of every JSON_VALUE in the inner SELECT
  -- list. This is a full scan, intentionally without a JSON_VALUE index
  -- predicate, so it measures multi-field document projection.
  benchmark('Faster path evaluation', 'Multiple JSON_VALUE projection', q'~
    select sum(nvl(po_number, 0) +
               nvl(length(document_reference), 0) +
               nvl(length(requestor), 0) +
               nvl(length(application_user), 0) +
               nvl(length(cost_center), 0) +
               nvl(length(city), 0) +
               nvl(padding_character_count, 0))
      from (
        select json_value(attributes, '$.PONumber' returning number) po_number,
               json_value(attributes, '$.Reference' returning varchar2(30)) document_reference,
               json_value(attributes, '$.Requestor' returning varchar2(100)) requestor,
               json_value(attributes, '$.User' returning varchar2(30)) application_user,
               json_value(attributes, '$.CostCenter' returning varchar2(10)) cost_center,
               json_value(attributes,
                          '$.ShippingInstructions.Address.city'
                          returning varchar2(100)) city,
               json_value(attributes,
                          '$.OSONStorageTest.paddingCharacterCount'
                          returning number) padding_character_count
          from po_oson_over_4k
      )
  ~', q'~
    select sum(nvl(po_number, 0) +
               nvl(length(document_reference), 0) +
               nvl(length(requestor), 0) +
               nvl(length(application_user), 0) +
               nvl(length(cost_center), 0) +
               nvl(length(city), 0) +
               nvl(padding_character_count, 0))
      from (
        select json_value(attributes, '$.PONumber' returning number) po_number,
               json_value(attributes, '$.Reference' returning varchar2(30)) document_reference,
               json_value(attributes, '$.Requestor' returning varchar2(100)) requestor,
               json_value(attributes, '$.User' returning varchar2(30)) application_user,
               json_value(attributes, '$.CostCenter' returning varchar2(10)) cost_center,
               json_value(attributes,
                          '$.ShippingInstructions.Address.city'
                          returning varchar2(100)) city,
               json_value(attributes,
                          '$.OSONStorageTest.paddingCharacterCount'
                          returning number) padding_character_count
          from po_json_text_over_4k
      )
  ~', multi_value_repetitions);

  benchmark('Server-side SQL/JSON operations', 'JSON_TABLE LineItems expansion', q'~
    select count(*)
      from po_oson_over_4k p,
           json_table(p.attributes, '$.LineItems[*]'
             columns (item_number number path '$.ItemNumber')) jt
  ~', q'~
    select count(*)
      from po_json_text_over_4k p,
           json_table(p.attributes, '$.LineItems[*]'
             columns (item_number number path '$.ItemNumber')) jt
  ~', json_table_repetitions);

  benchmark_update('Efficient random access',
                   'UPDATE all LineItems UnitPrice +10%');
  commit;
end;
/


prompt === OSON versus Text BLOB benchmark results ===
column use_case format a32 heading 'Use case'
column measure format a40 heading 'Measure'
column oson_result format 999999999 heading 'OSON|Result'
column text_blob_result format 999999999 heading 'Text BLOB|Result'
column executions format 999999 heading 'Executions'
column oson_ms_per_execution format 9999990.00 heading 'OSON|ms/exec'
column text_blob_ms_per_execution format 9999990.00 heading 'Text BLOB|ms/exec'
column difference_ms_text_minus_oson format 9999990.00 heading 'Text - OSON|ms/exec'
column oson_benefit_percent format 990.00 heading 'OSON benefit|% vs Text'

select use_case,
       measure,
       oson_result,
       text_blob_result,
       executions,
       round(oson_ms_per_execution, 2) as oson_ms_per_execution,
       round(text_blob_ms_per_execution, 2) as text_blob_ms_per_execution,
       round(difference_ms_text_minus_oson, 2) as difference_ms_text_minus_oson,
       round(oson_benefit_percent, 2) as oson_benefit_percent
  from po_json_benchmark_results
 order by use_case, measure;

prompt === Optional post-run cleanup ===
prompt drop table po_json_text_over_4k purge;
prompt drop table po_json_benchmark_results purge;


 /* 
 
View PO_OSON_OVER_4K_RELATIONAL_V created.

Elapsed: 00:00:00.096
=== OSON relational view (JSON fields mapped to Oracle SQL types) ===
Name                    Null?    Type                        
----------------------- -------- --------------------------- 
TABLE_PO_NUMBER         NOT NULL NUMBER                      
DOCUMENT_PO_NUMBER               NUMBER                      
DOCUMENT_REFERENCE               VARCHAR2(30)                
REQUESTOR                        VARCHAR2(100)               
APPLICATION_USER                 VARCHAR2(30)                
COST_CENTER                      VARCHAR2(10)                
SHIPPING_CITY                    VARCHAR2(100)               
SHIPPING_ZIP_CODE                NUMBER                      
FIRST_LINE_UNIT_PRICE            NUMBER                      
BENCHMARK_TIMESTAMP              TIMESTAMP(6) WITH TIME ZONE 
PADDING_CHARACTER_COUNT          NUMBER                      

=== Average document bytes (payload only) ===

STOR AVERAGE_BYTES
---- -------------
OSON          5358
TEXT          5464


=== OSON versus Text BLOB benchmark results ===

                                                                                OSON  Text BLOB                   OSON   Text BLOB Text - OSON OSON benefit
Use case                         Measure                                      Result     Result Executions     ms/exec     ms/exec     ms/exec    % vs Text
-------------------------------- ---------------------------------------- ---------- ---------- ---------- ----------- ----------- ----------- ------------
Efficient random access          UPDATE all LineItems UnitPrice +10%           10000      10000          1     1980.00     3660.00     1680.00        45.90
Faster path evaluation           Multiple JSON_VALUE projection             93506560   93506560        100       70.60      113.40       42.80        37.74
Server-side SQL/JSON operations  JSON_TABLE LineItems expansion                45260      45260        100       61.90      140.40       78.50        55.91

 OSON_RESULT
 Multiple JSON_VALUE projection: the aggregated value from all extracted JSON fields.
 JSON_TABLE expansion: total line-item rows returned.
 UPDATE: number of documents updated.
 
 TEXT_BLOB_RESULT
The same check for the Text BLOB table.
They should match, confirming both formats performed the same logical work before comparing the timings.

  
 */

 
