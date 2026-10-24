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
