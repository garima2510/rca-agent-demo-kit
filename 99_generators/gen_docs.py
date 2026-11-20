import os, re
from reportlab.lib.pagesizes import A4
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib import colors
from reportlab.lib.units import cm
ss=getSampleStyleSheet()
H1=ParagraphStyle('h1',parent=ss['Heading1'],textColor=colors.HexColor('#1F3864'),fontSize=16)
H2=ParagraphStyle('h2',parent=ss['Heading2'],textColor=colors.HexColor('#1F3864'),fontSize=12.5)
B=ParagraphStyle('b',parent=ss['BodyText'],fontSize=9.5,leading=13)
SM=ParagraphStyle('sm',parent=B,fontSize=8.5,leading=11)
def inline(t):
  t=t.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
  return re.sub(r'\*\*(.+?)\*\*',r'<b>\1</b>',t)
def pdf(path,md,header):
  os.makedirs(os.path.dirname(path),exist_ok=True)
  st=[];lines=md.strip().split('\n');i=0
  while i<len(lines):
    l=lines[i].rstrip()
    if l.startswith('# '): st.append(Paragraph(inline(l[2:]),H1))
    elif l.startswith('## '): st.append(Paragraph(inline(l[3:]),H2))
    elif l.startswith('|'):
      rows=[]
      while i<len(lines) and lines[i].startswith('|'):
        c=[x.strip() for x in lines[i].strip('|').split('|')]
        if not set(''.join(c))<=set('-: '): rows.append([Paragraph(inline(x),SM) for x in c])
        i+=1
      t=Table(rows,repeatRows=1,colWidths=[(17/len(rows[0]))*cm]*len(rows[0]))
      t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),colors.HexColor('#D9E2F3')),('GRID',(0,0),(-1,-1),0.4,colors.grey),('VALIGN',(0,0),(-1,-1),'TOP')]))
      st+= [t,Spacer(1,6)]; continue
    elif l.startswith('- '): st.append(Paragraph('• '+inline(l[2:]),B))
    elif l.strip()=='' : st.append(Spacer(1,4))
    else: st.append(Paragraph(inline(l),B))
    i+=1
  def hf(c,d):
    c.saveState();c.setFont('Helvetica',7.5);c.setFillColor(colors.grey)
    c.drawString(2*cm,28.6*cm,'Fabrikam Components B.V. - '+header);c.drawRightString(19*cm,1.2*cm,'Page %d  |  SYNTHETIC DEMO DATA'%d.page);c.restoreState()
  SimpleDocTemplate(path,pagesize=A4,topMargin=2*cm,bottomMargin=2*cm,leftMargin=2*cm,rightMargin=2*cm).build(st,onFirstPage=hf,onLaterPages=hf)

K='kit/02_foundry_iq_blob'
docs={}
docs['rca-reports/RCA-2025-014_Brno_L1_Dryer_Desiccant_Saturation.pdf']=('RCA Report - Controlled','''
# RCA-2025-014: Splay defects on CVR-115 - Brno Line 1
| Field | Value |
|---|---|
| Incident | INC0014211 (P1) / Problem PRB0004410 |
| Site / Line | Brno Plant (BRN) / Line 1 |
| Equipment | IMM-BRN-L1-03, Resin dryer DRY-BRN-L1-01 (DryMax DX-400) |
| Date of event | 12 June 2025 |
| RCA lead | Petr Svoboda (Quality Engineering) |
| Status | Approved - 20 June 2025 by Tomas Novak (Plant Manager) |
## 1. Problem statement
Night shift QC detected silver streaks (splay) on CVR-115 covers and brittle failures in the 1.2 m drop test. Defect rate rose from a 1.1% baseline to 17% over 72 hours. Three batches (6,400 parts) quarantined; one customer shipment delayed by 2 days.
## 2. Containment
- All Line 1 output since last good batch quarantined and 100% inspected.
- Resin re-dried in a spare dryer for 4 h at 120 C; moisture verified below 0.02% before restart.
## 3. Evidence
- Dryer DRY-BRN-L1-01 dew point drifted from -40 C to -15 C over 3 days. OEM alarm default (-20 C) triggered only on day 3 and was acknowledged by operators without escalation.
- Desiccant cartridge had 11,200 operating hours; OEM recommended life is 8,000 h. Preventive maintenance had been deferred twice due to missing spare parts.
- Barrel temperatures, mould temperature and cycle time were within limits (ruled out as causes).
- Resin lot moisture on receipt was within spec (0.011%).
## 4. 5-Why analysis
- Why splay? Moisture in polycarbonate hydrolyses during melting and forms gas streaks.
- Why moisture? Dryer could not reach target dew point (-40 C).
- Why? Desiccant saturated - past its service life.
- Why not replaced? PM deferred twice; spare cartridge not stocked as critical spare.
- Why not detected earlier? Alarm threshold at OEM default -20 C, no interlock, no escalation rule.
## 5. Root cause
**Primary:** Saturated desiccant in resin dryer due to deferred PM. **Contributing:** alarm threshold too permissive with no interlock; dryer desiccant cartridge not classified as critical spare.
## 6. Corrective and preventive actions (CAPA)
| # | Action | Owner | Due | Status |
|---|---|---|---|---|
| 1 | Replace desiccant cartridge, verify dew point | Maintenance BRN | 14-Jun-2025 | Done |
| 2 | Lower dew point alarm to -30 C and add machine interlock at -25 C | Automation BRN | 30-Jun-2025 | Done (BRN) |
| 3 | Add DX-400 desiccant cartridge to critical spares list (min stock 2 per site) | Central Maintenance | 31-Aug-2025 | Done (BRN), open at EIN and VAL |
| 4 | PM deferral of Class-A equipment requires Maintenance Manager approval | Central Maintenance | 30-Sep-2025 | Done |
| 5 | Roll out actions 2 and 3 to Eindhoven and Valencia | Group Engineering | Q1 2026 | VAL done; **EIN open** |
## 7. Lessons learned
Shared as Lessons Learned bulletin LL-2025-06. Moisture-related defects develop over 2-4 days and are visible in dryer dew point trends well before quality impact.
''')
docs['rca-reports/RCA-2025-022_Valencia_L2_Hydraulic_Hose_Rupture.pdf']=('RCA Report - Controlled','''
# RCA-2025-022: Hydraulic hose rupture - Valencia Line 2
| Field | Value |
|---|---|
| Incident | INC0015830 (P2) / PRB0004502 |
| Equipment | HPU-VAL-L2-01 (HydraPak HP-55) |
| Date | 3 September 2025 |
| Status | Approved 12 Sep 2025 |
## Problem statement
High-pressure hose burst, 8 h line stop, 40 l oil spill. No injuries.
## Evidence
- Hydraulic pressure dropped from 160 bar to ~115 bar in the 20 minutes before rupture; short shots observed.
- Hose installed 2019 (6 years); internal standard is replacement every 5 years.
- Hose replacement interval was not in the CMMS PM plan, only in the OEM manual.
## Root cause
Hose exceeded service life because the replacement interval was not loaded into the maintenance plan.
## CAPA
| # | Action | Owner | Status |
|---|---|---|---|
| 1 | Replace all HPU hoses older than 5 yrs at all sites | Central Maintenance | Done |
| 2 | Add 5-year hose replacement task to CMMS for all HPUs | Central Maintenance | Done |
| 3 | Add pressure-drop alert (>15% in 10 min) on HPU sensors | OT / Data team | Done |
''')
docs['rca-reports/RCA-2026-003_Eindhoven_L1_Heater_Band_Failure.pdf']=('RCA Report - Controlled','''
# RCA-2026-003: Short shots - heater band failure IMM-EIN-L1-02
| Field | Value |
|---|---|
| Incident | INC0017140 (P2) / PRB0004701 |
| Date | 2 April 2026 |
| Status | Approved 10 Apr 2026 - effectiveness check OPEN |
## Problem statement
Zone 3 barrel temperature could not reach set point (300 C); short shots, 7 h downtime.
## Root cause
Heater band failure caused by loose terminal connection (thermal cycling). Torque check not part of PM.
## CAPA
| # | Action | Status |
|---|---|---|
| 1 | Replace heater band | Done |
| 2 | Add terminal torque check to quarterly PM | Done |
| 3 | Effectiveness check after 6 months | Open - note: repeat failure 8 Oct 2026 (INC0019102) |
''')
docs['rca-reports/RCA-2026-007_Valencia_L3_Resin_Lot_Moisture.pdf']=('RCA Report - Controlled','''
# RCA-2026-007: Brittle BRK-310 brackets - customer complaint
| Field | Value |
|---|---|
| Incident | INC0016502 (P2) / PRB0004633 |
| Site / Line | Valencia (VAL) / Line 3 |
| Supplier | Polymerix GmbH, lot L-PC-26-0412 |
| Status | Approved 3 Mar 2026 |
## Problem statement
Customer reported cracked BRK-310 brackets at assembly. Impact strength of retained samples 40% below spec.
## Evidence
- Resin lot arrived with 0.05% moisture (supplier spec max 0.02% as shipped). Packaging liner damaged in transit.
- Standard drying time (4 h at 120 C) insufficient for this moisture level; dryer itself performed normally (dew point -41 C).
- No incoming moisture check: Certificate of Analysis (CoA) moisture value was not reviewed at goods receipt.
## Root cause
Wet incoming resin lot combined with no incoming moisture verification.
## CAPA
| # | Action | Owner | Status |
|---|---|---|---|
| 1 | Supplier CAPA with Polymerix GmbH (packaging, CoA) | Purchasing | Done |
| 2 | Goods receipt: review CoA moisture; if above 0.02% extend drying to 6 h and test | Quality VAL | Done (VAL only) |
| 3 | Evaluate rollout of incoming moisture check to EIN and BRN | Group Quality | **Open** |
''')
docs['rca-reports/RCA-2026-009_Brno_L2_Mould_Cooling_Blockage.pdf']=('RCA Report - Controlled','''
# RCA-2026-009: Sink marks and warpage HSG-220 - Brno Line 2
| Field | Value |
|---|---|
| Incident | INC0018077 (P2) / PRB0004788 |
| Equipment | TCU-BRN-L2-01, mould M-HSG220-04 |
| Status | Approved 2 Jul 2026 |
## Root cause
Cooling channel 3 partially blocked by calcium scale; water treatment dosing pump failed unnoticed.
## CAPA
- Flush all mould circuits; add water hardness check to weekly PM; alarm on TCU flow below 12 l/min.
''')
docs['procedures/SOP-RCA-001_Root_Cause_Analysis_Procedure.pdf']=('SOP - Controlled','''
# SOP-RCA-001: Root Cause Analysis Procedure (rev. 4)
## 1. Scope and triggers
An RCA is mandatory for every P1 incident and for P2 incidents with quality impact or more than 4 h downtime. A draft RCA must be available within 24 hours of incident opening and approved within 10 working days.
## 2. Roles
- **RCA lead:** Quality Engineer (quality events) or Maintenance Engineer (equipment events).
- **Approver:** Plant Manager. No RCA is official until approved.
## 3. Standard RCA questions (to be answered in every RCA)
- Q1. What exactly happened, where, when, and what is the impact (scrap, downtime, customer)?
- Q2. When did the problem start? What is the last known good batch/time?
- Q3. What changed before the event (material lot, supplier, settings, maintenance, people, shift)?
- Q4. Which equipment and process parameters were out of normal range?
- Q5. Was maintenance on the involved equipment up to date? Any deferred or overdue work orders?
- Q6. Have similar incidents occurred at this or another site? What were their root causes and CAPAs?
- Q7. Were alarms raised and how were they handled?
- Q8. Which causes can be ruled out, and based on what evidence?
- Q9. What is the root cause and what are contributing causes (5-Why)?
- Q10. Which corrective and preventive actions are proposed, and are lessons from earlier RCAs fully implemented at this site?
## 4. Method
Use 5-Why for single-path causes and Ishikawa (Man, Machine, Method, Material, Measurement, Environment) for complex events. Every conclusion must reference evidence (data, work order, document, interview).
## 5. Output
Use template TPL-RCA-002. Store approved RCA in the RCA library and link it to the ServiceNow incident and problem record.
''')
docs['procedures/SOP-MNT-021_Resin_Dryer_Preventive_Maintenance.pdf']=('SOP - Controlled','''
# SOP-MNT-021: Resin Dryer Preventive Maintenance (DryMax DX-400)
## Frequency
Every 4 weeks (Class A equipment). Deferral requires Maintenance Manager approval (since Sep 2025, CAPA RCA-2025-014).
## Tasks
- Verify dew point sensor against reference hygrometer.
- Check desiccant operating hours; replace cartridge DX-400-DC at 8,000 h or when dew point cannot reach -40 C.
- Replace inlet filter; check regeneration heater current.
## Alarm settings (group standard after RCA-2025-014)
| Parameter | OEM default | Group standard |
|---|---|---|
| Dew point warning | -20 C | -30 C |
| Dew point interlock (stop feed) | none | -25 C |
## Critical spares
DX-400-DC desiccant cartridge: minimum stock 2 per site.
''')
docs['procedures/SOP-QA-007_Nonconforming_Product_Quarantine.pdf']=('SOP - Controlled','''
# SOP-QA-007: Nonconforming Product and Quarantine
- Quarantine all output back to the last known good batch.
- Splay/silver streaks on polycarbonate parts: treat as potential moisture issue; perform drop test (1.2 m) on 32 parts per batch.
- Release only after 100% inspection or Quality Manager deviation approval.
- Notify the customer within 24 h if a confirmed shipment is at risk.
''')
docs['manuals/DryMax_DX-400_Manual_Excerpt.pdf']=('OEM Documentation','''
# DryMax DX-400 Desiccant Dryer - Operating Manual (excerpt)
## Dew point
Target dew point for polycarbonate: -40 C or lower. A dew point above -30 C indicates reduced drying capacity; above -20 C the material must be considered insufficiently dried.
## Desiccant life
Desiccant cartridge service life is approx. 8,000 operating hours. Symptoms of saturation: gradual dew point rise over 1-5 days, longer regeneration cycles.
## Troubleshooting
| Symptom | Likely cause | Action |
|---|---|---|
| Gradual dew point rise | Desiccant saturated / regeneration heater weak | Check hours, replace cartridge |
| Sudden dew point rise | Air leak, open hopper lid, valve failure | Inspect seals, valves |
| Normal dew point but splay | Wet incoming material / insufficient residence time | Check material moisture, extend drying |
''')
docs['lessons-learned/LL-2025-06_Moisture_Defects_Bulletin.pdf']=('Lessons Learned','''
# Lessons Learned Bulletin LL-2025-06: Moisture defects in polycarbonate
Distributed to: all plant managers, maintenance and quality managers (July 2025).
## Key messages
- Dew point trends show moisture problems 2-4 days before defects appear.
- Do not accept OEM default alarm (-20 C). Use group standard -30 C warning, -25 C interlock.
- Keep DX-400 desiccant cartridges as critical spares.
- Check CoA moisture on incoming resin lots (see also RCA-2026-007, added Mar 2026).
## Site implementation status (Group Engineering tracker, last update Oct 2026)
| Site | Alarm/interlock | Critical spares | Incoming CoA check |
|---|---|---|---|
| Brno | Done | Done | Open |
| Valencia | Done | Done | Done |
| Eindhoven | **Open - planned Q1 2026, not executed** | **Open** | Open |
''')
docs['templates/TPL-RCA-002_RCA_Report_Template.pdf']=('Template','''
# TPL-RCA-002: RCA Report Template
## Header
Incident / Problem number, site, line, equipment, date, RCA lead, approver, status (Draft / Approved).
## Sections
- 1. Problem statement (what, where, when, impact)
- 2. Containment actions
- 3. Timeline of events
- 4. Evidence (data, work orders, alarms, documents) - each item with its source
- 5. Causes ruled out
- 6. 5-Why / Ishikawa
- 7. Root cause and contributing causes
- 8. CAPA table (action, owner, due date, status)
- 9. Links to similar incidents and earlier RCAs
- 10. Approval
''')
for p,(h,md) in docs.items(): pdf(f'{K}/{p}',md,h)

# communications: shift logs + Teams export (text)
os.makedirs(f'{K}/communications',exist_ok=True)
open(f'{K}/communications/EIN_L2_Shift_Handover_Log_2026-10-30_to_11-04.txt','w').write('''Fabrikam Components - Eindhoven Plant - Line 2 shift handover log (SYNTHETIC DEMO DATA)

2026-10-30 Late  | Lead: R. Visser | New resin lot L-PC-26-1187 (Polymerix) received and loaded to dryer hopper DRY-EIN-L2-01 from 31-Oct early shift. Running normal.
2026-10-31 Early | Lead: S. Jansen | Lot 1187 in use. All 3 machines running. Dryer PM still open - waiting for desiccant cartridge (purchasing says delivery mid Nov).
2026-10-31 Night | Lead: D. Peeters | Normal. Dryer regeneration cycle seems longer than usual.
2026-11-01 Early | Lead: S. Jansen | Few cosmetic streaks on CVR-115 from L2-03, within limit. Adjusted back pressure +5 bar.
2026-11-01 Night | Lead: D. Peeters | Dryer L2 display shows dew point -29 C at 02:40, no alarm (alarm still at OEM default -20 C). Continued production.
2026-11-02 Late  | Lead: R. Visser | Streaks increasing on all L2 machines. Increased melt temp +5 C on L2-01 and L2-02 - no improvement. Informed QC.
2026-11-03 Early | Lead: S. Jansen | QC flagged 12% defects. Dryer dew point alarm (-20 C) active since ~05:00, acknowledged several times. Maintenance asked to look at dryer - no technician available until Monday.
2026-11-04 Night | Lead: D. Peeters | Drop test failures. QC stopped line 2 at 03:00, all output since 1 Nov quarantined. P1 ticket INC0019874 raised.
''')
open(f'{K}/communications/Teams_Export_EIN_Quality_Channel_2026-11-04.txt','w').write('''Teams channel export: "EIN Quality & Production" (SYNTHETIC DEMO DATA)

[04-11-2026 06:55] Anouk Smit (Quality Manager EIN): Line 2 stopped, ~20k CVR-115 covers in quarantine. Customer delivery Friday 6 Nov at risk. Need root cause today.
[04-11-2026 07:10] Sander Jansen (Maintenance): Dryer L2 dew point is at -16 C. PM on that dryer was deferred, cartridge not in stock. Could be same as Brno last year?
[04-11-2026 07:22] Anouk Smit: Also lot 1187 is from Polymerix - same supplier as Valencia brittle bracket case. Did anyone check the CoA moisture?
[04-11-2026 07:40] Goods receipt (Eindhoven): We don't check CoA moisture at EIN. CoA for 1187 says 0.046%.
[04-11-2026 08:05] Marieke de Vries (Plant Manager): Please prepare RCA draft per SOP-RCA-001 for review tomorrow 09:00. Borrow a cartridge from Brno.
''')
print('docs ok')
