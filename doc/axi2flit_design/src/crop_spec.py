"""从 AoU 规范 PDF 截取帧格式与消息字段图。用法：python3 crop_spec.py <规范 PDF> <输出目录>"""
import subprocess
import sys
import tempfile
from PIL import Image, ImageChops

PDF, OUT = sys.argv[1], sys.argv[2]
DPI = 300
# 页码与裁剪框（单位：页面宽度的千分比，与渲染分辨率无关）
CROPS = {
    "spec_flit": (13, (78, 103, 919, 355)),
    "spec_ph": (13, (92, 520, 919, 781)),
    "spec_wreq": (23, (78, 1018, 919, 1206)),
    "spec_wdata256": (24, (78, 290, 919, 675)),
    "spec_rdata256": (29, (78, 57, 919, 442)),
    "spec_wresp": (31, (78, 57, 919, 164)),
    "spec_crdt": (31, (78, 792, 919, 937)),
    "spec_pack": (32, (78, 296, 919, 548)),
}

with tempfile.TemporaryDirectory() as tmp:
    pages = {}
    for name, (page, box) in CROPS.items():
        if page not in pages:
            subprocess.run(["pdftoppm", "-f", str(page), "-l", str(page), "-r", str(DPI), "-png",
                            "-singlefile", PDF, f"{tmp}/p{page}"], check=True)
            pages[page] = Image.open(f"{tmp}/p{page}.png").convert("RGB")
        im = pages[page]
        s = im.width / 1000
        c = im.crop(tuple(int(v * s) for v in box))
        bg = Image.new("RGB", c.size, (255, 255, 255))
        bb = ImageChops.difference(c, bg).convert("L").point(lambda v: 255 if v > 12 else 0).getbbox()
        c = c.crop((max(bb[0] - 10, 0), max(bb[1] - 10, 0), min(bb[2] + 10, c.width), min(bb[3] + 10, c.height)))
        c.save(f"{OUT}/{name}.png")
        print(name, c.size)
