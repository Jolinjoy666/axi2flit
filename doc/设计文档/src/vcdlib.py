"""最小 VCD 读取：返回 {name: [(t_ns, value), ...]}，name 为去掉顶层作用域后的层次名。"""
def read_vcd(path, names, t_end):
    want = set(names); codes = {}; data = {n: [] for n in names}; scope = []; scale = 1.0
    with open(path) as f:
        for line in f:
            t = line.split()
            if not t: continue
            if t[0] == "$timescale":
                unit = t[1] if len(t) > 1 and t[1] != "$end" else next(f).split()[0]
                scale = {"1fs": 1e-6, "1ps": 1e-3, "1ns": 1.0}[unit]
            elif t[0] == "$scope": scope.append(t[2])
            elif t[0] == "$upscope": scope.pop()
            elif t[0] == "$var":
                n = ".".join(scope[1:] + [t[4]])
                if n in want: codes.setdefault(t[3], []).append(n)
            elif t[0] == "$enddefinitions": break
        now = 0.0
        for line in f:
            c = line[0]
            if c == "#":
                now = int(line[1:]) * scale
                if now > t_end: break
            elif c in "01xz":
                for n in codes.get(line[1:].strip(), []): data[n].append((now, 1 if c == "1" else 0))
            elif c == "b":
                v, code = line[1:].split()
                if code in codes:
                    val = int(v.replace("x", "0").replace("z", "0"), 2)
                    for n in codes[code]: data[n].append((now, val))
    return data

def value_at(series, t):
    """t 时刻之前（不含 t）的取值，即上升沿采样值。"""
    v = 0
    for tt, vv in series:
        if tt < t: v = vv
        else: break
    return v

def edges(t0, t1, period=2.0, phase=0.0):
    import math
    k = math.ceil((t0 - phase) / period)
    out = []
    t = phase + k * period
    while t <= t1:
        out.append(round(t, 6)); t += period
    return out
