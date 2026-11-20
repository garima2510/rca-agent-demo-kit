# Genie space configuration (mirrors the customer's split into Maintenance and Quality spaces)

Use a serverless SQL warehouse. Create two spaces. Note each space ID (in the URL: .../genie/rooms/<space_id>) - you need it in Foundry.

Use catalog `rca_demo_data` and warehouse **RCA Demo Serverless**. The data covers 20 September through 4 November 2026; use explicit dates in demo questions.

## Space 1 - "RCA Maintenance"
Tables: rca_demo_data.plant.dim_site, rca_demo_data.plant.dim_equipment, rca_demo_data.maintenance.fact_sensor_reading_hourly,
rca_demo_data.maintenance.v_sensor_daily, rca_demo_data.maintenance.fact_downtime_event, rca_demo_data.maintenance.fact_maintenance_work_order

General instructions:
- Sites: EIN = Eindhoven, BRN = Brno, VAL = Valencia. Lines L1-L3. Equipment id format <TYPE>-<SITE>-<LINE>-<NN>.
- Equipment types: IMM = injection moulding machine, DRY = resin dryer, TCU = mould temperature controller, HPU = hydraulic power unit.
- Resin dryer dew point: normal <= -40 C, warning above -30 C, material considered wet above -20 C.
- Hydraulic pressure normal ~160 bar; a drop of >15% is abnormal.
- "Overdue" PM = wo_type 'Preventive' with status 'Deferred' or not completed by planned_date.
- Prefer v_sensor_daily for trends longer than 2 days; use hourly table for exact onset times.

Sample questions / trusted SQL:
- "Show the daily dew point of DRY-EIN-L2-01 from 25 October to 4 November 2026"
- "Are there deferred or open work orders on equipment of Eindhoven line 2?"
  SELECT * FROM rca_demo_data.maintenance.fact_maintenance_work_order WHERE site_id='EIN' AND equipment_id LIKE '%-EIN-L2-%' AND status <> 'Completed' ORDER BY planned_date DESC
- "When did the dew point of DRY-EIN-L2-01 first exceed -30 C?"
  SELECT MIN(reading_ts) FROM rca_demo_data.maintenance.fact_sensor_reading_hourly WHERE equipment_id='DRY-EIN-L2-01' AND metric='dew_point_c' AND value > -30 AND reading_ts >= '2026-10-25'
- "Were barrel temperatures and cycle times normal on EIN line 2 machines since 28 Oct?"

## Space 2 - "RCA Quality"
Tables: rca_demo_data.plant.dim_site, rca_demo_data.plant.dim_equipment, rca_demo_data.quality.fact_production_batch,
rca_demo_data.quality.fact_quality_inspection, rca_demo_data.quality.dim_material_lot, rca_demo_data.quality.v_batch_quality

Optional: add `rca_demo_data.quality.mv_quality_kpis` only after explicitly creating the optional metric view in [setup_unity_catalog.sql](setup_unity_catalog.sql). It is not required for the base demo.

General instructions:
- Defect rate baseline is ~1.2%. Above 3% is abnormal.
- Resin moisture spec on receipt: max 0.02%.
- "Last known good batch" = latest batch on that line with defect_rate_pct < 3 before the problem started.

Sample questions:
- "Daily defect rate for Eindhoven line 2 since 25 October, with primary defect type"
- "Which resin lot was used on EIN L2 batches since 30 October and what was its moisture on receipt?"
- "How many parts are quarantined on Eindhoven line 2?"
- "What is the last known good batch on EIN L2?"
- "Which lots from Polymerix GmbH had moisture above spec?"
