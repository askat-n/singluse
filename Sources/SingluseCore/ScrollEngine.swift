import Foundation

/// Настройки плавной прокрутки. Чистые данные: без AppKit, чтобы физику можно было тестировать.
public struct ScrollSettings: Equatable, Sendable {
    /// Множитель длины шага колеса (1 = примерно 3 строки текста за щелчок).
    public var speed: Double
    /// 0 — резко, 1 — очень мягко.
    public var smoothness: Double
    /// 0 — без разгона, 1 — сильный разгон при быстром вращении колеса.
    public var acceleration: Double
    public var invert: Bool

    public init(speed: Double = 1.2, smoothness: Double = 0.75, acceleration: Double = 0.25, invert: Bool = false) {
        self.speed = speed
        self.smoothness = smoothness
        self.acceleration = acceleration
        self.invert = invert
    }
}

/// Превращает щелчки колеса в поток пикселей через двухступенчатый фильтр.
/// В отличие от простого затухания движение и начинается плавно, и плавно заканчивается,
/// а итоговый путь всегда совпадает с заказанным с точностью до пикселя.
public struct ScrollEngine: Sendable {
    public static let pixelsPerLine = 48.0

    private struct Axis: Sendable {
        var goal = 0.0
        var filter = 0.0
        var position = 0.0
        var sent = 0.0

        var isIdle: Bool { goal == 0 && position == 0 && sent == 0 }

        mutating func add(_ delta: Double) {
            guard delta != 0 else { return }
            // Смена направления сразу гасит остаток: страница не «тянет» в старую сторону.
            let remaining = goal - position
            if remaining != 0, (remaining < 0) != (delta < 0) {
                goal = position
                filter = position
            }
            goal += delta
        }

        mutating func step(alpha: Double) -> Int32 {
            guard !isIdle else { return 0 }
            filter += (goal - filter) * alpha
            position += (filter - position) * alpha
            if abs(goal - position) < 0.5 { position = goal; filter = goal }
            let output = position.rounded() - sent
            sent += output
            if position == goal {
                // Жест закончен: сбрасываем счётчики, чтобы они не росли бесконечно.
                let tail = goal.rounded() - sent
                goal = 0; filter = 0; position = 0; sent = 0
                return Int32(output + tail)
            }
            return Int32(output)
        }
    }

    public var settings: ScrollSettings
    private var y = Axis()
    private var x = Axis()
    private var lastWheelTime: TimeInterval?

    public init(settings: ScrollSettings = ScrollSettings()) {
        self.settings = settings
    }

    public var isIdle: Bool { y.isIdle && x.isIdle }

    /// Постоянная времени одной ступени фильтра.
    var timeConstant: Double { 0.012 + settings.smoothness * 0.09 }

    /// Добавляет щелчок колеса. `time` — монотонное время в секундах.
    public mutating func addWheel(deltaY: Int, deltaX: Int, at time: TimeInterval) {
        let multiplier = accelerationMultiplier(at: time)
        lastWheelTime = time
        let sign = settings.invert ? -1.0 : 1.0
        let base = Self.pixelsPerLine * settings.speed * multiplier * sign
        y.add(Double(deltaY) * base)
        x.add(Double(deltaX) * base)
    }

    private func accelerationMultiplier(at time: TimeInterval) -> Double {
        guard let last = lastWheelTime else { return 1 }
        let interval = time - last
        let window = 0.12
        guard interval < window else { return 1 }
        let intensity = (window - max(interval, 0)) / window
        return 1 + settings.acceleration * 3 * intensity
    }

    /// Шаг симуляции. Возвращает целые пиксели; длинный кадр не даёт рывка.
    public mutating func step(dt: TimeInterval) -> (dy: Int32, dx: Int32) {
        let alpha = 1 - exp(-min(max(dt, 0), 0.05) / timeConstant)
        return (y.step(alpha: alpha), x.step(alpha: alpha))
    }
}

/// Один щелчок колеса, записанный во время калибровки.
public struct WheelSample: Sendable, Equatable {
    public var time: TimeInterval
    public var delta: Int
    public init(time: TimeInterval, delta: Int) {
        self.time = time
        self.delta = delta
    }
}

public struct WheelProfile: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case notched, highResolution }
    public var kind: Kind
    public var ticksPerSecond: Double
    public var speed: Double
    public var smoothness: Double
    public var acceleration: Double
}

/// Подбирает настройки по тому, как реально работает колесо конкретной мыши.
public enum WheelCalibrator {
    public static let minimumSamples = 10
    /// Комфортная скорость страницы при обычном темпе вращения.
    private static let targetPixelsPerSecond = 1100.0

    public static func analyze(_ samples: [WheelSample]) -> WheelProfile? {
        guard samples.count >= minimumSamples else { return nil }
        let sorted = samples.sorted { $0.time < $1.time }
        // Паузы между движениями пальца не считаются темпом вращения.
        let intervals = zip(sorted, sorted.dropFirst())
            .map { $1.time - $0.time }
            .filter { $0 > 0 && $0 < 0.35 }
            .sorted()
        guard intervals.count >= minimumSamples / 2 else { return nil }
        let median = intervals[intervals.count / 2]
        let rate = 1 / median
        let kind: WheelProfile.Kind = median < 0.015 ? .highResolution : .notched
        let speed = min(max(targetPixelsPerSecond / (rate * ScrollEngine.pixelsPerLine), 0.5), 2.4)
        return WheelProfile(
            kind: kind,
            ticksPerSecond: rate,
            speed: speed,
            // Колесо с щелчками нуждается в большем сглаживании, у гладкого шаги и так мелкие.
            smoothness: kind == .notched ? 0.75 : 0.45,
            acceleration: kind == .notched ? 0.25 : 0
        )
    }
}
