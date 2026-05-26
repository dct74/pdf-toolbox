import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Quartz
import Vision
import Darwin

// Global lock for serializing terminal output
private let outputLock = NSLock()

private func lockedPrint(_ item: Any, terminator: String = "\n") {
    outputLock.lock()
    defer { outputLock.unlock() }
    print(item, terminator: terminator)
}

// MARK: - Terminal Output Helpers with ANSI colors
private func printError(_ message: String) {
    lockedPrint("\u{001B}[31m✘ \(message)\u{001B}[0m"); fflush(stdout)
}

private func printWarning(_ message: String) {
    lockedPrint("\u{001B}[33m⚠️ \(message)\u{001B}[0m"); fflush(stdout)
}

private func printSuccess(_ message: String) {
    lockedPrint("\u{001B}[32m✔︎ \(message)\u{001B}[0m"); fflush(stdout)
}

private func printInfo(_ message: String) {
    lockedPrint("\u{001B}[36m🔔 \(message)\u{001B}[0m"); fflush(stdout)
}

// MARK: - Graceful Cancellation State (Thread-Safe)
final class CancellationState {
    static let shared = CancellationState()
    private let lock = NSLock()
    private var _isCancelled: Bool = false
    
    var isCancelled: Bool {
        get { lock.withLock { _isCancelled } }
        set { lock.withLock { _isCancelled = newValue } }
    }
}

// Register signal handler safely
signal(SIGINT) { _ in
    CancellationState.shared.isCancelled = true
    lockedPrint("\n\n👋 Interrupt signal received. Cancelling pending tasks...")
}

// MARK: - Task Result Model for Unified Output
enum TaskResult {
    case success(String)
    case warning(String)
}

// Internal unified outcome for concurrent processing
enum ProcessOutcome {
    case success(String)
    case warning(String)
    case failure(String)
}

// MARK: - Concurrency Limiter (Actor-based Async Semaphore)
actor ConcurrencyLimiter {
    let limit: Int
    var active: Int = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    
    init(limit: Int) { self.limit = limit }
    
    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            active -= 1
        }
    }
}

// MARK: - Simple Progress Display
class Spinner {
    private var currentMessage: String = ""
    private var isActive: Bool = false
    private let isSilent: Bool
    
    init(isSilent: Bool = false) {
        self.isSilent = isSilent
    }

    func update(message: String) {
        if isSilent { return }
        if isActive {
            lockedPrint("\r[Progress] \(message)\u{001B}[K", terminator: "")
            fflush(stdout)
        }
        currentMessage = message
    }

    func start(filename: String, initialMessage: String) {
        currentMessage = initialMessage
        if isSilent {
            lockedPrint("⏳ [Starting] \(filename)")
            return
        }
        
        isActive = true
        lockedPrint(filename)
        lockedPrint("[Progress] \(initialMessage)", terminator: "")
        fflush(stdout)
    }

    func stop() {
        if isSilent { return }
        if isActive {
            lockedPrint("\r\u{001B}[K", terminator: "")
            fflush(stdout)
            isActive = false
        }
    }
}

// MARK: - Error Model
enum PDFToolError: LocalizedError {
    case filterNotFound
    case documentLoadFailed(URL)
    case writeFailed(URL)
    case ocrFailed(String)
    case textutilFailed(Int32)
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .filterNotFound:
            return "Failed to load system Quartz Filter."
        case .documentLoadFailed(let url):
            return "Failed to read source PDF: \(url.lastPathComponent)"
        case .writeFailed(let url):
            return "Failed to write file: \(url.lastPathComponent)"
        case .ocrFailed(let message):
            return "OCR processing failed: \(message)"
        case .textutilFailed(let code):
            return "Text conversion failed with exit code \(code)"
        case .cancelled:
            return "Task cancelled by user."
        }
    }
}

// OCR configuration — created once per page because VNRecognizeTextRequest is single-use.
private let ocrRecognitionLevel: VNRequestTextRecognitionLevel = .accurate
private let ocrRecognitionLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"]

// MARK: - Core Processing Logic

private func checkCancellation() throws {
    if CancellationState.shared.isCancelled {
        throw PDFToolError.cancelled
    }
}

/// 1. Compress PDF
func compressPDF(url: URL, spinner: Spinner) async throws -> TaskResult? {
    let outURL = url.deletingPathExtension().appendingPathExtension("reduced.pdf")
    let filterURL = URL(filePath: "/System/Library/Filters/Reduce File Size.qfilter")

    guard let quartzFilter = QuartzFilter(url: filterURL) else { throw PDFToolError.filterNotFound }
    guard let pdfDoc = CGPDFDocument(url as CFURL) else { throw PDFToolError.documentLoadFailed(url) }
    guard let firstPage = pdfDoc.page(at: 1) else { throw PDFToolError.documentLoadFailed(url) }

    var mediaBox = firstPage.getBoxRect(.mediaBox)
    guard let context = CGContext(outURL as CFURL, mediaBox: &mediaBox, nil) else { throw PDFToolError.writeFailed(outURL) }

    for pageIndex in 1...pdfDoc.numberOfPages {
        try checkCancellation()
        spinner.update(message: "Compressing page \(pageIndex)/\(pdfDoc.numberOfPages)...")
        guard let page = pdfDoc.page(at: pageIndex) else { continue }
        var pageMediaBox = page.getBoxRect(.mediaBox)
        context.beginPage(mediaBox: &pageMediaBox)
        quartzFilter.apply(to: context)
        context.drawPDFPage(page)
        context.endPage()
    }
    context.closePDF()

    let originalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    let compressedSize = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int64) ?? 0

    if compressedSize >= originalSize || originalSize == 0 {
        do {
            try FileManager.default.removeItem(at: outURL)
        } catch {
            printWarning("Could not remove unneeded output \(outURL.lastPathComponent): \(error.localizedDescription)")
        }
        return .warning("Skipped \(url.lastPathComponent): Original file is empty or already optimally compressed.")
    } else {
        let reduction = Double(originalSize - compressedSize) / Double(originalSize) * 100
        return .success("Compressed: \(outURL.lastPathComponent) (Reduced by \(String(format: "%.1f", reduction))%)")
    }
}

/// 2. Split PDF
func splitPDF(url: URL, spinner: Spinner) async throws -> TaskResult? {
    let outputDir = try createOutputDir(for: url)
    guard let doc = PDFDocument(url: url) else { throw PDFToolError.documentLoadFailed(url) }

    for i in 0..<doc.pageCount {
        try checkCancellation()
        spinner.update(message: "Splitting page \(i + 1)/\(doc.pageCount)...")
        guard let page = doc.page(at: i) else { continue }
        let newDoc = PDFDocument()
        newDoc.insert(page, at: 0)
        let outURL = outputDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_Page\(i + 1).pdf")
        newDoc.write(to: outURL)
    }
    return .success("Split: \(doc.pageCount) page(s) -> \(outputDir.lastPathComponent)/")
}

/// 3. Convert PDF to JPEG
func toJPEG(url: URL, spinner: Spinner) async throws -> TaskResult? {
    let outputDir = try createOutputDir(for: url)
    guard let doc = PDFDocument(url: url) else { throw PDFToolError.documentLoadFailed(url) }

    let scale: CGFloat = 2.0
    let quality: CGFloat = 0.85

    for i in 0..<doc.pageCount {
        try checkCancellation()
        spinner.update(message: "Converting page \(i + 1)/\(doc.pageCount) to JPEG...")
        guard let page = doc.page(at: i) else { continue }
        let rect = page.bounds(for: .mediaBox)
        let width = Int(rect.width * scale)
        let height = Int(rect.height * scale)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }

        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let cgImage = ctx.makeImage() else { continue }
        let outURL = outputDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_Page\(i + 1).jpg")

        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
        let options: CFDictionary = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(dest, cgImage, options)
        CGImageDestinationFinalize(dest)
    }
    return .success("Converted: \(doc.pageCount) image(s) -> \(outputDir.lastPathComponent)/")
}

/// 4. Convert PDF to Word (Async OCR supported)
func convertToWord(url: URL, spinner: Spinner, forceOCR: Bool) async throws -> TaskResult? {
    let outURL = url.deletingPathExtension().appendingPathExtension("docx")
    spinner.update(message: "Analyzing document structure...")
    guard let doc = PDFDocument(url: url) else { throw PDFToolError.documentLoadFailed(url) }

    let isScannedPDF = doc.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true

    if !forceOCR, !isScannedPDF, let text = doc.string, !text.isEmpty {
        spinner.update(message: "Extracting text via textutil...")
        let tempTxt = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_temp.txt")
        
        defer { try? FileManager.default.removeItem(at: tempTxt) } // temp file; failure is harmless

        do {
            try text.write(to: tempTxt, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            process.arguments = ["-convert", "docx", "-output", outURL.path, tempTxt.path]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0, FileManager.default.fileExists(atPath: outURL.path) {
                return .success("Converted (Text): \(outURL.lastPathComponent)")
            }
        } catch { /* Fall through to OCR */ }
    }

    if forceOCR {
        spinner.update(message: "Force OCR mode enabled. Preparing OCR...")
    } else {
        spinner.update(message: "Detected scanned PDF. Preparing OCR...")
    }
    
    if FileManager.default.fileExists(atPath: outURL.path) {
        do {
            try FileManager.default.removeItem(at: outURL)
        } catch {
            spinner.stop()
            printWarning("Could not remove existing \(outURL.lastPathComponent): \(error.localizedDescription)")
        }
    }
    var ocrText = ""

    for i in 0..<doc.pageCount {
        try checkCancellation()
        spinner.update(message: "OCR recognizing page \(i + 1)/\(doc.pageCount)...")
        guard let page = doc.page(at: i) else { continue }

        let rect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let colorCtx = CGContext(data: nil, width: Int(rect.width * scale), height: Int(rect.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }

        colorCtx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: colorCtx)
        guard let renderImage = colorCtx.makeImage() else { continue }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = ocrRecognitionLevel
        request.recognitionLanguages = ocrRecognitionLanguages

        let handler = VNImageRequestHandler(cgImage: renderImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            printError("OCR engine error on page \(i + 1): \(error.localizedDescription)")
            continue
        }

        if let results = request.results, !results.isEmpty {
            let pageText = results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            if !pageText.isEmpty { ocrText += pageText + "\n\n" }
        }
    }

    guard !ocrText.isEmpty else { throw PDFToolError.ocrFailed("No text recognized.") }

    spinner.update(message: "Generating Word document...")
    let tempTxt = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_ocr_temp.txt")
    
    defer { try? FileManager.default.removeItem(at: tempTxt) } // temp file; failure is harmless

    try ocrText.write(to: tempTxt, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
    process.arguments = ["-convert", "docx", "-output", outURL.path, tempTxt.path]
    process.standardError = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    
    try process.run()
    process.waitUntilExit()

    if process.terminationStatus == 0, FileManager.default.fileExists(atPath: outURL.path) {
        return .success("Converted (OCR): \(outURL.lastPathComponent)")
    } else {
        throw PDFToolError.writeFailed(outURL)
    }
}

// MARK: - Utility Functions

func createOutputDir(for sourceURL: URL) throws -> URL {
    let dirName = sourceURL.deletingPathExtension().lastPathComponent
    let outputDir = sourceURL.deletingLastPathComponent().appendingPathComponent(dirName)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    return outputDir
}

func collectPDFs(from urls: [URL]) -> [URL] {
    var pdfs: [URL] = []
    for url in urls {
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = resourceValues?.isDirectory ?? false

        if isDirectory {
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator {
                if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                   values.isRegularFile == true,
                   fileURL.pathExtension.lowercased() == "pdf" {
                    pdfs.append(fileURL)
                }
            }
        } else if url.pathExtension.lowercased() == "pdf" {
            pdfs.append(url)
        }
    }
    return pdfs
}

// MARK: - Dispatcher with Concurrency Control

func processPDFs(actionName: String, pdfs: [URL], action: @escaping (URL, Spinner) async throws -> TaskResult?) async {
    var successCount = 0
    var failCount = 0
    var cancelledCount = 0
    
    let cyan = "\u{001B}[36m"
    let green = "\u{001B}[32m"
    let red = "\u{001B}[31m"
    let yellow = "\u{001B}[33m"
    let reset = "\u{001B}[0m"

    let totalCores = ProcessInfo.processInfo.processorCount
    let maxConcurrency = max(2, min(4, totalCores / 2))
    
    if pdfs.count == 1 {
        let pdf = pdfs[0]
        let spinner = Spinner(isSilent: false)
        spinner.start(filename: pdf.lastPathComponent, initialMessage: "Initializing [\(actionName)]...")
        // Brief pause so the spinner's "Starting" / "Initializing" line renders visibly before the action overwrites it.
        try? await Task.sleep(nanoseconds: 50_000_000)

        do {
            if let result = try await action(pdf, spinner) {
                spinner.stop()
                switch result {
                case .success(let msg): printSuccess(msg)
                case .warning(let msg): printWarning(msg)
                }
                successCount += 1
            } else {
                spinner.stop()
                successCount += 1
            }
        } catch {
            spinner.stop()
            if case PDFToolError.cancelled = error {
                printWarning("\(pdf.lastPathComponent): Cancelled.")
                cancelledCount += 1
            } else {
                let errMsg = (error as? PDFToolError)?.errorDescription ?? error.localizedDescription
                printError("\(pdf.lastPathComponent): \(errMsg)")
                failCount += 1
            }
        }
    } else {
        printInfo("Processing \(pdfs.count) files with concurrency up to \(maxConcurrency)...")
        let limiter = ConcurrencyLimiter(limit: maxConcurrency)
        
        await withTaskGroup(of: ProcessOutcome.self) { group in
            for pdf in pdfs {
                guard !CancellationState.shared.isCancelled else { break }
                
                group.addTask {
                    await limiter.acquire()
                    defer { Task { await limiter.release() } }

                    // Bail out before any heavy work if the user already cancelled.
                    if CancellationState.shared.isCancelled {
                        return .failure("\(pdf.lastPathComponent): Cancelled.")
                    }

                    let silentSpinner = Spinner(isSilent: true)
                    silentSpinner.start(filename: pdf.lastPathComponent, initialMessage: "Initializing...")

                    do {
                        if let result = try await action(pdf, silentSpinner) {
                            switch result {
                            case .success(let msg): return .success(msg)
                            case .warning(let msg): return .warning(msg)
                            }
                        }
                        return .success("\(pdf.lastPathComponent) processed.")
                    } catch {
                        if case PDFToolError.cancelled = error {
                            return .failure("\(pdf.lastPathComponent): Cancelled.")
                        }
                        let errMsg = (error as? PDFToolError)?.errorDescription ?? error.localizedDescription
                        return .failure("\(pdf.lastPathComponent): \(errMsg)")
                    }
                }
            }
            
            for await outcome in group {
                switch outcome {
                case .success(let msg):
                    printSuccess(msg)
                    successCount += 1
                case .warning(let msg):
                    printWarning(msg)
                    successCount += 1
                case .failure(let msg):
                    if msg.contains("Cancelled") {
                        printWarning(msg)
                        cancelledCount += 1
                    } else {
                        printError(msg)
                        failCount += 1
                    }
                }
            }
        }
    }

    // MARK: - Smart Statistics Report
    lockedPrint("")
    var reportParts: [String] = []
    
    if successCount > 0 {
        reportParts.append("Success: \(green)\(successCount)\(cyan)")
    }
    if cancelledCount > 0 {
        reportParts.append("Cancelled: \(yellow)\(cancelledCount)\(cyan)")
    }
    if failCount > 0 {
        reportParts.append("Failed: \(red)\(failCount)")
    }
    
    let finalReport: String
    if reportParts.isEmpty {
        finalReport = "\(cyan)📊 Processing complete. No files processed.\(reset)"
    } else {
        finalReport = "\(cyan)📊 Processing complete. \(reportParts.joined(separator: ", "))\(reset)"
    }
    
    lockedPrint(finalReport)
    lockedPrint("")
    fflush(stdout)
}

// MARK: - Help Menu

private func printHelp() {
    lockedPrint("""
    Usage: pdf-toolbox [OPTIONS] [ACTION] [FILES...]

    Actions:
      1                Reduce File Size
      2                Split PDF
      3                Convert to JPEG
      4                Convert to Word
      5                Convert to Word (Force OCR)

    Options:
      --force-ocr      Force OCR processing for Word conversion (ignores normal text extraction).
                       If used without action '4', it will automatically execute Word conversion.
      --help, -h       Show this help message.

    Examples:
      pdf-toolbox 1 file1.pdf file2.pdf
      pdf-toolbox --force-ocr file.pdf
      pdf-toolbox 5 file.pdf
      pdf-toolbox file1.pdf  (Enter interactive mode)
    """)
}

// MARK: - Interactive Menu & Main Entry

func showMenu() {
    lockedPrint("\n========================================")
    lockedPrint(" 🛠️ PDF Batch Tool")
    lockedPrint("========================================")
    lockedPrint("1. Reduce File Size")
    lockedPrint("2. Split PDF")
    lockedPrint("3. Convert to JPEG")
    lockedPrint("4. Convert to Word (Text/OCR, no layout)")
    lockedPrint("5. Convert to Word (Force OCR)") // Added
    lockedPrint("Q. Exit")
    lockedPrint("", terminator: "\nEnter option (1-5, Q): ")
}

func run() async {
    let args = CommandLine.arguments.dropFirst()

    var forceOCR = false
    var remainingArgs: [String] = []

    for arg in args {
        switch arg.lowercased() {
        case "--help", "-h":
            printHelp()
            return
        case "--force-ocr":
            forceOCR = true
        default:
            remainingArgs.append(arg)
        }
    }

    guard !remainingArgs.isEmpty else {
        printWarning("Usage: Drag and drop PDF files or folders onto this script.")
        lockedPrint("Example: ./PDFTool file1.pdf \"Folder With Spaces\" file2.pdf")
        lockedPrint("Or: ./PDFTool 1 file1.pdf (1=Compress, 2=Split, 3=JPEG, 4=Word, 5=Force OCR)")
        lockedPrint("Run with --help for more details.")
        return
    }

    let possibleChoice = remainingArgs.first
    var choice: String?
    let inputPaths: [URL]

    // Added "5" to the direct command execution check
    if let first = possibleChoice, ["1", "2", "3", "4", "5"].contains(first) {
        choice = first
        inputPaths = remainingArgs.dropFirst().map { URL(fileURLWithPath: $0) }
    } else {
        choice = nil
        inputPaths = remainingArgs.map { URL(fileURLWithPath: $0) }
    }

    if forceOCR && choice == nil {
        choice = "4"
    }

    guard !inputPaths.isEmpty else {
        printWarning("No file or folder paths provided.")
        return
    }

    let pdfs = collectPDFs(from: inputPaths)
    guard !pdfs.isEmpty else {
        printWarning("No PDF files found in the provided paths.")
        return
    }

    lockedPrint("🔍 Found \(pdfs.count) PDF file(s) to process:")
    for pdf in pdfs {
        lockedPrint(" - \(pdf.lastPathComponent)")
    }

    if forceOCR {
        printInfo("Force OCR mode is ENABLED.")
    }

    func buildAction(for choice: String) -> ((URL, Spinner) async throws -> TaskResult?)? {
        switch choice {
        case "1": return compressPDF
        case "2": return splitPDF
        case "3": return toJPEG
        case "4":
            let isForced = forceOCR
            return { url, spinner in try await convertToWord(url: url, spinner: spinner, forceOCR: isForced) }
        case "5":
            // Directly force OCR when '5' is selected
            return { url, spinner in try await convertToWord(url: url, spinner: spinner, forceOCR: true) }
        default: return nil
        }
    }

    if let choice = choice {
        guard let action = buildAction(for: choice) else { return }
        // Updated action names array
        let actionName = ["", "Compress", "Split", "JPEG", "Word", "Word (Force OCR)"][Int(choice) ?? 0]
        lockedPrint("\n🚀 Executing [\(actionName)]...\n")
        await processPDFs(actionName: actionName, pdfs: pdfs, action: action)
        return
    }

    showMenu()
    guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        lockedPrint("No input available. Exiting.")
        return
    }

    var action: ((URL, Spinner) async throws -> TaskResult?)?
    var actionName = ""

    switch choice {
    case "1": action = compressPDF; actionName = "Compress"
    case "2": action = splitPDF; actionName = "Split"
    case "3": action = toJPEG; actionName = "JPEG"
    case "4":
        action = { url, spinner in try await convertToWord(url: url, spinner: spinner, forceOCR: false) }
        actionName = "Word"
    case "5":
        action = { url, spinner in try await convertToWord(url: url, spinner: spinner, forceOCR: true) }
        actionName = "Word (Force OCR)"
    case "Q", "q": lockedPrint("👋 Exit"); return
    default: return
    }

    lockedPrint("\n🚀 Executing [\(actionName)]...\n")
    await processPDFs(actionName: actionName, pdfs: pdfs, action: action!)
}

// MARK: - Modern Bootstrap Entry Point
Task {
    await run()
    exit(0)
}

dispatchMain()
