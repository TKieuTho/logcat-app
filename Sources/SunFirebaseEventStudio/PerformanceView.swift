import SwiftUI
import Charts

/// FPS, CPU, RAM and temperature of the running game over time, with crashes and Firebase events marked on the same time axis.
struct PerformanceView: View {
    @EnvironmentObject private var model: StudioModel
    @State private var hover: Date?

    private static let thermalNames = ["Bình thường", "Nhẹ", "Vừa", "Nặng", "Nghiêm trọng", "Khẩn cấp", "Tắt máy"]

    private var samples: [PerfSample] { model.perfSamples }
    private var domain: ClosedRange<Date> {
        let end = samples.last?.date ?? Date()
        let start = samples.first?.date ?? end.addingTimeInterval(-60)
        return start...max(end, start.addingTimeInterval(30))
    }
    private func nearest(_ d: Date?) -> PerfSample? {
        guard let d else { return samples.last }
        return samples.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
    }

    var body: some View {
        let shown = nearest(hover)
        let marks = markers()
        VStack(alignment: .leading, spacing: 12) {
            header
            if let e = model.perfError { Text(e).foregroundStyle(.red).font(.callout) }
            if samples.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Đang lấy mẫu đầu tiên…").foregroundStyle(.secondary) }.padding(.vertical, 20)
            } else {
                if shown?.running == false {
                    Text("Game chưa chạy trên máy này nên chưa có FPS / CPU / RAM. Nhiệt độ và pin vẫn được ghi. Mở game để bắt đầu đo.")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let s = shown { stats(s) }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: 18, alignment: .top)], spacing: 14) {
                        chart("FPS", unit: "fps", marks: marks, yMax: max(65, (samples.compactMap(\.fps).max() ?? 0) + 5)) { [("FPS", $0.fps, Theme.green)] }
                        chart("CPU của game", unit: "% của 1 nhân", marks: marks, yMax: Double((samples.last?.cores ?? 8) * 100)) { [("CPU", $0.cpu, Theme.accent)] }
                        chart("RAM (RSS)", unit: "MB", marks: marks, yMax: nil) { [("RSS", $0.rssMB, .purple)] }
                        chart("Nhiệt độ", unit: "°C", marks: marks, yMax: nil) { [("CPU", $0.cpuTemp, .orange), ("Pin", $0.batteryTemp, .yellow)] }
                    }
                }
                Text("Vạch đỏ = crash, vạch xanh mờ = event Firebase. Di chuột lên biểu đồ để xem số tại thời điểm đó. FPS đo từ SurfaceFlinger (đúng với game Unity); game đứng hình không vẽ frame mới thì FPS = 0. CPU 100% = một nhân chạy hết công suất. Giờ trên trục là giờ máy tính.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(maxWidth: 1100, maxHeight: 800, alignment: .topLeading)
        .background(Theme.bg)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hiệu năng game").font(.title3.bold())
                Text("\(model.selectedGame.title) · \(model.selectedSerial.map(model.deviceLabel) ?? "") · \(samples.count) mẫu, 1 mẫu mỗi ~2 giây").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.perfPaused.toggle() } label: { Label(model.perfPaused ? "Tiếp tục" : "Tạm dừng", systemImage: model.perfPaused ? "play.fill" : "pause.fill") }
            Button { model.clearPerf() } label: { Label("Xoá", systemImage: "trash") }.disabled(samples.isEmpty)
            Button { model.exportPerfCSV() } label: { Label("Xuất CSV…", systemImage: "square.and.arrow.up") }.disabled(samples.isEmpty)
            Button("Đóng") { model.closePerformance() }.keyboardShortcut(.cancelAction)
        }
    }

    private func stats(_ s: PerfSample) -> some View {
        let recent = samples.suffix(30).compactMap(\.fps)
        let avg = recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
        func v(_ x: Double?, _ f: String) -> String { x.map { String(format: f, $0) } ?? "—" }
        return HStack(alignment: .top, spacing: 26) {
            stat("FPS", v(s.fps, "%.1f"), sub: s.running && s.fps == nil ? "chưa đo được: game phải đang hiện trên màn hình" : avg.map { String(format: "TB 1 phút %.1f", $0) })
            stat("Frame giật", v(s.jankPct, "%.0f%%"), sub: s.maxFrameMs.map { String(format: "chậm nhất %.0f ms", $0) }, warn: (s.jankPct ?? 0) > 10)
            stat("CPU", v(s.cpu, "%.0f%%"), sub: s.cpu.map { String(format: "≈ %.0f%% cả máy (%d nhân)", $0 / Double(s.cores), s.cores) })
            stat("RAM", v(s.rssMB, "%.0f MB"), sub: s.threads.map { "\($0) luồng" })
            stat("Nhiệt độ CPU", v(s.cpuTemp, "%.1f°C"), sub: s.thermalStatus.map { "Throttle: " + Self.thermalNames[min($0, 6)] }, warn: (s.thermalStatus ?? 0) >= 2)
            stat("Pin", s.battery.map { "\($0)%" } ?? "—", sub: s.batteryTemp.map { String(format: "%.1f°C", $0) })
        }
    }
    private func stat(_ label: String, _ value: String, sub: String?, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundStyle(warn ? Color.orange : .primary)
            if let sub { Text(sub).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    // MARK: markers
    private struct Marks { var crashes: [LogEvent] = []; var events: [Date] = [] }
    /// Walks events newest-first and stops at the left edge of the chart, so it stays cheap with 50,000 events.
    private func markers() -> Marks {
        var m = Marks()
        guard let serial = model.perfSerial else { return m }
        let start = domain.lowerBound
        for e in model.events.reversed() {
            if e.date < start { break }
            guard e.deviceSerial == serial, e.date <= domain.upperBound else { continue }
            if e.kind == .crash { if e.crash?.isGame ?? true { m.crashes.append(e) } }
            else if e.kind == .event, m.events.count < 150 { m.events.append(e.date) }
        }
        return m
    }

    private func chart(_ title: String, unit: String, marks: Marks, yMax: Double?, series: @escaping (PerfSample) -> [(String, Double?, Color)]) -> some View {
        let names = series(samples.last ?? PerfSample(date: Date())).map { ($0.0, $0.2) }
        let at = nearest(hover)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(title).font(.caption.bold())
                ForEach(Array((at.map(series) ?? []).enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 4) {
                        Circle().fill(item.2).frame(width: 7, height: 7)
                        if names.count > 1 { Text(item.0).font(.caption2).foregroundStyle(.secondary) }
                        Text(item.1.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                }
                Text(unit).font(.caption2).foregroundStyle(.tertiary)
                if let h = hover { Text(h.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.tertiary) }
            }
            Chart {
                ForEach(samples) { s in
                    ForEach(series(s), id: \.0) { item in
                        if let v = item.1 {
                            LineMark(x: .value("Giờ", s.date), y: .value(item.0, v), series: .value("Nguồn", item.0))
                                .foregroundStyle(item.2).interpolationMethod(.monotone)
                        }
                    }
                }
                ForEach(Array(marks.events.enumerated()), id: \.offset) { _, d in
                    RuleMark(x: .value("Event", d)).foregroundStyle(Color.blue.opacity(0.13)).lineStyle(StrokeStyle(lineWidth: 1))
                }
                ForEach(marks.crashes) { c in
                    RuleMark(x: .value("Crash", c.date)).foregroundStyle(Color.red).lineStyle(StrokeStyle(lineWidth: 1.6))
                        .annotation(position: .top, alignment: .leading, spacing: 0) {
                            Text(c.crash?.kind.rawValue ?? "Crash").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                        }
                }
                if let h = hover { RuleMark(x: .value("Chọn", h)).foregroundStyle(Color.secondary.opacity(0.6)) }
            }
            .chartXScale(domain: domain)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartYScale(domain: 0...(yMax ?? autoMax(series)))
            .chartOverlay { proxy in
                GeometryReader { g in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p):
                                hover = proxy.value(atX: p.x - g[proxy.plotAreaFrame].origin.x, as: Date.self)
                            case .ended: hover = nil
                            }
                        }
                }
            }
            .frame(height: 125)
        }
    }
    private func autoMax(_ series: (PerfSample) -> [(String, Double?, Color)]) -> Double {
        let top = samples.flatMap { series($0).compactMap(\.1) }.max() ?? 1
        return max(1, top * 1.15)
    }
}
