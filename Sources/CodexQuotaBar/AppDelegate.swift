import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let quotaView = QuotaView(frame: NSRect(x: 0, y: 0, width: 290, height: 190), showsClaude: true)
    private let touchBarController = QuotaTouchBarController()
    private let approvalLogMonitor = ApprovalLogMonitor()
    private var client: CodexAppServerClient?
    private var quotaTimer: Timer?
    private var attentionTimer: Timer?
    private var lastSnapshot: RateLimitSnapshot?
    private var attentionState: CodexAttentionState = .none
    private let claudeClient = ClaudeUsageClient()
    private var claudeTimer: Timer?
    private var lastClaudeSnapshot: ClaudeUsageSnapshot?
    private var codexStatusTitle = "--%"
    private var claudeStatusTitle = "--%"

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

        updateClaudeUI(snapshot: nil, error: "正在读取 Claude Code 额度")
        refreshClaude()
        // The Claude usage endpoint is rate limited, so poll it less often.
        claudeTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshClaude()
        }

        touchBarController.present()
    }

    func applicationWillTerminate(_ notification: Notification) {
        quotaTimer?.invalidate()
        attentionTimer?.invalidate()
        claudeTimer?.invalidate()
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
        statusItem.button?.toolTip = "Codex / Claude Code 额度"
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
        refreshClaude()
    }

    @objc private func openCodex() {
        let byBundleID = ["com.openai.codex", "com.openai.chat"].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        let fallback = ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
            .first(where: FileManager.default.fileExists).map { URL(fileURLWithPath: $0) }
        guard let url = byBundleID ?? fallback else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
        codexStatusTitle = model.statusTitle
        updateStatusTitle()
        statusItem.button?.toolTip = attention.message ?? "左：Codex 剩余  右（C）：Claude Code 5小时剩余"
        quotaView.update(model)
        touchBarController.update(model)
    }

    private func refreshClaude() {
        claudeClient.readUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    self.lastClaudeSnapshot = snapshot
                    self.updateClaudeUI(snapshot: snapshot, error: nil)
                case .failure(let error):
                    self.updateClaudeUI(snapshot: self.lastClaudeSnapshot, error: error.localizedDescription)
                }
            }
        }
    }

    private func updateClaudeUI(snapshot: ClaudeUsageSnapshot?, error: String?) {
        let model = ClaudeDisplayModel(snapshot: snapshot, error: error)
        claudeStatusTitle = model.primary.remainingText
        quotaView.updateClaude(model)
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        statusItem.button?.title = "\(codexStatusTitle) · C \(claudeStatusTitle)"
    }
}
