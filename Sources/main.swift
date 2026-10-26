import AppKit
import IOKit.ps
import Network
import ServiceManagement
import SystemConfiguration
import UniformTypeIdentifiers

// 규칙 두 개:
// 1. 제한된 네트워크(저데이터 모드 / 종량제 / 아이폰 핫스팟)가 주 경로면 사용자가 고른 앱 종료
// 2. 배터리 전원이면 사용자가 고른 앱 종료
// 어느 규칙에도 안 걸리게 되면 LowTide가 종료했던 앱만 다시 실행한다.

// 본체가 띄우는 별도 동기화 엔진. 본체와 같이 종료만 하고 재실행은 본체에 맡긴다.
// OneDrive는 독립 설치판(com.microsoft.OneDrive)과 App Store판(com.microsoft.OneDrive-mac)이 따로 있음
let helperIDs: [String: [String]] = [
    "com.microsoft.OneDrive": ["com.microsoft.SharePoint-mac"],
    "com.microsoft.OneDrive-mac": ["com.microsoft.SharePoint-mac"],
]

enum AppList: String {
    case network = "networkAppIDs"
    case battery = "batteryAppIDs"

    var defaultIDs: [String] {
        switch self {
        case .network: return ["com.google.drivefs", "com.microsoft.OneDrive-mac", "com.microsoft.OneDrive"]
        case .battery: return ["ai.calidalab.SiliconScope"]
        }
    }
    var title: String {
        switch self {
        case .network: return "제한 네트워크일 때 종료할 앱"
        case .battery: return "배터리일 때 종료할 앱"
        }
    }
}

enum Key {
    static let enabled = "enabled"
    static let includeExpensive = "includeExpensive"
    static let detectHotspot = "detectHotspot"
    static let batteryEnabled = "batteryEnabled"
    static let killedByUs = "killedByUsIDs"
}

// 아이폰 개인용 핫스팟은 항상 172.20.10.0/28 대역, 라우터 172.20.10.1
let iPhoneHotspotRouter = "172.20.10.1"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = NWPathMonitor()
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var statusItem: NSStatusItem!
    private var debounce: DispatchWorkItem?
    private var lastPath: NWPath?
    private var wifiPath: NWPath?
    private var networkBlocking = false
    private var batteryBlocking = false
    private var networkReason = ""
    private let defaults = UserDefaults.standard
    private let store = SCDynamicStoreCreate(nil, "LowTide" as CFString, nil, nil)

    private var enabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }
    private var includeExpensive: Bool {
        get { defaults.object(forKey: Key.includeExpensive) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.includeExpensive) }
    }
    private var detectHotspot: Bool {
        get { defaults.object(forKey: Key.detectHotspot) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.detectHotspot) }
    }
    private var batteryEnabled: Bool {
        get { defaults.object(forKey: Key.batteryEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.batteryEnabled) }
    }
    private func ids(_ list: AppList) -> [String] {
        defaults.stringArray(forKey: list.rawValue) ?? list.defaultIDs
    }
    private func setIDs(_ ids: [String], _ list: AppList) {
        defaults.set(ids, forKey: list.rawValue)
    }
    private var killedByUs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.killedByUs) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.killedByUs) }
    }

    /// 지금 종료 상태여야 하는 앱
    private var blockedIDs: Set<String> {
        var result = Set<String>()
        if networkBlocking { result.formUnion(ids(.network)) }
        if batteryBlocking { result.formUnion(ids(.battery)) }
        return result
    }

    /// 지금 종료 상태여야 하는 헬퍼 (재실행 추적 안 함)
    private var blockedHelperIDs: Set<String> {
        Set(blockedIDs.flatMap { helperIDs[$0] ?? [] })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        // 차단 중에 앱이 (로그인 항목 등으로) 다시 뜨면 바로 종료
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastPath = path
                self.log("path status=\(path.status) constrained=\(path.isConstrained) expensive=\(path.isExpensive) primary=\(self.primaryInterface ?? "-") router=\(self.router ?? "-")")
                self.scheduleEvaluate()
            }
        }
        monitor.start(queue: .global(qos: .utility))

        wifiMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.wifiPath = path }
        }
        wifiMonitor.start(queue: .global(qos: .utility))

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.log("power source=\(delegate.powerSource)")
            delegate.scheduleEvaluate()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        log("power source=\(powerSource)")
        scheduleEvaluate()
    }

    /// 네트워크 전환·충전기 접촉 불량 같은 깜빡임 방지
    private func scheduleEvaluate() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func evaluate() {
        // 연결 끊김 상태에서는 네트워크 판단 보류 (끊겼다 같은 제한 네트워크로 재접속하는 경우 대비)
        if let path = lastPath, path.status == .satisfied {
            let limit = limitReason(path)
            networkReason = limit ?? ""
            networkBlocking = enabled && limit != nil
        }
        batteryBlocking = batteryEnabled && onBattery

        let blocked = blockedIDs
        for id in blocked where isRunning(id) {
            log("quitting \(displayName(id)) (network=\(networkBlocking) battery=\(batteryBlocking))")
            quit(id)
            killedByUs.insert(id)
        }
        for id in blockedHelperIDs where isRunning(id) {
            log("quitting helper \(id)")
            quit(id)
        }
        let toLaunch = killedByUs.subtracting(blocked)
        for id in toLaunch {
            log("relaunching \(displayName(id))")
            launch(id)
        }
        killedByUs.subtract(toLaunch)
        updateIcon()
    }

    // MARK: - Network

    private var globalIPv4: [String: Any]? {
        guard let store else { return nil }
        return SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    }
    private var primaryInterface: String? { globalIPv4?["PrimaryInterface"] as? String }
    private var router: String? { globalIPv4?["Router"] as? String }

    /// 주 경로(실제 트래픽이 나가는 경로)가 제한 네트워크인지. nil이면 제한 아님.
    private func limitReason(_ path: NWPath) -> String? {
        if path.isConstrained { return "저데이터 모드" }
        if includeExpensive && path.isExpensive { return "종량제 네트워크" }
        if detectHotspot && router == iPhoneHotspotRouter { return "아이폰 핫스팟" }
        return nil
    }

    // MARK: - Power

    private var powerSource: String {
        IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? ?? "unknown"
    }
    private var onBattery: Bool { powerSource == kIOPMBatteryPowerKey }

    // MARK: - Apps

    private func running(_ id: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: id)
    }

    private func isRunning(_ id: String) -> Bool { !running(id).isEmpty }

    private func appURL(_ id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    private func displayName(_ id: String) -> String {
        guard let url = appURL(id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func quit(_ id: String) {
        running(id).forEach { $0.terminate() }
        // 업로드 대기 확인창 등으로 안 꺼지면 강제 종료
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            let remaining = self.running(id)
            if !remaining.isEmpty {
                self.log("\(self.displayName(id)) still running → force terminate")
                remaining.forEach { $0.forceTerminate() }
            }
        }
    }

    private func launch(_ id: String) {
        guard let url = appURL(id) else {
            log("\(id) not installed")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            if let error { self?.log("\(id) launch failed: \(error.localizedDescription)") }
        }
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier else { return }
        if blockedIDs.contains(id) {
            log("\(displayName(id)) launched while blocked → quitting")
            quit(id)
            killedByUs.insert(id)
        } else if blockedHelperIDs.contains(id) {
            log("helper \(id) launched while blocked → quitting")
            quit(id)
        }
    }

    // MARK: - Menu

    private func updateIcon() {
        let symbol: String
        if networkBlocking { symbol = "icloud.slash" }
        else if batteryBlocking { symbol = "battery.25percent" }
        else { symbol = "icloud" }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LowTide")
    }

    // 메뉴를 열 때마다 최신 상태로 다시 그림
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled("네트워크: \(networkDescription)"))
        menu.addItem(disabled("  주 경로: \(primaryInterface ?? "-") · 라우터 \(router ?? "-")"))
        menu.addItem(disabled("  Wi-Fi: \(wifiDescription)"))
        menu.addItem(disabled("전원: \(onBattery ? "배터리" : "어댑터")\(batteryBlocking ? " → 차단 중" : "")"))
        menu.addItem(.separator())

        menu.addItem(toggle("제한 네트워크에서 앱 종료", on: enabled, #selector(toggleEnabled)))
        menu.addItem(toggle("종량제 네트워크도 포함", on: includeExpensive, #selector(toggleExpensive)))
        menu.addItem(toggle("아이폰 핫스팟 자동 감지", on: detectHotspot, #selector(toggleHotspot)))
        menu.addItem(listMenuItem(.network))
        if installedIDs(.network).contains(where: isRunning) {
            menu.addItem(action("지금 종료", #selector(manualQuitNetwork)))
        } else {
            menu.addItem(action("지금 실행", #selector(manualLaunchNetwork)))
        }
        menu.addItem(.separator())

        menu.addItem(toggle("배터리일 때 앱 종료", on: batteryEnabled, #selector(toggleBattery)))
        menu.addItem(listMenuItem(.battery))
        menu.addItem(.separator())

        menu.addItem(toggle("로그인 시 실행", on: SMAppService.mainApp.status == .enabled, #selector(toggleLoginItem)))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        menu.addItem(disabled("LowTide \(version)"))
        menu.addItem(NSMenuItem(title: "LowTide 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// 설치된 앱만 (기본 목록에 OneDrive 두 판이 다 들어 있으므로)
    private func installedIDs(_ list: AppList) -> [String] {
        ids(list).filter { appURL($0) != nil }
    }

    private func listMenuItem(_ list: AppList) -> NSMenuItem {
        let listItem = NSMenuItem(title: list.title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let installed = installedIDs(list)
        for id in installed {
            let item = NSMenuItem(title: appStatus(id), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let remove = action("목록에서 제거", #selector(removeApp(_:)))
            remove.representedObject = [list.rawValue, id]
            sub.addItem(remove)
            item.submenu = sub
            menu.addItem(item)
        }
        if !installed.isEmpty { menu.addItem(.separator()) }
        let add = action("앱 추가…", #selector(addApp(_:)))
        add.representedObject = list.rawValue
        menu.addItem(add)
        listItem.submenu = menu
        return listItem
    }

    private func appStatus(_ id: String) -> String {
        let state = isRunning(id) ? "실행 중" : "종료됨"
        let mark = killedByUs.contains(id) ? " (LowTide가 종료)" : ""
        return "\(displayName(id)): \(state)\(mark)"
    }

    private var networkDescription: String {
        guard let p = lastPath else { return "확인 중…" }
        guard p.status == .satisfied else { return "연결 없음" }
        return limitReason(p).map { "\($0)\(networkBlocking ? " → 차단 중" : "")" } ?? "일반"
    }

    private var wifiDescription: String {
        guard let p = wifiPath, p.status == .satisfied else { return "연결 안 됨" }
        var parts: [String] = []
        if p.isConstrained { parts.append("저데이터 모드") }
        if p.isExpensive { parts.append("종량제") }
        let flags = parts.isEmpty ? "일반" : parts.joined(separator: ", ")
        let isPrimary = p.availableInterfaces.contains { $0.name == primaryInterface }
        return isPrimary ? flags : "\(flags) (주 경로 아님)"
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func toggle(_ title: String, on: Bool, _ sel: Selector) -> NSMenuItem {
        let item = action(title, sel)
        item.state = on ? .on : .off
        return item
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleEnabled() { enabled.toggle(); evaluate() }
    @objc private func toggleExpensive() { includeExpensive.toggle(); evaluate() }
    @objc private func toggleHotspot() { detectHotspot.toggle(); evaluate() }
    @objc private func toggleBattery() { batteryEnabled.toggle(); evaluate() }

    @objc private func addApp(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let list = AppList(rawValue: raw) else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.message = "\(list.title)을 고르세요"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var current = ids(list)
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !current.contains(id),
                  id != Bundle.main.bundleIdentifier else { continue }
            current.append(id)
        }
        setIDs(current, list)
        evaluate()
    }

    @objc private func removeApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let list = AppList(rawValue: pair[0]) else { return }
        setIDs(ids(list).filter { $0 != pair[1] }, list)
        evaluate()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("login item error: \(error.localizedDescription)")
        }
    }

    @objc private func manualQuitNetwork() {
        // 수동 종료는 자동 재실행 대상 아님
        let targets = ids(.network)
        killedByUs.subtract(targets)
        let helpers = targets.flatMap { helperIDs[$0] ?? [] }
        (targets + helpers).filter(isRunning).forEach(quit)
    }

    @objc private func manualLaunchNetwork() {
        // 제한 네트워크 중 수동 실행이면 네트워크 규칙을 끄고 실행 (안 그러면 바로 다시 죽음)
        if networkBlocking { enabled = false; networkBlocking = false }
        let targets = installedIDs(.network)
        killedByUs.subtract(targets)
        // OneDrive 두 판이 다 깔려 있어도 하나만 실행
        var launched = Set<String>()
        for id in targets where launched.insert(displayName(id)).inserted {
            launch(id)
        }
        updateIcon()
    }

    fileprivate func log(_ message: String) {
        NSLog("[LowTide] %@", message)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
