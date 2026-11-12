import Testing
import Foundation
@testable import SunFirebaseEventStudio

@Suite struct EventParsingTests {
    @Test func testLoggingEventIsParsed() {
        let line = "11-12 10:00:01.123 V/FA (1234): Logging event: origin=app,name=level_start,params=Bundle[{level=5, mode=hard}]"
        let e = LogEvent.parse(raw: line)
        #expect(e?.name == "level_start")
        #expect(e?.params.first { $0.key == "level" }?.value == "5")
        #expect(e?.params.first { $0.key == "mode" }?.value == "hard")
    }

    @Test func testNoiseLineIsIgnored() {
        #expect((LogEvent.parse(raw: "11-12 10:00:01.123 V/FA (1234): Scheduling upload")) == nil)
        #expect((StudioModel.prepare("11-12 10:00:01.123 V/FA (1234): Scheduling upload")) == nil)
    }

    @Test func testUnreadableEventLineIsCountedNotDropped() {
        // Looks like an event but has no parsable name: must surface as .unreadable, never vanish silently.
        let item = StudioModel.prepare("11-12 10:00:01.123 V/FA (1234): Logging event garbage")
        if case .unreadable? = item { } else if case .event? = item { } else { Issue.record("line was dropped") }
    }

    @Test func testRelevantFilter() {
        #expect(LogEvent.looksRelevant("Event recorded: Event{x}"))
        #expect(!(LogEvent.looksRelevant("something else")))
    }
}

@Suite struct LineBufferTests {
    @Test func testLineSplitAcrossReadsIsNotLost() {
        let b = LineBuffer()
        #expect(b.append(Data("abc de".utf8)) == [])
        #expect(b.append(Data("f\nsecond\nthi".utf8)) == ["abc def", "second"])
        #expect(b.flush() == ["thi"])
    }

    @Test func testInvalidUTF8DoesNotDropLine() {
        let b = LineBuffer()
        var d = Data("Logging event ".utf8); d.append(0xFF); d.append(contentsOf: Array("\n".utf8))
        #expect(b.append(d).count == 1)
    }
}

@Suite struct CrashParserTests {
    @Test func testFatalExceptionIsReported() {
        var out: [CrashReport] = []
        let lock = NSLock()
        let p = CrashParser(package: "com.test.game") { lock.lock(); out.append($0); lock.unlock() }
        p.feed("11-12 10:00:00.100  4321  4321 E AndroidRuntime: FATAL EXCEPTION: main")
        p.feed("11-12 10:00:00.101  4321  4321 E AndroidRuntime: Process: com.test.game, PID: 4321")
        p.feed("11-12 10:00:00.102  4321  4321 E AndroidRuntime: java.lang.NullPointerException")
        p.flushAll()
        #expect(out.count == 1)
        #expect(out.first?.kind == .fatal)
        #expect(out.first?.package == "com.test.game")
        #expect(out.first?.isGame ?? false)
    }

    @Test func testPlainWarningsProduceNoCrash() {
        var count = 0
        let p = CrashParser(package: "com.test.game") { _ in count += 1 }
        p.feed("11-12 10:00:00.100  100  100 W SomeTag: just a warning")
        p.feed("11-12 10:00:00.200  100  100 I ActivityManager: Displayed something")
        p.flushAll()
        #expect(count == 0)
    }
}

@Suite struct ScreencapTests {
    private func raw(w: Int, h: Int, header: Int, format: UInt32 = 1) -> Data {
        var d = Data()
        for v in [UInt32(w), UInt32(h), format] { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        d.append(Data(count: header - 12))
        d.append(Data(repeating: 0x80, count: w * h * 4))
        return d
    }

    @Test func testHeader12And16BothDecode() throws {
        for header in [12, 16] {
            let png = try #require(ADBService.pngFromRawScreencap(raw(w: 20, h: 10, header: header)))
            #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        }
    }

    @Test func testUnexpectedFormatFallsBack() {
        #expect((ADBService.pngFromRawScreencap(raw(w: 20, h: 10, header: 16, format: 4))) == nil)
        #expect((ADBService.pngFromRawScreencap(Data(count: 10))) == nil)
        #expect(ADBService.pngFromRawScreencap(Data(raw(w: 20, h: 10, header: 16).dropLast(5))) == nil)   // truncated transfer
    }
}

@Suite struct MemInfoTests {
    @Test func oldAndroidWithoutTotalPssLine() {
        let dump = """
        ** MEMINFO in pid 7609 [x.y] **
                   Pss  Private
                 Total    Dirty
                ------   ------
          Native Heap     7229     7220
                TOTAL    84515    73212     7232   184487   156776    99144    57631

         App Summary
                               Pss(KB)
                                ------
                   Java Heap:    17316
                 Native Heap:     7220

                       TOTAL:    84515       TOTAL SWAP PSS:   184487

         Objects
                       Views:       41         ViewRootImpl:        1
        """
        let m = MemInfoParser.parse(package: "x.y", app: dump, device: "")
        #expect(m.running)
        #expect(m.totalPSS == 84515)
        #expect(m.swapPSS == 184487)
    }

    @Test func newAndroidTotalPssLine() {
        let dump = "** MEMINFO in pid 1 [x.y] **\n App Summary\n   TOTAL PSS:   1,234   TOTAL RSS: 2000   TOTAL SWAP PSS: 5\n"
        #expect(MemInfoParser.parse(package: "x.y", app: dump, device: "").totalPSS == 1234)
    }
}

@Suite struct NotificationParserTests {
    @Test func dateSuffixAfterTimestampIsAccepted() {
        let dump = """
          Notification List:
            NotificationRecord(0x024f3d80: pkg=studio.sun.snake.escape.puzzle user=UserHandle{0} id=1 tag=null importance=3 key=0|studio.sun.snake.escape.puzzle|1|null|10248: Notification(channel=default_channel flags=AUTO_CANCEL))
              mCreationTimeMs=1794461888379(2026-11-12 12:38:08.379+0700)
              mUpdateTimeMs=1794461888379(2026-11-12 12:38:08.379+0700)
              key=0|studio.sun.snake.escape.puzzle|1|null|10248
                    android.title=String (Hello)
                    android.text=String (World)
          Snoozed notifications:
        """
        let list = ActiveNotificationParser.parse(dump: dump)
        #expect(list.count == 1)
        #expect(list.first?.title == "Hello")
        #expect(list.first?.package == "studio.sun.snake.escape.puzzle")
    }
}
