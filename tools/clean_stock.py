import csv, re, sys, collections
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment

SRC, OUTDIR = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(SRC, encoding='utf-8')))

# Spelling variants -> one brand name. "sure" = obvious typo, else flagged for owner check.
BRAND_MAP = {
    'BLACK CHERY': ('BLACK CHERRY', True), 'ZARRA': ('ZARA', True), 'JUBLEEE': ('JUBLEE', True),
    'PALIN BOX FIT': ('PLAIN BOX FIT', True), 'GSTAR': ('G STAR', True), 'GSTASR': ('G STAR', True),
    '3BROTHER': ('3 BROTHERS', True), '3BROTHERS': ('3 BROTHERS', True), 'JACKOFF': ('JACK OFF', True),
    'LIKVID': ('LIQUID', True), 'ARTICAL': ('ARTICLE', True), 'JULIAN': ('JULIEN', True),
    'JULLIAN': ('JULIEN', True), 'ELBORN': ('ELEBORN', True), 'COOL DIET': ('COOL DUET', True),
    'COOL DUED': ('COOL DUET', True), 'REDVELVET': ('RED VELVET', True), 'ZAM ZAM': ('ZAMZAM', True),
    'GREEN SQR': ('GREEN SQUARE', True), 'KG 9': ('KG9', True), 'RR1-0': ('RR10', True),
    'RR10N': ('RR10', True), 'REACOVERY': ('RECOVERY', True), 'RECVERY': ('RECOVERY', True),
    'PURPLEN': ('PURPLE', True), 'CHEERPO': ('CHEERPRO', True), 'TOMMY': ('TOMMY HILFIGER', True),
    'CARRY ONN': ('CARRY ON', True), 'PPOTTER': ('POTTER', True), 'EMBRODRY': ('EMBROIDERY', True),
    'MATRIJX': ('METRIX', True), 'HHP': ('HPP', True), 'G S': ('G&S', True), 'GS': ('G&S', True),
    'CARRY': ('CARRY ON', True), 'RAJSHRI ROYAL': ('RAJSI ROYAL', True), 'AJ': ('AJ STUDIO', True),
    'COOL': ('COOL DUET', True), 'DX DENIM': ('DX', True), 'SMART': ('SMART CITY', True),
    'CHEER UP': ('CHEER UP', True),
}
TYPE_WORDS = [('SHIRTS', 'Shirt'), ('SHIRT', 'Shirt'), ('SAHIRT', 'Shirt'), ('JEANAS', 'Jeans'),
              ('JEANS', 'Jeans'), ('KURTA', 'Kurta'), ('CARGO', 'Cargo')]
SIZE_ORDER = ['S', 'M', 'L', 'XL', 'XXL', 'XXXL']

out, review, merges = [], [], collections.Counter()
seen_codes = collections.defaultdict(list)

def flag(rec, msg):
    rec['notes'].append(msg)

for n, r in enumerate(rows, start=2):
    raw = re.sub(r'\s+', ' ', r['Name'].strip().upper().lstrip('#'))
    color = r['Color'].strip().upper()
    color = '' if color == '-' else color
    rec = {'line': n, 'barcode': r['Barcode'].strip(), 'orig_name': r['Name'], 'notes': []}

    # Pull colour / sleeve words out of the name
    if raw.endswith(' WHITE'):
        raw, color = raw[:-6], 'WHITE'
    sleeve = ''
    if raw.endswith(' HALF'):
        raw, sleeve = raw[:-5], 'Half sleeve'

    gtype = ''
    for w, t in TYPE_WORDS:
        m = re.search(r'\b' + w + r'\b', raw)
        if m:
            gtype = t
            raw = (raw[:m.start()] + raw[m.end():]).strip()
            break
    brand = raw.strip()
    if brand in ('NAVY BLUE', 'BLACK') and not color:
        color, brand = brand, ''
    if brand == 'SHORT' and gtype == 'Kurta':
        brand, gtype = '', 'Short Kurta'
    if brand in BRAND_MAP:
        new, sure = BRAND_MAP[brand]
        if new != brand:
            merges[(brand, new, sure)] += 1
            if not sure:
                flag(rec, f'Brand "{brand}" merged into "{new}" - please confirm')
            brand = new
    if brand == 'EMBROIDERY':
        flag(rec, 'Name is a style (Embroidery), no brand given')

    size_raw = r['Size'].strip().upper()
    if brand in ('BOX FIT', 'LINING BOX FIT', 'PLAIN BOX FIT') and not gtype:
        gtype = 'T-Shirt'
    if not gtype:
        if re.fullmatch(r'\d+', size_raw):
            gtype = 'Jeans'
        else:
            gtype = 'Shirt'
        flag(rec, f'Item type not in name, assumed {gtype}')
    if gtype == 'Jeans' and re.fullmatch(r'[SMLX]+', size_raw):
        flag(rec, f'Jeans with letter size {size_raw} - shirt or jeans?')

    cat = r['Category'].strip()
    price = float(r['Selling Price'] or 0)
    stock = int(float(r['Stock Quantity (Pieces)'] or 0))
    cost = float(r['Cost Price'] or 0)

    if price <= 1:
        flag(rec, f'Price Rs {price:g} was a typing mistake - enter real selling price')
    if price == 5506:
        price = 550
        flag(rec, 'Price 5506 looked like a typo, set to 550')
    if stock == 0:
        flag(rec, 'Stock is 0')

    # Sizes: split combined cells into one row per size
    parts = []
    tokens = re.findall(r'(XXXL|XXL|XL|S|M|L|\d+)\s*;?\s*(\d*)', size_raw)
    if re.fullmatch(r'\d+', size_raw) or size_raw in SIZE_ORDER:
        parts = [(size_raw, stock)]
        if size_raw == '367':
            parts = [('36', stock)]
            flag(rec, 'Size 367 read as 36')
    elif tokens and all(q for _, q in tokens):
        parts = [(s, int(q)) for s, q in tokens]
        flag(rec, f'Size cell "{r["Size"]}" split into ' + ', '.join(f'{s}:{q}' for s, q in parts))
    else:
        sizes = [s for s, _ in tokens]
        each, rem = divmod(stock, len(sizes))
        parts = [(s, each + (1 if i < rem else 0)) for i, s in enumerate(sizes)]
        flag(rec, f'Size cell "{r["Size"]}" had {stock} pcs with no split - spread evenly, please correct')
    if sum(q for _, q in parts) != stock:
        flag(rec, f'Split quantities ({sum(q for _, q in parts)}) differ from stock {stock}')

    if not brand:
        brand = 'NO BRAND'
        flag(rec, 'No brand in name')
    for i, (sz, q) in enumerate(parts):
        c = cat
        if gtype == 'Jeans' and sz.isdigit() and int(sz) >= 32 and cat == 'Kids':
            c = 'Men'
        item = dict(rec, notes=list(rec['notes']), brand=brand, type=gtype, sleeve=sleeve,
                    size=sz, color=color, cat=c, cost=cost, price=price, stock=q,
                    barcode=rec['barcode'] if i == 0 else f"{rec['barcode']}-{sz}")
        if c != cat:
            item['notes'].append(f'Waist {sz} tagged Kids, changed to Men')
        if gtype == 'Jeans' and sz.isdigit() and 28 <= int(sz) <= 30 and c == 'Kids':
            item['notes'].append(f'Waist {sz} kept as Kids (sold as both) - change to Men if this one is adult')
        out.append(item)
        seen_codes[item['barcode'].replace('SKU-', '')].append(item)

for code, items in seen_codes.items():
    if len(items) > 1:
        for it in items:
            it['notes'].append(f'Barcode clashes with {", ".join(x["barcode"] for x in items if x is not it)}')

for it in out:
    it['name'] = ' '.join(x for x in [it['brand'], it['type'], f"({it['sleeve']})" if it['sleeve'] else ''] if x)

# ---- outputs ----
# 1) Import file in the app's own CSV layout
with open(f'{OUTDIR}/stock_clean_import.csv', 'w', newline='', encoding='utf-8') as f:
    w = csv.writer(f)
    w.writerow(['Barcode', 'Name', 'Brand', 'Type', 'Category', 'Size', 'Color', 'Cost Price', 'Selling Price', 'Stock Quantity (Pieces)'])
    for it in out:
        w.writerow([it['barcode'], it['name'], it['brand'], it['type'], it['cat'], it['size'], it['color'],
                    f"{it['cost']:g}" if it['cost'] else '', f"{it['price']:g}", it['stock']])

# 2) Review workbook
wb = Workbook()
hdr_font, hdr_fill = Font(bold=True, color='FFFFFF'), PatternFill('solid', fgColor='1E1B4B')
warn = PatternFill('solid', fgColor='FFF4CC')

def sheet(ws, header, data, widths, hl=None):
    ws.append(header)
    for c in ws[1]:
        c.font, c.fill = hdr_font, hdr_fill
    for row in data:
        ws.append(row)
        if hl and hl(row):
            for c in ws[ws.max_row]:
                c.fill = warn
    for i, wdt in enumerate(widths):
        ws.column_dimensions[chr(65 + i)].width = wdt
    ws.freeze_panes = 'A2'
    ws.auto_filter.ref = ws.dimensions

ws = wb.active
ws.title = 'Clean Stock'
sheet(ws, ['Barcode', 'Name', 'Brand', 'Type', 'Category', 'Size', 'Color', 'Cost Price', 'Selling Price', 'Stock', 'Check note', 'Original name', 'Original line'],
      [[it['barcode'], it['name'], it['brand'], it['type'], it['cat'], it['size'], it['color'], it['cost'] or None, it['price'], it['stock'],
        '; '.join(it['notes']), it['orig_name'], it['line']] for it in out],
      [13, 28, 18, 9, 9, 7, 8, 10, 11, 7, 60, 26, 9], hl=lambda r: r[10])

ws2 = wb.create_sheet('Needs Your Check')
sheet(ws2, ['Original line', 'Barcode', 'Name', 'Size', 'Category', 'Price', 'Stock', 'What to check'],
      [[it['line'], it['barcode'], it['name'], it['size'], it['cat'], it['price'], it['stock'], n]
       for it in out for n in it['notes'] if 'assumed' not in n],
      [10, 13, 28, 7, 9, 8, 7, 70])

ws3 = wb.create_sheet('Brand Merges')
sheet(ws3, ['Written as', 'Merged into', 'Rows', 'Status'],
      [[a, b, c, 'Obvious typo' if s else 'PLEASE CONFIRM'] for (a, b, s), c in sorted(merges.items())],
      [20, 20, 7, 16], hl=lambda r: r[3] == 'PLEASE CONFIRM')

summ = wb.create_sheet('Summary', 0)
by_type = collections.Counter()
for it in out:
    by_type[(it['cat'], it['type'])] += it['stock']
summ.append(['Stock summary after cleaning'])
summ['A1'].font = Font(bold=True, size=13)
summ.append([])
summ.append(['Rows in original file', len(rows)])
summ.append(['Rows after splitting sizes', len(out)])
summ.append(['Total pieces', sum(it['stock'] for it in out)])
summ.append(['Brands (after merging spellings)', len({it['brand'] for it in out})])
summ.append(['Rows that need a check', sum(1 for it in out if any('assumed' not in n for n in it['notes']))])
summ.append(['Cost price', 'Not tracked (selling price only)'])
summ.append([])
summ.append(['Category', 'Type', 'Pieces'])
for c in summ[summ.max_row]:
    c.font = Font(bold=True)
for (c, t), q in sorted(by_type.items()):
    summ.append([c, t, q])
summ.column_dimensions['A'].width = 34
summ.column_dimensions['B'].width = 14
wb.save(f'{OUTDIR}/stock_review.xlsx')

print('rows', len(rows), '->', len(out), 'pieces', sum(it['stock'] for it in out),
      'brands', len({it['brand'] for it in out}),
      'review rows', sum(1 for it in out if any('assumed' not in n for n in it['notes'])))
print(sorted(by_type.items()))
print(sorted({it['brand'] for it in out}))
