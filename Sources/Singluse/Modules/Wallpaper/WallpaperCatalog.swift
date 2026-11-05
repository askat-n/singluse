import AVFoundation
import AppKit
import SwiftUI

/// Обои, скачанные на этот Mac: видео и фото из источников с открытыми лицензиями.
/// Файлы лежат в папке приложения, в саму программу не встроены и для личного использования.
struct CollectionItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let section: String
    let file: String
    let kind: String
    let source: String
    let license: String
    var quality: String?
    var author: String?

    var path: String { WallpaperCollection.directory.appendingPathComponent(file).path }
    var isVideo: Bool { kind == "video" }
    var sourceKey: String { (isVideo ? "video:" : "image:") + path }
}

@MainActor
final class WallpaperCollection {
    static let shared = WallpaperCollection()
    let items: [CollectionItem]

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Singluse/Wallpapers/Collection", isDirectory: true)
    }

    private init() {
        let decoder = JSONDecoder()
        let lists = ["videos.json", "photos.json"].compactMap { name -> [CollectionItem]? in
            (try? Data(contentsOf: Self.directory.appendingPathComponent(name))).flatMap { try? decoder.decode([CollectionItem].self, from: $0) }
        }
        items = lists.flatMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func items(in section: WallpaperSection) -> [CollectionItem] {
        items.filter { $0.section == section.rawValue }
    }
}

extension NSScreen {
    /// Постоянный номер экрана: не меняется при переподключении, поэтому настройки не теряются.
    var stableID: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Кадр текущих обоев как обычная картинка рабочего стола. Экран блокировки macOS показывает именно её.
/// Живое видео туда нельзя: окно поверх блокировки закрыло бы поле ввода пароля.
@MainActor
final class LockScreenFrame {
    private let settings = AppSettings.shared
    private var appliedKey: String?

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Singluse/LockFrames", isDirectory: true)
    }

    /// Обои Singluse выключены: картинка macOS возвращается, и дальше Singluse её не трогает.
    /// Возврат уже сделан. Система меняет обои не мгновенно, и повторная проверка ещё видела бы картинку Singluse.
    private var restored = false
    private var applies = false
    private var spaceObserver: NSObjectProtocol?

    /// macOS меняет картинку только на текущем рабочем столе. Поэтому на остальных столах
    /// возврат делается, когда человек на них переходит.
    init() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.applies else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated {
                        guard !self.applies else { return }
                        self.restore()
                    }
                }
            }
        }
    }

    func update(active: Bool) {
        applies = active && settings.wallpaperLockFrame
        if applies {
            restored = false
            apply()
        } else if !restored {
            restored = true
            restore()
        }
    }

    private func apply() {
        let key = NSScreen.screens.map { "\($0.stableID)=\(settings.source(forScreen: $0.stableID))" }.joined(separator: ";")
        guard key != appliedKey else { return }
        appliedKey = key
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for screen in NSScreen.screens {
            let id = screen.stableID
            // Запоминаем картинку человека, чтобы вернуть её при выключении. Если он сменил обои в macOS,
            // запоминается уже новая: своя картинка Singluse исходной не считается.
            if let current = NSWorkspace.shared.desktopImageURL(for: screen), !Self.isOurs(current) {
                settings.originalDesktopImages[id] = current.path
            }
            let source = settings.source(forScreen: id)
            Task { [weak self] in
                guard let url = await self?.renderFrame(source: source, size: screen.frame.size, id: id) else { return }
                try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            }
        }
    }

    private func renderFrame(source: String, size: CGSize, id: String) async -> URL? {
        // Имя файла меняется при смене обоев: иначе система не заметит новую картинку.
        let safe = (id + "-" + source).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined().suffix(80)
        let name = "\(safe).png"
        let url = Self.directory.appendingPathComponent(name)
        if source.hasPrefix("image:") { return URL(fileURLWithPath: String(source.dropFirst("image:".count))) }
        if source.hasPrefix("video:") {
            let path = String(source.dropFirst("video:".count))
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            generator.appliesPreferredTrackTransform = true
            guard let frame = try? await generator.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image,
                  let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]),
                  (try? png.write(to: url)) != nil else { return nil }
            return url
        }
        let preset = ShaderPreset(rawValue: String(source.dropFirst("shader:".count))) ?? .aurora
        return ShaderEngine.renderFrame(preset: preset, width: Int(size.width), height: Int(size.height), to: url) ? url : nil
    }

    /// Картинка, которую поставил сам Singluse: кадр видео, обои из коллекции или своё фото из обоев.
    private static func isOurs(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(directory.standardizedFileURL.path) || path.hasPrefix(WallpaperCollection.directory.standardizedFileURL.path)
            || AppSettings.shared.wallpaperSources.values.contains("image:" + path) || AppSettings.shared.wallpaperSource == "image:" + path
    }

    private func restore() {
        appliedKey = nil
        for screen in NSScreen.screens {
            // Человек уже сам поставил другие обои в macOS: их не трогаем.
            guard let current = NSWorkspace.shared.desktopImageURL(for: screen), Self.isOurs(current) else { continue }
            // Если исходная картинка неизвестна или удалена, ставим стандартные обои macOS, а не оставляем кадр Singluse.
            let saved = settings.originalDesktopImages[screen.stableID].flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            let path = saved ?? "/System/Library/CoreServices/DefaultDesktop.heic"
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
        }
        // Экраны, которые сейчас не подключены, вернутся к своим обоям, когда их подключат.
    }
}
