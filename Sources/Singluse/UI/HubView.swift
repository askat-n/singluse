import AVFoundation
import Combine
import ImageIO
import ServiceManagement
import SingluseCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum HubPage: Hashable {
    case general, ai, meetings
    case module(Module)

    var title: String {
        switch self {
        case .general: return L("Основные")
        case .ai: return L("ИИ-сервисы")
        case .meetings: return L("Встречи")
        case .module(let module): return module.title
        }
    }
}

/// Главное окно устроено как Системные настройки: боковая панель и сгруппированные списки.
struct HubView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = Coordinator.shared.permissions
    @ObservedObject private var coordinator = Coordinator.shared
    @State private var page: HubPage = Coordinator.shared.requestedHubPage ?? .general

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                sidebarRow(.general, symbol: "gearshape.fill", tint: .gray, title: "Основные")
                Section {
                    ForEach(Module.allCases) { module in
                        sidebarRow(.module(module), symbol: module.symbol, tint: module.tint, title: module.title, module: module)
                    }
                }
                Section {
                    sidebarRow(.meetings, symbol: "record.circle.fill", tint: .red, title: "Встречи")
                    sidebarRow(.ai, symbol: "sparkle", tint: .purple, title: "ИИ-сервисы")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            Group {
                switch page {
                case .general: GeneralPage(page: $page)
                case .ai: AIPage()
                case .meetings: MeetingsPage()
                case .module(.wallpaper): WallpaperPage()
                case .module(.scroll): ScrollPage()
                case .module(.dictation): DictationPage()
                case .module(.dock): DockPage()
                case .module(.clipboard): ClipboardPage()
                case .module(.notch): NotchPage_()
                }
            }
            .id(page)
            .transition(.opacity)
            .navigationTitle(page.title)
        }
        .onChange(of: coordinator.requestedHubPage) { _, requested in
            guard let requested else { return }
            page = requested
            coordinator.requestedHubPage = nil
        }
        .animation(.smooth(duration: 0.2), value: page)
        .environment(\.layoutDirection, AppLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    private func sidebarRow(_ target: HubPage, symbol: String, tint: Color, title: String, module: Module? = nil) -> some View {
        HStack(spacing: 8) {
            IconTile(symbol: symbol, tint: tint, size: 22)
            Text(L(title))
            Spacer()
            // Точка нужна только там, где требуется действие: минимум лишнего на экране.
            if let module, settings.isEnabled(module), !permissions.hasAll(module.requiredPermissions) {
                Circle().fill(.orange).frame(width: 7, height: 7).help("Нужно разрешение")
            }
        }
        .tag(target)
    }
}

// MARK: - Общие элементы

struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint.gradient))
    }
}

/// Шапка страницы, как у разделов Системных настроек.
private struct ModuleHeader: View {
    let module: Module
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: module.symbol, tint: module.tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.headline)
                Text(module.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            // У обоев главный переключатель стоит отдельной строкой, с подписью.
            if module != .wallpaper {
                Toggle("", isOn: settings.binding(module)).labelsHidden().toggleStyle(.switch)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Сгруппированный список со стандартным оформлением, шапкой и кнопкой сброса внизу.
private struct ModuleForm<Content: View>: View {
    let module: Module
    @ViewBuilder var content: Content
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = Coordinator.shared.permissions

    var body: some View {
        Form {
            Section { ModuleHeader(module: module) }
            let missing = permissions.missing(for: module)
            if settings.isEnabled(module), !missing.isEmpty {
                Section("Нужно разрешение") {
                    ForEach(missing) { PermissionRow(permission: $0) }
                }
            }
            content
            Section {
                HStack {
                    Spacer()
                    Button("Настройки по умолчанию") {
                        withAnimation(.smooth) { settings.reset(module) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let permission: Permission
    @ObservedObject private var permissions = Coordinator.shared.permissions

    var body: some View {
        LabeledContent {
            if permissions.has(permission) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Разрешить") { permissions.request(permission) }
            }
        } label: {
            Text(permission.title)
            Text(permission.reason)
        }
    }
}

/// Список приложений-исключений. Добавление только из запущенных: так не нужно знать идентификаторы.
struct AppExclusions: View {
    let title: String
    let hint: String
    @Binding var apps: [String]

    private var candidates: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !apps.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Section {
            ForEach(apps, id: \.self) { bundleID in
                HStack {
                    Image(nsImage: Self.icon(bundleID)).resizable().frame(width: 20, height: 20)
                    Text(Self.name(bundleID))
                    Spacer()
                    Button {
                        withAnimation(.smooth) { apps.removeAll { $0 == bundleID } }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Убрать")
                }
            }
            Menu("Добавить приложение") {
                ForEach(candidates, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier!) {
                        withAnimation(.smooth) { apps.append(app.bundleIdentifier!) }
                    }
                }
            }
        } header: {
            Text(L(title))
        } footer: {
            Text(L(hint))
        }
    }

    private static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static func icon(_ bundleID: String) -> NSImage {
        appURL(bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
    }

    private static func name(_ bundleID: String) -> String {
        appURL(bundleID)?.deletingPathExtension().lastPathComponent ?? bundleID
    }
}

// MARK: - Основные

private struct GeneralPage: View {
    @Binding var page: HubPage
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = Coordinator.shared.permissions
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var language = AppLanguage.current
    @State private var showRelaunch = false

    private var neededPermissions: [Permission] {
        let enabled = Module.allCases.filter(settings.isEnabled)
        return Permission.allCases.filter { permission in enabled.contains { $0.requiredPermissions.contains(permission) } }
    }

    var body: some View {
        Form {
            Section("Модули") {
                ForEach(Module.allCases) { module in
                    HStack(spacing: 10) {
                        IconTile(symbol: module.symbol, tint: module.tint, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(module.title)
                            Text(module.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: settings.binding(module)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Button { page = .module(module) } label: {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                }
            }

            Section("Приложение") {
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Значок в строке меню", isOn: $settings.showMenuBarIcon)
                Picker("Язык приложения", selection: Binding(get: { language }, set: { value in
                    language = value
                    AppLanguage.set(value)
                    showRelaunch = value != AppLanguage.launched
                })) {
                    Text("Как в системе").tag("")
                    ForEach(AppLanguage.all, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                }
                if showRelaunch {
                    LabeledContent {
                        Button("Перезапустить") { permissions.relaunch() }
                    } label: {
                        Text("Язык изменится после перезапуска")
                    }
                }
                LabeledContent("Скорость анимаций") {
                    Picker("", selection: $settings.animationScale) {
                        Text("Быстрее").tag(0.75)
                        Text("Обычная").tag(1.0)
                        Text("Спокойнее").tag(1.3)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
            }

            UpdatesSection()

            if !neededPermissions.isEmpty {
                Section {
                    ForEach(neededPermissions) { PermissionRow(permission: $0) }
                } header: {
                    Text("Разрешения")
                } footer: {
                    HStack {
                        Text("Запись экрана применяется после перезапуска.")
                        Spacer()
                        Button("Перезапустить") { permissions.relaunch() }.controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdatesSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = Coordinator.shared.updater

    var body: some View {
        Section {
            Toggle("Проверять обновления автоматически", isOn: $settings.autoCheckUpdates)
            LabeledContent {
                if updater.state == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Проверить сейчас") { Task { await updater.check(manual: true) } }
                }
            } label: {
                Text(String(format: L("Версия %@"), Updater.currentVersion.description))
                Text(lastCheckText).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Обновления")
        } footer: {
            Text("Раз в день Singluse смотрит, вышла ли новая версия на GitHub, и предлагает её установить.")
        }
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheck else { return L("Ещё не проверялось") }
        return String(format: L("Последняя проверка: %@"), date.formatted(.relative(presentation: .named)))
    }
}

// MARK: - Обои

struct ShaderPreview: NSViewRepresentable {
    let preset: ShaderPreset
    var isAnimating = false

    func makeNSView(context: Context) -> ShaderView {
        let view = ShaderView(preset: preset, framesPerSecond: 30)
        view.renderScale = 0.75
        view.setPaused(!isAnimating)
        return view
    }

    func updateNSView(_ view: ShaderView, context: Context) {
        if view.preset != preset { view.preset = preset }
        view.setPaused(!isAnimating)
    }
}

/// Что показывать в каталоге.
private enum WallpaperFilter: Hashable {
    case favorites, section(WallpaperSection), mine
}

private struct WallpaperPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var wallpaper = Coordinator.shared.wallpaper
    @State private var filter: WallpaperFilter = .section(.tech)
    /// Пустая строка — все экраны сразу.
    @State private var targetScreen = ""

    private let grid = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    private var selectedSource: String {
        targetScreen.isEmpty ? settings.wallpaperSource : settings.source(forScreen: targetScreen)
    }

    private func install(_ source: String) {
        if !settings.isEnabled(.wallpaper) { settings.setEnabled(.wallpaper, true) }
        if targetScreen.isEmpty {
            settings.wallpaperSources = [:]
            settings.wallpaperSource = source
        } else {
            settings.wallpaperSources[targetScreen] = source
        }
    }

    private func isFavorite(_ source: String) -> Bool { settings.wallpaperFavorites.contains(source) }

    private func toggleFavorite(_ source: String) {
        withAnimation(.smooth) {
            if isFavorite(source) {
                settings.wallpaperFavorites.removeAll { $0 == source }
            } else {
                settings.wallpaperFavorites.append(source)
            }
        }
    }

    private func matches(_ source: String, section: WallpaperSection?) -> Bool {
        switch filter {
        case .favorites: return isFavorite(source)
        case .section(let wanted): return section == wanted
        case .mine: return false
        }
    }

    var body: some View {
        ModuleForm(module: .wallpaper) {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.isEnabled(.wallpaper) },
                    set: { on in withAnimation(.smooth) { settings.setEnabled(.wallpaper, on) } }
                )) {
                    Text("Включить обои").font(.headline)
                }
                .toggleStyle(.switch)
            } footer: {
                Text("Выключите, и Singluse вернёт обои macOS на всех экранах и рабочих столах и больше их не тронет.")
            }
            if settings.isEnabled(.wallpaper) {
            if let reason = wallpaper.pauseReason { pauseBanner(reason) }

            Section {
                if NSScreen.screens.count > 1 {
                    Picker("Экран", selection: $targetScreen) {
                        Text("Все экраны").tag("")
                        ForEach(NSScreen.screens, id: \.stableID) { Text($0.localizedName).tag($0.stableID) }
                    }
                }
                Picker("Раздел", selection: $filter) {
                    Label("Избранное", systemImage: "heart.fill").tag(WallpaperFilter.favorites)
                    ForEach(WallpaperSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol).tag(WallpaperFilter.section(section))
                    }
                    Label("Мои видео", systemImage: "film.fill").tag(WallpaperFilter.mine)
                }

                LazyVGrid(columns: grid, spacing: 14) {
                    ForEach(ShaderPreset.allCases.filter { matches("shader:\($0.rawValue)", section: $0.section) }) { preset in
                        let source = "shader:\(preset.rawValue)"
                        ShaderTile(preset: preset, isSelected: selectedSource == source, isFavorite: isFavorite(source)) {
                            install(source)
                        } favorite: {
                            toggleFavorite(source)
                        }
                    }
                    ForEach(WallpaperCollection.shared.items.filter { matches($0.sourceKey, section: WallpaperSection(rawValue: $0.section)) }) { item in
                        WallpaperTile(title: item.title, isSelected: selectedSource == item.sourceKey, isFavorite: isFavorite(item.sourceKey)) { _ in
                            CollectionThumbnail(item: item)
                        } action: {
                            install(item.sourceKey)
                        } favorite: {
                            toggleFavorite(item.sourceKey)
                        }
                        .help([item.author, item.source, item.license].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                    if filter == .mine || filter == .favorites {
                        ForEach(settings.videoLibrary.filter { filter == .mine || isFavorite("video:\($0)") }, id: \.self) { path in
                            let source = "video:\(path)"
                            WallpaperTile(title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, isSelected: selectedSource == source, isFavorite: isFavorite(source)) { _ in
                                VideoThumbnail(path: path)
                            } action: {
                                install(source)
                            } favorite: {
                                toggleFavorite(source)
                            }
                            .contextMenu {
                                Button("Убрать из списка", role: .destructive) { removeVideo(path) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                if filter == .favorites, settings.wallpaperFavorites.isEmpty {
                    Text("Нажмите на сердечко у любых обоев, и они появятся здесь.").foregroundStyle(.secondary)
                }
                if filter == .mine {
                    LabeledContent {
                        HStack {
                            Button("Найти в интернете") {
                                NSWorkspace.shared.open(URL(string: "https://www.pexels.com/search/videos/wallpaper/")!)
                            }
                            Button("Добавить видео…", action: addVideo)
                        }
                    } label: {
                        Text("Своё видео")
                        Text("MP4 или MOV, без звука. Файл остаётся на месте.")
                    }
                }
            } header: {
                Text("Обои")
            } footer: {
                Text("Нажмите на обои, и они сразу установятся. Видео с Mixkit, фото с Wikimedia Commons: скачаны на этот Mac для личного использования.")
            }

            Section("Воспроизведение") {
                LabeledContent("Скорость") {
                    Slider(value: $settings.wallpaperSpeed, in: 0.25...2) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "hare.fill").foregroundStyle(.secondary)
                    }
                    .frame(width: 260)
                }
                Picker("Плавность", selection: $settings.wallpaperFPS) {
                    Text("30 кадров, экономно").tag(30)
                    Text("60 кадров").tag(60)
                    Text("120 кадров").tag(120)
                }
                Picker("Качество", selection: $settings.wallpaperQuality) {
                    Text("Экономно").tag(0.35)
                    Text("Стандартное").tag(0.5)
                    Text("Высокое").tag(1.0)
                    Text("Максимальное (сильная нагрузка)").tag(2.0)
                }
                Picker("Менять обои", selection: $settings.wallpaperRotateMinutes) {
                    Text("Никогда").tag(0)
                    Text("Каждые 15 минут").tag(15)
                    Text("Каждый час").tag(60)
                    Text("Каждый день").tag(1440)
                }
            }

            Section {
                Toggle("Работать от батареи", isOn: $settings.wallpaperOnBattery)
                Toggle("Останавливать при заряде ниже \(WallpaperController.lowBatteryLevel)%", isOn: $settings.pauseOnBattery)
                    .disabled(!settings.wallpaperOnBattery)
                Toggle("Останавливать, когда рабочий стол закрыт", isOn: $settings.pauseWhenCovered)
            } header: {
                Text("Питание")
            } footer: {
                Text("Живые обои нагружают видеокарту и расходуют батарею. Когда рабочего стола не видно, они ничего не тратят.")
            }

            Section {
                Toggle("Кадр обоев на экране блокировки", isOn: $settings.wallpaperLockFrame)
            } header: {
                Text("Экран блокировки")
            } footer: {
                Text("macOS не даёт показывать там живое видео: такое окно закрыло бы поле ввода пароля. Поэтому ставится неподвижный кадр этих же обоев. Он заменит картинку рабочего стола, при выключении исходная вернётся. С закрытой крышкой встроенный экран выключен, поэтому там ничего не показывается.")
            }
            }
        }
    }

    @ViewBuilder
    private func pauseBanner(_ reason: WallpaperController.PauseReason) -> some View {
        Section {
            switch reason {
            case .onBattery:
                LabeledContent {
                    Button("Включить") { settings.wallpaperOnBattery = true }
                } label: {
                    Label("Пауза: работа от батареи выключена", systemImage: "battery.100percent")
                }
            case .lowBattery:
                LabeledContent {
                    Button("Всё равно играть") { settings.pauseOnBattery = false }
                } label: {
                    Label("Пауза: заряд ниже \(WallpaperController.lowBatteryLevel)%", systemImage: "battery.25percent")
                }
            case .lowPowerMode:
                Label("Пауза: включён режим энергосбережения", systemImage: "leaf.fill")
            case .covered:
                Label("Пауза: рабочий стол закрыт окнами", systemImage: "macwindow.on.rectangle")
            }
        }
    }

    private func addVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.message = L("Выберите видео для рабочего стола")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.videoLibrary.contains(url.path) {
            settings.videoLibrary.append(url.path)
        }
        if let first = panel.urls.first { install("video:\(first.path)") }
    }

    private func removeVideo(_ path: String) {
        settings.videoLibrary.removeAll { $0 == path }
        settings.wallpaperFavorites.removeAll { $0 == "video:\(path)" }
        if settings.wallpaperSource == "video:\(path)" { settings.wallpaperSource = "shader:aurora" }
        settings.wallpaperSources = settings.wallpaperSources.filter { $0.value != "video:\(path)" }
    }
}

/// Общий вид плитки. В замыкание передаётся, наведён ли курсор: так шейдер оживает только при наведении.
private struct WallpaperTile<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let isFavorite: Bool
    @ViewBuilder let preview: (Bool) -> Preview
    let action: () -> Void
    let favorite: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            preview(hovering)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 3 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    Button(action: favorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isFavorite ? Color.pink : .white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.black.opacity(0.45)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(6)
                    .opacity(hovering || isFavorite ? 1 : 0)
                    .help("Избранное")
                }
                .scaleEffect(hovering ? 1.02 : 1)
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: isSelected)
    }
}

private struct ShaderTile: View {
    let preset: ShaderPreset
    let isSelected: Bool
    let isFavorite: Bool
    let action: () -> Void
    let favorite: () -> Void

    var body: some View {
        WallpaperTile(title: preset.title, isSelected: isSelected, isFavorite: isFavorite) { hovering in
            ShaderPreview(preset: preset, isAnimating: hovering)
        } action: {
            action()
        } favorite: {
            favorite()
        }
    }
}

/// Плитка скачанных обоев: кадр из видео или уменьшенное фото, значок качества.
private struct CollectionThumbnail: View {
    let item: CollectionItem
    @State private var image: NSImage?

    var body: some View {
        Color.black
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Image(systemName: item.isVideo ? "play.fill" : "photo.fill")
                    if let quality = item.quality { Text(verbatim: quality) }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(6)
            }
            .task(id: item.id) { image = await Self.load(item) }
    }

    private static func load(_ item: CollectionItem) async -> NSImage? {
        let url = URL(fileURLWithPath: item.path)
        if item.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 300)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            guard let frame = try? await generator.image(at: CMTime(seconds: 3, preferredTimescale: 600)).image else { return nil }
            return NSImage(cgImage: frame, size: .zero)
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}

private struct VideoThumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Color.black
        .overlay {
            if let image {
                Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: path) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 300)
            if let result = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
                withAnimation(.smooth) { image = NSImage(cgImage: result.image, size: .zero) }
            }
        }
    }
}

// MARK: - Мышь

private struct ScrollPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mice = Coordinator.shared.mice
    @State private var showDetails = false
    @State private var calibrating: MouseDevice?

    private var presetBinding: Binding<String> {
        Binding(
            get: { settings.activeScrollPreset?.rawValue ?? "custom" },
            set: { value in
                if let preset = ScrollPreset(rawValue: value) {
                    withAnimation(.smooth) { settings.apply(preset) }
                }
            }
        )
    }

    var body: some View {
        ModuleForm(module: .scroll) {
            Section {
                if mice.devices.isEmpty {
                    LabeledContent("Мышь", value: "Не подключена")
                } else {
                    ForEach(mice.devices) { device in
                        LabeledContent {
                            Button("Калибровать") { calibrating = device }
                        } label: {
                            Text(device.name)
                            if let profile = settings.mouseProfiles[device.id] {
                                Text(profile.kind == .notched ? L("Настроена под колесо со щелчками") : L("Настроена под гладкое колесо"))
                            } else {
                                Text("Ещё не настроена под эту мышь")
                            }
                        }
                    }
                }
            } header: {
                Text("Подключённая мышь")
            } footer: {
                Text("Калибровка измеряет, как работает колесо именно этой мыши, и подбирает плавность. Настройки включатся сами при подключении.")
            }

            Section("Ощущение") {
                Picker("Режим", selection: presetBinding) {
                    ForEach(ScrollPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    if settings.activeScrollPreset == nil {
                        Text("Свой").tag("custom")
                    }
                }
                Toggle("Обратное направление", isOn: $settings.scrollInvert)
                DisclosureGroup("Точная настройка", isExpanded: $showDetails) {
                    sliderRow("Скорость", value: $settings.scrollSpeed, range: 0.3...3)
                    sliderRow("Плавность", value: $settings.scrollSmoothness, range: 0...1)
                    sliderRow("Разгон", value: $settings.scrollAcceleration, range: 0...1)
                }
            }

            AppExclusions(
                title: "Без сглаживания",
                hint: "В этих приложениях, например в играх, колесо работает как обычно. Трекпад не затрагивается нигде.",
                apps: $settings.scrollExcludedApps
            )

            Section("Попробуйте колесом") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(1...80, id: \.self) { index in
                            Text("Строка \(index)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 7)
                            Divider()
                        }
                    }
                }
                .frame(height: 200)
            }
        }
        .sheet(item: $calibrating) { CalibrationSheet(device: $0) }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range).frame(width: 260)
        }
    }
}

/// Калибровка под конкретную мышь: человек просто крутит колесо, остальное считается само.
private struct CalibrationSheet: View {
    let device: MouseDevice
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = Coordinator.shared.permissions
    @State private var count = 0
    @State private var profile: WheelProfile?
    @State private var failed = false
    @State private var firstTick: Date?
    @State private var finished = false

    private let duration = 6.0
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private var scroll: SmoothScrollController { Coordinator.shared.scroll }

    var body: some View {
        VStack(spacing: 16) {
            IconTile(symbol: "computermouse.fill", tint: .teal, size: 54)
            Text(device.name).font(.headline)

            if !Coordinator.shared.isRunning(.scroll) {
                Text("Включите модуль и выдайте разрешение, чтобы начать.").foregroundStyle(.secondary)
            } else if let profile {
                VStack(spacing: 6) {
                    Label(profile.kind == .notched ? L("Колесо со щелчками") : L("Гладкое колесо"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(format: L("Темп: %lld щелчков в секунду"), Int(profile.ticksPerSecond)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .transition(.blurReplace)
            } else if failed {
                Text("Не хватило данных. Покрутите колесо дольше.").foregroundStyle(.secondary).transition(.blurReplace)
            } else {
                Text("Покрутите колесо вверх и вниз так, как обычно листаете страницу.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Gauge(value: progress) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.teal)
                    .animation(.linear(duration: 0.1), value: progress)
            }

            HStack {
                Button("Отмена") { finish() }.keyboardShortcut(.cancelAction)
                if failed {
                    Button("Ещё раз") { restart() }
                }
                if let profile {
                    Button("Применить") {
                        settings.mouseProfiles[device.id] = profile
                        withAnimation(.smooth) { settings.apply(profile) }
                        finish()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 400)
        .animation(.smooth, value: profile)
        .animation(.smooth, value: failed)
        .onAppear { scroll.beginCalibration() }
        .onDisappear { if !finished { _ = scroll.endCalibration() } }
        .onReceive(ticker) { _ in tick() }
    }

    private var progress: Double {
        guard let firstTick else { return 0 }
        return min(Date().timeIntervalSince(firstTick) / duration, 1)
    }

    private func tick() {
        guard profile == nil, !failed else { return }
        count = scroll.calibrationCount
        if count > 0, firstTick == nil { firstTick = Date() }
        if progress >= 1 {
            let samples = scroll.endCalibration()
            if let result = WheelCalibrator.analyze(samples) { profile = result } else { failed = true }
        }
    }

    private func restart() {
        failed = false
        firstTick = nil
        count = 0
        scroll.beginCalibration()
    }

    private func finish() {
        finished = true
        _ = scroll.endCalibration()
        dismiss()
    }
}

// MARK: - Голос

private struct DictationPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var dictation = Coordinator.shared.dictation
    @ObservedObject private var ai = Coordinator.shared.ai
    @State private var sample = ""
    @State private var inputs = AudioInput.all()

    private let locales = [("ru-RU", "Русский"), ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("de-DE", "Deutsch"), ("fr-FR", "Français"), ("es-ES", "Español")]

    var body: some View {
        ModuleForm(module: .dictation) {
            Section {
                Picker("Клавиша", selection: $settings.dictationKeyCode) {
                    ForEach(DictationKey.all) { Text($0.title).tag($0.keyCode) }
                }
                Toggle("Вставлять текст сразу", isOn: $settings.dictationInstant)
                Toggle("Короткий звук в начале и в конце", isOn: $settings.dictationSound)
            } header: {
                Text("Управление")
            } footer: {
                Text("Удерживайте клавишу, пока говорите, или нажмите её дважды: запись пойдёт сама, а следующее нажатие её остановит. Если поля ввода нет, текст останется в буфере обмена. При мгновенной вставке черновик появляется сразу и через секунду заменяется точным текстом.")
            }

            Section("Распознавание") {
                Picker("Язык", selection: $settings.dictationLocale) {
                    ForEach(locales, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: settings.dictationLocale) { _, _ in
                    Task { await dictation.refreshModelState() }
                }
                Picker("Второй язык", selection: $settings.dictationSecondLanguage) {
                    Text("Нет").tag("")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Русский").tag("ru")
                }
                Picker("Микрофон", selection: $settings.dictationMic) {
                    Text("Как в системе").tag("")
                    ForEach(inputs) { Text($0.name).tag($0.id) }
                }
                Picker("Движок", selection: $settings.dictationEngine) {
                    Text("Singluse на этом Mac").tag("whisper")
                    Text("Apple на этом Mac").tag("local")
                    Text("Облако OpenAI").tag("openai")
                }
                if settings.dictationEngine == "whisper" {
                    WhisperRow()
                    ParakeetRow()
                }
                if settings.dictationEngine == "openai", !ai.hasKey.contains(.openai) {
                    Label("Добавьте ключ OpenAI в разделе «ИИ-сервисы». Пока используется Mac.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if settings.dictationEngine == "local", !dictation.modelInstalled {
                    LabeledContent {
                        if dictation.isDownloadingModel {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Загрузить") { dictation.downloadModel() }
                        }
                    } label: {
                        Text("Языковая модель не загружена")
                        Text("Загружается от Apple один раз, потом работает без сети")
                    }
                }
            }

            Section {
                Picker("Редактура ИИ", selection: $settings.dictationPolish) {
                    Text("Выключена").tag("off")
                    Text("Аккуратно").tag("light")
                    Text("Деловой стиль").tag("formal")
                    Text("Своя инструкция").tag("custom")
                }
                if settings.dictationPolish != "off" {
                    Picker("Сервис", selection: $settings.dictationPolishProvider) {
                        ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if !ai.hasKey.contains(AIProvider(rawValue: settings.dictationPolishProvider) ?? .claude) {
                        Label("Добавьте ключ этого сервиса в разделе «ИИ-сервисы».", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if settings.dictationPolish == "custom" {
                        TextField("Например: пиши короче и без эмоций", text: $settings.dictationCustomPrompt, axis: .vertical)
                    }
                }
            } header: {
                Text("Редактура")
            } footer: {
                Text("Модель Singluse сама ставит знаки препинания. Редактура нужна, если хочется ещё и убрать повторы или поменять стиль: она отправляет текст выбранному сервису и расходует ваш баланс.")
            }

            AppStyles()

            Section {
                TextField("Slack, Figma, Kubernetes", text: $settings.dictationVocabulary, axis: .vertical)
            } header: {
                Text("Мой словарь")
            } footer: {
                Text("Имена и термины через запятую. Распознавание будет ждать именно такое написание.")
            }

            Section("Проверьте здесь") {
                TextEditor(text: $sample)
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                LabeledContent {
                    Button(dictation.phase == .listening ? L("Остановить") : L("Начать")) { dictation.toggleManually() }
                } label: {
                    Text(statusText)
                }
            }

            DictationHistorySection()
        }
        .onAppear {
            inputs = AudioInput.all()
            Task { await dictation.refreshModelState() }
        }
    }

    private var statusText: String {
        switch dictation.phase {
        case .idle: return L("Поставьте курсор в поле выше и зажмите клавишу")
        case .listening: return dictation.partialText.isEmpty ? L("Слушаю…") : dictation.partialText
        case .finishing: return L("Обрабатываю…")
        case .failed(let message), .notice(let message): return message
        }
    }
}

// MARK: - Dock

/// Стиль под приложение: в почте деловой, в мессенджерах разговорный.
private struct AppStyles: View {
    @ObservedObject private var settings = AppSettings.shared

    private var installed: [String] {
        settings.appStyles.keys
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            .sorted()
    }

    private var candidates: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && settings.appStyles[$0.bundleIdentifier!] == nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Section {
            ForEach(installed, id: \.self) { bundleID in
                Picker(selection: Binding(
                    get: { settings.appStyles[bundleID] ?? "standard" },
                    set: { settings.appStyles[bundleID] = $0 }
                )) {
                    Text("Как сказано").tag("standard")
                    Text("Деловой").tag("business")
                    Text("Разговорный").tag("casual")
                } label: {
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                            Text(url.deletingPathExtension().lastPathComponent)
                        }
                    }
                }
            }
            Menu("Добавить приложение") {
                ForEach(candidates, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier!) {
                        settings.appStyles[app.bundleIdentifier!] = "casual"
                    }
                }
            }
        } header: {
            Text("Стиль под приложение")
        } footer: {
            Text("Без ИИ разговорный стиль только убирает точку в конце короткого сообщения. Настоящую смену тона даёт «Редактура ИИ» выше.")
        }
    }
}

/// История диктовок: текст не потеряется, даже если курсор стоял не там.
private struct DictationHistorySection: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var dictation = Coordinator.shared.dictation
    @State private var search = ""
    @State private var confirmingClear = false

    var body: some View {
        Section {
            Toggle("Сохранять историю", isOn: $settings.dictationKeepHistory)
            TextField("Поиск", text: $search, prompt: Text("Поиск"))
            let items = dictation.history.search(search)
            if items.isEmpty {
                Text("Здесь появится всё, что вы продиктуете.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.prefix(50))) { entry in
                    DictationRow(entry: entry)
                }
                HStack {
                    Spacer()
                    Button("Очистить…", role: .destructive) { confirmingClear = true }
                }
            }
        } header: {
            Text("История")
        } footer: {
            Text("Хранится только на этом Mac.")
        }
        .confirmationDialog("Удалить всю историю диктовок?", isPresented: $confirmingClear) {
            Button("Удалить", role: .destructive) { dictation.clearHistory() }
        }
    }
}

private struct DictationRow: View {
    let entry: DictationEntry
    @ObservedObject private var dictation = Coordinator.shared.dictation
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(entry.date, format: .dateTime.day().month().hour().minute())
                    if let app = entry.appName { Text(app) }
                    if !entry.wasInserted {
                        Label("Не вставлено", systemImage: "doc.on.clipboard").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help("Скопировать")
                Button { dictation.removeFromHistory(entry) } label: { Image(systemName: "trash") }
                .help("Удалить")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

// MARK: - Встречи

private struct MeetingsPage: View {
    @ObservedObject private var meetings = Coordinator.shared.meetings
    @ObservedObject private var whisper = Coordinator.shared.whisper
    @State private var opened: Meeting?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: "record.circle.fill", tint: .red, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        if meetings.isRecording, let start = meetings.startDate {
                            Text(start, style: .timer).font(.headline).monospacedDigit()
                            Text(meetings.current?.lines.last?.text ?? L("Слушаю…"))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        } else if meetings.isFinishing {
                            Text("Сохраняю запись…").font(.headline)
                        } else {
                            Text("Запись встречи").font(.headline)
                            Text("Микрофон и звук компьютера, текст в «Заметках» и в Singluse").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(meetings.isRecording ? L("Остановить") : L("Начать")) { meetings.toggle() }
                        .buttonStyle(.borderedProminent)
                        .tint(meetings.isRecording ? .red : .accentColor)
                        .disabled(meetings.isFinishing)
                }
                if let error = meetings.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                if let status = meetings.notesStatus {
                    Label(status, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("Предупреждайте собеседников о записи: в некоторых странах это обязательно по закону. Заметки сохраняются в папку «\(NotesBridge.folderName)». Голос обрабатывается на этом Mac.")
            }

            if let current = meetings.current, !current.lines.isEmpty {
                Section("Сейчас") {
                    ForEach(current.lines.suffix(6)) { MeetingLineRow(line: $0) }
                }
            }

            Section("Записи") {
                if meetings.meetings.isEmpty {
                    Text("Записей пока нет.").foregroundStyle(.secondary)
                }
                ForEach(meetings.meetings) { meeting in
                    Button { opened = meeting } label: {
                        LabeledContent {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        } label: {
                            Text(meeting.title)
                            Text("\(Meeting.time(meeting.duration)) · \(meeting.lines.count) реплик")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $opened) { MeetingSheet(meeting: $0) }
    }
}

private struct MeetingLineRow: View {
    let line: MeetingLine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Meeting.time(line.seconds)).monospacedDigit()
                Text(line.isMe ? "Я" : "Собеседники").fontWeight(.semibold).foregroundStyle(line.isMe ? Color.accentColor : .orange)
            }
            .font(.caption)
            Text(line.text).textSelection(.enabled)
        }
    }
}

private struct MeetingSheet: View {
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var meetings = Coordinator.shared.meetings
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(meeting.title).font(.headline)
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(meeting.lines) { MeetingLineRow(line: $0) }
                    if meeting.lines.isEmpty {
                        Text("Речь не распознана.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            HStack {
                Button("Скопировать текст") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meeting.plainText, forType: .string)
                }
                if let note = meeting.noteID {
                    Button("Открыть в Заметках") { NotesBridge.show(noteID: note) }
                }
                Spacer()
                Button("Удалить из Singluse…", role: .destructive) { confirmingDelete = true }
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
        .confirmationDialog("Удалить запись из Singluse? Заметка останется.", isPresented: $confirmingDelete) {
            Button("Удалить", role: .destructive) {
                meetings.delete(meeting)
                dismiss()
            }
        }
    }
}

private struct WhisperRow: View {
    @ObservedObject private var whisper = Coordinator.shared.whisper
    @State private var confirmingDelete = false

    var body: some View {
        LabeledContent {
            switch whisper.state {
            case .downloading(let progress):
                ProgressView(value: progress).frame(width: 140)
            case .loading:
                ProgressView().controlSize(.small)
            case .ready:
                Button("Удалить", role: .destructive) { confirmingDelete = true }
            case .notDownloaded, .failed:
                Button(whisper.isDownloaded ? "Загрузить в память" : "Скачать") { whisper.prepare() }
            }
        } label: {
            Text(title)
            Text(detail)
        }
        .animation(.smooth, value: whisper.state)
        .confirmationDialog("Удалить модель Singluse с диска?", isPresented: $confirmingDelete) {
            Button("Удалить", role: .destructive) { whisper.deleteModel() }
        }
    }

    private var title: String {
        switch whisper.state {
        case .downloading(let progress): return String(format: L("Скачивается модель: %lld%%"), Int(progress * 100))
        case .loading: return L("Модель загружается")
        case .ready: return L("Модель готова")
        case .notDownloaded: return whisper.isDownloaded ? L("Модель не загружена в память") : String(format: L("Нужна модель, %@"), WhisperEngine.modelSizeTitle)
        case .failed(let message): return message
        }
    }

    private var detail: String {
        switch whisper.state {
        case .ready: return L("Голос не покидает этот Mac. Основана на открытых Whisper и WhisperKit.")
        case .loading: return L("После скачивания первый раз может занять несколько минут")
        default: return L("Скачивается один раз. Пока её нет, работает движок Apple.")
        }
    }
}

/// Вторая модель: Parakeet. Работает вместе с Whisper, лучший вариант выбирается сам.
private struct ParakeetRow: View {
    @ObservedObject private var parakeet = Coordinator.shared.parakeet
    @State private var confirmingDelete = false

    var body: some View {
        LabeledContent {
            switch parakeet.state {
            case .downloading(let progress):
                ProgressView(value: progress).frame(width: 140)
            case .loading:
                ProgressView().controlSize(.small)
            case .ready:
                Button("Удалить", role: .destructive) { confirmingDelete = true }
            case .notDownloaded, .failed:
                Button(parakeet.isDownloaded ? "Загрузить в память" : "Скачать") { parakeet.prepare() }
            }
        } label: {
            Text(title)
            Text("Parakeet от NVIDIA слушает каждую фразу вместе с Whisper; Singluse берёт более точный вариант. Новые версии модели скачиваются сами.")
        }
        .animation(.smooth, value: parakeet.state)
        .confirmationDialog("Удалить вторую модель с диска?", isPresented: $confirmingDelete) {
            Button("Удалить", role: .destructive) { parakeet.deleteModel() }
        }
    }

    private var title: String {
        switch parakeet.state {
        case .downloading(let progress): return String(format: L("Вторая модель скачивается: %lld%%"), Int(progress * 100))
        case .loading: return L("Вторая модель загружается")
        case .ready: return L("Вторая модель готова")
        case .notDownloaded: return parakeet.isDownloaded ? L("Вторая модель не загружена в память") : String(format: L("Вторая модель, %@"), ParakeetEngine.modelSizeTitle)
        case .failed(let message): return message
        }
    }
}

private struct DockPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ModuleForm(module: .dock) {
            Section("Поведение") {
                LabeledContent("Задержка появления") {
                    Slider(value: $settings.dockHoverDelay, in: 0...0.6).frame(width: 260)
                }
                LabeledContent("Задержка скрытия") {
                    Slider(value: $settings.dockHideDelay, in: 0...0.5).frame(width: 260)
                }
            }
            Section("Вид") {
                Picker("Размер миниатюр", selection: $settings.dockThumbScale) {
                    Text("Маленькие").tag(0.75)
                    Text("Средние").tag(1.0)
                    Text("Большие").tag(1.3)
                }
                Toggle("Показывать названия окон", isOn: $settings.dockShowTitles)
            }
            Section {
                Toggle("Переключатель окон ⌥Tab", isOn: $settings.windowSwitcher)
            } footer: {
                Text("Держите ⌥ и нажимайте Tab: появятся миниатюры всех окон этого рабочего стола. Отпустите ⌥, и выбранное окно откроется. ⇧ листает назад, esc отменяет.")
            }
            AppExclusions(
                title: "Без превью",
                hint: "Для этих приложений карточка показываться не будет.",
                apps: $settings.dockExcludedApps
            )
        }
    }
}

// MARK: - Буфер

private struct ClipboardPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var clipboard = Coordinator.shared.clipboard
    @State private var search = ""
    @State private var confirmingClear = false

    var body: some View {
        ModuleForm(module: .clipboard) {
            Section("История") {
                TextField("Поиск", text: $search, prompt: Text("Поиск"))
                let items = clipboard.history.visible(matching: search)
                if items.isEmpty {
                    Text("Скопируйте что-нибудь, и запись появится здесь.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(items.prefix(30))) { item in
                        ClipRow(item: item, index: 99, isSelected: false, controller: clipboard)
                            .onTapGesture { clipboard.copyToPasteboard(item) }
                    }
                }
                HStack {
                    Button("Открыть панель") { clipboard.togglePanel() }
                    Spacer()
                    Button("Очистить…", role: .destructive) { confirmingClear = true }
                }
            }

            Section("Настройки") {
                Picker("Клавиши", selection: $settings.clipHotkey) {
                    ForEach(Array(ClipboardController.hotkeys.enumerated()), id: \.offset) { Text($0.element.title).tag($0.offset) }
                }
                Picker("Сколько записей хранить", selection: $settings.clipLimit) {
                    Text("50").tag(50)
                    Text("200").tag(200)
                    Text("1000").tag(1000)
                }
                Picker("Удалять старше", selection: $settings.clipRetentionDays) {
                    Text("Никогда").tag(0)
                    Text("Дня").tag(1)
                    Text("Недели").tag(7)
                    Text("Месяца").tag(30)
                }
            }

            AppExclusions(
                title: "Не записывать",
                hint: "То, что копируется из этих приложений, в историю не попадёт. Данные, которые менеджеры паролей помечают как секретные, не сохраняются никогда. Закреплённое при очистке остаётся.",
                apps: $settings.clipExcludedApps
            )
        }
        .confirmationDialog("Очистить историю? Закреплённые записи останутся.", isPresented: $confirmingClear) {
            Button("Очистить", role: .destructive) { clipboard.clearUnpinned() }
        }
    }
}

// MARK: - Чёлка

private struct NotchPage_: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = Coordinator.shared.permissions

    /// Сначала включённые в своём порядке, затем выключенные.
    private var orderedPages: [NotchPage] {
        let enabled = settings.notchPages.compactMap(NotchPage.init(rawValue:))
        return enabled + NotchPage.allCases.filter { !enabled.contains($0) }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard settings.notchPages.indices.contains(target) else { return }
        withAnimation(.smooth) { settings.notchPages.swapAt(index, target) }
    }

    private func movePages(from source: IndexSet, to destination: Int) {
        // Перетаскивать можно только среди включённых: выключенные всегда внизу.
        var pages = orderedPages
        pages.move(fromOffsets: source, toOffset: destination)
        let enabled = Set(settings.notchPages)
        withAnimation(.smooth) { settings.notchPages = pages.map(\.rawValue).filter { enabled.contains($0) } }
    }

    private func setPage(_ page: NotchPage, _ on: Bool) {
        withAnimation(.smooth) {
            if on {
                if !settings.notchPages.contains(page.rawValue) { settings.notchPages.append(page.rawValue) }
            } else if settings.notchPages.count > 1 {
                settings.notchPages.removeAll { $0 == page.rawValue }
            }
        }
    }

    var body: some View {
        ModuleForm(module: .notch) {
            Section {
                ForEach(orderedPages) { page in
                    let index = settings.notchPages.firstIndex(of: page.rawValue)
                    HStack(spacing: 8) {
                        Label(page.title, systemImage: page.symbol)
                            .foregroundStyle(index == nil ? .secondary : .primary)
                        Spacer()
                        if let index {
                            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                                .help("Выше")
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == settings.notchPages.count - 1)
                                .help("Ниже")
                        }
                        Toggle("", isOn: Binding(
                            get: { index != nil },
                            set: { on in setPage(page, on) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(index != nil && settings.notchPages.count == 1)
                    }
                    .buttonStyle(.borderless)
                }
                .onMove(perform: movePages)
            } header: {
                Text("Страницы")
            } footer: {
                Text("Включённые страницы идут сверху в том порядке, в каком они листаются в чёлке. Порядок меняется стрелками или перетаскиванием.")
            }

            Section("Поведение") {
                LabeledContent("Задержка раскрытия") {
                    Slider(value: $settings.notchHoverDelay, in: 0...0.5).frame(width: 260)
                }
                Toggle("Показывать на всех экранах", isOn: $settings.notchAllDisplays)
                Toggle("Лёгкий отклик трекпада при раскрытии", isOn: $settings.notchHaptics)
                Toggle("Обложка и позиция трека", isOn: $settings.notchArtwork)
            }

            Section("Таймер") {
                ForEach(settings.timerPresets.indices, id: \.self) { index in
                    Stepper(value: Binding(
                        get: { settings.timerPresets[index] },
                        set: { settings.timerPresets[index] = $0 }
                    ), in: 1...180) {
                        LabeledContent("Готовое время", value: "\(settings.timerPresets[index]) \(L("мин"))")
                    }
                }
                Picker("Звук окончания", selection: $settings.timerSound) {
                    Text("Без звука").tag("")
                    ForEach(["Glass", "Hero", "Ping", "Purr", "Sosumi", "Submarine", "Tink"], id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: settings.timerSound) { _, name in NSSound(named: name)?.play() }
            }

            TranslatorSettingsSection()

            if !permissions.has(.accessibility) {
                Section {
                    PermissionRow(permission: .accessibility)
                } footer: {
                    Text("Нужно только для кнопок воспроизведения.")
                }
            }
        }
    }
}

// MARK: - ИИ

private struct AIPage: View {
    @ObservedObject private var ai = Coordinator.shared.ai
    @State private var limitsFor: AIProvider?

    var body: some View {
        Form {
            Section {
                Text("Ключи хранятся в Связке ключей этого Mac и отправляются только в сам сервис. Войдите на странице лимитов один раз, и чёлка будет показывать лимиты подписки сама. Траты API считаются по официальным отчётам.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(AIProvider.allCases) { provider in
                AIProviderSection(provider: provider, limitsFor: $limitsFor)
            }
        }
        .formStyle(.grouped)
        .task { ai.refreshAll() }
        .sheet(item: $limitsFor, onDismiss: { Coordinator.shared.limits.refresh(force: true) }) { LimitsSheet(provider: $0) }
    }
}

private struct AIProviderSection: View {
    let provider: AIProvider
    @Binding var limitsFor: AIProvider?
    @ObservedObject private var ai = Coordinator.shared.ai
    @State private var keyInput = ""
    @State private var adminInput = ""
    @State private var showKeys = false

    var body: some View {
        let connected = ai.hasKey.contains(provider)
        Section {
            HStack(spacing: 10) {
                IconTile(symbol: provider.symbol, tint: provider.tint, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.title).font(.headline)
                    Text(ai.status[provider] ?? (connected ? L("Ключ сохранён") : L("Не подключён")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if ai.busy.contains(provider) { ProgressView().controlSize(.small) }
            }

            LabeledContent(provider.limitsTitle) {
                HStack {
                    Button("Открыть") { limitsFor = provider }
                    Button("В браузере") { NSWorkspace.shared.open(provider.limitsURL) }
                }
            }

            if let spend = ai.spend[provider] {
                SpendRow(title: "За 7 дней", value: spend.week, limit: ai.budget(provider, weekly: true), tint: provider.tint)
                SpendRow(title: "За 31 день", value: spend.month, limit: ai.budget(provider, weekly: false), tint: provider.tint)
            }

            DisclosureGroup("Подключение и лимиты", isExpanded: $showKeys) {
                keyField("API-ключ", text: $keyInput, saved: connected) {
                    ai.saveKey(keyInput, for: provider)
                    keyInput = ""
                }
                LabeledContent("Где взять ключ") {
                    Button("Открыть страницу") { NSWorkspace.shared.open(provider.keysURL) }
                }
                if connected {
                    if let models = ai.models[provider], !models.isEmpty {
                        Picker("Модель", selection: Binding(get: { ai.model(provider) }, set: { ai.setModel($0, for: provider) })) {
                            if !models.contains(ai.model(provider)) {
                                Text(ai.model(provider)).tag(ai.model(provider))
                            }
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        LabeledContent("Модель", value: ai.model(provider))
                    }
                }
                if provider.supportsSpendReport {
                    keyField(provider.adminKeyHint, text: $adminInput, saved: ai.hasAdminKey.contains(provider)) {
                        ai.saveAdminKey(adminInput, for: provider)
                        adminInput = ""
                    }
                    budgetField("Мой лимит на неделю, $", weekly: true)
                    budgetField("Мой лимит на месяц, $", weekly: false)
                } else {
                    Text("Google не отдаёт траты по API-ключу: они видны только на странице использования.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if connected || ai.hasAdminKey.contains(provider) {
                    Button("Удалить ключи", role: .destructive) { ai.removeKeys(for: provider) }
                }
            }
        }
    }

    private func keyField(_ title: String, text: Binding<String>, saved: Bool, save: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                SecureField("", text: text, prompt: Text(saved ? "Сохранён" : "Вставьте ключ"))
                    .frame(width: 190)
                    .onSubmit(save)
                Button("Сохранить", action: save).disabled(text.wrappedValue.isEmpty)
            }
        }
    }

    private func budgetField(_ title: String, weekly: Bool) -> some View {
        LabeledContent(title) {
            TextField("", value: Binding(
                get: { ai.budget(provider, weekly: weekly) },
                set: { ai.setBudget($0, for: provider, weekly: weekly) }
            ), format: .number)
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
        }
    }
}

private struct SpendRow: View {
    let title: String
    let value: Double
    let limit: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L(title))
                Spacer()
                Text(limit > 0 ? String(format: "$%.2f / $%.0f", value, limit) : String(format: "$%.2f", value))
                    .monospacedDigit()
                    .foregroundStyle(limit > 0 && value >= limit ? Color.red : .secondary)
            }
            if limit > 0 {
                ProgressView(value: min(value / limit, 1)).tint(value >= limit ? .red : tint)
            }
        }
    }
}

extension AIProvider {
    var limitsHelp: String { L("Войдите в свой аккаунт, если страница попросит.") }
}

/// Страница лимитов самого сервиса. Вход выполняет человек, Singluse не видит пароль.
/// После входа чёлка запрашивает у сайта только проценты лимитов.
private struct LimitsSheet: View {
    let provider: AIProvider
    @Environment(\.dismiss) private var dismiss
    @State private var pageURL: URL?
    @State private var linkError = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(provider.limitsTitle).font(.headline)
                Spacer()
                Button("Открыть ссылку из письма") { openCopiedLink() }
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            WebPageView(url: pageURL ?? provider.limitsURL)
            Divider()
            Group {
                if linkError {
                    Text("В буфере нет ссылки от этого сервиса. Скопируйте ссылку из письма ещё раз.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Пришла ссылка для входа? Не открывайте её: правый клик по ней, «Скопировать ссылку», затем кнопка наверху.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(8)
        }
        .frame(width: 780, height: 620)
    }

    /// Вход по ссылке должен пройти в этом окне: вход в обычном браузере Singluse не увидит.
    private func openCopiedLink() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard let link = SignInLink.resolve(text, allowedDomains: provider.signInDomains) else {
            linkError = true
            return
        }
        linkError = false
        pageURL = link
    }
}

private struct WebPageView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Loaded { Loaded() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        context.coordinator.url = url
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.load(URLRequest(url: url))
    }

    final class Loaded {
        var url: URL?
    }
}
