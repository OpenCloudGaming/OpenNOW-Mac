import AppKit
import ImageIO
import QuartzCore

let OPNInterfacePreferencesDidChangeNotification = Notification.Name("OpenNOW.InterfacePreferencesDidChange")

@objc(OpnImageLoadToken)
final class OpnImageLoadToken: NSObject {
    private let lock = NSLock()
    private var cancelledValue = false
    private var operation: Operation?
    private var task: URLSessionDataTask?
    private var children: [OpnImageLoadToken] = []
    private var cancelHandler: (() -> Void)?

    @objc(isCancelled)
    var isCancelled: Bool {
        lock.lock()
        let value = cancelledValue
        lock.unlock()
        return value
    }

    @objc
    func cancel() {
        var operationToCancel: Operation?
        var taskToCancel: URLSessionDataTask?
        var childrenToCancel: [OpnImageLoadToken] = []
        var handler: (() -> Void)?
        lock.lock()
        if !cancelledValue {
            cancelledValue = true
            operationToCancel = operation
            taskToCancel = task
            childrenToCancel = children
            children.removeAll()
            handler = cancelHandler
            cancelHandler = nil
        }
        lock.unlock()
        handler?()
        operationToCancel?.cancel()
        taskToCancel?.cancel()
        childrenToCancel.forEach { $0.cancel() }
    }

    func setOperation(_ operation: Operation) {
        lock.lock()
        self.operation = operation
        let cancelNow = cancelledValue
        lock.unlock()
        if cancelNow { operation.cancel() }
    }

    func setTask(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let cancelNow = cancelledValue
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    func addChild(_ token: OpnImageLoadToken) {
        lock.lock()
        let cancelNow = cancelledValue
        if !cancelNow { children.append(token) }
        lock.unlock()
        if cancelNow { token.cancel() }
    }

    func setCancelHandler(_ handler: (() -> Void)?) {
        lock.lock()
        cancelHandler = handler
        let cancelNow = cancelledValue
        if cancelNow { cancelHandler = nil }
        lock.unlock()
        if cancelNow { handler?() }
    }
}

extension OpnImageLoadToken: @unchecked Sendable {}

@objc(OPNHeroArtworkView)
final class OPNHeroArtworkView: NSView {
    @objc var image: NSImage? {
        didSet { updateImageLayer() }
    }

    private let imageLayer = CALayer()
    private let fadeLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = OPNUIHelpers.color(rgb: 0x101113, alpha: 1.0).cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
        fadeLayer.colors = [
            OPNUIHelpers.color(rgb: 0x101113, alpha: 0.0).cgColor,
            OPNUIHelpers.color(rgb: 0x101113, alpha: 0.28).cgColor,
            OPNUIHelpers.color(rgb: 0x101113, alpha: 1.0).cgColor
        ]
        fadeLayer.locations = [0.0, 0.46, 1.0]
        fadeLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        fadeLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        layer?.addSublayer(fadeLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        fadeLayer.frame = bounds
        CATransaction.commit()
    }

    private func updateImageLayer() {
        var rect = image.map { NSRect(origin: .zero, size: $0.size) } ?? .zero
        let cgImage = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = cgImage
        CATransaction.commit()
    }
}

private final class OPNPendingImageCompletion {
    let token: OpnImageLoadToken
    let completion: (NSImage?, String?, Data?) -> Void

    init(token: OpnImageLoadToken, completion: @escaping (NSImage?, String?, Data?) -> Void) {
        self.token = token
        self.completion = completion
    }
}

extension OPNPendingImageCompletion: @unchecked Sendable {}

private final class OPNImageCompletionBox: @unchecked Sendable {
    let completion: (NSImage?, String?, Data?) -> Void

    init(_ completion: @escaping (NSImage?, String?, Data?) -> Void) {
        self.completion = completion
    }
}

@objcMembers
@objc(OPNUIHelpers)
final class OPNUIHelpers: NSObject {
    private static let autoFullScreenDefaultsKey = "OpenNOW.Interface.AutoFullScreen"
    private static let appIconThemeDefaultsKey = "OpenNOW.Interface.AppIconTheme"
    private static let backgroundTintStrengthValue: CGFloat = 0.85
    private static let imageQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.opennow.image-loader"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 15.0
        configuration.urlCache = .shared
        return URLSession(configuration: configuration)
    }()
    private nonisolated(unsafe) static let decodedImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 260
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()
    private nonisolated(unsafe) static let imageDataMemoryCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 260
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private static let stateQueue = DispatchQueue(label: "com.opennow.image-loader.state")
    private nonisolated(unsafe) static var pendingCompletions: [String: [OPNPendingImageCompletion]] = [:]
    private nonisolated(unsafe) static var pendingOperations: [String: Operation] = [:]
    private nonisolated(unsafe) static var pendingTasks: [String: URLSessionDataTask] = [:]
    private nonisolated(unsafe) static var failureCache: [String: Date] = [:]
    private nonisolated(unsafe) static var fallbackHeroArtwork: NSImage?

    @objc(colorWithRGB:alpha:)
    static func color(rgb: UInt32, alpha: CGFloat) -> NSColor {
        let resolved = resolvedInterfaceColor(rgb)
        return NSColor(calibratedRed: CGFloat((resolved >> 16) & 0xFF) / 255.0, green: CGFloat((resolved >> 8) & 0xFF) / 255.0, blue: CGFloat(resolved & 0xFF) / 255.0, alpha: alpha)
    }

    @objc(blendRGB:target:amount:)
    static func blendRGB(_ rgb: UInt32, target: UInt32, amount: CGFloat) -> UInt32 {
        let clamped = max(0.0, min(amount, 1.0))
        let r = Int(round(Double(CGFloat((rgb >> 16) & 0xFF) * (1.0 - clamped) + CGFloat((target >> 16) & 0xFF) * clamped)))
        let g = Int(round(Double(CGFloat((rgb >> 8) & 0xFF) * (1.0 - clamped) + CGFloat((target >> 8) & 0xFF) * clamped)))
        let b = Int(round(Double(CGFloat(rgb & 0xFF) * (1.0 - clamped) + CGFloat(target & 0xFF) * clamped)))
        return (UInt32(clampedByte(r)) << 16) | (UInt32(clampedByte(g)) << 8) | UInt32(clampedByte(b))
    }

    static func autoFullScreenEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: autoFullScreenDefaultsKey)
    }

    static func setAutoFullScreenEnabled(_ enabled: Bool) {
        guard enabled != autoFullScreenEnabled() else { return }
        UserDefaults.standard.set(enabled, forKey: autoFullScreenDefaultsKey)
        UserDefaults.standard.synchronize()
        NotificationCenter.default.post(name: OPNInterfacePreferencesDidChangeNotification, object: nil)
    }

    static func appIconThemePreference() -> Int {
        let value = UserDefaults.standard.string(forKey: appIconThemeDefaultsKey)
        if value == "green" { return 1 }
        if value == "blue" { return 2 }
        return 0
    }

    static func setAppIconThemePreference(_ theme: Int) {
        let normalized = theme == 1 || theme == 2 ? theme : 0
        guard normalized != appIconThemePreference() else { return }
        let value = normalized == 1 ? "green" : (normalized == 2 ? "blue" : "black")
        UserDefaults.standard.set(value, forKey: appIconThemeDefaultsKey)
        UserDefaults.standard.synchronize()
        NotificationCenter.default.post(name: OPNInterfacePreferencesDidChangeNotification, object: nil)
    }

    static func backgroundTintStrength() -> CGFloat { backgroundTintStrengthValue }

    @objc(textStyleWithSize:color:weight:)
    static func textStyle(size: CGFloat, color: NSColor, weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    }

    @objc(labelWithText:frame:size:color:weight:alignment:)
    static func label(text: String, frame: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(frame: frame)
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = alignment
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }

    @objc(buttonWithTitle:frame:background:textColor:bordered:borderColor:)
    static func button(title: String, frame: NSRect, background: NSColor, textColor: NSColor, bordered: Bool, borderColor: NSColor?) -> NSButton {
        let button = NSButton(frame: frame)
        button.title = title
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.focusRingType = .none
        button.font = NSFont.systemFont(ofSize: 14.0, weight: .semibold)
        button.contentTintColor = textColor
        button.wantsLayer = true
        button.layer?.backgroundColor = background.cgColor
        button.layer?.cornerRadius = 10.0
        if bordered {
            button.layer?.borderWidth = 1.0
            button.layer?.borderColor = (borderColor ?? color(rgb: 0x34C759, alpha: 1.0)).cgColor
        }
        return button
    }

    @objc(textFieldWithFrame:placeholder:secure:)
    static func textField(frame: NSRect, placeholder: String, secure: Bool) -> NSTextField {
        let field = secure ? NSSecureTextField(frame: frame) : NSTextField(frame: frame)
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 14.0, weight: .regular)
        field.textColor = color(rgb: 0xF5F5F7, alpha: 1.0)
        field.backgroundColor = color(rgb: 0x24262B, alpha: 1.0)
        field.isBordered = true
        field.focusRingType = .exterior
        field.bezelStyle = .roundedBezel
        return field
    }

    @objc(spinnerWithFrame:)
    static func spinner(frame: NSRect) -> NSProgressIndicator {
        let spinner = NSProgressIndicator(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        return spinner
    }

    static func disableFocusHighlights(_ view: NSView) {
        view.focusRingType = .none
        view.subviews.forEach(disableFocusHighlights)
    }

    @objc(newRoundedRectPathWithRect:xRadius:yRadius:)
    static func newRoundedRectPath(rect: NSRect, xRadius: CGFloat, yRadius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: xRadius, cornerHeight: yRadius, transform: nil)
    }

    @objc(newEllipsePathWithRect:)
    static func newEllipsePath(rect: NSRect) -> CGPath {
        CGPath(ellipseIn: rect, transform: nil)
    }

    static func clearImageCaches() {
        decodedImageCache.removeAllObjects()
        imageDataMemoryCache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
        stateQueue.sync { failureCache.removeAll() }
    }

    @objc(loadImageForURL:maxPixelDimension:completion:)
    static func loadImage(urlString: String, maxPixelDimension: CGFloat, completion: @escaping (NSImage?, String?, Data?) -> Void) {
        _ = loadImageForURLCancellable(urlString: urlString, maxPixelDimension: maxPixelDimension, completion: completion)
    }

    @objc(loadImageFromCandidates:maxPixelDimension:completion:)
    static func loadImage(candidates: [String], maxPixelDimension: CGFloat, completion: @escaping (NSImage?, String?, Data?) -> Void) {
        _ = loadImageFromCandidatesCancellable(candidates: candidates, maxPixelDimension: maxPixelDimension, completion: completion)
    }

    @objc(cachedImageForURL:maxPixelDimension:)
    static func cachedImage(urlString: String, maxPixelDimension: CGFloat) -> NSImage? {
        let normalizedURL = normalized(urlString)
        guard !normalizedURL.isEmpty else { return nil }
        let key = cacheKey(normalizedURL, maxPixelDimension)
        if let image = decodedImageCache.object(forKey: key as NSString) { return image }
        let data = imageDataMemoryCache.object(forKey: key as NSString) as Data? ?? OPNGameDataCache.shared.loadImage(urlString: normalizedURL)
        guard let data, !data.isEmpty, let image = decodedImage(data: data, maxPixelDimension: maxPixelDimension) else { return nil }
        cache(image: image, data: data, key: key)
        return image
    }

    @objc(cachedImageFromCandidates:maxPixelDimension:resolvedURL:)
    static func cachedImage(candidates: [String], maxPixelDimension: CGFloat, resolvedURL: AutoreleasingUnsafeMutablePointer<NSString?>?) -> NSImage? {
        for candidate in candidates {
            let normalizedURL = normalized(candidate)
            guard !normalizedURL.isEmpty else { continue }
            guard let image = cachedImage(urlString: normalizedURL, maxPixelDimension: maxPixelDimension) else { continue }
            resolvedURL?.pointee = normalizedURL as NSString
            return image
        }
        resolvedURL?.pointee = nil
        return nil
    }

    @objc(cachedMemoryImageForURL:maxPixelDimension:)
    static func cachedMemoryImage(urlString: String, maxPixelDimension: CGFloat) -> NSImage? {
        let normalizedURL = normalized(urlString)
        guard !normalizedURL.isEmpty else { return nil }
        return decodedImageCache.object(forKey: cacheKey(normalizedURL, maxPixelDimension) as NSString)
    }

    @objc(cachedMemoryImageFromCandidates:maxPixelDimension:resolvedURL:)
    static func cachedMemoryImage(candidates: [String], maxPixelDimension: CGFloat, resolvedURL: AutoreleasingUnsafeMutablePointer<NSString?>?) -> NSImage? {
        for candidate in candidates {
            let normalizedURL = normalized(candidate)
            guard !normalizedURL.isEmpty else { continue }
            guard let image = cachedMemoryImage(urlString: normalizedURL, maxPixelDimension: maxPixelDimension) else { continue }
            resolvedURL?.pointee = normalizedURL as NSString
            return image
        }
        resolvedURL?.pointee = nil
        return nil
    }

    @objc(loadImageForURLCancellable:maxPixelDimension:completion:)
    static func loadImageForURLCancellable(urlString: String, maxPixelDimension: CGFloat, completion: @escaping (NSImage?, String?, Data?) -> Void) -> OpnImageLoadToken {
        let token = OpnImageLoadToken()
        let completionBox = OPNImageCompletionBox(completion)
        let normalizedURL = normalized(urlString)
        guard !normalizedURL.isEmpty else {
            DispatchQueue.main.async { if !token.isCancelled { completionBox.completion(nil, nil, nil) } }
            return token
        }
        let key = cacheKey(normalizedURL, maxPixelDimension)
        if let image = decodedImageCache.object(forKey: key as NSString) {
            let data = imageDataMemoryCache.object(forKey: key as NSString) as Data?
            DispatchQueue.main.async { if !token.isCancelled { completionBox.completion(image, normalizedURL, data) } }
            return token
        }
        if failureCacheContainsFreshEntry(normalizedURL) {
            DispatchQueue.main.async { if !token.isCancelled { completionBox.completion(nil, normalizedURL, nil) } }
            return token
        }
        let entry = OPNPendingImageCompletion(token: token, completion: completion)
        token.setCancelHandler { [weak token] in
            if let token { cancelPendingImageCompletion(cacheKey: key, token: token) }
        }
        let alreadyPending = stateQueue.sync { () -> Bool in
            if pendingCompletions[key] != nil {
                pendingCompletions[key]?.append(entry)
                return true
            }
            pendingCompletions[key] = [entry]
            return false
        }
        if alreadyPending { return token }
        if let diskData = OPNGameDataCache.shared.loadImage(urlString: normalizedURL), !diskData.isEmpty {
            let operation = BlockOperation {
                let image = decodedImage(data: diskData, maxPixelDimension: maxPixelDimension)
                completeImageRequest(cacheKey: key, urlString: normalizedURL, image: image, data: image == nil ? nil : diskData, cacheFailure: image == nil)
            }
            let shouldStart = stateQueue.sync { () -> Bool in
                guard pendingCompletions[key] != nil else { return false }
                pendingOperations[key] = operation
                return true
            }
            if shouldStart, !token.isCancelled {
                token.setOperation(operation)
                imageQueue.addOperation(operation)
            } else {
                operation.cancel()
            }
            return token
        }
        guard let url = URL(string: normalizedURL) else {
            completeImageRequest(cacheKey: key, urlString: normalizedURL, image: nil, data: nil, cacheFailure: true)
            return token
        }
        let request = NSMutableURLRequest(url: url)
        let trace = OPNSentry.traceHTTPRequest(request, name: "Image asset")
        let task = session.dataTask(with: request as URLRequest) { data, response, error in
            defer { trace?.finish() }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard error == nil, let data, !data.isEmpty, statusCode < 400 else {
                let cacheFailure = (error as NSError?)?.code != NSURLErrorCancelled
                completeImageRequest(cacheKey: key, urlString: normalizedURL, image: nil, data: nil, cacheFailure: cacheFailure)
                return
            }
            trace?.setStatus(true)
            let operation = BlockOperation {
                let image = decodedImage(data: data, maxPixelDimension: maxPixelDimension)
                if image != nil { OPNGameDataCache.shared.saveImage(urlString: normalizedURL, data: data) }
                completeImageRequest(cacheKey: key, urlString: normalizedURL, image: image, data: image == nil ? nil : data, cacheFailure: image == nil)
            }
            let shouldDecode = stateQueue.sync { () -> Bool in
                guard pendingCompletions[key] != nil else { return false }
                pendingOperations[key] = operation
                return true
            }
            if shouldDecode { imageQueue.addOperation(operation) } else { operation.cancel() }
        }
        let shouldStart = stateQueue.sync { () -> Bool in
            guard pendingCompletions[key] != nil else { return false }
            pendingTasks[key] = task
            return true
        }
        if shouldStart, !token.isCancelled {
            token.setTask(task)
            task.resume()
        } else {
            task.cancel()
        }
        return token
    }

    @objc(loadImageFromCandidatesCancellable:maxPixelDimension:completion:)
    static func loadImageFromCandidatesCancellable(candidates: [String], maxPixelDimension: CGFloat, completion: @escaping (NSImage?, String?, Data?) -> Void) -> OpnImageLoadToken {
        let token = OpnImageLoadToken()
        loadImageCandidate(at: 0, candidates: candidates, maxPixelDimension: maxPixelDimension, completion: completion, parentToken: token)
        return token
    }

    @objc(prefetchImageForURL:maxPixelDimension:)
    static func prefetchImage(urlString: String, maxPixelDimension: CGFloat) -> OpnImageLoadToken {
        loadImageForURLCancellable(urlString: urlString, maxPixelDimension: maxPixelDimension) { _, _, _ in }
    }

    @objc(prefetchImageFromCandidates:maxPixelDimension:)
    static func prefetchImage(candidates: [String], maxPixelDimension: CGFloat) -> OpnImageLoadToken {
        loadImageFromCandidatesCancellable(candidates: candidates, maxPixelDimension: maxPixelDimension) { _, _, _ in }
    }

    static func fallbackHeroArtworkImage() -> NSImage {
        if let fallbackHeroArtwork { return fallbackHeroArtwork }
        let size = NSSize(width: 1600.0, height: 900.0)
        let image = NSImage(size: size)
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: size)
        NSGradient(colors: [color(rgb: 0x182018, alpha: 1.0), color(rgb: 0x101113, alpha: 1.0)])?.draw(in: bounds, angle: 0.0)
        color(rgb: 0x34C759, alpha: 0.20).setFill()
        NSBezierPath(ovalIn: NSRect(x: -180.0, y: 90.0, width: 820.0, height: 820.0)).fill()
        color(rgb: 0xFFFFFF, alpha: 0.08).setStroke()
        for line in 0..<12 {
            let y = 120.0 + CGFloat(line) * 56.0
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0.0, y: y))
            path.line(to: NSPoint(x: size.width, y: y - 220.0))
            path.lineWidth = 1.0
            path.stroke()
        }
        image.unlockFocus()
        fallbackHeroArtwork = image
        return image
    }

    private static func resolvedInterfaceColor(_ rgb: UInt32) -> UInt32 {
        switch rgb {
        case 0x34C759, 0x49D56B, 0x2FB14F, 0x06140A: return rgb
        default: return rgb
        }
    }

    private static func clampedByte(_ value: Int) -> Int { max(0, min(value, 255)) }

    private static func normalized(_ urlString: String) -> String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cachePixelBucket(_ maxPixelDimension: CGFloat) -> Int {
        let clamped = max(64.0, min(maxPixelDimension > 0.0 ? maxPixelDimension : 1024.0, 4096.0))
        return Int(ceil(clamped / 128.0) * 128.0)
    }

    private static func cacheKey(_ urlString: String, _ maxPixelDimension: CGFloat) -> String {
        "\(urlString)|\(cachePixelBucket(maxPixelDimension))"
    }

    private static func decodedImage(data: Data, maxPixelDimension: CGFloat) -> NSImage? {
        guard !data.isEmpty else { return nil }
        let pixelLimit = cachePixelBucket(maxPixelDimension)
        let sourceOptions = [kCGImageSourceShouldCache as String: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceShouldCacheImmediately as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: pixelLimit
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return NSImage(data: data) }
        return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }

    private static func cache(image: NSImage, data: Data, key: String) {
        let cost = max(1, Int(image.size.width * image.size.height * 4.0))
        decodedImageCache.setObject(image, forKey: key as NSString, cost: cost)
        imageDataMemoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }

    private static func failureCacheContainsFreshEntry(_ urlString: String) -> Bool {
        guard !urlString.isEmpty else { return false }
        return stateQueue.sync {
            guard let expiresAt = failureCache[urlString] else { return false }
            if expiresAt.timeIntervalSinceNow > 0.0 { return true }
            failureCache.removeValue(forKey: urlString)
            return false
        }
    }

    private static func setFailure(_ urlString: String) {
        guard !urlString.isEmpty else { return }
        _ = stateQueue.sync { failureCache[urlString] = Date(timeIntervalSinceNow: 10.0 * 60.0) }
    }

    private static func clearFailure(_ urlString: String) {
        guard !urlString.isEmpty else { return }
        stateQueue.sync { failureCache.removeValue(forKey: urlString) }
    }

    private static func cancelPendingImageCompletion(cacheKey: String, token: OpnImageLoadToken) {
        var operationToCancel: Operation?
        var taskToCancel: URLSessionDataTask?
        stateQueue.sync {
            guard var entries = pendingCompletions[cacheKey] else { return }
            entries.removeAll { $0.token === token }
            if entries.isEmpty {
                pendingCompletions.removeValue(forKey: cacheKey)
                operationToCancel = pendingOperations.removeValue(forKey: cacheKey)
                taskToCancel = pendingTasks.removeValue(forKey: cacheKey)
            } else {
                pendingCompletions[cacheKey] = entries
            }
        }
        operationToCancel?.cancel()
        taskToCancel?.cancel()
    }

    private static func completeImageRequest(cacheKey: String, urlString: String, image: NSImage?, data: Data?, cacheFailure: Bool) {
        let completions = stateQueue.sync { () -> [OPNPendingImageCompletion] in
            if let image {
                let cost = max(1, Int(image.size.width * image.size.height * 4.0))
                decodedImageCache.setObject(image, forKey: cacheKey as NSString, cost: cost)
                failureCache.removeValue(forKey: urlString)
            } else if cacheFailure {
                failureCache[urlString] = Date(timeIntervalSinceNow: 10.0 * 60.0)
            }
            if let data, !data.isEmpty { imageDataMemoryCache.setObject(data as NSData, forKey: cacheKey as NSString, cost: data.count) }
            let entries = pendingCompletions.removeValue(forKey: cacheKey) ?? []
            pendingOperations.removeValue(forKey: cacheKey)
            pendingTasks.removeValue(forKey: cacheKey)
            entries.forEach { $0.token.setCancelHandler(nil) }
            return entries
        }
        DispatchQueue.main.async {
            for entry in completions where !entry.token.isCancelled {
                entry.completion(image, urlString, data)
            }
        }
    }

    private static func loadImageCandidate(at index: Int, candidates: [String], maxPixelDimension: CGFloat, completion: @escaping (NSImage?, String?, Data?) -> Void, parentToken: OpnImageLoadToken) {
        let completionBox = OPNImageCompletionBox(completion)
        guard !parentToken.isCancelled else { return }
        guard index < candidates.count else {
            DispatchQueue.main.async { if !parentToken.isCancelled { completionBox.completion(nil, nil, nil) } }
            return
        }
        let childToken = loadImageForURLCancellable(urlString: candidates[index], maxPixelDimension: maxPixelDimension) { image, resolvedURL, data in
            guard !parentToken.isCancelled else { return }
            if let image {
                completionBox.completion(image, resolvedURL, data)
                return
            }
            loadImageCandidate(at: index + 1, candidates: candidates, maxPixelDimension: maxPixelDimension, completion: completionBox.completion, parentToken: parentToken)
        }
        parentToken.addChild(childToken)
    }
}
