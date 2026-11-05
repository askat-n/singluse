import ServiceManagement
import AppKit

// Приложение создано на русском: пока человек сам не выбрал язык, не переключаем его на язык системы.
if UserDefaults.standard.object(forKey: "languageChosen") == nil {
    UserDefaults.standard.set(true, forKey: "languageChosen")
    if UserDefaults.standard.persistentDomain(forName: "com.askatbek.singluse")?["AppleLanguages"] == nil {
        UserDefaults.standard.set(["ru"], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        // Язык читается при старте процесса, поэтому запускаемся заново уже с ним.
        if CommandLine.arguments.count == 1 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", Bundle.main.bundlePath]
            try? process.run()
            exit(0)
        }
    }
}

// Служебный режим: отрисовать все живые обои в PNG (для проверки без запуска интерфейса).
if let index = CommandLine.arguments.firstIndex(of: "--render-wallpapers"), index + 1 < CommandLine.arguments.count {
    exit(ShaderEngine.renderPreviews(to: CommandLine.arguments[index + 1]) ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-notch"), index + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[index + 1]
    let page = index + 2 < CommandLine.arguments.count ? CommandLine.arguments[index + 2] : "music"
    exit(MainActor.assumeIsolated { renderExpandedNotch(to: path, page: page) } ? 0 : 1)
}

// Служебный режим: проверяет, что нужные системные вызовы для перехода на другой стол существуют.
if CommandLine.arguments.contains("--test-activation") {
    print("activation available:", WindowActivation.isAvailable)
    exit(0)
}

// Служебный режим: печатает состояние автозапуска.
if CommandLine.arguments.contains("--test-login-item") {
    let status = SMAppService.mainApp.status
    print("login item:", status == .enabled ? "enabled" : status == .requiresApproval ? "requires approval" : status == .notRegistered ? "not registered" : "not found")
    exit(0)
}

// Служебный режим: показывает, что чёлка видит в «Сейчас играет».
if CommandLine.arguments.contains("--test-now-playing") {
    Task { @MainActor in
        let nowPlaying = NowPlaying()
        nowPlaying.startMonitoring()
        try? await Task.sleep(for: .seconds(3))
        print("title:", nowPlaying.title ?? "-", "| artist:", nowPlaying.artist ?? "-", "| playing:", nowPlaying.isPlaying, "| app:", nowPlaying.appBundleID ?? "-", "| artwork:", nowPlaying.artwork != nil, "| duration:", Int(nowPlaying.duration))
        nowPlaying.stopMonitoring()
        exit(0)
    }
    RunLoop.main.run()
}

// Служебный режим: проверяет перевод без интернета на уже скачанных моделях.
if let index = CommandLine.arguments.firstIndex(of: "--test-translate"), index + 1 < CommandLine.arguments.count {
    let word = CommandLine.arguments[index + 1]
    Task { @MainActor in
        await TranslatorCheck.run(word)
        exit(0)
    }
    RunLoop.main.run()
}

// Служебный режим: отпущенная посреди разбора клавиша не должна стоить распознанного текста.
if let index = CommandLine.arguments.firstIndex(of: "--test-voice-cancel"), index + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[index + 1]
    Task { @MainActor in
        await SpeechBenchmark.runCancellation(path: path)
        exit(0)
    }
    RunLoop.main.run()
}

// Служебный режим: печатает окна каждого запущенного приложения так, как их видят превью.
if CommandLine.arguments.contains("--test-windows") {
    Task { @MainActor in
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let list = await WindowOps.windows(of: app) ?? []
            print(app.localizedName ?? "?", list.count, list.map { "\($0.title.prefix(24))\($0.isOnScreen ? "" : "(другой стол)")" })
        }
        exit(0)
    }
    RunLoop.main.run()
}

// Служебный режим: прогоняет аудиофайлы через модель и печатает результат.
if let index = CommandLine.arguments.firstIndex(of: "--test-speech"), index + 1 < CommandLine.arguments.count {
    let paths = Array(CommandLine.arguments[(index + 1)...])
    Task { @MainActor in
        await SpeechBenchmark.run(paths: paths)
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
