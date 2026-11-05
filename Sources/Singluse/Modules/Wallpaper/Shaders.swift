import AppKit
import CoreImage
import Metal
import MetalKit

/// Разделы каталога обоев.
enum WallpaperSection: String, CaseIterable, Identifiable {
    case tech, space, city, modern, nature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tech: return L("Технологии")
        case .space: return L("Космос")
        case .city: return L("Города")
        case .modern: return L("Модное")
        case .nature: return L("Природа")
        }
    }

    var symbol: String {
        switch self {
        case .tech: return "cpu.fill"
        case .space: return "sparkles"
        case .city: return "building.2.fill"
        case .modern: return "wand.and.stars"
        case .nature: return "leaf.fill"
        }
    }
}

/// Встроенные живые обои. Они рисуются шейдерами: не занимают места, не требуют скачивания
/// и остаются чёткими на любом экране. Все написаны для Singluse, поэтому прав третьих лиц здесь нет.
enum ShaderPreset: String, CaseIterable, Identifiable {
    case grid, matrix, circuit, dataWave
    case warp, planet, blackHole, nebula
    case neonCity, bokeh, skyline
    case synthwave, chrome, lava, prism, bloom, liquid
    case aurora, dunes, ocean, forest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return L("Неоновая сетка")
        case .matrix: return L("Поток данных")
        case .circuit: return L("Микросхема")
        case .dataWave: return L("Цифровая волна")
        case .warp: return L("Гиперпрыжок")
        case .planet: return L("Планета с кольцами")
        case .blackHole: return L("Чёрная дыра")
        case .nebula: return L("Туманность")
        case .neonCity: return L("Неоновый город")
        case .bokeh: return L("Огни ночного города")
        case .skyline: return L("Закат над городом")
        case .synthwave: return L("Синтвейв")
        case .chrome: return L("Жидкий хром")
        case .lava: return L("Лавовая лампа")
        case .prism: return L("Призма")
        case .bloom: return L("Мягкий свет")
        case .liquid: return L("Жидкий шёлк")
        case .aurora: return L("Северное сияние")
        case .dunes: return L("Дюны на закате")
        case .ocean: return L("Лунный океан")
        case .forest: return L("Лес в тумане")
        }
    }

    var section: WallpaperSection {
        switch self {
        case .grid, .matrix, .circuit, .dataWave: return .tech
        case .warp, .planet, .blackHole, .nebula: return .space
        case .neonCity, .bokeh, .skyline: return .city
        case .synthwave, .chrome, .lava, .prism, .bloom, .liquid: return .modern
        case .aurora, .dunes, .ocean, .forest: return .nature
        }
    }

    var function: String { rawValue + "Fragment" }
}

private let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 position [[position]]; float2 uv; };
struct Uniforms { float time; float aspect; };

vertex VOut fullscreenVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p, int octaves) {
    float value = 0.0, amplitude = 0.5;
    float2x2 rotation = float2x2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < octaves; i++) {
        value += amplitude * noise(p);
        p = rotation * p * 2.02;
        amplitude *= 0.5;
    }
    return value;
}

// Убирает ступеньки на тёмных градиентах.
static float3 dither(float3 color, float2 position) {
    return color + (hash21(position * 0.37) - 0.5) / 255.0;
}

static float stars(float2 uv, float density, float time) {
    float2 grid = uv * density;
    float2 id = floor(grid);
    float2 f = fract(grid) - 0.5;
    float seed = hash21(id);
    if (seed < 0.93) return 0.0;
    float2 offset = float2(hash21(id + 3.1), hash21(id + 7.7)) - 0.5;
    float d = length(f - offset * 0.7);
    float twinkle = 0.65 + 0.35 * sin(time * (0.6 + seed * 2.0) + seed * 40.0);
    return (1.0 - smoothstep(0.0, 0.085, d)) * twinkle * (0.35 + (seed - 0.93) * 9.0);
}

fragment float4 auroraFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float2 p = float2(uv.x * u.aspect, uv.y);
    float t = u.time * 0.07;

    float3 color = mix(float3(0.012, 0.022, 0.075), float3(0.03, 0.075, 0.13), smoothstep(0.0, 0.82, uv.y));
    color += stars(p, 62.0, u.time) * float3(0.85, 0.92, 1.0) * (1.0 - smoothstep(0.35, 0.8, uv.y));

    float3 aurora = float3(0.0);
    float3 low[3] = { float3(0.12, 1.00, 0.58), float3(0.10, 0.85, 0.80), float3(0.45, 0.45, 1.00) };
    float3 high[3] = { float3(0.10, 0.45, 0.70), float3(0.30, 0.20, 0.85), float3(0.70, 0.18, 0.75) };
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float wave = fbm(float2(p.x * 1.3 + t * (1.0 + fi * 0.4) + fi * 5.0, t * 0.6 + fi), 3);
        float fold = sin(p.x * (3.0 + fi) + wave * 9.0 + t * 2.0) * 0.035;
        float baseline = 0.62 - fi * 0.13 + (wave - 0.5) * 0.42 + fold;
        float above = baseline - uv.y;
        // Яркий нижний край и длинный тающий хвост вверх, как у настоящих полярных занавесей.
        float curtain = above > 0.0 ? exp(-above * (5.5 + fi)) : exp(above * 26.0);
        float rays = 0.35 + 1.1 * fbm(float2(p.x * 22.0 + wave * 10.0 + t * 3.0, t * 0.8 + fi * 9.0), 2);
        float3 tone = mix(low[i], high[i], smoothstep(0.0, 0.32, above));
        aurora += tone * curtain * rays * (0.85 - fi * 0.17);
    }
    color += aurora;

    // Горы и озеро внизу дают масштаб и спокойную тёмную зону под значки.
    float x = p.x;
    float ridge = 0.70 + 0.20 * fbm(float2(x * 3.4 + 3.0, 1.0), 4);
    float near = 0.79 + 0.18 * fbm(float2(x * 5.5 + 11.0, 4.0), 4);
    float lake = 0.915;
    if (uv.y > lake) {
        float mirrored = lake - (uv.y - lake) * 2.4;
        float ripple = fbm(float2(x * 5.0 + u.time * 0.04, uv.y * 150.0 - u.time * 0.18), 3);
        float3 reflection = float3(0.0);
        for (int i = 0; i < 2; i++) {
            float fi = float(i);
            float wave = fbm(float2(p.x * 1.3 + t * (1.0 + fi * 0.4) + fi * 5.0, t * 0.6 + fi), 3);
            float glow = exp(-abs((0.62 - fi * 0.13 + (wave - 0.5) * 0.42) - mirrored) * 2.6);
            reflection += low[i] * glow * 0.20;
        }
        color = float3(0.006, 0.012, 0.03) + reflection * (0.35 + 0.95 * ripple);
    } else {
        color = mix(color, float3(0.018, 0.035, 0.075), smoothstep(ridge - 0.002, ridge + 0.002, uv.y));
        color = mix(color, float3(0.006, 0.012, 0.028), smoothstep(near - 0.002, near + 0.002, uv.y));
    }
    color = color / (1.0 + color * 0.22);
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 liquidFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2(in.uv.x * u.aspect, in.uv.y) * 0.85;
    float t = u.time * 0.04;
    float2 q = float2(fbm(p + float2(0.0, t), 2), fbm(p + float2(5.2, 1.3 - t), 2));
    float2 r = float2(fbm(p + 2.0 * q + float2(1.7 - t, 9.2), 2), fbm(p + 2.0 * q + float2(8.3, 2.8 + t), 2));
    float field = (p.x * 0.9 - p.y * 0.55) + 2.1 * r.x + 1.2 * q.y;

    // Складки ткани: плавные полосы света поперёк течения.
    float folds = 0.5 + 0.5 * sin(field * 15.0);
    folds = pow(folds, 1.6);
    float broad = smoothstep(0.1, 0.8, 0.5 + 0.5 * sin(field * 3.4 + 1.0));

    float3 deep = float3(0.09, 0.05, 0.27);
    float3 violet = float3(0.42, 0.17, 0.78);
    float3 rose = float3(0.93, 0.30, 0.55);
    float3 peach = float3(1.00, 0.72, 0.58);
    float3 color = mix(deep, violet, folds * 0.9);
    color = mix(color, rose, broad * pow(folds, 1.5) * 0.85);
    color = mix(color, peach, broad * pow(folds, 7.0) * 0.8);
    color *= 0.78 + 0.22 * broad;
    color *= 1.0 - 0.18 * length(in.uv - 0.5);
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 nebulaFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2(in.uv.x * u.aspect, in.uv.y);
    float t = u.time * 0.022;
    float2 warp = float2(fbm(p * 1.3 + t, 3), fbm(p * 1.3 - t + 4.0, 3));
    float cloud = fbm(p * 1.55 + warp * 2.3 + float2(t, -t * 0.5), 4);
    float dust = fbm(p * 3.6 - warp * 1.9 + 7.0, 3);

    float3 color = float3(0.008, 0.012, 0.042);
    color += float3(0.03, 0.26, 0.52) * smoothstep(0.26, 0.56, cloud) * 1.15;
    color += float3(0.72, 0.13, 0.52) * smoothstep(0.40, 0.68, cloud) * 0.95;
    color += float3(1.00, 0.58, 0.34) * pow(smoothstep(0.54, 0.80, cloud), 2.0) * 1.1;
    color *= 1.0 - smoothstep(0.40, 0.68, dust) * 0.62;

    float field = stars(p, 34.0, u.time) * 1.1 + stars(p + 3.3, 76.0, u.time * 1.4) * 0.75;
    color += field * float3(0.92, 0.96, 1.0);
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 dunesFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float x = uv.x * u.aspect;
    float t = u.time * 0.035;

    float3 sky = mix(float3(1.00, 0.56, 0.34), float3(0.20, 0.13, 0.42), smoothstep(0.30, 0.95, 1.0 - uv.y));
    sky = mix(sky, float3(0.05, 0.06, 0.20), smoothstep(0.65, 1.05, 1.0 - uv.y));
    float2 sunCenter = float2(u.aspect * 0.70, 0.46 + 0.02 * sin(t));
    float sunDistance = length(float2(x, uv.y) - sunCenter);
    float3 color = sky + float3(1.0, 0.72, 0.45) * ((1.0 - smoothstep(0.068, 0.075, sunDistance)) + 0.30 * exp(-sunDistance * 5.5));
    color += float3(1.0, 0.8, 0.75) * 0.05 * fbm(float2(x * 1.5 - t, uv.y * 5.0), 3) * (1.0 - smoothstep(0.3, 0.65, uv.y));

    float3 far = float3(0.45, 0.20, 0.38), near = float3(0.035, 0.022, 0.085);
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float depth = fi / 4.0;
        float frequency = 1.1 + fi * 0.55;
        float height = 0.52 + depth * 0.36
            + 0.055 * sin(x * frequency + t * (0.5 + depth) + fi * 2.1)
            + 0.024 * sin(x * frequency * 2.4 - t * 0.7 + fi)
            + 0.016 * (fbm(float2(x * 2.8 + fi * 9.0 + t * 0.2, fi), 3) - 0.5);
        float mask = smoothstep(height - 0.0016, height + 0.0016, uv.y);
        // Подсветка гребня со стороны солнца.
        float rim = exp(-max(uv.y - height, 0.0) * 34.0) * mask;
        float3 dune = mix(far, near, depth) + float3(1.0, 0.55, 0.32) * rim * (0.34 - depth * 0.26);
        color = mix(color, dune, mask);
    }
    return float4(dither(color, in.position.xy), 1.0);
}

fragment float4 bloomFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = float2(in.uv.x * u.aspect, in.uv.y);
    float t = u.time * 0.11;
    float3 colors[5] = {
        float3(0.16, 0.30, 0.98), float3(0.60, 0.22, 0.96), float3(1.00, 0.30, 0.58),
        float3(0.10, 0.70, 0.95), float3(1.00, 0.56, 0.72)
    };
    float3 accumulated = float3(0.0);
    float weights = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float2 center = float2(
            u.aspect * (0.5 + 0.48 * sin(t * (0.61 + fi * 0.13) + fi * 2.4)),
            0.5 + 0.50 * cos(t * (0.47 + fi * 0.17) + fi * 1.3));
        float weight = 1.0 / (0.035 + pow(length(p - center), 2.6));
        accumulated += colors[i] * weight;
        weights += weight;
    }
    float3 color = accumulated / weights;
    color *= 0.90 + 0.10 * fbm(p * 2.0 + t * 0.4, 3);
    // Насыщенность: среднее цветов всегда уходит в серое, возвращаем чистоту.
    float luma = dot(color, float3(0.3, 0.59, 0.11));
    color = clamp(mix(float3(luma), color, 1.45), 0.0, 1.0);
    return float4(dither(color, in.position.xy), 1.0);
}
"""#

private struct ShaderUniforms {
    var time: Float
    var aspect: Float
}

/// Общие ресурсы Metal: один девайс и кэш пайплайнов на все окна.
final class ShaderEngine {
    static let shared = ShaderEngine()

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    private var library: MTLLibrary?
    private var pipelines: [ShaderPreset: MTLRenderPipelineState] = [:]
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        do {
            library = try device?.makeLibrary(source: shaderSource + shaderCollectionSource, options: nil)
        } catch {
            NSLog("Singluse: shader compile failed: \(error)")
        }
    }

    func pipeline(for preset: ShaderPreset) -> MTLRenderPipelineState? {
        if let cached = pipelines[preset] { return cached }
        guard let device, let library,
              let vertex = library.makeFunction(name: "fullscreenVertex"),
              let fragment = library.makeFunction(name: preset.function) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        let state = try? device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[preset] = state
        return state
    }

    /// Рисует один кадр обоев в PNG-файл.
    static func renderFrame(preset: ShaderPreset, width: Int, height: Int, time: Float = 40, to url: URL) -> Bool {
        let engine = shared
        guard let device = engine.device, let queue = engine.queue, let pipeline = engine.pipeline(for: preset) else { return false }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var uniforms = ShaderUniforms(time: time, aspect: Float(width) / Float(height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: space]) else { return false }
        let flipped = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height)))
        return (try? CIContext().writePNGRepresentation(of: flipped, to: url, format: .RGBA8, colorSpace: space)) != nil
    }

    /// Рисует все обои в PNG-файлы. Возвращает false, если хотя бы один шейдер не собрался.
    static func renderPreviews(to directory: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var ok = true
        for preset in ShaderPreset.allCases {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(preset.rawValue).png")
            if !renderFrame(preset: preset, width: 960, height: 600, to: url) {
                print("FAILED:", preset.rawValue)
                ok = false
            }
        }
        return ok
    }
}

/// Вид, в котором непрерывно идёт шейдер. Его используют и окна обоев, и миниатюры в настройках.
final class ShaderView: MTKView, MTKViewDelegate {
    var preset: ShaderPreset { didSet { pipelineState = ShaderEngine.shared.pipeline(for: preset) } }
    var speed: Double = 1
    /// Плавные поля не теряют в качестве при меньшем разрешении, а GPU нагружается заметно слабее.
    var renderScale: CGFloat = 1

    private var pipelineState: MTLRenderPipelineState?
    private var elapsed: Double
    private var lastFrame: CFTimeInterval?
    private static let sharedStart = Double.random(in: 0...600)
    private var hasDrawnFrame = false
    private var wantsPause = false

    init(preset: ShaderPreset, framesPerSecond: Int = 30) {
        self.preset = preset
        // Случайный, но общий для всех экранов старт: мониторы показывают один и тот же момент.
        elapsed = Self.sharedStart
        super.init(frame: .zero, device: ShaderEngine.shared.device)
        pipelineState = ShaderEngine.shared.pipeline(for: preset)
        colorPixelFormat = ShaderEngine.pixelFormat
        framebufferOnly = true
        autoResizeDrawable = false
        preferredFramesPerSecond = framesPerSecond
        enableSetNeedsDisplay = false
        isPaused = false
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    func updateDrawableSize() {
        let width = max(bounds.width * renderScale, 1)
        let height = max(bounds.height * renderScale, 1)
        drawableSize = CGSize(width: width, height: height)
    }

    func setPaused(_ paused: Bool) {
        wantsPause = paused
        if !paused {
            if isPaused { lastFrame = nil }
            isPaused = false
        } else if hasDrawnFrame {
            isPaused = true
        }
        // Иначе пауза включится сразу после первого кадра: без него вид остался бы чёрным.
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        if let lastFrame { elapsed += min(now - lastFrame, 0.2) * speed }
        lastFrame = now

        guard let pipelineState,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = ShaderEngine.shared.queue?.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = ShaderUniforms(
            // Остаток от большого периода: у Float иначе теряется точность за часы работы.
            time: Float(elapsed.truncatingRemainder(dividingBy: 20_000)),
            aspect: Float(max(bounds.width, 1) / max(bounds.height, 1))
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        hasDrawnFrame = true
        if wantsPause { isPaused = true }
    }
}
