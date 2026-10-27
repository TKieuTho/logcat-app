import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: StudioModel
    @State private var showDeviceBufferWarning = false
    @AppStorage("appearance") private var appearance = "light"
    private var scheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            HStack(spacing: 0) {
                eventList.frame(minWidth: 600, maxWidth: .infinity)
                Divider()
                detailPanel.frame(width: 420)
            }
            footer
        }
        .background(Theme.bg)
        .background(SlimScrollers())
        .preferredColorScheme(scheme)
        .alert("Configure Firebase Analytics logging?", isPresented: $model.showSetupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Configure Device") { model.confirmSetup() }
        } message: {
            Text("This changes Android debug properties on \(model.selectedSerial ?? "the selected device") for \(model.selectedGame.title). After setup, the app will ask before force-stopping and relaunching the game. Firebase DebugView remains the official source of truth.")
        }
        .alert("Restart game to begin capture?", isPresented: $model.showLaunchConfirmation) {
            Button("Not now", role: .cancel) { model.startStream() }
            Button("Restart & Stream") { model.confirmLaunch() }
        } message: {
            Text("The app will force-stop and relaunch \(model.selectedGame.title) on \(model.selectedSerial ?? "the selected device") and start its FA / FA-SVC log stream.")
        }
        .alert("Clear Android device log buffer?", isPresented: $showDeviceBufferWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Device Buffer", role: .destructive) { model.clearDeviceBufferAfterConfirmation() }
        } message: {
            Text("This is different from Clear View. It runs logcat -c on the selected device and deletes the current device log buffer.")
        }
        .alert("Có bản cập nhật Logcat", isPresented: $model.showUpdateAlert) {
            Button("Để sau", role: .cancel) {}
            Button("Tải về") { model.openUpdateDownload() }
        } message: {
            Text("Bản \(model.updateInfo?.version ?? "") (đang dùng \(Updater.currentVersion)).\n\(model.updateInfo?.notes ?? "")\n\nTải về, giải nén rồi kéo Logcat.app vào Applications và chọn Replace.")
        }
        .alert("Logcat", isPresented: Binding(get: { model.updateMessage != nil }, set: { if !$0 { model.updateMessage = nil } })) {
            Button("OK") { model.updateMessage = nil }
        } message: { Text(model.updateMessage ?? "") }
        .onAppear { model.checkForUpdates(manual: false) }
        .alert("Logcat", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let img = Bundle.main.image(forResource: "cat") ?? NSImage(contentsOfFile: "Resources/cat.png") {
                    Image(nsImage: img).resizable().scaledToFit()
                } else { Image(systemName: "cat") }
            }.frame(width: 44, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Logcat").font(.title2.bold()) + Text("  v\(Updater.currentVersion)").font(.caption).foregroundColor(.secondary)
                Text("Sun Studio · Firebase events (FA / FA-SVC)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $appearance) {
                Image(systemName: "circle.lefthalf.filled").tag("system")
                Image(systemName: "sun.max").tag("light")
                Image(systemName: "moon").tag("dark")
            }.pickerStyle(.segmented).frame(width: 110).labelsHidden().help("Appearance: System / Light / Dark")
            Circle().fill(model.isStreaming ? Theme.green : .gray).frame(width: 8, height: 8)
            Text(model.isStreaming ? "LIVE" : "NOT STREAMING").font(.caption.bold()).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ANDROID DEVICE").font(.caption2.bold()).foregroundStyle(.secondary)
                    Picker("Device", selection: Binding(get: { model.selectedSerial ?? "" }, set: { model.selectDevice($0.isEmpty ? nil : $0) })) {
                        Text("Select device…").tag("")
                        ForEach(model.devices) { device in
                            Text(device.displayName + (device.state == "unauthorized" ? " · UNAUTHORIZED" : "")).tag(device.serial)
                        }
                    }.frame(minWidth: 290)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("GAME PACKAGE").font(.caption2.bold()).foregroundStyle(.secondary)
                    Picker("Game", selection: $model.selectedGame) {
                        ForEach(GamePackage.allCases) { game in Text(game.title).tag(game) }
                    }.frame(minWidth: 190)
                }
                Button { model.requestSetup() } label: {
                    Label("Configure & Capture", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(model.selectedSerial == nil || model.selectedDevice?.state != "device")
                Button { model.isStreaming ? model.stopAllStreams() : model.startAllStreams() } label: {
                    Label(model.isStreaming ? "Stop All" : "Stream All Devices", systemImage: model.isStreaming ? "stop.fill" : "play.fill")
                }.disabled(!model.isStreaming && !model.devices.contains(where: { $0.state == "device" }))
                Menu {
                    Button("Clear View Only", systemImage: "eraser") { model.clearVisibleEvents() }
                    Button("Clear Device Log Buffer…", systemImage: "trash", role: .destructive) { showDeviceBufferWarning = true }
                    Divider()
                    Button("Copy Visible Logs", systemImage: "doc.on.doc") { model.copyVisibleEvents() }
                    Button("Export Visible Logs…", systemImage: "square.and.arrow.up") { model.exportVisibleEvents() }
                    Divider()
                    Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { model.checkForUpdates(manual: true) }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search: event name, parameter or value (e.g. shop level 3)", text: $model.searchText)
                    .textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Text("\(model.visibleEvents.count) found").font(.caption).foregroundStyle(.secondary)
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                Divider().frame(height: 18)
                Toggle("Auto-scroll", isOn: $model.autoScroll).toggleStyle(.checkbox).font(.caption)
            }
            .padding(9).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
    }

    private var eventList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("EVENTS").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.visibleEvents.count) events").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                List(selection: Binding(get: { model.selectedEventID }, set: { model.selectedEventID = $0 })) {
                    ForEach(model.visibleEvents) { event in
                        HStack(spacing: 10) {
                            Text(event.clock).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Text(event.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text("\(event.params.filter { !$0.isInternal }.count) params").font(.caption).foregroundStyle(.tertiary)
                            Button { copy(event.copyText) } label: { Image(systemName: "doc.on.doc").font(.caption) }
                                .buttonStyle(.borderless).help("Copy event + all parameters")
                        }
                        .padding(.vertical, 4)
                        .tag(event.id)
                        .id(event.id)
                    }
                }
                .listStyle(.plain)
                .onChange(of: model.visibleEvents.last?.id) { id in
                    if model.autoScroll, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let event = model.selectedEvent {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.name).font(.title3.bold()).textSelection(.enabled)
                    Spacer()
                    Button { copy(event.copyText) } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption) }
                        .buttonStyle(.bordered).controlSize(.small).help("Copy event name + all parameters")
                }
                Text("\(event.clock) · \(event.deviceSerial)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(event.params, id: \.self) { p in
                            HStack(alignment: .top, spacing: 10) {
                                Text(p.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                    .frame(width: 130, alignment: .leading)
                                Text(p.value).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .opacity(p.isInternal ? 0.5 : 1)
                            .padding(.vertical, 5)
                            Divider()
                        }
                        if event.params.isEmpty { Text("No parameters").foregroundStyle(.secondary).padding(.top, 8) }
                        DisclosureGroup("Raw log") {
                            Text(event.raw).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.top, 12).font(.caption)
                    }
                }
            } else {
                Spacer()
                Image(systemName: "hand.tap").font(.largeTitle).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                Text("Click an event to see its parameters.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text(model.statusText).lineLimit(1)
            Spacer()
            Text("Clear View never clears device logs").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.panel)
    }
}


/// Makes every scroll view in the window use thin overlay scrollbars.
struct SlimScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(view.window?.contentView) }
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.apply(view.window?.contentView) }
        }
    }
    private static func apply(_ root: NSView?) {
        guard let root else { return }
        if let sv = root as? NSScrollView {
            sv.scrollerStyle = .overlay
            sv.verticalScroller?.controlSize = .mini
            sv.horizontalScroller?.controlSize = .mini
        }
        root.subviews.forEach(apply)
    }
}


/// Palette taken from the cat mascot: cream, dark brown, dusty pink, leaf green.
enum Theme {
    static let accent = Color(red: 0.68, green: 0.48, blue: 0.48)       // #AD7B7B
    static let green = Color(red: 0.58, green: 0.69, blue: 0.35)        // #94B058
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let bg = dyn(NSColor.white, NSColor(red: 0.18, green: 0.14, blue: 0.13, alpha: 1))
    static let panel = dyn(NSColor(red: 0.95, green: 0.94, blue: 0.92, alpha: 1), NSColor(red: 0.24, green: 0.19, blue: 0.18, alpha: 1))
}
