import AppKit

final class QuotaTouchBarController: NSObject, NSTouchBarDelegate {
    private let touchBar = NSTouchBar()
    private let itemIdentifier = NSTouchBarItem.Identifier("CodexQuotaBar.item")
    private let trayIdentifier = "com.codex.quota.touchbar" as NSString
    private let view = QuotaView(frame: NSRect(x: 0, y: 0, width: 520, height: 64))

    override init() {
        super.init()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [itemIdentifier]
    }

    func present() {
        let selectors = [
            "presentSystemModalTouchBar:systemTrayItemIdentifier:",
            "presentSystemModalFunctionBar:systemTrayItemIdentifier:"
        ]

        for name in selectors {
            let selector = NSSelectorFromString(name)
            if NSApp.responds(to: selector) {
                _ = NSApp.perform(selector, with: touchBar, with: trayIdentifier)
                return
            }
        }
    }

    func update(_ model: QuotaDisplayModel) {
        view.update(model)
        present()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == itemIdentifier else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = view
        item.customizationLabel = "Codex 额度"
        return item
    }
}
