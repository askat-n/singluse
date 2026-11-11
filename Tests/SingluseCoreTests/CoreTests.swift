import XCTest
@testable import SingluseCore

final class ScrollEngineTests: XCTestCase {
    private func drain(_ engine: inout ScrollEngine, dt: Double = 1.0 / 120, maxSteps: Int = 2000) -> (y: Int, x: Int, steps: Int) {
        var y = 0, x = 0, steps = 0
        while !engine.isIdle, steps < maxSteps {
            let out = engine.step(dt: dt)
            y += Int(out.dy); x += Int(out.dx); steps += 1
        }
        return (y, x, steps)
    }

    func testOneClickDeliversExactDistanceAndStops() {
        var engine = ScrollEngine(settings: ScrollSettings(speed: 1, smoothness: 0.5, acceleration: 0))
        engine.addWheel(deltaY: 1, deltaX: 0, at: 0)
        let result = drain(&engine)
        XCTAssertTrue(engine.isIdle)
        XCTAssertLessThan(result.steps, 2000)
        XCTAssertEqual(Double(result.y), ScrollEngine.pixelsPerLine, accuracy: 1)
        XCTAssertEqual(result.x, 0)
    }

    func testMotionStartsSoftlyAndStaysSmooth() {
        var engine = ScrollEngine(settings: ScrollSettings(speed: 2, smoothness: 0.75, acceleration: 0))
        engine.addWheel(deltaY: 1, deltaX: 0, at: 0)
        var frames: [Int32] = []
        while !engine.isIdle, frames.count < 2000 { frames.append(engine.step(dt: 1.0 / 144).dy) }
        XCTAssertLessThan(Double(frames[0]), ScrollEngine.pixelsPerLine * 2 * 0.05, "first frame must not jump")
        XCTAssertGreaterThan(frames.count, 30, "motion must spread over many frames")
        let biggest = frames.max()!
        XCTAssertLessThan(Double(biggest), ScrollEngine.pixelsPerLine * 2 * 0.12, "no single frame may carry a big step")
        XCTAssertLessThanOrEqual(frames.map { abs(Int($0)) }.max()!, Int(biggest))
    }

    func testLongFrameDoesNotJump() {
        var engine = ScrollEngine(settings: ScrollSettings(speed: 2, smoothness: 0.75, acceleration: 0))
        engine.addWheel(deltaY: 1, deltaX: 0, at: 0)
        XCTAssertLessThan(Double(engine.step(dt: 2).dy), ScrollEngine.pixelsPerLine * 2 * 0.3)
    }

    func testInvertFlipsDirection() {
        var engine = ScrollEngine(settings: ScrollSettings(acceleration: 0, invert: true))
        engine.addWheel(deltaY: 1, deltaX: -1, at: 0)
        let result = drain(&engine)
        XCTAssertLessThan(result.y, 0)
        XCTAssertGreaterThan(result.x, 0)
    }

    func testReversalCancelsRemainingDistance() {
        var engine = ScrollEngine(settings: ScrollSettings(acceleration: 0))
        engine.addWheel(deltaY: 5, deltaX: 0, at: 0)
        _ = engine.step(dt: 1.0 / 120)
        engine.addWheel(deltaY: -1, deltaX: 0, at: 1)
        let result = drain(&engine)
        XCTAssertEqual(Double(result.y), -ScrollEngine.pixelsPerLine * 1.2, accuracy: 1)
    }

    func testStopsQuicklyAfterWheelStops() {
        // Сильно раскрученное колесо: после последнего щелчка страница должна встать быстро, без долгого хвоста.
        var engine = ScrollEngine(settings: ScrollSettings(speed: 1.9, smoothness: 0.6, acceleration: 0.2))
        for i in 0..<30 { engine.addWheel(deltaY: 1, deltaX: 0, at: Double(i) * 0.03) }
        let result = drain(&engine)
        XCTAssertLessThan(Double(result.steps) / 120, 0.6, "motion must settle within 0.6 s")
        XCTAssertLessThanOrEqual(Double(result.y), ScrollEngine.pixelsPerLine * 1.9 * ScrollEngine.maximumTicksAhead + 1)
    }

    func testTailDoesNotCrawl() {
        var engine = ScrollEngine(settings: ScrollSettings(speed: 1, smoothness: 1, acceleration: 0))
        engine.addWheel(deltaY: 1, deltaX: 0, at: 0)
        var frames: [Int32] = []
        while !engine.isIdle, frames.count < 2000 { frames.append(engine.step(dt: 1.0 / 120).dy) }
        // В конце нет длинной серии кадров по одному пикселю.
        let ones = frames.suffix(20).filter { $0 == 1 }.count
        XCTAssertLessThan(ones, 6)
        XCTAssertLessThan(frames.count, 50)
    }

    func testFastClicksAccelerate() {
        var slow = ScrollEngine(settings: ScrollSettings(acceleration: 1))
        slow.addWheel(deltaY: 1, deltaX: 0, at: 0)
        slow.addWheel(deltaY: 1, deltaX: 0, at: 1)
        var fast = ScrollEngine(settings: ScrollSettings(acceleration: 1))
        fast.addWheel(deltaY: 1, deltaX: 0, at: 0)
        fast.addWheel(deltaY: 1, deltaX: 0, at: 0.01)
        XCTAssertGreaterThan(drain(&fast).y, drain(&slow).y)
    }
}

final class WheelCalibratorTests: XCTestCase {
    private func samples(interval: Double, count: Int = 40) -> [WheelSample] {
        (0..<count).map { WheelSample(time: Double($0) * interval, delta: 1) }
    }

    func testTooFewSamplesGiveNoProfile() {
        XCTAssertNil(WheelCalibrator.analyze(samples(interval: 0.05, count: 4)))
    }

    func testNotchedWheelGetsMoreSmoothing() throws {
        let notched = try XCTUnwrap(WheelCalibrator.analyze(samples(interval: 0.06)))
        let smooth = try XCTUnwrap(WheelCalibrator.analyze(samples(interval: 0.005)))
        XCTAssertEqual(notched.kind, .notched)
        XCTAssertEqual(smooth.kind, .highResolution)
        XCTAssertGreaterThan(notched.smoothness, smooth.smoothness)
        XCTAssertGreaterThan(notched.speed, smooth.speed)
    }

    func testPausesBetweenGesturesAreIgnored() throws {
        var list = samples(interval: 0.06, count: 20)
        list += samples(interval: 0.06, count: 20).map { WheelSample(time: $0.time + 30, delta: 1) }
        XCTAssertEqual(try XCTUnwrap(WheelCalibrator.analyze(list)).ticksPerSecond, 1 / 0.06, accuracy: 0.5)
    }
}

final class ClipboardHistoryTests: XCTestCase {
    private func text(_ s: String) -> ClipItem { ClipItem(content: .text(s)) }

    func testDuplicateMovesToTopAndKeepsPin() {
        var history = ClipboardHistory()
        history.add(text("a"))
        let b = text("b")
        history.add(b)
        history.togglePin(id: b.id)
        history.add(text("c"))
        history.add(text("b"))
        XCTAssertEqual(history.items.count, 3)
        XCTAssertEqual(history.items.first?.content, .text("b"))
        XCTAssertEqual(history.items.first?.pinned, true)
    }

    func testLimitEvictsOldestUnpinnedOnly() {
        var history = ClipboardHistory(limit: 2)
        let pinned = text("pinned")
        history.add(pinned)
        history.togglePin(id: pinned.id)
        history.add(text("old"))
        let evicted = history.add(text("new"))
        XCTAssertEqual(evicted.map(\.content), [.text("old")])
        XCTAssertEqual(Set(history.items.map(\.searchableText)), ["pinned", "new"])
    }

    func testVisibleShowsPinnedFirstAndSearchIgnoresCase() {
        var history = ClipboardHistory()
        let pinned = text("Привет, мир")
        history.add(pinned)
        history.togglePin(id: pinned.id)
        history.add(text("другое"))
        XCTAssertEqual(history.visible().first?.id, pinned.id)
        XCTAssertEqual(history.visible(matching: "ПРИВЕТ").map(\.id), [pinned.id])
    }

    func testRetentionKeepsPinnedAndRecent() {
        var history = ClipboardHistory()
        let old = ClipItem(content: .text("old"), date: Date(timeIntervalSinceNow: -100))
        var oldPinned = ClipItem(content: .text("oldPinned"), date: Date(timeIntervalSinceNow: -100))
        oldPinned.pinned = true
        history = ClipboardHistory(items: [old, oldPinned, text("new")])
        XCTAssertEqual(history.removeOlder(than: Date(timeIntervalSinceNow: -50)).map(\.id), [old.id])
        XCTAssertEqual(history.items.count, 2)
    }

    func testClearKeepsPinned() {
        var history = ClipboardHistory()
        let pinned = text("keep")
        history.add(pinned)
        history.togglePin(id: pinned.id)
        history.add(text("drop"))
        XCTAssertEqual(history.clearUnpinned().count, 1)
        XCTAssertEqual(history.items.map(\.id), [pinned.id])
    }
}

final class TranscriptCleanerTests: XCTestCase {
    func testRemovesFillersAndCapitalizes() {
        XCTAssertEqual(TranscriptCleaner.clean("э-э привет э мир"), "Привет мир")
        XCTAssertEqual(TranscriptCleaner.clean("ээ, привет  ммм мир"), "Привет мир")
        XCTAssertEqual(TranscriptCleaner.clean("um hello uh world"), "Hello world")
    }

    func testKeepsRealWords() {
        XCTAssertEqual(TranscriptCleaner.clean("это экран и эмоции"), "Это экран и эмоции")
        XCTAssertEqual(TranscriptCleaner.clean("umbrella"), "Umbrella")
    }

    func testEmpty() {
        XCTAssertEqual(TranscriptCleaner.clean("  ээ  "), "")
    }
}

final class DictationHistoryTests: XCTestCase {
    func testNewestFirstAndLimit() {
        var history = DictationHistory(limit: 2)
        history.add(DictationEntry(text: "a"))
        history.add(DictationEntry(text: "b"))
        history.add(DictationEntry(text: "c"))
        XCTAssertEqual(history.entries.map(\.text), ["c", "b"])
    }

    func testSearchMatchesTextAndApp() {
        var history = DictationHistory()
        history.add(DictationEntry(text: "Купи молоко", appName: "Notes"))
        history.add(DictationEntry(text: "Hello", appName: "Telegram"))
        XCTAssertEqual(history.search("МОЛОКО").map(\.text), ["Купи молоко"])
        XCTAssertEqual(history.search("telegram").map(\.text), ["Hello"])
        XCTAssertEqual(history.search("  ").count, 2)
    }
}

final class WritingStyleTests: XCTestCase {
    func testCasualDropsFinalPeriodOfSingleSentence() {
        XCTAssertEqual(WritingStyle.casual.applyLocally(to: "Привет, как дела."), "Привет, как дела")
    }

    func testCasualKeepsLongTextAndQuestions() {
        XCTAssertEqual(WritingStyle.casual.applyLocally(to: "Первое. Второе."), "Первое. Второе.")
        XCTAssertEqual(WritingStyle.casual.applyLocally(to: "Как дела?"), "Как дела?")
        XCTAssertEqual(WritingStyle.casual.applyLocally(to: "Ну..."), "Ну...")
    }

    func testBusinessLeavesTextAlone() {
        XCTAssertEqual(WritingStyle.business.applyLocally(to: "Добрый день."), "Добрый день.")
    }
}

final class SpeechChunkerTests: XCTestCase {
    private let speech: (Double) -> [Float] = { seconds in
        (0..<Int(seconds * 16000)).map { sin(Float($0) * 0.05) * 0.2 }
    }
    private let quiet: (Double) -> [Float] = { [Float](repeating: 0, count: Int($0 * 16000)) }

    func testTooShortIsNotCut() {
        XCTAssertNil(SpeechChunker.cutPoint(in: speech(1)))
    }

    func testCutsInsidePause() throws {
        let samples = speech(9) + quiet(0.5) + speech(1)
        let cut = try XCTUnwrap(SpeechChunker.cutPoint(in: samples))
        XCTAssertGreaterThan(cut, 9 * 16000)
        XCTAssertLessThan(cut, Int(9.5 * 16000) + 320)
    }

    func testQuietMicrophoneIsNotCutMidSpeech() {
        // Вся речь тише старого абсолютного порога: раньше её разрезало посреди слова.
        let quietSpeech = (0..<(12 * 16000)).map { sin(Float($0) * 0.05) * 0.003 * (1 + sin(Float($0) * 0.002)) }
        XCTAssertNil(SpeechChunker.cutPoint(in: quietSpeech))
    }

    func testQuietMicrophoneStillCutsAtRealPause() throws {
        let quietWords = (0..<(9 * 16000)).map { sin(Float($0) * 0.05) * 0.003 }
        let samples = quietWords + [Float](repeating: 0, count: 8000) + quietWords
        let cut = try XCTUnwrap(SpeechChunker.cutPoint(in: samples))
        XCTAssertGreaterThan(cut, 9 * 16000)
        XCTAssertLessThan(cut, Int(9.5 * 16000) + 320)
    }

    func testDetectsEndOfSpeech() {
        XCTAssertTrue(SpeechChunker.endsWithPause(speech(1) + quiet(0.3)))
        XCTAssertFalse(SpeechChunker.endsWithPause(speech(1)))
        XCTAssertFalse(SpeechChunker.endsWithPause(quiet(2)))
    }

    func testDetectsNewSpeechAfterPause() {
        let reference = speech(1)
        XCTAssertTrue(SpeechChunker.hasSpeech(in: speech(0.2)[...], comparedTo: reference))
        XCTAssertFalse(SpeechChunker.hasSpeech(in: quiet(0.2)[...], comparedTo: reference))
        // Тихое окончание фразы тоже речь: иначе конец предложения терялся.
        let quietEnding = (0..<3200).map { sin(Float($0) * 0.05) * 0.02 }
        XCTAssertTrue(SpeechChunker.hasSpeech(in: quietEnding[...], comparedTo: reference))
    }

    func testContinuousSpeechWaitsThenForcesCut() {
        XCTAssertNil(SpeechChunker.cutPoint(in: speech(12)))
        XCTAssertEqual(SpeechChunker.cutPoint(in: speech(19)), 19 * 16000)
    }
}

final class TranscriptGuardTests: XCTestCase {
    func testFindsCutEnding() {
        let exact = "Сделай, чтобы таймер работал"
        let draft = "сделай чтобы таймер работал и показывал оставшееся время"
        XCTAssertEqual(TranscriptGuard.missingTail(exact: exact, draft: draft), "и показывал оставшееся время")
    }

    func testAcceptsSameEndingWithDifferentForms() {
        XCTAssertNil(TranscriptGuard.missingTail(exact: "Открой pull request в GitHub.", draft: "открой пулл реквест в гитхаб"))
        XCTAssertNil(TranscriptGuard.missingTail(exact: "Поехали домой завтра.", draft: "поехали домой завтра"))
    }

    func testOneTrailingWordIsNotACut() {
        XCTAssertNil(TranscriptGuard.missingTail(exact: "Пойдём домой", draft: "пойдём домой ну"))
    }

    func testDetectsLostMiddle() {
        XCTAssertTrue(TranscriptGuard.looksCut(exact: "Один два три", draft: "один два три четыре пять шесть семь восемь девять десять"))
        XCTAssertFalse(TranscriptGuard.looksCut(exact: "Один два три четыре пять шесть", draft: "один два три четыре пять шесть семь"))
    }
}

final class SignInLinkTests: XCTestCase {
    private let domains = ["claude.ai", "anthropic.com"]

    func testAcceptsServiceLink() {
        XCTAssertEqual(SignInLink.resolve(" https://claude.ai/magic-link#abc\n", allowedDomains: domains)?.host, "claude.ai")
        XCTAssertEqual(SignInLink.resolve("https://mail.anthropic.com/x", allowedDomains: domains)?.host, "mail.anthropic.com")
    }

    func testUnwrapsGmailRedirect() {
        let wrapped = "https://www.google.com/url?q=https://claude.ai/magic-link&sa=D"
        XCTAssertEqual(SignInLink.resolve(wrapped, allowedDomains: domains)?.host, "claude.ai")
    }

    func testRejectsOtherSites() {
        XCTAssertNil(SignInLink.resolve("https://claude.ai.evil.com/x", allowedDomains: domains))
        XCTAssertNil(SignInLink.resolve("http://claude.ai/x", allowedDomains: domains))
        XCTAssertNil(SignInLink.resolve("просто текст", allowedDomains: domains))
    }
}
