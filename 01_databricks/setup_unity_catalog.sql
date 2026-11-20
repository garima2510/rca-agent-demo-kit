-- RCA demo - Azure Databricks setup (run in a SQL editor / notebook on a Unity Catalog-enabled workspace)
-- SYNTHETIC DEMO DATA - Fabrikam Components (fictitious)

-- Prerequisite: create rca_demo_data in Catalog Explorer with a managed storage location.
-- Use your workspace's registered external location (<your-external-location>),
-- sub/path rca-demo-data. Do not rely on an unconfigured metastore storage root.
-- Run the schema/volume block first, upload the CSVs, then run the table/view block.
DESCRIBE CATALOG EXTENDED rca_demo_data;
CREATE SCHEMA  IF NOT EXISTS rca_demo_data.raw;
CREATE SCHEMA  IF NOT EXISTS rca_demo_data.plant;
CREATE SCHEMA  IF NOT EXISTS rca_demo_data.maintenance;
CREATE SCHEMA  IF NOT EXISTS rca_demo_data.quality;
CREATE VOLUME  IF NOT EXISTS rca_demo_data.raw.landing;
-- >>> Upload all CSVs from 01_databricks/data to /Volumes/rca_demo_data/raw/landing/ (Catalog Explorer > Volume > Upload)

CREATE OR REPLACE TABLE rca_demo_data.plant.dim_site AS
  SELECT * FROM read_files('/Volumes/rca_demo_data/raw/landing/dim_site.csv', format=>'csv', header=>true, inferSchema=>true);
CREATE OR REPLACE TABLE rca_demo_data.plant.dim_equipment AS
  SELECT * FROM read_files('/Volumes/rca_demo_data/raw/landing/dim_equipment.csv', format=>'csv', header=>true, inferSchema=>true);
CREATE OR REPLACE TABLE rca_demo_data.quality.dim_material_lot AS
  SELECT * FROM read_files('/Volumes/rca_demo_data/raw/landing/dim_material_lot.csv', format=>'csv', header=>true, inferSchema=>true);
CREATE OR REPLACE TABLE rca_demo_data.maintenance.fact_sensor_reading_hourly AS
  SELECT * FROM read_files('/Volumes/rca_demo_data/raw/landing/fact_sensor_reading_hourly.csv', format=>'csv', header=>true, inferSchema=>true);
CREATE OR REPLACE TABLE rca_demo_data.maintenance.fact_downtime_event AS
  SELECT * FROM read_files('/Volumes/rca_demo_data/raw/landing/fact_downtime_event.csv', format=>'csv', header=>true, inferSchema=>true);
CREATE OR REPLACE TABLE rca_demo_data.maintenance.fact_maintenance_work_order AS
  SELECT * FROM read_files('/Volumes/rca_demo_data/raw/landing/fact_maintenance_work_order.csv', format=>'csv', header=>true, inferSchema=>true);
CREATE OR REPLACE TABLE rca_demo_data.quality.fact_production_batch AS
  SELECT * FROM read_files('/Volumes/rca_demo_data/raw/landing/fact_production_batch.csv', format=>'csv', header=>true, inferSchema=>true);
CREATE OR REPLACE TABLE rca_demo_data.quality.fact_quality_inspection AS
  SELECT * FROM read_files('/Volumes/rca_demo_data/raw/landing/fact_quality_inspection.csv', format=>'csv', header=>true, inferSchema=>true);

-- Table / column comments help Genie generate correct SQL
COMMENT ON TABLE rca_demo_data.maintenance.fact_sensor_reading_hourly IS 'Hourly average sensor values per equipment. metric values: dew_point_c (resin dryers, normal <= -40, warning > -30), drying_temp_c, barrel_temp_zone3_c, cycle_time_s, mould_temp_c, hydraulic_pressure_bar (normal ~160).';
COMMENT ON TABLE rca_demo_data.maintenance.fact_maintenance_work_order IS 'CMMS work orders. wo_type Preventive/Corrective. status Completed/Deferred/Open. status_note explains deferrals.';
COMMENT ON TABLE rca_demo_data.quality.fact_quality_inspection IS 'End-of-batch inspection. defect_rate_pct = defect_count/sample_qty*100. disposition Released/Quarantined.';
COMMENT ON TABLE rca_demo_data.quality.dim_material_lot IS 'Incoming resin lots. moisture_on_receipt_pct spec max 0.02.';

-- Convenience views
CREATE OR REPLACE VIEW rca_demo_data.quality.v_batch_quality AS
SELECT b.*, q.primary_defect_type, q.defect_count, q.defect_rate_pct, q.disposition,
       l.supplier, l.moisture_on_receipt_pct
FROM rca_demo_data.quality.fact_production_batch b
JOIN rca_demo_data.quality.fact_quality_inspection q USING (batch_id)
LEFT JOIN rca_demo_data.quality.dim_material_lot l ON b.resin_lot_id = l.lot_id;

CREATE OR REPLACE VIEW rca_demo_data.maintenance.v_sensor_daily AS
SELECT s.equipment_id, e.site_id, e.line_id, e.equipment_type, s.metric,
       DATE(s.reading_ts) AS reading_date, ROUND(AVG(s.value),2) AS avg_value,
       ROUND(MIN(s.value),2) AS min_value, ROUND(MAX(s.value),2) AS max_value
FROM rca_demo_data.maintenance.fact_sensor_reading_hourly s
JOIN rca_demo_data.plant.dim_equipment e USING (equipment_id)
GROUP BY ALL;

-- Optional: metric view (Unity Catalog metric views) for consistent KPI definitions in Genie
-- Leave commented for the base demo; select and run separately only if supported.
/*
CREATE OR REPLACE VIEW rca_demo_data.quality.mv_quality_kpis
WITH METRICS LANGUAGE YAML AS $$
version: 0.1
source: rca_demo_data.quality.v_batch_quality
dimensions:
  - name: site_id
    expr: site_id
  - name: line_id
    expr: line_id
  - name: production_date
    expr: DATE(start_ts)
  - name: resin_lot_id
    expr: resin_lot_id
measures:
  - name: defect_rate_pct
    expr: SUM(defect_count) * 100.0 / SUM(qty_produced)
  - name: quarantined_parts
    expr: SUM(CASE WHEN disposition = 'Quarantined' THEN qty_produced ELSE 0 END)
  - name: good_parts
    expr: SUM(qty_good)
$$;
*/

-- For OAuth passthrough, grant to the consenting Databricks user/group.
-- For service-principal auth, use the registered Databricks service principal.
-- GRANT USE CATALOG ON CATALOG rca_demo_data TO `<databricks-principal>`;
-- GRANT USE SCHEMA, SELECT ON SCHEMA rca_demo_data.plant TO `<databricks-principal>`;
-- GRANT USE SCHEMA, SELECT ON SCHEMA rca_demo_data.maintenance TO `<databricks-principal>`;
-- GRANT USE SCHEMA, SELECT ON SCHEMA rca_demo_data.quality TO `<databricks-principal>`;
-- GRANT CAN USE on the SQL warehouse + CAN RUN on the Genie spaces (workspace UI)

-- Sanity checks (expected: EIN L2 defect rate ~1% until 31 Oct, then ~5% -> ~19% by 4 Nov; dryer dew point -42 -> -16)
SELECT DATE(start_ts) d, ROUND(AVG(defect_rate_pct),2) FROM rca_demo_data.quality.v_batch_quality
WHERE site_id='EIN' AND line_id='L2' AND start_ts >= '2026-10-25' GROUP BY 1 ORDER BY 1;
SELECT reading_date, avg_value FROM rca_demo_data.maintenance.v_sensor_daily
WHERE equipment_id='DRY-EIN-L2-01' AND metric='dew_point_c' AND reading_date >= '2026-10-25' ORDER BY 1;
