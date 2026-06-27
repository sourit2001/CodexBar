import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let quotaView = QuotaView(frame: NSRect(x: 0, y: 0, width: 290, height: 100))
    private let touchBarController = QuotaTouchBarController()
    private let approvalLogMonitor = ApprovalLogMonitor()
    private var client: CodexAppServerClient?
    private var quotaTimer: Timer?
    private var attentionTimer: Timer?
    private var lastSnapshot: RateLimitSnapshot?
    private var attentionState: CodexAttentionState = .none

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppLog.write("applicationDidFinishLaunching")
        configureStatusItem()
        updateUI(snapshot: nil, attention: .none, error: "正在连接 Codex")

        let client = CodexAppServerClient()
        self.client = client
        client.start()

        refresh()
        refreshAttention()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        attentionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshAttention()
        }

        touchBarController.present()
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaTimer?.invalidate()
        attentionTimer?.invalidate()
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
        menu.addItem(NSMenuItem(title: "打开 Codex", action: #selector(openCodex), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func refreshFromMenu() {
        refresh()
        refreshAttention()
    }

    @objc private func openCodex() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Codex.app"), configuration: NSWorkspace.OpenConfiguration())
    }

    private func refresh() {
        client?.readRateLimits { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let snapshot):
                    self?.lastSnapshot = snapshot
                    self?.updateUI(snapshot: snapshot, attention: self?.attentionState ?? .none, error: nil)
                case .failure(let error):
                    self?.updateUI(snapshot: self?.lastSnapshot, attention: self?.attentionState ?? .none, error: error.localizedDescription)
                }
            }
        }
    }

    private func refreshAttention() {
        approvalLogMonitor.readPendingApproval { [weak self] logAttention in
            DispatchQueue.main.async {
                self?.attentionState = logAttention
                self?.updateUI(snapshot: self?.lastSnapshot, attention: logAttention, error: nil)
            }

            self?.client?.readAttentionState { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let serverAttention):
                        let attention = serverAttention.merged(with: logAttention)
                        self?.attentionState = attention
                        self?.updateUI(snapshot: self?.lastSnapshot, attention: attention, error: nil)
                    case .failure(let error):
                        AppLog.write("attention refresh failed: \(error.localizedDescription)")
                        self?.attentionState = logAttention
                        self?.updateUI(snapshot: self?.lastSnapshot, attention: logAttention, error: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func updateUI(snapshot: RateLimitSnapshot?, attention: CodexAttentionState, error: String?) {
        let model = QuotaDisplayModel(snapshot: snapshot, attention: attention, error: error)
        statusItem.button?.title = model.statusTitle
        statusItem.button?.toolTip = attention.message ?? "Codex 额度"
        quotaView.update(model)
        touchBarController.update(model)
    }
}
