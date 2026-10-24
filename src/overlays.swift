// iOS 15 Swift overlay APIs implemented in Swift, exported under the overlay's own symbol
// names with @_silgen_name. Built with -enable-library-evolution so resilient overlay types
// keep their ABI here too (indirect results, self by address), and against the back-deployed
// Concurrency library the app bundles. Members @_silgen_name can't name (metadata
// accessors, inits, getters, enum case tags) get the overlay's name from overlays.aliases.

import Foundation
import UIKit
import os

// Foundation (15): NotificationCenter.notifications(named:object:), an AsyncSequence of
// notifications, on an AsyncStream fed by a block observer (removed with the sequence).
public final class WaportNotifications: @unchecked Sendable {
    let stream: AsyncStream<Notification>
    let center: NotificationCenter
    let token: NSObjectProtocol

    init(center: NotificationCenter, name: Notification.Name, object: AnyObject?) {
        var continuation: AsyncStream<Notification>.Continuation!
        stream = AsyncStream { continuation = $0 }
        let c = continuation!
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: nil) { c.yield($0) }
    }

    deinit { center.removeObserver(token) }

    // NotificationCenter.Notifications.makeAsyncIterator()
    @_silgen_name("$sSo20NSNotificationCenterC10FoundationE13NotificationsC17makeAsyncIteratorAE0G0VyF")
    public func makeAsyncIterator() -> WaportNotificationsIterator {
        WaportNotificationsIterator(owner: self, iterator: stream.makeAsyncIterator())
    }
}

// NotificationCenter.Notifications.Iterator (metadata accessor: overlays.aliases)
public struct WaportNotificationsIterator {
    let owner: WaportNotifications
    var iterator: AsyncStream<Notification>.Iterator

    @_silgen_name("$sSo20NSNotificationCenterC10FoundationE13NotificationsC8IteratorV4nextAC12NotificationVSgyYaF")
    public mutating func next() async -> Notification? { await iterator.next() }
}

// Foundation (15): Date.now
extension Date {
    @_silgen_name("$s10Foundation4DateV3nowACvgZ")
    public static func waportNow() -> Date { Date() }
}

// Foundation (15): URLSession async data/download, on completion-handler tasks (cancelled with
// the calling Task). The per-task delegate (15) is not supported and ignored.
extension URLSession {
    func waportRun<T>(_ make: (@escaping (T?, URLResponse?, Error?) -> Void) -> URLSessionTask) async throws
        -> (T, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<(T, URLResponse), Error>) in
                let task = make { value, response, error in
                    if let value = value, let response = response { c.resume(returning: (value, response)) }
                    else { c.resume(throwing: error ?? URLError(.unknown)) }
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    @_silgen_name("$sSo12NSURLSessionC10FoundationE4data3for8delegateAC4DataV_So13NSURLResponseCtAC10URLRequestV_So0A12TaskDelegate_pSgtYaKF")
    public func waportData(for request: URLRequest, delegate: URLSessionTaskDelegate?) async throws -> (Data, URLResponse) {
        try await waportRun { done in self.dataTask(with: request) { d, r, e in done(e == nil ? d ?? Data() : nil, r, e) } }
    }

    @_silgen_name("$sSo12NSURLSessionC10FoundationE4data4from8delegateAC4DataV_So13NSURLResponseCtAC3URLV_So0A12TaskDelegate_pSgtYaKF")
    public func waportData(from url: URL, delegate: URLSessionTaskDelegate?) async throws -> (Data, URLResponse) {
        try await waportRun { done in self.dataTask(with: url) { d, r, e in done(e == nil ? d ?? Data() : nil, r, e) } }
    }

    // the downloaded file is deleted when the completion handler returns: moved to a new
    // temporary file first (the caller owns it, as with the 15 API)
    @_silgen_name("$sSo12NSURLSessionC10FoundationE8download4from8delegateAC3URLV_So13NSURLResponseCtAH_So0A12TaskDelegate_pSgtYaKF")
    public func waportDownload(from url: URL, delegate: URLSessionTaskDelegate?) async throws -> (URL, URLResponse) {
        try await waportRun { done in
            self.downloadTask(with: url) { file, r, e in
                guard let file = file, e == nil else { return done(nil, r, e) }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("CFNetworkDownload_" + UUID().uuidString + ".tmp")
                do {
                    try FileManager.default.moveItem(at: file, to: dest)
                    done(dest, r, nil)
                } catch {
                    done(nil, r, error)
                }
            }
        }
    }
}

final class TaskBox: @unchecked Sendable {
    var task: URLSessionTask?
}

extension NotificationCenter {
    @_silgen_name("$sSo20NSNotificationCenterC10FoundationE13notifications5named6objectAbCE13NotificationsCSo0A4Namea_yXlSgtF")
    public func waportNotifications(named name: Notification.Name, object: AnyObject?) -> WaportNotifications {
        WaportNotifications(center: self, name: name, object: object)
    }
}

// UIKit (15): diffable data sources. reconfigureItems -> reloadItems (the cell is rebuilt, not
// reconfigured in place); applySnapshotUsingReloadData -> apply without animation (on 14 that
// is a full reload, the 15 behaviour of applySnapshotUsingReloadData); the async applies wait
// for the completion handler. Class methods are dispatch thunks (Tj) in the app's imports.
extension NSDiffableDataSourceSnapshot {
    @_silgen_name("$s5UIKit28NSDiffableDataSourceSnapshotV16reconfigureItemsyySayq_GF")
    public mutating func waportReconfigureItems(_ identifiers: [ItemIdentifierType]) {
        reloadItems(identifiers)
    }
}

extension UITableViewDiffableDataSource {
    @_silgen_name("$s5UIKit29UITableViewDiffableDataSourceC17sectionIdentifier3forxSgSi_tFTj")
    public func waportSectionIdentifier(for index: Int) -> SectionIdentifierType? {
        let sections = snapshot().sectionIdentifiers
        return sections.indices.contains(index) ? sections[index] : nil
    }

    @_silgen_name("$s5UIKit29UITableViewDiffableDataSourceC024applySnapshotUsingReloadE0_10completionyAA010NSDiffableefH0Vyxq_G_yycSgtFTj")
    public func waportApplyUsingReloadData(_ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>,
                                           completion: (() -> Void)?) {
        apply(snapshot, animatingDifferences: false, completion: completion)
    }

    @_silgen_name("$s5UIKit29UITableViewDiffableDataSourceC024applySnapshotUsingReloadE0yyAA010NSDiffableefH0Vyxq_GYaFTj")
    public func waportApplyUsingReloadData(_ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>) async {
        await withCheckedContinuation { c in apply(snapshot, animatingDifferences: false) { c.resume() } }
    }

    @_silgen_name("$s5UIKit29UITableViewDiffableDataSourceC5apply_20animatingDifferencesyAA010NSDiffableeF8SnapshotVyxq_G_SbtYaFTj")
    public func waportApply(_ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>,
                            animatingDifferences: Bool) async {
        await withCheckedContinuation { c in apply(snapshot, animatingDifferences: animatingDifferences) { c.resume() } }
    }
}

extension UICollectionViewDiffableDataSource {
    @_silgen_name("$s5UIKit34UICollectionViewDiffableDataSourceC17sectionIdentifier3forxSgSi_tFTj")
    public func waportSectionIdentifier(for index: Int) -> SectionIdentifierType? {
        let sections = snapshot().sectionIdentifiers
        return sections.indices.contains(index) ? sections[index] : nil
    }

    @_silgen_name("$s5UIKit34UICollectionViewDiffableDataSourceC024applySnapshotUsingReloadE0yyAA010NSDiffableefH0Vyxq_GYaFTj")
    public func waportApplyUsingReloadData(_ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>) async {
        await withCheckedContinuation { c in apply(snapshot, animatingDifferences: false) { c.resume() } }
    }

    @_silgen_name("$s5UIKit34UICollectionViewDiffableDataSourceC5apply_20animatingDifferencesyAA010NSDiffableeF8SnapshotVyxq_G_SbtYaFTj")
    public func waportApply(_ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>,
                            animatingDifferences: Bool) async {
        await withCheckedContinuation { c in apply(snapshot, animatingDifferences: animatingDifferences) { c.resume() } }
    }
}

// os (15): OSSignposter. Its API is @_transparent and inlined into the app (which emits the
// signposts itself with the 12+ os_signpost calls); what remains are the types and a few
// @usableFromInline members, mapped onto these with linker aliases (alias_list in
// build-shim.sh): metadata accessors, inits, getters and the error enum's case tag. Like os,
// a second endInterval of the same state reports .doubleEnd.
public struct WaportSignposter {
    public let logHandle: OSLog

    public init(subsystem: String, category: OSLog.Category) {
        logHandle = OSLog(subsystem: subsystem, category: category)
    }
}

public class WaportSignpostIntervalState {
    public final let signpostID: OSSignpostID
    var isOpen: Bool
    let lock = NSLock()

    public init(id: OSSignpostID, isOpen: Bool) {
        signpostID = id
        self.isOpen = isOpen
    }

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasOpen = isOpen
        isOpen = false
        return wasOpen
    }
}

public enum WaportSignpostError {
    case doubleEnd
    case none
}

@_silgen_name("$s2os28checkForErrorAndConsumeState5stateAA010OSSignpostD0OAA0i8IntervalG0C_tF")
public func waportCheckForErrorAndConsumeState(state: WaportSignpostIntervalState) -> WaportSignpostError {
    state.consume() ? .none : .doubleEnd
}

// Foundation (15): AttributeContainer, as far as UIConfigurationTextAttributesTransformer needs
// it: a container of attribute values keyed by name, set through the AttributedStringKey
// subscript (what the @inlinable dynamic-member setters call). Only the UIKit font and
// foreground color keys are mapped (their metadata and conformances: overlays.aliases).
public protocol WaportAttributedStringKey {
    associatedtype Value: Hashable
    static var name: String { get }
}

public struct WaportAttributeContainer: Equatable {
    var values: [String: AnyHashable] = [:]

    public init() {}

    public subscript<T: WaportAttributedStringKey>(_: T.Type) -> T.Value? {
        get { values[T.name]?.base as? T.Value }
        set { values[T.name] = newValue.map { AnyHashable($0) } }
    }
}

@frozen public enum WaportUIKitFontAttribute: WaportAttributedStringKey {
    public typealias Value = UIFont
    public static let name = NSAttributedString.Key.font.rawValue
}

@frozen public enum WaportUIKitForegroundColorAttribute: WaportAttributedStringKey {
    public typealias Value = UIColor
    public static let name = NSAttributedString.Key.foregroundColor.rawValue
}

// UIKit (15): UIConfigurationTextAttributesTransformer
public struct WaportTextAttributesTransformer {
    public let transform: (WaportAttributeContainer) -> WaportAttributeContainer

    public init(_ transform: @escaping (WaportAttributeContainer) -> WaportAttributeContainer) {
        self.transform = transform
    }
}

// UIKit (15): UIButton.Configuration. There is no UIButtonConfiguration on 14: the struct only
// holds the values, and UIButton.configuration's setter applies them with the legacy API
// (title/image setters, title font and color, background color, corner radius, content/title/
// image edge insets). Style defaults approximate the 15 ones; state-dependent updates
// (configurationUpdateHandler) don't run, highlighting is the system button's.
public struct WaportButtonConfiguration: Hashable {
    public enum Size { case mini, small, medium, large }
    public enum TitleAlignment { case automatic, leading, center, trailing }
    public enum CornerStyle { case fixed, dynamic, small, medium, large, capsule }
    enum Style { case plain, tinted, gray, filled, borderless }

    let style: Style
    public var background: UIBackgroundConfiguration
    public var cornerStyle = CornerStyle.dynamic
    public var buttonSize = Size.medium
    public var baseForegroundColor: UIColor?
    public var baseBackgroundColor: UIColor?
    public var image: UIImage?
    public var imageColorTransformer: UIConfigurationColorTransformer?
    public var preferredSymbolConfigurationForImage: UIImage.SymbolConfiguration?
    public var title: String?
    public var titleTextAttributesTransformer: WaportTextAttributesTransformer?
    public var contentInsets: NSDirectionalEdgeInsets
    public var imagePlacement = NSDirectionalRectEdge.leading
    public var imagePadding: CGFloat = 0
    public var titleAlignment = TitleAlignment.automatic
    public var titleLineBreakMode = NSLineBreakMode.byTruncatingMiddle

    init(_ style: Style) {
        self.style = style
        background = .clear()
        background.backgroundColor = nil
        contentInsets = Self.defaultInsets(.medium)
    }

    static func defaultInsets(_ size: Size) -> NSDirectionalEdgeInsets {
        switch size {
        case .mini: return NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
        case .small: return NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        case .medium: return NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        case .large: return NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        }
    }

    @_silgen_name("$sSo8UIButtonC5UIKitE13ConfigurationV5plainAEyFZ")
    public static func waportPlain() -> WaportButtonConfiguration { .init(.plain) }
    @_silgen_name("$sSo8UIButtonC5UIKitE13ConfigurationV6tintedAEyFZ")
    public static func waportTinted() -> WaportButtonConfiguration { .init(.tinted) }
    @_silgen_name("$sSo8UIButtonC5UIKitE13ConfigurationV4grayAEyFZ")
    public static func waportGray() -> WaportButtonConfiguration { .init(.gray) }
    @_silgen_name("$sSo8UIButtonC5UIKitE13ConfigurationV6filledAEyFZ")
    public static func waportFilled() -> WaportButtonConfiguration { .init(.filled) }
    @_silgen_name("$sSo8UIButtonC5UIKitE13ConfigurationV10borderlessAEyFZ")
    public static func waportBorderless() -> WaportButtonConfiguration { .init(.borderless) }

    // transformers are closures: compared by presence only
    public static func == (a: Self, b: Self) -> Bool {
        a.style == b.style && a.background == b.background && a.cornerStyle == b.cornerStyle
            && a.buttonSize == b.buttonSize && a.baseForegroundColor == b.baseForegroundColor
            && a.baseBackgroundColor == b.baseBackgroundColor && a.image == b.image
            && (a.imageColorTransformer == nil) == (b.imageColorTransformer == nil)
            && a.preferredSymbolConfigurationForImage == b.preferredSymbolConfigurationForImage
            && a.title == b.title
            && (a.titleTextAttributesTransformer == nil) == (b.titleTextAttributesTransformer == nil)
            && a.contentInsets == b.contentInsets && a.imagePlacement == b.imagePlacement
            && a.imagePadding == b.imagePadding && a.titleAlignment == b.titleAlignment
            && a.titleLineBreakMode == b.titleLineBreakMode
    }

    public func hash(into h: inout Hasher) {
        h.combine(title)
        h.combine(image)
        h.combine(baseForegroundColor)
        h.combine(baseBackgroundColor)
    }

    func apply(to button: UIButton, box: WaportButtonConfigurationBox) {
        let tint = button.tintColor ?? .systemBlue
        let fg = baseForegroundColor ?? (style == .filled ? .white : tint)
        var bg: UIColor?
        switch style {
        case .plain, .borderless: bg = nil
        case .tinted: bg = (baseBackgroundColor ?? tint).withAlphaComponent(0.15)
        case .gray: bg = baseBackgroundColor ?? .tertiarySystemFill
        case .filled: bg = baseBackgroundColor ?? tint
        }
        if let c = background.backgroundColor { bg = c }
        if let t = background.backgroundColorTransformer, let c = bg { bg = t.transform(c) }
        button.backgroundColor = bg
        button.layer.borderColor = background.strokeColor?.cgColor
        button.layer.borderWidth = background.strokeColor == nil ? 0 : background.strokeWidth

        // title: font of the size class, then the transformer's font and color
        let style: UIFont.TextStyle
        switch buttonSize {
        case .mini: style = .caption1
        case .small: style = .subheadline
        case .medium, .large: style = .body
        }
        var attrs = WaportAttributeContainer()
        attrs[WaportUIKitFontAttribute.self] = UIFont.preferredFont(forTextStyle: style)
        attrs[WaportUIKitForegroundColorAttribute.self] = fg
        if let t = titleTextAttributesTransformer { attrs = t.transform(attrs) }
        button.setTitle(title, for: .normal)
        button.setTitleColor(attrs[WaportUIKitForegroundColorAttribute.self] ?? fg, for: .normal)
        if let label = button.titleLabel {
            label.font = attrs[WaportUIKitFontAttribute.self]
            label.lineBreakMode = titleLineBreakMode
            switch titleAlignment {
            case .automatic, .center: label.textAlignment = .center
            case .leading: label.textAlignment = .natural
            case .trailing: label.textAlignment = button.effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? .left : .right
            }
        }

        // image: tinted to the foreground color (button.tintColor stays the style's input)
        var img = image
        if let i = img, i.renderingMode != .alwaysOriginal {
            img = i.withTintColor(imageColorTransformer?.transform(fg) ?? fg, renderingMode: .alwaysOriginal)
        }
        button.setImage(img, for: .normal)
        button.setPreferredSymbolConfiguration(preferredSymbolConfigurationForImage, forImageIn: .normal)

        // insets: content insets, then image padding/placement moved into title/image insets
        let rtl = button.effectiveUserInterfaceLayoutDirection == .rightToLeft
        var content = UIEdgeInsets(top: contentInsets.top, left: rtl ? contentInsets.trailing : contentInsets.leading,
                                   bottom: contentInsets.bottom, right: rtl ? contentInsets.leading : contentInsets.trailing)
        var titleInsets = UIEdgeInsets.zero, imageInsets = UIEdgeInsets.zero
        button.semanticContentAttribute = .unspecified
        if img != nil, let t = title, !t.isEmpty {
            let p = imagePadding
            let imageSize = button.imageView?.intrinsicContentSize ?? .zero
            let titleSize = button.titleLabel?.intrinsicContentSize ?? .zero
            switch imagePlacement {
            case .top, .bottom:
                // negative insets grow the image's/title's rect on one side: each moves by
                // half of it, onto a common center line and above/below each other
                let toTitle = titleSize.height + p, toImage = imageSize.height + p
                let top = imagePlacement == .top
                imageInsets = UIEdgeInsets(top: top ? -toTitle : 0, left: rtl ? -titleSize.width : 0,
                                           bottom: top ? 0 : -toTitle, right: rtl ? 0 : -titleSize.width)
                titleInsets = UIEdgeInsets(top: top ? 0 : -toImage, left: rtl ? 0 : -imageSize.width,
                                           bottom: top ? -toImage : 0, right: rtl ? -imageSize.width : 0)
                let extra = (imageSize.height + titleSize.height + p - max(imageSize.height, titleSize.height)) / 2
                let narrower = min(imageSize.width, titleSize.width) / 2
                content.top += extra; content.bottom += extra
                content.left -= narrower; content.right -= narrower
            case .trailing:
                button.semanticContentAttribute = rtl ? .forceLeftToRight : .forceRightToLeft
                titleInsets = rtl ? UIEdgeInsets(top: 0, left: p, bottom: 0, right: -p)
                    : UIEdgeInsets(top: 0, left: -p, bottom: 0, right: p)
                if rtl { content.right += p } else { content.left += p }
            default:
                titleInsets = rtl ? UIEdgeInsets(top: 0, left: -p, bottom: 0, right: p)
                    : UIEdgeInsets(top: 0, left: p, bottom: 0, right: -p)
                if rtl { content.left += p } else { content.right += p }
            }
        }
        button.contentEdgeInsets = content
        button.titleEdgeInsets = titleInsets
        button.imageEdgeInsets = imageInsets

        // corners: capsule follows the height
        let radius: CGFloat?
        switch cornerStyle {
        case .fixed: radius = background.cornerRadius
        case .dynamic:
            switch buttonSize {
            case .mini: radius = 4
            case .small: radius = 6
            case .medium: radius = 8
            case .large: radius = 10
            }
        case .small: radius = 6
        case .medium: radius = 8
        case .large: radius = 12
        case .capsule: radius = nil
        }
        box.observation = nil
        if let r = radius {
            button.layer.cornerRadius = bg == nil && background.strokeColor == nil ? 0 : r
        } else {
            button.layer.cornerRadius = button.bounds.height / 2
            box.observation = button.layer.observe(\.bounds) { layer, _ in layer.cornerRadius = layer.bounds.height / 2 }
        }
        button.layer.cornerCurve = .continuous
    }
}

final class WaportButtonConfigurationBox {
    var value: WaportButtonConfiguration?
    var observation: NSKeyValueObservation?
}

private var waportButtonConfigurationKey = 0

// UIButton.configuration, UIButton(configuration:primaryAction:) (names: overlays.aliases)
extension UIButton {
    var waportConfigurationBox: WaportButtonConfigurationBox {
        if let b = objc_getAssociatedObject(self, &waportButtonConfigurationKey) as? WaportButtonConfigurationBox {
            return b
        }
        let b = WaportButtonConfigurationBox()
        objc_setAssociatedObject(self, &waportButtonConfigurationKey, b, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return b
    }

    public var waportConfiguration: WaportButtonConfiguration? {
        get { waportConfigurationBox.value }
        set {
            let box = waportConfigurationBox
            box.value = newValue
            newValue?.apply(to: self, box: box)
        }
    }

    public convenience init(waportConfiguration: WaportButtonConfiguration, primaryAction: UIAction?) {
        self.init(type: .system, primaryAction: primaryAction)
        self.waportConfiguration = waportConfiguration
    }
}
