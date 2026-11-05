/// Вторая часть коллекции шейдеров. Использует функции из первой (hash21, noise, fbm, stars, dither).
let shaderCollectionSource = #"""

static float2x2 rot(float a) { float c = cos(a), s = sin(a); return float2x2(c, -s, s, c); }

// ---------- Технологии ----------

fragment float4 gridFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = float2((in.uv.x - 0.5) * u.aspect, in.uv.y - 0.42);
    float3 color = mix(float3(0.01, 0.015, 0.05), float3(0.02, 0.05, 0.14), smoothstep(-0.42, 0.0, uv.y));
    color += float3(0.05, 0.45, 0.85) * exp(-abs(uv.y) * 9.0) * 0.9;
    if (uv.y > 0.0) {
        float z = 0.32 / uv.y;
        float2 g = float2(uv.x * z + 0.5, z + u.time * 0.45);
        float2 f = abs(fract(g) - 0.5);
        float width = 0.012 * z + 0.006;
        float lines = (1.0 - smoothstep(0.0, width, 0.5 - f.x)) + (1.0 - smoothstep(0.0, width, 0.5 - f.y));
        float fade = exp(-z * 0.16);
        float pulse = 0.65 + 0.35 * sin(g.y * 0.8 - u.time * 1.2);
        color += float3(0.08, 0.75, 1.0) * min(lines, 1.0) * fade * pulse;
    } else {
        color += stars(uv * 1.2 + 3.0, 60.0, u.time) * float3(0.7, 0.85, 1.0);
    }
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 matrixFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = float2(in.uv.x * u.aspect, in.uv.y);
    float columns = 62.0;
    float x = floor(uv.x * columns);
    float speed = 0.16 + hash21(float2(x, 1.0)) * 0.34;
    float offset = hash21(float2(x, 7.0)) * 40.0;
    float y = uv.y * 30.0;
    float head = fract(u.time * speed + offset) * 42.0 - 6.0;
    float d = head - y;
    float trail = d > 0.0 ? exp(-d * 0.16) : 0.0;
    float row = floor(y);
    // «Символ» — маленькая случайная маска, которая время от времени меняется.
    float2 cell = fract(float2(uv.x * columns, y));
    float2 pixel = floor(cell * float2(5.0, 7.0));
    float flip = floor(u.time * (1.0 + hash21(float2(x, row)) * 3.0));
    float glyph = step(0.48, hash21(pixel + float2(x + flip, row)));
    glyph *= step(0.12, cell.x) * step(cell.x, 0.88) * step(0.08, cell.y) * step(cell.y, 0.92);
    float3 color = float3(0.0, 0.015, 0.012);
    color += float3(0.05, 0.85, 0.42) * trail * glyph;
    color += float3(0.75, 1.0, 0.85) * step(0.0, d) * step(d, 1.0) * glyph;
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 circuitFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2(in.uv.x * u.aspect, in.uv.y) * 14.0;
    float2 id = floor(p);
    float2 f = fract(p) - 0.5;
    float choice = hash21(id);
    // Каждая клетка — кусок дорожки; вместе они складываются в плату.
    float d = choice < 0.5 ? min(length(f - float2(0.5, -0.5)) , length(f + float2(0.5, -0.5))) : min(length(f - float2(0.5, 0.5)), length(f + float2(0.5, 0.5)));
    float trace = abs(d - 0.5);
    float line = 1.0 - smoothstep(0.015, 0.05, trace);
    float angle = atan2(f.y - sign(f.y) * 0.5, f.x - sign(f.x) * 0.5);
    float flow = fract(angle * 0.32 + (id.x + id.y) * 0.13 - u.time * 0.22 * (0.5 + choice));
    float pulse = pow(flow, 18.0);
    float pad = 1.0 - smoothstep(0.05, 0.09, length(fract(p + 0.5) - 0.5));
    float3 base = mix(float3(0.01, 0.03, 0.05), float3(0.015, 0.06, 0.08), in.uv.y);
    float3 color = base + float3(0.03, 0.22, 0.26) * line + float3(0.05, 0.3, 0.35) * pad * step(0.7, hash21(id + 4.0));
    color += float3(0.25, 1.0, 0.95) * pulse * line * 1.6;
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 dataWaveFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = float2(in.uv.x * u.aspect, in.uv.y);
    float t = u.time * 0.25;
    float3 color = mix(float3(0.02, 0.01, 0.07), float3(0.0, 0.03, 0.09), in.uv.x);
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float2 grid = float2(uv.x * (60.0 + fl * 18.0), 0.0);
        float x = floor(grid.x);
        float xc = (x + 0.5) / (60.0 + fl * 18.0);
        float wave = 0.5 + 0.17 * sin(xc * 3.1 + t * (1.0 + fl * 0.3) + fl * 2.0) * cos(xc * 1.3 - t * 0.7);
        for (int row = -3; row <= 3; row++) {
            float y = wave + float(row) * 0.028 * (1.0 + 0.5 * sin(xc * 5.0 + t + fl));
            float d = length((uv - float2(xc, y)) * float2(1.0, 1.0));
            float dot_ = 1.0 - smoothstep(0.0016, 0.0035, d);
            float3 tint = mix(float3(0.2, 0.55, 1.0), float3(0.85, 0.3, 1.0), 0.5 + 0.5 * sin(xc * 2.0 + fl));
            color += tint * dot_ * (1.5 - abs(float(row)) * 0.36);
        }
    }
    return float4(dither(color, in.position.xy), 1.0);
}

// ---------- Космос ----------

fragment float4 warpFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2((in.uv.x - 0.5) * u.aspect, in.uv.y - 0.5);
    float r = length(p);
    float a = atan2(p.y, p.x);
    float3 color = float3(0.004, 0.006, 0.02) + float3(0.07, 0.1, 0.3) * exp(-r * 3.0);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float bins = 150.0 + fi * 70.0;
        float id = floor((a + 3.14159) / 6.28318 * bins);
        float seed = hash21(float2(id, fi));
        float speed = 0.1 + seed * 0.22;
        float z = fract(seed * 7.0 + u.time * speed);
        float head = z * z * 1.3;
        float len = 0.02 + z * 0.16;
        float along = smoothstep(head - len, head, r) * (1.0 - smoothstep(head, head + 0.004, r));
        float across = 1.0 - abs(fract((a + 3.14159) / 6.28318 * bins) - 0.5) * 2.0;
        float3 tint = mix(float3(0.65, 0.8, 1.0), float3(1.0, 0.75, 0.9), seed);
        color += tint * along * smoothstep(0.55, 1.0, across) * z * 1.6 * step(0.45, hash21(float2(id, fi + 9.0)));
    }
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 planetFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2((in.uv.x - 0.62) * u.aspect, in.uv.y - 0.54);
    float3 color = float3(0.006, 0.008, 0.024) + stars(float2(in.uv.x * u.aspect, in.uv.y), 60.0, u.time) * float3(0.85, 0.9, 1.0);
    color += float3(0.1, 0.05, 0.18) * fbm(float2(in.uv.x * u.aspect, in.uv.y) * 2.0, 3) * 0.8;
    float2 q = rot(-0.32) * p;
    float R = 0.27;
    float d = length(q);
    float2 ringCoord = q * float2(1.0, 3.6);
    float ring = length(ringCoord);
    float bands = 0.5 + 0.5 * sin(ring * 120.0) * noise(float2(ring * 60.0, 2.0));
    float ringMask = smoothstep(0.34, 0.36, ring) * (1.0 - smoothstep(0.58, 0.6, ring)) * (0.35 + 0.65 * bands);
    float3 ringColor = float3(0.95, 0.82, 0.62) * ringMask * 0.75;
    // Сначала задняя половина колец, затем планета, затем передняя половина.
    if (q.y < 0.0) color += ringColor;
    if (d < R) {
        float z = sqrt(R * R - d * d);
        float3 n = normalize(float3(q, z));
        float latitude = q.y / R;
        float cloud = fbm(float2(u.time * 0.012 + q.x * 3.0 + n.x, latitude * 11.0), 4);
        float3 surface = mix(float3(0.72, 0.5, 0.32), float3(0.98, 0.86, 0.66), cloud);
        surface = mix(surface, float3(0.5, 0.28, 0.24), smoothstep(0.55, 0.75, sin(latitude * 13.0 + cloud * 2.0) * 0.5 + 0.5) * 0.35);
        float light = max(dot(n, normalize(float3(-0.7, -0.35, 0.6))), 0.0);
        color = surface * (0.03 + light * 1.1);
    } else {
        color += float3(0.5, 0.42, 0.34) * exp(-(d - R) * 34.0) * 0.28;
    }
    if (q.y >= 0.0) color += ringColor;
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 blackHoleFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2((in.uv.x - 0.5) * u.aspect, in.uv.y - 0.5);
    float2 q = rot(0.16) * p;
    float r = length(q);
    float3 color = float3(0.004, 0.004, 0.012) + stars(float2(in.uv.x * u.aspect, in.uv.y), 70.0, u.time) * float3(0.8, 0.85, 1.0) * smoothstep(0.17, 0.3, r);
    float2 disk = q * float2(1.0, 4.2);
    float rd = length(disk);
    float angle = atan2(disk.y, disk.x);
    float swirl = fbm(float2(angle * 3.0 + rd * 12.0 - u.time * 0.5, rd * 15.0), 3);
    float glow = exp(-abs(rd - 0.3) * 8.0) * (0.45 + swirl);
    float doppler = 1.0 + 0.75 * cos(angle + 0.3);
    float3 hot = mix(float3(1.0, 0.42, 0.1), float3(1.0, 0.9, 0.72), swirl);
    float front = q.y > 0.0 ? 1.0 : smoothstep(0.17, 0.24, r);
    color += hot * glow * doppler * 0.9 * front;
    // Свет искривляется вокруг тени и образует тонкое кольцо.
    color += float3(1.0, 0.72, 0.45) * exp(-abs(r - 0.165) * 110.0) * 1.2;
    color *= smoothstep(0.145, 0.16, r);
    return float4(dither(color, in.position.xy), 1.0);
}

// ---------- Города ----------

static float buildings(float x, float scale, float seed, float base, float height, float time, thread float3& lights, float2 uv) {
    float cx = x * scale + seed;
    float id = floor(cx);
    float h = base + hash21(float2(id, seed)) * height;
    float inBuilding = step(1.0 - h, uv.y);
    if (inBuilding > 0.5) {
        float wx = fract(cx) * 7.0;
        float wy = (uv.y) * 170.0 * (scale / 7.0);
        float2 win = floor(float2(wx, wy));
        float2 wf = fract(float2(wx, wy));
        float on = step(0.78, hash21(win + id * 3.1));
        on *= 0.75 + 0.25 * sin(time * (0.1 + hash21(win) * 0.5) + hash21(win + 2.0) * 6.28);
        float shape = step(0.22, wf.x) * step(wf.x, 0.78) * step(0.25, wf.y) * step(wf.y, 0.72);
        float3 tint = mix(float3(1.0, 0.76, 0.42), float3(0.45, 0.8, 1.0), step(0.72, hash21(win + 5.0)));
        lights = tint * on * shape;
    }
    return inBuilding;
}

fragment float4 neonCityFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float x = uv.x * u.aspect;
    float3 color = mix(float3(0.34, 0.06, 0.42), float3(0.03, 0.02, 0.1), smoothstep(0.75, 0.05, uv.y));
    color += float3(0.95, 0.2, 0.55) * exp(-abs(uv.y - 0.62) * 5.0) * 0.32;
    float3 far = float3(0.0), mid = float3(0.0), near = float3(0.0);
    float layer1 = buildings(x, 11.0, 3.0, 0.3, 0.3, u.time, far, uv);
    color = mix(color, float3(0.1, 0.04, 0.2) + far * 0.35, layer1);
    float layer2 = buildings(x, 7.0, 11.0, 0.22, 0.34, u.time, mid, uv);
    color = mix(color, float3(0.045, 0.02, 0.1) + mid * 0.7, layer2);
    float layer3 = buildings(x, 4.0, 23.0, 0.14, 0.26, u.time, near, uv);
    color = mix(color, float3(0.012, 0.008, 0.03) + near, layer3);
    // Дождь: тонкие косые штрихи поверх всего.
    float2 r = float2(x * 90.0 + uv.y * 26.0, uv.y * 7.0 - u.time * 1.6);
    float rain = step(0.965, hash21(floor(r))) * smoothstep(0.0, 0.5, fract(r.y));
    color += float3(0.5, 0.6, 0.9) * rain * 0.16;
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 bokehFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2(in.uv.x * u.aspect, in.uv.y);
    float3 color = mix(float3(0.02, 0.025, 0.07), float3(0.07, 0.03, 0.09), in.uv.y);
    for (int i = 0; i < 26; i++) {
        float fi = float(i);
        float2 s = float2(hash21(float2(fi, 1.0)), hash21(float2(fi, 2.0)));
        float speed = 0.004 + s.y * 0.012;
        float2 center = float2(fract(s.x + u.time * speed) * (u.aspect + 0.4) - 0.2, 0.3 + s.y * 0.6 + 0.012 * sin(u.time * 0.3 + fi));
        float radius = 0.022 + hash21(float2(fi, 3.0)) * 0.05;
        float d = length(p - center);
        float disc = 1.0 - smoothstep(radius - 0.003, radius, d);
        float edge = smoothstep(radius * 0.72, radius, d) * disc;
        float pick = hash21(float2(fi, 4.0));
        float3 tint = pick < 0.34 ? float3(1.0, 0.6, 0.24) : pick < 0.67 ? float3(1.0, 0.25, 0.32) : float3(0.45, 0.72, 1.0);
        float twinkle = 0.75 + 0.25 * sin(u.time * (0.3 + pick) + fi);
        color += tint * (disc * 0.26 + edge * 0.24) * twinkle;
    }
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 skylineFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float x = uv.x * u.aspect;
    float3 color = mix(float3(1.0, 0.62, 0.36), float3(0.14, 0.17, 0.42), smoothstep(0.68, 0.05, uv.y));
    color = mix(color, float3(0.96, 0.4, 0.42), exp(-abs(uv.y - 0.6) * 9.0) * 0.5);
    float clouds = fbm(float2(x * 1.4 - u.time * 0.012, uv.y * 7.0), 4);
    color += float3(1.0, 0.72, 0.6) * smoothstep(0.5, 0.78, clouds) * smoothstep(0.75, 0.2, uv.y) * 0.3;
    float3 far = float3(0.0), near = float3(0.0);
    float layer1 = buildings(x, 9.0, 41.0, 0.2, 0.22, u.time, far, uv);
    color = mix(color, float3(0.34, 0.24, 0.42) + far * 0.2, layer1);
    float layer2 = buildings(x, 5.0, 57.0, 0.1, 0.24, u.time, near, uv);
    color = mix(color, float3(0.06, 0.05, 0.12) + near * 0.85, layer2);
    return float4(dither(color, in.position.xy), 1.0);
}

// ---------- Модное ----------

fragment float4 synthwaveFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = float2((in.uv.x - 0.5) * u.aspect, in.uv.y - 0.6);
    float3 sky = mix(float3(0.98, 0.25, 0.55), float3(0.08, 0.02, 0.2), smoothstep(0.02, -0.55, uv.y));
    float3 color = sky + stars(float2(in.uv.x * u.aspect, in.uv.y), 60.0, u.time) * smoothstep(-0.2, -0.45, uv.y);
    float2 sunP = uv - float2(0.0, -0.17);
    float sun = 1.0 - smoothstep(0.195, 0.2, length(sunP));
    float stripes = step(0.42, fract((sunP.y + u.time * 0.012) * 24.0)) + step(sunP.y, -0.02) * 0.0;
    float cut = sunP.y > -0.03 ? mix(1.0, stripes, smoothstep(-0.03, 0.17, sunP.y)) : 1.0;
    float3 sunColor = mix(float3(1.0, 0.86, 0.3), float3(1.0, 0.18, 0.55), smoothstep(-0.2, 0.17, sunP.y));
    color = mix(color, sunColor, sun * cut);
    color += float3(1.0, 0.3, 0.5) * exp(-length(sunP) * 4.5) * 0.25;
    // Горы на горизонте.
    float ridge = 0.075 * abs(sin(uv.x * 4.2 + 1.0)) + 0.05 * abs(sin(uv.x * 9.1 + 2.0)) + 0.02 * noise(float2(uv.x * 18.0, 1.0));
    float mount = step(-ridge, uv.y) * step(uv.y, 0.0);
    color = mix(color, float3(0.1, 0.02, 0.2) + float3(0.8, 0.1, 0.7) * smoothstep(ridge * -0.8, -ridge, uv.y) * 0.35, mount);
    if (uv.y > 0.0) {
        float z = 0.25 / uv.y;
        float2 g = float2(uv.x * z + 0.5, z + u.time * 0.6);
        float2 f = abs(fract(g) - 0.5);
        float w = 0.015 * z + 0.008;
        float lines = (1.0 - smoothstep(0.0, w, 0.5 - f.x)) + (1.0 - smoothstep(0.0, w, 0.5 - f.y));
        color = mix(float3(0.05, 0.0, 0.12), float3(1.0, 0.18, 0.75), min(lines, 1.0) * exp(-z * 0.12));
    }
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 chromeFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2(in.uv.x * u.aspect, in.uv.y) * 1.3;
    float t = u.time * 0.05;
    float2 q = float2(fbm(p + t, 3), fbm(p + float2(4.2, -t), 3));
    float f = fbm(p + 2.4 * q + float2(-t, t * 0.5), 3);
    float bands = sin(f * 22.0 + q.x * 6.0);
    float metal = pow(0.5 + 0.5 * bands, 2.2);
    float3 color = mix(float3(0.03, 0.035, 0.05), float3(0.62, 0.66, 0.74), metal);
    color += float3(1.0) * pow(metal, 14.0) * 0.8;
    // Радужный отлив, как у жидкого хрома.
    float3 iridescent = 0.5 + 0.5 * cos(6.28318 * (f * 2.2 + float3(0.0, 0.33, 0.67)));
    color = mix(color, color * (0.55 + iridescent * 0.9), 0.55);
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 lavaFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2(in.uv.x * u.aspect, in.uv.y);
    float t = u.time * 0.12;
    float field = 0.0;
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        float2 c = float2(
            u.aspect * (0.5 + 0.46 * sin(t * (0.5 + fi * 0.07) + fi * 2.4)),
            0.5 + 0.56 * sin(t * (0.37 + fi * 0.05) + fi * 1.1));
        float r = 0.09 + hash21(float2(fi, 3.0)) * 0.09;
        field += r * r / max(dot(p - c, p - c), 0.0004);
    }
    float blob = smoothstep(0.95, 1.05, field);
    float rim = smoothstep(0.7, 1.0, field) * (1.0 - blob);
    float3 bg = mix(float3(0.98, 0.42, 0.62), float3(0.32, 0.2, 0.98), in.uv.y);
    float3 inside = mix(float3(1.0, 0.86, 0.32), float3(1.0, 0.3, 0.42), clamp((field - 1.0) * 0.1, 0.0, 1.0));
    float3 color = mix(bg, inside, blob) + float3(1.0, 0.9, 0.8) * rim * 0.28;
    // Лёгкое зерно, как на модных постерах.
    color += (hash21(in.position.xy * 0.73 + fract(u.time)) - 0.5) * 0.045;
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 prismFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2((in.uv.x - 0.5) * u.aspect, in.uv.y - 0.5);
    float t = u.time * 0.05;
    float3 color = float3(0.012, 0.012, 0.03);
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float2 q = rot(t * (0.6 + fi * 0.2) + fi * 1.26) * p;
        float offset = 0.09 * sin(q.x * 3.0 + t * 4.0 + fi);
        float d = abs(q.y + offset);
        float3 tint = 0.5 + 0.5 * cos(6.28318 * (fi * 0.18 + t + float3(0.0, 0.33, 0.67)));
        color += tint * exp(-d * 13.0) * 0.5;
    }
    color = color / (1.0 + color * 0.45);
    return float4(dither(color, in.position.xy), 1.0);
}

// ---------- Природа ----------

fragment float4 oceanFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = float2(in.uv.x * u.aspect, in.uv.y);
    float horizon = 0.46;
    float3 color;
    float2 moon = float2(u.aspect * 0.6, 0.2);
    if (uv.y < horizon) {
        color = mix(float3(0.02, 0.04, 0.13), float3(0.1, 0.17, 0.32), smoothstep(0.0, horizon, uv.y));
        color += stars(uv, 60.0, u.time) * smoothstep(horizon, 0.1, uv.y);
        float d = length(uv - moon);
        color += float3(1.0, 0.97, 0.88) * (1.0 - smoothstep(0.052, 0.055, d));
        color += float3(0.5, 0.58, 0.72) * exp(-d * 7.0) * 0.45;
    } else {
        float depth = (uv.y - horizon) / (1.0 - horizon);
        float z = 1.0 / (depth + 0.05);
        float2 w = float2(uv.x * z * 1.8, z * 2.6 + u.time * 0.26);
        float waves = fbm(w, 3) + 0.5 * fbm(w * 2.3 + float2(u.time * 0.18, 0.0), 2);
        color = mix(float3(0.05, 0.1, 0.2), float3(0.012, 0.035, 0.08), depth);
        float path = exp(-abs(uv.x - moon.x) * (2.2 + 9.0 * (1.0 - depth)));
        float glitter = smoothstep(0.72, 0.98, waves);
        color += float3(0.92, 0.95, 1.0) * path * glitter * 0.95;
        color += float3(0.1, 0.17, 0.25) * waves * 0.3;
    }
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 forestFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float x = uv.x * u.aspect;
    float3 color = mix(float3(0.92, 0.84, 0.66), float3(0.42, 0.62, 0.68), smoothstep(0.65, 0.0, uv.y));
    float t = u.time * 0.01;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float depth = fi / 4.0;
        float scale = 3.0 + fi * 2.4;
        float cx = x * scale + fi * 13.0;
        float id = floor(cx);
        float f = fract(cx) - 0.5;
        float height = 0.3 + 0.24 * hash21(float2(id, fi)) + depth * 0.1;
        float top = 1.0 - height - (1.0 - depth) * 0.12;
        float along = (uv.y - top) / height;
        // Пила из веток: ель сужается кверху и имеет зубцы.
        float teeth = 0.5 + 0.5 * fract(along * 7.0);
        float tree = step(abs(f), 0.42 * clamp(along, 0.0, 1.0) * teeth) * step(top, uv.y);
        float3 fog = mix(float3(0.62, 0.74, 0.72), float3(0.05, 0.11, 0.1), depth);
        color = mix(color, fog, max(tree, step(top + height * 0.82, uv.y)));
        float mist = fbm(float2(x * 1.5 + t * (2.0 + fi * 3.0), uv.y * 4.0 + fi * 3.0), 3);
        color = mix(color, float3(0.9, 0.9, 0.82), smoothstep(0.42, 0.75, mist) * (0.3 - depth * 0.2) * smoothstep(0.25, 0.85, uv.y));
    }
    return float4(dither(color, in.position.xy), 1.0);
}
"""#
