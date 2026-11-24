import UIKit
import SwiftUI
import AVKit
import Network
import NetworkExtension
import CoreLocation
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

final class ReceiverViewController: UIViewController, CLLocationManagerDelegate {
    private let receiver = NativeReceiver()
    private let bluetooth = BLEBootstrap()
    private let sameDevice = SameDeviceProbe()
    private let transportProbe = DirectAccessoryTransport()
    private let controlBrowser = CarPlayControlBrowser()
    private let receiverBrowser = TDSCarKitReceiverBrowser()
    private let receiverPicker = UIButton(type: .system)
    private var remoteTarget: TDSCarKitReceiverBrowser.Target?
    private let modeControl = UISegmentedControl(items: ["接收其他设备", "本机 CarPlay", "投送到 iPad"])
    private let nameField = UITextField()
    private let ipField = UITextField()
    private let ssidField = UITextField()
    private let passwordField = UITextField()
    private let showWiFiPasswordSwitch = UISwitch()
    private let pasteWiFiPassword = UIPasteControl(configuration: .init())
    private var passwordLoadedForSSID: String?
    private let channelField = UITextField()
    private let openNetworkSwitch = UISwitch()
    private enum SoundOutput: Int, CaseIterable {
        // Retain the persisted values so the existing Wi-Fi preference survives this change.
        case carWithin = 0, phone = 1, browser = 2

        var title: String { ["在接收设备上播放", "由 iPhone 输出", "随画面传输（Wi-Fi）"][rawValue] }

        var explanation: String {
            switch self {
            case .carWithin: return "声音由当前接收设备播放，例如 iPad 的扬声器。"
            case .phone: return "用 iPhone 当前的声音输出。想让车机出声，请先配对并选中车机蓝牙。"
            case .browser: return "由接收画面的设备播放。画面自动播放后，若网页提示「开启声音」，点一下即可。"
            }
        }
    }
    private var selectedSoundOutput: SoundOutput = {
        let defaults = UserDefaults.standard
        let receivesOnPad = UIDevice.current.userInterfaceIdiom == .pad
        let legacy: SoundOutput = receivesOnPad && (defaults.object(forKey: "speakerAudio") as? Bool ?? true)
            ? .carWithin : .phone
        let saved = (defaults.object(forKey: "soundOutput") as? Int).flatMap(SoundOutput.init(rawValue:)) ?? legacy
        if saved == .carWithin && !receivesOnPad {
            defaults.set(SoundOutput.phone.rawValue, forKey: "soundOutput")
            return .phone
        }
        return saved
    }()
    private var receivesAudioFromAnotherDevice: Bool { modeControl.selectedSegmentIndex == 0 }
    private var soundOutput: SoundOutput {
        if outputMode == .carLife || outputMode == .airPlay || outputMode.usesInstrumentWiFi { return .phone }
        if selectedSoundOutput == .carWithin && !receivesAudioFromAnotherDevice { return .phone }
        if selectedSoundOutput == .browser && !videoOutputSwitch.isOn { return .phone }
        return selectedSoundOutput
    }
    private let videoOutputSwitch = UISwitch()
    private let videoOutputPortField = UITextField()
    private let secureVideoOutputPortField = UITextField()
    private let httpsMode = ChoiceMenu(items: ["本地 IP", "sslip.io", "DuckDNS"])
    private let httpsDomainField = UITextField()
    private let httpsTokenField = UITextField()
    private let httpsStatus = StatusLabel()
    private let portStatus = StatusLabel()
    private let pictureInPictureButton = UIButton(type: .system)
    private let driveControl = ChoiceMenu(items: ["左舵", "右舵"])
    private let networkSummary = UILabel()
    private let locationManager = CLLocationManager()
    private var awaitingNetworkPermission = false
    private var activeWiFiForm: UUID?
    private var fetchingNetwork = false
    private var canDetectWiFiName: Bool { (Bundle.main.object(forInfoDictionaryKey: "TDSWiFiNameDetection") as? String) == "YES" }
    /// The settings sheet while it is shown.
    private weak var settingsNavigation: UINavigationController?
    private let transportProbeButton = UIButton(type: .system)
    private let orientationControl = ChoiceMenu(items: ["横屏", "竖屏"])
    private let wifiPathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var networkStartupTask: Task<Void, Never>?
    private var waitingForNetwork = false
    private let ninebotAutoConnectSwitch = UISwitch()
    private let ninebotCurrentWiFiSwitch = UISwitch()
    private var attemptedNinebotAutoConnect = false
    private var wiFiJoinID: UUID?
    private var wiFiJoinTask: Task<Void, Never>?
    private var wiFiJoinTimeoutTask: Task<Void, Never>?
    private var startingAfterWiFiJoin = false
    private var startingWithCurrentWiFi = false
    private var supportsCurrentWiFiStartup: Bool {
        modeControl.selectedSegmentIndex == 1 && (outputMode == .ninebot || outputMode == .ninebotSeven)
    }
    private var prefersCurrentWiFiStartup: Bool { supportsCurrentWiFiStartup && ninebotCurrentWiFiSwitch.isOn }
    private var enteredWiFiCredentials: AccessoryMessages.WiFi? {
        let password = openNetworkSwitch.isOn ? "" : (passwordField.text ?? "")
        guard openNetworkSwitch.isOn || !password.isEmpty else { return nil }
        return try? AccessoryMessages.WiFi(ssid: ssidField.text ?? "", password: password,
                                         channel: UInt8(channelField.text ?? "") ?? 36)
    }
    private var networkRestartCount = 0
    private var localStartupID: UUID?
    private let aspectRatioControl = ChoiceMenu(items: ["预设比例"] + ReceiverConfiguration.aspectRatios.map(\.title))
    private let resolutionControl = ChoiceMenu(items: ReceiverConfiguration.resolutions.map { "\($0.label)（\($0.width)×\($0.height)）" })
    private let frameRateControl = ChoiceMenu(items: ["自动", "30 FPS", "60 FPS"])
    private let codecControl = ChoiceMenu(items: ["自动", "H.264", "H.265"])
    /// 0 = follow the head unit's screen, 1 = the fixed resolution.
    private let sizeModeControl = ChoiceMenu(items: ["跟随车机", "固定尺寸"])
    private let iconSizeControl = ChoiceMenu(items: ReceiverConfiguration.iconSizes.map { "\($0.title)（\($0.widthMM) mm）" })
    private let autoRestartSwitch = UISwitch()
    private let performanceControl = ChoiceMenu(items: BrowserPerformance.allCases.map(\.title))
    private let showTouchesSwitch = UISwitch()
    private let carButtonSwitch = UISwitch()
    private static let customVehicleIconKey = "customVehicleButtonPNG"
    private var customVehicleIcon: Data? { UserDefaults.standard.data(forKey: Self.customVehicleIconKey) }
    private var importingVehicleIcon = false
    /// 0 = off, 1 = when leaving the app, 2 = as soon as CarPlay shows.
    private let pictureInPictureTiming = ChoiceMenu(items: ["关闭", "离开 App 时", "出画面后立即"])
    private var didRequestImmediatePiP = false
    /// What the running session was started with; compared against what the head unit reports.
    private var liveDisplay: DisplayPlan?
    /// Screen reported by a browser in this run; it wins over the saved default.
    private var reportedScreen: CarScreen?
    private var primaryViewer: UUID?
    private var screenAdaptation: DispatchWorkItem?
    /// Automatic restarts for lighter settings in this connection; at most two.
    private var autoRestarts = 0
    /// 0 = normal, 1 = 30 FPS, 2 = also at most 720p. Raised by "自动重启" when a browser keeps hitching.
    private var lightLevel = 0
    private var restartingAutomatically = false
    private var pendingRestartReason: String?
    private let appearanceControl = ChoiceMenu(items: ReceiverConfiguration.Appearance.allCases.map(\.title))
    /// CarPlay keys under the inline video.
    private let controlBar = UIStackView()
    private let secureBrowserURLLabel = UILabel()
    private let secureBrowserCopyButton = UIButton(type: .system)
    private let secureBrowserRow = UIStackView()
    private let secureBrowserDisclosure = UIButton(type: .system)
    private let httpsExpandedKey = "browserHTTPSExpanded"
    private var httpsExpanded: Bool { UserDefaults.standard.bool(forKey: httpsExpandedKey) }
    private let browserCard = UIStackView()
    private let zeehoCard = UIStackView()
    private let zeehoCardStatus = UILabel()
    private let zeehoStatus = StatusLabel()
    private let zeehoAddressField = UITextField()
    private func updateZeehoStatus(_ message: String) {
        zeehoStatus.text = message
        zeehoCardStatus.text = message
    }
    private let ninebotCard = UIStackView()
    private var ninebotCardInstructions: UILabel?
    private static let ninebotFiveInstructions = "点「启动本机 CarPlay」后，会先准备仪表投屏通道并发送握手，再自动启动 CarPlay。\n若仪表仍未出画，可保持 CarPlay 运行，到九号出行开启投屏导航；出画后退出九号出行。"
    private static let ninebotOfficialInstructions = "点「启动本机 CarPlay」后，会先准备仪表投屏通道并发送握手，再自动启动 CarPlay。\n若仪表仍未出画，该型号可能仍需在九号出行开启投屏导航，并让九号出行留在后台。"
    private let ninebotCardStatus = UILabel()
    private let ninebotStatus = StatusLabel()
    private let ninebotAddressField = UITextField()
    private let ninebot43AddressField = UITextField()
    private var activeNinebotAddressField: UITextField { outputMode == .ninebot43 ? ninebot43AddressField : ninebotAddressField }
    private var ninebotInstructions: String {
        outputMode == .ninebot ? Self.ninebotFiveInstructions : Self.ninebotOfficialInstructions
    }
    private func updateNinebotStatus(_ message: String) {
        ninebotStatus.text = message
        ninebotCardStatus.text = message
    }
    private let tailingCard = UIStackView()
    private let tailingCardStatus = UILabel()
    private let tailingAddressField = UITextField()
    private let tailingStatus = StatusLabel()
    private func updateTailingStatus(_ message: String) {
        tailingStatus.text = message; tailingCardStatus.text = message
    }
    private let carLifeCard = UIStackView()
    private let airPlayCard = UIStackView()
    private let carLifeCardStatus = UILabel()
    private let airPlayCardStatus = UILabel()
    private let airPlayRoutePicker = AVRoutePickerView()
    private let airPlayRetryButton = UIButton(type: .system)
    private let browserURLLabel = UILabel()
    private let browserViewersLabel = UILabel()
    private let browserCopyButton = UIButton(type: .system)
    private let bluetoothSetupSwitch = UISwitch()
    private var needsNetworkDetails: Bool { modeControl.selectedSegmentIndex != 0 || bluetoothSetupSwitch.isOn }
    private let startButton = UIButton(type: .system)
    private let heading = UILabel()
    private let explanation = UILabel()
    private let statusLabel = UILabel()
    private let startupHint = UILabel()
    private let identitySetupButton = UIButton(type: .system)
    private let identityImportStatus = StatusLabel()
    private enum DocumentImportPurpose { case https, identityIPA, identityFiles }
    private var documentImportPurpose: DocumentImportPurpose = .https
    private var startupHintTask: DispatchWorkItem?
    private var startupHintGeneration = UUID()
    private let connectionHelp = UILabel()
    private let homeStack = UIStackView()
    private let homeScroll = UIScrollView()
    private let heroStack = UIStackView()
    private var heroTitleRow: UIStackView?
    private let connectionDetailsButton = UIButton(type: .system)
    private var showsConnectionDetails = false
    private let vehicleProfileButton = UIButton(type: .system)
    private let autoFullscreenSwitch = UISwitch()
    private var connectionTimeline: ConnectionTimeline?
    private var lastReceiverMessage: String?
    private let connectionReportStatus = StatusLabel()
    private let bmsSessionStatus = StatusLabel()
    private let bmsTrend = BMSVoltageTrendView()
    private var bmsSession = ANTBMSSessionStatistics()
    private var bmsSessionStartedAt: Date?
    private var bmsSessionVehicle = ""
    private var bmsSessionDevice: UUID?
    private var bmsSessionMinimumUptime = 0.0
    private var bmsSessionRecordID = UUID()
    private var lastBMSSaveUptime = 0.0
    private var applyingVehicleProfile = false
    private let logView = UITextView()
    private let videoSurface = H264Surface()
    private let bmsClient = ANTBMSClient()
    private let bmsOverlay = BMSOverlayPresenter()
    private let bmsEnabledSwitch = UISwitch()
    private let bmsPosition = ChoiceMenu(items: ANTBMSCardConfiguration.Position.allCases.map(\.title))
    private let bmsCardSize = ChoiceMenu(items: ANTBMSCardConfiguration.Size.allCases.map(\.title))
    private let bmsCardBackground = ChoiceMenu(items: ANTBMSCardConfiguration.Background.allCases.map(\.title))
    private var bmsCardConfiguration = ANTBMSCardConfiguration()
    private var bmsFieldSwitches: [ANTBMSCardConfiguration.Field: UISwitch] = [:]
    private let bmsCardPreview = BMSCardPreviewView()
    private let bmsCardPreviewStatus = StatusLabel()
    private let bmsStatus = StatusLabel()
    private let bmsDetails = StatusLabel()
    private let bmsLiveSummary = BMSLiveSummaryView()
    private var bmsDeviceList: [UUID] = []
    private let inlineVideoContainer = UIView()
    private var inlineVideoConstraints: [NSLayoutConstraint] = []
    private lazy var pictureInPicture = CarPlayPictureInPicture(surface: videoSurface)
    private let keepAlive = BackgroundKeepAlive()
    private let keepAliveSwitch = UISwitch()
    private let headUnitOutput = ChoiceMenu(items: ["浏览器", "CarLife", "AirPlay", "台铃 4.3 寸", "九号 5 寸", "极核 6.2 寸", "九号 7 寸", "九号 4.3 寸（实验）"])
    private enum HeadUnitOutput: Int {
        case browser, carLife, airPlay, tailing, ninebot, zeeho, ninebotSeven, ninebot43
        var ninebotMode: NinebotOutput.Mode? {
            switch self {
            case .ninebot: .fiveInch
            case .ninebotSeven: .sevenInch
            case .ninebot43: .fourThreeInch
            default: nil
            }
        }
        var usesInstrumentWiFi: Bool { self == .tailing || self == .zeeho || ninebotMode != nil }
    }
    private var airPlayStreamID: UUID?
    private var airPlayStreamURL: URL?
    private var airPlayPlayer: AVPlayer?
    private var airPlayRouteObservation: NSKeyValueObservation?
    private var airPlayItemObservation: NSKeyValueObservation?
    #if DEBUG
    private var airPlayTimeObservation: NSKeyValueObservation?
    private var airPlayDiagnostic = ""
    #endif
    private static let lastAirPlayDeviceKey = "lastAirPlayDeviceName"
    private var airPlayReady = false
    private let airPlayStatus = StatusLabel()
    private func updateAirPlayStatus(_ message: String) {
        airPlayStatus.text = message
        airPlayCardStatus.text = message
        airPlayRoutePicker.isUserInteractionEnabled = airPlayReady
        airPlayRoutePicker.alpha = airPlayReady ? 1 : 0.45
        if airPlayReady {
            airPlayRoutePicker.accessibilityTraits.remove(.notEnabled)
        } else {
            airPlayRoutePicker.accessibilityTraits.insert(.notEnabled)
        }
    }
    private var outputMode: HeadUnitOutput { HeadUnitOutput(rawValue: headUnitOutput.selectedSegmentIndex) ?? .browser }
    private let carLifeAddressField = UITextField()
    private let carLifeStatus = StatusLabel()
    private func updateCarLifeStatus(_ message: String) {
        carLifeStatus.text = message
        carLifeCardStatus.text = message
    }
    struct DisplayPlan: Equatable {
        var width: Int; var height: Int; var fps: Int; var codec: VideoCodec; var iconWidthMM: Int
    }
    /// Local frames were dropped in the background; the display needs a new keyframe on return.
    private var skippedLocalVideo = false
    /// The session survives backgrounding through PiP or the silent keep-alive audio.
    private var canRunInBackground: Bool { keepAlive.isRunning || pictureInPicture.canKeepSessionInBackground }
    private let fullscreenButton = UIButton(type: .system)
    private let videoActions = UIStackView()
    private let passwordStatus = StatusLabel()
    private var videoHeight: NSLayoutConstraint!
    private var fullscreenContainer: UIView?
    private var fullscreenConstraints: [NSLayoutConstraint] = []
    private var sessionHasVehicleButton = false
    private weak var fullscreenExitButton: UIButton?
    private var fullscreenFadeTimer: Timer?
    override var prefersStatusBarHidden: Bool { fullscreenContainer != nil }
    override var prefersHomeIndicatorAutoHidden: Bool { fullscreenContainer != nil }
    private var displayedVideo = false
    private var identity: AccessoryIdentity?
    private var running = false
    private var checkingForUpdates = false
    private var updateCheckTask: Task<Void, Never>?
    private var updateTimer: Timer?
    private weak var updateSheet: UIViewController?
    private var updateSheetAutomatic = false
    private static let projectURL = URL(string: "https://github.com/xmz28/CarWithin")!
    private static let releasesURL = projectURL.appendingPathComponent("releases")
    private static let supportURL = URL(string: "https://qr.alipay.com/fkx16608y1puemmltuocze0")!
    private static let authorURL = URL(string: "https://v.douyin.com/x64M2NbYj0A/")!
    private var lines: [String] = []
    private var launchedTransportTest = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !running { modeChanged() }
        attemptNinebotAutoConnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.checkForUpdates(manual: false)
        }
        #if DEBUG
        if !launchedTransportTest, ProcessInfo.processInfo.arguments.contains("--test-same-device-transport") {
            launchedTransportTest = true
            revealSettings()
            testSameDeviceTransport()
        } else if !launchedTransportTest, ProcessInfo.processInfo.arguments.contains("--test-local-transport") {
            launchedTransportTest = true
            modeControl.selectedSegmentIndex = 1; modeChanged(); toggleReceiver()
        } else if !launchedTransportTest, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--open-settings") {
            // Screenshots: --open-settings [display|screens|wifi|presets|vehicle|sound|output|web|log|lab|about|usage]
            launchedTransportTest = true
            revealSettings()
            let arguments = ProcessInfo.processInfo.arguments
            let pages: [String: () -> UIViewController] = [
                "display": displayPage, "screens": screensPage, "wifi": wifiPage, "presets": presetsPage,
                "vehicle": vehiclePage, "sound": soundPage, "output": headUnitPage,
                "tailing": { [unowned self] in self.headUnitOutput.selectedSegmentIndex = HeadUnitOutput.tailing.rawValue; self.refreshVideoOutputSummary(); return self.headUnitPage() },
                "web": headUnitPage, "log": logPage, "lab": diagnosticsPage, "about": aboutPage,
                "usage": usagePage, "updates": aboutPage, "https": httpsSettingsPage,
                "bms": bmsPage, "bms-devices": bmsDevicesPage, "bms-card": bmsCardPage,
                "bms-order": { [unowned self] in
                    BMSCardOrderViewController(fields: self.bmsCardConfiguration.fields) { _, _ in }
                },
                "bms-trend": { [unowned self] in self.bmsTrendPreview(legacy: false) },
                "bms-old-trend": { [unowned self] in self.bmsTrendPreview(legacy: true) }]
            if arguments.indices.contains(index + 1), let make = pages[arguments[index + 1]] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.settingsNavigation?.pushViewController(make(), animated: false)
                    if arguments[index + 1] == "updates" { self?.checkForUpdates() }
                }
            } else if arguments.indices.contains(index + 1), arguments[index + 1] == "history" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.showVersionHistory()
                }
            }
        }
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "CarWithin"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape.fill"), style: .plain, target: self, action: #selector(toggleSettings))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "设置"
        locationManager.delegate = self
        heading.font = .systemFont(ofSize: 32, weight: .bold)
        heading.numberOfLines = 0

        explanation.font = .preferredFont(forTextStyle: .body); explanation.textColor = .secondaryLabel; explanation.numberOfLines = 0
        [heading, explanation, statusLabel, connectionHelp, networkSummary].forEach { $0.adjustsFontForContentSizeCategory = true; $0.lineBreakMode = .byWordWrapping }
        statusLabel.font = .preferredFont(forTextStyle: .headline); statusLabel.numberOfLines = 0
        statusLabel.textColor = .systemBlue
        let savedName = UserDefaults.standard.string(forKey: "receiverName")
        // Earlier default names follow the rename; a name the user typed is kept.
        let legacyDefaults: Set<String> = ["TDS Car Kit", "CarPlays"]
        nameField.text = savedName.map { legacyDefaults.contains($0) ? "CarWithin" : $0 } ?? "CarWithin"
        ipField.text = ReceiverConfiguration.localIPv4Addresses().first
        let selectedPreset = WiFiPresetStore.selected()
        ssidField.text = selectedPreset?.ssid ?? UserDefaults.standard.string(forKey: "wifiSSID")
        ssidField.addTarget(self, action: #selector(networkNameChanged), for: .editingChanged)
        ssidField.addTarget(self, action: #selector(loadWiFiPassword), for: .editingDidEnd)
        channelField.text = String(Int(selectedPreset?.channel ?? UInt8(UserDefaults.standard.object(forKey: "wifiChannel") as? Int ?? 36)))
        openNetworkSwitch.isOn = selectedPreset?.isOpen ?? false
        channelField.keyboardType = .numberPad
        channelField.placeholder = "默认 36，一般无需修改"
        bluetoothSetupSwitch.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.selectedSegmentIndex = UIDevice.current.userInterfaceIdiom == .phone ? 1 : 0
        modeControl.isHidden = UIDevice.current.userInterfaceIdiom == .phone
        modeControl.setEnabled(UIDevice.current.userInterfaceIdiom == .phone, forSegmentAt: 1)
        modeControl.setEnabled(UIDevice.current.userInterfaceIdiom == .phone, forSegmentAt: 2)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        connectionHelp.font = .preferredFont(forTextStyle: .body)
        connectionHelp.textColor = .secondaryLabel; connectionHelp.numberOfLines = 0
        receiverPicker.configuration = .bordered(); receiverPicker.showsMenuAsPrimaryAction = true
        let heroIcon = UIImageView(image: UIImage(systemName: "car.side.fill"))
        heroIcon.tintColor = .systemBlue
        heroIcon.contentMode = .scaleAspectFit
        heroIcon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let heroIconHeight = heroIcon.heightAnchor.constraint(equalToConstant: 48)
        heroIconHeight.priority = UILayoutPriority(999)
        heroIconHeight.isActive = true
        let titleStack = UIStackView(arrangedSubviews: [heroIcon, heading])
        titleStack.axis = .horizontal; titleStack.alignment = .center; titleStack.spacing = 14
        heroTitleRow = titleStack
        let statusIcon = UIImageView(image: UIImage(systemName: "circle.fill"))
        statusIcon.tintColor = .systemBlue
        statusIcon.contentMode = .scaleAspectFit
        statusIcon.widthAnchor.constraint(equalToConstant: 9).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 9).isActive = true
        let statusRow = UIStackView(arrangedSubviews: [statusIcon, statusLabel])
        statusRow.axis = .horizontal; statusRow.alignment = .center; statusRow.spacing = 8
        statusRow.isLayoutMarginsRelativeArrangement = true
        statusRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        statusRow.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        statusRow.layer.cornerRadius = 12; statusRow.layer.cornerCurve = .continuous
        startupHint.font = .preferredFont(forTextStyle: .footnote)
        startupHint.textColor = .secondaryLabel
        startupHint.numberOfLines = 0
        startupHint.adjustsFontForContentSizeCategory = true
        startupHint.isHidden = true
        identitySetupButton.configuration = .tinted()
        identitySetupButton.configuration?.title = "配置身份 / 从原版 IPA 导入"
        identitySetupButton.configuration?.image = UIImage(systemName: "key.fill")
        identitySetupButton.configuration?.imagePadding = 8
        identitySetupButton.addAction(UIAction { [weak self] _ in self?.revealSettings(showIdentity: true) }, for: .touchUpInside)
        [titleStack, explanation, statusRow, identitySetupButton, startupHint, connectionHelp, receiverPicker, networkSummary]
            .forEach { heroStack.addArrangedSubview($0) }
        vehicleProfileButton.configuration = .plain()
        vehicleProfileButton.contentHorizontalAlignment = .leading
        vehicleProfileButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.revealSettings()
            self.settingsNavigation?.pushViewController(self.vehicleProfilesPage(), animated: true)
        }, for: .touchUpInside)
        heroStack.addArrangedSubview(vehicleProfileButton)
        heroStack.axis = .vertical; heroStack.spacing = 14
        heroStack.isLayoutMarginsRelativeArrangement = true
        heroStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 22, leading: 20, bottom: 22, trailing: 20)
        heroStack.backgroundColor = .secondarySystemGroupedBackground
        heroStack.layer.cornerRadius = 24; heroStack.layer.cornerCurve = .continuous
        let stack = homeStack
        stack.addArrangedSubview(heroStack)
        configureSettingsControls()
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in self.applyAppearance() }
        }
        applyAppearance()
        refreshVideoOutputSummary()

        startButton.configuration = .filled(); startButton.setTitle("启动本机 CarPlay", for: .normal)
        startButton.addTarget(self, action: #selector(toggleReceiver), for: .touchUpInside)
        startButton.configuration?.cornerStyle = .large
        startButton.configuration?.image = UIImage(systemName: "play.fill")
        startButton.configuration?.imagePadding = 8
        startButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24)
        connectionDetailsButton.configuration = .bordered()
        connectionDetailsButton.setTitle("连接详情", for: .normal)
        connectionDetailsButton.isHidden = true
        connectionDetailsButton.addTarget(self, action: #selector(toggleConnectionDetails), for: .touchUpInside)
        let startupActions = UIStackView(arrangedSubviews: [startButton, connectionDetailsButton])
        startupActions.axis = .horizontal; startupActions.spacing = 10; startupActions.alignment = .fill
        startupActions.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        connectionDetailsButton.setContentHuggingPriority(.required, for: .horizontal)
        connectionDetailsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        heroStack.addArrangedSubview(startupActions)

        let browserIcon = UIImageView(image: UIImage(systemName: "globe"))
        browserIcon.tintColor = .systemGreen; browserIcon.contentMode = .scaleAspectFit
        browserIcon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let browserTitle = UILabel(); browserTitle.text = "局域网浏览器访问"
        browserTitle.font = .preferredFont(forTextStyle: .headline); browserTitle.adjustsFontForContentSizeCategory = true
        let browserHeader = UIStackView(arrangedSubviews: [browserIcon, browserTitle])
        browserHeader.spacing = 8; browserHeader.alignment = .center
        browserURLLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        browserURLLabel.adjustsFontSizeToFitWidth = true; browserURLLabel.minimumScaleFactor = 0.65
        browserURLLabel.textColor = .label
        browserViewersLabel.font = .preferredFont(forTextStyle: .footnote); browserViewersLabel.textColor = .secondaryLabel
        browserViewersLabel.numberOfLines = 0
        browserCopyButton.configuration = .tinted()
        browserCopyButton.configuration?.image = UIImage(systemName: "doc.on.doc")
        browserCopyButton.configuration?.imagePadding = 6
        browserCopyButton.setTitle("复制", for: .normal)
        browserCopyButton.addTarget(self, action: #selector(copyVideoURL), for: .touchUpInside)
        browserCopyButton.setContentHuggingPriority(.required, for: .horizontal)
        browserCopyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let urlRow = UIStackView(arrangedSubviews: [browserURLLabel, browserCopyButton])
        urlRow.spacing = 10; urlRow.alignment = .center
        secureBrowserURLLabel.font = browserURLLabel.font
        secureBrowserURLLabel.adjustsFontSizeToFitWidth = true; secureBrowserURLLabel.minimumScaleFactor = 0.65
        secureBrowserCopyButton.configuration = .tinted()
        secureBrowserCopyButton.configuration?.image = UIImage(systemName: "doc.on.doc")
        secureBrowserCopyButton.configuration?.imagePadding = 6
        secureBrowserCopyButton.setTitle("复制", for: .normal)
        secureBrowserCopyButton.addTarget(self, action: #selector(copySecureVideoURL), for: .touchUpInside)
        secureBrowserCopyButton.setContentHuggingPriority(.required, for: .horizontal)
        secureBrowserCopyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        secureBrowserRow.addArrangedSubview(secureBrowserURLLabel)
        secureBrowserRow.addArrangedSubview(secureBrowserCopyButton)
        secureBrowserRow.spacing = 10; secureBrowserRow.alignment = .center
        var disclosure = UIButton.Configuration.plain()
        disclosure.title = "HTTPS（低延迟）"
        disclosure.imagePlacement = .trailing
        disclosure.imagePadding = 6
        disclosure.contentInsets = .zero
        secureBrowserDisclosure.configuration = disclosure
        secureBrowserDisclosure.contentHorizontalAlignment = .leading
        secureBrowserDisclosure.addTarget(self, action: #selector(toggleHTTPSAddress), for: .touchUpInside)
        func caption(_ text: String) -> UILabel {
            let label = UILabel(); label.text = text
            label.font = .preferredFont(forTextStyle: .caption1); label.textColor = .secondaryLabel
            return label
        }
        browserCard.addArrangedSubview(browserHeader)
        browserCard.addArrangedSubview(caption("兼容模式（HTTP）"))
        browserCard.addArrangedSubview(urlRow)
        browserCard.addArrangedSubview(secureBrowserDisclosure)
        browserCard.addArrangedSubview(secureBrowserRow)
        browserCard.addArrangedSubview(browserViewersLabel)
        configureOutputCard(browserCard)
        stack.addArrangedSubview(browserCard)
        configureConnectionCard(carLifeCard, title: "CarLife 连接", symbol: "car.rear.fill", color: .systemGreen,
            instructions: "让车机和 iPhone 连同一个 Wi-Fi。打开车机上的 CarLife，再启动本机 CarPlay。",
            status: carLifeCardStatus)
        let carLifeSettings = UIButton(type: .system)
        carLifeSettings.configuration = .tinted()
        carLifeSettings.configuration?.title = "连接设置"
        carLifeSettings.addAction(UIAction { [weak self] _ in self?.revealSettings(output: true) }, for: .touchUpInside)
        carLifeCard.addArrangedSubview(carLifeSettings)
        stack.addArrangedSubview(carLifeCard)

        configureConnectionCard(zeehoCard, title: "极核 6.2 寸连接", symbol: "scooter", color: .systemBlue,
            instructions: "让 iPhone 加入极核仪表 Wi-Fi，打开仪表投屏后启动 CarPlay。", status: zeehoCardStatus)
        let zeehoSettings = UIButton(type: .system)
        zeehoSettings.configuration = .tinted()
        zeehoSettings.configuration?.title = "连接设置"
        zeehoSettings.addAction(UIAction { [weak self] _ in self?.revealSettings(output: true) }, for: .touchUpInside)
        zeehoCard.addArrangedSubview(zeehoSettings)
        stack.addArrangedSubview(zeehoCard)
        ninebotCardInstructions = configureConnectionCard(ninebotCard, title: "九号仪表连接", symbol: "scooter", color: .systemBlue,
            instructions: Self.ninebotFiveInstructions, status: ninebotCardStatus)
        let ninebotSettings = UIButton(type: .system)
        ninebotSettings.configuration = .tinted()
        ninebotSettings.configuration?.title = "连接设置"
        ninebotSettings.addAction(UIAction { [weak self] _ in self?.revealSettings(output: true) }, for: .touchUpInside)
        ninebotCard.addArrangedSubview(ninebotSettings)
        stack.addArrangedSubview(ninebotCard)
        configureConnectionCard(tailingCard, title: "台铃 4.3 寸连接", symbol: "scooter", color: .systemOrange,
            instructions: "iPhone 加入仪表的 Wi-Fi，打开仪表投屏，再启动本机 CarPlay。画面在仪表上显示，操作在 iPhone 上完成。",
            status: tailingCardStatus)
        let tailingSettings = UIButton(type: .system)
        tailingSettings.configuration = .tinted()
        tailingSettings.configuration?.title = "连接设置"
        tailingSettings.addAction(UIAction { [weak self] _ in self?.revealSettings(output: true) }, for: .touchUpInside)
        tailingCard.addArrangedSubview(tailingSettings)
        stack.addArrangedSubview(tailingCard)

        configureConnectionCard(airPlayCard, title: "AirPlay 连接", symbol: "airplayvideo", color: .systemBlue,
            instructions: "接收设备与 iPhone 连同一 Wi-Fi。启动 CarPlay 后，可在这里选择设备。",
            status: airPlayCardStatus)
        let routeTitle = UILabel()
        routeTitle.text = "选择 AirPlay 设备"
        routeTitle.font = .preferredFont(forTextStyle: .body)
        routeTitle.adjustsFontForContentSizeCategory = true
        routeTitle.numberOfLines = 0
        airPlayRoutePicker.prioritizesVideoDevices = true
        airPlayRoutePicker.tintColor = .systemBlue
        airPlayRoutePicker.activeTintColor = .systemGreen
        airPlayRoutePicker.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        airPlayRoutePicker.layer.cornerRadius = 14
        airPlayRoutePicker.accessibilityLabel = routeTitle.text
        routeTitle.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            airPlayRoutePicker.widthAnchor.constraint(equalToConstant: 44),
            airPlayRoutePicker.heightAnchor.constraint(equalToConstant: 44)
        ])
        let routeRow = UIStackView(arrangedSubviews: [routeTitle, airPlayRoutePicker])
        routeRow.alignment = .center
        routeRow.spacing = 8
        airPlayCard.addArrangedSubview(routeRow)
        airPlayRetryButton.configuration = .tinted()
        airPlayRetryButton.configuration?.title = "重试 AirPlay"
        airPlayRetryButton.addAction(UIAction { [weak self] _ in self?.startAirPlayTransport() }, for: .touchUpInside)
        airPlayRetryButton.isHidden = true
        airPlayCard.addArrangedSubview(airPlayRetryButton)
        stack.addArrangedSubview(airPlayCard)

        inlineVideoContainer.isHidden = true
        inlineVideoContainer.clipsToBounds = true
        inlineVideoContainer.layer.cornerRadius = 20
        inlineVideoContainer.layer.cornerCurve = .continuous
        videoSurface.translatesAutoresizingMaskIntoConstraints = false
        restoreInlineVideoSurface()
        videoHeight = inlineVideoContainer.heightAnchor.constraint(equalTo: inlineVideoContainer.widthAnchor,
                                                                    multiplier: displayAspectHeight)
        videoHeight.priority = .defaultLow
        videoHeight.isActive = true
        stack.addArrangedSubview(inlineVideoContainer)
        videoActions.addArrangedSubview(fullscreenButton)
        videoActions.addArrangedSubview(pictureInPictureButton)
        videoActions.axis = .horizontal; videoActions.distribution = .fillEqually; videoActions.spacing = 10
        fullscreenButton.configuration = .borderedProminent()
        fullscreenButton.setTitle("全屏显示", for: .normal)
        fullscreenButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
        fullscreenButton.addTarget(self, action: #selector(showFullscreen), for: .touchUpInside)
        pictureInPictureButton.configuration = .bordered()
        pictureInPictureButton.setTitle("画中画", for: .normal)
        pictureInPictureButton.setImage(UIImage(systemName: "pip.enter"), for: .normal)
        pictureInPictureButton.addTarget(self, action: #selector(startPictureInPicture), for: .touchUpInside)
        videoActions.isHidden = true
        fullscreenButton.isHidden = false; pictureInPictureButton.isHidden = false
        videoActions.tag = 8801
        stack.addArrangedSubview(videoActions)
        Self.barControls.forEach { controlBar.addArrangedSubview(makeControlButton($0)) }
        controlBar.axis = .horizontal; controlBar.distribution = .fillEqually; controlBar.spacing = 8
        controlBar.isHidden = true
        stack.addArrangedSubview(controlBar)
        logView.isEditable = false; logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.backgroundColor = .secondarySystemBackground; logView.layer.cornerRadius = 12
        logView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        transportProbeButton.addTarget(self, action: #selector(testSameDeviceTransport), for: .touchUpInside)
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = homeScroll; scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        scroll.panGestureRecognizer.require(toFail: videoSurface.touchOwnershipGestureRecognizer)
        view.addSubview(scroll); scroll.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
        preferredWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            preferredWidth, stack.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720)
        ])
        receiver.onLog = { [weak self] in self?.lastReceiverMessage = $0; self?.log($0) }
        bluetooth.onLog = { [weak self] in self?.log($0) }
        receiver.onControlConnected = { [weak self] in
            self?.recordConnection(.control, "已收到 CarPlay 控制请求")
            self?.sameDevice.didConnectControl()
        }
        receiver.onConnectionProgress = { [weak self] in self?.sameDevice.didProgressControl($0) }
        receiver.onFirstVideo = { [weak self] in
            self?.recordConnection(.video, "已收到视频关键帧")
            self?.sameDevice.didReceiveVideo()
        }
        receiver.onVideo = { [weak self] data, codec in
            guard let self, self.running else { return }
            // Nothing local is visible in the background without PiP: save the decoding work.
            // The browser output is fed before this callback and keeps running.
            if UIApplication.shared.applicationState == .background, !self.pictureInPicture.canKeepSessionInBackground {
                self.skippedLocalVideo = true; return
            }
            do {
                let acceptedPicture = try self.videoSurface.enqueue(accessUnit: data, codec: codec)
                if acceptedPicture, !self.displayedVideo {
                    self.inlineVideoContainer.isHidden = false
                    self.displayedVideo = true; self.statusLabel.text = "正在显示 CarPlay"
                    self.clearStartupHint()
                    self.networkStartupTask?.cancel()
                    self.networkStartupTask = nil
                    self.videoActions.isHidden = false; self.controlBar.isHidden = false
                    self.refreshHomePresentation()
                    self.view.layoutIfNeeded()
                    self.homeScroll.setContentOffset(CGPoint(x: 0, y: -self.homeScroll.adjustedContentInset.top), animated: false)
                    self.log("视频已送入本机显示层")
                    if UIDevice.current.userInterfaceIdiom == .pad || self.autoFullscreenSwitch.isOn { self.showFullscreen() }
                    self.updatePictureInPicturePolicy()
                }
                self.pictureInPicture.sourceMayBeReady()
            } catch {
                self.statusLabel.text = "视频显示异常"
                self.log("视频显示失败：\(error.localizedDescription)")
            }
        }
        videoSurface.onLog = { [weak self] in self?.log($0) }
        videoSurface.onKeyframeNeeded = { [weak self] reason in
            guard let self else { return }
            // In the background without PiP nothing is drawn locally; asking for keyframes then
            // would only bloat the browser stream with repeated IDRs.
            guard UIApplication.shared.applicationState != .background || self.pictureInPicture.canKeepSessionInBackground else { return }
            self.receiver.requestKeyFrame(reason: reason)
        }
        videoSurface.onTouches = { [weak self] points in
            self?.receiver.touches(source: "local", points)
            self?.refreshFullscreenExitButton()
        }
        receiver.onZeehoState = { [weak self] message in
            guard let self, self.running, self.outputMode == .zeeho else { return }
            self.updateZeehoStatus(message)
        }
        receiver.onNinebotState = { [weak self] message in
            guard let self, self.running, self.outputMode.ninebotMode != nil else { return }
            self.recordConnection(.instrument, message)
            self.updateNinebotStatus(message)
        }
        receiver.onTailingState = { [weak self] message in
            guard let self, self.running, self.outputMode == .tailing else { return }
            self.updateTailingStatus(message)
        }
        receiver.onCarLifeState = { [weak self] message in
            guard let self, self.running, self.outputMode == .carLife else { return }
            self.updateCarLifeStatus(message)
        }
        receiver.onBrowserDisplay = { [weak self] display, viewerID in self?.browserReportedDisplay(display, viewerID: viewerID) }
        receiver.onBrowserStruggling = { [weak self] peer, reason in self?.browserStruggling(peer: peer, reason: reason) }
        receiver.onCarUIRequested = { [weak self] in
            guard let self else { return }
            self.log("在 CarPlay 中点按了 CarWithin 车辆按钮")
            self.hideFullscreen(); self.revealSettings()
        }
        receiver.onAirPlayReady = { [weak self] id in
            guard let self, self.airPlayStreamID == id else { return }
            self.airPlayReady = true
            self.startAirPlayTransport()
        }
        receiver.onVideoOutputState = { [weak self] message in
            self?.portStatus.text = message
            self?.browserViewersLabel.text = message
            if let self, self.outputMode == .airPlay, self.running, !self.airPlayReady { self.updateAirPlayStatus(message) }
        }
        pictureInPicture.onLog = { [weak self] in self?.log($0) }
        pictureInPicture.onFailure = { [weak self] in
            guard let self, self.running else { return }
            if UIApplication.shared.applicationState == .background {
                if !self.keepAlive.isRunning { self.stop() }
            } else {
                self.statusLabel.text = "画中画未开启，可点「画中画」重试"
            }
        }
        pictureInPicture.onStopped = { [weak self] in
            guard let self, self.running else { return }
            if UIApplication.shared.applicationState == .background {
                if !self.keepAlive.isRunning { self.stop() }
            } else {
                self.resumeLocalVideo()
            }
        }
        keepAlive.onLog = { [weak self] in self?.log($0) }
        pictureInPicture.onRestore = { [weak self] in
            self?.hideFullscreen()
        }
        receiver.onFailure = { [weak self] in
            self?.recordConnection(.failed, self?.lastReceiverMessage ?? "接收服务失败，具体错误见运行日志")
            self?.stop()
        }
        bluetooth.onFailure = { [weak self] message in
            self?.stop()
            self?.statusLabel.text = message
        }
        bluetooth.onAdvertising = { [weak self] in
            guard let self, self.running else { return }
            self.statusLabel.text = "蓝牙广播已开启，正在等待 iPhone"
        }
        controlBrowser.onLog = { [weak self] in self?.log($0) }
        receiverBrowser.onLog = { [weak self] in self?.log($0) }
        receiverBrowser.onTargets = { [weak self] targets in
            guard let self, !self.running, self.modeControl.selectedSegmentIndex == 2 else { return }
            if let selected = self.remoteTarget, !targets.contains(selected) { self.remoteTarget = nil }
            self.receiverPicker.isEnabled = !targets.isEmpty
            self.receiverPicker.setTitle(self.remoteTarget.map { "\($0.name) · \($0.address)" }
                ?? (targets.isEmpty ? "正在搜索 iPad 接收端…" : "选择 iPad 接收端"), for: .normal)
            self.receiverPicker.menu = UIMenu(children: targets.map { target in
                UIAction(title: target.name, subtitle: "\(target.address):\(target.port)") { [weak self] _ in
                    self?.remoteTarget = target
                    self?.receiverPicker.setTitle("\(target.name) · \(target.address)", for: .normal)
                }
            })
        }
        sameDevice.onStage = { [weak self] message in
            guard let self, self.running, !self.displayedVideo else { return }
            let stage: ConnectionTimeline.Stage = message.contains("控制") || message.contains("媒体")
                || message.contains("认证响应") || message.contains("首帧") ? .control : .accessory
            self.recordConnection(stage, message)
            if self.modeControl.selectedSegmentIndex == 2 {
                self.statusLabel.text = message.contains("已请求")
                    ? "已请求连接，请保持 App 运行" : "正在连接 iPad…"
            } else {
                self.statusLabel.text = message
                self.scheduleStartupHint()
            }
        }
        sameDevice.onLog = { [weak self] in self?.log($0) }
        sameDevice.onFinished = { [weak self] message in
            self?.recordConnection(.failed, message)
            self?.stop()
            self?.statusLabel.text = message
        }
        #if DEBUG
        // Clears screens recorded by automated tests with a simulated browser.
        if ProcessInfo.processInfo.arguments.contains("--reset-car-screens") {
            CarScreenStore.screens().forEach { CarScreenStore.remove($0.key) }
            refreshScreenMenu()
        }
        #endif
        wifiPathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshNetworkAddresses() }
        }
        wifiPathMonitor.start(queue: DispatchQueue(label: "CarWithin.wifiPath"))
        ninebotAutoConnectSwitch.isOn = UserDefaults.standard.bool(forKey: "ninebotAutoConnect")
        ninebotAutoConnectSwitch.addTarget(self, action: #selector(ninebotAutoConnectChanged), for: .valueChanged)
        ninebotCurrentWiFiSwitch.isOn = UserDefaults.standard.bool(forKey: "ninebotCurrentWiFi")
        ninebotCurrentWiFiSwitch.addTarget(self, action: #selector(ninebotCurrentWiFiChanged), for: .valueChanged)
        configureBMS()
        configureExperience()
        loadIdentity()
        loadWiFiPassword()
        modeChanged()
        #if targetEnvironment(macCatalyst)
        log("正在 Mac Catalyst 上运行原生 UIKit 接收端")
        #elseif targetEnvironment(simulator)
        log("模拟器无法验证蓝牙和 CoreAccessories 真机能力")
        #else
        log("正在 iPhone/iPad 真机上运行")
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foregrounded), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(airPlayAudioRouteChanged),
            name: AVAudioSession.routeChangeNotification, object: nil)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkForUpdates(manual: false)
        }
    }
    deinit {
        wiFiJoinTask?.cancel()
        wiFiJoinTimeoutTask?.cancel()
        wifiPathMonitor.cancel()
        networkStartupTask?.cancel()
    }

    /// Presets are listed on their own settings page; refresh it if it is open.
    private func refreshWiFiPresetMenu() { reloadVisibleSettings() }

    private func configureBMS() {
        bmsEnabledSwitch.isOn = UserDefaults.standard.bool(forKey: "antBMSEnabled")
        bmsEnabledSwitch.addTarget(self, action: #selector(bmsSettingsChanged), for: .valueChanged)
        bmsPosition.addTarget(self, action: #selector(bmsCardAppearanceChanged), for: .valueChanged)
        bmsCardBackground.addTarget(self, action: #selector(bmsCardAppearanceChanged), for: .valueChanged)
        bmsCardConfiguration = ANTBMSCardConfiguration(
            savedFields: UserDefaults.standard.stringArray(forKey: "antBMSCardFields"),
            sizeRawValue: UserDefaults.standard.object(forKey: "antBMSCardSize") as? Int,
            positionRawValue: UserDefaults.standard.object(forKey: "antBMSPosition") as? Int,
            backgroundRawValue: UserDefaults.standard.object(forKey: "antBMSCardBackground") as? Int)
        bmsCardSize.selectedSegmentIndex = bmsCardConfiguration.size.rawValue
        bmsPosition.selectedSegmentIndex = bmsCardConfiguration.position.rawValue
        bmsCardBackground.selectedSegmentIndex = bmsCardConfiguration.background.rawValue
        bmsCardSize.addTarget(self, action: #selector(bmsCardSizeChanged), for: .valueChanged)
        for field in ANTBMSCardConfiguration.Field.allCases {
            let control = UISwitch()
            control.isOn = bmsCardConfiguration.fields.contains(field)
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                guard self.bmsCardConfiguration.set(field, visible: control.isOn) else {
                    control.setOn(true, animated: true)
                    self.alert("至少显示一项", "如需隐藏整张卡片，请关闭「读取并显示 BMS」。")
                    return
                }
                self.saveBMSCardConfiguration()
            }, for: .valueChanged)
            bmsFieldSwitches[field] = control
        }
        bmsDetails.numberOfLines = 0
        bmsDetails.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        bmsOverlay.attach(to: videoSurface)
        bmsOverlay.onImage = { [weak self] image, configuration in
            self?.receiver.setBMSOverlay(image, configuration: configuration)
        }
        bmsClient.onLog = { [weak self] message in self?.log("BMS：" + message) }
        bmsClient.onChange = { [weak self] in self?.refreshBMS() }
        if bmsEnabledSwitch.isOn { bmsClient.start() }
        refreshBMS()
    }

    @objc private func bmsSettingsChanged() {
        let wasEnabled = UserDefaults.standard.bool(forKey: "antBMSEnabled")
        UserDefaults.standard.set(bmsEnabledSwitch.isOn, forKey: "antBMSEnabled")
        UserDefaults.standard.set(bmsPosition.selectedSegmentIndex, forKey: "antBMSPosition")
        if bmsEnabledSwitch.isOn {
            bmsClient.start()
            if running, !wasEnabled { beginBMSSessionIfNeeded() }
        } else { finishBMSSession(); bmsClient.stop() }
        saveActiveVehicleProfile()
        refreshBMS()
        reloadVisibleSettings()
    }

    @objc private func bmsCardSizeChanged() {
        bmsCardConfiguration.size = ANTBMSCardConfiguration.Size(rawValue: bmsCardSize.selectedSegmentIndex) ?? .medium
        saveBMSCardConfiguration()
    }

    @objc private func bmsCardAppearanceChanged() {
        bmsCardConfiguration.position = ANTBMSCardConfiguration.Position(rawValue: bmsPosition.selectedSegmentIndex) ?? .topRight
        bmsCardConfiguration.background = ANTBMSCardConfiguration.Background(rawValue: bmsCardBackground.selectedSegmentIndex) ?? .standard
        saveBMSCardConfiguration()
    }

    private func saveBMSCardConfiguration() {
        UserDefaults.standard.set(bmsCardConfiguration.fields.map(\.rawValue), forKey: "antBMSCardFields")
        UserDefaults.standard.set(bmsCardConfiguration.size.rawValue, forKey: "antBMSCardSize")
        UserDefaults.standard.set(bmsCardConfiguration.position.rawValue, forKey: "antBMSPosition")
        UserDefaults.standard.set(bmsCardConfiguration.background.rawValue, forKey: "antBMSCardBackground")
        saveActiveVehicleProfile()
        refreshBMS()
        reloadVisibleSettings()
    }

    private func applyBMSCardPreset(_ fields: [ANTBMSCardConfiguration.Field]) {
        bmsCardConfiguration = ANTBMSCardConfiguration(savedFields: fields.map(\.rawValue),
            sizeRawValue: bmsCardConfiguration.size.rawValue,
            positionRawValue: bmsCardConfiguration.position.rawValue,
            backgroundRawValue: bmsCardConfiguration.background.rawValue)
        for (field, control) in bmsFieldSwitches { control.isOn = bmsCardConfiguration.fields.contains(field) }
        saveBMSCardConfiguration()
    }

    private func refreshBMS() {
        let reading = bmsClient.freshReading
        if bmsSessionStartedAt != nil, bmsSessionDevice != bmsClient.selectedID {
            finishBMSSession()
            if running, bmsEnabledSwitch.isOn { beginBMSSessionIfNeeded() }
        }
        if bmsSessionStartedAt != nil, let sample = bmsClient.sample, sample.uptime >= bmsSessionMinimumUptime,
           bmsSession.append(sample, now: ProcessInfo.processInfo.systemUptime) {
            bmsTrend.points = bmsSession.points
            if sample.uptime - lastBMSSaveUptime >= 15 {
                checkpointBMSSession(completed: false)
                lastBMSSaveUptime = sample.uptime
                reloadVisibleSettings()
            }
        }
        bmsSessionStatus.text = bmsStatisticsText(bmsSession)
        bmsStatus.text = bmsEnabledSwitch.isOn ? bmsClient.status : "BMS 显示已关闭"
        bmsLiveSummary.update(reading)
        if let reading {
            let temperature = reading.maximumTemperature.map { String(format: "%.0f°C", $0) } ?? "--"
            let mos = reading.mosTemperature.map { String(format: "%.0f°C", $0) } ?? "--"
            let delta = reading.cellDelta.map { String(format: "%.0f mV", $0 * 1000) } ?? "--"
            let states = [0: "无状态", 1: "静止", 2: "充电", 3: "待机", 4: "放电", 5: "异常"]
            bmsDetails.text = String(format: "电量 %d%% · %.2f V · %+.1f A · %d W\n剩余 %.2f / %.2f Ah\n最高温度 %@ · MOS %@\n%d 串 · 单体压差 %@\n状态：%@\n保护位：0x%llX · 告警位：0x%llX",
                reading.stateOfCharge, reading.voltage, reading.current, reading.power,
                reading.remainingAh, reading.capacityAh, temperature, mos, reading.cells.count, delta,
                states[reading.stateCode] ?? "未知", reading.protectionBits, reading.alarmBits)
        } else {
            bmsDetails.text = "电量 -- · 电压 -- · 电流 -- · 功率 --\n等待校验有效的 ANT 实时数据。"
        }
        bmsOverlay.update(enabled: bmsEnabledSwitch.isOn, reading: reading, status: bmsClient.status,
                          configuration: bmsCardConfiguration)
        bmsCardPreview.update(reading: reading, configuration: bmsCardConfiguration,
                             aspectRatio: outputMode == .ninebotSeven ? 1024 / 600 : 848 / 480)
        bmsCardPreviewStatus.text = reading == nil ? "示例数据 · 当前没有实时读数" : "实时数据 · 当前连接的 ANT BMS"
        let ids = bmsClient.devices.map(\.id)
        if ids != bmsDeviceList {
            bmsDeviceList = ids
            reloadVisibleSettings()
        }
    }
    private func applyWiFiPreset(_ preset: WiFiPreset) {
        WiFiPresetStore.select(preset.ssid)
        ssidField.text = preset.ssid
        channelField.text = String(preset.channel)
        openNetworkSwitch.isOn = preset.isOpen
        passwordField.text = ""
        passwordLoadedForSSID = nil
        loadWiFiPassword()
        refreshWiFiPresetMenu(); refreshNetworkSummary()
    }
    private func saveCurrentWiFiPreset() -> Bool {
        let ssid = ssidField.text ?? ""
        let channelText = channelField.text ?? ""
        let channel = channelText.isEmpty ? UInt8(36) : UInt8(channelText)
        guard !ssid.isEmpty, ssid.utf8.count <= 32, !ssid.contains("\0"), let channel, (1...196).contains(channel) else {
            passwordStatus.text = "请输入有效的 Wi-Fi 名称和 1–196 的兼容信道。"; return false
        }
        let password = openNetworkSwitch.isOn ? "" : (passwordField.text ?? "")
        let credentials = enteredWiFiCredentials
        let canSaveWithoutPassword = prefersCurrentWiFiStartup && !openNetworkSwitch.isOn && password.isEmpty
        guard credentials != nil || canSaveWithoutPassword else {
            passwordStatus.text = "Wi-Fi 密码需要 8–63 字节。"; return false
        }
        do {
            // A remembered SSID without credentials must not overwrite an existing
            // Keychain password or be marked as an open network.
            if credentials != nil { try WiFiCredentials.save(password, for: ssid) }
            WiFiPresetStore.upsert(ssid: ssid, channel: channel, isOpen: openNetworkSwitch.isOn)
            passwordStatus.text = credentials == nil
                ? "已记住 Wi-Fi 名称“\(ssid)”，仅用于当前连接实验"
                : "已保存 Wi-Fi 预设“\(ssid)”"
            refreshWiFiPresetMenu()
            return true
        } catch { passwordStatus.text = "保存 Wi-Fi 预设失败：\(error.localizedDescription)"; return false }
    }
    @objc private func displaySettingChanged() {
        guard !running else { return }
        saveDisplaySettings()
        updateVideoAspect()
        reloadVisibleSettings()
    }
    private func saveDisplaySettings() {
        let defaults = UserDefaults.standard
        defaults.set(resolutionControl.selectedSegmentIndex, forKey: "displayResolutionIndex")
        defaults.set(aspectRatioControl.selectedTitle, forKey: "displayAspectRatio")
        defaults.set([0, 30, 60][max(0, frameRateControl.selectedSegmentIndex)], forKey: "displayMaxFPS")
        defaults.set(["auto", "h264", "h265"][max(0, codecControl.selectedSegmentIndex)], forKey: "videoCodec")
        defaults.set(sizeModeControl.selectedSegmentIndex, forKey: "displaySizeMode")
        defaults.set(ReceiverConfiguration.iconSizes[max(0, iconSizeControl.selectedSegmentIndex)].widthMM, forKey: "widthPhysicalMM")
        defaults.set(selectedPerformance.rawValue, forKey: "browserPerformance")
        defaults.set(autoRestartSwitch.isOn, forKey: "autoRestart")
        defaults.set(showTouchesSwitch.isOn, forKey: "showTouches")
        defaults.set(carButtonSwitch.isOn, forKey: "carButton")
    }
    private var selectedPerformance: BrowserPerformance { BrowserPerformance.allCases[max(0, performanceControl.selectedSegmentIndex)] }
    private var followsCarScreen: Bool { sizeModeControl.selectedSegmentIndex == 0 }
    /// The screen "跟随车机" sizes for: reported in this run, else the ticked or latest saved one.
    private var targetScreen: CarScreen? { outputMode == .browser ? reportedScreen ?? CarScreenStore.preferred() : nil }

    /// Size, frame rate and codec for the next session from the settings, the known head-unit
    /// screen and any lighter level chosen by "自动重启".
    private func planDisplay(for screen: CarScreen?) -> DisplayPlan {
        if outputMode == .zeeho {
            let icon = ReceiverConfiguration.iconSizes[max(0, iconSizeControl.selectedSegmentIndex)].widthMM
            return DisplayPlan(width: 1024, height: 480, fps: 30, codec: .h264, iconWidthMM: icon)
        }
        if let mode = outputMode.ninebotMode {
            let icon = ReceiverConfiguration.iconSizes[max(0, iconSizeControl.selectedSegmentIndex)].widthMM
            let dimensions: (Int, Int)
            switch mode {
            case .fiveInch: dimensions = (NinebotOutput.width, NinebotOutput.height)
            case .sevenInch: dimensions = (NinebotOutput.sevenInchFormat.width, NinebotOutput.sevenInchFormat.height)
            case .fourThreeInch: dimensions = (NinebotOutput.fourThreeFormat.width * 2, NinebotOutput.fourThreeFormat.height * 2)
            }
            // CarPlay advertises at least 30 FPS. NinebotOutput limits the instrument independently.
            return DisplayPlan(width: dimensions.0, height: dimensions.1, fps: 30, codec: .h264, iconWidthMM: icon)
        }
        if outputMode == .tailing {
            // CarPlay requires at least 320 per side; render 2× the instrument then downsample.
            let icon = ReceiverConfiguration.iconSizes[max(0, iconSizeControl.selectedSegmentIndex)].widthMM
            return DisplayPlan(width: 960, height: 544, fps: 30, codec: .h264, iconWidthMM: icon)
        }
        let cap = selectedResolution()
        let portrait = UIDevice.current.userInterfaceIdiom == .pad && orientationControl.selectedSegmentIndex == 1
        var width = portrait ? cap.height : cap.width, height = portrait ? cap.width : cap.height
        var capArea = cap.width * cap.height
        if lightLevel >= 2 { capArea = min(capArea, 1280 * 720) }
        // CarLife head units decode H.264 up to 1080p and usually ask for 30 FPS.
        if outputMode != .browser { capArea = min(capArea, 1920 * 1080) }
        if followsCarScreen, let screen {
            width = screen.width; height = screen.height
        }
        // Scale down, keeping the aspect ratio, to the chosen maximum area and 3840 per side.
        var scale = min(1, (Double(capArea) / Double(width * height)).squareRoot(), 3840 / Double(max(width, height)))
        if outputMode != .browser {
            scale = min(scale, 1920 / Double(width), 1080 / Double(height))
        }
        width = max(320, Int(Double(width) * scale) / 2 * 2); height = max(320, Int(Double(height) * scale) / 2 * 2)
        if !followsCarScreen, let ratio = selectedAspectRatio {
            (width, height) = ReceiverConfiguration.fixedDisplaySize(area: capArea, ratio: ratio,
                maxWidth: outputMode == .browser ? 3840 : 1920,
                maxHeight: outputMode == .browser ? 3840 : 1080)
        }
        var fps: Int
        switch frameRateControl.selectedSegmentIndex {
        case 1: fps = 30
        case 2: fps = 60
        default: fps = screen.map { (1..<45).contains($0.refreshHz) ? 30 : 60 } ?? 60
        }
        if lightLevel >= 1 { fps = min(fps, 30) }
        if outputMode != .browser { fps = min(fps, 30) }
        var codec: VideoCodec
        switch codecControl.selectedSegmentIndex {
        case 1: codec = .h264
        case 2: codec = .h265
        default: codec = screen?.supportsH265 == true ? .h265 : .h264
        }
        if outputMode != .browser { codec = .h264 }
        let defaultIconWidth = ReceiverConfiguration.iconSizes[max(0, iconSizeControl.selectedSegmentIndex)].widthMM
        let iconWidth = followsCarScreen ? screen?.iconWidthMM ?? defaultIconWidth : defaultIconWidth
        return DisplayPlan(width: width, height: height, fps: fps, codec: codec, iconWidthMM: iconWidth)
    }
    private func refreshScreenMenu() { reloadVisibleSettings() }
    private var selectedAspectRatio: ReceiverConfiguration.AspectRatio? {
        ReceiverConfiguration.aspectRatios.first { $0.title == aspectRatioControl.selectedTitle }
    }
    private func selectedResolution() -> (width: Int, height: Int) {
        let options = ReceiverConfiguration.resolutions
        let index = resolutionControl.selectedSegmentIndex
        let option = options.indices.contains(index) ? options[index] : options[ReceiverConfiguration.defaultResolutionIndex]
        return (option.width, option.height)
    }
    private func reloadVisibleSettings() {
        (settingsNavigation?.topViewController as? SettingsPageController)?.reload()
    }
    private func updateVideoAspect() {
        guard videoHeight != nil else { return }
        let plan = running ? (liveDisplay ?? planDisplay(for: targetScreen)) : planDisplay(for: targetScreen)
        let width = plan.width, height = plan.height
        videoHeight.isActive = false
        videoHeight = inlineVideoContainer.heightAnchor.constraint(equalTo: inlineVideoContainer.widthAnchor,
                                                           multiplier: CGFloat(height) / CGFloat(width))
        videoHeight.priority = .defaultLow
        videoHeight.isActive = true
    }
    @objc private func keepAliveChanged() {
        UserDefaults.standard.set(keepAliveSwitch.isOn, forKey: "backgroundKeepAlive")
        if !keepAliveSwitch.isOn { keepAlive.stop() }
        else if running, UIApplication.shared.applicationState == .active { keepAlive.start() }
    }
    @objc private func appearanceChanged() {
        UserDefaults.standard.set(appearanceControl.selectedSegmentIndex, forKey: "carPlayAppearance")
        applyAppearance()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #unavailable(iOS 17.0) { applyAppearance() }
    }
    /// Sends the wanted day/night state; the receiver keeps it for the next session too.
    private func applyAppearance() {
        // iOS flips light/dark while taking the app-switcher snapshot; ignore changes off screen.
        guard UIApplication.shared.applicationState != .background else { return }
        let choice = ReceiverConfiguration.Appearance(rawValue: appearanceControl.selectedSegmentIndex) ?? .system
        let night: Bool
        switch choice {
        case .system: night = traitCollection.userInterfaceStyle == .dark
        case .light: night = false
        case .dark: night = true
        }
        receiver.setNightMode(night)
    }
    private func makeControlButton(_ control: CarPlayControl) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.image = UIImage(systemName: control.symbol)
        configuration.cornerStyle = .capsule
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.receiver.press(control)
        })
        button.accessibilityLabel = control.title
        button.showsLargeContentViewer = true; button.largeContentTitle = control.title
        return button
    }
    /// The keys worth a button on a touch screen; knob up/down/select stay on keyboards.
    private static let barControls: [CarPlayControl] = [.home, .back, .siri, .previous, .playPause, .next, .hookSwitch]
    @objc private func videoOutputSettingChanged() {
        guard !running else { return }
        refreshVideoOutputSummary()
        (settingsNavigation?.topViewController as? SettingsPageController)?.refreshDetails()
    }
    @objc private func saveBrowserPorts() {
        guard !running, let browserPort else { return }
        let defaults = UserDefaults.standard
        if outputMode == .airPlay {
            defaults.set(Int(browserPort), forKey: "videoOutputPort")
            return
        }
        guard browserPortError == nil else { return }
        defaults.set(Int(browserPort), forKey: "videoOutputPort")
        if secureVideoOutputPortField.text?.isEmpty == false, let secureBrowserPort {
            defaults.set(Int(secureBrowserPort), forKey: "secureVideoOutputPort")
        } else {
            defaults.removeObject(forKey: "secureVideoOutputPort")
        }
    }
    @objc private func videoOutputToggled() {
        guard !running else { return }
        UserDefaults.standard.set(videoOutputSwitch.isOn, forKey: "videoOutputEnabled")
        refreshVideoOutputSummary()
        reloadVisibleSettings()
    }
    private var browserAddress: String? {
        ReceiverConfiguration.wifiIPv4Address()
            ?? (UIDevice.current.userInterfaceIdiom == .phone ? nil : ReceiverConfiguration.localIPv4Addresses().first)
    }
    private func portNumber(_ text: String?) -> UInt16? {
        guard let text, let port = UInt16(text), port > 0 else { return nil }
        return port
    }
    private var browserPort: UInt16? { portNumber(videoOutputPortField.text) }
    private var defaultSecurePort: UInt16 {
        guard let browserPort, browserPort < UInt16.max else { return 9889 }
        return browserPort + 1
    }
    private var secureBrowserPort: UInt16? {
        if secureVideoOutputPortField.text?.isEmpty != false { return defaultSecurePort }
        return portNumber(secureVideoOutputPortField.text)
    }
    private var browserPortError: String? {
        guard let browserPort else { return "HTTP 端口请输入 1–65535。" }
        guard let secureBrowserPort else { return "HTTPS 端口请输入 1–65535，或留空使用默认值。" }
        guard browserPort != secureBrowserPort else { return "HTTP 和 HTTPS 端口不能相同。" }
        return nil
    }
    private var browserURL: String? {
        guard let address = browserAddress, let browserPort else { return nil }
        return "http://\(address):\(browserPort)"
    }
    private var localBrowserURL: URL? {
        browserPort.flatMap { URL(string: "http://127.0.0.1:\($0)/") }
    }
    private var secureBrowserURL: String? {
        guard let address = browserAddress, let port = secureBrowserPort, port != browserPort else { return nil }
        guard let host = HTTPSConfiguration.host(address: address) else { return nil }
        return "https://\(host):\(port)"
    }
    private func configureOutputCard(_ card: UIStackView) {
        card.axis = .vertical
        card.spacing = 10
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
    }

    @discardableResult
    private func configureConnectionCard(_ card: UIStackView, title: String, symbol: String, color: UIColor,
                                         instructions: String, status: UILabel) -> UILabel {
        configureOutputCard(card)
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = color
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        let header = UIStackView(arrangedSubviews: [icon, titleLabel])
        header.spacing = 8; header.alignment = .center
        let help = UILabel()
        help.text = instructions
        help.font = .preferredFont(forTextStyle: .subheadline)
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        for label in [help, status] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        card.addArrangedSubview(header)
        card.addArrangedSubview(help)
        card.addArrangedSubview(status)
        return help
    }

    private func refreshBrowserAddressLabels() {
        browserURLLabel.text = browserURL ?? (browserPort == nil ? "HTTP 端口无效" : "未连接 Wi-Fi")
        browserCopyButton.isEnabled = browserURL != nil
        secureBrowserURLLabel.text = secureBrowserURL ?? (browserPortError == nil ? "未连接 Wi-Fi" : "请检查 HTTPS 端口")
        secureBrowserCopyButton.isEnabled = secureBrowserURL != nil
    }

    private func refreshVideoOutputSummary() {
        videoOutputSwitch.isEnabled = !running && outputMode == .browser
        videoOutputPortField.isEnabled = !running && outputMode == .browser && videoOutputSwitch.isOn
        secureVideoOutputPortField.isEnabled = videoOutputPortField.isEnabled
        if outputMode == .airPlay {
            videoOutputPortField.isEnabled = !running
            if !running {
                updateAirPlayStatus(browserPort == nil ? "播放端口请输入 1–65535。" : "等待启动 CarPlay。")
            }
        }
        secureVideoOutputPortField.placeholder = String(defaultSecurePort)
        portStatus.text = browserPortError ?? (running ? "停止 CarPlay 后可修改端口。" : "启动 CarPlay 后即可打开上方地址。")
        let showsLocalOutput = modeControl.selectedSegmentIndex != 2
        zeehoCard.isHidden = !showsLocalOutput || outputMode != .zeeho
        if !running { updateZeehoStatus("等待启动 CarPlay · 仪表 IP：\(zeehoAddressField.text ?? "192.168.0.1")") }
        ninebotCard.isHidden = !showsLocalOutput || outputMode.ninebotMode == nil
        ninebotCardInstructions?.text = ninebotInstructions
        if !running { updateNinebotStatus("等待启动 CarPlay · 仪表 IP：\(activeNinebotAddressField.text ?? "")") }
        tailingCard.isHidden = !showsLocalOutput || outputMode != .tailing
        if !running { updateTailingStatus("等待启动 CarPlay · 仪表 IP：\(tailingAddressField.text ?? "192.168.1.1")") }
        carLifeCard.isHidden = !showsLocalOutput || outputMode != .carLife
        airPlayCard.isHidden = !showsLocalOutput || outputMode != .airPlay
        browserCard.isHidden = outputMode != .browser || !videoOutputSwitch.isOn
        refreshHomePresentation()
        guard outputMode == .browser, videoOutputSwitch.isOn else { return }
        refreshBrowserAddressLabels()
        secureBrowserDisclosure.configuration?.image = UIImage(systemName: httpsExpanded ? "chevron.up" : "chevron.down")
        secureBrowserDisclosure.accessibilityValue = httpsExpanded ? "已展开" : "已折叠"
        secureBrowserRow.isHidden = !httpsExpanded
        if !running {
            browserViewersLabel.text = "启动后最多 \(VideoOutputServer.maximumViewers) 台同时观看。"
        }
    }

    @objc private func toggleConnectionDetails() {
        showsConnectionDetails.toggle()
        refreshHomePresentation()
    }

    private func refreshHomePresentation() {
        let compact = displayedVideo && !showsConnectionDetails
        heroTitleRow?.isHidden = compact
        vehicleProfileButton.isHidden = compact
        vehicleProfileButton.isEnabled = !running && !waitingForNetwork
        explanation.isHidden = compact
        connectionHelp.isHidden = compact
        networkSummary.isHidden = compact
        heroStack.spacing = compact ? 10 : 14
        heroStack.directionalLayoutMargins = compact
            ? NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
            : NSDirectionalEdgeInsets(top: 22, leading: 20, bottom: 22, trailing: 20)
        connectionDetailsButton.isHidden = !displayedVideo
        connectionDetailsButton.setTitle(showsConnectionDetails ? "收起详情" : "连接详情", for: .normal)
        connectionDetailsButton.accessibilityValue = showsConnectionDetails ? "已展开" : "已收起"
        startButton.configuration?.contentInsets = compact
            ? NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
            : NSDirectionalEdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24)
        let cards: [(UIStackView, UILabel)] = [(carLifeCard, carLifeCardStatus), (zeehoCard, zeehoCardStatus),
            (ninebotCard, ninebotCardStatus), (tailingCard, tailingCardStatus)]
        for (card, status) in cards {
            for child in card.arrangedSubviews { child.isHidden = compact && child !== status }
            card.directionalLayoutMargins = compact
                ? NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
                : NSDirectionalEdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
        }
        guard displayedVideo, homeStack.arrangedSubviews.contains(inlineVideoContainer) else { return }
        let focus: [UIView] = [inlineVideoContainer, videoActions, controlBar]
        for (index, child) in focus.enumerated() {
            if homeStack.arrangedSubviews[index + 1] !== child {
                homeStack.removeArrangedSubview(child)
                homeStack.insertArrangedSubview(child, at: index + 1)
            }
        }
    }
    @objc private func toggleHTTPSAddress() {
        UserDefaults.standard.set(!httpsExpanded, forKey: httpsExpandedKey)
        refreshVideoOutputSummary()
    }
    @objc private func copyVideoURL() { copy(browserURL, button: browserCopyButton) }
    @objc private func copySecureVideoURL() { copy(secureBrowserURL, button: secureBrowserCopyButton) }
    private func copy(_ url: String?, button: UIButton) {
        guard let url else { return }
        UIPasteboard.general.string = url
        button.setTitle("已复制", for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { button.setTitle("复制", for: .normal) }
    }
    @objc private func startPictureInPicture() {
        if !pictureInPicture.start() { statusLabel.text = "暂时无法开启画中画" }
    }
    private var displayAspectHeight: CGFloat {
        let plan = planDisplay(for: targetScreen)
        return CGFloat(plan.height) / CGFloat(plan.width)
    }
    private func configureDisplay(_ config: inout ReceiverConfiguration) {
        let screen = targetScreen
        let plan = planDisplay(for: screen)
        config.rightHandDrive = driveControl.selectedSegmentIndex == 1
        config.width = plan.width; config.height = plan.height
        config.maxFPS = plan.fps; config.videoCodec = plan.codec
        config.widthPhysicalMM = plan.iconWidthMM
        config.browserPerformance = selectedPerformance
        config.showTouches = showTouchesSwitch.isOn
        if carButtonSwitch.isOn {
            config.oemIconPNG = customVehicleIcon ?? Self.carButtonIcon
            config.oemIconLabel = String((nameField.text ?? "").prefix(12)).isEmpty ? "CarWithin" : String((nameField.text ?? "").prefix(12))
        }
        let source = outputMode != .browser ? headUnitOutput.selectedTitle
            : followsCarScreen ? (screen.map { "车机屏幕 \($0.title)" } ?? "尚无车机屏幕，用固定分辨率") : "固定尺寸"
        log("画面计划：\(plan.width)×\(plan.height) @ \(plan.fps) FPS \(plan.codec.displayName)（\(source)\(lightLevel > 0 ? "，减轻档 \(lightLevel)" : "")）")
        config.browserAudio = soundOutput == .browser && config.videoOutputPort != nil && outputMode == .browser
        if outputMode == .airPlay, config.videoOutputPort != nil { config.airPlayStreamID = UUID() }
        if outputMode == .zeeho {
            config.zeehoAddress = (zeehoAddressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let mode = outputMode.ninebotMode {
            config.ninebotAddress = (activeNinebotAddressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            config.ninebotMode = mode
        }
        if outputMode.usesInstrumentWiFi {
            let screen = view.window?.screen ?? UIScreen.main
            let orientation = view.window?.windowScene?.interfaceOrientation
            let rotation: Int
            switch orientation {
            case .landscapeLeft: rotation = 1
            case .portraitUpsideDown: rotation = 2
            case .landscapeRight: rotation = 3
            default: rotation = 0
            }
            config.tailingPhoneInfo = TailingPhoneInfo(package: Bundle.main.bundleIdentifier ?? "CarWithin",
                versionCode: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
                model: UIDevice.current.model, systemVersion: UIDevice.current.systemVersion,
                width: Int(screen.bounds.width * screen.scale), height: Int(screen.bounds.height * screen.scale), rotation: rotation)
        }
        if outputMode == .tailing {
            config.tailingAddress = (tailingAddressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        }
        config.carLifeEnabled = outputMode == .carLife
        let carLifeAddress = (carLifeAddressField.text ?? "").trimmingCharacters(in: .whitespaces)
        config.carLifeAddress = !config.carLifeEnabled || carLifeAddress.isEmpty ? nil : carLifeAddress
    }
    @objc private func toggleSettings() { revealSettings() }
    @objc private func driveChanged() {
        UserDefaults.standard.set(driveControl.selectedSegmentIndex == 1, forKey: "rightHandDrive")
    }
    @objc private func orientationChanged() {
        guard !running else { return }
        UserDefaults.standard.set(orientationControl.selectedSegmentIndex == 1, forKey: "portraitDisplay")
        updateVideoAspect()
        reloadVisibleSettings()
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        guard fullscreenContainer != nil, UIDevice.current.userInterfaceIdiom == .pad else { return .all }
        return orientationControl.selectedSegmentIndex == 1 ? .portrait : .landscape
    }
    @objc private func showFullscreen() {
        guard displayedVideo, fullscreenContainer == nil else { return }
        view.endEditing(true)
        NSLayoutConstraint.deactivate(inlineVideoConstraints)
        videoSurface.removeFromSuperview()
        let container = UIView(); container.backgroundColor = .black; container.translatesAutoresizingMaskIntoConstraints = false
        fullscreenContainer = container; view.addSubview(container); container.addSubview(videoSurface)
        videoSurface.translatesAutoresizingMaskIntoConstraints = false
        fullscreenConstraints = [container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor), container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor), videoSurface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoSurface.trailingAnchor.constraint(equalTo: container.trailingAnchor), videoSurface.topAnchor.constraint(equalTo: container.topAnchor),
            videoSurface.bottomAnchor.constraint(equalTo: container.bottomAnchor)]
        NSLayoutConstraint.activate(fullscreenConstraints)
        if !sessionHasVehicleButton { addFullscreenExitButton(to: container) }
        navigationController?.setNavigationBarHidden(true, animated: false)
        setNeedsStatusBarAppearanceUpdate(); setNeedsUpdateOfHomeIndicatorAutoHidden()
        if UIDevice.current.userInterfaceIdiom == .pad {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations)) { [weak self] _ in
                self?.log("请把 iPad 旋转到所选方向以获得全屏画面")
            }
        }
    }

    private func addFullscreenExitButton(to container: UIView) {
        let exit = UIButton(type: .system)
        let icon = UIImage(systemName: "arrow.down.right.and.arrow.up.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        exit.setImage(icon, for: .normal)
        exit.tintColor = .white
        exit.backgroundColor = .clear
        exit.layer.cornerRadius = 22
        exit.layer.borderWidth = 1
        exit.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        exit.layer.shadowColor = UIColor.black.cgColor
        exit.layer.shadowOpacity = 0.8
        exit.layer.shadowRadius = 2
        exit.layer.shadowOffset = .zero
        exit.accessibilityLabel = "退出全屏"
        exit.addTarget(self, action: #selector(hideFullscreen), for: .touchUpInside)
        exit.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(exit)
        fullscreenExitButton = exit

        let constraints = [
            exit.widthAnchor.constraint(equalToConstant: 44), exit.heightAnchor.constraint(equalToConstant: 44),
            exit.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            exit.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 8)]
        NSLayoutConstraint.activate(constraints)
        fullscreenConstraints += constraints
        refreshFullscreenExitButton()
    }
    private func refreshFullscreenExitButton() {
        guard let exit = fullscreenExitButton else { return }
        if exit.alpha < 1 {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                exit.alpha = 1
            }
        }
        if let fullscreenFadeTimer {
            fullscreenFadeTimer.fireDate = Date(timeIntervalSinceNow: 5)
            return
        }
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self, weak exit] _ in
            self?.fullscreenFadeTimer = nil
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                exit?.alpha = 0.3
            }
        }
        fullscreenFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func hideFullscreen() {
        guard let container = fullscreenContainer else { return }
        fullscreenFadeTimer?.invalidate()
        fullscreenFadeTimer = nil
        fullscreenExitButton = nil
        UIView.performWithoutAnimation {
            NSLayoutConstraint.deactivate(fullscreenConstraints)
            fullscreenConstraints = []
            videoSurface.removeFromSuperview()
            container.removeFromSuperview()
            fullscreenContainer = nil
            restoreInlineVideoSurface()
            navigationController?.setNavigationBarHidden(false, animated: false)
            setNeedsUpdateOfSupportedInterfaceOrientations()
            setNeedsStatusBarAppearanceUpdate()
            setNeedsUpdateOfHomeIndicatorAutoHidden()
            view.layoutIfNeeded()
        }
        pictureInPicture.sourceMayBeReady()
    }

    private func restoreInlineVideoSurface() {
        inlineVideoContainer.addSubview(videoSurface)
        inlineVideoConstraints = [
            videoSurface.leadingAnchor.constraint(equalTo: inlineVideoContainer.leadingAnchor),
            videoSurface.trailingAnchor.constraint(equalTo: inlineVideoContainer.trailingAnchor),
            videoSurface.topAnchor.constraint(equalTo: inlineVideoContainer.topAnchor),
            videoSurface.bottomAnchor.constraint(equalTo: inlineVideoContainer.bottomAnchor)
        ]
        NSLayoutConstraint.activate(inlineVideoConstraints)
    }

    @objc private func networkNameChanged() {
        passwordLoadedForSSID = nil
        passwordField.text = ""; openNetworkSwitch.isOn = false; passwordStatus.text = ""
        // No table rebuild while the user is typing an SSID or composing Chinese text.
        refreshNetworkSummary()
    }
    @objc private func loadWiFiPassword() {
        let ssid = ssidField.text ?? ""
        guard !ssid.isEmpty else { return }
        // Merely revisiting the name field must not overwrite an edited password with Keychain.
        guard (passwordField.text ?? "").isEmpty else { return }
        do {
            if let saved = try WiFiCredentials.password(for: ssid) {
                passwordField.text = saved; openNetworkSwitch.isOn = saved.isEmpty
                passwordLoadedForSSID = ssid
                passwordStatus.text = saved.isEmpty ? "已读取本 App 保存的开放网络配置。" : "已读取本 App 保存的 Wi-Fi 密码。"
            } else {
                passwordLoadedForSSID = nil
                passwordStatus.text = "已读取 Wi-Fi 名称，但本 App 尚未保存该网络的密码。请在系统设置中查看并复制密码，粘贴到这里后保存。"
            }
        } catch {
            // A locked Keychain or changed signing access group must remain retryable.
            passwordLoadedForSSID = nil
            passwordStatus.text = "无法读取本 App 保存的密码。请解锁后重新读取；若更换过签名或安装包，请重新粘贴并保存密码。"
        }
    }

    @objc private func showWiFiPasswordChanged() {
        let text = passwordField.text
        passwordField.isSecureTextEntry = !showWiFiPasswordSwitch.isOn
        passwordField.text = text
    }

    private func refreshNetworkSummary() {
        let name = ssidField.text ?? ""
        if needsNetworkDetails, !name.isEmpty {
            networkSummary.text = "CarPlay Wi-Fi 预设：\(name)"
        } else if needsNetworkDetails {
            networkSummary.text = "请在设置中添加或选择 Wi-Fi 预设。"
        } else {
            networkSummary.text = "让两台设备连接同一个 Wi-Fi。"
        }
    }
    @objc private func detectNetwork() { refreshCurrentNetwork(requestPermission: true) }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard awaitingNetworkPermission, manager.authorizationStatus != .notDetermined else { return }
        awaitingNetworkPermission = false
        guard activeWiFiForm != nil else { return }
        refreshCurrentNetwork(requestPermission: true)
    }
    private func refreshCurrentNetwork(requestPermission: Bool) {
        guard canDetectWiFiName, !running, !waitingForNetwork, !fetchingNetwork, needsNetworkDetails,
              requestPermission || (activeWiFiForm == nil && (ssidField.text ?? "").isEmpty) else { return }
        let authorization = locationManager.authorizationStatus
        if authorization == .notDetermined, requestPermission {
            awaitingNetworkPermission = true; locationManager.requestWhenInUseAuthorization(); return
        }
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            if requestPermission {
                passwordStatus.text = "可以手动填写 Wi-Fi 名称，也可允许定位后自动读取。"
                reloadVisibleSettings()
            }
            return
        }
        fetchingNetwork = true
        let previousSSID = ssidField.text
        let form = activeWiFiForm
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                guard let self else { return }; self.fetchingNetwork = false
                guard !self.running, !self.ssidField.isFirstResponder, !self.passwordField.isFirstResponder,
                      self.ssidField.text == previousSSID, self.activeWiFiForm == form, !self.waitingForNetwork else { return }
                guard let network else {
                    if requestPermission {
                        self.passwordStatus.text = "无法读取 Wi-Fi 名称，请手动填写。"
                        self.reloadVisibleSettings()
                    }
                    return
                }
                if self.ssidField.text != network.ssid {
                    self.ssidField.text = network.ssid; self.networkNameChanged()
                }
                // Also retry when the SSID is unchanged but the password is missing.
                self.loadWiFiPassword()
                self.refreshNetworkSummary()
                if requestPermission { self.reloadVisibleSettings() }
            }
        }
    }
    @objc private func forgetWiFiPassword() {
        let ssid = ssidField.text ?? ""
        guard !ssid.isEmpty else { return }
        do {
            try WiFiCredentials.forget(ssid)
            WiFiPresetStore.remove(ssid)
            if let next = WiFiPresetStore.selected() { applyWiFiPreset(next) }
            else {
                ssidField.text = ""; passwordField.text = ""; channelField.text = "36"; openNetworkSwitch.isOn = false
                passwordLoadedForSSID = nil
                refreshWiFiPresetMenu(); refreshNetworkSummary()
            }
            passwordStatus.text = "已删除 Wi-Fi 预设“\(ssid)”"
        } catch { passwordStatus.text = "无法删除 Wi-Fi 预设：\(error.localizedDescription)" }
    }
    private func saveSettings(_ config: ReceiverConfiguration) -> Bool {
        let savesPassword = needsNetworkDetails &&
            (config.wiFiBootstrap == nil || config.wiFiBootstrap?.availableCredentials != nil)
        do { if savesPassword { try WiFiCredentials.save(config.password, for: config.ssid) } }
        catch { statusLabel.text = "无法安全保存 Wi-Fi 密码，请重试。"; return false }
        if needsNetworkDetails {
            passwordStatus.text = savesPassword ? "Wi-Fi 密码已保存到 Keychain" : "已记住 Wi-Fi 名称，未保存或修改密码"
            UserDefaults.standard.set(config.ssid, forKey: "wifiSSID")
            UserDefaults.standard.set(Int(config.wifiChannel), forKey: "wifiChannel")
            WiFiPresetStore.upsert(ssid: config.ssid, channel: config.wifiChannel, isOpen: openNetworkSwitch.isOn)
            refreshWiFiPresetMenu()
        }
        audioSettingChanged()
        UserDefaults.standard.set(resolutionControl.selectedSegmentIndex, forKey: "displayResolutionIndex")
        saveDisplaySettings()
        UserDefaults.standard.set(pictureInPictureTiming.selectedSegmentIndex != 0, forKey: "pictureInPictureEnabled")
        UserDefaults.standard.set(pictureInPictureTiming.selectedSegmentIndex, forKey: "pictureInPictureTiming")
        UserDefaults.standard.set(videoOutputSwitch.isOn, forKey: "videoOutputEnabled")
        saveHeadUnitOutput()
        if config.videoOutputPort != nil { saveBrowserPorts() }
        if modeControl.selectedSegmentIndex != 2 { UserDefaults.standard.set(config.name, forKey: "receiverName") }
        return true
    }
    @objc private func testSameDeviceTransport() {
        guard !running else {
            statusLabel.text = "请先停止 CarPlay，再测试本机传输。"
            saveTransportProbeResult("blocked: CarPlay 正在运行")
            return
        }
        transportProbeButton.isEnabled = false
        transportProbe.stop()
        do {
            let identifier = "CarWithin-Transport-Probe-\(UUID().uuidString)"
            try transportProbe.start(withIdentifier: identifier, transportType: 2)
            statusLabel.text = "本机传输能力可用"
            log("CoreAccessories 已创建并发布 protocol-4 iAP2 endpoint")
            saveTransportProbeResult("success: CoreAccessories 已发布 protocol-4 iAP2 endpoint")
        } catch {
            statusLabel.text = "本机传输能力不可用"
            log("CoreAccessories 传输测试失败：\(error.localizedDescription)")
            saveTransportProbeResult("failure: \(error.localizedDescription)")
        }
        transportProbe.stop()
        transportProbeButton.isEnabled = true
    }
    private func saveTransportProbeResult(_ result: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let value = "\(ISO8601DateFormatter().string(from: Date()))\n\(result)\n"
        do {
            try value.write(to: documents.appendingPathComponent("transport-probe.txt"), atomically: true, encoding: .utf8)
        } catch {
            log("无法保存传输测试结果：\(error.localizedDescription)")
        }
    }
    private func loadIdentity() {
        let importing = ProcessInfo.processInfo.arguments.contains("--import-mfi-identity")
        do {
            if importing {
                identity = try AccessoryIdentityStore.importFromDocuments()
                log("MFi 身份验证通过并已保存到本机 Keychain")
                saveIdentityImportResult("success: MFi 身份已验证并保存到 Keychain")
            } else if let keychainIdentity = try? AccessoryIdentityStore.load() {
                identity = keychainIdentity
                log("已从 Keychain 载入 MFi 身份，ECDSA 自检通过")
            } else {
                identity = try AccessoryIdentityStore.loadFromBundle()
                log("已从内置资源载入 MFi 身份，ECDSA 自检通过")
            }
            startButton.isEnabled = true
            identitySetupButton.isHidden = true
            identityImportStatus.text = "已载入身份，本地证书与私钥匹配校验通过。"
            statusLabel.text = "可以开始连接"
        } catch {
            identity = nil
            identitySetupButton.isHidden = false
            identityImportStatus.text = "此安装包未载入身份。若原版可以启动，请从原版 IPA 导入；仅重新签名不能补齐身份。"
            statusLabel.text = "尚未导入有效的 MFi 身份"; startButton.isEnabled = false
            log("请通过 Documents/IdentityImport 导入 certificate.p7b、leaf.cer 和 private.x963。错误：\(error.localizedDescription)")
            if importing { saveIdentityImportResult("failure: \(error.localizedDescription)") }
        }
    }
    private func saveIdentityImportResult(_ result: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let value = "\(ISO8601DateFormatter().string(from: Date()))\n\(result)\n"
        do {
            try value.write(to: documents.appendingPathComponent("identity-import-result.txt"), atomically: true, encoding: .utf8)
        } catch {
            log("无法保存身份导入结果：\(error.localizedDescription)")
        }
    }
    @objc private func ninebotAutoConnectChanged() {
        UserDefaults.standard.set(ninebotAutoConnectSwitch.isOn, forKey: "ninebotAutoConnect")
        // A failed or cancelled attempt is retried only by an explicit user action.
        attemptedNinebotAutoConnect = false
    }

    @objc private func ninebotCurrentWiFiChanged() {
        UserDefaults.standard.set(ninebotCurrentWiFiSwitch.isOn, forKey: "ninebotCurrentWiFi")
        reloadVisibleSettings()
    }

    private func attemptNinebotAutoConnect() {
        guard ninebotAutoConnectSwitch.isOn, !attemptedNinebotAutoConnect,
              outputMode.ninebotMode != nil, modeControl.selectedSegmentIndex == 1,
              identity != nil, !running, !waitingForNetwork, activeWiFiForm == nil,
              presentedViewController == nil, UIApplication.shared.applicationState == .active,
              let preset = WiFiPresetStore.selected(), preset.ssid == ssidField.text else { return }
        attemptedNinebotAutoConnect = true
        joinSelectedWiFi(startCarPlay: true)
    }

    private func joinSelectedWiFi(startCarPlay: Bool) {
        guard !running, !waitingForNetwork, UIApplication.shared.applicationState == .active else { return }
        if startCarPlay {
            guard identity != nil else {
                statusLabel.text = "尚未载入身份，请点「配置身份」从原版 IPA 导入。"
                revealSettings(showIdentity: true)
                return
            }
            guard modeControl.selectedSegmentIndex == 1 else {
                statusLabel.text = "请先选择本机 CarPlay 模式。"
                return
            }
        }
        if startCarPlay { attemptedNinebotAutoConnect = true }
        if startCarPlay, !restartingAutomatically { beginConnectionTimeline() }
        view.endEditing(true)
        guard saveCurrentWiFiPreset() else {
            statusLabel.text = passwordStatus.text
            recordConnection(.failed, passwordStatus.text ?? "Wi-Fi 配置未通过检查")
            reloadVisibleSettings()
            return
        }
        #if targetEnvironment(macCatalyst) || targetEnvironment(simulator)
        statusLabel.text = "自动加入或复用 Wi-Fi 需要在 iPhone 或 iPad 真机上使用。"
        passwordStatus.text = statusLabel.text
        reloadVisibleSettings()
        #else
        let ssid = ssidField.text ?? ""
        let credentials = enteredWiFiCredentials
        let reuseCurrentWiFi = startCarPlay && prefersCurrentWiFiStartup
        let restarting = restartingAutomatically
        let id = UUID()
        wiFiJoinID = id
        waitingForNetwork = true
        modeControl.isEnabled = false
        setEditing(false)
        startButton.setTitle("取消连接", for: .normal)
        statusLabel.text = "正在检查当前 Wi-Fi…"
        passwordStatus.text = statusLabel.text
        wiFiJoinTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishWiFiJoin(id: id, message: "检查或加入 Wi-Fi 超时，请确认系统提示后重试。")
        }
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                guard let self, self.wiFiJoinID == id else { return }
                if network?.ssid == ssid {
                    self.log("已连接所选仪表 Wi-Fi，复用当前网络，不重复申请加入")
                    self.statusLabel.text = "已连接 Wi-Fi：\(ssid)，正在确认网络就绪…"
                    self.passwordStatus.text = self.statusLabel.text
                    self.waitForSelectedWiFi(id: id, ssid: ssid, startCarPlay: startCarPlay,
                        useCurrentWiFi: reuseCurrentWiFi, restarting: restarting)
                    return
                }
                guard let credentials else {
                    self.finishWiFiJoin(id: id, message: "未确认已连接所选仪表 Wi-Fi。请先在系统设置连接并允许读取 Wi-Fi 名称，或填写密码后重试。")
                    return
                }
                guard UIApplication.shared.applicationState == .active else {
                    self.finishWiFiJoin(id: id, message: "请返回 CarWithin 后重试连接。")
                    return
                }
                let configuration = credentials.password.isEmpty
                    ? NEHotspotConfiguration(ssid: ssid)
                    : NEHotspotConfiguration(ssid: ssid, passphrase: credentials.password, isWEP: false)
                // Keep the network when switching to the official Ninebot app.
                configuration.joinOnce = false
                self.statusLabel.text = "正在加入 Wi-Fi：\(ssid)…"
                self.passwordStatus.text = self.statusLabel.text
                NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self, self.wiFiJoinID == id else { return }
                        if let error = error as NSError?,
                           !(error.domain == NEHotspotConfigurationErrorDomain &&
                             error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
                            let denied = error.domain == NEHotspotConfigurationErrorDomain &&
                                error.code == NEHotspotConfigurationError.userDenied.rawValue
                            self.finishWiFiJoin(id: id, message: denied ? "已取消加入 Wi-Fi，可手动重试。" :
                                "加入 Wi-Fi 失败：\(error.localizedDescription)。请检查密码、仪表热点和签名的 Hotspot Configuration 权限。")
                            return
                        }
                        // Newly joined networks retain the established credential-based path.
                        self.waitForSelectedWiFi(id: id, ssid: ssid, startCarPlay: startCarPlay,
                            useCurrentWiFi: false, restarting: restarting)
                    }
                }
            }
        }
        #endif
    }

    private func waitForSelectedWiFi(id: UUID, ssid: String, startCarPlay: Bool,
                                     useCurrentWiFi: Bool, restarting: Bool) {
        guard wiFiJoinID == id else { return }
        wiFiJoinTask?.cancel()
        wiFiJoinTask = Task { [weak self] in
            var previousAddress: String?
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.wiFiJoinID == id else { return }
                let network = await NEHotspotNetwork.fetchCurrent()
                guard !Task.isCancelled, self.wiFiJoinID == id else { return }
                let address = ReceiverConfiguration.wifiIPv4Address()
                if network?.ssid == ssid, let address, address == previousAddress,
                   UIApplication.shared.applicationState == .active {
                    self.finishWiFiJoin(id: id, message: "已连接 Wi-Fi：\(ssid)")
                    if startCarPlay {
                        let previousRestarting = self.restartingAutomatically
                        self.startingAfterWiFiJoin = true
                        self.startingWithCurrentWiFi = useCurrentWiFi
                        self.restartingAutomatically = restarting
                        defer {
                            self.startingAfterWiFiJoin = false
                            self.startingWithCurrentWiFi = false
                            self.restartingAutomatically = previousRestarting
                        }
                        self.toggleReceiver()
                    }
                    return
                }
                previousAddress = network?.ssid == ssid ? address : nil
            }
            self?.finishWiFiJoin(id: id, message: "未确认仪表 Wi-Fi 连接。请检查热点已开启、Wi-Fi 权限及密码，然后重试。")
        }
    }

    private func finishWiFiJoin(id: UUID, message: String) {
        guard wiFiJoinID == id else { return }
        recordConnection(message.hasPrefix("已连接 Wi-Fi") ? .wifi : .failed, message)
        wiFiJoinID = nil
        wiFiJoinTask?.cancel()
        wiFiJoinTask = nil
        wiFiJoinTimeoutTask?.cancel()
        wiFiJoinTimeoutTask = nil
        waitingForNetwork = false
        modeControl.isEnabled = true
        setEditing(true)
        ninebotAutoConnectSwitch.isEnabled = true
        modeChanged()
        statusLabel.text = message
        passwordStatus.text = message
        if outputMode.ninebotMode != nil { updateNinebotStatus(message) }
        refreshNetworkAddresses()
        reloadVisibleSettings()
    }

    @objc private func toggleReceiver() {
        if running || waitingForNetwork { attemptedNinebotAutoConnect = true; stop(); return }
        if outputMode.ninebotMode != nil, modeControl.selectedSegmentIndex == 1,
           !startingAfterWiFiJoin {
            joinSelectedWiFi(startCarPlay: true)
            return
        }
        if !startingAfterWiFiJoin, !restartingAutomatically { beginConnectionTimeline() }
        if !restartingAutomatically { networkRestartCount = 0 }
        clearStartupHint()
        updateCheckTask?.cancel()
        view.endEditing(true)
        refreshNetworkAddresses()
        let channel = UInt8(channelField.text ?? "") ?? 36
        guard (1...196).contains(channel) else {
            revealSettings(); statusLabel.text = "兼容信道请输入 1–196，或留空使用默认值 36。"; return
        }
        let outputPort: UInt16?
        let httpsPort: UInt16?
        if outputMode == .browser && videoOutputSwitch.isOn {
            if let error = browserPortError {
                statusLabel.text = error
                revealSettings(output: true)
                return
            }
            outputPort = browserPort
            httpsPort = secureBrowserPort
        } else if outputMode == .airPlay {
            guard let browserPort else {
                revealSettings(output: true)
                return
            }
            outputPort = browserPort
            httpsPort = nil
        } else {
            outputPort = nil
            httpsPort = nil
        }
        guard startingWithCurrentWiFi || !needsNetworkDetails || openNetworkSwitch.isOn || !(passwordField.text ?? "").isEmpty else {
            statusLabel.text = "请输入 Wi-Fi 密码；开放网络请选择“无密码”。"
            revealSettings(wifi: true); return
        }
        let password = !needsNetworkDetails || openNetworkSwitch.isOn ? "" : (passwordField.text ?? "")
        if modeControl.selectedSegmentIndex == 2 {
            guard let identity, let target = remoteTarget else {
                statusLabel.text = "请先选择 iPad 接收端，并确保两台设备位于同一 Wi-Fi。"; return
            }
            let config = ReceiverConfiguration(name: target.name, address: target.address,
                ssid: ssidField.text ?? "", password: password, port: target.port,
                wifiChannel: channel, audioEnabled: false, videoOutputPort: nil, deviceID: target.deviceID)
            do { try config.validate(requiresLocalAddress: false) } catch {
                revealSettings(); statusLabel.text = error.localizedDescription; return
            }
            guard saveSettings(config) else { return }
            if keepAliveSwitch.isOn { keepAlive.start() }
            view.endEditing(true); running = true; modeControl.isEnabled = false; setEditing(false)
            beginBMSSessionIfNeeded()
            receiverPicker.isEnabled = false; receiverBrowser.stop()
            UIApplication.shared.isIdleTimerDisabled = true
            startButton.setTitle("停止 iPad 连接", for: .normal)
            log("正在请求把本机 CarPlay 投送到 \(target.name)（\(target.address):\(target.port)）")
            sameDevice.start(configuration: config, identity: identity, expectsLocalControl: false)
            return
        }
        if modeControl.selectedSegmentIndex == 1 {
            guard let identity else { return }
            guard let address = localCarPlayAddress else { waitForLocalNetwork(); return }
            var config = ReceiverConfiguration(name: nameField.text ?? "CarWithin", address: address,
                ssid: ssidField.text ?? "", password: password, wifiChannel: channel, audioEnabled: soundOutput != .phone,
                videoOutputPort: outputPort, secureVideoOutputPort: httpsPort,
                deviceID: ReceiverConfiguration.persistentDeviceID())
            if !restartingAutomatically { autoRestarts = 0; lightLevel = 0; reportedScreen = nil; primaryViewer = nil }
            configureDisplay(&config)
            if startingWithCurrentWiFi {
                config.wiFiBootstrap = CarPlayWiFiBootstrap.onConfirmedNetwork(credentials: enteredWiFiCredentials)
            }
            do { try config.validate(requiresWiFiCredentials: !startingWithCurrentWiFi) } catch {
                log("无法启动本机 CarPlay：\(error.localizedDescription)")
                recordConnection(.failed, error.localizedDescription)
                revealSettings(); statusLabel.text = error.localizedDescription; return
            }
            liveDisplay = DisplayPlan(width: config.width, height: config.height, fps: config.maxFPS,
                                      codec: config.videoCodec, iconWidthMM: config.widthPhysicalMM)
            updateVideoAspect()
            guard saveSettings(config) else { return }
            sessionHasVehicleButton = CarPlayInfo.vehicleButtonSize(in: config) != nil
            // Activate while foregrounded, before the virtual CarPlay route is selected.
            // Waiting until willResignActive can fail to acquire an audio session on CarAudio.
            if keepAliveSwitch.isOn { keepAlive.start() }
            view.endEditing(true)
            running = true; modeControl.isEnabled = false; setEditing(false)
            beginBMSSessionIfNeeded()
            saveActiveVehicleProfile()
            startButton.setTitle("停止 CarPlay", for: .normal)
            startButton.configuration?.image = UIImage(systemName: "stop.fill")
            statusLabel.text = "正在启动本机 CarPlay…"
            UIApplication.shared.isIdleTimerDisabled = true
            let startupID = UUID()
            localStartupID = startupID
            receiver.onListening = { [weak self] port in
                guard let self, self.running, self.localStartupID == startupID else { return }
                var live = config; live.port = port
                self.controlBrowser.start()
                self.sameDevice.start(configuration: live, identity: identity)
            }
            prepareExternalOutput(configuration: config)
            receiver.start(configuration: config, identity: identity, preferredViewer: primaryViewer)
            watchStartupAddress(address)
            return
        }
        guard let identity else { return }
        let addresses = ReceiverConfiguration.localIPv4Addresses()
        if !addresses.contains(ipField.text ?? "") { ipField.text = browserAddress ?? addresses.first }
        var config = ReceiverConfiguration(name: nameField.text ?? "CarWithin", address: ipField.text ?? "",
            ssid: ssidField.text ?? "", password: password, wifiChannel: channel, audioEnabled: soundOutput != .phone,
            videoOutputPort: outputPort, secureVideoOutputPort: httpsPort,
            deviceID: ReceiverConfiguration.persistentDeviceID())
        configureDisplay(&config)
        do { try config.validate(requiresWiFiCredentials: needsNetworkDetails) } catch {
            statusLabel.text = error.localizedDescription
            recordConnection(.failed, error.localizedDescription)
            log("无法启动：\(error.localizedDescription)")
            revealSettings(wifi: config.ssid.isEmpty)
            return
        }
        guard saveSettings(config) else { return }
        sessionHasVehicleButton = CarPlayInfo.vehicleButtonSize(in: config) != nil
        if keepAliveSwitch.isOn { keepAlive.start() }
        view.endEditing(true)
        running = true; modeControl.isEnabled = false; setEditing(false); startButton.setTitle("停止接收", for: .normal)
        beginBMSSessionIfNeeded()
        startButton.configuration?.image = UIImage(systemName: "stop.fill")
        UIApplication.shared.isIdleTimerDisabled = true; statusLabel.text = "正在启动接收服务…"
        receiver.onListening = { [weak self] port in
            guard let self, self.running else { return }
            var live = config; live.port = port
            self.statusLabel.text = "正在等待 iPhone 连接"
            if self.bluetoothSetupSwitch.isOn { self.bluetooth.start(configuration: live) }
        }
        prepareExternalOutput(configuration: config)
        receiver.start(configuration: config, identity: identity)
    }
    private var localCarPlayAddress: String? {
        outputMode.usesInstrumentWiFi ? ReceiverConfiguration.wifiIPv4Address() : browserAddress
    }

    private func refreshNetworkAddresses() {
        refreshBrowserAddressLabels()
    }

    private func waitForLocalNetwork() {
        waitingForNetwork = true
        modeControl.isEnabled = false
        setEditing(false)
        startButton.setTitle("取消连接", for: .normal)
        statusLabel.text = "正在等待 Wi-Fi 分配 IP 地址…"
        networkStartupTask?.cancel()
        networkStartupTask = Task { [weak self] in
            var candidate: String?
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                let address = self.localCarPlayAddress
                if let address, address == candidate, UIApplication.shared.applicationState == .active {
                    self.waitingForNetwork = false
                    self.modeControl.isEnabled = true
                    self.setEditing(true)
                    self.restartingAutomatically = self.networkRestartCount > 0
                    self.toggleReceiver()
                    self.restartingAutomatically = false
                    return
                }
                candidate = address
            }
            guard let self else { return }
            self.stop()
            self.statusLabel.text = "未获得 Wi-Fi 地址。请连接正确的 Wi-Fi 后重试。"
        }
    }

    private func watchStartupAddress(_ initialAddress: String) {
        networkStartupTask?.cancel()
        let startupID = localStartupID
        networkStartupTask = Task { [weak self] in
            var monitor = StartupNetworkMonitor(address: initialAddress)
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.running, !self.displayedVideo,
                      self.localStartupID == startupID else { return }
                let address = self.localCarPlayAddress
                self.refreshNetworkAddresses()
                let update = monitor.observe(address: address, at: ProcessInfo.processInfo.systemUptime)
                if update == .recovered {
                    self.log("Wi-Fi 地址短暂中断后已恢复，保留当前 CarPlay 启动会话")
                }
                guard case .restart(let newAddress) = update, self.networkRestartCount < 2,
                      UIApplication.shared.applicationState == .active else { continue }
                self.networkRestartCount += 1
                self.log("启动期间 Wi-Fi 地址已变更或长时间中断（\(initialAddress) → \(newAddress)），重新连接 CarPlay")
                self.recordConnection(.preparing, "Wi-Fi 地址变化，自动重新连接")
                self.stop(preserveDiagnostics: true)
                self.restartingAutomatically = true
                self.toggleReceiver()
                self.restartingAutomatically = false
                return
            }
        }
    }

    private func stop(preserveDiagnostics: Bool = false) {
        if !preserveDiagnostics { recordConnection(.stopped, "连接已停止") }
        finishBMSSession()
        wiFiJoinID = nil
        wiFiJoinTask?.cancel()
        wiFiJoinTask = nil
        wiFiJoinTimeoutTask?.cancel()
        wiFiJoinTimeoutTask = nil
        localStartupID = nil
        networkStartupTask?.cancel()
        networkStartupTask = nil
        waitingForNetwork = false
        clearStartupHint()
        airPlayReady = false
        airPlayItemObservation = nil
        airPlayRouteObservation = nil
        #if DEBUG
        airPlayTimeObservation = nil
        #endif
        airPlayPlayer?.pause()
        airPlayPlayer?.replaceCurrentItem(with: nil)
        airPlayPlayer?.allowsExternalPlayback = false
        airPlayPlayer = nil
        airPlayStreamID = nil; airPlayStreamURL = nil
        airPlayRetryButton.isHidden = true
        updateAirPlayStatus("等待启动 CarPlay。")
        updateCarLifeStatus("等待启动 CarPlay。")
        running = false
        sessionHasVehicleButton = false
        screenAdaptation?.cancel(); screenAdaptation = nil
        reportedScreen = nil; primaryViewer = nil; pendingRestartReason = nil
        pictureInPicture.stop(); keepAlive.stop(); skippedLocalVideo = false
        hideFullscreen(); videoActions.isHidden = true; controlBar.isHidden = true
        displayedVideo = false; didRequestImmediatePiP = false
        showsConnectionDetails = false
        videoSurface.reset(); inlineVideoContainer.isHidden = true
        receiver.onListening = nil; bluetooth.stop(); sameDevice.stop(); controlBrowser.stop(); receiver.stop()
        receiverBrowser.stop()
        modeControl.isEnabled = true
        UIApplication.shared.isIdleTimerDisabled = false; setEditing(true)
        modeChanged()
        statusLabel.text = identity == nil ? "需要导入 MFi 身份" : "已停止"
        log("CarPlay 接收已停止")
    }

    private func clearStartupHint() {
        startupHintTask?.cancel()
        startupHintTask = nil
        startupHintGeneration = UUID()
        startupHint.text = nil
        startupHint.isHidden = true
    }

    private func scheduleStartupHint() {
        guard modeControl.selectedSegmentIndex == 1, startupHintTask == nil else { return }
        let generation = startupHintGeneration
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.startupHintGeneration == generation, self.running,
                  !self.displayedVideo, self.modeControl.selectedSegmentIndex == 1 else { return }
            self.startupHint.text = "正在等待下一连接阶段。若超时，请到「设置 → 诊断与实验 → 日志」复制记录。已有 Wi-Fi 密码时会直接使用配置启动。"
            self.startupHint.isHidden = false
        }
        startupHintTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }
    @objc private func modeChanged() {
        if UIDevice.current.userInterfaceIdiom == .phone { modeControl.selectedSegmentIndex = 1 }
        UserDefaults.standard.set(modeControl.selectedSegmentIndex, forKey: "connectionMode")
        let local = modeControl.selectedSegmentIndex == 1
        let remote = modeControl.selectedSegmentIndex == 2
        receiverBrowser.stop(); remoteTarget = nil
        receiverPicker.isHidden = !remote
        if remote {
            receiverPicker.menu = nil; receiverPicker.isEnabled = false
            receiverPicker.setTitle("正在搜索 iPad 接收端…", for: .normal)
            receiverBrowser.start()
        }
        let title = remote ? "连接到 iPad" : local ? "本机 CarPlay" : "CarPlay 接收屏"
        let headingText = NSMutableAttributedString(string: title)
        if local, let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            headingText.append(NSAttributedString(string: "（\(version)）", attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: UIColor.secondaryLabel
            ]))
        }
        heading.attributedText = headingText
        explanation.text = remote ? "选择一台 iPad，把这台 iPhone 的 CarPlay 投送到它的屏幕。"
            : local ? "无需外接盒子，直接在这台 iPhone 上启动并显示 CarPlay。" : "接收另一台 iPhone 的导航、音乐和触控画面。"
        connectionHelp.text = remote
            ? "让 iPhone 和 iPad 连接同一个 Wi-Fi。"
            : local ? "先在系统设置连接 Wi-Fi，再在 CarWithin 选择对应预设。"
            : "先启动此接收屏，再从另一台 iPhone 发起连接。"
        refreshNetworkSummary()
        refreshVideoOutputSummary()
        refreshVehicleProfileTitle()
        startButton.isEnabled = identity != nil
        identitySetupButton.isHidden = identity != nil
        startButton.configuration?.image = UIImage(systemName: "play.fill")
        startButton.setTitle(remote ? "连接到 iPad" : local ? "启动本机 CarPlay" : "启动 CarPlay 接收屏", for: .normal)
        statusLabel.text = identity == nil ? "需要导入 MFi 身份" : remote ? "请选择接收端" : "准备就绪"
        refreshCurrentNetwork(requestPermission: false)
    }
    private func setEditing(_ value: Bool) {
        [nameField, ipField, ssidField, passwordField, channelField, videoOutputPortField, secureVideoOutputPortField].forEach { $0.isEnabled = value }
        openNetworkSwitch.isEnabled = value
        videoOutputSwitch.isEnabled = value && outputMode == .browser
        orientationControl.isEnabled = value
        resolutionControl.isEnabled = value
        aspectRatioControl.isEnabled = value
        frameRateControl.isEnabled = value
        codecControl.isEnabled = value
        [sizeModeControl, iconSizeControl, performanceControl].forEach { $0.isEnabled = value }
        [autoRestartSwitch, showTouchesSwitch, carButtonSwitch].forEach { $0.isEnabled = value }
        driveControl.isEnabled = value
        bluetoothSetupSwitch.isEnabled = value
        transportProbeButton.isEnabled = value
        headUnitOutput.isEnabled = value
        zeehoAddressField.isEnabled = value
        ninebotAutoConnectSwitch.isEnabled = value
        ninebotCurrentWiFiSwitch.isEnabled = value
        ninebotAddressField.isEnabled = value
        ninebot43AddressField.isEnabled = value
        tailingAddressField.isEnabled = value
        carLifeAddressField.isEnabled = value
    }
    @objc private func willResignActive() {
        guard running else { return }
        // Normally already running; retry if foreground activation failed.
        if keepAliveSwitch.isOn { keepAlive.start() }
        pictureInPicture.awaitAutomaticStart()
    }
    @objc private func becameActive() {
        refreshNetworkAddresses()
        attemptNinebotAutoConnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.checkForUpdates(manual: false)
        }
        pictureInPicture.returnedToForeground()
        resumeLocalVideo()
        pictureInPicture.sourceMayBeReady()
        if running, keepAliveSwitch.isOn { keepAlive.start() }
        if let reason = pendingRestartReason {
            pendingRestartReason = nil
            restartCarPlay(reason: reason, forPerformance: true)
        } else {
            scheduleScreenAdaptation()
        }
    }
    @objc private func pictureInPictureTimingChanged() {
        UserDefaults.standard.set(pictureInPictureTiming.selectedSegmentIndex, forKey: "pictureInPictureTiming")
        UserDefaults.standard.set(pictureInPictureTiming.selectedSegmentIndex != 0, forKey: "pictureInPictureEnabled")
        didRequestImmediatePiP = false
        pictureInPicture.cancelPendingStart()
        updatePictureInPicturePolicy()
    }

    private func updatePictureInPicturePolicy() {
        let timing = pictureInPictureTiming.selectedSegmentIndex
        pictureInPicture.setAutomatic(running && displayedVideo && timing != 0)
        guard running, displayedVideo, timing == 2, !didRequestImmediatePiP,
              presentedViewController == nil else { return }
        didRequestImmediatePiP = true
        _ = pictureInPicture.start()
    }

    // MARK: Follow the head unit

    private func browserReportedDisplay(_ display: BrowserDisplay?, viewerID: UUID?) {
        guard running else { return }
        reportedScreen = display.map(CarScreenStore.record)
        primaryViewer = viewerID
        refreshScreenMenu()
        scheduleScreenAdaptation()
    }

    private func scheduleScreenAdaptation() {
        screenAdaptation?.cancel(); screenAdaptation = nil
        guard running, reportedScreen != nil, modeControl.selectedSegmentIndex == 1 else { return }
        // Refresh rate and viewport reports can arrive separately. Apply the settled plan once.
        let work = DispatchWorkItem { [weak self] in self?.adaptToPrimaryScreen() }
        screenAdaptation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func adaptToPrimaryScreen() {
        guard running, UIApplication.shared.applicationState == .active,
              let screen = reportedScreen, let live = liveDisplay else { return }
        let wanted = planDisplay(for: screen)
        // Ignore differences under 4 %: rounding, or a browser bar appearing.
        func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) * 25 <= max(a, b) }
        let sizeChanged = !(near(wanted.width, live.width) && near(wanted.height, live.height))
        var changes: [String] = []
        if sizeChanged { changes.append("\(live.width)×\(live.height) → \(wanted.width)×\(wanted.height)") }
        if wanted.fps != live.fps { changes.append("\(live.fps) → \(wanted.fps) FPS") }
        if wanted.codec != live.codec { changes.append("\(live.codec.displayName) → \(wanted.codec.displayName)") }
        if wanted.iconWidthMM != live.iconWidthMM { changes.append("图标大小") }
        guard !changes.isEmpty else { return }
        restartCarPlay(reason: "跟随主接收屏幕（\(changes.joined(separator: "，"))）")
    }
    private func browserStruggling(peer: String, reason: String) {
        log("浏览器 \(peer) 持续卡顿（\(reason)）")
        guard autoRestartSwitch.isOn, running, lightLevel < 2 else { return }
        lightLevel += 1
        requestRestart(reason: lightLevel == 1 ? "画面卡顿，改用 30 FPS" : "画面卡顿，改用 720P")
    }
    private func requestRestart(reason: String) {
        guard autoRestarts < 2 else { log("本次连接已自动重启 2 次，不再重启：\(reason)"); return }
        // Restarting off screen would drop the background keep-alive; wait until the app is back.
        guard UIApplication.shared.applicationState == .active else {
            pendingRestartReason = reason; log("回到 CarWithin 后重启：\(reason)"); return
        }
        restartCarPlay(reason: reason, forPerformance: true)
    }
    private func restartCarPlay(reason: String, forPerformance: Bool = false) {
        guard running, modeControl.selectedSegmentIndex == 1 else { return }
        if forPerformance {
            guard autoRestarts < 2 else { return }
            autoRestarts += 1
        }
        log("自动重启 CarPlay：\(reason)")
        let keepScreen = reportedScreen, keepViewer = primaryViewer, level = lightLevel, count = autoRestarts
        recordConnection(.preparing, "自动重连：\(reason)")
        stop(preserveDiagnostics: true)
        statusLabel.text = "正在按新的画面设置重启 CarPlay…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.running else { return }
            self.reportedScreen = keepScreen; self.primaryViewer = keepViewer
            self.lightLevel = level; self.autoRestarts = count
            self.restartingAutomatically = true
            self.toggleReceiver()
            self.restartingAutomatically = false
        }
    }

    /// The car button on the CarPlay home screen: 120 px, a white car on the app's blue.
    private static let carButtonIcon: Data? = {
        let size = CGSize(width: 120, height: 120)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(red: 0.18, green: 0.55, blue: 1, alpha: 1).cgColor, UIColor(red: 0.04, green: 0.32, blue: 0.86, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            let symbol = UIImage(systemName: "car.side.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 58, weight: .semibold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            if let symbol {
                symbol.draw(in: CGRect(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height))
            }
        }
        return image.pngData()
    }()
    private func resumeLocalVideo() {
        guard running else { return }
        videoSurface.resumeAfterBackground(skippedFrames: skippedLocalVideo)
        skippedLocalVideo = false
    }
    @objc private func foregrounded() {
        refreshNetworkAddresses()
        guard running else {
            if !waitingForNetwork { modeChanged() }
            return
        }
        // Light/dark changes were ignored while off screen; send the current state once.
        DispatchQueue.main.async { [weak self] in self?.applyAppearance() }
    }
    @objc private func backgrounded() {
        updateCheckTask?.cancel()
        receiverBrowser.stop()
        guard running else { return }
        // willResignActive may have failed to start it (e.g. the session was busy); try once more
        // before deciding the session cannot survive in the background.
        if keepAliveSwitch.isOn, !keepAlive.isRunning, keepAlive.start() { log("后台保持在进入后台时重试成功") }
        if canRunInBackground {
            log(keepAlive.isRunning ? "App 已进入后台，CarPlay 继续运行" : "App 已进入后台，由画中画保持运行")
        } else {
            log("App 已进入后台且没有画中画或后台保持，iOS 会挂起 App，已停止 CarPlay")
            stop()
        }
    }
    @objc private func copyLog() { UIPasteboard.general.string = lines.joined(separator: "\n") }
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lines.append("\(timestamp)  \(message)"); if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        if logView.window != nil {
            logView.text = lines.joined(separator: "\n")
            if !logView.text.isEmpty { logView.scrollRangeToVisible(NSRange(location: logView.text.utf16.count - 1, length: 1)) }
        }
        NSLog("[CarWithin] %@", message)
    }
}

// MARK: - Settings pages

extension ReceiverViewController {
    /// Initial values and change handlers for every setting control. The controls live on the
    /// settings pages; the rest of this controller reads them directly.
    fileprivate func configureSettingsControls() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didApplyLeftHandDefaultV2") {
            defaults.set(false, forKey: "rightHandDrive"); defaults.set(true, forKey: "didApplyLeftHandDefaultV2")
        }
        if !defaults.bool(forKey: "didApplyBrowserDefaultV3") {
            defaults.set(true, forKey: "videoOutputEnabled"); defaults.set(60, forKey: "displayMaxFPS")
            defaults.set(true, forKey: "didApplyBrowserDefaultV3")
        }
        driveControl.selectedSegmentIndex = defaults.bool(forKey: "rightHandDrive") ? 1 : 0
        driveControl.addTarget(self, action: #selector(driveChanged), for: .valueChanged)
        orientationControl.selectedSegmentIndex = defaults.bool(forKey: "portraitDisplay") ? 1 : 0
        orientationControl.addTarget(self, action: #selector(orientationChanged), for: .valueChanged)
        resolutionControl.selectedSegmentIndex = min(ReceiverConfiguration.resolutions.count - 1, max(0,
            defaults.object(forKey: "displayResolutionIndex") as? Int ?? ReceiverConfiguration.defaultResolutionIndex))
        aspectRatioControl.selectedSegmentIndex = ReceiverConfiguration.aspectRatios.firstIndex {
            $0.title == defaults.string(forKey: "displayAspectRatio")
        }.map { $0 + 1 } ?? 0
        sizeModeControl.selectedSegmentIndex = defaults.object(forKey: "displaySizeMode") as? Int ?? 0
        frameRateControl.selectedSegmentIndex = [0: 0, 30: 1, 60: 2][defaults.object(forKey: "displayMaxFPS") as? Int ?? 60] ?? 2
        codecControl.selectedSegmentIndex = ["auto": 0, "h264": 1, "h265": 2][defaults.string(forKey: "videoCodec") ?? "h264"] ?? 1
        let savedWidth = defaults.object(forKey: "widthPhysicalMM") as? Int ?? CarPlayInfo.defaultWidthPhysicalMM
        iconSizeControl.selectedSegmentIndex = ReceiverConfiguration.iconSizes.firstIndex { $0.widthMM == savedWidth } ?? 1
        performanceControl.selectedSegmentIndex = BrowserPerformance.allCases.firstIndex(of:
            BrowserPerformance(rawValue: defaults.string(forKey: "browserPerformance") ?? "") ?? .auto) ?? 0
        autoRestartSwitch.isOn = defaults.object(forKey: "autoRestart") as? Bool ?? false
        showTouchesSwitch.isOn = defaults.bool(forKey: "showTouches")
        carButtonSwitch.isOn = defaults.object(forKey: "carButton") as? Bool ?? true
        let displayControls: [UIControl] = [resolutionControl, aspectRatioControl, sizeModeControl, frameRateControl, codecControl, iconSizeControl,
                                            performanceControl, autoRestartSwitch, showTouchesSwitch, carButtonSwitch]
        displayControls.forEach { $0.addTarget(self, action: #selector(displaySettingChanged), for: .valueChanged) }
        appearanceControl.selectedSegmentIndex = defaults.integer(forKey: "carPlayAppearance")
        appearanceControl.addTarget(self, action: #selector(appearanceChanged), for: .valueChanged)
        passwordField.isSecureTextEntry = true
        showWiFiPasswordSwitch.addTarget(self, action: #selector(showWiFiPasswordChanged), for: .valueChanged)
        pasteWiFiPassword.target = passwordField
        httpsMode.selectedSegmentIndex = HTTPSConfiguration.mode.rawValue
        httpsMode.addTarget(self, action: #selector(httpsModeChanged), for: .valueChanged)
        httpsDomainField.text = HTTPSConfiguration.domain
        httpsDomainField.keyboardType = .URL
        httpsTokenField.isSecureTextEntry = true
        httpsStatus.text = "修改地址或证书后，重新启动 CarPlay 生效。"
        httpsTokenField.text = (try? HTTPSConfiguration.secret("duckToken")).flatMap { String(data: $0, encoding: .utf8) }
        httpsDomainField.addTarget(self, action: #selector(saveHTTPSFields), for: .editingDidEnd)
        httpsTokenField.addTarget(self, action: #selector(saveHTTPSFields), for: .editingDidEnd)
        passwordField.textContentType = .password
        ipField.keyboardType = .decimalPad
        let legacyPiPEnabled = defaults.object(forKey: "pictureInPictureEnabled") as? Bool ?? true
        pictureInPictureTiming.selectedSegmentIndex = defaults.object(forKey: "pictureInPictureTiming") as? Int ?? (legacyPiPEnabled ? 1 : 0)
        pictureInPictureTiming.addTarget(self, action: #selector(pictureInPictureTimingChanged), for: .valueChanged)
        keepAliveSwitch.isOn = defaults.object(forKey: "backgroundKeepAlive") as? Bool ?? true
        keepAliveSwitch.addTarget(self, action: #selector(keepAliveChanged), for: .valueChanged)
        let savedOutput = defaults.object(forKey: "headUnitOutputV2") as? Int
        let previousOutput = defaults.object(forKey: "headUnitOutput") as? Int
        let legacyOutput: HeadUnitOutput = defaults.bool(forKey: "carLifeEnabled") ? .carLife : .browser
        let migratedOutput = previousOutput.map { $0 == 1 ? HeadUnitOutput.carLife : .browser } ?? legacyOutput
        headUnitOutput.selectedSegmentIndex = (savedOutput.flatMap(HeadUnitOutput.init(rawValue:)) ?? migratedOutput).rawValue
        headUnitOutput.addTarget(self, action: #selector(headUnitOutputChanged), for: .valueChanged)
        zeehoAddressField.text = defaults.string(forKey: "zeehoAddress") ?? "192.168.0.1"
        zeehoAddressField.keyboardType = .decimalPad
        zeehoAddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        ninebotAddressField.text = defaults.string(forKey: "ninebotAddress") ?? "192.168.1.1"
        ninebotAddressField.keyboardType = .decimalPad
        ninebotAddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        ninebot43AddressField.text = defaults.string(forKey: "ninebot43Address") ?? "192.168.169.1"
        ninebot43AddressField.keyboardType = .decimalPad
        ninebot43AddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        tailingAddressField.text = defaults.string(forKey: "tailingAddress") ?? "192.168.1.1"
        tailingAddressField.keyboardType = .decimalPad
        tailingAddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        carLifeAddressField.text = defaults.string(forKey: "carLifeAddress")
        carLifeAddressField.keyboardType = .decimalPad
        carLifeAddressField.addTarget(self, action: #selector(saveHeadUnitOutput), for: .editingDidEnd)
        updateCarLifeStatus("等待启动 CarPlay。")
        updateAirPlayStatus("等待启动 CarPlay。")
        videoOutputSwitch.isOn = defaults.object(forKey: "videoOutputEnabled") as? Bool ?? true
        videoOutputSwitch.addTarget(self, action: #selector(videoOutputToggled), for: .valueChanged)
        videoOutputPortField.text = String(defaults.object(forKey: "videoOutputPort") as? Int ?? 9888)
        secureVideoOutputPortField.text = (defaults.object(forKey: "secureVideoOutputPort") as? Int).map { String($0) }
        for (field, label) in [(videoOutputPortField, "HTTP 端口"), (secureVideoOutputPortField, "HTTPS 端口")] {
            field.keyboardType = .numberPad
            field.accessibilityLabel = label
            field.addTarget(self, action: #selector(videoOutputSettingChanged), for: .editingChanged)
            field.addTarget(self, action: #selector(saveBrowserPorts), for: .editingDidEnd)
            let toolbar = UIToolbar()
            toolbar.items = [.flexibleSpace(), UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak field] _ in
                field?.resignFirstResponder()
            })]
            toolbar.sizeToFit()
            field.inputAccessoryView = toolbar
        }
        nameField.addTarget(self, action: #selector(receiverNameChanged), for: .editingDidEnd)
        channelField.keyboardType = .numberPad
        [nameField, ipField, ssidField, passwordField, channelField, carLifeAddressField, tailingAddressField, ninebotAddressField, ninebot43AddressField, zeehoAddressField, videoOutputPortField, secureVideoOutputPortField, httpsDomainField, httpsTokenField].forEach {
            $0.returnKeyType = .done
            $0.addTarget($0, action: #selector(UIResponder.resignFirstResponder), for: .editingDidEndOnExit)
            if $0.inputAccessoryView == nil {
                let field = $0
                let toolbar = UIToolbar()
                toolbar.items = [.flexibleSpace(), UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak field] _ in
                    field?.resignFirstResponder()
                })]
                toolbar.sizeToFit()
                field.inputAccessoryView = toolbar
            }
        }
    }

    @objc private func saveHeadUnitOutput() {
        UserDefaults.standard.set(outputMode.rawValue, forKey: "headUnitOutputV2")
        UserDefaults.standard.set(carLifeAddressField.text ?? "", forKey: "carLifeAddress")
        UserDefaults.standard.set(zeehoAddressField.text ?? "", forKey: "zeehoAddress")
        UserDefaults.standard.set(ninebotAddressField.text ?? "", forKey: "ninebotAddress")
        UserDefaults.standard.set(ninebot43AddressField.text ?? "", forKey: "ninebot43Address")
        UserDefaults.standard.set(tailingAddressField.text ?? "", forKey: "tailingAddress")
        refreshVideoOutputSummary()
    }
    @objc private func headUnitOutputChanged() {
        saveHeadUnitOutput()
        refreshVideoOutputSummary()
        updateVideoAspect()
        reloadVisibleSettings()
    }
    @objc private func audioSettingChanged() {
        UserDefaults.standard.set(selectedSoundOutput.rawValue, forKey: "soundOutput")
    }
    @objc private func receiverNameChanged() {
        guard !running else { return }
        UserDefaults.standard.set(nameField.text ?? "CarWithin", forKey: "receiverName")
    }

    /// Shows settings and, when needed, takes the user to the relevant connection settings.
    func revealSettings(wifi: Bool = false, output: Bool = false, showIdentity: Bool = false) {
        view.endEditing(true)
        if let navigation = settingsNavigation {
            if showIdentity {
                navigation.popToRootViewController(animated: false)
                navigation.pushViewController(identityPage(), animated: true)
                return
            }
            if wifi, activeWiFiForm == nil {
                navigation.popToRootViewController(animated: false)
                navigation.pushViewController(wifiPage(), animated: true)
            }
            return
        }
        let root = rootSettingsPage()
        let navigation = UINavigationController(rootViewController: root)
        navigation.navigationBar.prefersLargeTitles = false
        root.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.settingsNavigation?.view.endEditing(true)
            self?.settingsNavigation?.dismiss(animated: true) { self?.settingsDismissed() }
        })
        navigation.presentationController?.delegate = self
        if wifi { navigation.pushViewController(wifiPage(), animated: false) }
        if output { navigation.pushViewController(headUnitPage(), animated: false) }
        if showIdentity { navigation.pushViewController(identityPage(), animated: false) }
        settingsNavigation = navigation
        present(navigation, animated: true)
    }

    fileprivate func settingsDismissed() {
        view.endEditing(true)
        UserDefaults.standard.set(nameField.text ?? "CarWithin", forKey: "receiverName")
        saveHeadUnitOutput()
        saveActiveVehicleProfile()
        refreshNetworkSummary(); refreshVideoOutputSummary(); updateVideoAspect()
        updatePictureInPicturePolicy()
    }

    private var editingLockedFooter: String? { running ? "CarPlay 运行中，停止后才能修改这些设置。" : nil }
    private func onOff(_ toggle: UISwitch) -> () -> String? { { toggle.isOn ? "开" : "关" } }
    private func page(_ title: String, _ build: @escaping () -> [SettingsSection]) -> SettingsPageController {
        SettingsPageController(title: title, build: build)
    }
    private func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        (settingsNavigation ?? self).present(alert, animated: true)
    }

    private func aboutLinks() -> [SettingsRow] {
        [
            .externalLink("GitHub 项目", icon: ("chevron.left.forwardslash.chevron.right", .systemIndigo)) {
                UIApplication.shared.open(Self.projectURL)
            },
            .action("检查更新", icon: ("arrow.clockwise.circle.fill", .systemBlue), detail: { [unowned self] in
                self.checkingForUpdates ? "检查中…" : nil
            }) { [unowned self] in self.checkForUpdates() },
            .action("版本记录", icon: ("clock.arrow.circlepath", .systemPurple)) { [unowned self] in
                self.showVersionHistory()
            }
        ]
    }

    private func usagePage() -> SettingsPageController {
        page("使用说明") {
            [
                SettingsSection("1. 先连 Wi-Fi", [
                    .guide("让 iPhone 加入 Wi-Fi", icon: ("wifi", .systemBlue),
                           "路由器、车机 Wi-Fi 或另一台手机的热点都可以。有网、没网都能投屏。运行 CarWithin 的 iPhone 需要实际加入 Wi-Fi，自己开热点不能代替这一步。"),
                    .guide("选择同名预设", icon: ("list.bullet", .systemBlue),
                           "回到 CarWithin，在「Wi-Fi 预设」选择刚连的网络。第一次用，在「Wi-Fi 与网络」添加。")
                ]),
                SettingsSection("2. 选一种输出", [
                    .guide("浏览器", icon: ("globe", .systemTeal),
                           "车机连同一个 Wi-Fi。在「当前输出」选浏览器，启动 CarPlay，再用车机打开首页显示的 HTTP 地址。"),
                    .guide("车机或仪表", icon: ("car.fill", .systemIndigo),
                           "使用仪表时先加入仪表 Wi-Fi，再按首页连接卡的顺序操作。CarLife 先打开车机上的 CarLife；AirPlay 在首页选接收设备。")
                ]),
                SettingsSection("3. 常见问题", [
                    .guide("卡在正在连接", icon: ("arrow.clockwise", .systemOrange),
                           "核对 iPhone 连的 Wi-Fi 和预设是否同名。仍连不上，关开一次 Wi-Fi，回到 App 重新启动。"),
                    .guide("网页打不开或没有画面", icon: ("exclamationmark.circle", .systemOrange),
                           "先核对两台设备的 Wi-Fi 和首页地址。能打开但没画面时，先试 HTTP，再把画面设为 H.264、720P、30 帧。"),
                    .guide("仪表没有画面", icon: ("display", .systemPurple),
                           "确认选对仪表型号、仪表已打开投屏，并在「输出设置」核对仪表 IP。先结束其他投屏。")
                ])
            ]
        }
    }

    private func httpsHelpPage() -> SettingsPageController {
        page("HTTPS 低延迟") {
            [
                SettingsSection("从 HTTP 接收页开始", footer: "在接收设备上打开 HTTP 接收页，点「配置 HTTPS」，再按页面步骤为该设备安装证书。", []),
                SettingsSection("iPhone 和 iPad", footer: "下载描述文件后，在系统设置安装，再前往「通用 › 关于本机 › 证书信任设置」开启完全信任，最后打开 HTTPS 地址。", []),
                SettingsSection("Android", footer: "下载 Android 证书，按接收页指引在系统设置中安装为 CA 证书，再打开 HTTPS 地址。系统菜单名称随品牌而异。", [])
            ]
        }
    }

    private var installedAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var canAutomaticallyCheckUpdates: Bool {
        UIApplication.shared.applicationState == .active && !running
            && viewIfLoaded?.window != nil && presentedViewController == nil
    }

    private func checkForUpdates(manual: Bool = true) {
        guard UIApplication.shared.applicationState == .active, !checkingForUpdates else { return }
        if !manual {
            guard canAutomaticallyCheckUpdates, AppUpdatePolicy().shouldCheck() else { return }
        }
        checkingForUpdates = true
        reloadVisibleSettings()
        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.checkingForUpdates = false
                self.updateCheckTask = nil
                self.reloadVisibleSettings()
            }
            do {
                let release = try await AppReleaseService().latest()
                try Task.checkCancellation()
                guard UIApplication.shared.applicationState == .active else { return }
                if manual {
                    guard self.settingsNavigation?.viewIfLoaded?.window != nil else { return }
                    AppUpdatePolicy().succeeded()
                    self.showVersionDetails(release, automatic: false)
                } else {
                    guard self.canAutomaticallyCheckUpdates else { return }
                    AppUpdatePolicy().succeeded()
                    if AppUpdatePolicy().shouldOffer(release, installedBuild: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0) {
                        self.showVersionDetails(release, automatic: true)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                AppUpdatePolicy().failed()
                if manual, self.settingsNavigation?.viewIfLoaded?.window != nil {
                    self.alert("检查更新失败", error.localizedDescription)
                }
            }
        }
    }

    private func showVersionHistory() {
        let history = ReleaseHistoryView(installed: installedAppVersion, canDownload: { [weak self] in
            self?.running == false && UIApplication.shared.applicationState == .active
        })
        let controller = UIHostingController(rootView: NavigationStack {
            history.toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { [weak self] in self?.updateSheet?.dismiss(animated: true) }
                }
            }
        })
        presentReleaseController(controller, automatic: false)
    }

    private func showVersionDetails(_ release: AppRelease, automatic: Bool) {
        let details = ReleaseDetailView(
            release: release, installed: installedAppVersion, latestTag: release.tag_name,
            canDownload: { [weak self] in
                self?.running == false && UIApplication.shared.applicationState == .active
            }, automatic: automatic, close: { [weak self] in
                self?.updateSheet?.dismiss(animated: true)
            })
        presentReleaseController(UIHostingController(rootView: NavigationStack { details }), automatic: automatic)
    }

    private func presentReleaseController(_ controller: UIViewController, automatic: Bool) {
        let presenter = settingsNavigation ?? self
        guard presenter.presentedViewController == nil else { return }
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [.large()]
        updateSheet = controller
        updateSheetAutomatic = automatic
        controller.presentationController?.delegate = self
        presenter.present(controller, animated: true)
    }

    // MARK: Root

    fileprivate func rootSettingsPage() -> SettingsPageController {
        page("设置") { [unowned self] in
            var connection: [SettingsRow] = [
                .page("使用说明", icon: ("book.fill", .systemOrange)) { [unowned self] in self.usagePage() },
                .page("车辆配置", icon: ("scooter", .systemBlue), detail: { [unowned self] in self.currentVehicleName }) { [unowned self] in self.vehicleProfilesPage() }
            ]
            if needsNetworkDetails {
                connection.append(.page("Wi-Fi 与网络", icon: ("wifi", .systemBlue), detail: { [unowned self] in
                    self.running || self.waitingForNetwork ? nil : "添加"
                }) { [unowned self] in self.wifiForm(adding: true) })
            }
            connection.append(.page("Wi-Fi 预设", icon: ("list.bullet", .systemBlue), detail: { WiFiPresetStore.selected()?.ssid ?? "未选择" }) { [unowned self] in self.presetsPage() })
            connection.append(.control("当前输出", icon: ("point.3.connected.trianglepath.dotted", .systemIndigo), headUnitOutput))
            connection.append(.page("输出设置", icon: ("slider.horizontal.3", .systemGray)) { [unowned self] in self.headUnitPage() })
            if outputMode == .browser {
                connection.append(.page("HTTPS 设置", icon: ("lock.shield", .systemBlue)) { [unowned self] in self.httpsSettingsPage() })
            }
            return [
                SettingsSection("连接与输出", connection),
                SettingsSection("CarPlay", [
                    .control("出画后自动全屏", icon: ("arrow.up.left.and.arrow.down.right", .systemBlue), autoFullscreenSwitch),
                    .page("画面", icon: ("rectangle.on.rectangle", .systemGreen), detail: { [unowned self] in
                        self.outputMode.usesInstrumentWiFi ? "仪表固定尺寸" : self.followsCarScreen ? "跟随车机" : self.resolutionControl.selectedTitle.components(separatedBy: "（").first
                    }) { [unowned self] in self.displayPage() },
                    .control("CarPlay 外观", icon: ("circle.lefthalf.filled", .systemBlue), appearanceControl),
                    .page("声音", icon: ("speaker.wave.2.fill", .systemOrange), detail: { [unowned self] in
                        switch self.soundOutput {
                        case .carWithin: return "接收设备播放"
                        case .phone: return "iPhone 输出"
                        case .browser: return "Wi-Fi 伴音"
                        }
                    }) { [unowned self] in self.soundPage() },
                    .control("驾驶位", icon: ("steeringwheel", .systemTeal), driveControl),
                    .page("电池与 BMS", icon: ("battery.100", .systemGreen), detail: { [unowned self] in
                        self.bmsEnabledSwitch.isOn ? self.bmsClient.selectedName : "关闭"
                    }) { [unowned self] in self.bmsPage() },
                    .page("车辆", icon: ("car.fill", .systemTeal)) { [unowned self] in self.vehiclePage() }
                ]),
                SettingsSection("后台与画中画", footer: "锁屏前，请在 iPhone「设置 › 通用 › CarPlay › CarWithin」中打开「锁定时允许 CarPlay」。后台运行会增加耗电。画中画仅显示实时画面。离开 App 时自动开启需打开 iPhone「设置 › 通用 › 画中画」中的自动选项。", [
                    .control("锁屏与后台继续运行", icon: ("lock.fill", .systemPurple), keepAliveSwitch),
                    .control("画中画开启时机", icon: ("pip.fill", .systemIndigo), pictureInPictureTiming)
                ]),
                SettingsSection("支持", [
                    .externalLink("关注作者", icon: ("heart.fill", .systemRed), detail: "抖音") {
                        UIApplication.shared.open(Self.authorURL)
                    },
                    .externalLink("请我喝杯咖啡", icon: ("cup.and.saucer.fill", .systemOrange), detail: "支付宝") {
                        UIApplication.shared.open(Self.supportURL)
                    },
                    .page("诊断与实验", icon: ("stethoscope", .systemTeal)) { [unowned self] in self.diagnosticsPage() },
                    .page("关于", icon: ("info.circle.fill", .systemGray)) { [unowned self] in self.aboutPage() }
                ])
            ]
        }
    }

    // MARK: CarPlay 画面

    private var currentVehicleName: String {
        VehicleProfileStore.profiles().first { $0.id == VehicleProfileStore.selectedID }?.name ?? headUnitOutput.selectedTitle
    }

    private func configureExperience() {
        autoFullscreenSwitch.isOn = UserDefaults.standard.bool(forKey: "autoFullscreen")
        autoFullscreenSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(self.autoFullscreenSwitch.isOn, forKey: "autoFullscreen")
            self.saveActiveVehicleProfile()
        }, for: .valueChanged)
        if let data = UserDefaults.standard.data(forKey: "lastConnectionTimeline.v1") {
            connectionTimeline = try? JSONDecoder().decode(ConnectionTimeline.self, from: data)
        }
        refreshConnectionReport()
        refreshVehicleProfileTitle()
    }

    private func refreshVehicleProfileTitle() {
        vehicleProfileButton.setTitle("\(currentVehicleName) · 车辆配置", for: .normal)
        vehicleProfileButton.accessibilityLabel = "车辆配置，\(currentVehicleName)"
    }

    private func capturedVehicle(id: UUID, name: String) -> VehicleProfile {
        let address: String
        switch outputMode {
        case .zeeho: address = zeehoAddressField.text ?? ""
        case .tailing: address = tailingAddressField.text ?? ""
        case .carLife: address = carLifeAddressField.text ?? ""
        default: address = activeNinebotAddressField.text ?? ""
        }
        return VehicleProfile(id: id, name: name, output: outputMode.rawValue, ssid: ssidField.text ?? "",
            channel: UInt8(channelField.text ?? "") ?? 36, openNetwork: openNetworkSwitch.isOn,
            instrumentAddress: address, bmsID: bmsClient.selectedID, bmsName: bmsClient.selectedName,
            bmsEnabled: bmsEnabledSwitch.isOn, cardFields: bmsCardConfiguration.fields.map(\.rawValue),
            cardSize: bmsCardConfiguration.size.rawValue, cardPosition: bmsPosition.selectedSegmentIndex,
            autoConnect: ninebotAutoConnectSwitch.isOn, currentWiFiExperiment: ninebotCurrentWiFiSwitch.isOn,
            keepAlive: keepAliveSwitch.isOn, autoFullscreen: autoFullscreenSwitch.isOn,
            cardBackground: bmsCardConfiguration.background.rawValue)
    }

    private func saveActiveVehicleProfile() {
        guard !applyingVehicleProfile, let id = VehicleProfileStore.selectedID,
              let previous = VehicleProfileStore.profiles().first(where: { $0.id == id }) else { return }
        let channel = UInt8(channelField.text ?? "") ?? 36
        guard let ssid = ssidField.text, (1...32).contains(ssid.utf8.count), !ssid.contains("\0"),
              (1...196).contains(channel) else { return }
        do { try VehicleProfileStore.save(capturedVehicle(id: id, name: previous.name)) }
        catch { log("车辆配置保存失败：\(error.localizedDescription)") }
        refreshVehicleProfileTitle()
    }

    private func vehicleProfilesPage() -> SettingsPageController {
        page("车辆配置") { [unowned self] in
            let locked = self.running || self.waitingForNetwork
            let rows = VehicleProfileStore.profiles().map { profile -> SettingsRow in
                var row = SettingsRow.action(profile.name, detail: {
                    (HeadUnitOutput(rawValue: profile.output).map { _ in profile.ssid }) ?? "请重新配置"
                }) { [unowned self] in self.applyVehicleProfile(profile) }
                row.checked = { VehicleProfileStore.selectedID == profile.id }
                if !locked {
                    row.onDelete = { [unowned self] in
                        do { try VehicleProfileStore.remove(profile.id); self.refreshVehicleProfileTitle() }
                        catch { self.alert("删除失败", error.localizedDescription) }
                    }
                }
                return row
            }
            var sections = [SettingsSection("已保存车辆", footer: locked ? "停止连接后可切换或保存车辆。" :
                "先设置仪表、Wi-Fi、BMS 和卡片样式，再保存为车辆。切换车辆会恢复该车配置；密码按 SSID 从 Keychain 读取。", rows)]
            if !locked {
                sections.append(SettingsSection([
                    .action("将当前设置存为新车辆", icon: ("plus.circle", .systemBlue)) { [unowned self] in self.promptVehicleName() },
                    .action("更新当前车辆配置", icon: ("square.and.arrow.down", .systemBlue)) { [unowned self] in
                        guard VehicleProfileStore.selectedID != nil else {
                            self.alert("尚未选择车辆", "先将当前设置保存为新车辆。保持现有连接设置即可。")
                            return
                        }
                        self.saveActiveVehicleProfile(); self.reloadVisibleSettings()
                    }
                ]))
            }
            return sections
        }
    }

    private func promptVehicleName() {
        guard !running, !waitingForNetwork else { return }
        view.endEditing(true)
        guard saveCurrentWiFiPreset() else {
            alert("先配置 Wi-Fi", passwordStatus.text ?? "请保存车辆的 Wi-Fi 名称。")
            return
        }
        let prompt = UIAlertController(title: "保存车辆配置", message: "保存当前仪表、Wi-Fi、BMS 和显示设置。", preferredStyle: .alert)
        prompt.addTextField { $0.placeholder = "例如：九号五寸"; $0.text = self.headUnitOutput.selectedTitle }
        prompt.addAction(UIAlertAction(title: "取消", style: .cancel))
        prompt.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak prompt] _ in
            guard let self, !self.running, !self.waitingForNetwork else { return }
            let name = String((prompt?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            guard !name.isEmpty else {
                self.alert("未填写车辆名称", "填写名称后再保存。")
                return
            }
            self.saveActiveVehicleProfile()
            do {
                try VehicleProfileStore.save(self.capturedVehicle(id: UUID(), name: name))
                self.refreshVehicleProfileTitle(); self.reloadVisibleSettings()
            } catch { self.alert("保存失败", error.localizedDescription) }
        })
        (settingsNavigation ?? self).present(prompt, animated: true)
    }

    private func applyVehicleProfile(_ profile: VehicleProfile) {
        guard !running, !waitingForNetwork, !applyingVehicleProfile else { return }
        guard let output = HeadUnitOutput(rawValue: profile.output), (1...196).contains(profile.channel),
              (1...32).contains(profile.ssid.utf8.count), !profile.ssid.contains("\0") else {
            alert("车辆配置无效", "请重新保存该车辆的仪表和 Wi-Fi 配置。")
            return
        }
        view.endEditing(true)
        saveActiveVehicleProfile()
        finishBMSSession()
        applyingVehicleProfile = true
        defer { applyingVehicleProfile = false }
        bmsClient.stop()
        headUnitOutput.selectedSegmentIndex = output.rawValue
        switch output {
        case .zeeho: zeehoAddressField.text = profile.instrumentAddress
        case .tailing: tailingAddressField.text = profile.instrumentAddress
        case .carLife: carLifeAddressField.text = profile.instrumentAddress
        default: activeNinebotAddressField.text = profile.instrumentAddress
        }
        WiFiPresetStore.upsert(ssid: profile.ssid, channel: profile.channel, isOpen: profile.openNetwork)
        applyWiFiPreset(WiFiPreset(ssid: profile.ssid, channel: profile.channel, isOpen: profile.openNetwork))
        bmsClient.restoreSelection(id: profile.bmsID, name: profile.bmsName)
        bmsEnabledSwitch.isOn = profile.bmsEnabled
        bmsCardConfiguration = ANTBMSCardConfiguration(savedFields: profile.cardFields, sizeRawValue: profile.cardSize,
            positionRawValue: profile.cardPosition, backgroundRawValue: profile.cardBackground)
        bmsPosition.selectedSegmentIndex = bmsCardConfiguration.position.rawValue
        bmsCardBackground.selectedSegmentIndex = bmsCardConfiguration.background.rawValue
        bmsCardSize.selectedSegmentIndex = bmsCardConfiguration.size.rawValue
        for (field, control) in bmsFieldSwitches { control.isOn = bmsCardConfiguration.fields.contains(field) }
        ninebotAutoConnectSwitch.isOn = profile.autoConnect
        ninebotCurrentWiFiSwitch.isOn = profile.currentWiFiExperiment
        keepAliveSwitch.isOn = profile.keepAlive
        autoFullscreenSwitch.isOn = profile.autoFullscreen
        let defaults = UserDefaults.standard
        defaults.set(profile.autoConnect, forKey: "ninebotAutoConnect")
        defaults.set(profile.currentWiFiExperiment, forKey: "ninebotCurrentWiFi")
        defaults.set(profile.keepAlive, forKey: "backgroundKeepAlive")
        defaults.set(profile.autoFullscreen, forKey: "autoFullscreen")
        defaults.set(profile.bmsEnabled, forKey: "antBMSEnabled")
        defaults.set(bmsPosition.selectedSegmentIndex, forKey: "antBMSPosition")
        saveBMSCardConfiguration()
        VehicleProfileStore.select(profile.id)
        saveHeadUnitOutput()
        if profile.bmsEnabled { bmsClient.start() }
        attemptedNinebotAutoConnect = false
        modeChanged(); refreshVehicleProfileTitle(); reloadVisibleSettings()
        statusLabel.text = "已切换到 \(profile.name)"
    }

    private func beginConnectionTimeline() {
        lastReceiverMessage = nil
        connectionTimeline = ConnectionTimeline(output: headUnitOutput.selectedTitle,
            uptime: ProcessInfo.processInfo.systemUptime)
        recordConnection(.preparing, outputMode.ninebotMode != nil
            ? "开始连接；仪表自动激活仍需官方投屏流程" : "开始 CarPlay 连接")
    }

    private func recordConnection(_ stage: ConnectionTimeline.Stage, _ detail: String) {
        connectionTimeline?.record(stage, detail: detail, uptime: ProcessInfo.processInfo.systemUptime)
        if let timeline = connectionTimeline, let data = try? JSONEncoder().encode(timeline) {
            UserDefaults.standard.set(data, forKey: "lastConnectionTimeline.v1")
        }
        refreshConnectionReport()
    }

    private func refreshConnectionReport() {
        guard let timeline = connectionTimeline else { connectionReportStatus.text = "暂无连接记录。启动一次 CarPlay 后生成报告。"; return }
        let timing = timeline.firstVideoSeconds.map { String(format: "首个视频关键帧：%.1f 秒\n", $0) } ?? "尚未收到视频关键帧\n"
        connectionReportStatus.text = "输出：\(timeline.output)\n" + timing + timeline.events.map {
            String(format: "+%.1f 秒 · %@：%@", $0.elapsed, $0.stage.title, $0.detail)
        }.joined(separator: "\n")
    }

    private func connectionReportData() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let timeline: Any = try connectionTimeline.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) } ?? NSNull()
        let report: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "iOS": UIDevice.current.systemVersion, "device": UIDevice.current.model,
            "localWiFiAddress": ReceiverConfiguration.wifiIPv4Address() ?? "",
            "bmsStatus": bmsClient.status, "timeline": timeline,
            "instrumentActivation": "尚未实现独立激活；仪表是否出画需实物确认"]
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    }

    private func connectionReportPage() -> SettingsPageController {
        page("连接诊断报告") { [unowned self] in
            [SettingsSection("最近一次连接", footer: "记录连接阶段和耗时，保留最近 64 条；不包含 Wi-Fi 密码或身份私钥。", [.note(self.connectionReportStatus)]),
             SettingsSection([
                .page("预览并导出报告", icon: ("square.and.arrow.up", .systemBlue)) { [unowned self] in
                    self.reportPreviewPage(title: "连接报告预览", name: "CarWithin-connection-report.json", data: { try self.connectionReportData() })
                },
                .page("运行日志", icon: ("doc.text", .systemGray)) { [unowned self] in self.logPage() }
             ])]
        }
    }

    private func reportPreviewPage(title: String, name: String, data: () throws -> Data) -> SettingsPageController {
        do {
            let snapshot = try data()
            let text = UITextView(); text.isEditable = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.text = String(data: snapshot, encoding: .utf8)
            text.heightAnchor.constraint(equalToConstant: 360).isActive = true
            return page(title) { [weak self] in
                [SettingsSection(footer: "以下为本次导出的完整内容。", [.view(text)]), SettingsSection([
                    .action("复制报告", icon: ("doc.on.doc", .systemBlue)) { UIPasteboard.general.string = text.text },
                    .action("分享 JSON 文件", icon: ("square.and.arrow.up", .systemBlue)) {
                        self?.shareReport(snapshot, name: name)
                    }
                ])]
            }
        } catch {
            return page(title) { [SettingsSection([.info("报告生成失败", error.localizedDescription)])] }
        }
    }

    private func shareReport(_ data: Data, name: String) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CarWithinReports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            let presenter: UIViewController = settingsNavigation ?? self
            sheet.popoverPresentationController?.sourceView = presenter.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            presenter.present(sheet, animated: true)
        } catch { alert("无法导出", error.localizedDescription) }
    }

    private func beginBMSSessionIfNeeded() {
        guard bmsEnabledSwitch.isOn, bmsSessionStartedAt == nil else { return }
        bmsSession = ANTBMSSessionStatistics(); bmsTrend.points = []
        bmsSessionMinimumUptime = ProcessInfo.processInfo.systemUptime
        lastBMSSaveUptime = bmsSessionMinimumUptime
        bmsSessionRecordID = UUID()
        bmsSessionStartedAt = Date(); bmsSessionVehicle = currentVehicleName; bmsSessionDevice = bmsClient.selectedID
        bmsSessionStatus.text = "等待新的 BMS 实时数据"
    }

    private func finishBMSSession() {
        guard bmsSessionStartedAt != nil else { return }
        checkpointBMSSession(completed: true)
        bmsSessionStartedAt = nil
        reloadVisibleSettings()
    }

    private func checkpointBMSSession(completed: Bool) {
        guard let startedAt = bmsSessionStartedAt else { return }
        guard bmsSession.sampleCount > 0 else { return }
        let record = BMSRideRecord(id: bmsSessionRecordID, startedAt: startedAt, endedAt: Date(),
            vehicleName: bmsSessionVehicle, statistics: bmsSession, completed: completed)
        do { try BMSRideRecordStore.save(record) }
        catch { log("BMS 记录保存失败，本次统计仍可导出：\(error.localizedDescription)") }
    }

    private func bmsStatisticsText(_ statistics: ANTBMSSessionStatistics) -> String {
        guard statistics.sampleCount > 0 else { return "暂无有效样本。启动 CarPlay 且开启 BMS 后自动记录，也可手动开始。" }
        let charge = statistics.firstCharge.flatMap { first in statistics.lastCharge.map { "\(first)% → \($0)%" } } ?? "--"
        return String(format: "有效采样 %.0f 秒 · %d 帧\n电量 %@\n全程电压 %.2f–%.2f V\n峰值电流 |I| %.1f A · 峰值功率 |P| %ld W\n最高温度 %@ · 最大压差 %@",
            statistics.sampledSeconds, statistics.sampleCount, charge, statistics.minimumVoltage ?? 0, statistics.maximumVoltage ?? 0,
            statistics.peakAbsoluteCurrent, statistics.peakAbsolutePower,
            statistics.maximumTemperature.map { String(format: "%.0f°C", $0) } ?? "--",
            statistics.maximumCellDelta.map { String(format: "%.0f mV", $0 * 1000) } ?? "--")
    }

    private func bmsStatisticsPage() -> SettingsPageController {
        page("BMS 统计与记录") { [unowned self] in
            var sections = [SettingsSection(self.bmsSessionStartedAt == nil ? "本次统计" : "正在记录", footer:
                "有效采样时长不计入断线间隔；峰值取绝对值。记录电池读数，不计算里程、每公里耗电或预计续航。", [.note(self.bmsSessionStatus), .view(self.bmsTrend)])]
            var controls: [SettingsRow] = []
            if self.bmsSessionStartedAt != nil {
                controls.append(.action("结束并保存本次记录", icon: ("stop.circle", .systemBlue)) { [unowned self] in
                    self.finishBMSSession(); self.reloadVisibleSettings()
                })
            } else {
                controls.append(.action("开始新记录", icon: ("record.circle", .systemBlue)) { [unowned self] in
                    guard self.bmsEnabledSwitch.isOn else { self.alert("先开启 BMS", "在电池与 BMS 页面开启读取并连接自己的设备。"); return }
                    self.beginBMSSessionIfNeeded(); self.reloadVisibleSettings()
                })
            }
            controls.append(.page("预览并导出本次统计", icon: ("square.and.arrow.up", .systemBlue)) { [unowned self] in
                self.reportPreviewPage(title: "BMS 统计预览", name: "CarWithin-bms-statistics.json", data: {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    return try encoder.encode(self.bmsSession)
                })
            })
            sections.append(SettingsSection(controls))
            let history = BMSRideRecordStore.records().map { record -> SettingsRow in
                let date = DateFormatter.localizedString(from: record.startedAt, dateStyle: .short, timeStyle: .short)
                let activelyRecording = self.bmsSessionStartedAt != nil && record.id == self.bmsSessionRecordID
                var row = SettingsRow.page("\(record.vehicleName) · \(date)", detail: {
                    activelyRecording ? "记录中" : record.completed ? "已结束" : "已保存片段"
                }) { [unowned self] in self.bmsRecordPage(record) }
                if self.bmsSessionStartedAt == nil || record.id != self.bmsSessionRecordID {
                    row.onDelete = { [unowned self] in
                        do { try BMSRideRecordStore.remove(record.id) } catch { self.alert("删除失败", error.localizedDescription) }
                    }
                }
                return row
            }
            sections.append(SettingsSection("最近记录", footer: "保存在本机，最多保留 20 次，每 15 秒保存片段。趋势保留最近 120 个五秒区间的最低、最高和最新电压；全程范围包含全部有效帧。断线不会用直线补齐。停止 CarPlay 或关闭 BMS 时完成记录。", history))
            return sections
        }
    }

    private func bmsRecordPage(_ record: BMSRideRecord) -> SettingsPageController {
        let summary = StatusLabel(); summary.text = bmsStatisticsText(record.statistics)
        let trend = BMSVoltageTrendView(); trend.points = record.statistics.points
        return page(record.vehicleName) { [unowned self] in
            [SettingsSection("电池记录", footer: record.completed ? "已结束并保存。" : "这是最近保存的片段，可能尚未正常结束。", [.note(summary), .view(trend)]),
             SettingsSection([.page("预览并导出记录", icon: ("square.and.arrow.up", .systemBlue)) { [unowned self] in
                 self.reportPreviewPage(title: "记录预览", name: "CarWithin-bms-\(record.id.uuidString).json", data: {
                     let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                     encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                     return try encoder.encode(record)
                 })
             }])]
        }
    }

    private func identityPage() -> SettingsPageController {
        page("CarPlay 身份") { [unowned self] in
            [
                SettingsSection("当前状态", footer: "身份用于本机 CarPlay 配件认证，与 IPA 安装签名不同。BMS 蓝牙读取不需要此身份。", [
                    .info("身份", self.identity == nil ? "未载入" : "已载入"),
                    .note(self.identityImportStatus)
                ]),
                SettingsSection("从已有材料导入", footer: "选择你原来可用的 CarWithin IPA。只在本机读取证书与对应私钥，校验匹配后存入此 App 的 Keychain，不上传、不修改原文件。安装包不含材料时会提示。", [
                    .action("从原版 IPA 导入", icon: ("square.and.arrow.down", .systemBlue)) { [unowned self] in self.chooseIdentityFiles(ipa: true) },
                    .action("选择三个身份文件", icon: ("doc.on.doc", .systemGray)) { [unowned self] in self.chooseIdentityFiles(ipa: false) }
                ]),
                SettingsSection("说明", [
                    .guide("所需文件", icon: ("doc.fill", .systemOrange), "certificate.p7b、leaf.cer、private.x963。三个文件必须属于同一身份。"),
                    .guide("导入后", icon: ("checkmark.shield", .systemGreen), "本地匹配校验通过后可以尝试启动；最终认证是否接受仍由 iOS 决定。停止 CarPlay 后才能导入。")
                ])
            ]
        }
    }

    private func chooseIdentityFiles(ipa: Bool) {
        guard !running, !waitingForNetwork else {
            alert("请先停止连接", "停止 CarPlay 和 Wi-Fi 连接后再导入身份。")
            return
        }
        documentImportPurpose = ipa ? .identityIPA : .identityFiles
        // .item also allows IPA/X9.63 files that have no registered type on iOS.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = !ipa
        picker.delegate = self
        (settingsNavigation ?? self).present(picker, animated: true)
    }

    private func importIdentitySelection(_ urls: [URL], fromIPA: Bool) {
        guard !running, !waitingForNetwork else { return }
        let access = urls.map { $0.startAccessingSecurityScopedResource() }
        defer {
            for (url, granted) in zip(urls, access) where granted { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let imported: AccessoryIdentity
            if fromIPA {
                guard urls.count == 1, let url = urls.first else { throw MFiIdentityArchive.Failure.invalidArchive }
                imported = try AccessoryIdentityStore.importFromIPA(url)
            } else {
                imported = try AccessoryIdentityStore.importSelectedFiles(urls)
            }
            identity = imported
            modeChanged()
            statusLabel.text = "身份已导入，可以尝试启动 CarPlay。"
            identityImportStatus.text = "证书与私钥本地匹配校验通过，已保存到本机 Keychain。最终认证由 iOS 确认。"
            log("用户选择的身份已通过本地匹配校验并存入 Keychain")
        } catch {
            identityImportStatus.text = "导入失败：\(error.localizedDescription)"
            if identity == nil { statusLabel.text = "身份未导入，请在「CarPlay 身份」查看原因。" }
            log("身份导入失败，未启动 CarPlay")
        }
        reloadVisibleSettings()
    }

    private func bmsPage() -> SettingsPageController {
        page("电池与 BMS") { [unowned self] in
            [SettingsSection("蚂蚁 ANT BMS", [
                .control("读取并显示 BMS", self.bmsEnabledSwitch),
                .note(self.bmsStatus),
                .page("连接设备", icon: ("antenna.radiowaves.left.and.right", .systemBlue), detail: { [unowned self] in
                    self.bmsClient.selectedName
                }) { [unowned self] in self.bmsDevicesPage() }
            ]),
            SettingsSection("实时电池", footer: "只显示最近 5 秒内的有效数据，断开后自动清空旧值。", [.view(self.bmsLiveSummary)]),
            SettingsSection("显示与记录", [
                .page("卡片显示", icon: ("rectangle.topthird.inset.filled", .systemBlue), detail: { [unowned self] in
                    "\(self.bmsCardConfiguration.fields.count) 项 · \(self.bmsCardConfiguration.size.title)号"
                }) { [unowned self] in self.bmsCardPage() },
                .page("本次统计与记录", icon: ("chart.xyaxis.line", .systemGreen)) { [unowned self] in self.bmsStatisticsPage() },
                .page("电池详情", icon: ("list.bullet.rectangle", .systemGray)) { [unowned self] in
                    self.page("电池详情") { [unowned self] in
                        [SettingsSection("实时参数", footer: "电流保留 ANT 原始符号。容量、温度、串数和状态由 BMS 上报。", [.note(self.bmsDetails)])]
                    }
                }
            ])]
        }
    }

    private func bmsDevicesPage() -> SettingsPageController {
        page("BMS 连接设备") { [unowned self] in
            var sections = [SettingsSection("当前设备", [
                .info("已记住的设备", self.bmsClient.selectedName),
                .note(self.bmsStatus)
            ])]
            guard self.bmsEnabledSwitch.isOn else {
                sections.append(SettingsSection(footer: "开启读取后搜索并选择自己的 ANT BMS。", [
                    .action("开启读取并查找设备", icon: ("antenna.radiowaves.left.and.right", .systemBlue)) { [unowned self] in
                        self.bmsEnabledSwitch.setOn(true, animated: false)
                        self.bmsSettingsChanged()
                    }
                ]))
                return sections
            }
            sections.append(SettingsSection(footer: "选定后会记住并自动重连。连接不上时，先断开其他 BMS App。", [
                .action("扫描附近 BMS", icon: ("antenna.radiowaves.left.and.right", .systemBlue)) { [unowned self] in self.bmsClient.scan() },
                .action("忘记当前 BMS", destructive: true) { [unowned self] in
                    self.bmsClient.forget()
                    self.reloadVisibleSettings()
                }
            ]))
            let devices = self.bmsClient.devices.map { device in
                var row = SettingsRow.action(device.name, detail: { "\(device.rssi) dBm" }) { [unowned self] in
                    self.bmsClient.select(device.id)
                }
                row.checked = { [weak self] in self?.bmsClient.selectedID == device.id }
                return row
            }
            sections.append(SettingsSection("附近设备", footer: "仅支持 ANT FFE0/FFE1 实时通道。扫描到 FFE0 不代表协议兼容，收到有效 ANT 数据后才确认连接。",
                devices.isEmpty ? [.info("暂无设备", "点击上方扫描")] : devices))
            return sections
        }
    }

    private func bmsCardPage() -> SettingsPageController {
        bmsCardPreview.update(reading: bmsClient.freshReading, configuration: bmsCardConfiguration,
                             aspectRatio: outputMode == .ninebotSeven ? 1024 / 600 : 848 / 480)
        return page("BMS 卡片显示") { [unowned self] in
            var sections = [SettingsSection("布局", footer: "修改后立即同步到手机和九号五寸、七寸投屏，并自动保存。卡片最多两行；减少显示项可留出更多地图空间。", [
                .control("字号", self.bmsCardSize),
                .control("显示位置", self.bmsPosition),
                .control("背景", self.bmsCardBackground),
                .page("字段顺序", icon: ("arrow.up.arrow.down", .systemBlue)) { [unowned self] in
                    BMSCardOrderViewController(fields: self.bmsCardConfiguration.fields) { [weak self] field, destination in
                        guard let self else { return }
                        self.bmsCardConfiguration.move(field, to: destination)
                        self.saveBMSCardConfiguration()
                    }
                }
            ])]
            sections.append(SettingsSection("布局预览", footer: "背景为布局示意，比例随所选仪表变化。没有实时读数时使用示例数据，示例不会写入电池记录或投屏画面。", [
                .note(self.bmsCardPreviewStatus), .view(self.bmsCardPreview)
            ]))
            sections.append(SettingsSection("快捷布局", [
                .action("精简：电量、总压、压差", icon: ("minus.circle", .systemBlue)) { [unowned self] in
                    self.applyBMSCardPreset(ANTBMSCardConfiguration.compactFields)
                },
                .action("常用：显示全部六项", icon: ("square.grid.2x2", .systemBlue)) { [unowned self] in
                    self.applyBMSCardPreset(ANTBMSCardConfiguration.Field.allCases)
                }
            ]))
            let fields = ANTBMSCardConfiguration.Field.allCases.compactMap { field -> SettingsRow? in
                guard let control = self.bmsFieldSwitches[field] else { return nil }
                return .control(field.title, control)
            }
            sections.append(SettingsSection("显示内容", footer: "至少保留一项。单体压差以 mV 显示；未知读数显示 --，BMS 告警会保留提示。", fields))
            return sections
        }
    }

    #if DEBUG
    /// Deterministic simulator fixtures, isolated from BMS history and live data.
    private func bmsTrendPreview(legacy: Bool) -> SettingsPageController {
        var statistics = ANTBMSSessionStatistics()
        for second in 0...370 {
            let voltage = second == 0 ? 86.93 : second == 2 ? 83.67 :
                86.0 + 0.5 * sin(Double(second) / 35)
            let reading = ANTBMSReading(voltage: voltage, current: -12.3, power: -1018, stateOfCharge: 98,
                stateOfHealth: nil, stateCode: 4, capacityAh: 170, remainingAh: 167,
                cells: [4.1, 4.106], temperatures: [24], mosTemperature: 25,
                protectionBits: 0, warningBits: 0)
            statistics.append(ANTBMSSample(reading: reading, uptime: Double(second)), now: Double(second))
        }
        if legacy, let encoded = try? JSONEncoder().encode(statistics),
           var values = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] {
            values["points"] = stride(from: 0, through: 370, by: 5).map { second in
                ["elapsed": Double(second), "voltage": second == 0 ? 86.93 : 86.0 + 0.5 * sin(Double(second) / 35)]
            }
            if let data = try? JSONSerialization.data(withJSONObject: values),
               let restored = try? JSONDecoder().decode(ANTBMSSessionStatistics.self, from: data) { statistics = restored }
        }
        let label = StatusLabel(); label.text = bmsStatisticsText(statistics)
        let trend = BMSVoltageTrendView(); trend.points = statistics.points
        return page(legacy ? "旧记录预览" : "压降测试预览") {
            [SettingsSection("模拟数据", footer: "仅供开发验证，不会保存到电池记录。", [.note(label), .view(trend)])]
        }
    }
    #endif

    fileprivate func displayPage() -> SettingsPageController {
        page("画面") { [unowned self] in
            if outputMode == .zeeho {
                return [
                    SettingsSection("极核 6.2 寸", [.info("仪表画面", "1024×480 · H.264 · 25 FPS")]),
                    SettingsSection("图标", [.control("CarPlay 图标大小", icon: ("square.grid.2x2.fill", .systemPurple), iconSizeControl)])
                ]
            }
            if let mode = outputMode.ninebotMode {
                let format: String
                switch mode {
                case .fiveInch: format = "848×480 · H.264 · 最高 30 FPS"
                case .sevenInch: format = "1024×600 · H.264 · 最高 25 FPS"
                case .fourThreeInch: format = "480×272 · JPEG · 最高 10 FPS"
                }
                return [
                    SettingsSection(headUnitOutput.selectedTitle, [
                        .info("仪表画面", format)
                    ]),
                    SettingsSection("图标", [.control("CarPlay 图标大小", icon: ("square.grid.2x2.fill", .systemPurple), iconSizeControl)])
                ]
            }
            if outputMode == .tailing {
                return [
                    SettingsSection("台铃 4.3 寸", footer: "选择台铃输出时自动使用匹配的画面参数；切回其他输出后恢复原设置。", [
                        .info("仪表画面", "480×272 · JPEG · 最高 20 FPS"),
                        .info("本机 CarPlay", "960×544 · H.264 · 30 FPS")
                    ]),
                    SettingsSection("图标", [.control("CarPlay 图标大小", icon: ("square.grid.2x2.fill", .systemPurple), iconSizeControl)])
                ]
            }
            var size: [SettingsRow] = [.control("画面尺寸", icon: ("aspectratio.fill", .systemGreen), sizeModeControl)]
            if followsCarScreen {
                size.append(.page("车机屏幕", icon: ("display", .systemGreen), detail: { [unowned self] in
                    self.targetScreen?.title ?? "尚未记录"
                }) { [unowned self] in self.screensPage() })
            }
            size.append(.control(followsCarScreen ? "最高分辨率" : "分辨率", icon: ("arrow.up.left.and.arrow.down.right", .systemGreen), resolutionControl))
            if !followsCarScreen {
                size.append(.control("画面比例", icon: ("aspectratio", .systemGreen), aspectRatioControl))
            }
            if UIDevice.current.userInterfaceIdiom == .pad, modeControl.selectedSegmentIndex != 2 {
                size.append(.control("CarPlay 方向", icon: ("rotate.right.fill", .systemGreen), orientationControl))
            }
            let plan = planDisplay(for: targetScreen)
            return [
                SettingsSection(footer: (followsCarScreen
                    ? "启动时先用勾选的屏幕或最近一次设置。第一个网页接管后，窗口尺寸变化会在 CarWithin 回到前台时应用。更大的窗口按最高分辨率等比缩小。"
                    : "选择比例后按分辨率档位计算尺寸，短边至少 320 像素，实际值见下方。2K/4K 会增加发热和带宽。")
                    + (!followsCarScreen && outputMode != .browser ? "\n此输出受 1920×1080 限制，较长的竖屏比例以实际尺寸为准。" : "")
                    + "\n下次启动：\(plan.width)×\(plan.height) · \(plan.fps) FPS · \(plan.codec.displayName)", size),
                SettingsSection(footer: "自动帧率根据主网页选择 30 或 60 FPS。支持 H.265 的主网页会优先使用 H.265。", [
                    .control("视频编码", icon: ("film.fill", .systemGreen), codecControl),
                    .control("帧率", icon: ("gauge.with.dots.needle.67percent", .systemGreen), frameRateControl)
                ]),
                SettingsSection(footer: "浏览器画面持续卡顿时，自动以更轻的画面重启 CarPlay（先降到 30 FPS，再降到 720P），每次连接最多两次。", [
                    .control("自动重启", icon: ("arrow.clockwise", .systemGreen), autoRestartSwitch)
                ]),
                SettingsSection("图标", footer: "图标越小，一页放下的越多。可以在「车机屏幕」为不同屏幕保存图标大小。", [
                    .control("CarPlay 图标大小", icon: ("square.grid.2x2.fill", .systemPurple), iconSizeControl)
                ]),
                SettingsSection(footer: editingLockedFooter, [])
            ].filter { !$0.rows.isEmpty || $0.footer != nil }
        }
    }

    /// Third level: screens "跟随车机" has recorded. Tap to tick, swipe to delete.
    fileprivate func screensPage() -> SettingsPageController {
        page("车机屏幕") { [unowned self] in
            let screens = CarScreenStore.screens()
            guard !screens.isEmpty else {
                return [SettingsSection(footer: "启动 CarPlay 后，在车机浏览器打开接收页，屏幕会自动记录在这里。", [])]
            }
            var rows: [SettingsRow] = screens.map { screen in
                var row = SettingsRow.action(screen.title) { CarScreenStore.setDefault(screen.key) }
                row.subtitle = { screen.subtitle }
                row.checked = { CarScreenStore.defaultKeyValue == screen.key }
                row.onDelete = { [unowned self] in
                    CarScreenStore.remove(screen.key)
                    if self.reportedScreen?.key == screen.key { self.reportedScreen = nil }
                }
                return row
            }
            var latest = SettingsRow.action("不勾选，使用最近一次") { CarScreenStore.setDefault(nil) }
            latest.checked = { CarScreenStore.defaultKeyValue == nil }
            rows.append(latest)
            let iconRows = screens.map { screen in
                SettingsRow.page(screen.title, detail: {
                    ReceiverConfiguration.iconSizes.first { $0.widthMM == screen.iconWidthMM }?.title ?? "跟随默认"
                }) { [unowned self] in
                    self.screenIconSizePage(key: screen.key, title: screen.title)
                }
            }
            return [
                SettingsSection(footer: "启动时使用勾选的屏幕。左滑可删除。", rows),
                SettingsSection("按屏幕设置图标大小", iconRows)
            ]
        }
    }

    private func screenIconSizePage(key: String, title: String) -> SettingsPageController {
        page(title) {
            guard let screen = CarScreenStore.screens().first(where: { $0.key == key }) else { return [] }
            let choices: [(title: String, width: Int?)] =
                [("跟随默认", nil)] + ReceiverConfiguration.iconSizes.map { ($0.title, Optional($0.widthMM)) }
            let rows = choices.map { choice in
                var row = SettingsRow.action(choice.title) { CarScreenStore.setIconWidth(choice.width, for: key) }
                row.checked = { screen.iconWidthMM == choice.width }
                return row
            }
            return [SettingsSection(footer: "设置会在下次使用这块屏幕时应用。", rows)]
        }
    }

    // MARK: 声音 / 车辆

    fileprivate func soundPage() -> SettingsPageController {
        page("声音") { [unowned self] in
            guard outputMode == .browser else {
                let phone = SoundOutput.phone
                return [SettingsSection(footer: phone.explanation, [.info("声音输出", "由 iPhone 输出")])]
            }
            let choices = SoundOutput.allCases.filter { output in
                switch output {
                case .carWithin: return receivesAudioFromAnotherDevice
                case .phone: return true
                case .browser: return videoOutputSwitch.isOn
                }
            }
            let rows = choices.map { output in
                let icons = ["speaker.wave.2.fill", "iphone", "wifi"]
                var row = SettingsRow.action(output.title, icon: (icons[output.rawValue], .systemOrange)) { [unowned self] in
                    guard !self.running else {
                        self.alert("请先停止 CarPlay", "停止后即可修改声音输出。")
                        return
                    }
                    self.selectedSoundOutput = output
                    self.audioSettingChanged()
                }
                row.subtitle = { output.explanation }
                row.checked = { [unowned self] in self.soundOutput == output }
                return row
            }
            let footer = videoOutputSwitch.isOn
                ? "更改在下次启动 CarPlay 时生效。使用 Wi-Fi 伴音时，通话和 Siri 留在 iPhone。"
                : "打开局域网接收页后可使用 Wi-Fi 伴音。更改在下次启动 CarPlay 时生效。"
            return [SettingsSection(footer: footer, rows)]
        }
    }

    fileprivate func vehiclePage() -> SettingsPageController {
        page("车辆") { [unowned self] in
            var sections: [SettingsSection] = []
            if modeControl.selectedSegmentIndex != 2 {
                sections.append(SettingsSection(footer: "车辆名称显示在 iPhone 的 CarPlay 车辆列表中。", [
                    .field("车辆名称", nameField, placeholder: "CarWithin")
                ]))
            }
            var button: [SettingsRow] = [.control("显示车辆按钮", icon: ("car.side.fill", .systemTeal), carButtonSwitch)]
            if let data = customVehicleIcon ?? Self.carButtonIcon, let image = UIImage(data: data) {
                let thumbnail = UIImageView(image: image)
                thumbnail.layer.cornerRadius = 8
                thumbnail.clipsToBounds = true
                thumbnail.widthAnchor.constraint(equalToConstant: 36).isActive = true
                thumbnail.heightAnchor.constraint(equalToConstant: 36).isActive = true
                let preview = UILabel()
                preview.text = customVehicleIcon == nil ? "当前图标 · 默认" : "当前图标 · 自选图片"
                preview.font = .preferredFont(forTextStyle: .body)
                let row = UIStackView(arrangedSubviews: [thumbnail, preview])
                row.spacing = 12; row.alignment = .center
                button.append(.view(row))
            }
            if importingVehicleIcon {
                button.append(.info("正在读取照片…", ""))
            } else if !running {
                button.append(.action("从照片选择图标", icon: ("photo", .systemBlue)) { [unowned self] in
                    self.pickVehicleIcon()
                })
                if customVehicleIcon != nil {
                    button.append(.action("恢复默认图标") { [unowned self] in
                        UserDefaults.standard.removeObject(forKey: Self.customVehicleIconKey)
                        self.reloadVisibleSettings()
                    })
                }
            }
            let footer = running ? "停止 CarPlay 后可更换图标。" : "图片会居中裁成正方形，下次启动 CarPlay 时生效。"
            sections.append(SettingsSection("CarPlay 车辆按钮", footer: footer, button))
            return sections
        }
    }

    private func pickVehicleIcon() {
        guard !running, !importingVehicleIcon else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        (settingsNavigation ?? self).present(picker, animated: true)
    }

    private static func vehicleIconPNG(at url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let size = CGSize(width: 120, height: 120)
        let image = UIImage(cgImage: thumbnail)
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
        }
    }

    // MARK: Wi-Fi

    fileprivate func wifiPage() -> SettingsPageController { wifiForm(adding: false) }

    private func wifiForm(adding: Bool) -> SettingsPageController {
        let editable = !running && !waitingForNetwork
        let form = UUID()
        let previous = (ssidField.text, passwordField.text, channelField.text,
                        openNetworkSwitch.isOn, passwordLoadedForSSID, passwordStatus.text)
        let isAdding = adding && editable
        if isAdding {
            ssidField.text = ""; passwordField.text = ""; channelField.text = "36"
            openNetworkSwitch.isOn = false; passwordLoadedForSSID = nil; passwordStatus.text = nil
        }
        activeWiFiForm = form
        showWiFiPasswordSwitch.isOn = false
        passwordField.isSecureTextEntry = true
        let title = isAdding ? "添加 Wi-Fi" : editable ? "编辑 Wi-Fi" : "Wi-Fi 与网络"
        let controller = page(title) { [unowned self] in
            var current: [SettingsRow] = []
            if canDetectWiFiName && editable {
                current.append(.action("读取当前 Wi-Fi", icon: ("antenna.radiowaves.left.and.right", .systemBlue)) { [unowned self] in
                    guard !self.running else { return }
                    self.detectNetwork()
                })
            }
            if editable {
                current.append(.action("重新读取本 App 已存密码", icon: ("key.fill", .systemBlue)) { [unowned self] in
                    let hadText = !(self.passwordField.text ?? "").isEmpty
                    self.loadWiFiPassword()
                    if hadText {
                        self.passwordStatus.text = "密码框已有内容，已保留。可开启「显示密码」核对；重新读取不会覆盖当前输入。"
                    }
                    self.reloadVisibleSettings()
                })
            }
            var fields: [SettingsRow] = []
            if modeControl.selectedSegmentIndex == 0 {
                fields.append(.field("本机 IP 地址", ipField))
            }
            fields += [
                .field("Wi-Fi 名称", ssidField),
                .field("密码", passwordField, placeholder: prefersCurrentWiFiStartup ? "复用当前连接可留空（实验）" : "首次填写，保存后自动读取"),
                .control("开放网络（无密码）", openNetworkSwitch),
                .field("兼容信道", channelField, placeholder: "36")
            ]
            var sections: [SettingsSection] = []
            if !current.isEmpty { sections.append(SettingsSection(current)) }
            sections.append(SettingsSection(footer: editingLockedFooter ?? "返回自动保存。同名网络会更新原预设，兼容信道通常保持 36。", fields))
            if editable {
                sections.append(SettingsSection(footer: "读取当前 Wi-Fi 可获取名称，密码仅从本 App 已保存的配置读取，无法获取系统保存的 Wi-Fi 密码。首次可从系统设置复制后粘贴。", [
                    .control("粘贴密码", self.pasteWiFiPassword),
                    .control("显示密码", self.showWiFiPasswordSwitch)
                ]))
            }
            if editable {
                sections.append(SettingsSection(footer: prefersCurrentWiFiStartup
                    ? "有已保存密码时直接使用配置启动，避免先等待免密码实验。只有未填密码时才尝试复用当前网络。"
                    : "可先读取当前 Wi-Fi 名称。已连接所选网络时直接复用；未连接时申请加入。首次配置密码仍需填写，后续自动读取。", [
                    .action("保存并加入 Wi-Fi", icon: ("wifi", .systemBlue)) { [unowned self] in
                        self.joinSelectedWiFi(startCarPlay: false)
                    }
                ]))
            }
            if editable, passwordStatus.text?.isEmpty == false { sections.append(SettingsSection([.note(passwordStatus)])) }
            return sections
        }
        controller.onLeave = { [weak self] in
            guard let self, self.activeWiFiForm == form else { return }
            self.showWiFiPasswordSwitch.isOn = false
            self.passwordField.isSecureTextEntry = true
            self.activeWiFiForm = nil
            self.awaitingNetworkPermission = false
            guard editable, !self.running, !self.waitingForNetwork else { return }
            let hasName = !(self.ssidField.text ?? "").isEmpty
            if hasName, self.saveCurrentWiFiPreset() {
                self.refreshNetworkSummary()
                return
            }
            let reason = hasName ? self.passwordStatus.text : nil
            (self.ssidField.text, self.passwordField.text, self.channelField.text,
             self.openNetworkSwitch.isOn, self.passwordLoadedForSSID, self.passwordStatus.text) = previous
            self.refreshNetworkSummary()
            if let reason {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.alert("Wi-Fi 未保存", reason)
                }
            }
        }
        return controller
    }

    /// Select, edit or remove a saved Wi-Fi preset.
    fileprivate func presetsPage() -> SettingsPageController {
        page("Wi-Fi 预设") { [unowned self] in
            let presets = WiFiPresetStore.presets()
            let editable = !running && !waitingForNetwork
            guard !presets.isEmpty else {
                return [SettingsSection(footer: editable ? "添加预设后，切换网络时可直接选用。" : editingLockedFooter, editable ? [
                    .page("添加 Wi-Fi", icon: ("plus", .systemBlue)) { [unowned self] in self.wifiForm(adding: true) }
                ] : [])]
            }
            let rows = presets.map { preset in
                var row = SettingsRow.action(preset.ssid) { [unowned self] in if editable { self.applyWiFiPreset(preset) } }
                row.subtitle = {
                    if preset.isOpen { return "开放网络" }
                    let password = try? WiFiCredentials.password(for: preset.ssid)
                    return password?.isEmpty == false ? "已保存密码" : "未保存密码，仅可复用当前连接（实验）"
                }
                row.checked = { WiFiPresetStore.selected()?.ssid == preset.ssid }
                row.onDelete = { [unowned self] in
                    guard !self.running else { return }
                    do { try WiFiCredentials.forget(preset.ssid) }
                    catch { self.alert("删除失败", "无法删除保存的密码，请重试。"); return }
                    WiFiPresetStore.remove(preset.ssid)
                    if self.ssidField.text == preset.ssid {
                        if let next = WiFiPresetStore.selected() { self.applyWiFiPreset(next) }
                        else {
                            self.ssidField.text = ""; self.passwordField.text = ""
                            self.passwordLoadedForSSID = nil; self.openNetworkSwitch.isOn = false
                            self.refreshNetworkSummary()
                        }
                    }
                }
                if !editable { row.onDelete = nil }
                return row
            }
            var sections = [SettingsSection(footer: editable ? "轻点选用，左滑后确认删除。" : editingLockedFooter, rows)]
            if editable {
                sections.append(SettingsSection([.page("编辑当前预设", icon: ("pencil", .systemBlue)) { [unowned self] in self.wifiPage() }]))
            }
            return sections
        }
    }

    // MARK: 输出方式

    fileprivate func headUnitPage() -> SettingsPageController {
        page("输出设置") { [unowned self] in
            switch outputMode {
            case .browser: return browserOutputSections()
            case .carLife: return carLifeOutputSections()
            case .airPlay: return airPlayOutputSections()
            case .tailing: return tailingOutputSections()
            case .zeeho:
                return [SettingsSection("极核 AE4 MAX2+ 6.2 寸", footer: "让 iPhone 加入仪表 Wi-Fi，选择同名预设。结束其他投屏，打开仪表投屏后启动 CarPlay。声音由 iPhone 或蓝牙输出。", [
                    .field("仪表 IP 地址", zeehoAddressField, placeholder: "192.168.0.1"),
                    .note(zeehoStatus)
                ])]
            case .ninebot, .ninebotSeven, .ninebot43:
                var sections = [SettingsSection(headUnitOutput.selectedTitle, footer: outputMode == .ninebot ? ninebotInstructions : "\(ninebotInstructions) 切换 App 前请打开「锁屏与后台继续运行」。", [
                    .control("打开 App 自动连接", ninebotAutoConnectSwitch),
                    .action("连接并启动 CarPlay", icon: ("wifi", .systemBlue)) { [unowned self] in
                        self.joinSelectedWiFi(startCarPlay: true)
                    },
                    .field("仪表 IP 地址", activeNinebotAddressField, placeholder: outputMode == .ninebot43 ? "192.168.169.1" : "192.168.1.1"),
                    .note(ninebotStatus)
                ])]
                if supportsCurrentWiFiStartup {
                    sections.append(SettingsSection(footer: "已有密码时始终优先发送已保存的 Wi-Fi 配置，不等待免密码实验。只有未填密码且已确认连上所选仪表网络时才尝试省略配置；12 秒未连接会提示补全密码。", [
                        .control("无密码时尝试当前 Wi-Fi（实验）", ninebotCurrentWiFiSwitch)
                    ]))
                }
                return sections
            }
        }
    }

    private func airPlayOutputSections() -> [SettingsSection] {
        [
            SettingsSection("AirPlay（实验）", footer: "在主界面的 AirPlay 连接卡选择设备。画面有缓冲，触控在 iPhone 上操作，声音沿用 iPhone 或车机蓝牙。", [
                .field("播放端口", videoOutputPortField),
                .note(airPlayStatus)
            ])
        ]
    }

    private func prepareExternalOutput(configuration: ReceiverConfiguration) {
        if configuration.zeehoAddress != nil { updateZeehoStatus("正在连接极核仪表…") }
        if configuration.ninebotAddress != nil { updateNinebotStatus("正在连接九号仪表…") }
        if configuration.tailingAddress != nil { updateTailingStatus("正在连接台铃仪表…") }
        if configuration.carLifeEnabled {
            updateCarLifeStatus("正在等待车机连接…")
        }
        guard let id = configuration.airPlayStreamID, let port = configuration.videoOutputPort else { return }
        airPlayStreamID = id
        airPlayStreamURL = URL(string: "http://\(configuration.address):\(port)/airplay/\(id.uuidString)/master.m3u8")
        updateAirPlayStatus("正在准备直播画面…")
    }

    private func startAirPlayTransport() {
        guard airPlayReady, let url = airPlayStreamURL else { return }
        let player: AVPlayer
        if let existing = airPlayPlayer {
            player = existing
        } else {
            // Local video stays on the CarPlay surface. Each session owns its player.
            player = AVPlayer()
            player.allowsExternalPlayback = true
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
            airPlayRouteObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.refreshAirPlayPlaybackStatus() }
            }
            airPlayPlayer = player
        }
        let item = AVPlayerItem(url: url)
        #if DEBUG
        airPlayDiagnostic = ""
        log("AirPlay HLS 已就绪：\(url.absoluteString)")
        airPlayTimeObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.refreshAirPlayPlaybackStatus() }
        }
        #endif
        airPlayItemObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, self.airPlayPlayer?.currentItem === item else { return }
                self.refreshAirPlayPlaybackStatus()
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        refreshAirPlayPlaybackStatus()
    }

    @objc private func airPlayAudioRouteChanged() {
        DispatchQueue.main.async { [weak self] in self?.refreshAirPlayPlaybackStatus() }
    }

    private func refreshAirPlayPlaybackStatus() {
        guard running, outputMode == .airPlay, airPlayReady, let player = airPlayPlayer,
              let item = player.currentItem else { return }
        #if DEBUG
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue)/\($0.portName)" }.joined(separator: ", ")
        let error = item.error as NSError?
        let errorDetail = error.map { "\($0.domain)(\($0.code)) \($0.localizedDescription)" } ?? "–"
        let diagnostic = "AirPlay 播放器：item=\(item.status.rawValue) time=\(player.timeControlStatus.rawValue) 外部视频=\(player.isExternalPlaybackActive) 路由=\(outputs) 等待=\(player.reasonForWaitingToPlay?.rawValue ?? "–") 错误=\(errorDetail)"
        if diagnostic != airPlayDiagnostic { airPlayDiagnostic = diagnostic; log(diagnostic) }
        #endif
        airPlayRetryButton.isHidden = item.status != .failed
        if item.status == .failed {
            updateAirPlayStatus("AirPlay 画面加载失败，可以重试。")
            return
        }
        let defaults = UserDefaults.standard
        if player.isExternalPlaybackActive {
            let route = AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay }
            if let name = route?.portName, !name.isEmpty {
                defaults.set(name, forKey: Self.lastAirPlayDeviceKey)
                updateAirPlayStatus("正在投放到 \(name)")
            } else {
                updateAirPlayStatus("正在通过 AirPlay 投放")
            }
        } else if let previous = defaults.string(forKey: Self.lastAirPlayDeviceKey) {
            updateAirPlayStatus("上次设备：\(previous)")
        } else {
            updateAirPlayStatus("画面已就绪，可选择设备。")
        }
    }

    private func tailingOutputSections() -> [SettingsSection] {
        [
            SettingsSection("台铃 4.3 寸", footer: "适用于 TL-DASH-V2 仪表。iPhone 加入仪表 Wi-Fi，在「Wi-Fi 与网络」填写该网络信息；开启仪表投屏后启动 CarPlay。请先退出其他投屏 App。", [
                .field("仪表 IP 地址", tailingAddressField, placeholder: "192.168.1.1")
            ]),
            SettingsSection(footer: "仪表输出固定为 480×272、JPEG，最高 20 FPS。本机 CarPlay 使用 H.264、960×544、30 FPS。声音由 iPhone／蓝牙输出；仪表不回传触控。", [.note(tailingStatus)])
        ]
    }

    private func carLifeOutputSections() -> [SettingsSection] {
        [
            SettingsSection("CarLife", footer: "车机与 iPhone 连同一个 Wi-Fi，打开车机上的 CarLife 后启动 CarPlay。使用 H.264，最高 1080p、30 FPS。", [
                .field("车机 IP 地址", carLifeAddressField, placeholder: "留空自动发现")
            ]),
            SettingsSection("连接状态", footer: "CarLife 传输画面和触控，声音走 iPhone 与车机的蓝牙。", [.note(carLifeStatus)])
        ]
    }

    private func browserOutputSections() -> [SettingsSection] {
        let browser = SettingsSection(footer: videoOutputSwitch.isOn ? nil : "开启后，同一局域网的浏览器可以查看并触控 CarPlay。", [
            .control("局域网接收页", icon: ("globe", .systemTeal), videoOutputSwitch)
        ])
        guard videoOutputSwitch.isOn else { return [browser] }
        return [
            browser,
            SettingsSection("HTTP · 兼容模式", [
                .field("HTTP 端口", videoOutputPortField),
                browserAddressRow(secure: false),
                .action("在本机浏览器打开") { [unowned self] in
                    guard self.running, let url = self.localBrowserURL else {
                        self.alert("请先启动 CarPlay", "启动后就可以在本机浏览器查看画面。")
                        return
                    }
                    UIApplication.shared.open(url)
                }
            ]),
            SettingsSection("高级", footer: "浏览器性能默认自动。低延迟频繁跳帧时会回到兼容模式。", [
                .control("浏览器性能", icon: ("speedometer", .systemBlue), performanceControl),
                .control("显示触摸点", icon: ("hand.tap.fill", .systemOrange), showTouchesSwitch)
            ])
        ]
    }

    @objc private func httpsModeChanged() {
        guard !running else { httpsMode.selectedSegmentIndex = HTTPSConfiguration.mode.rawValue; return }
        HTTPSConfiguration.mode = HTTPSConfiguration.Mode(rawValue: httpsMode.selectedSegmentIndex) ?? .local
        refreshVideoOutputSummary(); reloadVisibleSettings()
    }

    @objc private func saveHTTPSFields() {
        guard !running else { return }
        let input = httpsDomainField.text ?? ""
        if let domain = HTTPSConfiguration.normalizedDomain(input) {
            HTTPSConfiguration.domain = domain
        } else if input.isEmpty { HTTPSConfiguration.domain = "" }
        else { httpsStatus.text = "域名格式应为 name.duckdns.org，不包含协议或端口。"; return }
        do {
            try HTTPSConfiguration.saveSecret(Data((httpsTokenField.text ?? "").utf8), name: "duckToken")
            httpsStatus.text = "配置已保存，停止并重新启动 CarPlay 后使用新证书或地址。"
        } catch { httpsStatus.text = "无法安全保存 Token，请重试。" }
        refreshVideoOutputSummary()
    }

    fileprivate func httpsSettingsPage() -> SettingsPageController {
        let controller = page("HTTPS 设置") { [unowned self] in
            self.httpsMode.isEnabled = !self.running
            self.httpsDomainField.isEnabled = !self.running
            self.httpsTokenField.isEnabled = !self.running
            var sections = [SettingsSection("地址与证书", footer: self.editingLockedFooter ?? "本地 IP 和 sslip.io 使用这台设备的本地根证书。DuckDNS 可使用自行申请的公开 CA 证书。", [
                .control("地址方案", icon: ("globe", .systemTeal), self.httpsMode),
                .field("HTTPS 端口", self.secureVideoOutputPortField), self.browserAddressRow(secure: true)
            ])]
            switch HTTPSConfiguration.mode {
            case .local:
                sections.append(SettingsSection(footer: "在接收设备的 HTTP 页面点「配置 HTTPS」，安装并信任本机根证书。", [
                    .page("证书安装说明", icon: ("doc.text", .systemBlue)) { [unowned self] in self.httpsHelpPage() }
                ]))
            case .sslip:
                sections.append(SettingsSection(footer: "地址根据手机当前 IP 自动生成，无需账号；DNS 解析需要网络。仍需在接收设备信任本机根证书。只改变域名，不保证绕过特斯拉的私网限制。", [
                    .page("证书安装说明", icon: ("doc.text", .systemBlue)) { [unowned self] in self.httpsHelpPage() }
                ]))
            case .duckDNS:
                sections.append(SettingsSection("DuckDNS", footer: "先在 duckdns.org 注册自己的域名。Token 可修改账号中的域名，请像密码一样保管；仅保存在本机 Keychain。此处将域名指向当前局域网地址，不开放公网端口。", [
                    .externalLink("注册或管理域名", icon: ("link", .systemBlue)) { UIApplication.shared.open(URL(string: "https://www.duckdns.org")!) },
                    .field("域名", self.httpsDomainField, placeholder: "name.duckdns.org"),
                    .field("Token", self.httpsTokenField),
                    .action("更新到当前 IP") { [unowned self] in self.updateDuckDNS() }
                ]))
                sections.append(SettingsSection("受信任证书", footer: "使用 ACME DNS-01 等方式在外部申请该域名的公开证书，导出包含私钥与完整证书链的 P12 后导入。当前不自动签发或续期；到期后需重新导入。仅在本机受信任不能保证车机信任；域名和证书也不能保证绕过车机的私网限制。", [
                    .action("导入 P12 证书") { [unowned self] in self.chooseHTTPSCertificate() },
                    .info("证书文件", (try? HTTPSConfiguration.secret("certificate")) == nil ? "尚未导入" : "已保存，启动时校验")
                ]))
            }
            sections.append(SettingsSection([.note(self.httpsStatus), .note(self.portStatus)]))
            return sections
        }
        controller.onLeave = { [weak self] in self?.saveHTTPSFields() }
        return controller
    }

    private func updateDuckDNS() {
        guard !running, let address = browserAddress else { httpsStatus.text = "请先停止 CarPlay，并连接 Wi-Fi。"; return }
        saveHTTPSFields()
        guard HTTPSConfiguration.normalizedDomain(httpsDomainField.text ?? "") != nil else { return }
        httpsStatus.text = "正在更新解析…"
        Task { [weak self] in
            do { try await HTTPSConfiguration.updateDNS(address: address); self?.httpsStatus.text = "解析已更新到 \(address)，DNS 缓存生效可能需要稍等。" }
            catch { self?.httpsStatus.text = error.localizedDescription }
        }
    }

    private func chooseHTTPSCertificate() {
        guard !running else { return }
        saveHTTPSFields()
        guard HTTPSConfiguration.normalizedDomain(httpsDomainField.text ?? "") != nil else { httpsStatus.text = "请先填写有效域名。"; return }
        documentImportPurpose = .https
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data], asCopy: true)
        picker.delegate = self
        (settingsNavigation ?? self).present(picker, animated: true)
    }

    private func browserAddressRow(secure: Bool) -> SettingsRow {
        let address = { [unowned self] in secure ? self.secureBrowserURL : self.browserURL }
        var row = SettingsRow.action(secure ? "复制 HTTPS 地址" : "复制 HTTP 地址") { [unowned self] in
            self.copySettingsAddress(address())
        }
        row.subtitle = { address() ?? "地址暂不可用" }
        return row
    }

    private func copySettingsAddress(_ url: String?) {
        guard let url else {
            alert("无法复制地址", browserPortError ?? "请先连接 Wi-Fi。")
            return
        }
        UIPasteboard.general.string = url
        alert("已复制", url)
    }

    // MARK: 日志 / 实验 / 关于

    fileprivate func logPage() -> SettingsPageController {
        let controller = page("日志") { [unowned self] in
            [
                SettingsSection(footer: "最近 200 条，不含 Wi-Fi 密码和 MFi 私钥。", [.view(logView)]),
                SettingsSection([.action("复制日志", icon: ("doc.on.doc.fill", .systemBlue)) { [unowned self] in
                    self.copyLog(); self.alert("已复制", "日志已复制到剪贴板。")
                }])
            ]
        }
        logView.constraints.filter { $0.firstAttribute == .height }.forEach { $0.constant = 380 }
        controller.onAppear = { [unowned self] in
            self.logView.text = self.lines.joined(separator: "\n")
            if !self.logView.text.isEmpty { self.logView.scrollRangeToVisible(NSRange(location: self.logView.text.utf16.count - 1, length: 1)) }
        }
        return controller
    }

    private func experimentSections() -> [SettingsSection] {
        var sections = [SettingsSection("实验性功能", footer: "检查这台 iPhone 是否允许 App 发布本机 iAP2 配件端点（本机 CarPlay 的前提）。CarPlay 运行中不能测试。", [
            .action("测试本机传输能力", icon: ("checkmark.shield.fill", .systemPink), detail: { [unowned self] in self.statusLabel.text }) { [unowned self] in
                self.testSameDeviceTransport()
            }
        ])]
        if UIDevice.current.userInterfaceIdiom == .pad {
            sections.append(SettingsSection("iPad 模式", footer: "接收其他 iPhone 的 CarPlay，或把这台设备的 CarPlay 投送到另一台 iPad。", [.view(modeControl)]))
            if modeControl.selectedSegmentIndex == 0 {
                sections.append(SettingsSection(footer: "用蓝牙通知 iPhone 连接这块接收屏。", [
                    .control("蓝牙引导", icon: ("dot.radiowaves.right", .systemBlue), bluetoothSetupSwitch)
                ]))
            }
        }
        return sections
    }

    private func diagnosticsSection() -> SettingsSection {
        var system = utsname(); uname(&system)
        let model = withUnsafeBytes(of: &system.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return SettingsSection("诊断信息", [
            .page("日志", icon: ("doc.text.fill", .systemGray)) { [unowned self] in self.logPage() },
            .page("连接诊断报告", icon: ("doc.text.magnifyingglass", .systemBlue)) { [unowned self] in self.connectionReportPage() },
            .info("浏览器页面", BrowserReceiverPage.version),
            .info("设备", "\(model) · iOS \(UIDevice.current.systemVersion)"),
            .info("MFi 身份", identity != nil ? "已载入" : "未载入")
        ])
    }

    private func diagnosticsPage() -> SettingsPageController {
        page("诊断与实验") { [unowned self] in
            [diagnosticsSection()] + experimentSections()
        }
    }

    fileprivate func aboutPage() -> SettingsPageController {
        page("关于") { [unowned self] in
            [
                SettingsSection([.view(self.aboutIdentityCard())]),
                SettingsSection(footer: "Copyright © 2026 xmz28", self.aboutLinks())
            ]
        }
    }

    private func aboutIdentityCard() -> UIView {
        let info = Bundle.main.infoDictionary ?? [:]
        let primaryIcon = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconName = (primaryIcon?["CFBundleIconFiles"] as? [String])?.first
        let image = iconName.flatMap { UIImage(named: $0) } ?? Self.carButtonIcon.flatMap { UIImage(data: $0) }
        let icon = UIImageView(image: image)
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 17
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 76),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor)
        ])
        let name = UILabel()
        name.text = "CarWithin"
        name.font = .preferredFont(forTextStyle: .title2)
        name.adjustsFontForContentSizeCategory = true
        name.accessibilityTraits.insert(.header)
        let version = UILabel()
        version.text = "版本 \(info["CFBundleShortVersionString"] as? String ?? "-")（\(info["CFBundleVersion"] as? String ?? "-")）"
        version.font = .preferredFont(forTextStyle: .subheadline)
        version.textColor = .secondaryLabel
        version.adjustsFontForContentSizeCategory = true
        let introduction = UILabel()
        introduction.text = "在 iPhone 上启动 CarPlay，通过浏览器或兼容的 CarLife 车机查看和操控。"
        introduction.font = .preferredFont(forTextStyle: .subheadline)
        introduction.textColor = .secondaryLabel
        introduction.adjustsFontForContentSizeCategory = true
        introduction.textAlignment = .center
        introduction.numberOfLines = 0

        let card = UIStackView(arrangedSubviews: [icon, name, version, introduction])
        card.axis = .vertical
        card.alignment = .center
        card.spacing = 4
        card.setCustomSpacing(12, after: icon)
        card.setCustomSpacing(12, after: version)
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 8, bottom: 16, trailing: 8)
        return card
    }

}

extension ReceiverViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        switch documentImportPurpose {
        case .identityIPA, .identityFiles:
            let fromIPA: Bool
            if case .identityIPA = documentImportPurpose { fromIPA = true } else { fromIPA = false }
            documentImportPurpose = .https
            importIdentitySelection(urls, fromIPA: fromIPA)
            return
        case .https: break
        }
        guard let url = urls.first, !running else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512 * 1024,
              let data = try? Data(contentsOf: url) else { alert("无法导入", "请选择不超过 512 KB 的 P12 证书。"); return }
        let prompt = UIAlertController(title: "证书密码", message: "密码与证书仅保存在本机 Keychain。", preferredStyle: .alert)
        prompt.addTextField { $0.isSecureTextEntry = true; $0.placeholder = "P12 密码，可为空" }
        prompt.addAction(UIAlertAction(title: "取消", style: .cancel))
        prompt.addAction(UIAlertAction(title: "导入", style: .default) { [weak self, weak prompt] _ in
            do {
                try HTTPSConfiguration.importCertificate(data, password: prompt?.textFields?.first?.text ?? "")
                self?.httpsStatus.text = "证书通过本机域名、有效期和信任校验，重新启动 CarPlay 后生效。"
                self?.reloadVisibleSettings()
            } catch { self?.httpsStatus.text = error.localizedDescription }
        })
        let presentPrompt = { [weak self] in
            guard let self else { return }
            (self.settingsNavigation ?? self).present(prompt, animated: true)
        }
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true, completion: presentPrompt)
        } else {
            DispatchQueue.main.async(execute: presentPrompt)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        documentImportPurpose = .https
    }
}

extension ReceiverViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController === updateSheet {
            if updateSheetAutomatic { AppUpdatePolicy().snooze() }
            updateSheetAutomatic = false
        } else {
            settingsDismissed()
        }
    }
}

extension ReceiverViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let provider = results.first?.itemProvider else {
            picker.dismiss(animated: true)
            return
        }
        let identifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
            ?? UTType.image.identifier
        picker.dismiss(animated: true) { [weak self] in
            self?.importVehicleIcon(from: provider, typeIdentifier: identifier)
        }
    }

    private func importVehicleIcon(from provider: NSItemProvider, typeIdentifier: String) {
        importingVehicleIcon = true
        reloadVisibleSettings()
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, _ in
            let png = url.flatMap(Self.vehicleIconPNG(at:))
            DispatchQueue.main.async {
                guard let self else { return }
                self.importingVehicleIcon = false
                defer { self.reloadVisibleSettings() }
                guard let png else {
                    self.alert("无法读取图片", "请选择另一张照片再试。")
                    return
                }
                UserDefaults.standard.set(png, forKey: Self.customVehicleIconKey)
            }
        }
    }
}
