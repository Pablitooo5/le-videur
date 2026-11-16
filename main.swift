// Le Videur — quand Claude Code s'apprête à faire quelque chose de dangereux, un videur apparaît à l'écran
// pendant que Claude Code te demande ton accord. (Le blocage lui-même est fait par videur.py, dans le hook.)
import Cocoa
import WebKit

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct Config: Codable {
    var paused: Bool = false
    var sound: Bool = true
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var panel: OverlayPanel!
    private var web: WKWebView!
    private var statusItem: NSStatusItem!
    private var protectItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private var pageReady = false
    private var showing = false
    private var showingSince = Date()
    private var sounds: [String: NSSound] = [:]
    private var playing: [NSSound] = []
    private var config = Config()

    private let home = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/videur")
    private var eventsDir: String { (home as NSString).appendingPathComponent("events") }
    private var configPath: String { (home as NSString).appendingPathComponent("config.json") }
    private var demoFlag: String { (home as NSString).appendingPathComponent("demo") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: eventsDir, withIntermediateDirectories: true)
        loadConfig()
        let frame = currentScreen().visibleFrame

        panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "videur")
        web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        panel.contentView = web
        if let url = Bundle.main.url(forResource: "overlay", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        for name in ["stomp", "buzzer"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
                sounds[name] = NSSound(contentsOf: url, byReference: false)
            }
        }
        buildMenu()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageReady = true }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let value = body["value"] as? String ?? ""
        if type == "sfx", config.sound { play(value) }
        if type == "done" { showing = false }
    }

    private func play(_ name: String) {
        playing.removeAll { !$0.isPlaying }
        guard let s = sounds[name]?.copy() as? NSSound else { return }
        s.play()
        playing.append(s)
    }

    private func tick() {
        guard pageReady else { return }
        let fm = FileManager.default
        if showing {
            if Date().timeIntervalSince(showingSince) > 30 { showing = false }   // garde-fou
            return
        }
        if fm.fileExists(atPath: demoFlag) {
            try? fm.removeItem(atPath: demoFlag)
            runDemo()
            return
        }
        guard let names = try? fm.contentsOfDirectory(atPath: eventsDir) else { return }
        let files = names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        guard let first = files.first else {
            followScreen()
            return
        }
        // S'il y en a plusieurs d'un coup, on n'en montre qu'un (le plus récent).
        let path = (eventsDir as NSString).appendingPathComponent(files.last ?? first)
        let data = fm.contents(atPath: path)
        for f in files { try? fm.removeItem(atPath: (eventsDir as NSString).appendingPathComponent(f)) }
        guard let data, let json = String(data: data, encoding: .utf8),
              json.trimmingCharacters(in: .whitespaces).hasPrefix("{") else { return }
        show(json)
    }

    private func show(_ eventJSON: String) {
        showing = true
        showingSince = Date()
        followScreen()
        web.evaluateJavaScript("videur.show(\(eventJSON))", completionHandler: nil)
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func followScreen() {
        let frame = currentScreen().visibleFrame
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func loadConfig() {
        if let data = FileManager.default.contents(atPath: configPath),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
        }
        saveConfig()
    }

    private func saveConfig() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(config) {
            try? data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        }
    }

    // MARK: - Menu (icône 🕶️)

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🕶️"
        let menu = NSMenu()
        let title = NSMenuItem(title: "Le Videur", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item("Lancer la démo", #selector(runDemo)))
        protectItem = item("Protection active", #selector(toggleProtection)); menu.addItem(protectItem)
        soundItem = item("Son", #selector(toggleSound)); menu.addItem(soundItem)
        menu.addItem(.separator())
        menu.addItem(item("Quitter (la protection reste active)", #selector(quit), key: "q"))
        statusItem.menu = menu
        refreshMenu()
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func refreshMenu() {
        protectItem.state = config.paused ? .off : .on
        soundItem.state = config.sound ? .on : .off
        statusItem.button?.title = config.paused ? "😴" : "🕶️"
    }

    @objc private func runDemo() {
        show("{\"action\":\"Supprimer définitivement : ressources-app\",\"detail\":\"rm -rf ressources-app\",\"title\":\"Démo\"}")
    }

    @objc private func toggleProtection() {
        if !config.paused {
            let alert = NSAlert()
            alert.messageText = "Désactiver le Videur ?"
            alert.informativeText = "Claude pourra de nouveau lancer des actions dangereuses sans te demander."
            alert.addButton(withTitle: "Désactiver")
            alert.addButton(withTitle: "Annuler")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        config.paused.toggle()
        saveConfig()
        refreshMenu()
    }

    @objc private func toggleSound() { config.sound.toggle(); saveConfig(); refreshMenu() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
