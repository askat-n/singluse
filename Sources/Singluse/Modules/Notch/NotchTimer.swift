import AppKit
import Combine
import SwiftUI

/// Таймер как на iPhone: идёт от конечной даты, поэтому не сбивается при сне Mac и перезапуске Singluse.
@MainActor
final class NotchTimer: ObservableObject {
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: Double?
    @Published private(set) var total: Double = 0
    @Published private(set) var isRinging = false

    private let d = UserDefaults.standard
    private var fireTimer: Timer?
    private var ringTimer: Timer?
    private var ringCount = 0
    private var wakeObserver: NSObjectProtocol?

    init() {
        total = d.double(forKey: "timer.total")
        if let end = d.object(forKey: "timer.end") as? Date { endDate = end }
        if d.object(forKey: "timer.paused") != nil { pausedRemaining = d.double(forKey: "timer.paused") }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        schedule()
    }

    var isActive: Bool { endDate != nil || pausedRemaining != nil }
    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at date: Date = Date()) -> Double {
        if let pausedRemaining { return pausedRemaining }
        guard let endDate else { return 0 }
        return max(endDate.timeIntervalSince(date), 0)
    }

    func progress(at date: Date = Date()) -> Double {
        total > 0 ? min(remaining(at: date) / total, 1) : 0
    }

    func start(minutes: Int) {
        stopRinging()
        total = Double(minutes) * 60
        pausedRemaining = nil
        endDate = Date(timeIntervalSinceNow: total)
        changed()
    }

    func pause() {
        guard let endDate else { return }
        pausedRemaining = max(endDate.timeIntervalSinceNow, 0)
        self.endDate = nil
        changed()
    }

    func resume() {
        guard let pausedRemaining else { return }
        endDate = Date(timeIntervalSinceNow: pausedRemaining)
        self.pausedRemaining = nil
        changed()
    }

    func cancel() {
        endDate = nil
        pausedRemaining = nil
        total = 0
        stopRinging()
        changed()
    }

    func addMinute() {
        if let pausedRemaining {
            self.pausedRemaining = pausedRemaining + 60
        } else if let endDate {
            self.endDate = endDate.addingTimeInterval(60)
        } else {
            start(minutes: 1)
            return
        }
        total += 60
        changed()
    }

    func stopRinging() {
        ringTimer?.invalidate()
        ringTimer = nil
        ringCount = 0
        if isRinging { isRinging = false }
    }

    private func changed() {
        if let endDate { d.set(endDate, forKey: "timer.end") } else { d.removeObject(forKey: "timer.end") }
        if let pausedRemaining { d.set(pausedRemaining, forKey: "timer.paused") } else { d.removeObject(forKey: "timer.paused") }
        d.set(total, forKey: "timer.total")
        schedule()
    }

    private func schedule() {
        fireTimer?.invalidate()
        fireTimer = nil
        guard let endDate else { return }
        let delay = endDate.timeIntervalSinceNow
        guard delay > 0 else {
            finish()
            return
        }
        fireTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func finish() {
        endDate = nil
        pausedRemaining = nil
        total = 0
        d.removeObject(forKey: "timer.end")
        d.removeObject(forKey: "timer.paused")
        isRinging = true
        playRing()
        // Звенит, пока не остановят, но не бесконечно: Mac мог остаться без присмотра.
        ringTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ringCount += 1
                if self.ringCount >= 27 { self.stopRinging() } else { self.playRing() }
            }
        }
    }

    private func playRing() {
        let name = AppSettings.shared.timerSound
        guard !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }

    static func format(_ seconds: Double) -> String {
        let value = Int(seconds.rounded(.up))
        let hours = value / 3600, minutes = value % 3600 / 60, rest = value % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// Оставшееся время, обновляется само. На паузе просто стоит на месте.
struct TimerText: View {
    @ObservedObject var timer: NotchTimer
    let size: CGFloat
    var weight: Font.Weight = .semibold

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(NotchTimer.format(timer.remaining(at: context.date)))
                .font(.system(size: size, weight: weight, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(.smooth(duration: 0.25), value: Int(timer.remaining(at: context.date)))
        }
    }
}

/// Страница таймера: готовые времена запускаются одним нажатием, как недавние таймеры на iPhone.
struct NotchTimerPage: View {
    @ObservedObject private var timer = Coordinator.shared.timer
    @ObservedObject private var settings = AppSettings.shared
    @State private var customMinutes = 15

    var body: some View {
        Group {
            if timer.isRinging {
                ringing
            } else if timer.isActive {
                running
            } else {
                presets
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.panel, value: timer.isActive)
    }

    private var ringing: some View {
        HStack(spacing: 18) {
            Image(systemName: "bell.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .repeating)
            Text("Время вышло").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            Spacer(minLength: 0)
            Button { timer.stopRinging() } label: {
                Text("Стоп")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 72, height: 38)
                    .background(Capsule().fill(.orange))
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.horizontal, 16)
    }

    private var running: some View {
        HStack(spacing: 0) {
            roundButton("xmark", tint: .white.opacity(0.16), foreground: .white, label: L("Отмена")) { timer.cancel() }
            Spacer()
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: 5)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Circle()
                        .trim(from: 0, to: timer.progress(at: context.date))
                        .stroke(.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: timer.progress(at: context.date))
                }
                TimerText(timer: timer, size: 21).foregroundStyle(timer.isPaused ? .white.opacity(0.55) : .white)
            }
            .frame(width: 104, height: 104)
            Spacer()
            VStack(spacing: 8) {
                roundButton(timer.isPaused ? "play.fill" : "pause.fill", tint: .orange.opacity(0.28), foreground: .orange, label: timer.isPaused ? L("Продолжить") : L("Пауза")) {
                    timer.isPaused ? timer.resume() : timer.pause()
                }
                Button { timer.addMinute() } label: {
                    Text("+1 мин")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 54, height: 22)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(.horizontal, 22)
    }

    private var presets: some View {
        HStack(spacing: 12) {
            ForEach(Array(settings.timerPresets.enumerated()), id: \.offset) { _, minutes in
                Button { timer.start(minutes: minutes) } label: {
                    VStack(spacing: 0) {
                        Text("\(minutes)").font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("мин").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.orange)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(.orange.opacity(0.2)))
                    .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
            }
            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 52)
            VStack(spacing: 6) {
                HStack(spacing: 2) {
                    stepButton("minus") { customMinutes = max(customMinutes - 1, 1) }
                    Text("\(customMinutes)")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 34)
                        .contentTransition(.numericText())
                    stepButton("plus") { customMinutes = min(customMinutes + 1, 180) }
                }
                Button { timer.start(minutes: customMinutes) } label: {
                    Text("Старт")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 84, height: 24)
                        .background(Capsule().fill(.orange))
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func roundButton(_ symbol: String, tint: Color, foreground: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(foreground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 54, height: 54)
                .background(Circle().fill(tint))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(label)
    }
}

/// Таймер закончился: чёлка сама открывается ровно настолько, чтобы его остановить.
struct NotchTimerAlertView: View {
    let topInset: CGFloat
    @ObservedObject private var timer = Coordinator.shared.timer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .repeating)
            Text("Время вышло").foregroundStyle(.white)
            Spacer(minLength: 0)
            Button { timer.addMinute() } label: {
                Text("+1 мин")
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 26)
                    .background(Capsule().fill(.white.opacity(0.16)))
            }
            .buttonStyle(PressableButtonStyle())
            Button { timer.stopRinging() } label: {
                Text("Стоп")
                    .foregroundStyle(.black)
                    .frame(width: 62, height: 26)
                    .background(Capsule().fill(.orange))
            }
            .buttonStyle(PressableButtonStyle())
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.top, topInset + 2)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
