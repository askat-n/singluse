import AppKit
import Combine
import NaturalLanguage
import SwiftUI
import Translation

/// Переводчик в чёлке. Работает на встроенных языковых моделях macOS: текст не покидает этот Mac.
@MainActor
final class NotchTranslator: ObservableObject {
    enum State: Equatable {
        case idle, working, done
        /// Для этой пары языков ещё не скачана модель.
        case needsModel
        case unsupported
        case failed
    }

    @Published var input = "" { didSet { if input != oldValue { schedule() } } }
    @Published private(set) var output = ""
    @Published private(set) var state: State = .idle
    /// Какой язык был определён у введённого текста.
    @Published private(set) var detected: String?

    private let settings = AppSettings.shared
    private let availability = LanguageAvailability()
    private var work: Task<Void, Never>?

    func schedule() {
        work?.cancel()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            output = ""
            detected = nil
            state = .idle
            return
        }
        state = .working
        work = Task { [weak self] in
            // Перевод идёт по ходу набора, но не на каждую букву.
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            await self?.translate(text)
        }
    }

    func clear() {
        input = ""
    }

    func swapLanguages() {
        let currentSource = settings.translatorSource == "auto" ? (detected ?? otherLanguage(than: settings.translatorTarget)) : settings.translatorSource
        guard let currentSource, currentSource != settings.translatorTarget else { return }
        let target = settings.translatorTarget
        settings.translatorTarget = currentSource
        if settings.translatorSource != "auto" { settings.translatorSource = target }
        if !output.isEmpty { input = output } else { schedule() }
    }

    private func otherLanguage(than code: String) -> String? {
        settings.translatorLanguages.first { $0 != code }
    }

    /// Определяет язык текста среди выбранных. Короткие слова бывают неоднозначны, поэтому выбор ограничен списком человека.
    private func recognize(_ text: String) -> String? {
        let selected = settings.translatorLanguages
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = selected.map { NLLanguage(rawValue: Self.base($0)) }
        recognizer.processString(text)
        guard let found = recognizer.dominantLanguage?.rawValue else { return nil }
        return selected.first { Self.base($0) == Self.base(found) }
    }

    private static func base(_ code: String) -> String {
        Locale.Language(identifier: code).languageCode?.identifier ?? code
    }

    private func translate(_ text: String) async {
        let found = settings.translatorSource == "auto" ? recognize(text) : settings.translatorSource
        detected = found
        var target = settings.translatorTarget
        // Написали на языке перевода: значит, переводить надо обратно.
        if settings.translatorSource == "auto", let found, Self.base(found) == Self.base(target), let other = otherLanguage(than: found) {
            target = other
        }
        guard let source = found ?? otherLanguage(than: target) else {
            state = .failed
            return
        }
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        switch await availability.status(from: from, to: to) {
        case .installed:
            break
        case .supported:
            output = ""
            state = .needsModel
            return
        default:
            output = ""
            state = .unsupported
            return
        }
        do {
            let session = TranslationSession(installedSource: from, target: to)
            let response = try await session.translate(text)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.18)) {
                output = response.targetText
                state = .done
            }
        } catch {
            guard !Task.isCancelled else { return }
            NSLog("Singluse: translation failed: \(error)")
            output = ""
            state = .failed
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    static func title(_ code: String) -> String {
        let name = Locale.current.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

struct NotchTranslatorPage: View {
    let takeKeyboard: () -> Void
    let close: () -> Void
    @ObservedObject private var translator = Coordinator.shared.translator
    @ObservedObject private var settings = AppSettings.shared
    @FocusState private var focused: Bool
    @State private var copied = false

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                languageMenu(selection: $settings.translatorSource, includesAuto: true)
                Button { translator.swapLanguages() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                languageMenu(selection: $settings.translatorTarget, includesAuto: false)
            }

            TextField("Введите слово или фразу", text: $translator.input)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .focused($focused)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(.white.opacity(0.11)))
                .onSubmit {
                    translator.copyOutput()
                    flashCopied()
                }
                .onExitCommand {
                    if translator.input.isEmpty { close() } else { translator.clear() }
                }

            result
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .onAppear {
            // Кнопка страницы уже нажата: сразу можно печатать, как в Spotlight.
            takeKeyboard()
            DispatchQueue.main.async { focused = true }
        }
    }

    @ViewBuilder private var result: some View {
        switch translator.state {
        case .idle:
            Text("Без интернета, на моделях Apple. Enter копирует перевод.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        case .working where translator.output.isEmpty:
            ProgressView().controlSize(.small)
        case .needsModel:
            HStack(spacing: 8) {
                Text("Языковая модель ещё не скачана.").font(.system(size: 12)).foregroundStyle(.orange)
                Button("Скачать") { Coordinator.shared.openSettings(.module(.notch)) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        case .unsupported:
            Text("Apple не переводит между этими языками.").font(.system(size: 12)).foregroundStyle(.orange)
        case .failed:
            Text("Не удалось перевести.").font(.system(size: 12)).foregroundStyle(.orange)
        default:
            Button {
                translator.copyOutput()
                flashCopied()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Text(translator.output)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .contentTransition(.symbolEffect(.replace))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Скопировать")
        }
    }

    private func flashCopied() {
        guard !translator.output.isEmpty else { return }
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated { withAnimation { copied = false } }
        }
    }

    private func languageMenu(selection: Binding<String>, includesAuto: Bool) -> some View {
        Menu {
            if includesAuto {
                Button("Определять сам") {
                    selection.wrappedValue = "auto"
                    translator.schedule()
                }
            }
            ForEach(settings.translatorLanguages, id: \.self) { code in
                Button(NotchTranslator.title(code)) {
                    selection.wrappedValue = code
                    translator.schedule()
                }
            }
        } label: {
            Text(menuTitle(selection.wrappedValue))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    private func menuTitle(_ code: String) -> String {
        guard code == "auto" else { return NotchTranslator.title(code) }
        if let detected = translator.detected { return NotchTranslator.title(detected) }
        return L("Определять сам")
    }
}

/// Настройки переводчика: какие языки он знает. Модели скачивает сама macOS, спрашивая человека.
struct TranslatorSettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var supported: [String] = []
    @State private var installed: Set<String> = []
    @State private var configuration: TranslationSession.Configuration?

    private var base: String { settings.translatorLanguages.first ?? "ru" }

    var body: some View {
        Section {
            ForEach(supported, id: \.self) { code in
                HStack {
                    Toggle(NotchTranslator.title(code), isOn: binding(code))
                    Spacer()
                    if settings.translatorLanguages.contains(code), code != base {
                        if installed.contains(code) {
                            Label("Скачан", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Скачать") { download(code) }.controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            Text("Языки переводчика")
        } footer: {
            Text("Перевод работает без интернета, на моделях Apple. Модель скачивается один раз, скачанными можно управлять в «Системных настройках», раздел «Язык и регион».")
        }
        .task { await reload() }
        .translationTask(configuration) { session in
            try? await session.prepareTranslation()
            await reload()
        }
    }

    private func binding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { settings.translatorLanguages.contains(code) },
            set: { isOn in
                if isOn {
                    settings.translatorLanguages.append(code)
                } else if settings.translatorLanguages.count > 2 {
                    settings.translatorLanguages.removeAll { $0 == code }
                    if settings.translatorTarget == code { settings.translatorTarget = settings.translatorLanguages[0] }
                    if settings.translatorSource == code { settings.translatorSource = "auto" }
                }
                Task { await reload() }
            }
        )
    }

    private func download(_ code: String) {
        let next = TranslationSession.Configuration(source: Locale.Language(identifier: base), target: Locale.Language(identifier: code))
        if configuration == next { configuration?.invalidate() } else { configuration = next }
    }

    private func reload() async {
        let availability = LanguageAvailability()
        let languages = await availability.supportedLanguages
        var seen = Set<String>()
        var codes = languages.map(\.minimalIdentifier).filter { seen.insert($0).inserted }
        codes.sort { NotchTranslator.title($0) < NotchTranslator.title($1) }
        supported = codes
        var ready = Set<String>()
        let from = Locale.Language(identifier: base)
        for code in settings.translatorLanguages where code != base {
            if await availability.status(from: from, to: Locale.Language(identifier: code)) == .installed { ready.insert(code) }
        }
        installed = ready
    }
}

/// Служебная проверка: какие пары языков скачаны и работает ли перевод без интернета.
enum TranslatorCheck {
    @MainActor
    static func run(_ word: String) async {
        let availability = LanguageAvailability()
        let languages = await availability.supportedLanguages
        print("supported:", languages.map(\.minimalIdentifier).joined(separator: " "))
        let ru = Locale.Language(identifier: "ru"), en = Locale.Language(identifier: "en")
        let status = await availability.status(from: ru, to: en)
        print("ru-en:", status == .installed ? "installed" : status == .supported ? "not downloaded" : "unsupported")
        guard status == .installed else { return }
        do {
            let response = try await TranslationSession(installedSource: ru, target: en).translate(word)
            print("result:", response.targetText)
        } catch {
            print("error:", error)
        }
    }
}
