import math, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4096           # supersampled canvas (4x of 1024)
K = S / 1024

def squircle_mask():
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    x0, y0, x1, y1 = 100*K, 100*K, 924*K, 924*K
    d.rounded_rectangle([x0, y0, x1, y1], radius=185*K, fill=255)
    return m

def lerp(a, b, t): return tuple(int(a[i] + (b[i]-a[i])*t) for i in range(3))

def gradient(c0, c1, angle=135, stops=None):
    w = S
    g = Image.new("RGB", (w, w))
    px = g.load()
    # do it small then upscale for speed
    small = 256
    gs = Image.new("RGB", (small, small))
    p = gs.load()
    a = math.radians(angle)
    dx, dy = math.cos(a), math.sin(a)
    for y in range(small):
        for x in range(small):
            u = (x/small - .5)*dx + (y/small - .5)*dy
            t = max(0, min(1, u/1.0 + .5))
            if stops:
                for i in range(len(stops)-1):
                    t0, col0 = stops[i]; t1, col1 = stops[i+1]
                    if t0 <= t <= t1:
                        p[x, y] = lerp(col0, col1, (t-t0)/(t1-t0) if t1 > t0 else 0); break
            else:
                p[x, y] = lerp(c0, c1, t)
    return gs.resize((S, S), Image.BICUBIC)

def radial_glow(center, radius, color, alpha):
    layer = Image.new("RGBA", (S, S), (0,0,0,0))
    d = ImageDraw.Draw(layer)
    cx, cy = center
    d.ellipse([cx-radius, cy-radius, cx+radius, cy+radius], fill=color+(alpha,))
    return layer.filter(ImageFilter.GaussianBlur(radius*0.6))

def chevron_mask(width=78):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    pts = [(300*K, 330*K), (500*K, 512*K), (300*K, 694*K)]
    w = int(width*K)
    d.line(pts, fill=255, width=w, joint="curve")
    for p in (pts[0], pts[2]):
        d.ellipse([p[0]-w/2, p[1]-w/2, p[0]+w/2, p[1]+w/2], fill=255)
    return m

def sparkle_mask(cx, cy, r, pinch=0.18, n=4):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    pts = []
    steps = 400
    for i in range(steps):
        t = 2*math.pi*i/steps
        # astroid-like four point star with concave sides
        c, s = math.cos(t), math.sin(t)
        x = math.copysign(abs(c)**(1/ (pinch*2+0.5)) , c) if False else None
        rr = r * (pinch + (1-pinch) * (abs(math.cos(n/2*t)))**6)
        pts.append((cx + rr*c, cy + rr*s))
    d.polygon(pts, fill=255)
    return m

def astroid(cx, cy, r, k=2.6):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    pts = []
    for i in range(720):
        t = 2*math.pi*i/720
        c, s = math.cos(t), math.sin(t)
        x = cx + r * math.copysign(abs(c)**k, c)
        y = cy + r * math.copysign(abs(s)**k, s)
        pts.append((x, y))
    d.polygon(pts, fill=255)
    return m

def paint(base, mask, fill):
    if isinstance(fill, tuple):
        fill = Image.new("RGB", (S, S), fill)
    base.paste(fill, (0, 0), mask)

def glow(base_rgba, mask, color, blur, strength=1.0):
    g = Image.new("RGBA", (S, S), color + (0,))
    a = mask.filter(ImageFilter.GaussianBlur(blur*K)).point(lambda v: int(min(255, v*strength)))
    g.putalpha(a)
    return Image.alpha_composite(base_rgba, g)

def finish(img_rgb, name):
    sq = squircle_mask()
    out = Image.new("RGBA", (S, S), (0,0,0,0))
    # drop shadow
    sh = Image.new("RGBA", (S, S), (0,0,0,0))
    shm = sq.filter(ImageFilter.GaussianBlur(18*K)).point(lambda v: int(v*0.45))
    sh.putalpha(shm)
    sh = ImageChops.offset(sh, 0, int(10*K))
    out = Image.alpha_composite(out, sh)
    body = img_rgb.convert("RGBA"); body.putalpha(sq)
    out = Image.alpha_composite(out, body)
    # inner top highlight stroke
    hl = Image.new("RGBA", (S, S), (255,255,255,0))
    inner = ImageChops.subtract(sq, sq.filter(ImageFilter.MinFilter(int(6*K)|1)))
    grad = Image.linear_gradient("L").resize((S, S)).transpose(Image.FLIP_TOP_BOTTOM)
    hl.putalpha(ImageChops.multiply(inner, grad.point(lambda v: int(v*0.35))))
    out = Image.alpha_composite(out, hl)
    out.resize((1024, 1024), Image.LANCZOS).save(name)

def option_a():
    # 延续:深绿底 + 薄荷 >,光标换成 AI 四芒星
    bg = gradient(None, None, 120, stops=[(0, (22, 58, 46)), (1, (8, 24, 19))]).convert("RGBA")
    bg = Image.alpha_composite(bg, radial_glow((560*K, 520*K), 300*K, (60, 200, 150), 60))
    cm = chevron_mask()
    bg = glow(bg, cm, (90, 240, 180), 26, 1.3)
    paint(bg, cm, (120, 238, 196))
    sm = astroid(680*K, 600*K, 120*K)
    bg = glow(bg, sm, (200, 255, 230), 30, 1.6)
    paint(bg, sm, (236, 255, 246))
    sm2 = astroid(760*K, 400*K, 46*K)
    bg = glow(bg, sm2, (180, 255, 220), 14, 1.2)
    paint(bg, sm2, (200, 250, 228))
    finish(bg.convert("RGB"), "A.png")

def option_b():
    # 午夜靛蓝 → 紫,> 用青→紫→粉渐变,星光光标
    bg = gradient(None, None, 125, stops=[(0, (38, 30, 92)), (0.55, (20, 16, 52)), (1, (10, 8, 26))]).convert("RGBA")
    bg = Image.alpha_composite(bg, radial_glow((380*K, 420*K), 300*K, (90, 120, 255), 70))
    bg = Image.alpha_composite(bg, radial_glow((700*K, 640*K), 260*K, (220, 90, 220), 60))
    cm = chevron_mask()
    fill = gradient(None, None, 90, stops=[(0, (110, 220, 255)), (0.5, (150, 130, 255)), (1, (255, 120, 210))])
    bg = glow(bg, cm, (140, 140, 255), 28, 1.3)
    tmp = bg.convert("RGB"); paint(tmp, cm, fill); bg = tmp.convert("RGBA")
    sm = astroid(690*K, 610*K, 125*K)
    bg = glow(bg, sm, (255, 200, 255), 32, 1.7)
    paint(bg, sm, (255, 246, 255))
    finish(bg.convert("RGB"), "B.png")

def option_c():
    # 多 agent:> 后面三颗大小不一的星,极光渐变底
    bg = gradient(None, None, 135, stops=[(0, (14, 34, 48)), (1, (6, 12, 22))]).convert("RGBA")
    bg = Image.alpha_composite(bg, radial_glow((300*K, 300*K), 320*K, (40, 200, 170), 70))
    bg = Image.alpha_composite(bg, radial_glow((760*K, 760*K), 320*K, (120, 80, 240), 75))
    cm = chevron_mask()
    fill = gradient(None, None, 90, stops=[(0, (110, 245, 200)), (1, (130, 170, 255))])
    bg = glow(bg, cm, (110, 220, 220), 26, 1.2)
    tmp = bg.convert("RGB"); paint(tmp, cm, fill); bg = tmp.convert("RGBA")
    for (x, y, r, col) in [(680, 610, 105, (255, 255, 255)), (770, 420, 58, (200, 230, 255)), (640, 380, 34, (190, 255, 230))]:
        sm = astroid(x*K, y*K, r*K)
        bg = glow(bg, sm, col, r*0.28, 1.5)
        paint(bg, sm, col)
    finish(bg.convert("RGB"), "C.png")

def chevron_mask2(width=80):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    pts = [(322*K, 318*K), (532*K, 510*K), (322*K, 702*K)]
    w = int(width*K)
    d.line(pts, fill=255, width=w, joint="curve")
    for p in (pts[0], pts[2]):
        d.ellipse([p[0]-w/2, p[1]-w/2, p[0]+w/2, p[1]+w/2], fill=255)
    return m

def final():
    # 与原图标同色:底 (29,55,42) 附近,中心微亮;> 薄荷 (136,238,200);光标位换星光
    bg = gradient(None, None, 120, stops=[(0, (34, 72, 56)), (0.5, (26, 54, 42)), (1, (14, 32, 25))]).convert("RGBA")
    bg = Image.alpha_composite(bg, radial_glow((540*K, 540*K), 280*K, (52, 140, 104), 70))
    # 四周压暗(原图标的暗角)
    vig = Image.new("L", (S, S), 0)
    ImageDraw.Draw(vig).ellipse([60*K, 40*K, 964*K, 944*K], fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(160*K))
    dark = Image.new("RGBA", (S, S), (6, 16, 12, 255))
    dark.putalpha(vig.point(lambda v: int((255 - v) * 0.75)))
    bg = Image.alpha_composite(bg, dark)
    cm = chevron_mask2()
    bg = glow(bg, cm, (110, 240, 190), 30, 1.35)
    paint(bg, cm, (120, 226, 186))
    # 内芯高光:与原图标一样,笔画中间亮一档
    core = chevron_mask2(width=44).filter(ImageFilter.GaussianBlur(6*K))
    hl = Image.new("RGBA", (S, S), (160, 248, 214, 0)); hl.putalpha(core)
    bg = Image.alpha_composite(bg, hl)
    big = astroid(700*K, 636*K, 118*K, k=2.8)
    bg = glow(bg, big, (190, 255, 228), 34, 1.7)
    paint(bg, big, (236, 255, 246))
    small = astroid(800*K, 430*K, 46*K, k=2.8)
    bg = glow(bg, small, (160, 250, 210), 16, 1.3)
    paint(bg, small, (196, 250, 226))
    rgb = bg.convert("RGB")
    # iOS 满版:系统自己切圆角,取圆角矩形所在区域铺满整张
    rgb.crop((int(100*K), int(100*K), int(924*K), int(924*K))).resize((1024, 1024), Image.LANCZOS).save("ios.png")
    finish(rgb, "final.png")

if sys.argv[1:] == ["final"]:
    final()
    sys.exit()
option_a(); option_b(); option_c()
# 对比板:大图 + 小尺寸(Dock/Finder 实际观感)
sheet = Image.new("RGB", (3*560, 700), (236, 236, 236))
d = ImageDraw.Draw(sheet)
for i, n in enumerate("ABC"):
    im = Image.open(n + ".png")
    sheet.paste(im.resize((512, 512), Image.LANCZOS), (i*560 + 24, 20), im.resize((512, 512), Image.LANCZOS))
    for j, sz in enumerate((128, 64, 32)):
        s = im.resize((sz, sz), Image.LANCZOS)
        sheet.paste(s, (i*560 + 60 + j*150, 560 + (128 - sz)//2), s)
    d.text((i*560 + 270, 670), n, fill=(40, 40, 40))
sheet.save("sheet.png")
