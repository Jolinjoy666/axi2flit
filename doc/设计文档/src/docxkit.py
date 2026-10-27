"""docx 排版公共部分：内容以条目列表描述，render() 负责编号与排版。"""
import re
from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_CELL_VERTICAL_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

# 每项为 (类型, ...)。正文中 {图:key} / {表:key} 在生成时替换为编号。
C = []
h1 = lambda t: C.append(("h1", t))
h2 = lambda t: C.append(("h2", t))
h3 = lambda t: C.append(("h3", t))
p = lambda t: C.append(("p", t))
li = lambda t: C.append(("li", t))
code = lambda t: C.append(("code", t))


def fig(key, file, cap, width=15.5, spec=False):
    C.append(("fig", key, file, cap, width, spec))


def tab(key, cap, head, rows, widths, note=None):
    C.append(("tab", key, cap, head, rows, widths, note))



h1n = lambda t: C.append(("h1n", t))
tip = lambda t: C.append(("tip", t))
brk = lambda: C.append(("brk",))


def render(fig_dir, spec_dir, out, title, subtitle, meta, toc=True):
    FIG_DIR, SPEC_DIR, OUT = fig_dir, spec_dir, out
    BODY_FONT, HEAD_FONT, MONO = "宋体", "黑体", "Consolas"


    def set_font(run, east, latin=None, size=None, bold=None, color=None):
        run.font.name = latin or "Times New Roman"
        rpr = run._element.get_or_add_rPr()
        rfonts = rpr.find(qn("w:rFonts"))
        if rfonts is None:
            rfonts = OxmlElement("w:rFonts")
            rpr.insert(0, rfonts)
        rfonts.set(qn("w:eastAsia"), east)
        rfonts.set(qn("w:ascii"), latin or "Times New Roman")
        rfonts.set(qn("w:hAnsi"), latin or "Times New Roman")
        if size:
            run.font.size = Pt(size)
        if bold is not None:
            run.font.bold = bold
        if color:
            run.font.color.rgb = RGBColor.from_string(color)


    def style_font(style, east, latin, size, bold=False):
        style.font.name = latin
        style.font.size = Pt(size)
        style.font.bold = bold
        style.font.color.rgb = RGBColor(0, 0, 0)
        rpr = style.element.get_or_add_rPr()
        rfonts = rpr.find(qn("w:rFonts"))
        if rfonts is None:
            rfonts = OxmlElement("w:rFonts")
            rpr.insert(0, rfonts)
        for k in ("w:eastAsia",):
            rfonts.set(qn(k), east)
        rfonts.set(qn("w:ascii"), latin)
        rfonts.set(qn("w:hAnsi"), latin)
        for a in ("w:asciiTheme", "w:hAnsiTheme", "w:eastAsiaTheme", "w:cstheme"):
            if rfonts.get(qn(a)) is not None:
                del rfonts.attrib[qn(a)]


    doc = Document()
    sec = doc.sections[0]
    sec.page_height, sec.page_width = Cm(29.7), Cm(21.0)
    sec.left_margin = sec.right_margin = Cm(2.5)
    sec.top_margin, sec.bottom_margin = Cm(2.5), Cm(2.3)

    st = doc.styles
    style_font(st["Normal"], BODY_FONT, "Times New Roman", 10.5)
    pf = st["Normal"].paragraph_format
    pf.line_spacing = 1.3
    pf.space_after = Pt(3)
    for name, size, before, after in [("Heading 1", 15, 18, 10), ("Heading 2", 13, 12, 6), ("Heading 3", 11.5, 8, 4)]:
        s = st[name]
        style_font(s, HEAD_FONT, "Arial", size, bold=False)
        s.paragraph_format.space_before = Pt(before)
        s.paragraph_format.space_after = Pt(after)
        s.paragraph_format.line_spacing = 1.2
        s.paragraph_format.keep_with_next = True
        s.paragraph_format.first_line_indent = Cm(0)

    for lvl, ind in ((1, 0), (2, 0.74)):
        try:
            ts = st[f"toc {lvl}"]
        except KeyError:
            ts = st.add_style(f"toc {lvl}", 1)
            ts.base_style = st["Normal"]
        ts.paragraph_format.line_spacing = 1.15
        ts.paragraph_format.space_after = Pt(2)
        ts.paragraph_format.left_indent = Cm(ind)
        ts.paragraph_format.first_line_indent = Cm(0)

    counters = {"h1": 0, "h2": 0, "h3": 0}
    labels = {}


    def number_items():
        ch, nf, nt = 0, 0, 0
        for it in C:
            if it[0] == "h1":
                ch += 1
                nf = nt = 0
            elif it[0] == "h1n":
                ch = "A"
                nf = nt = 0
            elif it[0] == "fig":
                nf += 1
                labels["图:" + it[1]] = f"图 {ch}-{nf}"
            elif it[0] == "tab":
                nt += 1
                labels["表:" + it[1]] = f"表 {ch}-{nt}"


    number_items()


    def resolve(t):
        return re.sub(r"\{(图|表):([a-z_0-9]+)\}", lambda m: labels[f"{m.group(1)}:{m.group(2)}"], t)


    def para(text, indent=True, align=None, size=None, east=BODY_FONT, space_after=None, keep=False):
        para_ = doc.add_paragraph()
        if indent:
            para_.paragraph_format.first_line_indent = Pt(21)
        if align is not None:
            para_.alignment = align
        if space_after is not None:
            para_.paragraph_format.space_after = Pt(space_after)
        if keep:
            para_.paragraph_format.keep_with_next = True
        r = para_.add_run(resolve(text))
        set_font(r, east, size=size)
        return para_


    def shade(cell, color):
        tcpr = cell._element.get_or_add_tcPr()
        shd = OxmlElement("w:shd")
        shd.set(qn("w:val"), "clear")
        shd.set(qn("w:color"), "auto")
        shd.set(qn("w:fill"), color)
        tcpr.append(shd)


    def table_borders(tbl):
        tblpr = tbl._element.tblPr
        b = OxmlElement("w:tblBorders")
        for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
            e = OxmlElement(f"w:{edge}")
            e.set(qn("w:val"), "single")
            e.set(qn("w:sz"), "8" if edge in ("top", "bottom") else "4")
            e.set(qn("w:space"), "0")
            e.set(qn("w:color"), "000000" if edge in ("top", "bottom") else "808080")
            b.append(e)
        tblpr.append(b)


    def caption(text):
        c_ = doc.add_paragraph()
        c_.alignment = WD_ALIGN_PARAGRAPH.CENTER
        c_.paragraph_format.first_line_indent = Cm(0)
        c_.paragraph_format.space_before = Pt(3)
        c_.paragraph_format.space_after = Pt(8)
        r = c_.add_run(text)
        set_font(r, HEAD_FONT, latin="Arial", size=9)
        return c_


    def add_table(key, cap, head, rows, widths, note):
        tc = caption(f"{labels['表:' + key]}　{cap}")
        tc.paragraph_format.space_after = Pt(3)
        tc.paragraph_format.keep_with_next = True
        tbl = doc.add_table(rows=1 + len(rows), cols=len(head))
        tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
        tbl.autofit = False
        table_borders(tbl)
        tblpr = tbl._element.tblPr
        lay = OxmlElement("w:tblLayout")
        lay.set(qn("w:type"), "fixed")
        tblpr.append(lay)
        tw = OxmlElement("w:tblW")
        tw.set(qn("w:w"), str(int(sum(widths) * 567)))
        tw.set(qn("w:type"), "dxa")
        for old_tw in tblpr.findall(qn("w:tblW")):
            tblpr.remove(old_tw)
        tblpr.append(tw)
        for c_i, col in enumerate(tbl.columns):
            col.width = Cm(widths[c_i])
        # 整列都是短内容时居中，否则左对齐，避免同列对齐不一致
        centered = [all(len(str(r[c])) <= 10 and "\n" not in str(r[c]) for r in rows) for c in range(len(head))]
        for r_i, row in enumerate([head] + rows):
            for c_i, val in enumerate(row):
                cell = tbl.cell(r_i, c_i)
                cell.width = Cm(widths[c_i])
                cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
                cp = cell.paragraphs[0]
                cp.paragraph_format.first_line_indent = Cm(0)
                cp.paragraph_format.space_after = Pt(0)
                cp.paragraph_format.line_spacing = 1.15
                if r_i == 0 or centered[c_i]:
                    cp.alignment = WD_ALIGN_PARAGRAPH.CENTER
                run = cp.add_run(str(val))
                set_font(run, HEAD_FONT if r_i == 0 else BODY_FONT, size=9)
                if r_i == 0:
                    shade(cell, "E7E6E6")
        for row in tbl.rows:
            trpr = row._tr.get_or_add_trPr()
            cant = OxmlElement("w:cantSplit")
            trpr.append(cant)
        hdr = tbl.rows[0]._tr.get_or_add_trPr()
        th = OxmlElement("w:tblHeader")
        hdr.append(th)
        if note:
            n = doc.add_paragraph()
            n.paragraph_format.first_line_indent = Cm(0)
            n.paragraph_format.space_before = Pt(2)
            r = n.add_run("注：" + note)
            set_font(r, BODY_FONT, size=8.5, color="595959")
        else:
            sp = doc.add_paragraph()
            sp.paragraph_format.space_after = Pt(2)
            sp.paragraph_format.line_spacing = 0.8


    def add_fig(key, file, cap, width, spec):
        path = f"{SPEC_DIR if spec else FIG_DIR}/{file}"
        fp = doc.add_paragraph()
        fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
        fp.paragraph_format.first_line_indent = Cm(0)
        fp.paragraph_format.keep_with_next = True
        fp.paragraph_format.space_before = Pt(6)
        fp.paragraph_format.line_spacing = 1.0
        fp.add_run().add_picture(path, width=Cm(width))
        caption(f"{labels['图:' + key]}　{cap}")


    def add_code(text):
        for i, line in enumerate(text.split("\n")):
            cp = doc.add_paragraph()
            cp.paragraph_format.first_line_indent = Cm(0)
            cp.paragraph_format.left_indent = Cm(0.6)
            cp.paragraph_format.space_after = Pt(0)
            cp.paragraph_format.space_before = Pt(4) if i == 0 else Pt(0)
            cp.paragraph_format.line_spacing = 1.15
            ppr = cp._element.get_or_add_pPr()
            shd = OxmlElement("w:shd")
            shd.set(qn("w:val"), "clear")
            shd.set(qn("w:color"), "auto")
            shd.set(qn("w:fill"), "F2F2F2")
            ppr.append(shd)
            r = cp.add_run(line if line else " ")
            set_font(r, BODY_FONT, latin=MONO, size=8.5)
        doc.add_paragraph().paragraph_format.space_after = Pt(0)


    def add_tip(text):
        tp_ = doc.add_paragraph()
        tp_.paragraph_format.first_line_indent = Cm(0)
        tp_.paragraph_format.left_indent = Cm(0.4)
        tp_.paragraph_format.space_before = Pt(4)
        tp_.paragraph_format.space_after = Pt(8)
        tp_.paragraph_format.line_spacing = 1.25
        ppr = tp_._element.get_or_add_pPr()
        bdr_ = OxmlElement("w:pBdr")
        left = OxmlElement("w:left")
        for k_, v_ in (("w:val", "single"), ("w:sz", "18"), ("w:space", "8"), ("w:color", "2F6DB3")):
            left.set(qn(k_), v_)
        bdr_.append(left)
        ppr.append(bdr_)
        shd = OxmlElement("w:shd")
        shd.set(qn("w:val"), "clear")
        shd.set(qn("w:color"), "auto")
        shd.set(qn("w:fill"), "F2F2F2")
        ppr.append(shd)
        r0 = tp_.add_run("讲解提示　")
        set_font(r0, HEAD_FONT, size=9.5, color="2F6DB3")
        r1 = tp_.add_run(resolve(text))
        set_font(r1, BODY_FONT, size=9.5)

    def add_field(paragraph, instr):
        r = paragraph.add_run()
        b = OxmlElement("w:fldChar")
        b.set(qn("w:fldCharType"), "begin")
        r._element.append(b)
        r2 = paragraph.add_run()
        it = OxmlElement("w:instrText")
        it.set(qn("xml:space"), "preserve")
        it.text = instr
        r2._element.append(it)
        r3 = paragraph.add_run()
        s = OxmlElement("w:fldChar")
        s.set(qn("w:fldCharType"), "separate")
        r3._element.append(s)
        r4 = paragraph.add_run("1" if "PAGE" in instr else "右键选择“更新域”生成目录")
        set_font(r4, BODY_FONT, size=9)
        r5 = paragraph.add_run()
        e = OxmlElement("w:fldChar")
        e.set(qn("w:fldCharType"), "end")
        r5._element.append(e)


    # 封面
    for _ in range(7):
        doc.add_paragraph()
    t = para(title[0], indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, size=26, east=HEAD_FONT, space_after=6)
    t = para(title[1], indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, size=26, east=HEAD_FONT, space_after=30)
    para(subtitle, indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, size=12, space_after=150)
    for k, v in meta:
        para(f"{k}：{v}", indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, size=11, space_after=4)
    doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)

    # 目录
    if toc:
        tp = para("目　录", indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, size=15, east=HEAD_FONT, space_after=12)
        toc_p = doc.add_paragraph()
        add_field(toc_p, 'TOC \\o "1-2" \\h \\z \\u')

    # 正文另起一节，页码从 1 开始
    body = doc.add_section(WD_SECTION.NEW_PAGE)
    pg = body._sectPr
    pn = OxmlElement("w:pgNumType")
    pn.set(qn("w:start"), "1")
    pg.append(pn)
    body.header.is_linked_to_previous = False
    body.footer.is_linked_to_previous = False
    hp = body.header.paragraphs[0]
    hp.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    hr = hp.add_run(title[0] + " " + title[1])
    set_font(hr, BODY_FONT, size=8.5, color="7F7F7F")
    hppr = hp._element.get_or_add_pPr()
    bdr = OxmlElement("w:pBdr")
    bot = OxmlElement("w:bottom")
    for k, v in (("w:val", "single"), ("w:sz", "4"), ("w:space", "1"), ("w:color", "A6A6A6")):
        bot.set(qn(k), v)
    bdr.append(bot)
    hppr.append(bdr)
    fpar = body.footer.paragraphs[0]
    fpar.alignment = WD_ALIGN_PARAGRAPH.CENTER
    add_field(fpar, "PAGE")

    for it in C:
        kind = it[0]
        if kind == "h1":
            counters["h1"] += 1
            counters["h2"] = counters["h3"] = 0
            doc.add_heading(f"{counters['h1']}　{it[1]}", level=1)
        elif kind == "h1n":
            # 附录：标题形如“附录 A　…”，其下小节编号为 A.1、A.2。
            counters["h1"] = it[1].split("　")[0].split()[-1]
            counters["h2"] = counters["h3"] = 0
            doc.add_heading(it[1], level=1)
        elif kind == "h2":
            counters["h2"] += 1
            counters["h3"] = 0
            doc.add_heading(f"{counters['h1']}.{counters['h2']}　{it[1]}", level=2)
        elif kind == "h3":
            counters["h3"] += 1
            doc.add_heading(f"{counters['h1']}.{counters['h2']}.{counters['h3']}　{it[1]}", level=3)
        elif kind == "p":
            para(it[1])
        elif kind == "li":
            q = para(it[1], indent=False)
            q.paragraph_format.left_indent = Pt(21)
            q.paragraph_format.space_after = Pt(1)
        elif kind == "code":
            add_code(it[1])
        elif kind == "tip":
            add_tip(it[1])
        elif kind == "brk":
            doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)
        elif kind == "fig":
            add_fig(*it[1:])
        elif kind == "tab":
            add_table(*it[1:])

    # 打开文档时提示更新目录域
    if toc:
        settings = doc.settings.element
        uf = OxmlElement("w:updateFields")
        uf.set(qn("w:val"), "true")
        settings.append(uf)

    doc.core_properties.title = title[0] + " " + title[1]
    doc.core_properties.author = ""
    doc.save(OUT)
    print("saved", OUT, "figures:", sum(1 for k in labels if k.startswith("图")), "tables:",
          sum(1 for k in labels if k.startswith("表")))
