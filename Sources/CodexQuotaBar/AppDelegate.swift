import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let quotaView = QuotaView(frame: NSRect(x: 0, y: 0, width: 290, height: 78))
    private let touchBarController = QuotaTouchBarController()
    private var client: CodexAppServerClient?
    private var timer: Timer?
    private var lastSnapshot: RateLimitSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppLog.write("applicationDidFinishLaunching")
        configureStatusItem()
        updateUI(snapshot: nil, error: "正在连接 Codex")

        let client = CodexAppServerClient()
        self.client = client
        client.start()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        touchBarController.present()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        client?.stop()
    }

    private func configureStatusItem() {
        statusItem.isVisible = true
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        if #available(macOS 11.0, *) {
            statusItem.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Codex")
        }
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = "--%"
        statusItem.button?.toolTip = "Codex 额度"
        AppLog.write("status button configured: \(statusItem.button != nil)")

        let menu = NSMenu()
        let viewItem = NSMenuItem()
        viewItem.view = quotaView
        menu.addItem(viewItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    private func refresh() {
        client?.readRateLimits { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let snapshot):
                    self?.lastSnapshot = snapshot
                    self?.updateUI(snapshot: snapshot, error: nil)
                case .failure(let error):
                    self?.updateUI(snapshot: self?.lastSnapshot, error: error.localizedDescription)
                }
            }
        }
    }

    private func updateUI(snapshot: RateLimitSnapshot?, error: String?) {
        let model = QuotaDisplayModel(snapshot: snapshot, error: error)
        statusItem.button?.title = model.statusTitle
        quotaView.update(model)
        touchBarController.update(model)
    }
}
