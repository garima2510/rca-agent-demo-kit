import numpy as np, pandas as pd, random, json, os
from datetime import datetime, timedelta
rng=np.random.default_rng(42); random.seed(42)
BASE='kit/01_databricks/data'; os.makedirs(BASE,exist_ok=True)
SN='kit/03_servicenow'; os.makedirs(SN,exist_ok=True)

sites=pd.DataFrame([
 ['EIN','Eindhoven Plant','Netherlands','Europe/Amsterdam','Marieke de Vries'],
 ['BRN','Brno Plant','Czech Republic','Europe/Prague','Tomas Novak'],
 ['VAL','Valencia Plant','Spain','Europe/Madrid','Lucia Ferrer']],
 columns=['site_id','site_name','country','timezone','plant_manager'])
sites.to_csv(f'{BASE}/dim_site.csv',index=False)

eq=[]
for s in ['EIN','BRN','VAL']:
  for l in [1,2,3]:
    L=f'L{l}'
    for n in [1,2,3]:
      eq.append([f'IMM-{s}-{L}-0{n}',s,L,'Injection Moulding Machine','Engel victory 200' if n<3 else 'Arburg 570 A','A' if n==3 else 'B',f'20{18+n}-0{l+2}-15'])
    eq.append([f'DRY-{s}-{L}-01',s,L,'Resin Dryer','DryMax DX-400','A','2019-06-01'])
    eq.append([f'TCU-{s}-{L}-01',s,L,'Mould Temperature Controller','Thermocool TC-90','B','2020-02-10'])
    eq.append([f'HPU-{s}-{L}-01',s,L,'Hydraulic Power Unit','HydraPak HP-55','B','2018-11-20'])
equip=pd.DataFrame(eq,columns=['equipment_id','site_id','line_id','equipment_type','make_model','criticality','install_date'])
equip.to_csv(f'{BASE}/dim_equipment.csv',index=False)

# material lots
sup=['Polymerix GmbH','NordResin AB','IberPoly SA']
lots=[]; d0=datetime(2026,8,1)
for i in range(60):
  rd=d0+timedelta(days=int(i*1.6)); s=random.choice(sup)
  m=round(float(rng.normal(0.012,0.003)),3)
  lots.append([f'L-PC-26-{1100+i}','PC Makrolon-equiv. grade 2405',s,rd.date(),random.choice(['EIN','BRN','VAL']),max(m,0.005),'Accepted'])
lots.append(['L-PC-26-1187','PC Makrolon-equiv. grade 2405','Polymerix GmbH',datetime(2026,10,30).date(),'EIN',0.046,'Accepted - CoA moisture not checked'])
lots=pd.DataFrame(lots,columns=['lot_id','material','supplier','received_date','site_id','moisture_on_receipt_pct','incoming_status'])
lots.to_csv(f'{BASE}/dim_material_lot.csv',index=False)

# sensors hourly
start=datetime(2026,9,20); end=datetime(2026,11,5,0)
hours=pd.date_range(start,end,freq='h',inclusive='left')
rows=[]
def add(eid,metric,vals,unit):
  for t,v in zip(hours,vals): rows.append([eid,t,metric,round(float(v),2),unit])
for _,e in equip.iterrows():
  if e.site_id=='BRN' and e.line_id=='L3': continue
  N=len(hours); eid=e.equipment_id
  if e.equipment_type=='Resin Dryer':
    v=rng.normal(-42,1.5,N)
    if eid=='DRY-EIN-L2-01':
      t0=hours.get_loc(pd.Timestamp('2026-10-31 06:00')); t1=hours.get_loc(pd.Timestamp('2026-11-03 18:00'))
      for i in range(t0,N):
        frac=min(1,(i-t0)/(t1-t0)); v[i]=-42+frac*26+rng.normal(0,1.2)
    add(eid,'dew_point_c',v,'degC')
    add(eid,'drying_temp_c',rng.normal(120,1.0,N),'degC')
  elif e.equipment_type=='Injection Moulding Machine':
    add(eid,'barrel_temp_zone3_c',rng.normal(300,1.5,N),'degC')
    ct=rng.normal(38,0.6,N)
    if eid=='IMM-EIN-L1-02':
      i0=hours.get_loc(pd.Timestamp('2026-10-08 10:00')); ct[i0:i0+30]+=4
    add(eid,'cycle_time_s',ct,'s')
  elif e.equipment_type=='Mould Temperature Controller':
    add(eid,'mould_temp_c',rng.normal(85,0.8,N),'degC')
  else:
    p=rng.normal(160,2,N)
    if eid=='HPU-VAL-L1-01':
      i0=hours.get_loc(pd.Timestamp('2026-10-15 13:00')); p[i0:i0+6]=rng.normal(118,5,6)
    add(eid,'hydraulic_pressure_bar',p,'bar')
sens=pd.DataFrame(rows,columns=['equipment_id','reading_ts','metric','value','unit'])
sens.to_csv(f'{BASE}/fact_sensor_reading_hourly.csv',index=False)

# production batches + quality
prods={'L1':'HSG-220 Housing','L2':'CVR-115 Cover','L3':'BRK-310 Bracket'}
bat=[];qi=[];bid=0
einlots=[l for l in lots.lot_id if l!='L-PC-26-1187']
for day in pd.date_range('2026-09-20','2026-11-04'):
  for s in ['EIN','BRN','VAL']:
    for L in ['L1','L2','L3']:
      for shift,h in [('Early',6),('Late',14),('Night',22)]:
        bid+=1; st=day+timedelta(hours=h)
        lot=random.choice(einlots)
        if s=='EIN' and L=='L2' and st>=datetime(2026,10,31,6): lot='L-PC-26-1187'
        qty=int(rng.normal(2200,80))
        rate=max(0.004,rng.normal(0.012,0.003)); dtype='Mixed minor'
        disp='Released'
        if s=='EIN' and L=='L2' and st>=datetime(2026,11,1,6):
          k=(st-datetime(2026,11,1,6)).total_seconds()/3600/78
          rate=0.03+0.17*min(1,k)+rng.normal(0,0.01); dtype='Splay / silver streaks'; disp='Quarantined'
        if s=='EIN' and L=='L1' and datetime(2026,10,8,6)<=st<datetime(2026,10,9,6):
          rate=0.06; dtype='Short shot'
        if s=='VAL' and L=='L1' and datetime(2026,10,15,6)<=st<datetime(2026,10,15,22):
          rate=0.09; dtype='Short shot'
        good=int(qty*(1-rate))
        b=f'B-{s}{L}-{st:%y%m%d}-{shift[0]}'
        bat.append([b,s,L,prods[L],shift,st,st+timedelta(hours=8),qty,good,lot])
        qi.append([f'QI-{bid:06d}',b,st+timedelta(hours=8,minutes=15),dtype,qty-good,qty,round((qty-good)/qty*100,2),disp,'AQL 1.0 visual + drop test'])
pd.DataFrame(bat,columns=['batch_id','site_id','line_id','product','shift','start_ts','end_ts','qty_produced','qty_good','resin_lot_id']).to_csv(f'{BASE}/fact_production_batch.csv',index=False)
pd.DataFrame(qi,columns=['inspection_id','batch_id','inspected_ts','primary_defect_type','defect_count','sample_qty','defect_rate_pct','disposition','method']).to_csv(f'{BASE}/fact_quality_inspection.csv',index=False)

# downtime
dt=[];k=0
reasons=[('Mould change','Planned'),('Material changeover','Planned'),('Heater band fault','Electrical'),('Hydraulic leak','Mechanical'),('Robot gripper fault','Automation'),('Waiting for material','Logistics'),('Quality hold','Quality'),('Nozzle blockage','Process')]
for _ in range(420):
  e=equip[equip.equipment_type=='Injection Moulding Machine'].sample(1,random_state=int(rng.integers(1e9))).iloc[0]
  st=start+timedelta(minutes=int(rng.integers(0,45*24*60))); r=random.choice(reasons); dur=int(abs(rng.normal(45,30)))+5
  k+=1; dt.append([f'DT-{k:05d}',e.equipment_id,e.site_id,e.line_id,st,st+timedelta(minutes=dur),dur,r[0],r[1]])
for rec in [('IMM-EIN-L1-02',datetime(2026,10,8,9,40),210,'Heater band fault','Electrical'),
            ('HPU-VAL-L1-01',datetime(2026,10,15,13,5),340,'Hydraulic leak','Mechanical'),
            ('IMM-EIN-L2-01',datetime(2026,11,4,3,0),780,'Quality hold','Quality'),
            ('IMM-EIN-L2-02',datetime(2026,11,4,3,0),780,'Quality hold','Quality'),
            ('IMM-EIN-L2-03',datetime(2026,11,4,3,0),780,'Quality hold','Quality')]:
  k+=1; e=equip.set_index('equipment_id').loc[rec[0]]
  dt.append([f'DT-{k:05d}',rec[0],e.site_id,e.line_id,rec[1],rec[1]+timedelta(minutes=rec[2]),rec[2],rec[3],rec[4]])
pd.DataFrame(dt,columns=['downtime_id','equipment_id','site_id','line_id','start_ts','end_ts','duration_min','reason','category']).sort_values('start_ts').to_csv(f'{BASE}/fact_downtime_event.csv',index=False)

# work orders
wo=[];k=4000
techs=['J. Bakker','P. Svoboda','A. Martinez','S. Jansen','K. Dvorak','M. Lopez']
for _,e in equip.iterrows():
  for d in pd.date_range('2026-06-01','2026-11-04',freq='28D'):
    k+=1; pd_=d+timedelta(days=int(rng.integers(0,10)))
    desc={'Resin Dryer':'PM: desiccant regeneration check, dew point sensor verification, filter replacement (SOP-MNT-021)',
          'Injection Moulding Machine':'PM: lubrication, heater band resistance check, screw/barrel inspection',
          'Mould Temperature Controller':'PM: flush circuit, check pump & flow',
          'Hydraulic Power Unit':'PM: hose inspection, oil sample, filter change'}[e.equipment_type]
    status='Completed'; comp=pd_+timedelta(days=int(rng.integers(0,3))); note=''
    if pd_>datetime(2026,11,4): continue
    if e.equipment_id=='DRY-EIN-L2-01' and datetime(2026,10,15)<=pd_<=datetime(2026,11,4):
      status='Deferred'; comp=None; note='Spare desiccant cartridge DX-400-DC not in stock; re-planned awaiting parts'
    wo.append([f'WO-{e.site_id}-26-{k:05d}',e.equipment_id,e.site_id,'Preventive',desc,pd_.date(),comp.date() if comp is not None else None,status,random.choice(techs),note,None])
cms=[('IMM-EIN-L1-02','2026-10-08','CM: replace failed heater band zone 3','Completed','J. Bakker','INC0019102'),
     ('HPU-VAL-L1-01','2026-10-15','CM: replace ruptured high-pressure hose, top up oil','Completed','A. Martinez','INC0019355'),
     ('DRY-EIN-L2-01','2026-11-04','CM: investigate high dew point, inspect desiccant wheel','Open','S. Jansen','INC0019874')]
for c in cms:
  k+=1; e=equip.set_index('equipment_id').loc[c[0]]
  wo.append([f'WO-{e.site_id}-26-{k:05d}',c[0],e.site_id,'Corrective',c[2],c[1],c[1] if c[3]=='Completed' else None,c[3],c[4],'',c[5]])
pd.DataFrame(wo,columns=['work_order_id','equipment_id','site_id','wo_type','description','planned_date','completed_date','status','technician','status_note','servicenow_incident']).to_csv(f'{BASE}/fact_maintenance_work_order.csv',index=False)

# ServiceNow incidents
inc=[]
templ=[('Short shots on {e}','Short shot defects observed; suspected heater/pressure issue','Production Engineering','Equipment'),
 ('Robot gripper fault {e}','Takeout robot dropping parts','Automation Support','Equipment'),
 ('MES not receiving cycle counts from {e}','OPC-UA connection drop','OT Support','Software'),
 ('Flash on parts from {e}','Excess flash at parting line','Production Engineering','Process'),
 ('Hydraulic oil leak {e}','Minor oil leak at pump flange','Maintenance','Equipment'),
 ('Mould temperature alarm {e}','TCU over-temperature alarm','Maintenance','Equipment'),
 ('Label printer offline line {l}','Packaging label printer offline','IT Field Services','Hardware')]
n=14000
for i in range(70):
  t=random.choice(templ); e=equip[equip.equipment_type=='Injection Moulding Machine'].sample(1,random_state=i).iloc[0]
  op=datetime(2025,1,5)+timedelta(hours=int(rng.integers(0,22*30*24)))
  pr=random.choices([2,3,4],[0.15,0.55,0.30])[0]; n+=int(rng.integers(30,90))
  inc.append(dict(number=f'INC00{n}',opened_at=op,priority=f'{pr} - '+{2:'High',3:'Moderate',4:'Low'}[pr],
    short_description=t[0].format(e=e.equipment_id,l=e.line_id),description=t[1],cmdb_ci=e.equipment_id,location=e.site_id,
    category=t[3],assignment_group=t[2],state='Closed',resolved_at=op+timedelta(hours=int(rng.integers(2,72))),
    close_code='Solved (Permanently)',close_notes='Fixed and verified by shift lead',problem_id='',u_rca_reference=''))
key=[
 dict(number='INC0014211',opened_at=datetime(2025,6,12,4,20),priority='1 - Critical',short_description='Splay / silver streaks on CVR-115 covers, Brno Line 1 - batches quarantined',description='Night shift found silver streaks and brittle failures in drop test on CVR-115. 3 batches quarantined. Customer shipment at risk.',cmdb_ci='IMM-BRN-L1-03',location='BRN',category='Quality',assignment_group='Quality Engineering',state='Closed',resolved_at=datetime(2025,6,14,16,0),close_code='Solved (Permanently)',close_notes='Root cause: resin dryer DRY-BRN-L1-01 desiccant saturated; dew point drifted to -15C. Desiccant replaced, alarm threshold lowered to -30C with interlock. See RCA-2025-014.',problem_id='PRB0004410',u_rca_reference='RCA-2025-014'),
 dict(number='INC0015830',opened_at=datetime(2025,9,3,14,5),priority='2 - High',short_description='Line stopped - hydraulic hose rupture HPU-VAL-L2-01',description='High pressure hose burst; oil on floor; line 2 stopped.',cmdb_ci='HPU-VAL-L2-01',location='VAL',category='Equipment',assignment_group='Maintenance',state='Closed',resolved_at=datetime(2025,9,3,22,0),close_code='Solved (Permanently)',close_notes='Hose replaced. Hose age 6 yrs, beyond 5-yr replacement interval. See RCA-2025-022.',problem_id='PRB0004502',u_rca_reference='RCA-2025-022'),
 dict(number='INC0016502',opened_at=datetime(2026,2,17,9,30),priority='2 - High',short_description='Brittle BRK-310 brackets - customer complaint, Valencia Line 3',description='Customer reported cracked brackets at assembly. Retained samples show low impact strength.',cmdb_ci='IMM-VAL-L3-01',location='VAL',category='Quality',assignment_group='Quality Engineering',state='Closed',resolved_at=datetime(2026,2,24,12,0),close_code='Solved (Permanently)',close_notes='Resin lot from Polymerix GmbH arrived with 0.05% moisture; drying time insufficient. Supplier CAPA raised; incoming CoA moisture check introduced at VAL. See RCA-2026-007.',problem_id='PRB0004633',u_rca_reference='RCA-2026-007'),
 dict(number='INC0017140',opened_at=datetime(2026,4,2,11,10),priority='2 - High',short_description='Short shots and line stop IMM-EIN-L1-02',description='Zone 3 temperature unable to reach set point.',cmdb_ci='IMM-EIN-L1-02',location='EIN',category='Equipment',assignment_group='Production Engineering',state='Closed',resolved_at=datetime(2026,4,2,18,0),close_code='Solved (Permanently)',close_notes='Heater band zone 3 failed. Replaced. See RCA-2026-003.',problem_id='PRB0004701',u_rca_reference='RCA-2026-003'),
 dict(number='INC0018077',opened_at=datetime(2026,6,22,7,45),priority='2 - High',short_description='Sink marks and warpage HSG-220, Brno Line 2',description='Dimensional failures on HSG-220; mould temp uneven.',cmdb_ci='TCU-BRN-L2-01',location='BRN',category='Quality',assignment_group='Production Engineering',state='Closed',resolved_at=datetime(2026,6,25,10,0),close_code='Solved (Permanently)',close_notes='Cooling channel partially blocked by scale. Flushed; water treatment check added to PM. See RCA-2026-009.',problem_id='PRB0004788',u_rca_reference='RCA-2026-009'),
 dict(number='INC0019102',opened_at=datetime(2026,10,8,9,45),priority='3 - Moderate',short_description='Short shots IMM-EIN-L1-02 zone 3',description='Zone 3 heater fault again.',cmdb_ci='IMM-EIN-L1-02',location='EIN',category='Equipment',assignment_group='Maintenance',state='Closed',resolved_at=datetime(2026,10,8,13,15),close_code='Solved (Permanently)',close_notes='Heater band replaced (repeat failure, see RCA-2026-003).',problem_id='',u_rca_reference=''),
 dict(number='INC0019355',opened_at=datetime(2026,10,15,13,10),priority='2 - High',short_description='Hydraulic hose rupture HPU-VAL-L1-01, Line 1 stopped',description='Pressure dropped to ~118 bar, short shots then line stop.',cmdb_ci='HPU-VAL-L1-01',location='VAL',category='Equipment',assignment_group='Maintenance',state='Resolved',resolved_at=datetime(2026,10,15,18,45),close_code='Solved (Work Around)',close_notes='Hose replaced. RCA pending.',problem_id='',u_rca_reference=''),
 dict(number='INC0019874',opened_at=datetime(2026,11,4,3,10),priority='1 - Critical',short_description='Splay / silver streaks and brittle CVR-115 covers, Eindhoven Line 2 - all L2 output quarantined',description='Night shift QC found silver streaks on CVR-115 covers from all three Line 2 machines; drop test failures. Defect rate climbing since 1 Nov. All Line 2 output since 1 Nov quarantined (approx. 20k parts). Customer delivery on Fri 6 Nov at risk.',cmdb_ci='IMM-EIN-L2-03',location='EIN',category='Quality',assignment_group='Quality Engineering',state='In Progress',resolved_at=None,close_code='',close_notes='',problem_id='',u_rca_reference=''),
]
df=pd.DataFrame(inc+key).sort_values('opened_at')
df.to_csv(f'{SN}/servicenow_incidents.csv',index=False)
df.to_json(f'{SN}/servicenow_incidents.json',orient='records',date_format='iso',indent=1)
prb=pd.DataFrame([
 ['PRB0004410','Resin dryer desiccant saturation causes moisture-related defects','RCA-2025-014','Closed/Resolved','INC0014211'],
 ['PRB0004502','Hydraulic hoses exceeding replacement interval','RCA-2025-022','Closed/Resolved','INC0015830'],
 ['PRB0004633','Incoming resin lots exceeding moisture spec','RCA-2026-007','Closed/Resolved','INC0016502'],
 ['PRB0004701','Repeat heater band failures zone 3 EIN-L1-02','RCA-2026-003','Fix in progress','INC0017140;INC0019102'],
 ['PRB0004788','Mould cooling channel scaling','RCA-2026-009','Closed/Resolved','INC0018077']],
 columns=['number','short_description','u_rca_reference','state','related_incidents'])
prb.to_csv(f'{SN}/servicenow_problems.csv',index=False)
print(len(sens),len(bat),len(dt),len(wo),len(df))
